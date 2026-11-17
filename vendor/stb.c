// Compiles the stb single-header implementations and exposes a couple of small
// helpers to Zig. stb_truetype's declarations are pulled into Zig via @cImport;
// here we only need the implementations plus a to-memory PNG encoder.
#include <stdlib.h>

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

// Encode tightly-packed RGBA (stride = w*4) to a PNG in a malloc'd buffer.
// Returns the buffer and sets *out_len; caller frees with merz_free.
unsigned char *merz_encode_png(const unsigned char *rgba, int w, int h, int *out_len) {
    return stbi_write_png_to_mem(rgba, w * 4, w, h, 4, out_len);
}

void merz_free(void *p) {
    free(p);
}
