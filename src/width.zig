//! Cell widths from Ghostty's own tables, so layout agrees with the terminal about every emoji,
//! combining mark and CJK character.
const std = @import("std");
const vt = @import("ghostty-vt");

/// True when the terminal clusters graphemes (mode 2027). Otherwise a ZWJ sequence is several cells
/// wide, and width is the sum of its codepoints.
pub var grapheme_mode: bool = true;

pub const Cluster = struct { len: u32, width: u8 };

/// The first grapheme cluster of s, which must not be empty.
pub fn next(s: []const u8) Cluster {
    const c = s[0];
    if (c < 0x80 and (s.len == 1 or s[1] < 0x80)) {
        return .{ .len = 1, .width = if (c < 0x20 or c == 0x7f) 0 else 1 };
    }
    var cps: [24]u21 = undefined;
    var ends: [24]u32 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < cps.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const cp: u21 = if (i + l <= s.len and l > 1)
            std.unicode.utf8Decode(s[i .. i + l]) catch 0xFFFD
        else if (s[i] < 0x80) s[i] else 0xFFFD;
        // A control character is always a cluster of its own. The grapheme rules would join one to
        // a Prepend character before it, and code checking for control characters looks at the
        // start of a cluster: an escape sequence could ride through the screen inside one.
        if (n > 0 and isControl(cp)) break;
        i += if (i + l <= s.len) l else 1;
        cps[n] = cp;
        ends[n] = @intCast(i);
        n += 1;
        if (isControl(cp)) break;
    }
    if (grapheme_mode) {
        const g = vt.unicode.graphemeWidth(u21, cps[0..n]);
        return .{ .len = ends[g.len - 1], .width = @intCast(g.width) };
    }
    return .{ .len = ends[0], .width = @intCast(vt.unicode.codepointWidth(cps[0])) };
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp < 0xa0);
}

/// Total cell width of s.
pub fn of(s: []const u8) u32 {
    var w: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        // Plain ASCII dominates real documents, and needs no tables.
        if (s[i] >= 0x20 and s[i] < 0x7f and (i + 1 == s.len or s[i + 1] < 0x80)) {
            w += 1;
            i += 1;
            continue;
        }
        const c = next(s[i..]);
        w += c.width;
        i += c.len;
    }
    return w;
}

test "control characters are never part of a cluster" {
    try std.testing.expectEqual(@as(u32, 2), next("\u{0600}\x1b]52;c;x").len);
    try std.testing.expectEqual(@as(u32, 2), next("\u{0600}\u{9b}31m").len);
    try std.testing.expectEqual(@as(u32, 1), next("\x1b\u{301}").len);
    try std.testing.expectEqual(@as(u32, 2), next("\u{9b}\u{301}").len);
}

test "widths match the terminal" {
    try std.testing.expectEqual(@as(u32, 5), of("hello"));
    try std.testing.expectEqual(@as(u32, 4), of("你好"));
    try std.testing.expectEqual(@as(u32, 2), of("🏳️‍🌈"));
    try std.testing.expectEqual(@as(u32, 2), of("👩‍💻"));
    try std.testing.expectEqual(@as(u32, 5), of("café!"));
    try std.testing.expectEqual(@as(u32, 1), of("e\u{301}"));
}
