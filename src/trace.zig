//! Spans and percentiles: every operation is timed into a small ring per span, which feeds the HUD,
//! the benchmark and the session report. A second ring keeps the last frames whole, so a bad moment
//! can be written out and looked at afterwards.
const std = @import("std");

pub const Span = enum { load, layout, paint, flush, input, edit, find, image, frame };

/// Frame rates to measure against. A target is met when the p99 frame fits its budget.
pub const fps_targets = [_]u32{ 60, 120, 240, 480, 540, 600, 720, 1000 };

pub fn fpsBudgetUs(fps: u32) u32 {
    return 1_000_000 / fps;
}

/// The highest target a p99 frame time meets, or 0.
pub fn bestFps(p99_us: u32) u32 {
    var best: u32 = 0;
    for (fps_targets) |t| {
        if (p99_us <= fpsBudgetUs(t)) best = t;
    }
    return best;
}

/// A frame slower than this misses 60 fps.
pub const slow_us = 16_700;

const ring_size = 4096;

const Ring = struct {
    us: [ring_size]u32 = undefined,
    n: u64 = 0,

    fn add(self: *Ring, v: u32) void {
        self.us[self.n % ring_size] = v;
        self.n += 1;
    }

    fn slice(self: *const Ring) []const u32 {
        return self.us[0..@min(self.n, ring_size)];
    }
};

const span_count = std.enums.values(Span).len;

var rings: [span_count]Ring = @splat(.{});

/// What set a frame off. Only ever the kind of thing: which keys were pressed stays out of a log
/// that's meant to be shared.
pub const Cause = enum(u8) { none, key, mouse, paste, resize, other };

const Frame = struct {
    /// Since the first frame.
    at_ms: u32,
    /// Time in each span since the frame before.
    us: [span_count]u32,
    bytes: u32,
    rows: u32,
    cause: Cause,
};

const log_size = 1024;

var log: [log_size]Frame = undefined;
var log_n: u64 = 0;
var log_start: u64 = 0;
var since_frame: [span_count]u32 = @splat(0);

pub fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Records the time since t0 (from now()). Returns it in microseconds.
pub fn end(span: Span, t0: u64) u32 {
    const us: u32 = @intCast(@min((now() - t0) / 1000, std.math.maxInt(u32)));
    rings[@intFromEnum(span)].add(us);
    since_frame[@intFromEnum(span)] +|= us;
    return us;
}

/// Closes a frame in the log, with everything timed since the last one. This runs every frame, so
/// it's only a copy into memory that's already there.
pub fn record(cause: Cause, rows: u32, bytes: usize) void {
    const t = now();
    if (log_n == 0) log_start = t;
    log[log_n % log_size] = .{
        .at_ms = @intCast(@min((t - log_start) / std.time.ns_per_ms, std.math.maxInt(u32))),
        .us = since_frame,
        .bytes = @intCast(@min(bytes, std.math.maxInt(u32))),
        .rows = rows,
        .cause = cause,
    };
    log_n += 1;
    since_frame = @splat(0);
}

/// Forgets what was timed since the last frame, for a frame that doesn't count.
pub fn skipFrame() void {
    since_frame = @splat(0);
}

fn logged(i: u64) *const Frame {
    return &log[i % log_size];
}

fn firstLogged() u64 {
    return log_n -| log_size;
}

/// Frames drawn in the last second.
pub fn drawnFps() u32 {
    if (log_n == 0) return 0;
    const at: u64 = (now() - log_start) / std.time.ns_per_ms;
    var n: u32 = 0;
    var i = log_n;
    while (i > firstLogged()) : (i -= 1) {
        if (@as(u64, logged(i - 1).at_ms) + 1000 < at) break;
        n += 1;
    }
    return n;
}

/// Frames in the log that missed 60 fps.
pub fn slowFrames() u32 {
    var n: u32 = 0;
    var i = firstLogged();
    while (i < log_n) : (i += 1) {
        if (logged(i).us[@intFromEnum(Span.frame)] > slow_us) n += 1;
    }
    return n;
}

/// The logged frames as a Markdown table, oldest first, with the slow ones in bold.
pub fn frameLog(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, "| At ms | Cause | Frame ms | Input | Edit | Find | Layout | Paint | Flush | Image | Rows | Bytes |\n|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|\n");
    var i = firstLogged();
    while (i < log_n) : (i += 1) {
        const f = logged(i);
        const u = struct {
            fn at(fr: *const Frame, s: Span) Fixed {
                return ms(fr.us[@intFromEnum(s)], 2);
            }
        }.at;
        const mark: []const u8 = if (f.us[@intFromEnum(Span.frame)] > slow_us) "**" else "";
        var buf: [192]u8 = undefined;
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "| {d} | {s} | {s}{f}{s} | {f} | {f} | {f} | {f} | {f} | {f} | {f} | {d} | {d} |\n", .{ f.at_ms, @tagName(f.cause), mark, u(f, .frame), mark, u(f, .input), u(f, .edit), u(f, .find), u(f, .layout), u(f, .paint), u(f, .flush), u(f, .image), f.rows, f.bytes }));
    }
}

pub fn reset() void {
    for (&rings) |*r| r.n = 0;
}

/// Forgets one span, such as the frames of startup, which say nothing about steady state.
pub fn clear(span: Span) void {
    rings[@intFromEnum(span)].n = 0;
}

pub const Stats = struct { n: u64, p50: u32, p95: u32, p99: u32, max: u32 };

pub fn stats(span: Span) Stats {
    const r = &rings[@intFromEnum(span)];
    var sorted: [ring_size]u32 = undefined;
    const s = r.slice();
    if (s.len == 0) return .{ .n = 0, .p50 = 0, .p95 = 0, .p99 = 0, .max = 0 };
    @memcpy(sorted[0..s.len], s);
    std.mem.sort(u32, sorted[0..s.len], {}, std.sort.asc(u32));
    const at = struct {
        fn f(v: []const u32, p: usize) u32 {
            return v[@min(v.len - 1, v.len * p / 100)];
        }
    }.f;
    return .{ .n = r.n, .p50 = at(sorted[0..s.len], 50), .p95 = at(sorted[0..s.len], 95), .p99 = at(sorted[0..s.len], 99), .max = sorted[s.len - 1] };
}

/// p50 and p99 of the last n values, so the HUD follows what's happening now.
pub fn recentStats(span: Span, comptime n: usize) struct { p50: u32, p99: u32 } {
    var vals: [n]u32 = undefined;
    const v = recent(span, &vals);
    if (v.len == 0) return .{ .p50 = 0, .p99 = 0 };
    std.mem.sort(u32, v, {}, std.sort.asc(u32));
    return .{ .p50 = v[v.len / 2], .p99 = v[@min(v.len - 1, v.len * 99 / 100)] };
}

/// The most recent values of a span, newest last, for the HUD's graph.
pub fn recent(span: Span, out: []u32) []u32 {
    const r = &rings[@intFromEnum(span)];
    const n: usize = @intCast(@min(r.n, out.len));
    for (0..n) |i| out[i] = r.us[(r.n - n + i) % ring_size];
    return out[0..n];
}

/// Percentiles of every span that ran, as a Markdown table.
pub fn report(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(gpa, "| Span | Count | p50 ms | p95 ms | p99 ms | Max ms |\n|---|--:|--:|--:|--:|--:|\n");
    for (std.enums.values(Span)) |s| {
        const st = stats(s);
        if (st.n == 0) continue;
        var buf: [128]u8 = undefined;
        try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "| {s} | {d} | {f} | {f} | {f} | {f} |\n", .{ @tagName(s), st.n, ms(st.p50, 2), ms(st.p95, 2), ms(st.p99, 2), ms(st.max, 2) }));
    }
}

/// Thousandths of something, printed with {f}. Everything shown is a whole number underneath, and
/// the code that prints floats would cost more than everything here.
pub const Fixed = struct {
    value: u64,
    places: u8,

    pub fn format(self: Fixed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const unit: u64 = switch (self.places) {
            1 => 100,
            2 => 10,
            else => 1,
        };
        const scale = 1000 / unit;
        const v = (self.value + unit / 2) / unit;
        try w.print("{d}.", .{v / scale});
        var d = scale / 10;
        while (d > 0) : (d /= 10) try w.writeByte('0' + @as(u8, @intCast(v / d % 10)));
    }
};

pub fn ms(us: u64, places: u8) Fixed {
    return .{ .value = us, .places = places };
}

test "fixed point rounds as floats would" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.23", try std.fmt.bufPrint(&buf, "{f}", .{ms(1234, 2)}));
    try std.testing.expectEqualStrings("1.24", try std.fmt.bufPrint(&buf, "{f}", .{ms(1235, 2)}));
    try std.testing.expectEqualStrings("0.06", try std.fmt.bufPrint(&buf, "{f}", .{ms(55, 2)}));
    try std.testing.expectEqualStrings("0.051", try std.fmt.bufPrint(&buf, "{f}", .{ms(51, 3)}));
    try std.testing.expectEqualStrings("2.0", try std.fmt.bufPrint(&buf, "{f}", .{ms(1960, 1)}));
    try std.testing.expectEqualStrings("10.00", try std.fmt.bufPrint(&buf, "{f}", .{ms(9999, 2)}));
}
