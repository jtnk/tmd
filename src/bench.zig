//! The frame benchmark: the real app, driven with the keystrokes of each scenario and timed from
//! input to bytes ready for the terminal. It fails if a scenario's p99 frame misses 60 fps.
const std = @import("std");
const input = @import("input.zig");
const trace = @import("trace.zig");
const App = @import("app.zig").App;
const Key = input.Key;

const budget_us = 16_700;

const Result = struct { frames: usize, p50: u32, p95: u32, p99: u32, max: u32, bytes: usize };

const Run = struct {
    gpa: std.mem.Allocator,
    app: *App,
    us: std.ArrayList(u32) = .empty,
    bytes: usize = 0,

    fn tick(self: *Run, e: ?input.Event) !void {
        const t0 = trace.now();
        if (e) |ev| try self.app.event(ev);
        try self.app.frame();
        const us: u32 = @intCast((trace.now() - t0) / 1000);
        try self.us.append(self.gpa, us);
        self.bytes += self.app.out.items.len;
        self.app.out.clearRetainingCapacity();
    }

    fn key(self: *Run, code: u21) !void {
        try self.tick(.{ .key = .{ .code = code } });
    }

    fn ctrl(self: *Run, code: u21) !void {
        try self.tick(.{ .key = .{ .code = code, .mods = .{ .ctrl = true } } });
    }

    fn finish(self: *Run) Result {
        std.mem.sort(u32, self.us.items, {}, std.sort.asc(u32));
        const v = self.us.items;
        const r = Result{
            .frames = v.len,
            .p50 = v[v.len / 2],
            .p95 = v[@min(v.len - 1, v.len * 95 / 100)],
            .p99 = v[@min(v.len - 1, v.len * 99 / 100)],
            .max = v[v.len - 1],
            .bytes = self.bytes / v.len,
        };
        self.us.deinit(self.gpa);
        return r;
    }
};

const Scenario = struct {
    name: []const u8,
    go: *const fn (*Run) anyerror!void,
};

fn scrollLines(r: *Run) !void {
    try r.key('g');
    for (0..3000) |_| try r.key('j');
}

fn scrollPages(r: *Run) !void {
    try r.key('g');
    for (0..600) |_| try r.key(Key.page_down);
}

fn jumps(r: *Run) !void {
    for (0..300) |_| {
        try r.key('G');
        try r.key('g');
    }
}

fn resizing(r: *Run) !void {
    for (0..120) |i| {
        try r.app.resize(@intCast(60 + i % 60), 40);
        try r.tick(null);
    }
    try r.app.resize(120, 40);
}

fn toggling(r: *Run) !void {
    for (0..100) |_| {
        try r.key('e');
        try r.key(Key.escape);
    }
}

fn typing(r: *Run) !void {
    try r.key('e');
    for (0..1500) |i| {
        try r.key(if (i % 7 == 6) ' ' else 'a' + @as(u21, @intCast(i % 26)));
    }
    for (0..300) |_| try r.key(Key.backspace);
    for (0..1800) |_| try r.ctrl('z');
    try r.key(Key.escape);
}

fn cursorMoves(r: *Run) !void {
    try r.key('e');
    for (0..1500) |_| try r.key(Key.down);
    for (0..1500) |_| try r.key(Key.up);
    try r.key(Key.escape);
}

const scenarios = [_]Scenario{
    .{ .name = "scroll by line", .go = scrollLines },
    .{ .name = "scroll by page", .go = scrollPages },
    .{ .name = "jump top/bottom", .go = jumps },
    .{ .name = "resize", .go = resizing },
    .{ .name = "toggle preview/editor", .go = toggling },
    .{ .name = "typing + undo", .go = typing },
    .{ .name = "cursor movement", .go = cursorMoves },
};

fn print(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(s);
    _ = std.c.write(1, s.ptr, s.len);
}

pub fn run(gpa: std.mem.Allocator, path: []const u8, json: bool) !bool {
    var app = App.init(gpa);
    defer app.deinit();
    app.spawn = false;
    app.settings.experimental_edit = true; // the scenarios type
    app.screen.th.palette = 1;
    // As in a graphics terminal: headings are images, and upload as they come into view.
    app.store.mode = .placeholder;
    try app.resize(120, 40);

    const t0 = trace.now();
    const tab = try app.open(path);
    try app.frame();
    const first = (trace.now() - t0) / 1000;
    app.out.clearRetainingCapacity();
    const size = tab.ed.text().len;
    const rows = tab.layout.?.rows.items.len;

    if (json) {
        print(gpa, "{{\"file\":\"{s}\",\"bytes\":{d},\"rows\":{d},\"first_frame_ms\":{f},\"scenarios\":[", .{ path, size, rows, trace.ms(first, 3) });
    } else {
        print(gpa, "{s}: {d} bytes, {d} rows\nfirst frame: {f} ms\n\n", .{ path, size, rows, trace.ms(first, 2) });
        print(gpa, "| Scenario | Frames | p50 ms | p99 ms | Max ms | Bytes/frame | Best fps | 60 fps |\n|---|--:|--:|--:|--:|--:|--:|---|\n", .{});
    }

    var ok = true;
    for (scenarios, 0..) |s, i| {
        var r = Run{ .gpa = gpa, .app = &app };
        try s.go(&r);
        const res = r.finish();
        const pass = res.p99 <= budget_us;
        ok = ok and pass;
        const best = trace.bestFps(res.p99);
        if (json) {
            print(gpa, "{s}{{\"name\":\"{s}\",\"frames\":{d},\"p50_ms\":{f},\"p95_ms\":{f},\"p99_ms\":{f},\"max_ms\":{f},\"bytes_per_frame\":{d},\"best_fps\":{d}}}", .{ if (i > 0) "," else "", s.name, res.frames, trace.ms(res.p50, 3), trace.ms(res.p95, 3), trace.ms(res.p99, 3), trace.ms(res.max, 3), res.bytes, best });
        } else {
            print(gpa, "| {s} | {d} | {f} | {f} | {f} | {d} | {d} | {s} |\n", .{ s.name, res.frames, trace.ms(res.p50, 2), trace.ms(res.p99, 2), trace.ms(res.max, 2), res.bytes, best, if (pass) "yes" else "NO" });
        }
    }
    if (json) print(gpa, "]}}\n", .{});
    return ok;
}
