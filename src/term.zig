//! The real terminal: raw mode, the capability probe, and putting everything back on every way out.
const std = @import("std");
const c = std.c;
const input = @import("input.zig");
const images = @import("images.zig");

pub const Caps = struct {
    images: images.Mode = .off,
    grapheme: bool = false,
    kitty_keys: bool = false,
    light: bool = false,
    cell_w: u32 = 0,
    cell_h: u32 = 0,
    tmux: bool = false,
    /// Rex: it holds at most 10MB of images per block.
    rex: bool = false,
};

const enter_seq =
    "\x1b[?1049h" ++ // alternate screen
    "\x1b[?7l" ++ // no autowrap: the last column is safe to write
    "\x1b[?25l" ++ // no cursor until there's something to edit
    "\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h" ++ // mouse, with drags and hover, in SGR form
    "\x1b[?2004h"; // bracketed paste

const leave_seq =
    "\x1b[0 q" ++
    "\x1b[?2004l" ++
    "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l" ++
    "\x1b[?25h" ++
    "\x1b[?7h" ++
    "\x1b[0m" ++
    "\x1b[?1049l";

// Module state, because signal handlers have nothing else to reach.
var in_fd: c.fd_t = 0;
var out_fd: c.fd_t = 1;
var saved: c.termios = undefined;
var active: bool = false;
var kitty_keys: bool = false;
var grapheme_set: bool = false;
/// Sequences to run on exit that delete uploaded images.
var cleanup: []const u8 = "";

pub var resized = std.atomic.Value(bool).init(false);
pub var resumed = std.atomic.Value(bool).init(false);

fn writeRaw(bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(out_fd, bytes[i..].ptr, bytes.len - i);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n < 0 and std.posix.errno(n) == .AGAIN) {
                var p = [_]c.pollfd{.{ .fd = out_fd, .events = c.POLL.OUT, .revents = 0 }};
                _ = c.poll(&p, 1, 1000);
                continue;
            }
            return;
        }
        i += @intCast(n);
    }
}

pub fn write(bytes: []const u8) void {
    writeRaw(bytes);
}

pub fn open() !void {
    // stdin may be the document, so the terminal itself is always the input.
    in_fd = if (c.isatty(0) != 0) 0 else c.open("/dev/tty", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (in_fd < 0) return error.NoTerminal;
    out_fd = 1;
    if (c.tcgetattr(in_fd, &saved) != 0) return error.NoTerminal;
}

fn rawMode() void {
    var t = saved;
    t.iflag.BRKINT = false;
    t.iflag.ICRNL = false;
    t.iflag.INPCK = false;
    t.iflag.ISTRIP = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.cflag.CSIZE = .CS8;
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    t.lflag.IEXTEN = false;
    t.lflag.ISIG = false;
    t.cc[@intFromEnum(c.V.MIN)] = 0;
    t.cc[@intFromEnum(c.V.TIME)] = 0;
    _ = c.tcsetattr(in_fd, .FLUSH, &t);
}

/// Asks the terminal what it can do. Every terminal answers primary device attributes, which comes
/// last, so the wait ends as soon as the answers are in rather than at the timeout.
pub fn probe(gpa: std.mem.Allocator) !Caps {
    var caps = Caps{};
    rawMode();
    defer _ = c.tcsetattr(in_fd, .FLUSH, &saved);

    caps.tmux = c.getenv("TMUX") != null;
    const graphics = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";
    const version = "\x1b[>q";
    var q: std.ArrayList(u8) = .empty;
    defer q.deinit(gpa);
    if (caps.tmux) {
        // tmux answers XTVERSION itself and swallows graphics, so ask the terminal behind it.
        try q.appendSlice(gpa, "\x1bPtmux;\x1b\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\x1b\\\x1b\\");
        try q.appendSlice(gpa, "\x1bPtmux;\x1b\x1b[>q\x1b\\");
    } else {
        try q.appendSlice(gpa, graphics);
        try q.appendSlice(gpa, version);
    }
    try q.appendSlice(gpa, "\x1b[?2027$p\x1b[?u\x1b]11;?\x1b\\\x1b[16t\x1b[c");
    writeRaw(q.items);

    var graphics_ok = false;
    var placeholders = false;
    var dec = input.Decoder{ .gpa = gpa };
    defer dec.deinit();
    const deadline = @import("trace.zig").now() + 250 * std.time.ns_per_ms;
    var done = false;
    while (!done) {
        const t = @import("trace.zig").now();
        if (t >= deadline) break;
        var p = [_]c.pollfd{.{ .fd = in_fd, .events = c.POLL.IN, .revents = 0 }};
        const left: c_int = @intCast((deadline - t) / std.time.ns_per_ms + 1);
        if (c.poll(&p, 1, left) <= 0) continue;
        var buf: [512]u8 = undefined;
        const n = c.read(in_fd, &buf, buf.len);
        if (n <= 0) continue;
        try dec.feed(buf[0..@intCast(n)]);
        while (try dec.next()) |e| switch (e) {
            .graphics => |ok| graphics_ok = ok,
            .version => |v| {
                placeholders = isPlaceholderTerminal(v);
                caps.rex = std.ascii.startsWithIgnoreCase(v, "rex");
            },
            .mode => |m| if (m.mode == 2027) {
                caps.grapheme = m.state != 0 and m.state != 4;
            },
            .kitty_keys => caps.kitty_keys = true,
            .background => |bg| {
                const luma = @as(u32, bg[0]) * 3 + @as(u32, bg[1]) * 6 + bg[2];
                caps.light = luma > 1280;
            },
            .cell_size => |s| {
                caps.cell_w = s.w;
                caps.cell_h = s.h;
            },
            .device_attrs => done = true,
            else => {},
        };
    }

    // Some terminals report 0 pixels here, so the ioctl only fills in what the query didn't.
    if (caps.cell_w == 0) {
        if (cellPixels()) |cell| {
            caps.cell_w = cell.w;
            caps.cell_h = cell.h;
        }
    }

    if (!placeholders) {
        if (envIs("TERM", "xterm-kitty") or envIs("TERM", "xterm-ghostty") or envIs("TERM_PROGRAM", "ghostty")) placeholders = true;
    }
    if (graphics_ok or placeholders) {
        // tmux can only carry placeholders, since it owns the grid.
        caps.images = if (placeholders) .placeholder else if (caps.tmux) .off else .direct;
    }
    if (c.getenv("TMD_IMAGES")) |v| {
        const s = std.mem.span(v);
        if (std.mem.eql(u8, s, "off")) caps.images = .off;
        if (std.mem.eql(u8, s, "direct")) caps.images = .direct;
        if (std.mem.eql(u8, s, "placeholder")) caps.images = .placeholder;
    }
    return caps;
}

fn envIs(name: [*:0]const u8, value: []const u8) bool {
    const v = c.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(v), value);
}

fn isPlaceholderTerminal(version: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(version, "ghostty") or
        std.ascii.startsWithIgnoreCase(version, "kitty") or
        std.ascii.startsWithIgnoreCase(version, "rex");
}

fn getSize(ws: *std.posix.winsize) bool {
    return c.ioctl(out_fd, std.posix.T.IOCGWINSZ, @intFromPtr(ws)) == 0 or
        c.ioctl(in_fd, std.posix.T.IOCGWINSZ, @intFromPtr(ws)) == 0;
}

/// The cell size in device pixels, if the terminal gives one. A pane that has just opened may not
/// yet, and may answer the query in probe with defaults, so this is read again after a resize.
pub fn cellPixels() ?struct { w: u32, h: u32 } {
    var ws: std.posix.winsize = undefined;
    if (!getSize(&ws) or ws.col == 0 or ws.row == 0) return null;
    const w = ws.xpixel / ws.col;
    const h = ws.ypixel / ws.row;
    return if (w > 0 and h > 0) .{ .w = w, .h = h } else null;
}

pub fn size() struct { cols: u16, rows: u16 } {
    var ws: std.posix.winsize = undefined;
    if (getSize(&ws) and ws.col > 0 and ws.row > 0) return .{ .cols = ws.col, .rows = ws.row };
    return .{ .cols = 80, .rows = 24 };
}

pub fn enter(caps: Caps) void {
    kitty_keys = caps.kitty_keys;
    grapheme_set = caps.grapheme;
    rawMode();
    writeRaw(enter_seq);
    if (caps.grapheme) writeRaw("\x1b[?2027h");
    // Tells Esc apart from sequences, and Ctrl+I from Tab.
    if (caps.kitty_keys) writeRaw("\x1b[>1u");
    active = true;
}

/// Undoes enter. Safe in a signal handler, and safe to call twice.
pub fn leave() void {
    if (!active) return;
    active = false;
    writeRaw(cleanup);
    if (kitty_keys) writeRaw("\x1b[<u");
    if (grapheme_set) writeRaw("\x1b[?2027l");
    writeRaw(leave_seq);
    _ = c.tcsetattr(in_fd, .FLUSH, &saved);
}

/// Bytes for leave to send, such as deleting images. Must stay valid.
pub fn setCleanup(bytes: []const u8) void {
    cleanup = bytes;
}

pub fn suspendSelf(caps: Caps) void {
    leave();
    _ = c.raise(.STOP);
    enter(caps);
    resumed.store(true, .release);
}

fn onFatal(sig: c.SIG) callconv(.c) void {
    leave();
    var act = std.mem.zeroes(c.Sigaction);
    act.handler = .{ .handler = c.SIG.DFL };
    _ = c.sigaction(sig, &act, null);
    _ = c.raise(sig);
}

fn onResize(_: c.SIG) callconv(.c) void {
    resized.store(true, .release);
}

fn onContinue(_: c.SIG) callconv(.c) void {
    resumed.store(true, .release);
}

pub fn installSignals() void {
    var act = std.mem.zeroes(c.Sigaction);
    act.handler = .{ .handler = onFatal };
    for ([_]c.SIG{ .TERM, .HUP, .INT, .QUIT, .SEGV, .ABRT, .BUS, .ILL, .FPE }) |s| _ = c.sigaction(s, &act, null);
    act.handler = .{ .handler = onResize };
    _ = c.sigaction(.WINCH, &act, null);
    act.handler = .{ .handler = onContinue };
    _ = c.sigaction(.CONT, &act, null);
    // A closed pipe surfaces as a failed write instead of killing the process.
    act.handler = .{ .handler = c.SIG.IGN };
    _ = c.sigaction(.PIPE, &act, null);
    // Links open in children nobody waits for.
    _ = c.sigaction(.CHLD, &act, null);
}

/// Waits up to timeout_ms for input. Returns bytes read, 0 on timeout or a signal.
pub fn read(buf: []u8, timeout_ms: i32) usize {
    var p = [_]c.pollfd{.{ .fd = in_fd, .events = c.POLL.IN, .revents = 0 }};
    if (c.poll(&p, 1, timeout_ms) <= 0) return 0;
    const n = c.read(in_fd, buf.ptr, buf.len);
    return if (n > 0) @intCast(n) else 0;
}
