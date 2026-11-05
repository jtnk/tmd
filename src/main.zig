const std = @import("std");
const build_options = @import("build_options");
const term = @import("term.zig");
const theme = @import("theme.zig");
const md = @import("md.zig");
const files = @import("files.zig");
const input = @import("input.zig");
const width = @import("width.zig");
const trace = @import("trace.zig");
const fetch = @import("fetch.zig");
const bench = @import("bench.zig");
const screen_mod = @import("screen.zig");
const App = @import("app.zig").App;
const Settings = @import("app.zig").Settings;
const c = std.c;

const usage =
    \\tmd: a tiny Markdown viewer and editor for the terminal
    \\
    \\usage: tmd [options] [file.md | url ...]
    \\       command | tmd
    \\
    \\  -p, --print         Print the rendered document and exit (the default when piped)
    \\  -w, --width N       Widest text column (default 100)
    \\      --palette NAME  system, dracula, nord, gruvbox, tokyo-night, catppuccin,
    \\                      solarized-dark, solarized-light or one-light
    \\      --no-images     Show alt text instead of images
    \\      --plain-headings  Draw headings as text, not large type
    \\      --bench FILE    Run the frame benchmark, exit 1 if it misses 60 fps
    \\  -v, --version       Print the version
    \\  -h, --help          Print this help
    \\
    \\In tmd, press ? for keys.
    \\
;

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    term.leave();
    _ = c.write(2, "tmd: panic: ", 12);
    _ = c.write(2, msg.ptr, msg.len);
    _ = c.write(2, "\n", 1);
    c.abort();
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "tmd: " ++ fmt ++ "\n", args) catch "tmd: error\n";
    _ = c.write(2, s.ptr, s.len);
    c.exit(1);
}

fn stdoutWrite(bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(1, bytes[i..].ptr, bytes.len - i);
        if (n <= 0) return;
        i += @intCast(n);
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    run(init) catch |e| {
        term.leave();
        fail("{s}", .{@errorName(e)});
    };
}

fn run(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.c_allocator;

    var settings = Settings{};
    const config_path = configPath(gpa);
    var theme_problem: ?[]const u8 = null;
    if (config_path) |p| {
        // Themes first, so the config can choose one.
        const dir = try std.fmt.allocPrintSentinel(gpa, "{s}/themes", .{std.fs.path.dirname(p) orelse "."}, 0);
        defer gpa.free(dir);
        theme_problem = try theme.loadDir(gpa, dir);
        loadConfig(gpa, p, &settings);
    }

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var print = false;
    var bench_file: ?[]const u8 = null;
    var bench_json = false;
    var want_edit = false;
    var it = init.args.iterate();
    _ = it.next();
    while (it.next()) |a| {
        if (eq(a, "-h") or eq(a, "--help")) {
            stdoutWrite(usage);
            return;
        } else if (eq(a, "-v") or eq(a, "--version")) {
            stdoutWrite("tmd " ++ build_options.version ++ "\n");
            return;
        } else if (eq(a, "--experimental-edit")) {
            settings.experimental_edit = true;
        } else if (eq(a, "-e") or eq(a, "--edit")) {
            settings.open_in = .edit;
            want_edit = true;
        } else if (eq(a, "-p") or eq(a, "--print")) {
            print = true;
        } else if (eq(a, "--no-images")) {
            settings.images = false;
        } else if (eq(a, "--plain-headings")) {
            settings.big_headings = false;
        } else if (eq(a, "-w") or eq(a, "--width")) {
            const v = it.next() orelse fail("{s} needs a number", .{a});
            settings.max_width = std.fmt.parseInt(u16, v, 10) catch fail("bad width: {s}", .{v});
        } else if (eq(a, "--palette")) {
            const v = it.next() orelse fail("{s} needs a name", .{a});
            settings.palette = theme.find(v) orelse fail("unknown palette: {s}", .{v});
        } else if (eq(a, "--bench")) {
            bench_file = it.next() orelse fail("{s} needs a file", .{a});
        } else if (eq(a, "--json")) {
            bench_json = true;
        } else if (a.len > 1 and a[0] == '-' and !eq(a, "--")) {
            fail("unknown option: {s}", .{a});
        } else if (!eq(a, "--")) {
            try paths.append(gpa, a);
        }
    }

    if (want_edit and !settings.experimental_edit) fail("--edit needs --experimental-edit", .{});

    if (bench_file) |f| {
        if (!try bench.run(gpa, f, bench_json)) c.exit(1);
        return;
    }

    // The document can arrive on stdin.
    var piped: ?[]u8 = null;
    if (paths.items.len == 0) {
        if (c.isatty(0) != 0) {
            _ = c.write(2, usage.ptr, usage.len);
            c.exit(2);
        }
        const raw = try files.readFd(gpa, 0, 512 * 1024 * 1024);
        piped = (try files.decode(gpa, raw)).bytes;
    }

    if (print or c.isatty(1) == 0) {
        const tty = c.isatty(1) != 0;
        for (paths.items) |p| {
            const z = try gpa.dupeSentinel(u8, p, 0);
            const raw = if (fetch.isUrl(p))
                (fetch.get(gpa, p) catch |e| fail("{s} {s}", .{ fetch.describe(e) orelse @errorName(e), p })).text
            else
                files.read(gpa, z.ptr, 512 * 1024 * 1024) catch fail("can't read {s}", .{p});
            try printDoc(gpa, (try files.decode(gpa, raw)).bytes, &settings, tty);
        }
        if (piped) |text| try printDoc(gpa, text, &settings, tty);
        return;
    }

    var app = App.init(gpa);
    app.settings = settings;
    app.config_path = config_path;
    app.screen.th.palette = settings.palette;

    term.open() catch fail("no terminal", .{});
    term.installSignals();
    const caps = try term.probe(gpa);
    width.grapheme_mode = caps.grapheme;
    app.screen.th.light = caps.light;
    app.store.mode = if (settings.images) caps.images else .off;
    app.store.tmux = caps.tmux;
    app.store.big_headings = settings.big_headings;
    app.store.font_path = settings.heading_font;
    if (caps.rex) {
        app.store.points = true;
        app.store.budget = 8 * 1024 * 1024;
    }
    app.store.id_base = (@as(u32, @intCast(c.getpid())) & 0xFFF) << 12;
    if (caps.cell_w > 0 and caps.cell_h > 0) _ = try app.store.setCell(&app.out, caps.cell_w, caps.cell_h);

    for (paths.items) |p| {
        _ = app.open(p) catch |e| switch (e) {
            error.NotFound => fail("no such file: {s}", .{p}),
            error.NoCurl, error.FetchFailed, error.NotMarkdown, error.HttpError => fail("{s} {s}", .{ fetch.describe(e).?, p }),
            else => return e,
        };
    }
    if (piped) |text| _ = try app.openText("stdin", text, false);
    app.active = 0;
    if (theme_problem) |p| app.notice("Theme not loaded: {s}", .{p});

    const sz = term.size();
    try app.resize(sz.cols, sz.rows);
    term.enter(caps);
    defer term.leave();
    try loop(gpa, &app, caps);
    if (std.c.getenv("TMD_TRACE")) |path| try writeReport(gpa, std.mem.span(path));
}

fn loop(gpa: std.mem.Allocator, app: *App, caps: term.Caps) !void {
    var dec = input.Decoder{ .gpa = gpa };
    var sent_images: usize = 0;
    var first_frame = true;
    // Nothing has happened that needs drawing.
    var idle = false;
    while (!app.quit) {
        if (term.resized.swap(false, .acq_rel)) {
            const sz = term.size();
            if (term.cellPixels()) |cell| _ = try app.store.setCell(&app.out, cell.w, cell.h);
            try app.resize(sz.cols, sz.rows);
            idle = false;
        }
        if (term.resumed.swap(false, .acq_rel)) {
            app.store.forgetSent();
            app.screen.invalidate();
            idle = false;
        }
        if (!idle) {
            try app.frame();
            term.write(app.out.items);
            app.out.clearRetainingCapacity();
            // The first frame is startup, and shouldn't weigh on the frame rate shown.
            if (first_frame) trace.clear(.frame);
            first_frame = false;

            // Keep the exit path able to delete whatever has been uploaded.
            const sent = app.store.sentCount();
            if (sent != sent_images) {
                sent_images = sent;
                var bytes: std.ArrayList(u8) = .empty;
                try app.store.deleteAll(&bytes);
                term.setCleanup(bytes.items);
            }
        }

        if (app.loadPending()) {
            try app.finishLoad();
            idle = false;
            continue;
        }

        var buf: [64 * 1024]u8 = undefined;
        // The HUD's numbers go stale with nothing to redraw them, so it gets a slow tick of its own.
        const n = term.read(&buf, if (dec.pendingEscape()) 25 else if (app.hud) 500 else -1);
        if (n == 0) {
            if (dec.timeout()) |e| try app.event(e) else if (app.hud) app.hud_tick = true;
            idle = false;
            continue;
        }
        try dec.feed(buf[0..n]);
        idle = true;
        while (try dec.next()) |e| {
            if (app.idleMotion(e)) continue;
            idle = false;
            try app.event(e);
        }
        if (app.want_suspend) {
            app.want_suspend = false;
            term.suspendSelf(caps);
        }
    }
}

fn printDoc(gpa: std.mem.Allocator, text: []const u8, settings: *const Settings, tty: bool) !void {
    const sz = if (tty) term.size() else @TypeOf(term.size()){ .cols = columnsEnv(), .rows = 24 };
    const w = @min(sz.cols, settings.max_width);
    var l = try md.layout(gpa, text, .{ .width = w });
    defer l.deinit();

    var sc = screen_mod.Screen{ .gpa = gpa };
    sc.th.palette = settings.palette;
    sc.th.color = tty;
    try sc.resize(w, 1);
    var out: std.ArrayList(u8) = .empty;
    for (l.rows.items) |r| {
        sc.begin();
        sc.row(w);
        for (l.rowSpans(r)) |s| try sc.text(s.style, s.text);
        if (tty) try sc.raw("\x1b[0m");
        out.clearRetainingCapacity();
        try out.appendSlice(gpa, std.mem.trimEnd(u8, sc.bytes.items, " "));
        try out.append(gpa, '\n');
        stdoutWrite(out.items);
    }
}

fn columnsEnv() u16 {
    const v = c.getenv("COLUMNS") orelse return 80;
    return std.fmt.parseInt(u16, std.mem.span(v), 10) catch 80;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn configPath(gpa: std.mem.Allocator) ?[:0]u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |d| {
        return std.fmt.allocPrintSentinel(gpa, "{s}/tmd/config", .{std.mem.span(d)}, 0) catch null;
    }
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.allocPrintSentinel(gpa, "{s}/.config/tmd/config", .{std.mem.span(home)}, 0) catch null;
}

fn loadConfig(gpa: std.mem.Allocator, path: [:0]const u8, s: *Settings) void {
    const text = files.read(gpa, path.ptr, 64 * 1024) catch return;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = theme.stripComment(raw);
        const eq_at = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_at], " \t");
        const val = std.mem.trim(u8, line[eq_at + 1 ..], " \t");
        if (eq(key, "palette")) {
            s.palette = theme.find(val) orelse s.palette;
        } else if (eq(key, "width")) {
            s.max_width = std.fmt.parseInt(u16, val, 10) catch s.max_width;
        } else if (eq(key, "open")) {
            if (eq(val, "editor") or eq(val, "edit")) s.open_in = .edit;
        } else if (eq(key, "images")) {
            s.images = !eq(val, "off");
        } else if (eq(key, "big_headings")) {
            s.big_headings = !eq(val, "off");
        } else if (eq(key, "experimental_edit")) {
            s.experimental_edit = eq(val, "on");
        } else if (eq(key, "heading_font")) {
            s.heading_font = gpa.dupeSentinel(u8, val, 0) catch null;
        }
    }
}

fn writeReport(gpa: std.mem.Allocator, path: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "# tmd session\n\n");
    try trace.report(gpa, &out);
    try out.appendSlice(gpa, "\n## Last frames\n\n");
    try trace.frameLog(gpa, &out);
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    files.writeAtomic(gpa, z, out.items) catch {};
}
