// Wrapper so `zig translate-c` sees size_t/stdint before stb_truetype's
// declarations. No implementation is pulled in — only the decls and structs.
#include <stddef.h>
#include <stdint.h>
#include "stb_truetype.h"
