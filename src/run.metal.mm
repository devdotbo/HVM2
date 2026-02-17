#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <dlfcn.h>
#include <errno.h>
#include <limits>
#include <string>
#include <vector>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#ifndef HVM_GEN_STANDALONE
#include "hvm_metal_lib.h"
#endif

using u8 = uint8_t;
using u32 = uint32_t;
using i32 = int32_t;
using u64 = uint64_t;
using f32 = float;

using Tag = u32;
using Val = u32;
using Port = u32;
using Pair = u64;
using Numb = u32;

static constexpr Tag VAR = 0x0;
static constexpr Tag REF = 0x1;
static constexpr Tag ERA = 0x2;
static constexpr Tag NUM = 0x3;
static constexpr Tag CON = 0x4;
static constexpr Tag DUP = 0x5;
static constexpr Tag OPR = 0x6;
static constexpr Tag SWI = 0x7;

static constexpr Port ROOT = 0xFFFFFFF8u;
static constexpr u32 ROOT_VAR_ID = 0x1FFFFFFFu;
static constexpr Port NONE = 0xFFFFFFFFu;

static constexpr Tag TY_SYM = 0x00;
static constexpr Tag TY_U24 = 0x01;
static constexpr Tag TY_I24 = 0x02;
static constexpr Tag TY_F24 = 0x03;
static constexpr Tag OP_ADD = 0x04;
static constexpr Tag OP_SUB = 0x05;
static constexpr Tag FP_SUB = 0x06;
static constexpr Tag OP_MUL = 0x07;
static constexpr Tag OP_DIV = 0x08;
static constexpr Tag FP_DIV = 0x09;
static constexpr Tag OP_REM = 0x0A;
static constexpr Tag FP_REM = 0x0B;
static constexpr Tag OP_EQ = 0x0C;
static constexpr Tag OP_NEQ = 0x0D;
static constexpr Tag OP_LT = 0x0E;
static constexpr Tag OP_GT = 0x0F;
static constexpr Tag OP_AND = 0x10;
static constexpr Tag OP_OR = 0x11;
static constexpr Tag OP_XOR = 0x12;
static constexpr Tag OP_SHL = 0x13;
static constexpr Tag FP_SHL = 0x14;
static constexpr Tag OP_SHR = 0x15;
static constexpr Tag FP_SHR = 0x16;

static constexpr u32 MAX_TM_ALLOCS = 0x0FFFu;

static constexpr u32 ERR_NONE = 0u;
static constexpr u32 ERR_NODE_OOM = 1u;
static constexpr u32 ERR_VARS_OOM = 2u;
static constexpr u32 ERR_RBAG_OOM = 3u;
static constexpr u32 ERR_BAD_FID = 4u;
static constexpr u32 ERR_STEP_LIMIT = 5u;
static constexpr u32 ERR_BAD_BOOK = 6u;
static constexpr u32 ERR_NODE_OOB = 7u;
static constexpr u32 ERR_VARS_OOB = 8u;
static constexpr u32 ERR_TM_OOM = 9u;

static constexpr u32 IO_MAGIC_0 = 0xD0CA11u;
static constexpr u32 IO_MAGIC_1 = 0xFF1FF1u;

static constexpr u32 IO_DONE = 0u;
static constexpr u32 IO_CALL = 1u;

static constexpr u32 RESULT_OK = 0u;
static constexpr u32 RESULT_ERR = 1u;

static constexpr u32 IO_ERR_TYPE = 0u;
static constexpr u32 IO_ERR_NAME = 1u;
static constexpr u32 IO_ERR_INNER = 2u;

static constexpr u32 LIST_NIL = 0u;
static constexpr u32 LIST_CONS = 1u;

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
  u32 command;
  u32 error;
  u32 root_var;
  u32 node_head;
  u32 vars_head;
  u32 rbag_len;
  u32 steps;
  u64 itrs;
};

struct Ctr {
  u32 tag;
  u32 args_len;
  Port args_buf[16];
};

struct Tup {
  u32 elem_len;
  Port elem_buf[8];
};

struct Str {
  u32 len;
  char* buf;
};

struct Bytes {
  u32 len;
  char* buf;
};

struct IOError {
  u32 tag;
  Port val;
};

struct HostBook {
  std::vector<DefMeta> defs;
  std::vector<std::string> names;
  std::vector<Pair> def_rbag;
  std::vector<Pair> def_nodes;
  u64 total_rbag = 0;
  u64 total_nodes = 0;
  u64 total_vars = 0;
};

static inline Port new_port(Tag tag, Val val) {
  return (val << 3) | tag;
}

static inline Tag get_tag(Port port) {
  return port & 7u;
}

static inline Val get_val(Port port) {
  return port >> 3;
}

static inline Pair new_pair(Port fst, Port snd) {
  return (u64(snd) << 32) | u64(fst);
}

static inline Port get_fst(Pair pair) {
  return u32(pair & 0xFFFFFFFFull);
}

static inline Port get_snd(Pair pair) {
  return u32(pair >> 32);
}

static inline u32 get_typ(Numb word) {
  return word & 0x1Fu;
}

static inline u32 get_sym(Numb word) {
  return word >> 5;
}

static inline u32 get_u24(Numb word) {
  return word >> 5;
}

static inline Numb new_u24(u32 val) {
  return (val << 5) | TY_U24;
}

static inline i32 get_i24(Numb word) {
  return (i32(word) << 3) >> 8;
}

static inline Numb new_i24(i32 val) {
  return (u32(val) << 5) | TY_I24;
}

static inline f32 get_f24(Numb word) {
  u32 bits = (word << 3) & 0xFFFFFF00u;
  f32 out = 0;
  std::memcpy(&out, &bits, sizeof(out));
  return out;
}

static std::string decode_name(const u32* ptr) {
  const char* bytes = reinterpret_cast<const char*>(ptr);
  size_t len = 0;
  while (len < 256 && bytes[len] != '\0') {
    len += 1;
  }
  return std::string(bytes, len);
}

static bool load_book(const u32* book_buffer, HostBook* out) {
  if (!book_buffer || !out) {
    return false;
  }

  const u32* ptr = book_buffer;
  u32 defs_count = *ptr++;

  for (u32 i = 0; i < defs_count; ++i) {
    u32 fid = *ptr++;
    std::string name = decode_name(ptr);
    ptr += 64;

    DefMeta def{};
    def.safe = *ptr++;
    def.rbag_len = *ptr++;
    def.node_len = *ptr++;
    def.vars_len = *ptr++;
    def.root = *ptr++;

    if (def.rbag_len > MAX_TM_ALLOCS || def.node_len > MAX_TM_ALLOCS || def.vars_len > MAX_TM_ALLOCS) {
      std::fprintf(stderr, "failed to load book\n");
      std::fprintf(stderr, "definition '%s' exceeds Metal runtime per-interaction limits\n", name.c_str());
      return false;
    }

    def.rbag_off = static_cast<u32>(out->def_rbag.size());
    for (u32 j = 0; j < def.rbag_len; ++j) {
      Pair pair = new_pair(ptr[0], ptr[1]);
      out->def_rbag.push_back(pair);
      ptr += 2;
    }

    def.node_off = static_cast<u32>(out->def_nodes.size());
    for (u32 j = 0; j < def.node_len; ++j) {
      Pair pair = new_pair(ptr[0], ptr[1]);
      out->def_nodes.push_back(pair);
      ptr += 2;
    }

    if (fid >= out->defs.size()) {
      out->defs.resize(fid + 1);
      out->names.resize(fid + 1);
    }

    out->defs[fid] = def;
    out->names[fid] = name;
    out->total_rbag += def.rbag_len;
    out->total_nodes += def.node_len;
    out->total_vars += def.vars_len;
  }

  return true;
}

static u32 next_pow2_u32(u64 x) {
  if (x <= 1) {
    return 1;
  }
  u64 v = x - 1;
  v |= v >> 1;
  v |= v >> 2;
  v |= v >> 4;
  v |= v >> 8;
  v |= v >> 16;
  v |= v >> 32;
  v += 1;
  if (v > std::numeric_limits<u32>::max()) {
    return std::numeric_limits<u32>::max();
  }
  return static_cast<u32>(v);
}

static u32 clamp_u32(u32 value, u32 lo, u32 hi) {
  return std::max(lo, std::min(value, hi));
}

static Port host_vars_load(const RuntimeState& st, const u32* vars_buf, u32 var) {
  if (var == ROOT_VAR_ID) {
    return st.root_var;
  }
  if (var >= st.vars_cap) {
    return NONE;
  }
  return vars_buf[var];
}

static void host_vars_store(RuntimeState* st, u32* vars_buf, u32 var, Port val) {
  if (var == ROOT_VAR_ID) {
    st->root_var = val;
    return;
  }
  if (var >= st->vars_cap) {
    return;
  }
  vars_buf[var] = val;
}

static Port host_vars_exchange(RuntimeState* st, u32* vars_buf, u32 var, Port val) {
  if (var == ROOT_VAR_ID) {
    Port old = st->root_var;
    st->root_var = val;
    return old;
  }
  if (var >= st->vars_cap) {
    return NONE;
  }
  Port old = vars_buf[var];
  vars_buf[var] = val;
  return old;
}

static void host_vars_take(RuntimeState* st, u32* vars_buf, u32 var) {
  if (var == ROOT_VAR_ID) {
    st->root_var = 0;
    return;
  }
  if (var >= st->vars_cap) {
    return;
  }
  vars_buf[var] = 0;
}

static Port host_enter(RuntimeState* st, u32* vars_buf, Port var) {
  while (get_tag(var) == VAR) {
    u32 loc = get_val(var);
    Port val = host_vars_exchange(st, vars_buf, loc, NONE);
    if (val == NONE || val == 0) {
      break;
    }
    host_vars_take(st, vars_buf, loc);
    var = val;
  }
  return var;
}

static void pretty_print_numb(Numb word) {
  switch (get_typ(word)) {
    case TY_SYM:
      switch (get_sym(word)) {
        case TY_U24: std::printf("[u24]"); break;
        case TY_I24: std::printf("[i24]"); break;
        case TY_F24: std::printf("[f24]"); break;
        case OP_ADD: std::printf("[+]"); break;
        case OP_SUB: std::printf("[-]"); break;
        case FP_SUB: std::printf("[:-]"); break;
        case OP_MUL: std::printf("[*]"); break;
        case OP_DIV: std::printf("[/]"); break;
        case FP_DIV: std::printf("[:/]"); break;
        case OP_REM: std::printf("[%%]"); break;
        case FP_REM: std::printf("[:%%]"); break;
        case OP_EQ: std::printf("[=]"); break;
        case OP_NEQ: std::printf("[!]"); break;
        case OP_LT: std::printf("[<]"); break;
        case OP_GT: std::printf("[>]"); break;
        case OP_AND: std::printf("[&]"); break;
        case OP_OR: std::printf("[|]"); break;
        case OP_XOR: std::printf("[^]"); break;
        case OP_SHL: std::printf("[<<]"); break;
        case FP_SHL: std::printf("[:<<]"); break;
        case OP_SHR: std::printf("[>>]"); break;
        case FP_SHR: std::printf("[:>>]"); break;
        default: std::printf("[?]"); break;
      }
      break;
    case TY_U24:
      std::printf("%u", get_u24(word));
      break;
    case TY_I24:
      std::printf("%+d", get_i24(word));
      break;
    case TY_F24: {
      float val = get_f24(word);
      if (std::isinf(val)) {
        if (std::signbit(val)) {
          std::printf("-inf");
        } else {
          std::printf("+inf");
        }
      } else if (std::isnan(val)) {
        std::printf("+NaN");
      } else {
        std::printf("%.7e", val);
      }
      break;
    }
    default:
      switch (get_typ(word)) {
        case OP_ADD: std::printf("[+0x%07X]", get_u24(word)); break;
        case OP_SUB: std::printf("[-0x%07X]", get_u24(word)); break;
        case FP_SUB: std::printf("[:-0x%07X]", get_u24(word)); break;
        case OP_MUL: std::printf("[*0x%07X]", get_u24(word)); break;
        case OP_DIV: std::printf("[/0x%07X]", get_u24(word)); break;
        case FP_DIV: std::printf("[:/0x%07X]", get_u24(word)); break;
        case OP_REM: std::printf("[%%0x%07X]", get_u24(word)); break;
        case FP_REM: std::printf("[:%%0x%07X]", get_u24(word)); break;
        case OP_EQ: std::printf("[=0x%07X]", get_u24(word)); break;
        case OP_NEQ: std::printf("[!0x%07X]", get_u24(word)); break;
        case OP_LT: std::printf("[<0x%07X]", get_u24(word)); break;
        case OP_GT: std::printf("[>0x%07X]", get_u24(word)); break;
        case OP_AND: std::printf("[&0x%07X]", get_u24(word)); break;
        case OP_OR: std::printf("[|0x%07X]", get_u24(word)); break;
        case OP_XOR: std::printf("[^0x%07X]", get_u24(word)); break;
        case OP_SHL: std::printf("[<<0x%07X]", get_u24(word)); break;
        case FP_SHL: std::printf("[:<<0x%07X]", get_u24(word)); break;
        case OP_SHR: std::printf("[>>0x%07X]", get_u24(word)); break;
        case FP_SHR: std::printf("[:>>0x%07X]", get_u24(word)); break;
        default: std::printf("[?0x%07X]", get_u24(word)); break;
      }
      break;
  }
}

static void pretty_print_port(
  RuntimeState* st,
  const HostBook& book,
  const Pair* node_buf,
  u32* vars_buf,
  Port port
) {
  Port stack[4096];
  u32 len = 0;
  stack[len++] = port;

  while (len > 0) {
    Port cur = stack[--len];
    switch (get_tag(cur)) {
      case CON: {
        u32 loc = get_val(cur);
        if (loc >= st->node_cap) {
          std::printf("*");
          break;
        }
        Pair node = node_buf[loc];
        Port p1 = get_fst(node);
        Port p2 = get_snd(node);
        std::printf("(");
        if (len + 4 >= 4096) {
          std::printf("...");
          break;
        }
        stack[len++] = new_port(ERA, static_cast<u32>(')'));
        stack[len++] = p2;
        stack[len++] = new_port(ERA, static_cast<u32>(' '));
        stack[len++] = p1;
        break;
      }
      case ERA:
        if (get_val(cur) != 0) {
          std::printf("%c", static_cast<char>(get_val(cur)));
        } else {
          std::printf("*");
        }
        break;
      case VAR: {
        Port got = host_vars_load(*st, vars_buf, get_val(cur));
        if (got != NONE) {
          if (len + 1 >= 4096) {
            std::printf("...");
            break;
          }
          stack[len++] = got;
        } else {
          std::printf("x%x", get_val(cur));
        }
        break;
      }
      case NUM:
        pretty_print_numb(get_val(cur));
        break;
      case DUP: {
        u32 loc = get_val(cur);
        if (loc >= st->node_cap) {
          std::printf("*");
          break;
        }
        Pair node = node_buf[loc];
        Port p1 = get_fst(node);
        Port p2 = get_snd(node);
        std::printf("{");
        if (len + 4 >= 4096) {
          std::printf("...");
          break;
        }
        stack[len++] = new_port(ERA, static_cast<u32>('}'));
        stack[len++] = p2;
        stack[len++] = new_port(ERA, static_cast<u32>(' '));
        stack[len++] = p1;
        break;
      }
      case OPR: {
        u32 loc = get_val(cur);
        if (loc >= st->node_cap) {
          std::printf("*");
          break;
        }
        Pair node = node_buf[loc];
        Port p1 = get_fst(node);
        Port p2 = get_snd(node);
        std::printf("$(");
        if (len + 4 >= 4096) {
          std::printf("...");
          break;
        }
        stack[len++] = new_port(ERA, static_cast<u32>(')'));
        stack[len++] = p2;
        stack[len++] = new_port(ERA, static_cast<u32>(' '));
        stack[len++] = p1;
        break;
      }
      case SWI: {
        u32 loc = get_val(cur);
        if (loc >= st->node_cap) {
          std::printf("*");
          break;
        }
        Pair node = node_buf[loc];
        Port p1 = get_fst(node);
        Port p2 = get_snd(node);
        std::printf("?(");
        if (len + 4 >= 4096) {
          std::printf("...");
          break;
        }
        stack[len++] = new_port(ERA, static_cast<u32>(')'));
        stack[len++] = p2;
        stack[len++] = new_port(ERA, static_cast<u32>(' '));
        stack[len++] = p1;
        break;
      }
      case REF: {
        u32 fid = get_val(cur) & 0x0FFFFFFFu;
        if (fid < book.names.size() && !book.names[fid].empty()) {
          std::printf("@%s", book.names[fid].c_str());
        } else {
          std::printf("@%u", fid);
        }
        break;
      }
      default:
        std::printf("*");
        break;
    }
  }
}

static const char* metal_error_message(u32 code) {
  switch (code) {
    case ERR_NONE: return "none";
    case ERR_NODE_OOM: return "node allocation exhausted";
    case ERR_VARS_OOM: return "variable allocation exhausted";
    case ERR_RBAG_OOM: return "redex bag exhausted";
    case ERR_BAD_FID: return "invalid reference id";
    case ERR_STEP_LIMIT: return "step limit reached";
    case ERR_BAD_BOOK: return "book metadata is invalid";
    case ERR_NODE_OOB: return "node index out of bounds";
    case ERR_VARS_OOB: return "variable index out of bounds";
    case ERR_TM_OOM: return "temporary interaction storage overflow";
    default: return "unknown error";
  }
}

struct MetalRuntime {
  id<MTLComputePipelineState> pipeline = nil;
  id<MTLCommandQueue> queue = nil;
  id<MTLBuffer> defs_buf = nil;
  id<MTLBuffer> def_rbag_buf = nil;
  id<MTLBuffer> def_nodes_buf = nil;
  id<MTLBuffer> node_buf = nil;
  id<MTLBuffer> vars_buf = nil;
  id<MTLBuffer> rbag_buf = nil;
  id<MTLBuffer> state_buf = nil;
  RuntimeState state{};
  u64 total_itrs = 0;
};

using IoFn = Port (*)(MetalRuntime*, Port);

struct IoBinding {
  const char* name;
  IoFn func;
};

static FILE* FILE_POINTERS[256] = {nullptr};
static void* DYLIBS[256] = {nullptr};

static inline Pair* rt_nodes(MetalRuntime* rt) {
  return static_cast<Pair*>([rt->node_buf contents]);
}

static inline Port* rt_vars(MetalRuntime* rt) {
  return static_cast<Port*>([rt->vars_buf contents]);
}

static inline Pair* rt_rbag(MetalRuntime* rt) {
  return static_cast<Pair*>([rt->rbag_buf contents]);
}

static inline void rt_set_error(MetalRuntime* rt, u32 error) {
  if (rt->state.error == ERR_NONE) {
    rt->state.error = error;
  }
}

static inline Pair rt_node_load(MetalRuntime* rt, u32 loc) {
  if (loc >= rt->state.node_cap) {
    rt_set_error(rt, ERR_NODE_OOB);
    return 0;
  }
  return rt_nodes(rt)[loc];
}

static inline void rt_node_store(MetalRuntime* rt, u32 loc, Pair value) {
  if (loc >= rt->state.node_cap) {
    rt_set_error(rt, ERR_NODE_OOB);
    return;
  }
  rt_nodes(rt)[loc] = value;
}

static inline Pair rt_node_take(MetalRuntime* rt, u32 loc) {
  Pair old = rt_node_load(rt, loc);
  if (rt->state.error != ERR_NONE) {
    return 0;
  }
  rt_nodes(rt)[loc] = 0;
  return old;
}

static inline Port rt_vars_load(MetalRuntime* rt, u32 var) {
  if (var == ROOT_VAR_ID) {
    return rt->state.root_var;
  }
  if (var >= rt->state.vars_cap) {
    rt_set_error(rt, ERR_VARS_OOB);
    return NONE;
  }
  return rt_vars(rt)[var];
}

static inline void rt_vars_store(MetalRuntime* rt, u32 var, Port value) {
  if (var == ROOT_VAR_ID) {
    rt->state.root_var = value;
    return;
  }
  if (var >= rt->state.vars_cap) {
    rt_set_error(rt, ERR_VARS_OOB);
    return;
  }
  rt_vars(rt)[var] = value;
}

static inline Port rt_vars_exchange(MetalRuntime* rt, u32 var, Port value) {
  if (var == ROOT_VAR_ID) {
    Port old = rt->state.root_var;
    rt->state.root_var = value;
    return old;
  }
  if (var >= rt->state.vars_cap) {
    rt_set_error(rt, ERR_VARS_OOB);
    return NONE;
  }
  Port old = rt_vars(rt)[var];
  rt_vars(rt)[var] = value;
  return old;
}

static inline void rt_vars_take(MetalRuntime* rt, u32 var) {
  rt_vars_store(rt, var, 0);
}

static inline bool rt_push_redex(MetalRuntime* rt, Pair redex) {
  if (rt->state.rbag_len >= rt->state.rbag_cap) {
    rt_set_error(rt, ERR_RBAG_OOM);
    return false;
  }
  rt_rbag(rt)[rt->state.rbag_len++] = redex;
  return true;
}

static bool rt_dispatch_normalize(MetalRuntime* rt, u32 command) {
  rt->state.command = command;
  std::memcpy([rt->state_buf contents], &rt->state, sizeof(rt->state));

  id<MTLCommandBuffer> cmd = [rt->queue commandBuffer];
  id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
  [enc setComputePipelineState:rt->pipeline];
  [enc setBuffer:rt->defs_buf offset:0 atIndex:0];
  [enc setBuffer:rt->def_rbag_buf offset:0 atIndex:1];
  [enc setBuffer:rt->def_nodes_buf offset:0 atIndex:2];
  [enc setBuffer:rt->node_buf offset:0 atIndex:3];
  [enc setBuffer:rt->vars_buf offset:0 atIndex:4];
  [enc setBuffer:rt->rbag_buf offset:0 atIndex:5];
  [enc setBuffer:rt->state_buf offset:0 atIndex:6];
  [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
  [enc endEncoding];

  [cmd commit];
  [cmd waitUntilCompleted];

  if (cmd.error) {
    std::fprintf(stderr, "Metal runtime command failure: %s\n", [[cmd.error localizedDescription] UTF8String]);
    rt_set_error(rt, ERR_BAD_BOOK);
    return false;
  }

  std::memcpy(&rt->state, [rt->state_buf contents], sizeof(rt->state));
  rt->total_itrs += rt->state.itrs;
  return rt->state.error == ERR_NONE;
}

static bool rt_alloc_nodes(MetalRuntime* rt, u32 need, u32* out) {
  if (need > MAX_TM_ALLOCS) {
    rt_set_error(rt, ERR_TM_OOM);
    return false;
  }
  u32 got = 0;
  for (u32 tries = 0; tries < rt->state.node_cap && got < need; ++tries) {
    u32 idx = rt->state.node_head;
    rt->state.node_head = (rt->state.node_head + 1u) % rt->state.node_cap;
    if (idx == 0) {
      continue;
    }
    if (rt_nodes(rt)[idx] == 0) {
      out[got++] = idx;
    }
  }
  if (got < need) {
    rt_set_error(rt, ERR_NODE_OOM);
    return false;
  }
  return true;
}

static bool rt_alloc_vars(MetalRuntime* rt, u32 need, u32* out) {
  if (need > MAX_TM_ALLOCS) {
    rt_set_error(rt, ERR_TM_OOM);
    return false;
  }
  u32 got = 0;
  for (u32 tries = 0; tries < rt->state.vars_cap && got < need; ++tries) {
    u32 idx = rt->state.vars_head;
    rt->state.vars_head = (rt->state.vars_head + 1u) % rt->state.vars_cap;
    if (idx == 0) {
      continue;
    }
    if (rt_vars(rt)[idx] == 0) {
      out[got++] = idx;
    }
  }
  if (got < need) {
    rt_set_error(rt, ERR_VARS_OOM);
    return false;
  }
  return true;
}

static bool rt_get_resources(MetalRuntime* rt, u32 need_rbag, u32 need_node, u32 need_vars, u32* nloc, u32* vloc) {
  if (rt->state.rbag_len + need_rbag > rt->state.rbag_cap) {
    rt_set_error(rt, ERR_RBAG_OOM);
    return false;
  }
  return rt_alloc_nodes(rt, need_node, nloc) && rt_alloc_vars(rt, need_vars, vloc);
}

static Port rt_peek(MetalRuntime* rt, Port var) {
  while (get_tag(var) == VAR) {
    Port val = rt_vars_load(rt, get_val(var));
    if (rt->state.error != ERR_NONE || val == NONE || val == 0) {
      break;
    }
    var = val;
  }
  return var;
}

static Port rt_enter(MetalRuntime* rt, Port var) {
  while (get_tag(var) == VAR) {
    u32 loc = get_val(var);
    Port val = rt_vars_exchange(rt, loc, NONE);
    if (rt->state.error != ERR_NONE || val == NONE || val == 0) {
      break;
    }
    rt_vars_take(rt, loc);
    if (rt->state.error != ERR_NONE) {
      return var;
    }
    var = val;
  }
  return var;
}

static bool rt_boot_redex(MetalRuntime* rt, Pair redex) {
  rt_vars_store(rt, ROOT_VAR_ID, NONE);
  if (rt->state.error != ERR_NONE) {
    return false;
  }
  return rt_push_redex(rt, redex);
}

static Port rt_expand(MetalRuntime* rt, Port port) {
  Port old = rt_vars_load(rt, ROOT_VAR_ID);
  Port got = rt_peek(rt, port);
  while (get_tag(got) == REF && rt->state.error == ERR_NONE) {
    if (!rt_boot_redex(rt, new_pair(got, ROOT))) {
      break;
    }
    if (!rt_dispatch_normalize(rt, 1)) {
      break;
    }
    got = rt_peek(rt, rt_vars_load(rt, ROOT_VAR_ID));
  }
  rt_vars_store(rt, ROOT_VAR_ID, old);
  return got;
}

static Ctr readback_ctr(MetalRuntime* rt, Port port) {
  Ctr ctr{};
  ctr.tag = std::numeric_limits<u32>::max();
  ctr.args_len = 0;

  Port lam_port = rt_expand(rt, port);
  if (get_tag(lam_port) != CON) {
    return ctr;
  }
  Pair lam_node = rt_node_load(rt, get_val(lam_port));
  if (rt->state.error != ERR_NONE) {
    return ctr;
  }

  Port app_port = rt_expand(rt, get_fst(lam_node));
  if (get_tag(app_port) != CON) {
    return ctr;
  }
  Pair app_node = rt_node_load(rt, get_val(app_port));
  if (rt->state.error != ERR_NONE) {
    return ctr;
  }

  Port arg_port = rt_expand(rt, get_fst(app_node));
  if (get_tag(arg_port) != NUM) {
    return ctr;
  }
  ctr.tag = get_u24(get_val(arg_port));

  while (ctr.args_len < 16) {
    app_port = rt_expand(rt, get_snd(app_node));
    if (get_tag(app_port) != CON) {
      break;
    }
    app_node = rt_node_load(rt, get_val(app_port));
    if (rt->state.error != ERR_NONE) {
      break;
    }
    arg_port = rt_expand(rt, get_fst(app_node));
    ctr.args_buf[ctr.args_len++] = arg_port;
  }

  return ctr;
}

static Tup readback_tup(MetalRuntime* rt, Port port, u32 size) {
  Tup tup{};
  tup.elem_len = 0;

  while (get_tag(port) == CON && (tup.elem_len + 1 < size)) {
    Pair node = rt_node_load(rt, get_val(port));
    if (rt->state.error != ERR_NONE) {
      return tup;
    }
    tup.elem_buf[tup.elem_len++] = rt_expand(rt, get_fst(node));
    port = rt_expand(rt, get_snd(node));
  }

  tup.elem_buf[tup.elem_len++] = port;
  return tup;
}

static Bytes readback_bytes(MetalRuntime* rt, Port port) {
  Bytes bytes{};
  u32 capacity = 256;
  bytes.buf = static_cast<char*>(std::malloc(capacity));
  bytes.len = 0;

  if (!bytes.buf) {
    rt_set_error(rt, ERR_BAD_BOOK);
    return bytes;
  }

  while (true) {
    if (!rt_dispatch_normalize(rt, 1)) {
      break;
    }

    Ctr ctr = readback_ctr(rt, rt_peek(rt, port));
    if (rt->state.error != ERR_NONE) {
      break;
    }

    if (ctr.tag == LIST_CONS) {
      if (ctr.args_len != 2 || get_tag(ctr.args_buf[0]) != NUM) {
        break;
      }
      if (bytes.len == capacity - 1) {
        capacity *= 2;
        char* bigger = static_cast<char*>(std::realloc(bytes.buf, capacity));
        if (!bigger) {
          rt_set_error(rt, ERR_BAD_BOOK);
          break;
        }
        bytes.buf = bigger;
      }
      bytes.buf[bytes.len++] = static_cast<char>(get_u24(get_val(ctr.args_buf[0])));
      if (!rt_boot_redex(rt, new_pair(ctr.args_buf[1], ROOT))) {
        break;
      }
      port = ROOT;
      continue;
    }

    break;
  }

  return bytes;
}

static Str readback_str(MetalRuntime* rt, Port port) {
  Bytes bytes = readback_bytes(rt, port);
  Str str{};
  str.len = bytes.len;
  str.buf = bytes.buf;
  if (str.buf) {
    str.buf[str.len] = 0;
  }
  return str;
}

static Port inject_nil(MetalRuntime* rt) {
  u32 nloc[2];
  u32 vloc[1];
  if (!rt_get_resources(rt, 0, 2, 1, nloc, vloc)) {
    return new_port(ERA, 0);
  }
  rt_vars_store(rt, vloc[0], NONE);
  Port var = new_port(VAR, vloc[0]);
  rt_node_store(rt, nloc[0], new_pair(new_port(NUM, new_u24(LIST_NIL)), var));
  rt_node_store(rt, nloc[1], new_pair(new_port(CON, nloc[0]), var));
  return new_port(CON, nloc[1]);
}

static Port inject_cons(MetalRuntime* rt, Port head, Port tail) {
  u32 nloc[4];
  u32 vloc[1];
  if (!rt_get_resources(rt, 0, 4, 1, nloc, vloc)) {
    return new_port(ERA, 0);
  }
  rt_vars_store(rt, vloc[0], NONE);
  Port var = new_port(VAR, vloc[0]);
  rt_node_store(rt, nloc[0], new_pair(tail, var));
  rt_node_store(rt, nloc[1], new_pair(head, new_port(CON, nloc[0])));
  rt_node_store(rt, nloc[2], new_pair(new_port(NUM, new_u24(LIST_CONS)), new_port(CON, nloc[1])));
  rt_node_store(rt, nloc[3], new_pair(new_port(CON, nloc[2]), var));
  return new_port(CON, nloc[3]);
}

static Port inject_bytes(MetalRuntime* rt, Bytes* bytes) {
  Port port = inject_nil(rt);
  if (rt->state.error != ERR_NONE) {
    return new_port(ERA, 0);
  }
  for (u32 i = 0; i < bytes->len; ++i) {
    Port byte = new_port(NUM, new_u24(static_cast<u8>(bytes->buf[bytes->len - i - 1])));
    port = inject_cons(rt, byte, port);
    if (rt->state.error != ERR_NONE) {
      return new_port(ERA, 0);
    }
  }
  return port;
}

static Port inject_ok(MetalRuntime* rt, Port val) {
  u32 nloc[3];
  u32 vloc[1];
  if (!rt_get_resources(rt, 0, 3, 1, nloc, vloc)) {
    return new_port(ERA, 0);
  }
  rt_vars_store(rt, vloc[0], NONE);
  Port var = new_port(VAR, vloc[0]);
  rt_node_store(rt, nloc[0], new_pair(val, var));
  rt_node_store(rt, nloc[1], new_pair(new_port(NUM, new_u24(RESULT_OK)), new_port(CON, nloc[0])));
  rt_node_store(rt, nloc[2], new_pair(new_port(CON, nloc[1]), var));
  return new_port(CON, nloc[2]);
}

static Port inject_err(MetalRuntime* rt, Port err) {
  u32 nloc[3];
  u32 vloc[1];
  if (!rt_get_resources(rt, 0, 3, 1, nloc, vloc)) {
    return new_port(ERA, 0);
  }
  rt_vars_store(rt, vloc[0], NONE);
  Port var = new_port(VAR, vloc[0]);
  rt_node_store(rt, nloc[0], new_pair(err, var));
  rt_node_store(rt, nloc[1], new_pair(new_port(NUM, new_u24(RESULT_ERR)), new_port(CON, nloc[0])));
  rt_node_store(rt, nloc[2], new_pair(new_port(CON, nloc[1]), var));
  return new_port(CON, nloc[2]);
}

static Port inject_io_err(MetalRuntime* rt, IOError err) {
  if (err.tag <= IO_ERR_NAME) {
    u32 nloc[2];
    u32 vloc[1];
    if (!rt_get_resources(rt, 0, 2, 1, nloc, vloc)) {
      return new_port(ERA, 0);
    }
    rt_vars_store(rt, vloc[0], NONE);
    Port var = new_port(VAR, vloc[0]);
    rt_node_store(rt, nloc[0], new_pair(new_port(NUM, new_u24(err.tag)), var));
    rt_node_store(rt, nloc[1], new_pair(new_port(CON, nloc[0]), var));
    return inject_err(rt, new_port(CON, nloc[1]));
  }

  u32 nloc[3];
  u32 vloc[1];
  if (!rt_get_resources(rt, 0, 3, 1, nloc, vloc)) {
    return new_port(ERA, 0);
  }
  rt_vars_store(rt, vloc[0], NONE);
  Port var = new_port(VAR, vloc[0]);
  rt_node_store(rt, nloc[0], new_pair(err.val, var));
  rt_node_store(rt, nloc[1], new_pair(new_port(NUM, new_u24(IO_ERR_INNER)), new_port(CON, nloc[0])));
  rt_node_store(rt, nloc[2], new_pair(new_port(CON, nloc[1]), var));
  return inject_err(rt, new_port(CON, nloc[2]));
}

static Port inject_io_err_type(MetalRuntime* rt) {
  IOError err{IO_ERR_TYPE, 0};
  return inject_io_err(rt, err);
}

static Port inject_io_err_name(MetalRuntime* rt) {
  IOError err{IO_ERR_NAME, 0};
  return inject_io_err(rt, err);
}

static Port inject_io_err_inner(MetalRuntime* rt, Port val) {
  IOError err{IO_ERR_INNER, val};
  return inject_io_err(rt, err);
}

static Port inject_io_err_str(MetalRuntime* rt, const char* err) {
  Bytes bytes{};
  bytes.buf = const_cast<char*>(err);
  bytes.len = static_cast<u32>(std::strlen(err));
  Port p = inject_bytes(rt, &bytes);
  return inject_io_err_inner(rt, p);
}

static FILE* readback_file(Port port) {
  if (get_tag(port) != NUM) {
    return nullptr;
  }
  u32 idx = get_u24(get_val(port));
  if (idx == 0) return stdin;
  if (idx == 1) return stdout;
  if (idx == 2) return stderr;
  if (idx >= sizeof(FILE_POINTERS) / sizeof(FILE_POINTERS[0])) {
    return nullptr;
  }
  return FILE_POINTERS[idx];
}

static Port io_read(MetalRuntime* rt, Port argm) {
  Tup tup = readback_tup(rt, argm, 2);
  if (tup.elem_len != 2 || get_tag(tup.elem_buf[1]) != NUM) {
    return inject_io_err_type(rt);
  }
  FILE* fp = readback_file(tup.elem_buf[0]);
  u32 num_bytes = get_u24(get_val(tup.elem_buf[1]));
  if (!fp) {
    return inject_io_err_inner(rt, new_port(NUM, new_i24(EBADF)));
  }

  Bytes bytes{};
  bytes.buf = static_cast<char*>(std::malloc(std::max<u32>(num_bytes, 1)));
  bytes.len = static_cast<u32>(std::fread(bytes.buf, sizeof(char), num_bytes, fp));
  if ((bytes.len != num_bytes) && std::ferror(fp)) {
    std::free(bytes.buf);
    return inject_io_err_inner(rt, new_port(NUM, new_i24(std::ferror(fp))));
  }
  Port ret = inject_bytes(rt, &bytes);
  std::free(bytes.buf);
  return inject_ok(rt, ret);
}

static Port io_open(MetalRuntime* rt, Port argm) {
  Tup tup = readback_tup(rt, argm, 2);
  if (tup.elem_len != 2) {
    return inject_io_err_type(rt);
  }
  Str name = readback_str(rt, tup.elem_buf[0]);
  Str mode = readback_str(rt, tup.elem_buf[1]);
  if (!name.buf || !mode.buf) {
    if (name.buf) std::free(name.buf);
    if (mode.buf) std::free(mode.buf);
    return inject_io_err_type(rt);
  }

  for (u32 fd = 3; fd < sizeof(FILE_POINTERS) / sizeof(FILE_POINTERS[0]); ++fd) {
    if (FILE_POINTERS[fd] == nullptr) {
      FILE_POINTERS[fd] = std::fopen(name.buf, mode.buf);
      std::free(name.buf);
      std::free(mode.buf);
      if (FILE_POINTERS[fd] == nullptr) {
        return inject_io_err_inner(rt, new_port(NUM, new_i24(errno)));
      }
      return inject_ok(rt, new_port(NUM, new_u24(fd)));
    }
  }

  std::free(name.buf);
  std::free(mode.buf);
  return inject_io_err_inner(rt, new_port(NUM, new_i24(EMFILE)));
}

static Port io_close(MetalRuntime* rt, Port argm) {
  FILE* fp = readback_file(argm);
  if (!fp) {
    return inject_io_err_inner(rt, new_port(NUM, new_i24(EBADF)));
  }
  if (std::fclose(fp) != 0) {
    return inject_io_err_inner(rt, new_port(NUM, new_i24(std::ferror(fp))));
  }
  u32 fd = get_u24(get_val(argm));
  if (fd < sizeof(FILE_POINTERS) / sizeof(FILE_POINTERS[0])) {
    FILE_POINTERS[fd] = nullptr;
  }
  return inject_ok(rt, new_port(ERA, 0));
}

static Port io_write(MetalRuntime* rt, Port argm) {
  Tup tup = readback_tup(rt, argm, 2);
  if (tup.elem_len != 2) {
    return inject_io_err_type(rt);
  }
  FILE* fp = readback_file(tup.elem_buf[0]);
  Bytes bytes = readback_bytes(rt, tup.elem_buf[1]);
  if (!fp) {
    if (bytes.buf) std::free(bytes.buf);
    return inject_io_err_inner(rt, new_port(NUM, new_i24(EBADF)));
  }
  if (std::fwrite(bytes.buf, sizeof(char), bytes.len, fp) != bytes.len) {
    std::free(bytes.buf);
    return inject_io_err_inner(rt, new_port(NUM, new_i24(std::ferror(fp))));
  }
  std::free(bytes.buf);
  return inject_ok(rt, new_port(ERA, 0));
}

static Port io_flush(MetalRuntime* rt, Port argm) {
  FILE* fp = readback_file(argm);
  if (!fp) {
    return inject_io_err_inner(rt, new_port(NUM, new_i24(EBADF)));
  }
  if (std::fflush(fp) != 0) {
    return inject_io_err_inner(rt, new_port(NUM, new_i24(std::ferror(fp))));
  }
  return inject_ok(rt, new_port(ERA, 0));
}

static Port io_seek(MetalRuntime* rt, Port argm) {
  Tup tup = readback_tup(rt, argm, 3);
  if (tup.elem_len != 3 || get_tag(tup.elem_buf[1]) != NUM || get_tag(tup.elem_buf[2]) != NUM) {
    return inject_io_err_type(rt);
  }
  FILE* fp = readback_file(tup.elem_buf[0]);
  i32 offset = get_i24(get_val(tup.elem_buf[1]));
  u32 whence = get_u24(get_val(tup.elem_buf[2]));
  if (!fp) {
    return inject_io_err_inner(rt, new_port(NUM, new_i24(EBADF)));
  }
  int cwhence = SEEK_SET;
  if (whence == 1) cwhence = SEEK_CUR;
  else if (whence == 2) cwhence = SEEK_END;
  else if (whence != 0) return inject_io_err_type(rt);
  if (std::fseek(fp, offset, cwhence) != 0) {
    return inject_io_err_inner(rt, new_port(NUM, new_i24(std::ferror(fp))));
  }
  return inject_ok(rt, new_port(ERA, 0));
}

static u64 time64_ns() {
  auto now = std::chrono::steady_clock::now().time_since_epoch();
  return static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(now).count());
}

static Port io_get_time(MetalRuntime* rt, Port argm) {
  (void)argm;
  u32 nloc[1];
  u32 vloc[1];
  if (!rt_get_resources(rt, 0, 1, 0, nloc, vloc)) {
    return new_port(ERA, 0);
  }
  u64 ns = time64_ns();
  u32 hi = static_cast<u32>((ns >> 24) & 0xFFFFFFu);
  u32 lo = static_cast<u32>(ns & 0xFFFFFFu);
  rt_node_store(rt, nloc[0], new_pair(new_port(NUM, new_u24(hi)), new_port(NUM, new_u24(lo))));
  return inject_ok(rt, new_port(CON, nloc[0]));
}

static Port io_sleep(MetalRuntime* rt, Port argm) {
  Tup tup = readback_tup(rt, argm, 2);
  if (tup.elem_len != 2 || get_tag(tup.elem_buf[0]) != NUM || get_tag(tup.elem_buf[1]) != NUM) {
    return inject_io_err_type(rt);
  }
  u64 hi = get_u24(get_val(tup.elem_buf[0]));
  u64 lo = get_u24(get_val(tup.elem_buf[1]));
  u64 ns = (hi << 24) | lo;
  timespec ts{};
  ts.tv_sec = static_cast<time_t>(ns / 1000000000ull);
  ts.tv_nsec = static_cast<long>(ns % 1000000000ull);
  nanosleep(&ts, nullptr);
  return inject_ok(rt, new_port(ERA, 0));
}

static const IoBinding IO_BINDINGS[] = {
  {"READ", io_read},
  {"OPEN", io_open},
  {"CLOSE", io_close},
  {"FLUSH", io_flush},
  {"WRITE", io_write},
  {"SEEK", io_seek},
  {"GET_TIME", io_get_time},
  {"SLEEP", io_sleep},
};

static Port run_io_func(MetalRuntime* rt, const char* name, Port argm) {
  for (const IoBinding& binding : IO_BINDINGS) {
    if (std::strcmp(binding.name, name) == 0) {
      return binding.func(rt, argm);
    }
  }
  return inject_io_err_name(rt);
}

static bool do_run_io(MetalRuntime* rt) {
  setlinebuf(stdout);
  setlinebuf(stderr);
  Port port = ROOT;

  while (true) {
    if (!rt_dispatch_normalize(rt, 1)) {
      return false;
    }

    Ctr ctr = readback_ctr(rt, rt_peek(rt, port));
    if (rt->state.error != ERR_NONE) {
      return false;
    }

    if (ctr.args_len < 1 || get_tag(ctr.args_buf[0]) != CON) {
      break;
    }

    Pair io_magic = rt_node_load(rt, get_val(ctr.args_buf[0]));
    if (rt->state.error != ERR_NONE) {
      return false;
    }

    if (get_val(get_fst(io_magic)) != new_u24(IO_MAGIC_0) || get_val(get_snd(io_magic)) != new_u24(IO_MAGIC_1)) {
      break;
    }

    if (ctr.tag == IO_DONE) {
      break;
    }

    if (ctr.tag != IO_CALL || ctr.args_len != 4) {
      break;
    }

    Str func = readback_str(rt, ctr.args_buf[1]);
    Port argm = ctr.args_buf[2];
    Port cont = ctr.args_buf[3];
    Port ret = func.buf ? run_io_func(rt, func.buf, argm) : inject_io_err_type(rt);
    if (func.buf) {
      std::free(func.buf);
    }

    u32 nloc[1];
    u32 vloc[1];
    if (!rt_get_resources(rt, 1, 1, 0, nloc, vloc)) {
      return false;
    }
    rt_node_store(rt, nloc[0], new_pair(ret, ROOT));
    if (!rt_boot_redex(rt, new_pair(new_port(CON, nloc[0]), cont))) {
      return false;
    }
    port = ROOT;
  }

  return true;
}

extern "C" int hvm_mtl(const u32* book_buffer) {
  @autoreleasepool {
    HostBook book;
    if (!load_book(book_buffer, &book)) {
      std::fprintf(stderr, "failed to load book\n");
      return 1;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      std::fprintf(stderr, "Metal runtime not available!\n No Metal-compatible device was found.\n");
      return 1;
    }

    NSError* error = nil;
    id<MTLLibrary> library = nil;
#ifndef HVM_GEN_STANDALONE
    dispatch_data_t lib_data = dispatch_data_create(
      HVM_METAL_LIB,
      HVM_METAL_LIB_LEN,
      dispatch_get_main_queue(),
      DISPATCH_DATA_DESTRUCTOR_DEFAULT
    );
    library = [device newLibraryWithData:lib_data error:&error];
    if (!library) {
      std::fprintf(stderr, "Metal runtime failed to load embedded library: %s\n", [[error localizedDescription] UTF8String]);
      return 1;
    }
#else
    NSString* source = [NSString stringWithUTF8String:HVM_METAL_SRC];
    if (!source) {
      std::fprintf(stderr, "Metal runtime failed to decode embedded shader source.\n");
      return 1;
    }
    MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
    library = [device newLibraryWithSource:source options:opts error:&error];
    if (!library) {
      std::fprintf(stderr, "Metal runtime failed to compile embedded source: %s\n", [[error localizedDescription] UTF8String]);
      return 1;
    }
#endif

    id<MTLFunction> kernel = [library newFunctionWithName:@"hvm_eval"];
    if (!kernel) {
      std::fprintf(stderr, "Metal runtime failed to find kernel 'hvm_eval'.\n");
      return 1;
    }

    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:kernel error:&error];
    if (!pipeline) {
      std::fprintf(stderr, "Metal runtime failed to create compute pipeline: %s\n", [[error localizedDescription] UTF8String]);
      return 1;
    }

    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) {
      std::fprintf(stderr, "Metal runtime failed to create command queue.\n");
      return 1;
    }

    u32 node_cap = clamp_u32(next_pow2_u32(book.total_nodes * 128ull + 65536ull), 1u << 21, 1u << 25);
    u32 vars_cap = clamp_u32(next_pow2_u32(book.total_vars * 128ull + 65536ull), 1u << 21, 1u << 25);
    u32 rbag_cap = clamp_u32(next_pow2_u32(book.total_rbag * 128ull + 65536ull), 1u << 20, 1u << 24);

    size_t defs_bytes = book.defs.size() * sizeof(DefMeta);
    size_t def_rbag_bytes = book.def_rbag.size() * sizeof(Pair);
    size_t def_nodes_bytes = book.def_nodes.size() * sizeof(Pair);
    size_t node_bytes = size_t(node_cap) * sizeof(Pair);
    size_t vars_bytes = size_t(vars_cap) * sizeof(Port);
    size_t rbag_bytes = size_t(rbag_cap) * sizeof(Pair);

    MetalRuntime rt{};
    rt.pipeline = pipeline;
    rt.queue = queue;
    rt.defs_buf = [device newBufferWithLength:std::max<size_t>(defs_bytes, 4) options:MTLResourceStorageModeShared];
    rt.def_rbag_buf = [device newBufferWithLength:std::max<size_t>(def_rbag_bytes, 8) options:MTLResourceStorageModeShared];
    rt.def_nodes_buf = [device newBufferWithLength:std::max<size_t>(def_nodes_bytes, 8) options:MTLResourceStorageModeShared];
    rt.node_buf = [device newBufferWithLength:node_bytes options:MTLResourceStorageModeShared];
    rt.vars_buf = [device newBufferWithLength:vars_bytes options:MTLResourceStorageModeShared];
    rt.rbag_buf = [device newBufferWithLength:rbag_bytes options:MTLResourceStorageModeShared];
    rt.state_buf = [device newBufferWithLength:sizeof(RuntimeState) options:MTLResourceStorageModeShared];

    if (!rt.defs_buf || !rt.def_rbag_buf || !rt.def_nodes_buf || !rt.node_buf || !rt.vars_buf || !rt.rbag_buf || !rt.state_buf) {
      std::fprintf(stderr, "Metal runtime failed to allocate buffers.\n");
      return 1;
    }

    if (!book.defs.empty()) {
      std::memcpy([rt.defs_buf contents], book.defs.data(), defs_bytes);
    }
    if (!book.def_rbag.empty()) {
      std::memcpy([rt.def_rbag_buf contents], book.def_rbag.data(), def_rbag_bytes);
    }
    if (!book.def_nodes.empty()) {
      std::memcpy([rt.def_nodes_buf contents], book.def_nodes.data(), def_nodes_bytes);
    }

    std::memset([rt.node_buf contents], 0, node_bytes);
    std::memset([rt.vars_buf contents], 0, vars_bytes);
    std::memset([rt.rbag_buf contents], 0, rbag_bytes);

    rt.state.defs_len = static_cast<u32>(book.defs.size());
    rt.state.node_cap = node_cap;
    rt.state.vars_cap = vars_cap;
    rt.state.rbag_cap = rbag_cap;
    rt.state.max_steps = 0xF0000000u;
    rt.state.command = 0;
    std::memcpy([rt.state_buf contents], &rt.state, sizeof(rt.state));

    auto start = std::chrono::steady_clock::now();

    if (!rt_dispatch_normalize(&rt, 0)) {
      std::fprintf(stderr, "Metal runtime error: %s (code %u, step %u)\n", metal_error_message(rt.state.error), rt.state.error, rt.state.steps);
      return 1;
    }

    if (!do_run_io(&rt)) {
      std::fprintf(stderr, "Metal runtime error: %s (code %u, step %u)\n", metal_error_message(rt.state.error), rt.state.error, rt.state.steps);
      return 1;
    }

    auto end = std::chrono::steady_clock::now();
    double duration = std::chrono::duration<double>(end - start).count();

    Port result = rt_enter(&rt, ROOT);
    if (rt.state.error != ERR_NONE) {
      std::fprintf(stderr, "Metal runtime error: %s (code %u, step %u)\n", metal_error_message(rt.state.error), rt.state.error, rt.state.steps);
      return 1;
    }

    std::printf("Result: ");
    pretty_print_port(&rt.state, book, rt_nodes(&rt), rt_vars(&rt), result);
    std::printf("\n");

    std::printf("- ITRS: %llu\n", static_cast<unsigned long long>(rt.total_itrs));
    std::printf("- TIME: %.2fs\n", duration);
    double mips = duration > 0.0 ? (double(rt.total_itrs) / duration / 1000000.0) : 0.0;
    std::printf("- MIPS: %.2f\n", mips);
    return 0;
  }
}
