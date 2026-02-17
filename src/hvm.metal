#include <metal_stdlib>
using namespace metal;

typedef uchar u8;
typedef uint u32;
typedef int i32;
typedef float f32;
typedef ulong u64;

typedef u32 Tag;
typedef u32 Val;
typedef u32 Port;
typedef u64 Pair;
typedef u32 Rule;
typedef u32 Numb;

constant Tag VAR = 0x0;
constant Tag REF = 0x1;
constant Tag ERA = 0x2;
constant Tag NUM = 0x3;
constant Tag CON = 0x4;
constant Tag DUP = 0x5;
constant Tag OPR = 0x6;
constant Tag SWI = 0x7;

constant Rule LINK = 0x0;
constant Rule CALL = 0x1;
constant Rule VOID = 0x2;
constant Rule ERAS = 0x3;
constant Rule ANNI = 0x4;
constant Rule COMM = 0x5;
constant Rule OPER = 0x6;
constant Rule SWIT = 0x7;

constant Port ROOT = 0xFFFFFFF8u;
constant u32 ROOT_VAR_ID = 0x1FFFFFFFu;
constant Port NONE = 0xFFFFFFFFu;

constant Tag TY_SYM = 0x00;
constant Tag TY_U24 = 0x01;
constant Tag TY_I24 = 0x02;
constant Tag TY_F24 = 0x03;
constant Tag OP_ADD = 0x04;
constant Tag OP_SUB = 0x05;
constant Tag FP_SUB = 0x06;
constant Tag OP_MUL = 0x07;
constant Tag OP_DIV = 0x08;
constant Tag FP_DIV = 0x09;
constant Tag OP_REM = 0x0A;
constant Tag FP_REM = 0x0B;
constant Tag OP_EQ  = 0x0C;
constant Tag OP_NEQ = 0x0D;
constant Tag OP_LT  = 0x0E;
constant Tag OP_GT  = 0x0F;
constant Tag OP_AND = 0x10;
constant Tag OP_OR  = 0x11;
constant Tag OP_XOR = 0x12;
constant Tag OP_SHL = 0x13;
constant Tag FP_SHL = 0x14;
constant Tag OP_SHR = 0x15;
constant Tag FP_SHR = 0x16;

constant f32 U24_MAX = 16777215.0f;
constant f32 U24_MIN = 0.0f;
constant f32 I24_MAX = 8388607.0f;
constant f32 I24_MIN = -8388608.0f;

constant u32 MAX_TM_ALLOCS = 0x0FFFu;

constant u32 ERR_NONE = 0u;
constant u32 ERR_NODE_OOM = 1u;
constant u32 ERR_VARS_OOM = 2u;
constant u32 ERR_RBAG_OOM = 3u;
constant u32 ERR_BAD_FID = 4u;
constant u32 ERR_STEP_LIMIT = 5u;
constant u32 ERR_BAD_BOOK = 6u;
constant u32 ERR_NODE_OOB = 7u;
constant u32 ERR_VARS_OOB = 8u;
constant u32 ERR_TM_OOM = 9u;

struct DefMeta {
  u32 safe;
  u32 rbag_len;
  u32 node_len;
  u32 vars_len;
  u32 root;
  u32 rbag_off;
  u32 node_off;
};

struct RuntimeState {
  u32 defs_len;
  u32 node_cap;
  u32 vars_cap;
  u32 rbag_cap;
  u32 max_steps;
  u32 error;
  u32 root_var;
  u32 node_head;
  u32 vars_head;
  u32 rbag_len;
  u32 steps;
  u64 itrs;
};

inline Port new_port(Tag tag, Val val) {
  return (val << 3) | tag;
}

inline Tag get_tag(Port port) {
  return port & 7u;
}

inline Val get_val(Port port) {
  return port >> 3;
}

inline Pair new_pair(Port fst, Port snd) {
  return (u64(snd) << 32) | u64(fst);
}

inline Port get_fst(Pair pair) {
  return u32(pair & 0xFFFFFFFFul);
}

inline Port get_snd(Pair pair) {
  return u32(pair >> 32);
}

inline bool is_nod(Port a) {
  return get_tag(a) >= CON;
}

inline bool is_var(Port a) {
  return get_tag(a) == VAR;
}

constant u8 RULE_TABLE[64] = {
  LINK, LINK, LINK, LINK, LINK, LINK, LINK, LINK,
  LINK, VOID, VOID, VOID, CALL, CALL, CALL, CALL,
  LINK, VOID, VOID, VOID, ERAS, ERAS, ERAS, ERAS,
  LINK, VOID, VOID, VOID, ERAS, ERAS, OPER, SWIT,
  LINK, CALL, ERAS, ERAS, ANNI, COMM, COMM, COMM,
  LINK, CALL, ERAS, ERAS, COMM, ANNI, COMM, COMM,
  LINK, CALL, ERAS, OPER, COMM, COMM, ANNI, COMM,
  LINK, CALL, ERAS, SWIT, COMM, COMM, COMM, ANNI,
};

inline Rule get_rule(Port a, Port b) {
  return RULE_TABLE[(get_tag(a) << 3) | get_tag(b)];
}

inline bool should_swap(Port a, Port b) {
  return get_tag(b) < get_tag(a);
}

inline f32 clamp_f32(f32 x, f32 minv, f32 maxv) {
  f32 y = x < minv ? minv : x;
  return y > maxv ? maxv : y;
}

inline Numb new_sym(u32 val) {
  return (val << 5) | TY_SYM;
}

inline u32 get_sym(Numb word) {
  return word >> 5;
}

inline Numb new_u24(u32 val) {
  return (val << 5) | TY_U24;
}

inline u32 get_u24(Numb word) {
  return word >> 5;
}

inline Numb new_i24(i32 val) {
  return (u32(val) << 5) | TY_I24;
}

inline i32 get_i24(Numb word) {
  return (i32(word) << 3) >> 8;
}

inline Numb new_f24(f32 val) {
  u32 bits = as_type<u32>(val);
  u32 shifted = bits >> 8;
  u32 lost = bits & 0xFFu;
  u32 tie = (lost >> 7) & (shifted == 0u ? 1u : 0u);
  shifted += (isnan(val) ? 0u : 1u) & ((lost - tie) >> 7);
  shifted |= isnan(val) ? 1u : 0u;
  return (shifted << 5) | TY_F24;
}

inline f32 get_f24(Numb word) {
  u32 bits = (word << 3) & 0xFFFFFF00u;
  return as_type<f32>(bits);
}

inline Tag get_typ(Numb word) {
  return word & 0x1Fu;
}

inline bool is_num(Numb word) {
  Tag typ = get_typ(word);
  return typ >= TY_U24 && typ <= TY_F24;
}

inline bool is_cast(Numb word) {
  return get_typ(word) == TY_SYM && get_sym(word) >= TY_U24 && get_sym(word) <= TY_F24;
}

inline Numb partial(Numb a, Numb b) {
  return (b & ~0x1Fu) | get_sym(a);
}

inline Numb cast(Numb a, Numb b) {
  if (get_sym(a) == TY_U24 && get_typ(b) == TY_U24) return b;
  if (get_sym(a) == TY_U24 && get_typ(b) == TY_I24) {
    i32 val = get_i24(b);
    return new_u24(as_type<u32>(val));
  }
  if (get_sym(a) == TY_U24 && get_typ(b) == TY_F24) {
    f32 val = get_f24(b);
    if (isnan(val)) {
      return new_u24(0);
    }
    return new_u24(u32(clamp_f32(val, U24_MIN, U24_MAX)));
  }

  if (get_sym(a) == TY_I24 && get_typ(b) == TY_U24) {
    u32 val = get_u24(b);
    return new_i24(as_type<i32>(val));
  }
  if (get_sym(a) == TY_I24 && get_typ(b) == TY_I24) return b;
  if (get_sym(a) == TY_I24 && get_typ(b) == TY_F24) {
    f32 val = get_f24(b);
    if (isnan(val)) {
      return new_i24(0);
    }
    return new_i24(i32(clamp_f32(val, I24_MIN, I24_MAX)));
  }

  if (get_sym(a) == TY_F24 && get_typ(b) == TY_U24) return new_f24(f32(get_u24(b)));
  if (get_sym(a) == TY_F24 && get_typ(b) == TY_I24) return new_f24(f32(get_i24(b)));
  if (get_sym(a) == TY_F24 && get_typ(b) == TY_F24) return b;

  return new_u24(0);
}

inline Numb operate(Numb a, Numb b) {
  Tag at = get_typ(a);
  Tag bt = get_typ(b);
  if (at == TY_SYM && bt == TY_SYM) {
    return new_u24(0);
  }
  if (is_cast(a) && is_num(b)) {
    return cast(a, b);
  }
  if (is_cast(b) && is_num(a)) {
    return cast(b, a);
  }
  if (at == TY_SYM && bt != TY_SYM) {
    return partial(a, b);
  }
  if (at != TY_SYM && bt == TY_SYM) {
    return partial(b, a);
  }
  if (at >= OP_ADD && bt >= OP_ADD) {
    return new_u24(0);
  }
  if (at < OP_ADD && bt < OP_ADD) {
    return new_u24(0);
  }

  Tag op;
  Tag ty;
  if (at >= OP_ADD) {
    op = at;
    ty = bt;
  } else {
    op = bt;
    ty = at;
    Numb swp = a;
    a = b;
    b = swp;
  }

  switch (ty) {
    case TY_U24: {
      u32 av = get_u24(a);
      u32 bv = get_u24(b);
      switch (op) {
        case OP_ADD: return new_u24(av + bv);
        case OP_SUB: return new_u24(av - bv);
        case FP_SUB: return new_u24(bv - av);
        case OP_MUL: return new_u24(av * bv);
        case OP_DIV: return new_u24(av / bv);
        case FP_DIV: return new_u24(bv / av);
        case OP_REM: return new_u24(av % bv);
        case FP_REM: return new_u24(bv % av);
        case OP_EQ:  return new_u24(av == bv);
        case OP_NEQ: return new_u24(av != bv);
        case OP_LT:  return new_u24(av < bv);
        case OP_GT:  return new_u24(av > bv);
        case OP_AND: return new_u24(av & bv);
        case OP_OR:  return new_u24(av | bv);
        case OP_XOR: return new_u24(av ^ bv);
        case OP_SHL: return new_u24(av << (bv & 31u));
        case FP_SHL: return new_u24(bv << (av & 31u));
        case OP_SHR: return new_u24(av >> (bv & 31u));
        case FP_SHR: return new_u24(bv >> (av & 31u));
        default:     return new_u24(0);
      }
    }
    case TY_I24: {
      i32 av = get_i24(a);
      i32 bv = get_i24(b);
      switch (op) {
        case OP_ADD: return new_i24(av + bv);
        case OP_SUB: return new_i24(av - bv);
        case FP_SUB: return new_i24(bv - av);
        case OP_MUL: return new_i24(av * bv);
        case OP_DIV: return new_i24(av / bv);
        case FP_DIV: return new_i24(bv / av);
        case OP_REM: return new_i24(av % bv);
        case FP_REM: return new_i24(bv % av);
        case OP_EQ:  return new_u24(av == bv);
        case OP_NEQ: return new_u24(av != bv);
        case OP_LT:  return new_u24(av < bv);
        case OP_GT:  return new_u24(av > bv);
        case OP_AND: return new_i24(av & bv);
        case OP_OR:  return new_i24(av | bv);
        case OP_XOR: return new_i24(av ^ bv);
        default:     return new_i24(0);
      }
    }
    case TY_F24: {
      f32 av = get_f24(a);
      f32 bv = get_f24(b);
      switch (op) {
        case OP_ADD: return new_f24(av + bv);
        case OP_SUB: return new_f24(av - bv);
        case FP_SUB: return new_f24(bv - av);
        case OP_MUL: return new_f24(av * bv);
        case OP_DIV: return new_f24(av / bv);
        case FP_DIV: return new_f24(bv / av);
        case OP_REM: return new_f24(fmod(av, bv));
        case FP_REM: return new_f24(fmod(bv, av));
        case OP_EQ:  return new_u24(av == bv);
        case OP_NEQ: return new_u24(av != bv);
        case OP_LT:  return new_u24(av < bv);
        case OP_GT:  return new_u24(av > bv);
        case OP_AND: return new_f24(atan2(av, bv));
        case OP_OR:  return new_f24(log(bv) / log(av));
        case OP_XOR: return new_f24(pow(av, bv));
        case OP_SHL: return new_f24(sin(av + bv));
        case OP_SHR: return new_f24(tan(av + bv));
        default:     return new_f24(0.0f);
      }
    }
    default: return new_u24(0);
  }
}

inline Pair node_load(device RuntimeState* st, device Pair* node_buf, u32 loc) {
  if (loc >= st->node_cap) {
    st->error = ERR_NODE_OOB;
    return 0;
  }
  return node_buf[loc];
}

inline void node_store(device RuntimeState* st, device Pair* node_buf, u32 loc, Pair val) {
  if (loc >= st->node_cap) {
    st->error = ERR_NODE_OOB;
    return;
  }
  node_buf[loc] = val;
}

inline Pair node_take(device RuntimeState* st, device Pair* node_buf, u32 loc) {
  if (loc >= st->node_cap) {
    st->error = ERR_NODE_OOB;
    return 0;
  }
  Pair old = node_buf[loc];
  node_buf[loc] = 0;
  return old;
}

inline Port vars_load(device RuntimeState* st, device Port* vars_buf, u32 var) {
  if (var == ROOT_VAR_ID) {
    return st->root_var;
  }
  if (var >= st->vars_cap) {
    st->error = ERR_VARS_OOB;
    return NONE;
  }
  return vars_buf[var];
}

inline void vars_store(device RuntimeState* st, device Port* vars_buf, u32 var, Port val) {
  if (var == ROOT_VAR_ID) {
    st->root_var = val;
    return;
  }
  if (var >= st->vars_cap) {
    st->error = ERR_VARS_OOB;
    return;
  }
  vars_buf[var] = val;
}

inline Port vars_exchange(device RuntimeState* st, device Port* vars_buf, u32 var, Port val) {
  if (var == ROOT_VAR_ID) {
    Port old = st->root_var;
    st->root_var = val;
    return old;
  }
  if (var >= st->vars_cap) {
    st->error = ERR_VARS_OOB;
    return NONE;
  }
  Port old = vars_buf[var];
  vars_buf[var] = val;
  return old;
}

inline void vars_take(device RuntimeState* st, device Port* vars_buf, u32 var) {
  if (var == ROOT_VAR_ID) {
    st->root_var = 0;
    return;
  }
  if (var >= st->vars_cap) {
    st->error = ERR_VARS_OOB;
    return;
  }
  vars_buf[var] = 0;
}

inline bool push_redex(device RuntimeState* st, device Pair* rbag_buf, Pair redex) {
  if (st->rbag_len >= st->rbag_cap) {
    st->error = ERR_RBAG_OOM;
    return false;
  }
  rbag_buf[st->rbag_len++] = redex;
  return true;
}

inline Pair pop_redex(device RuntimeState* st, device Pair* rbag_buf) {
  if (st->rbag_len == 0) {
    return 0;
  }
  return rbag_buf[--st->rbag_len];
}

inline bool alloc_nodes(device RuntimeState* st, device Pair* node_buf, u32 need, thread u32* out) {
  if (need > MAX_TM_ALLOCS) {
    st->error = ERR_TM_OOM;
    return false;
  }
  u32 got = 0;
  for (u32 tries = 0; tries < st->node_cap && got < need; ++tries) {
    u32 idx = st->node_head;
    st->node_head = (st->node_head + 1u) % st->node_cap;
    if (idx == 0u) {
      continue;
    }
    if (node_buf[idx] == 0ul) {
      out[got++] = idx;
    }
  }
  if (got < need) {
    st->error = ERR_NODE_OOM;
    return false;
  }
  return true;
}

inline bool alloc_vars(device RuntimeState* st, device Port* vars_buf, u32 need, thread u32* out) {
  if (need > MAX_TM_ALLOCS) {
    st->error = ERR_TM_OOM;
    return false;
  }
  u32 got = 0;
  for (u32 tries = 0; tries < st->vars_cap && got < need; ++tries) {
    u32 idx = st->vars_head;
    st->vars_head = (st->vars_head + 1u) % st->vars_cap;
    if (idx == 0u) {
      continue;
    }
    if (vars_buf[idx] == 0u) {
      out[got++] = idx;
    }
  }
  if (got < need) {
    st->error = ERR_VARS_OOM;
    return false;
  }
  return true;
}

inline bool get_resources(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  u32 need_rbag,
  u32 need_node,
  u32 need_vars,
  thread u32* nloc,
  thread u32* vloc
) {
  if (st->error != ERR_NONE) {
    return false;
  }
  if (st->rbag_len + need_rbag > st->rbag_cap) {
    st->error = ERR_RBAG_OOM;
    return false;
  }
  if (!alloc_nodes(st, node_buf, need_node, nloc)) {
    return false;
  }
  if (!alloc_vars(st, vars_buf, need_vars, vloc)) {
    return false;
  }
  return true;
}

inline Port peek(device RuntimeState* st, device Port* vars_buf, Port var) {
  while (get_tag(var) == VAR) {
    Port val = vars_load(st, vars_buf, get_val(var));
    if (st->error != ERR_NONE) {
      return var;
    }
    if (val == NONE || val == 0u) {
      break;
    }
    var = val;
  }
  return var;
}

inline Port enter(device RuntimeState* st, device Port* vars_buf, Port var) {
  while (get_tag(var) == VAR) {
    u32 loc = get_val(var);
    Port val = vars_exchange(st, vars_buf, loc, NONE);
    if (st->error != ERR_NONE) {
      return var;
    }
    if (val == NONE || val == 0u) {
      break;
    }
    vars_take(st, vars_buf, loc);
    if (st->error != ERR_NONE) {
      return var;
    }
    var = val;
  }
  return var;
}

inline bool link(
  device RuntimeState* st,
  device Port* vars_buf,
  device Pair* rbag_buf,
  Port A,
  Port B
) {
  while (true) {
    if (get_tag(A) != VAR && get_tag(B) == VAR) {
      Port X = A;
      A = B;
      B = X;
    }

    if (get_tag(A) != VAR) {
      return push_redex(st, rbag_buf, new_pair(A, B));
    }

    B = enter(st, vars_buf, B);
    if (st->error != ERR_NONE) {
      return false;
    }

    u32 loc = get_val(A);
    Port A_ = vars_exchange(st, vars_buf, loc, B);
    if (st->error != ERR_NONE) {
      return false;
    }
    if (A_ == NONE) {
      return true;
    }

    vars_take(st, vars_buf, loc);
    if (st->error != ERR_NONE) {
      return false;
    }
    A = A_;
  }
}

inline bool link_pair(
  device RuntimeState* st,
  device Port* vars_buf,
  device Pair* rbag_buf,
  Pair AB
) {
  return link(st, vars_buf, rbag_buf, get_fst(AB), get_snd(AB));
}

inline Port adjust_port(
  device RuntimeState* st,
  Port port,
  thread const u32* nloc,
  thread const u32* vloc,
  u32 node_len,
  u32 vars_len
) {
  Tag tag = get_tag(port);
  Val val = get_val(port);
  if (tag >= CON) {
    if (val >= node_len) {
      st->error = ERR_BAD_BOOK;
      return port;
    }
    return new_port(tag, nloc[val]);
  }
  if (tag == VAR) {
    if (val >= vars_len) {
      st->error = ERR_BAD_BOOK;
      return port;
    }
    return new_port(tag, vloc[val]);
  }
  return new_port(tag, val);
}

inline Pair adjust_pair(
  device RuntimeState* st,
  Pair pair,
  thread const u32* nloc,
  thread const u32* vloc,
  u32 node_len,
  u32 vars_len
) {
  Port p1 = adjust_port(st, get_fst(pair), nloc, vloc, node_len, vars_len);
  Port p2 = adjust_port(st, get_snd(pair), nloc, vloc, node_len, vars_len);
  return new_pair(p1, p2);
}

inline bool interact_eras(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
);

inline bool interact_link(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
) {
  if (!get_resources(st, node_buf, vars_buf, 1, 0, 0, nloc, vloc)) {
    return false;
  }
  return link_pair(st, vars_buf, rbag_buf, new_pair(a, b));
}

inline bool interact_call(
  device RuntimeState* st,
  device const DefMeta* defs,
  device const Pair* def_rbag,
  device const Pair* def_nodes,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
) {
  u32 fid = get_val(a) & 0x0FFFFFFFu;
  if (fid >= st->defs_len) {
    st->error = ERR_BAD_FID;
    return false;
  }

  DefMeta def = defs[fid];

  if (def.safe && get_tag(b) == DUP) {
    return interact_eras(st, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b);
  }

  if (!get_resources(st, node_buf, vars_buf, def.rbag_len + 1u, def.node_len, def.vars_len, nloc, vloc)) {
    return false;
  }

  for (u32 i = 0; i < def.vars_len; ++i) {
    vars_store(st, vars_buf, vloc[i], NONE);
    if (st->error != ERR_NONE) {
      return false;
    }
  }

  for (u32 i = 0; i < def.node_len; ++i) {
    Pair pair = adjust_pair(st, def_nodes[def.node_off + i], nloc, vloc, def.node_len, def.vars_len);
    if (st->error != ERR_NONE) {
      return false;
    }
    node_store(st, node_buf, nloc[i], pair);
    if (st->error != ERR_NONE) {
      return false;
    }
  }

  for (u32 i = 0; i < def.rbag_len; ++i) {
    Pair pair = adjust_pair(st, def_rbag[def.rbag_off + i], nloc, vloc, def.node_len, def.vars_len);
    if (st->error != ERR_NONE) {
      return false;
    }
    if (!link_pair(st, vars_buf, rbag_buf, pair)) {
      return false;
    }
  }

  Port root = adjust_port(st, def.root, nloc, vloc, def.node_len, def.vars_len);
  if (st->error != ERR_NONE) {
    return false;
  }
  return link_pair(st, vars_buf, rbag_buf, new_pair(root, b));
}

inline bool interact_void(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
) {
  (void)st;
  (void)node_buf;
  (void)vars_buf;
  (void)rbag_buf;
  (void)nloc;
  (void)vloc;
  (void)a;
  (void)b;
  return true;
}

inline bool interact_eras(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
) {
  if (!get_resources(st, node_buf, vars_buf, 2, 0, 0, nloc, vloc)) {
    return false;
  }

  Pair loaded = node_load(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }
  if (loaded == 0) {
    return false;
  }

  Pair B = node_take(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }
  Port B1 = get_fst(B);
  Port B2 = get_snd(B);

  if (!link_pair(st, vars_buf, rbag_buf, new_pair(a, B1))) {
    return false;
  }
  if (!link_pair(st, vars_buf, rbag_buf, new_pair(a, B2))) {
    return false;
  }

  return true;
}

inline bool interact_anni(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
) {
  if (!get_resources(st, node_buf, vars_buf, 2, 0, 0, nloc, vloc)) {
    return false;
  }

  Pair loadedA = node_load(st, node_buf, get_val(a));
  Pair loadedB = node_load(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }
  if (loadedA == 0 || loadedB == 0) {
    return false;
  }

  Pair A = node_take(st, node_buf, get_val(a));
  Pair B = node_take(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }

  if (!link_pair(st, vars_buf, rbag_buf, new_pair(get_fst(A), get_fst(B)))) {
    return false;
  }
  if (!link_pair(st, vars_buf, rbag_buf, new_pair(get_snd(A), get_snd(B)))) {
    return false;
  }

  return true;
}

inline bool interact_comm(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
) {
  if (!get_resources(st, node_buf, vars_buf, 4, 4, 4, nloc, vloc)) {
    return false;
  }

  Pair loadedA = node_load(st, node_buf, get_val(a));
  Pair loadedB = node_load(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }
  if (loadedA == 0 || loadedB == 0) {
    return false;
  }

  Pair A = node_take(st, node_buf, get_val(a));
  Pair B = node_take(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }

  vars_store(st, vars_buf, vloc[0], NONE);
  vars_store(st, vars_buf, vloc[1], NONE);
  vars_store(st, vars_buf, vloc[2], NONE);
  vars_store(st, vars_buf, vloc[3], NONE);
  if (st->error != ERR_NONE) {
    return false;
  }

  node_store(st, node_buf, nloc[0], new_pair(new_port(VAR, vloc[0]), new_port(VAR, vloc[1])));
  node_store(st, node_buf, nloc[1], new_pair(new_port(VAR, vloc[2]), new_port(VAR, vloc[3])));
  node_store(st, node_buf, nloc[2], new_pair(new_port(VAR, vloc[0]), new_port(VAR, vloc[2])));
  node_store(st, node_buf, nloc[3], new_pair(new_port(VAR, vloc[1]), new_port(VAR, vloc[3])));
  if (st->error != ERR_NONE) {
    return false;
  }

  if (!link_pair(st, vars_buf, rbag_buf, new_pair(new_port(get_tag(b), nloc[0]), get_fst(A)))) {
    return false;
  }
  if (!link_pair(st, vars_buf, rbag_buf, new_pair(new_port(get_tag(b), nloc[1]), get_snd(A)))) {
    return false;
  }
  if (!link_pair(st, vars_buf, rbag_buf, new_pair(new_port(get_tag(a), nloc[2]), get_fst(B)))) {
    return false;
  }
  if (!link_pair(st, vars_buf, rbag_buf, new_pair(new_port(get_tag(a), nloc[3]), get_snd(B)))) {
    return false;
  }

  return true;
}

inline bool interact_oper(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
) {
  if (!get_resources(st, node_buf, vars_buf, 1, 1, 0, nloc, vloc)) {
    return false;
  }

  Pair loaded = node_load(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }
  if (loaded == 0) {
    return false;
  }

  Val av = get_val(a);
  Pair B = node_take(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }
  Port B1 = get_fst(B);
  Port B2 = enter(st, vars_buf, get_snd(B));
  if (st->error != ERR_NONE) {
    return false;
  }

  if (get_tag(B1) == NUM) {
    Val bv = get_val(B1);
    Numb cv = operate(av, bv);
    return link_pair(st, vars_buf, rbag_buf, new_pair(new_port(NUM, cv), B2));
  }

  node_store(st, node_buf, nloc[0], new_pair(a, B2));
  if (st->error != ERR_NONE) {
    return false;
  }
  return link_pair(st, vars_buf, rbag_buf, new_pair(B1, new_port(OPR, nloc[0])));
}

inline bool interact_swit(
  device RuntimeState* st,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc,
  Port a,
  Port b
) {
  if (!get_resources(st, node_buf, vars_buf, 1, 2, 0, nloc, vloc)) {
    return false;
  }

  Pair loaded = node_load(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }
  if (loaded == 0) {
    return false;
  }

  u32 av = get_u24(get_val(a));
  Pair B = node_take(st, node_buf, get_val(b));
  if (st->error != ERR_NONE) {
    return false;
  }
  Port B1 = get_fst(B);
  Port B2 = get_snd(B);

  if (av == 0) {
    node_store(st, node_buf, nloc[0], new_pair(B2, new_port(ERA, 0)));
    if (st->error != ERR_NONE) {
      return false;
    }
    return link_pair(st, vars_buf, rbag_buf, new_pair(new_port(CON, nloc[0]), B1));
  }

  node_store(st, node_buf, nloc[0], new_pair(new_port(ERA, 0), new_port(CON, nloc[1])));
  node_store(st, node_buf, nloc[1], new_pair(new_port(NUM, new_u24(av - 1u)), B2));
  if (st->error != ERR_NONE) {
    return false;
  }
  return link_pair(st, vars_buf, rbag_buf, new_pair(new_port(CON, nloc[0]), B1));
}

inline bool interact(
  device RuntimeState* st,
  device const DefMeta* defs,
  device const Pair* def_rbag,
  device const Pair* def_nodes,
  device Pair* node_buf,
  device Port* vars_buf,
  device Pair* rbag_buf,
  thread u32* nloc,
  thread u32* vloc
) {
  Pair redex = pop_redex(st, rbag_buf);

  if (redex == 0) {
    return true;
  }

  Port a = get_fst(redex);
  Port b = get_snd(redex);

  Rule rule = get_rule(a, b);
  if (get_tag(a) == REF && b == ROOT) {
    rule = CALL;
  } else if (should_swap(a, b)) {
    Port t = a;
    a = b;
    b = t;
  }

  bool success = false;
  switch (rule) {
    case LINK: success = interact_link(st, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b); break;
    case CALL: success = interact_call(st, defs, def_rbag, def_nodes, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b); break;
    case VOID: success = interact_void(st, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b); break;
    case ERAS: success = interact_eras(st, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b); break;
    case ANNI: success = interact_anni(st, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b); break;
    case COMM: success = interact_comm(st, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b); break;
    case OPER: success = interact_oper(st, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b); break;
    case SWIT: success = interact_swit(st, node_buf, vars_buf, rbag_buf, nloc, vloc, a, b); break;
    default: success = false; break;
  }

  if (!success) {
    if (st->error != ERR_NONE) {
      return false;
    }
    return push_redex(st, rbag_buf, redex);
  }

  if (rule != LINK) {
    st->itrs += 1;
  }

  return true;
}

kernel void hvm_eval(
  device const DefMeta* defs [[buffer(0)]],
  device const Pair* def_rbag [[buffer(1)]],
  device const Pair* def_nodes [[buffer(2)]],
  device Pair* node_buf [[buffer(3)]],
  device Port* vars_buf [[buffer(4)]],
  device Pair* rbag_buf [[buffer(5)]],
  device RuntimeState* state [[buffer(6)]],
  uint gid [[thread_position_in_grid]]
) {
  if (gid != 0) {
    return;
  }

  state->error = ERR_NONE;
  state->root_var = NONE;
  state->node_head = 1u;
  state->vars_head = 1u;
  state->rbag_len = 0u;
  state->steps = 0u;
  state->itrs = 0ul;

  vars_store(state, vars_buf, ROOT_VAR_ID, NONE);
  if (state->error != ERR_NONE) {
    return;
  }

  if (!push_redex(state, rbag_buf, new_pair(new_port(REF, 0), ROOT))) {
    return;
  }

  thread u32 nloc[MAX_TM_ALLOCS];
  thread u32 vloc[MAX_TM_ALLOCS];

  while (state->rbag_len > 0u && state->error == ERR_NONE) {
    if (state->steps >= state->max_steps) {
      state->error = ERR_STEP_LIMIT;
      break;
    }
    state->steps += 1u;

    bool ok = interact(state, defs, def_rbag, def_nodes, node_buf, vars_buf, rbag_buf, nloc, vloc);
    if (!ok && state->error != ERR_NONE) {
      break;
    }
  }
}
