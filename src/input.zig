//! Decodes what the terminal sends: keys (legacy and the kitty protocol), SGR mouse, bracketed paste
//! and the replies to tmd's startup queries. Reads may split a sequence anywhere.
const std = @import("std");

pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    _pad: u5 = 0,

    pub fn none(m: Mods) bool {
        return !m.shift and !m.alt and !m.ctrl;
    }
};

/// Above Unicode, so a key is one number.
pub const Key = struct {
    pub const up: u21 = 0x110001;
    pub const down: u21 = 0x110002;
    pub const left: u21 = 0x110003;
    pub const right: u21 = 0x110004;
    pub const home: u21 = 0x110005;
    pub const end: u21 = 0x110006;
    pub const page_up: u21 = 0x110007;
    pub const page_down: u21 = 0x110008;
    pub const insert: u21 = 0x110009;
    pub const delete: u21 = 0x11000A;
    pub const f1: u21 = 0x110010; // f1 + n - 1
    pub const enter: u21 = 13;
    pub const tab: u21 = 9;
    pub const backspace: u21 = 127;
    pub const escape: u21 = 27;
};

pub const Mouse = struct {
    pub const Button = enum { left, middle, right, wheel_up, wheel_down, none };
    button: Button,
    x: u16,
    y: u16,
    press: bool,
    motion: bool,
    mods: Mods,
};

pub const Event = union(enum) {
    key: struct { code: u21, mods: Mods = .{} },
    mouse: Mouse,
    paste: []const u8,
    focus: bool,
    /// Reply to the kitty graphics query: was it accepted?
    graphics: bool,
    /// Primary device attributes: always the last reply to the startup queries.
    device_attrs,
    /// XTVERSION, such as "ghostty 1.4.0".
    version: []const u8,
    /// DECRPM: mode and its state (0 means the terminal doesn't know it).
    mode: struct { mode: u16, state: u16 },
    /// Kitty keyboard protocol supported.
    kitty_keys,
    /// OSC 11: the background color, 8 bits per channel.
    background: [3]u8,
    /// CSI 16 t: cell size in pixels.
    cell_size: struct { w: u16, h: u16 },
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    /// Paste bytes are held here so a paste event can outlive the next read.
    paste: std.ArrayList(u8) = .empty,
    in_paste: bool = false,

    pub fn deinit(self: *Decoder) void {
        self.buf.deinit(self.gpa);
        self.paste.deinit(self.gpa);
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        if (self.pos > 0) {
            const rest = self.buf.items.len - self.pos;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.pos..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.pos = 0;
        }
        try self.buf.appendSlice(self.gpa, bytes);
    }

    /// A lone ESC is only a key once no more bytes arrive after it.
    pub fn pendingEscape(self: *const Decoder) bool {
        return !self.in_paste and self.pos < self.buf.items.len and self.buf.items[self.pos] == 0x1b;
    }

    /// Call when input has gone quiet: whatever is left starting with ESC is an Escape press.
    pub fn timeout(self: *Decoder) ?Event {
        if (!self.pendingEscape()) return null;
        self.pos += 1;
        return .{ .key = .{ .code = Key.escape } };
    }

    /// The next complete event, or null if more bytes are needed.
    pub fn next(self: *Decoder) std.mem.Allocator.Error!?Event {
        while (true) {
            const s = self.buf.items[self.pos..];
            if (s.len == 0) return null;
            if (self.in_paste) {
                const end = "\x1b[201~";
                if (std.mem.indexOf(u8, s, end)) |i| {
                    try self.paste.appendSlice(self.gpa, s[0..i]);
                    self.pos += i + end.len;
                    self.in_paste = false;
                    return .{ .paste = self.paste.items };
                }
                // Keep a possible partial terminator for the next read.
                const keep = @min(s.len, end.len - 1);
                try self.paste.appendSlice(self.gpa, s[0 .. s.len - keep]);
                self.pos += s.len - keep;
                return null;
            }
            if (s[0] != 0x1b) return self.plain(s);
            if (s.len == 1) return null;
            switch (s[1]) {
                '[' => {
                    var i: usize = 2;
                    while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) : (i += 1) {
                        // A stray ESC inside means the sequence was broken off.
                        if (s[i] == 0x1b) {
                            self.pos += i;
                            break;
                        }
                    } else {
                        if (i >= s.len) return null;
                        self.pos += i + 1;
                        if (try self.csi(s[2..i], s[i])) |e| return e;
                    }
                    continue;
                },
                'O' => {
                    if (s.len < 3) return null;
                    self.pos += 3;
                    const code: ?u21 = switch (s[2]) {
                        'A' => Key.up,
                        'B' => Key.down,
                        'C' => Key.right,
                        'D' => Key.left,
                        'H' => Key.home,
                        'F' => Key.end,
                        'P'...'S' => Key.f1 + (s[2] - 'P'),
                        else => null,
                    };
                    if (code) |c| return .{ .key = .{ .code = c } };
                    continue;
                },
                'P', '_', ']' => {
                    // String sequences end at ST (ESC \) or, for OSC, BEL.
                    var i: usize = 2;
                    const end: ?usize = while (i < s.len) : (i += 1) {
                        if (s[i] == 0x07) break i;
                        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') break i;
                    } else null;
                    const stop = end orelse return null;
                    const body = s[2..stop];
                    const kind = s[1];
                    self.pos += stop + (if (s[stop] == 0x07) @as(usize, 1) else 2);
                    if (stringReply(kind, body)) |e| return e;
                    continue;
                },
                else => {
                    // Alt+key.
                    self.pos += 1;
                    var e = (try self.plain(self.buf.items[self.pos..])) orelse return null;
                    e.key.mods.alt = true;
                    return e;
                },
            }
        }
    }

    fn plain(self: *Decoder, s: []const u8) std.mem.Allocator.Error!?Event {
        const c = s[0];
        if (c < 0x80) {
            self.pos += 1;
            return .{ .key = switch (c) {
                9, 13, 27 => .{ .code = c },
                10 => .{ .code = 'j', .mods = .{ .ctrl = true } },
                8, 127 => .{ .code = Key.backspace },
                0 => .{ .code = ' ', .mods = .{ .ctrl = true } },
                1...7, 11, 12, 14...26 => .{ .code = 'a' + c - 1, .mods = .{ .ctrl = true } },
                28...31 => .{ .code = '\\' + c - 28, .mods = .{ .ctrl = true } },
                else => .{ .code = c },
            } };
        }
        const l = std.unicode.utf8ByteSequenceLength(c) catch {
            self.pos += 1;
            return self.next();
        };
        if (s.len < l) return null;
        self.pos += l;
        const cp = std.unicode.utf8Decode(s[0..l]) catch return self.next();
        return .{ .key = .{ .code = cp } };
    }

    fn csi(self: *Decoder, params: []const u8, final: u8) !?Event {
        if (params.len > 0 and params[0] == '<' and (final == 'M' or final == 'm')) return mouse(params[1..], final == 'M');
        if (params.len > 0 and params[0] == '?') {
            if (final == 'c') return .device_attrs;
            if (final == 'u') return .kitty_keys;
            if (final == 'y') {
                var it = Params.init(params[1..]);
                const m = it.next(0);
                return .{ .mode = .{ .mode = m, .state = it.next(0) } };
            }
            return null;
        }
        var it = Params.init(params);
        const first = it.next(1);
        const mods = decodeMods(it.next(1));
        switch (final) {
            'A' => return key(Key.up, mods),
            'B' => return key(Key.down, mods),
            'C' => return key(Key.right, mods),
            'D' => return key(Key.left, mods),
            'H' => return key(Key.home, mods),
            'F' => return key(Key.end, mods),
            'P'...'S' => return key(Key.f1 + (final - 'P'), mods),
            'Z' => return key(Key.tab, .{ .shift = true }),
            'I' => return .{ .focus = true },
            'O' => return .{ .focus = false },
            'u' => return key(switch (first) {
                57399...57408 => first - 57399 + '0', // keypad digits
                57414 => Key.enter,
                8 => Key.backspace,
                else => first,
            }, mods),
            't' => if (first == 6) return .{ .cell_size = .{ .h = param(params, 1), .w = param(params, 2) } },
            '~' => {
                if (first == 200) {
                    self.in_paste = true;
                    self.paste.clearRetainingCapacity();
                    return null;
                }
                const code: ?u21 = switch (first) {
                    1, 7 => Key.home,
                    2 => Key.insert,
                    3 => Key.delete,
                    4, 8 => Key.end,
                    5 => Key.page_up,
                    6 => Key.page_down,
                    11...15 => Key.f1 + (first - 11),
                    17...21 => Key.f1 + 5 + (first - 17),
                    23, 24 => Key.f1 + 10 + (first - 23),
                    else => null,
                };
                if (code) |c| return key(c, mods);
            },
            else => {},
        }
        return null;
    }
};

fn key(code: u21, mods: Mods) Event {
    return .{ .key = .{ .code = code, .mods = mods } };
}

fn decodeMods(v: u16) Mods {
    const m = if (v > 0) v - 1 else 0;
    return .{ .shift = m & 1 != 0, .alt = m & 2 != 0, .ctrl = m & 4 != 0 };
}

fn param(params: []const u8, n: usize) u16 {
    var it = Params.init(params);
    var i: usize = 0;
    while (i < n) : (i += 1) _ = it.next(0);
    return it.next(0);
}

/// Semicolon-separated numbers. A colon's subparameters (kitty's event type) are skipped.
const Params = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    fn init(s: []const u8) Params {
        return .{ .it = std.mem.splitScalar(u8, s, ';') };
    }

    fn next(self: *Params, default: u16) u16 {
        const p = self.it.next() orelse return default;
        const head = if (std.mem.indexOfScalar(u8, p, ':')) |c| p[0..c] else p;
        return std.fmt.parseInt(u16, head, 10) catch default;
    }
};

fn mouse(params: []const u8, press: bool) ?Event {
    var it = Params.init(params);
    const b = it.next(0);
    const x = it.next(1);
    const y = it.next(1);
    const button: Mouse.Button = if (b & 64 != 0)
        (if (b & 1 != 0) .wheel_down else .wheel_up)
    else switch (b & 3) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };
    return .{ .mouse = .{
        .button = button,
        .x = x -| 1,
        .y = y -| 1,
        .press = press,
        .motion = b & 32 != 0,
        .mods = .{ .shift = b & 4 != 0, .alt = b & 8 != 0, .ctrl = b & 16 != 0 },
    } };
}

fn stringReply(kind: u8, body: []const u8) ?Event {
    switch (kind) {
        '_' => if (body.len > 0 and body[0] == 'G') {
            return .{ .graphics = std.mem.indexOf(u8, body, ";OK") != null };
        },
        'P' => if (std.mem.startsWith(u8, body, ">|")) return .{ .version = body[2..] },
        ']' => if (std.mem.startsWith(u8, body, "11;rgb:")) {
            var it = std.mem.splitScalar(u8, body[7..], '/');
            var rgb: [3]u8 = undefined;
            for (&rgb) |*c| {
                const h = it.next() orelse return null;
                if (h.len == 0 or h.len > 4) return null;
                const v = std.fmt.parseInt(u16, h, 16) catch return null;
                // Scale from however many digits the terminal chose down to 8 bits.
                const bits: u4 = @intCast(h.len * 4 - 1);
                c.* = if (h.len >= 2) @intCast(v >> (bits - 7)) else @intCast(v * 17);
            }
            return .{ .background = rgb };
        },
        else => {},
    }
    return null;
}

const testing = std.testing;

fn one(d: *Decoder, bytes: []const u8) !?Event {
    try d.feed(bytes);
    return d.next();
}

test "keys, split reads and replies" {
    var d = Decoder{ .gpa = testing.allocator };
    defer d.deinit();
    try testing.expectEqual(@as(u21, 'q'), (try one(&d, "q")).?.key.code);
    try testing.expectEqual(@as(u21, 's'), (try one(&d, "\x13")).?.key.code);
    try testing.expectEqual(Key.up, (try one(&d, "\x1b[A")).?.key.code);
    try testing.expect((try one(&d, "\x1b[1;")) == null);
    const e = (try one(&d, "5C")).?;
    try testing.expectEqual(Key.right, e.key.code);
    try testing.expect(e.key.mods.ctrl);
    const k = (try one(&d, "\x1b[105;5u")).?;
    try testing.expectEqual(@as(u21, 'i'), k.key.code);
    try testing.expect(k.key.mods.ctrl);
    try testing.expect((try one(&d, "\x1b")) == null);
    try testing.expectEqual(Key.escape, d.timeout().?.key.code);
    try testing.expectEqual(@as(u21, 0x4f60), (try one(&d, "你")).?.key.code);
    const m = (try one(&d, "\x1b[<0;10;5M")).?.mouse;
    try testing.expectEqual(@as(u16, 9), m.x);
    try testing.expectEqual(Mouse.Button.wheel_down, (try one(&d, "\x1b[<65;1;1M")).?.mouse.button);
    try testing.expect((try one(&d, "\x1b_Gi=31;OK\x1b\\")).?.graphics);
    try testing.expectEqualStrings("ghostty 1.4.0", (try one(&d, "\x1bP>|ghostty 1.4.0\x1b\\")).?.version);
    try testing.expectEqual(@as(u16, 2027), (try one(&d, "\x1b[?2027;2$y")).?.mode.mode);
    try testing.expectEqual(@as(u8, 0x28), (try one(&d, "\x1b]11;rgb:2828/2a2a/3636\x1b\\")).?.background[0]);
    try testing.expectEqual(@as(u16, 20), (try one(&d, "\x1b[6;20;10t")).?.cell_size.h);
}

test "bracketed paste across reads" {
    var d = Decoder{ .gpa = testing.allocator };
    defer d.deinit();
    try testing.expect((try one(&d, "\x1b[200~hello")) == null);
    try testing.expectEqualStrings("hello world", (try one(&d, " world\x1b[201~")).?.paste);
}
