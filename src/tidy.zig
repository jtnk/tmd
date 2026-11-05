//! Conservative whitespace tidy, the same rules as mmd: trims trailing spaces (keeping two-space hard
//! breaks), collapses runs of blank lines, puts blank lines around headings, and ends with one
//! newline. Code blocks are left alone.
const std = @import("std");

pub fn run(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in_fence = false;
    var prev_heading = false;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        const lead = std.mem.trimStart(u8, raw, " ");
        const fence = std.mem.startsWith(u8, lead, "```") or std.mem.startsWith(u8, lead, "~~~");
        if (in_fence) {
            try out.appendSlice(gpa, raw);
            try out.append(gpa, '\n');
            if (fence) in_fence = false;
            continue;
        }
        const hard_break = std.mem.endsWith(u8, raw, "  ");
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) {
            if (out.items.len > 0 and !endsBlank(out.items)) try out.append(gpa, '\n');
            prev_heading = false;
            continue;
        }
        const heading = isHeading(lead);
        if ((heading or prev_heading) and out.items.len > 0 and !endsBlank(out.items)) try out.append(gpa, '\n');
        try out.appendSlice(gpa, line);
        if (hard_break) try out.appendSlice(gpa, "  ");
        try out.append(gpa, '\n');
        if (fence) in_fence = true;
        prev_heading = heading;
    }
    while (out.items.len >= 2 and std.mem.endsWith(u8, out.items, "\n\n")) out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

fn endsBlank(s: []const u8) bool {
    return std.mem.endsWith(u8, s, "\n\n") or std.mem.eql(u8, s, "\n");
}

fn isHeading(l: []const u8) bool {
    var n: usize = 0;
    while (n < l.len and l[n] == '#') n += 1;
    return n >= 1 and n <= 6 and (n == l.len or l[n] == ' ');
}

test "tidy" {
    const t = std.testing;
    const cases = [_][2][]const u8{
        .{ "a  \nb   x  \n", "a  \nb   x  \n" },
        .{ "a \t\n\n\n\nb\n\n\n", "a\n\nb\n" },
        .{ "text\n# H\nmore\n", "text\n\n# H\n\nmore\n" },
        .{ "```\n  x  \n\n\n```\n", "```\n  x  \n\n\n```\n" },
        .{ "", "" },
    };
    for (cases) |c| {
        const got = try run(t.allocator, c[0]);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c[1], got);
    }
}
