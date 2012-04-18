/*
 * Copyright (C) 2010, 2011, 2012 Mail.RU
 * Copyright (C) 2010, 2011, 2012 Yuriy Vostrikov
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#import <util.h>
#import <fiber.h>
#import <iproto.h>
#import <log_io.h>
#import <net_io.h>
#import <pickle.h>
#import <salloc.h>
#import <say.h>
#import <stat.h>
#import <tarantool.h>
#import <tbuf.h>
#import <util.h>
#import <object.h>
#import <assoc.h>
#import <index.h>

#import <mod/box/box.h>
#import <mod/box/moonbox.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sysexits.h>

static struct service *box_primary, *box_secondary;

static int stat_base;
STRS(messages, MESSAGES);

const int MEMCACHED_OBJECT_SPACE = 23;

struct object_space *object_space_registry;
const int object_space_count = 256;

@class BoxRecovery;
static BoxRecovery *recovery;

struct box_snap_row {
	u32 object_space;
	u32 tuple_size;
	u32 data_size;
	u8 data[];
} __attribute((packed));

void __attribute__((noreturn))
bad_object_type()
{
	raise("bad object type");
}

static inline struct box_snap_row *
box_snap_row(const struct tbuf *t)
{
	return (struct box_snap_row *)t->data;
}


void *
next_field(void *f)
{
	u32 size = LOAD_VARINT32(f);
	return (u8 *)f + size;
}

void *
tuple_field(struct box_tuple *tuple, size_t i)
{
	void *field = tuple->data;

	if (i >= tuple->cardinality)
		return NULL;

	while (i-- > 0)
		field = next_field(field);

	return field;
}

static void
lock_object(struct box_txn *txn, struct tnt_object *obj)
{
	if (obj->flags & WAL_WAIT)
		iproto_raise(ERR_CODE_NODE_IS_RO, "object is locked");

	say_debug("lock_object(%p)", obj);
	txn->lock_obj = obj;
	obj->flags |= WAL_WAIT;
}

static void
field_print(struct tbuf *buf, void *f)
{
	uint32_t size;

	size = LOAD_VARINT32(f);

	if (size == 2)
		tbuf_printf(buf, "%i:", *(u16 *)f);

	if (size == 4)
		tbuf_printf(buf, "%i:", *(u32 *)f);

	tbuf_printf(buf, "\"");
	while (size-- > 0) {
		if (0x20 <= *(u8 *)f && *(u8 *)f < 0x7f)
			tbuf_printf(buf, "%c", *(u8 *)f++);
		else
			tbuf_printf(buf, "\\x%02X", *(u8 *)f++);
	}
	tbuf_printf(buf, "\"");

}

static void
tuple_print(struct tbuf *buf, uint8_t cardinality, void *f)
{
	tbuf_printf(buf, "<");

	for (size_t i = 0; i < cardinality; i++, f = next_field(f)) {
		field_print(buf, f);

		if (likely(i + 1 < cardinality))
			tbuf_printf(buf, ", ");

	}

	tbuf_printf(buf, ">");
}

static struct tnt_object *
tuple_alloc(size_t size)
{
	struct tnt_object *obj = object_alloc(BOX_TUPLE, sizeof(struct box_tuple) + size);
	struct box_tuple *tuple = box_tuple(obj);

	tuple->bsize = size;
	say_debug("tuple_alloc(%zu) = %p", size, tuple);
	return obj;
}

static u32
valid_tuple(struct tbuf *buf, u32 cardinality)
{
	struct tbuf tmp;

	memcpy(&tmp, buf, sizeof(tmp));
	for (int i = 0; i < cardinality; i++)
		read_field(&tmp);

	return tbuf_len(buf) - tbuf_len(&tmp);
}

static void
validate_indexes(struct box_txn *txn)
{
	foreach_index(index, txn->object_space) {
                [index valid_object:txn->obj];

		if (index->unique) {
                        struct tnt_object *obj = [index find_by_obj:txn->obj];

                        if (obj != NULL && obj != txn->old_obj)
				iproto_raise_fmt(ERR_CODE_INDEX_VIOLATION,
						 "duplicate key value violates unique index %i:%s",
						 index->n, [index class]->name);
                }
	}
}


static void __attribute((noinline))
prepare_replace(struct box_txn *txn, size_t cardinality, struct tbuf *data)
{
	if (cardinality == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "cardinality can't be equal to 0");
	if (tbuf_len(data) == 0 || tbuf_len(data) != valid_tuple(data, cardinality))
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "tuple encoding error");

	txn->obj = tuple_alloc(tbuf_len(data));
	struct box_tuple *tuple = box_tuple(txn->obj);
	object_ref(txn->obj, +1);
	tuple->cardinality = cardinality;
	memcpy(tuple->data, data->data, tbuf_len(data));
	tbuf_ltrim(data, tbuf_len(data));

	txn->old_obj = [txn->index find_by_obj:txn->obj];
	if (txn->old_obj != NULL)
		object_ref(txn->old_obj, +1);

	if (txn->flags & BOX_ADD && txn->old_obj != NULL)
		iproto_raise(ERR_CODE_NODE_FOUND, "tuple found");

	if (txn->flags & BOX_REPLACE && txn->old_obj == NULL)
		iproto_raise(ERR_CODE_NODE_NOT_FOUND, "tuple not found");

	validate_indexes(txn);

	if (txn->old_obj != NULL) {
		lock_object(txn, txn->old_obj);
		txn->obj_affected = 2;
	} else {
		/*
		 * if tuple doesn't exist insert GHOST tuple in indeces
		 * in order to avoid race condition
		 * ref count will be incr in commit
		 */

		foreach_index(index, txn->object_space)
			[index replace: txn->obj];

		lock_object(txn, txn->obj);
		txn->obj->flags |= GHOST;
		txn->obj_affected = 1;
	}
}

static void
commit_replace(struct box_txn *txn)
{
	if (txn->old_obj != NULL) {
		foreach_index(index, txn->object_space)
			[index remove: txn->old_obj];

		object_ref(txn->old_obj, -1);

		foreach_index(index, txn->object_space)
			[index replace: txn->obj];
	}

	if (txn->obj != NULL) {
		txn->obj->flags &= ~GHOST;
		object_ref(txn->obj, +1);
	}

	if (txn->m) {
		net_add_iov_dup(&txn->m, &txn->obj_affected, sizeof(u32));

		if (txn->obj && txn->flags & BOX_RETURN_TUPLE)
			tuple_add_iov(&txn->m, txn->obj);
	}
}

static void
rollback_replace(struct box_txn *txn)
{
	say_debug("rollback_replace: txn->obj:%p", txn->obj);

	if (txn->obj && txn->obj->flags & GHOST) {
		foreach_index(index, txn->object_space)
			[index remove: txn->obj];
	}
}

static void
do_field_arith(u8 op, struct tbuf *field, void *arg, u32 arg_size)
{
	if (tbuf_len(field) != 4)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "num op on field with length != 4");
	if (arg_size != 4)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "num op with arg not u32");

	switch (op) {
	case 1:
		*(i32 *)field->data += *(i32 *)arg;
		break;
	case 2:
		*(u32 *)field->data &= *(u32 *)arg;
		break;
	case 3:
		*(u32 *)field->data ^= *(u32 *)arg;
		break;
	case 4:
		*(u32 *)field->data |= *(u32 *)arg;
		break;
	}
}

static size_t
do_field_splice(struct tbuf *field, void *args_data, u32 args_data_size)
{
	struct tbuf args = {
		.len = args_data_size,
		.size = args_data_size,
		.data = args_data,
		.pool = NULL
	};
	struct tbuf *new_field = NULL;
	void *offset_field, *length_field, *list_field;
	u32 offset_size, length_size, list_size;
	i32 offset, length;
	u32 noffset, nlength;	/* normalized values */

	new_field = tbuf_alloc(fiber->pool);

	offset_field = read_field(&args);
	length_field = read_field(&args);
	list_field = read_field(&args);
	if (tbuf_len(&args)!= 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad args");

	offset_size = LOAD_VARINT32(offset_field);
	if (offset_size == 0)
		noffset = 0;
	else if (offset_size == sizeof(offset)) {
		offset = pick_u32(offset_field, &offset_field);
		if (offset < 0) {
			if (tbuf_len(field) < -offset)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					  "do_field_splice: noffset is negative");
			noffset = offset + tbuf_len(field);
		} else
			noffset = offset;
	} else
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad size of offset field");
	if (noffset > tbuf_len(field))
		noffset = tbuf_len(field);

	length_size = LOAD_VARINT32(length_field);
	if (length_size == 0)
		nlength = tbuf_len(field) - noffset;
	else if (length_size == sizeof(length)) {
		if (offset_size == 0)
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
				  "do_field_splice: offset field is empty but length is not");

		length = pick_u32(length_field, &length_field);
		if (length < 0) {
			if ((tbuf_len(field) - noffset) < -length)
				nlength = 0;
			else
				nlength = length + tbuf_len(field) - noffset;
		} else
			nlength = length;
	} else
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad size of length field");
	if (nlength > (tbuf_len(field) - noffset))
		nlength = tbuf_len(field) - noffset;

	list_size = LOAD_VARINT32(list_field);
	if (list_size > 0 && length_size == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
			  "do_field_splice: length field is empty but list is not");
	if (list_size > (UINT32_MAX - (tbuf_len(field) - nlength)))
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: list_size is too long");

	say_debug("do_field_splice: noffset = %i, nlength = %i, list_size = %u",
		  noffset, nlength, list_size);

	new_field->len = 0;
	tbuf_append(new_field, field->data, noffset);
	tbuf_append(new_field, list_field, list_size);
	tbuf_append(new_field, field->data + noffset + nlength, tbuf_len(field) - (noffset + nlength));

	size_t diff = (varint32_sizeof(new_field->len) + new_field->len) -
		      (varint32_sizeof(field->len) + field->len);

	*field = *new_field;
	return diff;
}

static void __attribute__((noinline))
prepare_update_fields(struct box_txn *txn, struct tbuf *data)
{
	struct tbuf *fields;
	void *field;
	int i;
	u32 op_cnt;

	u32 key_cardinality = read_u32(data);
	txn->old_obj = [txn->index find_key:data with_cardinalty:key_cardinality];
	op_cnt = read_u32(data);

	if (op_cnt > 128)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "too many ops");
	if (op_cnt == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "no ops");

	if (txn->old_obj == NULL) {
		/* pretend we parsed all data */
		tbuf_ltrim(data, tbuf_len(data));
		return;
	}

	object_ref(txn->old_obj, +1);
	lock_object(txn, txn->old_obj);
	txn->obj_affected = 1;

	struct box_tuple *old_tuple = box_tuple(txn->old_obj);
	size_t bsize = old_tuple->bsize;
	int cardinality = old_tuple->cardinality;
	int field_count = cardinality * 1.2;
	fields = palloc(fiber->pool, field_count * sizeof(struct tbuf));

	for (i = 0, field = old_tuple->data; i < cardinality; i++) {
		void *src = field;
		int len = LOAD_VARINT32(field);
		fields[i] = (struct tbuf){len, field - src, src,  NULL};
		field += len;
	}

	while (op_cnt-- > 0) {
		u8 op;
		u32 field_no, arg_size;
		void *arg;
		struct tbuf *field = NULL;

		field_no = read_u32(data);
		op = read_u8(data);
		arg = read_field(data);
		arg_size = LOAD_VARINT32(arg);

		if (op <= 6) {
			if (field_no >= cardinality)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					     "update of field beyond tuple cardinality");
			field = &fields[field_no];

			if (field->pool == NULL) {
				void *tmp = field->data + field->size;
				field->size = MAX(arg_size, field->len);
				if (field->size == 0)
					field->size = 8;
				field->data = palloc(fiber->pool, field->size);
				memcpy(field->data, tmp, field->len);
				field->pool = fiber->pool;
			}
		}

		switch (op) {
		case 0:
			tbuf_ensure(field, arg_size);
			bsize -= varint32_sizeof(field->len) + field->len;
			bsize += varint32_sizeof(arg_size) + arg_size;
			field->len = arg_size;
			memcpy(field->data, arg, arg_size);
			break;
		case 1 ... 4:
			do_field_arith(op, field, arg, arg_size);
			break;
		case 5:
			bsize += do_field_splice(field, arg, arg_size);
			break;
		case 6:
			if (arg_size != 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "delete must have empty arg");
			if (field_no == 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unabled to delete PK");

			bsize -= varint32_sizeof(field->len) + field->len;
			for (int i = field_no; i < cardinality - 1; i++)
				fields[i] = fields[i + 1];
			cardinality--;
			break;
		case 7:
			if (field_no == 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unabled to insert PK");
			if (field_no > cardinality)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					     "update of field beyond tuple cardinality");
			if (unlikely(field_count == cardinality)) {
				struct tbuf *tmp = fields;
				fields = p0alloc(fiber->pool,
						 (old_tuple->cardinality + 128) * sizeof(struct tbuf));
				memcpy(fields, tmp, field_count * sizeof(struct tbuf));
			}
			for (int i = cardinality - 1; i >= field_no; i--)
				fields[i + 1] = fields[i];
			fields[field_no] = (struct tbuf){arg_size, arg_size,
							 palloc(fiber->pool, arg_size),
							 fiber->pool};
			memcpy(fields[field_no].data, arg, arg_size);
			bsize += varint32_sizeof(arg_size) + arg_size;
			cardinality++;
			break;
		default:
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "invalid op");
		}
	}

	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");

	txn->obj = tuple_alloc(bsize);
	object_ref(txn->obj, +1);
	box_tuple(txn->obj)->cardinality = cardinality;

	u8 *p = box_tuple(txn->obj)->data;
	i = 0;
	do {
		if (fields[i].pool == NULL) {
			void *src = fields[i].data;
			int len = fields[i].len + fields[i].size;
			for (i++; i < cardinality && src + len == fields[i].data; i++)
				len += fields[i].len + fields[i].size;
			memcpy(p, src, len);
			p += len;
		} else {
			int len = fields[i].len;
			p = save_varint32(p, len);
			memcpy(p, fields[i].data, len);
			p += len;
			i++;
		}
	} while (i < cardinality);

	validate_indexes(txn);
}

void
tuple_add_iov(struct netmsg **m, struct tnt_object *obj)
{
	struct box_tuple *tuple = box_tuple(obj);

	net_add_ref_iov(m, obj, &tuple->bsize,
			tuple->bsize + sizeof(tuple->bsize) +
			sizeof(tuple->cardinality));
}

static void __attribute__((noinline))
process_select(struct box_txn *txn, u32 limit, u32 offset, struct tbuf *data)
{
	struct tnt_object *obj;
	uint32_t *found;
	u32 count = read_u32(data);

	found = palloc(txn->m->pool, sizeof(*found));
	net_add_iov(&txn->m, found, sizeof(*found));
	*found = 0;

	if (txn->index->unique) {
		for (u32 i = 0; i < count; i++) {
			u32 c = read_u32(data);
			obj = [txn->index find_key:data with_cardinalty:c];
			if (obj == NULL)
				continue;
			if (unlikely(limit == 0))
				continue;
			if (unlikely(offset > 0)) {
				offset--;
				continue;
			}

			(*found)++;
			tuple_add_iov(&txn->m, obj);
			limit--;
		}
	} else {
		/* The only non unique index type is Tree */
		Tree *tree = (Tree *)txn->index;
		for (u32 i = 0; i < count; i++) {
			u32 c = read_u32(data);
			[tree iterator_init:data with_cardinalty:c];

			if (unlikely(limit == 0))
				continue;

			while ((obj = [tree iterator_next_verify_pattern]) != NULL) {
				if (unlikely(limit == 0))
					continue;
				if (unlikely(offset > 0)) {
					offset--;
					continue;
				}

				(*found)++;
				tuple_add_iov(&txn->m, obj);
				--limit;
			}
		}
	}

	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");

	stat_collect(stat_base, SELECT_KEYS, count);
	stat_collect(stat_base, txn->op, 1);
}

static void __attribute__((noinline))
prepare_delete(struct box_txn *txn, struct tbuf *key_data)
{
	u32 c = read_u32(key_data);
	txn->old_obj = [txn->index find_key:key_data with_cardinalty:c];

	if (txn->old_obj == NULL)
		return;

	object_ref(txn->old_obj, +1);
	lock_object(txn, txn->old_obj);
	txn->obj_affected = 1;
}

static void
commit_delete(struct box_txn *txn)
{
	if (txn->old_obj) {
		foreach_index(index, txn->object_space)
			[index remove: txn->old_obj];
		object_ref(txn->old_obj, -1);
	}
	if (txn->m)
		net_add_iov_dup(&txn->m, &txn->obj_affected, sizeof(u32));
}

void
txn_init(struct iproto_header *req, struct box_txn *txn, struct netmsg *m)
{
	memset(txn, 0, sizeof(*txn));
	txn->op = req->msg_code;
	if (m) {
		txn->m = m;
		netmsg_getmark(txn->m, &txn->header_mark);
		iproto_reply(&txn->m, req->msg_code, req->sync);
	}
}

void
txn_cleanup(struct box_txn *txn)
{
	assert(txn->op != 0);

	if (txn->lock_obj) {
		txn->lock_obj->flags &= ~WAL_WAIT;
		txn->lock_obj = NULL;
	}

	if (txn->obj)
		object_ref(txn->obj, -1);

	if (txn->old_obj)
		object_ref(txn->old_obj, -1);

	/* mark txn as clean */
	memset(txn, 0, sizeof(*txn));
}


void
txn_commit(struct box_txn *txn)
{
	if (txn->op == DELETE)
		commit_delete(txn);
	else
		commit_replace(txn);

	say_debug("txn_commit(op:%s)", messages_strs[txn->op]);
	stat_collect(stat_base, txn->op, 1);
}

void
txn_abort(struct box_txn *txn)
{
	say_debug("box_rollback(op:%s)", messages_strs[txn->op]);

	if (txn->op == DELETE)
		return;

	if (txn->op == INSERT)
		rollback_replace(txn);
}

void
txn_submit_to_storage(struct box_txn *txn)
{
	[recovery submit_change:txn->wal_record];
}

static void
txn_common_parser(struct box_txn *txn, struct tbuf *data)
{
	i32 n = read_u32(data);
	if (n < 0 || n > object_space_count - 1)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "bad namespace number");

	if (!object_space_registry[n].enabled) {
		say_warn("object_space %i is not enabled", n);
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "object_space is not enabled");
	}

	txn->object_space = &object_space_registry[n];
}

static bool __attribute__((pure))
op_is_select(u32 op)
{
	return op == SELECT || op == SELECT_LIMIT;
}

static void
box_dispach_select(struct box_txn *txn, struct tbuf *data)
{
	txn_common_parser(txn, data);

	u32 i = read_u32(data);
	u32 offset = read_u32(data);
	u32 limit = read_u32(data);

	if (i > MAX_IDX)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "index too big");

	if ((txn->index = txn->object_space->index[i]) == NULL)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "index is invalid");

	process_select(txn, limit, offset, data);
}


void
box_prepare_update(struct box_txn *txn, struct tbuf *data)
{
	txn->wal_record = tbuf_alloc(fiber->pool);
	tbuf_append(txn->wal_record, &txn->op, sizeof(txn->op));
	tbuf_append(txn->wal_record, data->data, tbuf_len(data));

	say_debug("box_dispach(%i)", txn->op);
	txn_common_parser(txn, data);
	txn->index = txn->object_space->index[0];

	switch (txn->op) {
	case INSERT:
		txn->flags = read_u32(data);
		u32 cardinality = read_u32(data);
		if (txn->object_space->cardinality > 0
		    && txn->object_space->cardinality != cardinality)
		{
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
				  "tuple cardinality must match object_space cardinality");
		}
		prepare_replace(txn, cardinality, data);
		break;

	case DELETE:
		prepare_delete(txn, data);
		break;

	case UPDATE_FIELDS:
		txn->flags = read_u32(data);
		prepare_update_fields(txn, data);
		break;

	default:
		say_error("box_dispach: unsupported command = %" PRIi32 "", txn->op);
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unknown op code");
	}

	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");
}

static void
box_process(struct conn *c, struct tbuf *request)
{
	struct box_txn txn = { .op = 0 };
	u32 msg_code = iproto(request)->msg_code;
	struct tbuf request_data = { .pool = fiber->pool,
				     .len = iproto(request)->len,
				     .size = iproto(request)->len,
				     .data = iproto(request)->data };
	@try {
		if (op_is_select(msg_code)) {
			txn_init(iproto(request), &txn, netmsg_tail(&c->out_messages, c->pool));
			box_dispach_select(&txn, &request_data);
			iproto_commit(&txn.header_mark);
		} else {
			ev_tstamp start = ev_now(), stop;
			struct netmsg_tailq q = TAILQ_HEAD_INITIALIZER(q);
			txn_init(iproto(request), &txn, netmsg_tail(&q, fiber->pool));

			if (unlikely(c->service != box_primary))
				iproto_raise(ERR_CODE_NONMASTER, "updates forbiden on secondary port");

			if (msg_code == EXEC_LUA) {
				box_dispach_lua(&txn, &request_data);
			} else {
				box_prepare_update(&txn, &request_data);
				/* we'r potentially block here */
				txn_submit_to_storage(&txn);
				txn_commit(&txn);
			}
			iproto_commit(&txn.header_mark);
			netmsg_concat(&c->out_messages, &q, c->pool);

			stop = ev_now();
			if (stop - start > cfg.too_long_threshold)
				say_warn("too long %s: %.3f sec", messages_strs[txn.op], stop - start);
		}
	}
	@catch (Error *e) {
		say_debug("aboring txn, [%s reason:\"%s\"] at %s:%d",
			  [[e class] name], e->reason, e->file, e->line);
		if (e->backtrace)
			say_debug("backtrace: %s", e->backtrace);
		txn_abort(&txn);
		u32 rc = ERR_CODE_UNKNOWN_ERROR;
		if ([e respondsTo:@selector(code)])
			rc = [(id)e code];
		else if ([e isMemberOf:[IndexError class]])
			rc = ERR_CODE_ILLEGAL_PARAMS;
		iproto_error(&txn.m, &txn.header_mark, rc, e->reason);
		if (&c->out_messages != txn.m->tailq)
			netmsg_concat(&c->out_messages, txn.m->tailq, c->pool);
	}
	@finally {
		txn_cleanup(&txn);
	}
}

static int
box_xlog_sprint(struct tbuf *buf, const struct tbuf *t)
{
	struct row_v12 *row = row_v12(t);

	struct tbuf *b = palloc(fiber->pool, sizeof(*b));
	b->data = row->data;
	b->len = row->len;
	u16 tag, op;
	u64 cookie;
	struct sockaddr_in *peer = (void *)&cookie;

	u32 n, key_len;
	void *key;
	u32 cardinality, field_no;
	u32 flags;
	u32 op_cnt;

	tbuf_printf(buf, "lsn:%" PRIi64 " ", row->lsn);

	tag = row->tag;
	cookie = row->cookie;
	op = read_u16(b);
	n = read_u32(b);

	tbuf_printf(buf, "tm:%.3f t:%s %s %s n:%i ",
		    row->tm, xlog_tag_to_a(tag), sintoa(peer),
		    messages_strs[op], n);

	switch (op) {
	case INSERT:
		flags = read_u32(b);
		cardinality = read_u32(b);
		if (tbuf_len(b) != valid_tuple(b, cardinality))
			abort();
		tuple_print(buf, cardinality, b->data);
		break;

	case DELETE:
		key_len = read_u32(b);
		key = read_field(b);
		if (tbuf_len(b) != 0)
			abort();
		tuple_print(buf, key_len, key);
		break;

	case UPDATE_FIELDS:
		flags = read_u32(b);
		key_len = read_u32(b);
		key = read_field(b);
		op_cnt = read_u32(b);

		tbuf_printf(buf, "flags:%08X ", flags);
		tuple_print(buf, key_len, key);

		while (op_cnt-- > 0) {
			field_no = read_u32(b);
			u8 op = read_u8(b);
			void *arg = read_field(b);

			tbuf_printf(buf, " [field_no:%i op:", field_no);
			switch (op) {
			case 0:
				tbuf_printf(buf, "set ");
				break;
			case 1:
				tbuf_printf(buf, "add ");
				break;
			case 2:
				tbuf_printf(buf, "and ");
				break;
			case 3:
				tbuf_printf(buf, "xor ");
				break;
			case 4:
				tbuf_printf(buf, "or ");
				break;
			case 5:
				tbuf_printf(buf, "splice ");
				break;
			case 6:
				tbuf_printf(buf, "delete ");
				break;
			case 7:
				tbuf_printf(buf, "insert ");
				break;
			}
			tuple_print(buf, 1, arg);
			tbuf_printf(buf, "] ");
		}
		break;
	default:
		tbuf_printf(buf, "unknown wal op %" PRIi32, op);
	}
	return 0;
}



static int
snap_print(Recovery *r __attribute__((unused)), struct tbuf *t)
{
	struct tbuf *out = tbuf_alloc(t->pool);
	struct box_snap_row *row;
	struct row_v12 *raw_row = row_v12(t);

	struct tbuf *b = palloc(fiber->pool, sizeof(*b));
	b->data = raw_row->data;
	b->len = raw_row->len;

	u16 tag = raw_row->tag;

	row = box_snap_row(b);

	if (tag == snap_tag) {
		tuple_print(out, row->tuple_size, row->data);
		printf("lsn:%" PRIi64 " tm:%.3f n:%i %*s\n",
		       raw_row->lsn, raw_row->tm,
		       row->object_space, tbuf_len(out), (char *)out->data);
	} else if (tag == snap_initial_tag)
		printf("lsn:%" PRIi64 " initial row\n", raw_row->lsn);
	return 0;
}

static int
xlog_print(Recovery *r __attribute__((unused)), struct tbuf *t)
{
	struct tbuf *out = tbuf_alloc(t->pool);
	int res = box_xlog_sprint(out, t);
	if (res >= 0)
		printf("%*s\n", tbuf_len(out), (char *)out->data);
	return res;
}

static void
configure(void)
{
	if (cfg.object_space == NULL)
		panic("at least one object_space should be configured");

	for (int i = 0; i < object_space_count; i++) {
		if (cfg.object_space[i] == NULL)
			break;

		if (!CNF_STRUCT_DEFINED(cfg.object_space[i]))
			object_space_registry[i].enabled = false;
		else
			object_space_registry[i].enabled = !!cfg.object_space[i]->enabled;

		if (!object_space_registry[i].enabled)
			continue;

		object_space_registry[i].cardinality = cfg.object_space[i]->cardinality;

		if (cfg.object_space[i]->index == NULL)
			panic("(object_space = %" PRIu32 ") at least one index must be defined", i);

		for (int j = 0; j < nelem(object_space_registry[i].index); j++) {

			if (cfg.object_space[i]->index[j] == NULL)
				break;

                        typeof(cfg.object_space[i]->index[j]) index_cfg = cfg.object_space[i]->index[j];
			Index *index = [Index new_with_n:j cfg:index_cfg];
			object_space_registry[i].index[j] = (Index<BasicIndex> *)index;

			if (index == nil)
				panic("object_space = %" PRIu32 " index = %" PRIu32 ") "
				      "unknown index type `%s'", i, j, index_cfg->type);

			if ([index respondsTo:@selector(resize)])
				[(id)index resize:cfg.object_space[i]->estimated_rows];
		}

		Index *pk = object_space_registry[i].index[0];

		if (pk->unique == false)
			panic("(object_space = %" PRIu32 ") object_space PK index must be unique", i);

		if ([pk cardinality] != 1)
			panic("(object_space = %" PRIu32 ") object_space PK index must be 1 cardinality", i);

		object_space_registry[i].enabled = true;

		say_info("object space %i successfully configured", i);
		say_info("  PK %i:%s", pk->n, [pk class]->name);
	}
}

static void
title(const char *fmt, ...)
{
	va_list ap;
	char buf[64];

	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);

	if (cfg.memcached)
		set_proc_title("memcached:%s%s pri:%i adm:%i",
			       buf, custom_proc_title, cfg.primary_port, cfg.admin_port);
	else
		set_proc_title("box:%s%s pri:%i sec:%i adm:%i",
			       buf, custom_proc_title,
			       cfg.primary_port, cfg.secondary_port, cfg.admin_port);
}

static void
build_object_space_trees(struct object_space *object_space)
{
	Index<BasicIndex> *pk = object_space->index[0];
	size_t n_tuples = [pk size];
        size_t estimated_tuples = n_tuples * 1.2;

	Tree *ts[MAX_IDX] = { nil, };
	void *nodes[MAX_IDX] = { NULL, };
	int i = 0, tree_count = 0;

	for (int j = 0; object_space->index[j]; j++)
		if ([object_space->index[j] isKindOf:[DummyIndex class]]) {
			DummyIndex *dummy = (id)object_space->index[j];
			if ([dummy is_wrapper_of:[Tree class]]) {
				object_space->index[j] = [dummy unwrap];
				ts[i++] = (id)object_space->index[j];
			}
		}
	tree_count = i;
	if (tree_count == 0)
		return;

	say_info("Building tree indexes of object space %i", object_space->n);

        if (n_tuples > 0) {
		for (int i = 0; i < tree_count; i++) {
                        nodes[i] = malloc(estimated_tuples * ts[i]->node_size);
			if (nodes[i] == NULL)
                                panic("can't allocate node array");
                }

		struct tnt_object *obj;
		u32 t = 0;
		[pk iterator_init];
		while ((obj = [pk iterator_next])) {
			for (int i = 0; i < tree_count; i++) {
                                struct index_node *node = nodes[i] + t * ts[i]->node_size;
                                ts[i]->dtor(obj, node, ts[i]->dtor_arg);
                        }
                        t++;
		}
	}

	for (int i = 0; i < tree_count; i++) {
		say_info("  %i:%s", ts[i]->n, [ts[i] class]->name);
		[ts[i] set_nodes:nodes[i]
			   count:n_tuples
		       allocated:estimated_tuples];
	}
}

static void
build_secondary_indexes()
{
	title("building_indexes");
	@try {
		for (u32 n = 0; n < object_space_count; n++) {
			if (object_space_registry[n].enabled)
				build_object_space_trees(&object_space_registry[n]);
		}
	}
	@catch (Error *e) {
		raise("unable to built tree indexes: %s", e->reason);
	}

	for (u32 n = 0; n < object_space_count; n++) {
		if (!object_space_registry[n].enabled)
			continue;

		struct tbuf *i = tbuf_alloc(fiber->pool);
		foreach_index(index, &object_space_registry[n])
			tbuf_printf(i, " %i:%s", index->n, [index class]->name);

		say_info("Object space %i indexes:%.*s", n, tbuf_len(i), (char *)i->data);
	}
}

void
box_bound_to_primary(int fd)
{
	if (fd < 0) {
		if (!cfg.local_hot_standby)
			panic("unable bind server socket");
		return;
	}

	if (cfg.local_hot_standby) {
		@try {
			[recovery enable_local_writes];
			title("%s", [recovery status]);
		}
		@catch (Error *e) {
			panic("Recovery failure: %s", e->reason);
		}
	}
}

static void
initialize_service()
{
	if (cfg.memcached != 0) {
		memcached_init();
	} else {
		box_primary = iproto_service(cfg.primary_port, box_bound_to_primary);
		for (int i = 0; i < cfg.wal_writer_inbox_size - 2; i++)
			fiber_create("box_worker", iproto_interact, box_primary, box_process);

		if (cfg.secondary_port > 0) {
			box_secondary = iproto_service(cfg.secondary_port, NULL);
			fiber_create("box_secondary_worker", iproto_interact, box_secondary, box_process);
		}

		say_info("(silver)box initialized (%i workers)", cfg.wal_writer_inbox_size);
	}
}

@interface BoxRecovery: Recovery
@end

static void
snap_apply(struct box_txn *txn, struct tbuf *t)
{
	struct box_snap_row *row;

	row = box_snap_row(t);
	txn->object_space = &object_space_registry[row->object_space];

	if (!txn->object_space->enabled)
		raise("object_space %i is not configured", txn->object_space->n);

	txn->index = txn->object_space->index[0];
	assert(txn->index != nil);

	struct tbuf b = { .size = row->data_size,
			  .len = row->data_size,
			  .data = row->data,
			  .pool = NULL };

	prepare_replace(txn, row->tuple_size, &b);
	txn->op = INSERT;
}

static void
wal_apply(struct box_txn *txn, struct tbuf *t)
{
	txn->op = read_u16(t);
	box_prepare_update(txn, t);
}

static void
recover_row(struct tbuf *row)
{
	u16 tag = row_v12(row)->tag;

	struct box_txn txn;
	memset(&txn, 0, sizeof(txn));

	/* drop header */
	tbuf_peek(row, sizeof(struct row_v12));

	switch (tag) {
	case wal_tag:
		wal_apply(&txn, row);
		txn_commit(&txn);
		txn_cleanup(&txn);
		break;
	case snap_tag:
		snap_apply(&txn, row);
		txn_commit(&txn);
		txn_cleanup(&txn);
		break;
	case snap_initial_tag:
		break;
	case snap_final_tag:
		break;
	case wal_final_tag:
		if (box_primary == NULL) {
			build_secondary_indexes();
			initialize_service();
			title("%s", [recovery status]);
		}
		break;
	default:
		raise("unknown row tag :%u", tag);
	}
}


static void
init(void)
{
	stat_base = stat_register(messages_strs, messages_MAX);

	object_space_registry = calloc(object_space_count, sizeof(struct object_space));
	for (int i = 0; i < object_space_count; i++)
		object_space_registry[i].n = i;

	if (cfg.memcached != 0) {
		if (cfg.secondary_port != 0)
			panic("in memcached mode secondary_port must be 0");
		if (cfg.wal_feeder_addr)
			panic("remote replication is not supported in memcached mode.");
	}

	title("loading");
	recovery = [[Recovery alloc] init_snap_dir:cfg.snap_dir
					   wal_dir:cfg.wal_dir
				       recover_row:recover_row
				      rows_per_wal:cfg.rows_per_wal
				       feeder_addr:cfg.wal_feeder_addr
				       fsync_delay:cfg.wal_fsync_delay
					     flags:init_storage ? RECOVER_READONLY : 0
				snap_io_rate_limit:cfg.snap_io_rate_limit * 1024 * 1024];

	/* initialize hashes _after_ starting wal writer */

	if (cfg.memcached != 0) {
		int n = cfg.memcached_object_space > 0 ? cfg.memcached_object_space : MEMCACHED_OBJECT_SPACE;

		cfg.object_space = calloc(n + 2, sizeof(cfg.object_space[0]));
		for (u32 i = 0; i <= n; ++i) {
			cfg.object_space[i] = calloc(1, sizeof(cfg.object_space[0][0]));
			cfg.object_space[i]->enabled = false;
		}

		cfg.object_space[n]->enabled = true;
		cfg.object_space[n]->cardinality = 4;
		cfg.object_space[n]->estimated_rows = 0;
		cfg.object_space[n]->index = calloc(2, sizeof(cfg.object_space[n]->index[0]));
		cfg.object_space[n]->index[0] = calloc(1, sizeof(cfg.object_space[n]->index[0][0]));
		cfg.object_space[n]->index[1] = NULL;
		cfg.object_space[n]->index[0]->type = "HASH";
		cfg.object_space[n]->index[0]->unique = 1;
		cfg.object_space[n]->index[0]->key_field =
			calloc(2, sizeof(cfg.object_space[n]->index[0]->key_field[0]));
		cfg.object_space[n]->index[0]->key_field[0] =
			calloc(1, sizeof(cfg.object_space[n]->index[0]->key_field[0][0]));
		cfg.object_space[n]->index[0]->key_field[1] = NULL;
		cfg.object_space[n]->index[0]->key_field[0]->fieldno = 0;
		cfg.object_space[n]->index[0]->key_field[0]->type = "STR";

		memcached_index = (StringHash *)object_space_registry[n].index[0];
	}

	configure();

	if (init_storage)
		return;

	luaT_openbox(root_L);

	int local_lsn = [recovery recover_local:0];

	if (local_lsn == 0) {
		if (!cfg.wal_feeder_addr) {
			say_crit("don't you forget to initialize "
				 "storage with --init-storage switch?");
			exit(EX_USAGE);
		}
	}

	if (!cfg.local_hot_standby)
		[recovery enable_local_writes];
}

static int
cat(const char *filename)
{
	return read_log(filename, xlog_print, snap_print, NULL);
}

static void
snapshot_rows(XLog *l)
{
	struct box_snap_row header;
	struct tnt_object *obj;
	struct box_tuple *tuple;
	struct tbuf *row;

	for (uint32_t n = 0; n < object_space_count; ++n) {
		if (!object_space_registry[n].enabled)
			continue;

		id pk = object_space_registry[n].index[0];
		[pk iterator_init];
		while ((obj = [pk iterator_next])) {
			tuple = box_tuple(obj);

			header.object_space = n;
			header.tuple_size = tuple->cardinality;
			header.data_size = tuple->bsize;

			/* snapshot_write_row will release fiber->pool time to time */
			row = tbuf_alloc(fiber->pool);
			tbuf_append(row, &header, sizeof(header));
			tbuf_append(row, tuple->data, tuple->bsize);

			snapshot_write_row(l, snap_tag, row);
		}
	}
}

static void
snapshot(bool initial)
{
	if (initial)
		[recovery initial_lsn:1];
	[recovery snapshot_save:snapshot_rows];
}

static void
info(struct tbuf *out)
{
	tbuf_printf(out, "info:" CRLF);
	tbuf_printf(out, "  version: \"%s\"" CRLF, tarantool_version());
	tbuf_printf(out, "  uptime: %i" CRLF, tnt_uptime());
	tbuf_printf(out, "  pid: %i" CRLF, getpid());
	tbuf_printf(out, "  wal_writer_pid: %" PRIi64 CRLF,
		    (i64) [recovery wal_writer]->pid);
	tbuf_printf(out, "  lsn: %" PRIi64 CRLF, [recovery lsn]);
	tbuf_printf(out, "  recovery_lag: %.3f" CRLF, [recovery lag]);
	tbuf_printf(out, "  recovery_last_update: %.3f" CRLF,
		    [recovery last_update_tstamp]);
	tbuf_printf(out, "  status: %s%s" CRLF, [recovery status], custom_proc_title);

	tbuf_printf(out, "  namespaces:" CRLF);
	for (uint32_t n = 0; n < object_space_count; ++n) {
		if (!object_space_registry[n].enabled)
			continue;
		tbuf_printf(out, "  - n: %i"CRLF, n);
		tbuf_printf(out, "    objects: %i"CRLF, [object_space_registry[n].index[0] size]);
		tbuf_printf(out, "    indexes:"CRLF);
		foreach_index(index, &object_space_registry[n])
			tbuf_printf(out, "    - { index: %i, slots: %i, bytes: %zi }" CRLF,
				    index->n, [index slots], [index bytes]);
	}

	if (box_primary != NULL)
		service_info(out, box_primary);
	if (box_secondary != NULL)
		service_info(out, box_secondary);
}


struct tnt_module box = {
        .name = "box",
        .init = init,
        .check_config = NULL,
        .reload_config = NULL,
        .cat = cat,
        .snapshot = snapshot,
        .info = info,
        .exec = NULL
};

register_module(box);
