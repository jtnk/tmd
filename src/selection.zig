//! Selecting rendered text in the preview. A selection is a range of cells in the layout's rows,
//! and copying turns those cells back into the text they came from: wrapped lines become one line
//! again, and what only decorates a row is left out.
const std = @import("std");
const md = @import("md.zig");
const width = @import("width.zig");

pub const Point = struct { row: u32, col: u32 };

pub const Selection = struct {
    anchor: Point,
    head: Point,

    fn ordered(self: Selection) [2]Point {
        const a = self.anchor;
        const h = self.head;
        return if (a.row < h.row or (a.row == h.row and a.col <= h.col)) .{ a, h } else .{ h, a };
    }

    /// The selected cells of a row, as first and one past the last, or null if there are none.
    pub fn cells(self: Selection, row: u32) ?[2]u32 {
        const ends = self.ordered();
        if (row < ends[0].row or row > ends[1].row) return null;
        return .{
            if (row == ends[0].row) ends[0].col else 0,
            if (row == ends[1].row) ends[1].col + 1 else std.math.maxInt(u32),
        };
    }

    /// Appends the selected text to out.
    pub fn text(self: Selection, gpa: std.mem.Allocator, l: *const md.Layout, out: *std.ArrayList(u8)) !void {
        const ends = self.ordered();
        const start = out.items.len;
        var row = ends[0].row;
        while (row <= ends[1].row and row < l.rows.items.len) : (row += 1) {
            const r = l.rows.items[row];
            if (r.image != 0) {
                // A large heading is pixels, but the layout kept its words.
                const words = headingAt(l, row) orelse continue;
                if (out.items.len > start) try out.append(gpa, '\n');
                try appendClean(gpa, out, words);
                continue;
            }
            if (out.items.len > start) switch (r.join) {
                .none => try out.append(gpa, '\n'),
                .space => try out.append(gpa, ' '),
                .tight => {},
            };
            const range = self.cells(row).?;
            const code = !(r.fill.kind == .role and r.fill.value == 0);
            const first = if (r.join != .none or code) @max(range[0], r.lead) else range[0];
            var col: u32 = 0;
            for (l.rowSpans(r)) |s| {
                const i = cellOffset(s.text, first -| col);
                // A selection can end inside what's left out at the start of a row.
                const j = @max(i, cellOffset(s.text, range[1] -| col));
                if (!md.isLinkMark(s.text)) try appendClean(gpa, out, s.text[i..j]);
                col += s.width;
            }
            // Padding that fills out a table cell or the end of a row isn't text.
            while (out.items.len > start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        }
        while (out.items.len > start and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    }
};

fn headingAt(l: *const md.Layout, row: u32) ?[]const u8 {
    for (l.headings.items) |h| {
        if (h.row == row and h.text.len > 0) return h.text;
    }
    return null;
}

/// Where in s a run of the given number of cells ends.
pub fn cellOffset(s: []const u8, cells_wanted: u32) usize {
    var i: usize = 0;
    var w: u32 = 0;
    while (i < s.len and w < cells_wanted) {
        const c = width.next(s[i..]);
        w += c.width;
        i += c.len;
    }
    return i;
}

/// Copies s without what the screen would never show as itself. Control characters appear as a dot,
/// so letting them through would paste something other than what was selected.
fn appendClean(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const n = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1;
            continue;
        };
        if (i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            i += 1;
            continue;
        }
        const control = c < 0x20 or c == 0x7f or (c == 0xc2 and s[i + 1] < 0xa0);
        if (!control) try out.appendSlice(gpa, s[i .. i + n]);
        i += n;
    }
}

const testing = std.testing;

fn expectCopy(source: []const u8, w: u16, from: Point, to: Point, want: []const u8) !void {
    var l = try md.layout(testing.allocator, source, .{ .width = w });
    defer l.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try (Selection{ .anchor = from, .head = to }).text(testing.allocator, &l, &out);
    try testing.expectEqualStrings(want, out.items);
}

const all_of = Point{ .row = 100, .col = 100 };
const top = Point{ .row = 0, .col = 0 };

test "wrapped lines copy as the line they were" {
    try expectCopy("one two three four five six\n\nnext\n", 10, top, all_of, "one two three four five six\n\nnext");
}

test "words split by the width join without a space" {
    try expectCopy("abcdefghijklmnopqrstuvwxyz\n", 10, top, all_of, "abcdefghijklmnopqrstuvwxyz");
    try expectCopy("你好世界你好世界\n", 8, top, all_of, "你好世界你好世界");
}

test "a selection can start and end inside a row, in either direction" {
    try expectCopy("hello world\n", 40, .{ .row = 0, .col = 3 }, .{ .row = 0, .col = 7 }, "lo wo");
    try expectCopy("hello world\n", 40, .{ .row = 0, .col = 7 }, .{ .row = 0, .col = 3 }, "lo wo");
    try expectCopy("你好世界\n", 40, .{ .row = 0, .col = 2 }, .{ .row = 0, .col = 5 }, "好世");
}

test "code copies without its padding, and long lines stay whole" {
    try expectCopy("```\nfn main() {\n  body\n}\n```\n", 40, top, all_of, "fn main() {\n  body\n}");
    try expectCopy("```\nabcdefghijklmnopqrstuvwxyz\n```\n", 12, top, all_of, "abcdefghijklmnopqrstuvwxyz");
}

test "terminal output copies without its padding, even split over rows" {
    try expectCopy("```ansi\n\x1b[31mabcdefghijklmnopqrstuvwxyz\x1b[0m\n```\n", 12, top, all_of, "abcdefghijklmnopqrstuvwxyz");
}

test "continuation lines lose their quote bar and list indent" {
    try expectCopy("> one two three four five\n", 12, top, all_of, "▌ one two three four five");
    try expectCopy("- one two three four five\n", 12, top, all_of, "• one two three four five");
}

test "the arrow on a link stays out of what's copied" {
    var l = try md.layout(testing.allocator, "see [site](https://a.io) now\n", .{ .width = 40, .link_marks = true });
    defer l.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try (Selection{ .anchor = top, .head = all_of }).text(testing.allocator, &l, &out);
    try testing.expectEqualStrings("see site now", out.items);
}

test "a selection can end in the decoration of a wrapped row" {
    try expectCopy("> one two three four five\n", 12, .{ .row = 0, .col = 2 }, .{ .row = 1, .col = 0 }, "one two");
    try expectCopy("- one two three four five\n", 12, .{ .row = 0, .col = 2 }, .{ .row = 1, .col = 1 }, "one two");
}

test "control characters never reach the clipboard" {
    try expectCopy("a\x07b\x1b[2Jc\u{9b}31md\n", 40, top, all_of, "ab[2Jc31md");
}
