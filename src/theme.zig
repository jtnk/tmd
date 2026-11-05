//! Colors and text styles. Layout stores roles, not colors, so changing the palette only repaints.
const std = @import("std");
const files = @import("files.zig");

pub const Role = enum(u8) { none, text, heading, muted, dim, link, code, code_bg, bg, accent };

/// A role, a 256-color index, or a direct color.
pub const Color = packed struct(u32) {
    value: u24 = 0,
    kind: enum(u8) { role, index, rgb } = .role,

    pub const none: Color = role(.none);
    pub fn role(r: Role) Color {
        return .{ .value = @intFromEnum(r) };
    }
    pub fn index(i: u8) Color {
        return .{ .value = i, .kind = .index };
    }
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .value = (@as(u24, r) << 16) | (@as(u24, g) << 8) | b, .kind = .rgb };
    }
};

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    reverse: bool = false,
    _pad: u2 = 0,
};

pub const Style = struct {
    fg: Color = Color.role(.text),
    bg: Color = Color.none,
    attrs: Attrs = .{},

    pub fn eql(a: Style, b: Style) bool {
        return @as(u32, @bitCast(a.fg)) == @as(u32, @bitCast(b.fg)) and
            @as(u32, @bitCast(a.bg)) == @as(u32, @bitCast(b.bg)) and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }
};

pub const Palette = struct {
    name: []const u8,
    /// null means the terminal's own colors.
    rgb: ?[9]u24,
    pub const bg = 0;
};

// The eight fixed palettes are mmd's:   bg        text      heading   muted     dim       link      code      code bg   accent
const builtin_palettes = [_]Palette{
    .{ .name = "system", .rgb = null },
    .{ .name = "dracula", .rgb = .{ 0x282A36, 0xF8F8F2, 0xBD93F9, 0x8C98C4, 0x6272A4, 0x8BE9FD, 0x50FA7B, 0x383A4A, 0xFFB86C } },
    .{ .name = "nord", .rgb = .{ 0x2E3440, 0xD8DEE9, 0x88C0D0, 0x8F9AB0, 0x616E88, 0x81A1C1, 0xA3BE8C, 0x3B4252, 0xEBCB8B } },
    .{ .name = "gruvbox", .rgb = .{ 0x282828, 0xEBDBB2, 0xFABD2F, 0xA89984, 0x7C6F64, 0x83A598, 0xB8BB26, 0x3C3836, 0xFE8019 } },
    .{ .name = "tokyo-night", .rgb = .{ 0x1A1B26, 0xC0CAF5, 0xBB9AF7, 0x8990B3, 0x565F89, 0x7AA2F7, 0x9ECE6A, 0x24283B, 0xFF9E64 } },
    .{ .name = "catppuccin", .rgb = .{ 0x1E1E2E, 0xCDD6F4, 0xCBA6F7, 0x9399B2, 0x6C7086, 0x89B4FA, 0xA6E3A1, 0x313244, 0xFAB387 } },
    .{ .name = "solarized-dark", .rgb = .{ 0x002B36, 0x93A1A1, 0xB58900, 0x839496, 0x586E75, 0x268BD2, 0x2AA198, 0x073642, 0xCB4B16 } },
    .{ .name = "solarized-light", .rgb = .{ 0xFDF6E3, 0x586E75, 0xCB4B16, 0x839496, 0x93A1A1, 0x268BD2, 0x859900, 0xEEE8D5, 0xB58900 } },
    .{ .name = "one-light", .rgb = .{ 0xFAFAFA, 0x383A42, 0xA626A4, 0x696C77, 0xA0A1A7, 0x4078F2, 0x50A14F, 0xECECED, 0xC18401 } },
};

/// The built-in palettes, then the user's.
pub var palettes: []const Palette = &builtin_palettes;

pub fn find(name: []const u8) ?usize {
    for (palettes, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
    return null;
}

/// In the order of Palette.rgb.
const color_keys = [_][]const u8{ "bg", "text", "heading", "muted", "dim", "link", "code", "code_bg", "accent" };

/// Why a theme file was refused.
pub const Problem = struct { line: u32, what: []const u8 };

/// What's left of a config line once its comment is gone. A # only starts a comment at the start of
/// a line or after a space, and a color's # never comes after one once the key's value has begun.
pub fn stripComment(line: []const u8) []const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len > 0 and t[0] == '#') return "";
    const eq_at = std.mem.indexOfScalar(u8, t, '=') orelse return t;
    var i = eq_at + 1;
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
    while (i + 1 < t.len) : (i += 1) {
        if ((t[i] == ' ' or t[i] == '\t') and t[i + 1] == '#') return std.mem.trimEnd(u8, t[0..i], " \t");
    }
    return t;
}

fn parseColor(s: []const u8) ?u24 {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 6) return null;
    return std.fmt.parseInt(u24, hex, 16) catch null;
}

/// Reads a theme: colors by role, and the palette the rest come from. The file's name is the theme's.
pub fn parse(name: []const u8, text: []const u8, problem: *Problem) ?Palette {
    var base: [9]u24 = builtin_palettes[1].rgb.?;
    var set: [9]?u24 = @splat(null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = stripComment(raw);
        if (line.len == 0) continue;
        const eq_at = std.mem.indexOfScalar(u8, line, '=') orelse {
            problem.* = .{ .line = n, .what = "expected key = value" };
            return null;
        };
        const key = std.mem.trim(u8, line[0..eq_at], " \t");
        const val = std.mem.trim(u8, line[eq_at + 1 ..], " \t");
        if (std.mem.eql(u8, key, "base")) {
            const from = for (builtin_palettes) |p| {
                if (std.mem.eql(u8, p.name, val)) break p;
            } else {
                problem.* = .{ .line = n, .what = "unknown base palette" };
                return null;
            };
            base = from.rgb orelse {
                problem.* = .{ .line = n, .what = "base can't be system, which has no colors of its own" };
                return null;
            };
            continue;
        }
        const role = for (color_keys, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) break i;
        } else {
            problem.* = .{ .line = n, .what = "unknown color name" };
            return null;
        };
        set[role] = parseColor(val) orelse {
            problem.* = .{ .line = n, .what = "colors look like #ff79c6" };
            return null;
        };
    }
    for (set, 0..) |v, i| if (v) |c| {
        base[i] = c;
    };
    return .{ .name = name, .rgb = base };
}

/// Adds every .theme file in a directory to the palettes, in name order. A file with a built-in's
/// name replaces it. Returns a message for the first file that was refused.
pub fn loadDir(gpa: std.mem.Allocator, dir: [:0]const u8) !?[]const u8 {
    const d = std.c.opendir(dir.ptr) orelse return null;
    defer _ = std.c.closedir(d);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    while (std.c.readdir(d)) |e| {
        const entry = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.name)), 0);
        if (entry.len > ".theme".len and std.mem.endsWith(u8, entry, ".theme")) try names.append(gpa, try gpa.dupe(u8, entry));
    }
    std.sort.insertion([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    var all: std.ArrayList(Palette) = .empty;
    try all.appendSlice(gpa, &builtin_palettes);
    var first_problem: ?[]const u8 = null;
    for (names.items) |file| {
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, file }, 0);
        defer gpa.free(path);
        const text = files.read(gpa, path.ptr, 64 * 1024) catch continue;
        defer gpa.free(text);
        var problem: Problem = .{ .line = 0, .what = "" };
        const p = parse(file[0 .. file.len - ".theme".len], text, &problem) orelse {
            if (first_problem == null) first_problem = try std.fmt.allocPrint(gpa, "{s} line {d}: {s}", .{ file, problem.line, problem.what });
            continue;
        };
        for (all.items) |*have| {
            if (std.mem.eql(u8, have.name, p.name)) {
                have.* = p;
                break;
            }
        } else try all.append(gpa, p);
    }
    palettes = all.items;
    return first_problem;
}

pub const Theme = struct {
    palette: usize = 0,
    /// Whether the terminal's background is light, for the one system color that must be chosen.
    light: bool = false,
    /// false writes no escape sequences at all (for pipes).
    color: bool = true,

    /// The base style of a row: the palette's background, or the terminal default.
    pub fn base(self: Theme) Style {
        return .{ .bg = if (palettes[self.palette].rgb != null) Color.role(.bg) else Color.none };
    }

    fn writeColor(self: Theme, out: *std.ArrayList(u8), gpa: std.mem.Allocator, c: Color, bg: bool, attrs: *Attrs) !void {
        var buf: [32]u8 = undefined;
        const lead: u8 = if (bg) '4' else '3';
        const s: []const u8 = switch (c.kind) {
            .index => try std.fmt.bufPrint(&buf, ";{c}8;5;{d}", .{ lead, c.value }),
            .rgb => try rgbSeq(&buf, lead, c.value),
            .role => r: {
                const role: Role = @enumFromInt(c.value);
                if (role == .none) return;
                if (palettes[self.palette].rgb) |p| {
                    const v = switch (role) {
                        .bg => p[0],
                        .text => p[1],
                        .heading => p[2],
                        .muted => p[3],
                        .dim => p[4],
                        .link => p[5],
                        .code => p[6],
                        .code_bg => p[7],
                        .accent => p[8],
                        .none => unreachable,
                    };
                    break :r try rgbSeq(&buf, lead, v);
                }
                // The terminal's own 16 colors: whatever theme the user runs carries through.
                switch (role) {
                    .text, .bg, .none => return,
                    .muted, .dim => {
                        attrs.faint = true;
                        return;
                    },
                    .heading => break :r if (bg) ";105" else ";95",
                    .link => break :r if (bg) ";104" else ";94",
                    .code => break :r if (bg) ";106" else ";36",
                    .accent => break :r if (bg) ";43" else ";33",
                    .code_bg => break :r if (self.light) ";48;5;254" else ";48;5;236",
                }
            },
        };
        try out.appendSlice(gpa, s);
    }

    /// Appends the SGR that replaces every attribute with s.
    pub fn sgr(self: Theme, out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: Style) !void {
        if (!self.color) return;
        try out.appendSlice(gpa, "\x1b[0");
        var a = s.attrs;
        try self.writeColor(out, gpa, s.fg, false, &a);
        try self.writeColor(out, gpa, s.bg, true, &a);
        if (a.bold) try out.appendSlice(gpa, ";1");
        if (a.faint) try out.appendSlice(gpa, ";2");
        if (a.italic) try out.appendSlice(gpa, ";3");
        if (a.underline) try out.appendSlice(gpa, ";4");
        if (a.reverse) try out.appendSlice(gpa, ";7");
        if (a.strike) try out.appendSlice(gpa, ";9");
        try out.append(gpa, 'm');
    }
};

/// ;38;2;r;g;b, or ;48 with a lead of '4'. This runs for every change of color on every painted row.
fn rgbSeq(buf: []u8, lead: u8, v: u24) ![]const u8 {
    buf[0..6].* = ";08;2;".*;
    buf[1] = lead;
    var n: usize = 6;
    for ([_]u8{ @intCast(v >> 16), @intCast((v >> 8) & 255), @intCast(v & 255) }, 0..) |c, i| {
        if (i > 0) {
            buf[n] = ';';
            n += 1;
        }
        if (c >= 100) {
            buf[n] = '0' + c / 100;
            n += 1;
        }
        if (c >= 10) {
            buf[n] = '0' + c / 10 % 10;
            n += 1;
        }
        buf[n] = '0' + c % 10;
        n += 1;
    }
    return buf[0..n];
}

const testing = std.testing;

fn expectTheme(text: []const u8) !Palette {
    var problem: Problem = .{ .line = 0, .what = "" };
    return parse("mine", text, &problem) orelse error.Refused;
}

fn expectProblem(text: []const u8, line: u32) !void {
    var problem: Problem = .{ .line = 0, .what = "" };
    try testing.expect(parse("mine", text, &problem) == null);
    try testing.expectEqual(line, problem.line);
}

test "color sequences" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(";38;2;255;121;198", try rgbSeq(&buf, '3', 0xff79c6));
    try testing.expectEqualStrings(";48;2;0;9;10", try rgbSeq(&buf, '4', 0x00090a));
    try testing.expectEqualStrings(";38;2;100;99;0", try rgbSeq(&buf, '3', 0x646300));
}

test "a theme sets what it names, and the rest comes from its base" {
    const nord = builtin_palettes[find("nord").?].rgb.?;
    const p = try expectTheme("# pinker\nbase = nord\n\nlink = #ff79c6   # links\ncode_bg=112233\n");
    try testing.expectEqualStrings("mine", p.name);
    try testing.expectEqual(@as(u24, 0xff79c6), p.rgb.?[5]);
    try testing.expectEqual(@as(u24, 0x112233), p.rgb.?[7]);
    try testing.expectEqual(nord[0], p.rgb.?[0]);
    try testing.expectEqual(nord[2], p.rgb.?[2]);
    // base can come after the colors, and an empty theme is a copy of dracula.
    try testing.expectEqual(@as(u24, 0xff79c6), (try expectTheme("link = #ff79c6\nbase = nord\n")).rgb.?[5]);
    try testing.expectEqual(builtin_palettes[1].rgb.?, (try expectTheme("")).rgb.?);
}

test "a broken theme says which line" {
    try expectProblem("link = #ff\n", 1);
    try expectProblem("base = nord\nlnik = #ff79c6\n", 2);
    try expectProblem("# ok\n\nnonsense\n", 3);
    try expectProblem("base = nope\n", 1);
    try expectProblem("base = system\n", 1);
    try expectProblem("link = #gggggg\n", 1);
}

test "comments come off config lines, and colors and paths stay whole" {
    try testing.expectEqualStrings("palette = nord", stripComment("palette = nord          # system, dracula"));
    try testing.expectEqualStrings("link = #ff79c6", stripComment("  link = #ff79c6  "));
    try testing.expectEqualStrings("heading_font = /a b/c#d.ttf", stripComment("heading_font = /a b/c#d.ttf"));
    try testing.expectEqualStrings("", stripComment("  # width = 100"));
}
