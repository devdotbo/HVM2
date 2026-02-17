#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "hvm_metal_lib.h"

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

static inline i32 get_i24(Numb word) {
  return (i32(word) << 3) >> 8;
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

extern "C" void hvm_mtl(const u32* book_buffer) {
  @autoreleasepool {
    HostBook book;
    if (!load_book(book_buffer, &book)) {
      std::fprintf(stderr, "failed to load book\n");
      return;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      std::fprintf(stderr, "Metal runtime not available!\n No Metal-compatible device was found.\n");
      return;
    }

    NSError* error = nil;
    dispatch_data_t lib_data = dispatch_data_create(
      HVM_METAL_LIB,
      HVM_METAL_LIB_LEN,
      dispatch_get_main_queue(),
      DISPATCH_DATA_DESTRUCTOR_DEFAULT
    );

    id<MTLLibrary> library = [device newLibraryWithData:lib_data error:&error];
    if (!library) {
      std::fprintf(stderr, "Metal runtime failed to load embedded library: %s\n", [[error localizedDescription] UTF8String]);
      return;
    }

    id<MTLFunction> kernel = [library newFunctionWithName:@"hvm_eval"];
    if (!kernel) {
      std::fprintf(stderr, "Metal runtime failed to find kernel 'hvm_eval'.\n");
      return;
    }

    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:kernel error:&error];
    if (!pipeline) {
      std::fprintf(stderr, "Metal runtime failed to create compute pipeline: %s\n", [[error localizedDescription] UTF8String]);
      return;
    }

    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) {
      std::fprintf(stderr, "Metal runtime failed to create command queue.\n");
      return;
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
    size_t state_bytes = sizeof(RuntimeState);

    id<MTLBuffer> defs_buf = [device newBufferWithLength:std::max<size_t>(defs_bytes, 4) options:MTLResourceStorageModeShared];
    id<MTLBuffer> def_rbag_buf = [device newBufferWithLength:std::max<size_t>(def_rbag_bytes, 8) options:MTLResourceStorageModeShared];
    id<MTLBuffer> def_nodes_buf = [device newBufferWithLength:std::max<size_t>(def_nodes_bytes, 8) options:MTLResourceStorageModeShared];
    id<MTLBuffer> node_buf = [device newBufferWithLength:node_bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> vars_buf = [device newBufferWithLength:vars_bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> rbag_buf = [device newBufferWithLength:rbag_bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> state_buf = [device newBufferWithLength:state_bytes options:MTLResourceStorageModeShared];

    if (!defs_buf || !def_rbag_buf || !def_nodes_buf || !node_buf || !vars_buf || !rbag_buf || !state_buf) {
      std::fprintf(stderr, "Metal runtime failed to allocate buffers.\n");
      return;
    }

    if (!book.defs.empty()) {
      std::memcpy([defs_buf contents], book.defs.data(), defs_bytes);
    }
    if (!book.def_rbag.empty()) {
      std::memcpy([def_rbag_buf contents], book.def_rbag.data(), def_rbag_bytes);
    }
    if (!book.def_nodes.empty()) {
      std::memcpy([def_nodes_buf contents], book.def_nodes.data(), def_nodes_bytes);
    }

    std::memset([node_buf contents], 0, node_bytes);
    std::memset([vars_buf contents], 0, vars_bytes);
    std::memset([rbag_buf contents], 0, rbag_bytes);

    RuntimeState initial{};
    initial.defs_len = static_cast<u32>(book.defs.size());
    initial.node_cap = node_cap;
    initial.vars_cap = vars_cap;
    initial.rbag_cap = rbag_cap;
    initial.max_steps = 0xF0000000u;
    std::memcpy([state_buf contents], &initial, sizeof(initial));

    auto start = std::chrono::steady_clock::now();

    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:pipeline];
    [enc setBuffer:defs_buf offset:0 atIndex:0];
    [enc setBuffer:def_rbag_buf offset:0 atIndex:1];
    [enc setBuffer:def_nodes_buf offset:0 atIndex:2];
    [enc setBuffer:node_buf offset:0 atIndex:3];
    [enc setBuffer:vars_buf offset:0 atIndex:4];
    [enc setBuffer:rbag_buf offset:0 atIndex:5];
    [enc setBuffer:state_buf offset:0 atIndex:6];

    MTLSize grid = MTLSizeMake(1, 1, 1);
    MTLSize tpg = MTLSizeMake(1, 1, 1);
    [enc dispatchThreads:grid threadsPerThreadgroup:tpg];
    [enc endEncoding];

    [cmd commit];
    [cmd waitUntilCompleted];

    if (cmd.error) {
      std::fprintf(stderr, "Metal runtime command failure: %s\n", [[cmd.error localizedDescription] UTF8String]);
      return;
    }

    auto end = std::chrono::steady_clock::now();
    double duration = std::chrono::duration<double>(end - start).count();

    RuntimeState state{};
    std::memcpy(&state, [state_buf contents], sizeof(state));

    if (state.error != ERR_NONE) {
      std::fprintf(
        stderr,
        "Metal runtime error: %s (code %u, step %u)\n",
        metal_error_message(state.error),
        state.error,
        state.steps
      );
      return;
    }

    auto* nodes = static_cast<Pair*>([node_buf contents]);
    auto* vars = static_cast<Port*>([vars_buf contents]);

    Port result = host_enter(&state, vars, ROOT);

    std::printf("Result: ");
    pretty_print_port(&state, book, nodes, vars, result);
    std::printf("\n");

    std::printf("- ITRS: %llu\n", static_cast<unsigned long long>(state.itrs));
    std::printf("- TIME: %.2fs\n", duration);

    double mips = duration > 0.0 ? (double(state.itrs) / duration / 1000000.0) : 0.0;
    std::printf("- MIPS: %.2f\n", mips);
  }
}
