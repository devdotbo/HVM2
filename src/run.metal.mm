#include <cstdint>
#include <cstdio>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

extern "C" void hvm_c(const uint32_t* book_buffer) __attribute__((weak_import));

extern "C" void hvm_mtl(const uint32_t* book_buffer) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      std::fprintf(stderr, "Metal runtime not available!\\n No Metal-compatible device was found.\\n");
      return;
    }

    if (!hvm_c) {
      std::fprintf(stderr, "Metal runtime build is incomplete!\\n C runtime fallback is unavailable.\\n");
      return;
    }

    // Temporary execution path: preserve HVM output contract by reusing the C runtime.
    // This keeps `Result:` and stats formatting stable while Metal bring-up evolves.
    hvm_c(book_buffer);
  }
}
