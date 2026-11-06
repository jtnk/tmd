//! Layout and what it depends on. This is a module of its own so that it can be built for speed
//! while the rest of tmd is built for size: see build.zig.
pub const md = @import("md.zig");
pub const inl = @import("inline.zig");
pub const width = @import("width.zig");
pub const theme = @import("theme.zig");
pub const files = @import("files.zig");

test {
    _ = md;
    _ = inl;
    _ = width;
    _ = theme;
    _ = files;
}
