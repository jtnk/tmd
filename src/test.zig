const std = @import("std");
test {
    _ = @import("width.zig");
    _ = @import("input.zig");
    _ = @import("inline.zig");
    _ = @import("md.zig");
    _ = @import("theme.zig");
    _ = @import("selection.zig");
}
test {
    _ = @import("tidy.zig");
    _ = @import("files.zig");
    _ = @import("fetch.zig");
    _ = @import("complete.zig");
    _ = @import("editor.zig");
    _ = @import("images.zig");
}
test {
    _ = @import("app.zig");
    _ = @import("term.zig");
}
test {
    _ = @import("e2e.zig");
}
