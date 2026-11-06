// The C libraries tmd links: stb_image (JPEG, GIF, BMP, and PNG when it must be measured), nanosvg,
// and stb_truetype for large headings. PNG data itself goes to the terminal undecoded.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <sys/stat.h>

#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_PSD
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_NO_TGA
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "stb_truetype.h"

#define NANOSVG_IMPLEMENTATION
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvg.h"
#include "nanosvgrast.h"

int tm_info(const unsigned char *data, int len, int *w, int *h) {
    int comp;
    return stbi_info_from_memory(data, len, w, h, &comp);
}

unsigned char *tm_decode(const unsigned char *data, int len, int *w, int *h) {
    int comp;
    return stbi_load_from_memory(data, len, w, h, &comp, 4);
}

void tm_free(void *p) { free(p); }

// svg must be NUL-terminated and writable (nanosvg parses in place).
int tm_svg_size(char *svg, int *w, int *h) {
    NSVGimage *img = nsvgParse(svg, "px", 96.0f);
    if (!img) return 0;
    *w = (int)ceilf(img->width);
    *h = (int)ceilf(img->height);
    nsvgDelete(img);
    return *w > 0 && *h > 0;
}

// Rasterizes to RGBA at width out_w, keeping the aspect ratio.
unsigned char *tm_svg_render(char *svg, int out_w, int *w, int *h) {
    NSVGimage *img = nsvgParse(svg, "px", 96.0f);
    if (!img || img->width <= 0 || img->height <= 0) { if (img) nsvgDelete(img); return NULL; }
    float scale = (float)out_w / img->width;
    int ow = out_w, oh = (int)ceilf(img->height * scale);
    unsigned char *px = malloc((size_t)ow * oh * 4);
    NSVGrasterizer *r = nsvgCreateRasterizer();
    if (px && r) nsvgRasterize(r, img, 0, 0, scale, px, ow, oh, ow * 4);
    if (r) nsvgDeleteRasterizer(r);
    nsvgDelete(img);
    *w = ow; *h = oh;
    return px;
}

// The permission bits of a file, or -1.
int tm_file_mode(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 ? (int)(st.st_mode & 07777) : -1;
}

// Whether a path is an ordinary file, and not a device, pipe or folder.
int tm_is_regular(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static stbtt_fontinfo font;

// Kerning between ASCII characters, by codepoint. Looking a pair up in the font is slow, and a
// document's headings use the same few pairs again and again. 0x7fff means not looked up yet.
#define KERN_FIRST 32
#define KERN_COUNT 95
#define KERN_UNKNOWN 0x7fff
static short kern_pairs[KERN_COUNT][KERN_COUNT];

// data must stay valid. Returns 0 if it isn't a usable font.
int tm_font_load(const unsigned char *data) {
    int offset = stbtt_GetFontOffsetForIndex(data, 0);
    if (offset < 0 || !stbtt_InitFont(&font, data, offset)) return 0;
    for (int i = 0; i < KERN_COUNT; i++)
        for (int j = 0; j < KERN_COUNT; j++) kern_pairs[i][j] = KERN_UNKNOWN;
    return 1;
}

static int kern(int cp1, int glyph1, int cp2, int glyph2) {
    int a = cp1 - KERN_FIRST, b = cp2 - KERN_FIRST;
    if (a < 0 || a >= KERN_COUNT || b < 0 || b >= KERN_COUNT) return stbtt_GetGlyphKernAdvance(&font, glyph1, glyph2);
    if (kern_pairs[a][b] == KERN_UNKNOWN) {
        int k = stbtt_GetGlyphKernAdvance(&font, glyph1, glyph2);
        if (k == KERN_UNKNOWN || k != (short)k) return k;
        kern_pairs[a][b] = (short)k;
    }
    return kern_pairs[a][b];
}

// Width in pixels of a run of codepoints, or -1 if the font lacks one of them.
int tm_text_width(const int *cps, int n, float px) {
    float scale = stbtt_ScaleForPixelHeight(&font, px), x = 0;
    // The codepoint calls would each look their glyphs up again, four times a character.
    int glyph = n > 0 ? stbtt_FindGlyphIndex(&font, cps[0]) : 0;
    for (int i = 0; i < n; i++) {
        if (cps[i] != ' ' && glyph == 0) return -1;
        int advance, bearing;
        stbtt_GetGlyphHMetrics(&font, glyph, &advance, &bearing);
        x += advance * scale;
        if (i + 1 < n) {
            int next = stbtt_FindGlyphIndex(&font, cps[i + 1]);
            if (font.kern || font.gpos) x += scale * kern(cps[i], glyph, cps[i + 1], next);
            glyph = next;
        }
    }
    return (int)ceilf(x) + 1;
}

// Draws text into a w x h coverage map, vertically centered.
void tm_text_render(const int *cps, int n, float px, unsigned char *out, int w, int h) {
    float scale = stbtt_ScaleForPixelHeight(&font, px), x = 0;
    int ascent, descent, gap;
    stbtt_GetFontVMetrics(&font, &ascent, &descent, &gap);
    int baseline = (int)((h - (ascent - descent) * scale) / 2 + ascent * scale);
    for (int i = 0; i < n; i++) {
        int advance, bearing, x0, y0, x1, y1;
        stbtt_GetCodepointHMetrics(&font, cps[i], &advance, &bearing);
        float shift = x - floorf(x);
        stbtt_GetCodepointBitmapBoxSubpixel(&font, cps[i], scale, scale, shift, 0, &x0, &y0, &x1, &y1);
        int gw = x1 - x0, gh = y1 - y0;
        if (gw > 0 && gh > 0) {
            unsigned char *glyph = malloc((size_t)gw * gh);
            if (glyph) {
                stbtt_MakeCodepointBitmapSubpixel(&font, glyph, gw, gh, gw, scale, scale, shift, 0, cps[i]);
                for (int y = 0; y < gh; y++) {
                    int oy = baseline + y0 + y;
                    if (oy < 0 || oy >= h) continue;
                    for (int gx = 0; gx < gw; gx++) {
                        int ox = (int)x + x0 + gx;
                        if (ox < 0 || ox >= w) continue;
                        unsigned char v = glyph[y * gw + gx];
                        if (v > out[oy * w + ox]) out[oy * w + ox] = v;
                    }
                }
                free(glyph);
            }
        }
        x += advance * scale;
        if (i + 1 < n) x += scale * stbtt_GetCodepointKernAdvance(&font, cps[i], cps[i + 1]);
    }
}
