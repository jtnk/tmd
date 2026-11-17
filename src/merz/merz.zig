//! Vendored from the merz project (../merz): a native Mermaid flowchart
//! renderer. tmd uses it to turn a ```mermaid code block into a PNG, passing in
//! its own font bytes. Keep src/merz/*.zig and vendor/stb.c, stbtt_decl.h,
//! stb_image_write.h in sync with upstream merz; local changes: stripped unit
//! tests, and it builds against tmd's existing vendor/stb_truetype.h (v1.26)
//! rather than merz's own copy.
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
