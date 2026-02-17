#include <metal_stdlib>
using namespace metal;

// Placeholder kernel for Metal backend bring-up.
// The functional evaluator is currently routed through the C runtime shim.
kernel void hvm_noop(device uint *data [[buffer(0)]], uint id [[thread_position_in_grid]]) {
  if (id == 0) {
    data[0] = data[0];
  }
}
