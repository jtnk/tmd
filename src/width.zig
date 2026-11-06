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
    // Most clusters are one codepoint, so decode only as far as the answer needs. graphemeWidth
    // reads forward and stops at the first break: if that's before the end of what it was given,
    // decoding more can't change it.
    var want: usize = if (grapheme_mode) 2 else 1;
    while (true) {
        var whole = i >= s.len;
        while (i < s.len and n < want) {
            const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const cp: u21 = if (i + l <= s.len and l > 1)
                std.unicode.utf8Decode(s[i .. i + l]) catch 0xFFFD
            else if (s[i] < 0x80) s[i] else 0xFFFD;
            // A control character is always a cluster of its own. The grapheme rules would join
            // one to a Prepend character before it, and code checking for control characters looks
            // at the start of a cluster: an escape sequence could ride through the screen inside one.
            if (n > 0 and isControl(cp)) {
                whole = true;
                break;
            }
            i += if (i + l <= s.len) l else 1;
            cps[n] = cp;
            ends[n] = @intCast(i);
            n += 1;
            if (isControl(cp)) {
                whole = true;
                break;
            }
        }
        if (!grapheme_mode) return .{ .len = ends[0], .width = @intCast(vt.unicode.codepointWidth(cps[0])) };
        const g = vt.unicode.graphemeWidth(u21, cps[0..n]);
        if (g.len < n or whole or i >= s.len or n == cps.len) {
            return .{ .len = ends[g.len - 1], .width = @intCast(g.width) };
        }
        want = @min(want * 2, cps.len);
    }
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

/// next as it would be with nothing to stop it early: all that the cluster could reach, decoded first.
fn nextAll(s: []const u8) Cluster {
    var cps: [24]u21 = undefined;
    var ends: [24]u32 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < cps.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const cp: u21 = if (i + l <= s.len and l > 1)
            std.unicode.utf8Decode(s[i .. i + l]) catch 0xFFFD
        else if (s[i] < 0x80) s[i] else 0xFFFD;
        if (n > 0 and isControl(cp)) break;
        i += if (i + l <= s.len) l else 1;
        cps[n] = cp;
        ends[n] = @intCast(i);
        n += 1;
        if (isControl(cp)) break;
    }
    const g = vt.unicode.graphemeWidth(u21, cps[0..n]);
    return .{ .len = ends[g.len - 1], .width = @intCast(g.width) };
}

test "decoding only what a cluster needs changes nothing" {
    const pieces = [_][]const u8{
        "a",        " ",        "\x1b",     "\xff",     "\xe2\x94", "─",        "你",       "é",
        "e\u{301}", "\u{301}",  "\u{200D}", "\u{FE0F}", "\u{FE0E}", "\u{0600}", "👩",       "💻",
        "🏳",       "🌈",       "🇺",        "🇸",        "ᄀ",        "ᅡ",        "ᆨ",        "क",
        "्",        "\u{1F3FB}", "\u{9b}",   "#",         "\u{20E3}",
    };
    var prng = std.Random.DefaultPrng.init(0x7a11);
    const r = prng.random();
    var buf: [256]u8 = undefined;
    for (0..200_000) |_| {
        var n: usize = 0;
        for (0..r.intRangeAtMost(usize, 1, 40)) |_| {
            const p = pieces[r.uintLessThan(usize, pieces.len)];
            if (n + p.len > buf.len) break;
            @memcpy(buf[n..][0..p.len], p);
            n += p.len;
        }
        // next answers plain ASCII before it decodes anything, as it always has.
        if (buf[0] < 0x80 and (n == 1 or buf[1] < 0x80)) continue;
        const want = nextAll(buf[0..n]);
        const got = next(buf[0..n]);
        try std.testing.expectEqual(want.len, got.len);
        try std.testing.expectEqual(want.width, got.width);
    }
}

test "a cluster longer than the first look still comes back whole" {
    // A family: seven codepoints, one cell pair.
    const family = "👨‍👩‍👧‍👦x";
    try std.testing.expectEqual(@as(u32, family.len - 1), next(family).len);
    try std.testing.expectEqual(@as(u8, 2), next(family).width);
    // Past the 24 codepoints a cluster is looked at, as before.
    var marks: [81]u8 = undefined;
    marks[0] = 'e';
    for (0..40) |i| @memcpy(marks[1 + i * 2 ..][0..2], "\u{301}");
    try std.testing.expectEqual(@as(u32, 1 + 23 * 2), next(&marks).len);
}

test "widths match the terminal" {
    try std.testing.expectEqual(@as(u32, 5), of("hello"));
    try std.testing.expectEqual(@as(u32, 4), of("你好"));
    try std.testing.expectEqual(@as(u32, 2), of("🏳️‍🌈"));
    try std.testing.expectEqual(@as(u32, 2), of("👩‍💻"));
    try std.testing.expectEqual(@as(u32, 5), of("café!"));
    try std.testing.expectEqual(@as(u32, 1), of("e\u{301}"));
}
