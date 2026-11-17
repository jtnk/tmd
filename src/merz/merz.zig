//! Vendored from merz (https://github.com/jtnk/merz), a native Mermaid
//! flowchart renderer. tmd uses it to turn a ```mermaid code block into a PNG,
//! passing in its own font bytes.
//!
//! Pinned to merz commit 3908ae0. Refresh with `tools/sync-merz.sh <merz-checkout>`,
//! which copies src/merz/{model,parser,layout,raster}.zig and the vendor/ stb
//! glue. Deliberate local deltas: raster.zig's unit tests are dropped (they
//! embed merz's own font, which tmd supplies at the call site), and the whole
//! thing builds against tmd's shared vendor/stb_truetype.h (v1.26) rather than
//! merz's newer copy. This facade and vendor/stb_truetype.h are tmd's own; the
//! sync script never touches them.
const std = @import("std");

pub const model = @import("model.zig");
pub const parser = @import("parser.zig");
pub const layout = @import("layout.zig");
pub const raster = @import("raster.zig");

pub const Graph = model.Graph;
pub const Bounds = layout.Bounds;
pub const parse = parser.parse;

/// Render Mermaid source to a PNG using the given TrueType font bytes.
/// Caller owns the returned slice. Returns parser.Error / raster.Error.
pub fn renderPng(gpa: std.mem.Allocator, src: []const u8, font_bytes: []const u8) ![]u8 {
    var g = try parser.parse(gpa, src);
    defer g.deinit();
    const bounds = try layout.layout(gpa, &g);
    return raster.renderPng(gpa, &g, bounds, font_bytes);
}
