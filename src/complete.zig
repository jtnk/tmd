//! Path completion for the Open prompt.
const std = @import("std");
const c = std.c;
const files = @import("layout").files;
const md = @import("layout").md;

pub const Result = struct {
    /// What the prompt should now say.
    text: []u8,
    /// The choices left, when there's more than one.
    hint: []u8,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.hint);
    }
};

/// The folder to list for what's typed so far, with ~ expanded.
fn folder(a: std.mem.Allocator, typed_dir: []const u8) ![:0]u8 {
    if (typed_dir.len == 0) return a.dupeSentinel(u8, ".", 0);
    if (std.mem.startsWith(u8, typed_dir, "~/")) {
        if (c.getenv("HOME")) |h| return std.fmt.allocPrintSentinel(a, "{s}{s}", .{ std.mem.span(h), typed_dir[1..] }, 0);
    }
    return a.dupeSentinel(u8, typed_dir, 0);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// Completes a path as far as it's certain, or returns null if nothing matches.
pub fn path(gpa: std.mem.Allocator, typed: []const u8) !?Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cut = if (std.mem.lastIndexOfScalar(u8, typed, '/')) |i| i + 1 else 0;
    const typed_dir = typed[0..cut];
    const prefix = typed[cut..];
    const dir = try folder(a, typed_dir);

    const d = c.opendir(dir.ptr) orelse return null;
    defer _ = c.closedir(d);
    var names: std.ArrayList([]const u8) = .empty;
    while (c.readdir(d)) |e| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.name)), 0);
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
        const full = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
        // Folders show their slash, and files that tmd can't show aren't worth offering.
        const is_dir = files.isFolder(full.ptr);
        if (!is_dir and !md.isMarkdown(name)) continue;
        try names.append(a, if (is_dir) try std.fmt.allocPrint(a, "{s}/", .{name}) else try a.dupe(u8, name));
    }
    if (names.items.len == 0) return null;
    std.sort.insertion([]const u8, names.items, {}, lessThan);

    var common = names.items[0];
    for (names.items[1..]) |n| common = common[0..std.mem.indexOfDiff(u8, common, n) orelse common.len];

    const text = try std.fmt.allocPrint(gpa, "{s}{s}", .{ typed_dir, common });
    errdefer gpa.free(text);
    const hint = if (names.items.len > 1) try std.mem.join(gpa, "  ", names.items) else try gpa.dupe(u8, "");
    return .{ .text = text, .hint = hint };
}

const testing = std.testing;

fn expectComplete(typed: []const u8, want: []const u8, choices: bool) !void {
    const r = (try path(testing.allocator, typed)).?;
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(want, r.text);
    try testing.expectEqual(choices, r.hint.len > 0);
}

test "completion goes as far as it's certain" {
    try expectComplete("testd", "testdata/", false);
    try expectComplete("testdata/01", "testdata/01-text.md", false);
    try expectComplete("testdata/0", "testdata/0", true);
    try expectComplete("testdata/no", "testdata/notes/", false);
}

test "completion offers folders and Markdown, and hides dotfiles until asked" {
    const r = (try path(testing.allocator, "testdata/images/")) orelse return;
    defer r.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, r.hint, "hero.svg") == null);
    try testing.expectEqual(@as(?Result, null), try path(testing.allocator, "testdata/nothing-like-this"));
    try testing.expectEqual(@as(?Result, null), try path(testing.allocator, "/no/such/folder/x"));
    // .gitignore isn't Markdown, but .zig-cache/ is a folder: dotted names appear once typed.
    try expectComplete(".zig-c", ".zig-cache/", false);
    const top = (try path(testing.allocator, "")).?;
    defer top.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, top.hint, ".zig-cache") == null);
}
