//! Proves the vendored merz renderer compiles and runs inside tmd's build:
//! a Mermaid block, tmd's test font, out comes a PNG. The real wiring (finding
//! ```mermaid blocks and showing the image) comes next.
const std = @import("std");
const build_options = @import("build_options");
const files = @import("layout").files;
const merz = @import("merz");

test "tmd renders a mermaid block to a PNG via merz" {
    const gpa = std.testing.allocator;
    const path = try gpa.allocSentinel(u8, build_options.test_font.len, 0);
    defer gpa.free(path);
    @memcpy(path, build_options.test_font);
    const font = try files.read(gpa, path.ptr, 8 * 1024 * 1024);
    defer gpa.free(font);

    const png = try merz.renderPng(gpa, "flowchart TD\n A[Start] --> B((End))", font);
    defer gpa.free(png);

    try std.testing.expect(png.len > 100);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }, png[0..8]);
}
