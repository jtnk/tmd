//! The application: tabs, modes, keys, and painting a frame. It never touches the terminal. Bytes go
//! in through event() and come out of frame(), so the benchmark and the tests drive the real thing.
const std = @import("std");
const theme = @import("theme.zig");
const md = @import("md.zig");
const selection = @import("selection.zig");
const Selection = selection.Selection;
const input = @import("input.zig");
const images = @import("images.zig");
const files = @import("files.zig");
const fetch = @import("fetch.zig");
const complete = @import("complete.zig");
const trace = @import("trace.zig");
const build_options = @import("build_options");
const tidy = @import("tidy.zig");
const width = @import("width.zig");
const screen_mod = @import("screen.zig");
const editor = @import("editor.zig");
const Editor = editor.Editor;
const Screen = screen_mod.Screen;
const Style = theme.Style;
const Color = theme.Color;
const Key = input.Key;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const max_doc = 512 * 1024 * 1024;
/// Below this, the line and space around the status row cost more than they give.
const min_rows_for_frame = 8;
const web_icon = "🌐 ";
const help_text = @embedFile("help.md");
const help_editor_text = @embedFile("help-editor.md");

pub const Mode = enum { preview, edit };

pub const Settings = struct {
    palette: usize = 0,
    /// Widest the text column gets.
    max_width: u16 = 100,
    open_in: Mode = .preview,
    images: bool = true,
    /// Draw h1 and h2 as large type, where the terminal can show images.
    big_headings: bool = true,
    heading_font: ?[:0]const u8 = null,
    /// Editing is experimental, and off unless asked for.
    experimental_edit: bool = false,
};

pub const Tab = struct {
    gpa: std.mem.Allocator,
    path: ?[:0]u8 = null,
    name: []const u8 = "untitled",
    /// Directory relative links resolve against.
    dir: []const u8 = ".",
    ed: Editor,
    crlf: bool = false,
    read_only: bool = false,
    mode: Mode = .preview,
    layout: ?md.Layout = null,
    layout_gen: u64 = 0,
    layout_width: u16 = 0,
    layout_cell: u32 = 0,
    layout_rows: u16 = 0,
    top: u32 = 0,
    /// Focused link, plus one. Only set while tabbing through links, so nothing stays highlighted.
    focus: u32 = 0,
    /// The link last focused or followed, plus one: where Tab picks up again.
    last_link: u32 = 0,
    selection: ?Selection = null,
    /// Where the page came from, if it's from the web.
    url: ?[]u8 = null,

    /// Cells the tab bar gives the name, with the icon in front of a page from the web.
    fn nameCols(self: *const Tab) u32 {
        return width.of(self.name) + if (self.url != null) width.of(web_icon) else 0;
    }

    fn deinit(self: *Tab) void {
        if (self.layout) |*l| l.deinit();
        self.ed.deinit();
        if (self.path) |p| self.gpa.free(p);
        if (self.url) |u| self.gpa.free(u);
        if (!std.mem.eql(u8, self.dir, ".")) self.gpa.free(self.dir);
    }
};

pub const Prompt = enum { none, find, save_as, open, confirm_close, confirm_quit };

pub const App = struct {
    gpa: std.mem.Allocator,
    settings: Settings = .{},
    screen: Screen,
    store: images.Store,
    tabs: std.ArrayList(*Tab) = .empty,
    active: usize = 0,
    /// Bytes for the terminal, taken after each frame.
    out: std.ArrayList(u8) = .empty,
    quit: bool = false,
    hud: bool = false,
    message: []const u8 = "",
    message_buf: [160]u8 = undefined,
    prompt: Prompt = .none,
    prompt_text: std.ArrayList(u8) = .empty,
    /// The completions on offer, beside the Open prompt.
    prompt_hint: std.ArrayList(u8) = .empty,
    /// A page to load once the message saying so is on screen.
    pending_load: std.ArrayList(u8) = .empty,
    pending_reload: bool = false,
    query: std.ArrayList(u8) = .empty,
    match_rows: std.ArrayList(u32) = .empty,
    match_gen: u64 = 0,
    match_width: u16 = 0,
    clip: std.ArrayList(u8) = .empty,
    /// Rows the preview moved since the last frame, for terminal scrolling.
    scroll_hint: i32 = 0,
    dragging: bool = false,
    /// false in tests and the benchmark: no child processes.
    spawn: bool = true,
    /// What a followed link would have opened, when spawn is off.
    opened: std.ArrayList(u8) = .empty,
    config_path: ?[:0]u8 = null,
    row_text: std.ArrayList(u8) = .empty,
    last_bytes: usize = 0,
    /// Set by Ctrl+Z: the terminal loop suspends the process.
    want_suspend: bool = false,
    shown_mode: Mode = .preview,
    /// The tab under the mouse, which shows its close button.
    hover: ?usize = null,
    /// What the next frame is for, for the frame log.
    cause: trace.Cause = .none,
    /// The next frame only refreshes the HUD, and isn't one to count.
    hud_tick: bool = false,
    /// Where the left button went down in the preview, until it comes up.
    drag_from: ?selection.Point = null,

    pub fn init(gpa: std.mem.Allocator) App {
        return .{ .gpa = gpa, .screen = .{ .gpa = gpa }, .store = .{ .gpa = gpa } };
    }

    pub fn deinit(self: *App) void {
        for (self.tabs.items) |t| {
            t.deinit();
            self.gpa.destroy(t);
        }
        self.tabs.deinit(self.gpa);
        self.screen.deinit();
        self.store.deinit();
        self.out.deinit(self.gpa);
        self.prompt_text.deinit(self.gpa);
        self.prompt_hint.deinit(self.gpa);
        self.pending_load.deinit(self.gpa);
        self.query.deinit(self.gpa);
        self.match_rows.deinit(self.gpa);
        self.clip.deinit(self.gpa);
        self.opened.deinit(self.gpa);
        self.row_text.deinit(self.gpa);
        if (self.config_path) |p| self.gpa.free(p);
    }

    /// Shows a message on the status row.
    pub fn notice(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.say(fmt, args);
    }

    fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.message_buf, fmt, args) catch self.message_buf[0..];
    }

    pub fn tab(self: *App) *Tab {
        return self.tabs.items[self.active];
    }

    // Documents.

    fn newTab(self: *App) !*Tab {
        const t = try self.gpa.create(Tab);
        t.* = .{ .gpa = self.gpa, .ed = .{ .gpa = self.gpa } };
        t.mode = if (self.settings.experimental_edit) self.settings.open_in else .preview;
        try self.tabs.append(self.gpa, t);
        self.active = self.tabs.items.len - 1;
        return t;
    }

    /// Opens a file in a new tab. A file that doesn't exist yet starts empty in the editor.
    pub fn open(self: *App, path: []const u8) !*Tab {
        const t0 = trace.now();
        defer _ = trace.end(.load, t0);
        if (fetch.isUrl(path)) return self.openUrl(path);
        const z = try self.gpa.dupeSentinel(u8, path, 0);
        // Until the tab has it, and then the tab frees it.
        var unowned: ?[:0]u8 = z;
        errdefer if (unowned) |u| self.gpa.free(u);
        for (self.tabs.items, 0..) |t, i| {
            if (t.path) |p| if (std.mem.eql(u8, p, path)) {
                self.gpa.free(z);
                self.active = i;
                return t;
            };
        }
        const raw = files.read(self.gpa, z.ptr, max_doc) catch |e| switch (e) {
            // A new file means editing it, which has to be switched on.
            error.NotFound => if (self.settings.experimental_edit) null else return e,
            else => return e,
        };
        const t = try self.newTab();
        t.path = z;
        unowned = null;
        t.name = std.fs.path.basename(z);
        const dir = std.fs.path.dirname(path) orelse ".";
        t.dir = if (std.mem.eql(u8, dir, ".")) "." else try self.gpa.dupe(u8, dir);
        if (raw) |r| {
            const text = try files.decode(self.gpa, r);
            defer self.gpa.free(text.bytes);
            t.crlf = text.crlf;
            try t.ed.load(text.bytes);
        } else {
            try t.ed.load("");
            t.mode = .edit;
        }
        return t;
    }

    fn openUrl(self: *App, url: []const u8) !*Tab {
        for (self.tabs.items, 0..) |t, i| {
            if (t.url) |u| if (std.mem.eql(u8, u, url)) {
                self.active = i;
                return t;
            };
        }
        const page = try fetch.get(self.gpa, url);
        // Until the tab has it, and then the tab frees it.
        var unowned: ?[]u8 = page.url;
        errdefer if (unowned) |u| self.gpa.free(u);
        const text = try files.decode(self.gpa, page.text);
        defer self.gpa.free(text.bytes);
        const t = try self.newTab();
        t.url = page.url;
        unowned = null;
        t.name = fetch.nameOf(page.url);
        t.read_only = true;
        try t.ed.load(text.bytes);
        return t;
    }

    pub fn openText(self: *App, name: []const u8, text: []const u8, read_only: bool) !*Tab {
        const t = try self.newTab();
        t.name = name;
        t.read_only = read_only;
        t.mode = .preview;
        try t.ed.load(text);
        return t;
    }

    fn textWidth(self: *const App) u16 {
        const room = self.screen.cols -| 5;
        return @max(@min(room, self.settings.max_width), 8);
    }

    pub fn leftMargin(self: *const App) u16 {
        return @max((self.screen.cols -| self.textWidth()) / 2, 1);
    }

    fn viewRows(self: *const App) u16 {
        return self.screen.rows -| (1 + self.barRows() + self.hudRows() + 2 * self.frameRows());
    }

    /// The line above the status row and the space below it, which a short window can't spare.
    fn frameRows(self: *const App) u16 {
        return if (self.screen.rows >= min_rows_for_frame) 1 else 0;
    }

    fn barRows(self: *const App) u16 {
        return if (self.tabs.items.len > 1 and self.screen.rows >= 3) 1 else 0;
    }

    /// The HUD sits under the status line, and gives way in a very short window.
    fn hudRows(self: *const App) u16 {
        return if (self.hud and self.screen.rows >= 9) 3 else 0;
    }

    /// Makes sure a tab's layout matches its text and the window.
    fn ensureLayout(self: *App, t: *Tab) !void {
        const w = self.textWidth();
        const max_rows = @max(self.viewRows() -| 2, 4);
        if (t.layout != null and t.layout_gen == t.ed.generation and t.layout_width == w and t.layout_rows == max_rows and t.layout_cell == self.store.cell_gen) return;
        const t0 = trace.now();
        defer _ = trace.end(.layout, t0);

        const text_changed = t.layout_gen != t.ed.generation;
        // Keep the same text at the top across the change.
        var src: ?u32 = null;
        if (t.layout) |*l| {
            if (l.rows.items.len > 0) src = l.rows.items[@min(t.top, l.rows.items.len - 1)].src;
        }
        self.store.dir = t.dir;
        self.store.no_files = t.url != null;
        self.store.heading_rgb = self.headingColor();
        const opts = md.Options{
            .width = w,
            .max_image_rows = max_rows,
            .images = if (self.store.mode != .off) self.store.source() else null,
            .link_marks = true,
        };
        if (t.layout) |*l| {
            md.relayout(l, t.ed.text(), opts) catch |e| {
                l.deinit();
                t.layout = null;
                return e;
            };
        } else t.layout = try md.layout(self.gpa, t.ed.text(), opts);
        // Selections are cells, and the cells just moved.
        t.selection = null;
        self.drag_from = null;
        t.layout_gen = t.ed.generation;
        t.layout_width = w;
        t.layout_rows = max_rows;
        t.layout_cell = self.store.cell_gen;
        // A resize keeps the focused link. An edit may have renumbered them.
        if (t.focus > t.layout.?.links.items.len or text_changed) {
            t.focus = 0;
            t.last_link = 0;
        }
        if (src) |s| t.top = t.layout.?.rowForOffset(s);
        self.clampTop(t);
        self.screen.invalidate();
    }

    /// Large headings are pixels, so they need a real color even when the palette defers to the
    /// terminal's own.
    fn headingColor(self: *const App) u24 {
        if (theme.palettes[self.settings.palette].rgb) |p| return p[2];
        return if (self.screen.th.light) 0xA626A4 else 0xC792EA;
    }

    fn maxTop(self: *App, t: *Tab) u32 {
        const n: u32 = @intCast(t.layout.?.rows.items.len);
        return n -| self.viewRows();
    }

    fn clampTop(self: *App, t: *Tab) void {
        t.top = @min(t.top, self.maxTop(t));
    }

    pub fn resize(self: *App, cols: u16, rows: u16) !void {
        self.cause = .resize;
        self.hud_tick = false;
        try self.screen.resize(cols, rows);
    }

    fn setMode(self: *App, t: *Tab, mode: Mode) !void {
        if (t.mode == mode) return;
        if (mode == .edit) {
            if (!self.settings.experimental_edit) return;
            if (t.read_only) {
                self.say("Read-only", .{});
                return;
            }
            try self.ensureLayout(t);
            const l = &t.layout.?;
            const src = l.rows.items[@min(t.top, l.rows.items.len - 1)].src;
            const line = t.ed.lineOf(src);
            t.ed.top_line = line;
            t.ed.top_sub = 0;
            // The cursor stays where it was if that's still on screen.
            const cl = t.ed.lineOf(t.ed.cursor);
            if (cl < line or cl >= line + self.viewRows()) t.ed.moveTo(t.ed.starts.items[line], false);
            t.mode = .edit;
        } else {
            t.mode = .preview;
            const src = t.ed.starts.items[@min(t.ed.top_line, t.ed.lineCount() - 1)];
            try self.ensureLayout(t);
            t.top = t.layout.?.rowForOffset(src);
            self.clampTop(t);
        }
        self.screen.invalidate();
    }

    fn save(self: *App, t: *Tab) !void {
        const p = t.path orelse {
            self.startPrompt(.save_as);
            return;
        };
        var with_crlf: ?[]u8 = null;
        defer if (with_crlf) |w| self.gpa.free(w);
        const text = t.ed.text();
        var bytes = text;
        if (t.crlf) {
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(self.gpa);
            for (text) |c| {
                if (c == '\n') try list.append(self.gpa, '\r');
                try list.append(self.gpa, c);
            }
            with_crlf = try list.toOwnedSlice(self.gpa);
            bytes = with_crlf.?;
        }
        files.writeAtomic(self.gpa, p, bytes) catch {
            self.say("Could not save {s}", .{t.name});
            return;
        };
        t.ed.markSaved();
        self.say("Saved {s}", .{t.name});
    }

    fn reload(self: *App, t: *Tab) !void {
        if (t.url != null) {
            self.pending_reload = true;
            self.say("Loading {s}…", .{t.name});
            return;
        }
        const p = t.path orelse return;
        const raw = files.read(self.gpa, p.ptr, max_doc) catch {
            self.say("Could not read {s}", .{t.name});
            return;
        };
        const text = try files.decode(self.gpa, raw);
        defer self.gpa.free(text.bytes);
        t.crlf = text.crlf;
        const top = t.top;
        try t.ed.load(text.bytes);
        t.top = top;
        self.say("Reloaded {s}", .{t.name});
    }

    fn closeTab(self: *App) void {
        const t = self.tab();
        if (t.ed.dirty()) {
            self.startPrompt(.confirm_close);
            return;
        }
        self.dropTab();
    }

    fn dropTab(self: *App) void {
        const t = self.tab();
        t.deinit();
        self.gpa.destroy(t);
        _ = self.tabs.orderedRemove(self.active);
        self.hover = null;
        if (self.tabs.items.len == 0) {
            self.quit = true;
            return;
        }
        self.active = @min(self.active, self.tabs.items.len - 1);
        self.screen.invalidate();
    }

    /// Closes tab i. Closing another tab leaves the view alone, unless the tab has unsaved changes:
    /// then it comes forward to ask.
    fn closeTabAt(self: *App, i: usize) void {
        const current = self.active;
        const ask = self.tabs.items[i].ed.dirty();
        self.active = i;
        self.screen.invalidate();
        self.closeTab();
        if (ask or i == current) return;
        self.active = if (i < current) current - 1 else current;
    }

    fn reloadUrl(self: *App, t: *Tab, url: []const u8) !void {
        const page = fetch.get(self.gpa, url) catch |e| {
            self.say("{s} {s}", .{ fetch.describe(e) orelse @errorName(e), t.name });
            return;
        };
        // It may have moved, and relative links go by where it is now.
        self.gpa.free(url);
        t.url = page.url;
        t.name = fetch.nameOf(page.url);
        const text = try files.decode(self.gpa, page.text);
        defer self.gpa.free(text.bytes);
        const top = t.top;
        try t.ed.load(text.bytes);
        t.top = top;
        self.say("Reloaded {s}", .{t.name});
    }

    /// Asks for a page from the web to open as a tab. Loading blocks, so it waits until the terminal
    /// loop has drawn the message saying so, and then calls finishLoad.
    fn followUrl(self: *App, url: []const u8) !void {
        if (!self.spawn) {
            self.opened.clearRetainingCapacity();
            try self.opened.appendSlice(self.gpa, url);
            return;
        }
        self.pending_load.clearRetainingCapacity();
        try self.pending_load.appendSlice(self.gpa, url);
        self.say("Loading {s}…", .{url[0..@min(url.len, 100)]});
    }

    pub fn loadPending(self: *const App) bool {
        return self.pending_load.items.len > 0 or self.pending_reload;
    }

    /// Does the load that followUrl or a reload set up.
    pub fn finishLoad(self: *App) !void {
        self.message = "";
        if (self.pending_reload) {
            self.pending_reload = false;
            const t = self.tab();
            if (t.url) |u| try self.reloadUrl(t, u);
            return;
        }
        const url = try self.gpa.dupe(u8, self.pending_load.items);
        defer self.gpa.free(url);
        self.pending_load.clearRetainingCapacity();
        const hash = std.mem.indexOfScalar(u8, url, '#');
        const next = self.open(url[0 .. hash orelse url.len]) catch |e| {
            self.say("{s} {s}", .{ fetch.describe(e) orelse @errorName(e), url[0..@min(url.len, 100)] });
            return;
        };
        if (hash) |h| {
            try self.ensureLayout(next);
            self.goAnchor(next, url[h + 1 ..]);
        }
        self.screen.invalidate();
    }

    /// There's no listing a website, so only paths complete.
    fn completeOpen(self: *App) !void {
        if (fetch.isUrl(self.prompt_text.items)) return;
        const r = (try complete.path(self.gpa, self.prompt_text.items)) orelse return;
        defer r.deinit(self.gpa);
        self.prompt_text.clearRetainingCapacity();
        try self.prompt_text.appendSlice(self.gpa, r.text);
        try self.prompt_hint.appendSlice(self.gpa, r.hint);
    }

    /// Opens what was typed at the Open prompt: a path, from where tmd started, or a URL.
    fn openPrompted(self: *App) !void {
        const typed = std.mem.trim(u8, self.prompt_text.items, " \t");
        if (typed.len == 0) return;
        if (fetch.isUrl(typed)) return self.followUrl(typed);
        const home = if (std.mem.startsWith(u8, typed, "~/")) std.c.getenv("HOME") else null;
        const path = if (home) |h|
            try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ std.mem.span(h), typed[1..] })
        else
            try self.gpa.dupe(u8, typed);
        defer self.gpa.free(path);
        const next = self.open(path) catch |e| {
            const shown = typed[0..@min(typed.len, 100)];
            if (e == error.NotFound) {
                self.say("No such file: {s}", .{shown});
            } else {
                self.say("{s} {s}", .{ fetch.describe(e) orelse "Couldn't open", shown });
            }
            return;
        };
        for (self.tabs.items, 0..) |t, i| {
            if (t == next) self.active = i;
        }
        self.screen.invalidate();
    }

    fn requestQuit(self: *App) void {
        for (self.tabs.items, 0..) |t, i| {
            if (t.ed.dirty()) {
                self.active = i;
                self.startPrompt(.confirm_quit);
                return;
            }
        }
        self.quit = true;
    }

    fn startPrompt(self: *App, p: Prompt) void {
        self.prompt = p;
        self.prompt_text.clearRetainingCapacity();
        self.message = "";
    }

    // Links.

    fn follow(self: *App, url: []const u8) !void {
        const t = self.tab();
        if (url.len == 0) return;
        if (url[0] == '#') {
            self.goAnchor(t, url[1..]);
            return;
        }
        if (schemeOf(url)) |scheme| {
            const ok = std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "mailto");
            if (!ok) {
                self.say("Not opening a {s}: link", .{scheme});
                return;
            }
            if (fetch.isUrl(url) and md.isMarkdown(fetch.pathOf(url))) return self.followUrl(url);
            try self.launch(url);
            return;
        }
        // A page from the web has no folder here: its links stay on the web.
        if (t.url) |base| {
            const abs = try fetch.resolve(self.gpa, base, url);
            defer self.gpa.free(abs);
            return if (md.isMarkdown(fetch.pathOf(abs))) self.followUrl(abs) else self.launch(abs);
        }
        const hash = std.mem.indexOfScalar(u8, url, '#');
        const raw = url[0 .. hash orelse url.len];
        const decoded = try images.decodePercent(self.gpa, raw);
        defer self.gpa.free(decoded);
        const full = if (decoded.len > 0 and decoded[0] == '/')
            try self.gpa.dupe(u8, decoded)
        else
            try std.fs.path.join(self.gpa, &.{ t.dir, decoded });
        defer self.gpa.free(full);
        const z = try self.gpa.dupeSentinel(u8, full, 0);
        defer self.gpa.free(z);
        if (!files.isFile(z.ptr)) {
            self.say("Not found: {s}", .{raw});
            return;
        }
        if (md.isMarkdown(full)) {
            const next = self.open(full) catch {
                self.say("Could not open {s}", .{raw[0..@min(raw.len, 100)]});
                return;
            };
            if (hash) |h| {
                try self.ensureLayout(next);
                self.goAnchor(next, url[h + 1 ..]);
            }
            self.screen.invalidate();
        } else if (!safeToOpen(full)) {
            self.say("Not opening {s}: it could run something", .{raw[0..@min(raw.len, 100)]});
        } else {
            // An absolute path can't be mistaken for an option by the opener.
            var abs_buf: [4096]u8 = undefined;
            const abs: ?[*:0]u8 = std.c.realpath(z.ptr, &abs_buf);
            if (abs) |a| try self.launch(std.mem.span(a));
        }
    }

    fn goAnchor(self: *App, t: *Tab, slug: []const u8) void {
        const l = &(t.layout orelse return);
        if (l.anchor(slug)) |row| {
            t.top = row;
            self.clampTop(t);
        } else {
            self.say("No heading #{s}", .{slug});
        }
    }

    fn launch(self: *App, target: []const u8) !void {
        self.opened.clearRetainingCapacity();
        try self.opened.appendSlice(self.gpa, target);
        if (!self.spawn) return;
        const z = try self.gpa.dupeSentinel(u8, target, 0);
        defer self.gpa.free(z);
        const opener: [*:0]const u8 = if (@import("builtin").os.tag == .macos) "open" else "xdg-open";
        const pid = std.c.fork();
        if (pid == 0) {
            _ = std.c.setsid();
            const dev = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
            if (dev >= 0) {
                _ = std.c.dup2(dev, 0);
                _ = std.c.dup2(dev, 1);
                _ = std.c.dup2(dev, 2);
            }
            const argv = [_:null]?[*:0]const u8{ opener, z.ptr };
            _ = execvp(opener, &argv);
            std.c._exit(127);
        }
        self.say("Opened {s}", .{target[0..@min(target.len, 100)]});
    }

    fn focusLink(self: *App, t: *Tab, back: bool) void {
        const links = t.layout.?.links.items;
        const n: u32 = @intCast(links.len);
        if (n == 0) return;
        // Pick up from the last link if it's still in view, as when coming back from following it.
        if (t.focus == 0 and t.last_link != 0 and t.last_link <= n) {
            const row = links[t.last_link - 1].row;
            if (row >= t.top and row < t.top + self.viewRows()) t.focus = t.last_link;
        }
        if (t.focus == 0) {
            // Start from the view: the first link at or below the top.
            var first: u32 = 0;
            while (first < n and links[first].row < t.top) first += 1;
            t.focus = if (back) (if (first == 0) n else first) else (if (first == n) 1 else first + 1);
        } else if (back) {
            t.focus = if (t.focus == 1) n else t.focus - 1;
        } else {
            t.focus = if (t.focus == n) 1 else t.focus + 1;
        }
        self.revealLink(t);
    }

    fn revealLink(self: *App, t: *Tab) void {
        if (t.focus == 0) return;
        const row = t.layout.?.links.items[t.focus - 1].row;
        const view = self.viewRows();
        if (row < t.top or row >= t.top + view) {
            t.top = row -| (view / 3);
            self.clampTop(t);
        }
        const url = t.layout.?.links.items[t.focus - 1].url;
        self.say("{s}", .{url[0..@min(url.len, 150)]});
    }

    // Find.

    fn rowPlain(self: *App, l: *const md.Layout, r: md.Row) ![]const u8 {
        self.row_text.clearRetainingCapacity();
        for (l.rowSpans(r)) |s| try self.row_text.appendSlice(self.gpa, s.text);
        return self.row_text.items;
    }

    fn updateMatches(self: *App, t: *Tab) !void {
        const t0 = trace.now();
        defer _ = trace.end(.find, t0);
        self.match_rows.clearRetainingCapacity();
        if (self.query.items.len == 0) return;
        const l = &t.layout.?;
        for (l.rows.items, 0..) |r, i| {
            const text = try self.rowPlain(l, r);
            if (editor.indexOfFold(text, 0, self.query.items) != null) try self.match_rows.append(self.gpa, @intCast(i));
        }
        for (l.headings.items) |h| {
            if (editor.indexOfFold(h.text, 0, self.query.items) != null) try self.match_rows.append(self.gpa, h.row);
        }
        std.mem.sort(u32, self.match_rows.items, {}, std.sort.asc(u32));
        self.match_gen = t.layout_gen;
        self.match_width = t.layout_width;
    }

    fn findNext(self: *App, t: *Tab, back: bool, from_here: bool) !void {
        if (self.query.items.len == 0) return;
        if (t.mode == .edit) {
            const s = t.ed.selection();
            const from = if (back)
                (if (s) |x| x[0] else t.ed.cursor) -| 1
            else if (from_here)
                (if (s) |x| x[0] else t.ed.cursor)
            else
                (if (s) |x| x[1] else t.ed.cursor);
            if (t.ed.find(self.query.items, from, back)) |p| {
                t.ed.anchor = p;
                t.ed.cursor = p + @as(u32, @intCast(self.query.items.len));
            } else self.say("No matches", .{});
            return;
        }
        if (self.match_gen != t.layout_gen or self.match_width != t.layout_width) try self.updateMatches(t);
        const rows = self.match_rows.items;
        if (rows.len == 0) {
            self.say("No matches", .{});
            return;
        }
        var i: usize = 0;
        if (back) {
            i = rows.len - 1;
            var k = rows.len;
            while (k > 0) {
                k -= 1;
                if (rows[k] < t.top) {
                    i = k;
                    break;
                }
            }
        } else {
            const at = if (from_here) t.top else t.top + 1;
            for (rows, 0..) |r, k| {
                if (r >= at) {
                    i = k;
                    break;
                }
            }
        }
        self.scrollTo(t, rows[i]);
        self.say("Match {d} of {d}", .{ i + 1, rows.len });
    }

    fn scrollTo(self: *App, t: *Tab, row: u32) void {
        const before = t.top;
        t.top = row;
        self.clampTop(t);
        self.scroll_hint += @as(i32, @intCast(t.top)) - @as(i32, @intCast(before));
    }

    // Input.

    pub fn event(self: *App, e: input.Event) !void {
        const t0 = trace.now();
        defer _ = trace.end(.input, t0);
        self.message = if (self.prompt == .none) "" else self.message;
        if (self.tabs.items.len == 0) return;
        self.cause = switch (e) {
            .key => .key,
            .mouse => .mouse,
            .paste => .paste,
            else => .other,
        };
        switch (e) {
            .key => |k| {
                if (self.prompt != .none) return self.promptKey(k.code, k.mods);
                const t = self.tab();
                // Ctrl+` cycles tabs in either mode. Legacy terminals send it as NUL, which decodes
                // as Ctrl+Space, and Shift can turn the key into ~.
                if (k.mods.ctrl and (k.code == '`' or k.code == '~' or k.code == ' ')) {
                    clearFocus(t);
                    self.switchTab(if (k.mods.shift) -1 else 1);
                    return;
                }
                if (k.code == Key.f1 + 10 or (k.code == 'l' and k.mods.alt)) return self.saveFrameLog();
                if (k.code == Key.f1 + 11 or (k.code == 'h' and k.mods.alt)) {
                    self.hud = !self.hud;
                    self.screen.invalidate();
                    // The view just changed height.
                    if (t.mode == .edit) try t.ed.reveal(self.textWidth(), self.viewRows());
                    return;
                }
                switch (t.mode) {
                    .preview => try self.previewKey(t, k.code, k.mods),
                    .edit => try self.editKey(t, k.code, k.mods),
                }
            },
            .mouse => |m| try self.mouse(m),
            .paste => |text| {
                if (self.prompt != .none) {
                    try self.prompt_text.appendSlice(self.gpa, text);
                    return;
                }
                const t = self.tab();
                if (t.mode == .edit) {
                    const clean = try normalizeNewlines(self.gpa, text);
                    defer self.gpa.free(clean);
                    try t.ed.insert(clean, .other);
                    try t.ed.reveal(self.textWidth(), self.viewRows());
                }
            },
            else => {},
        }
    }

    fn previewKey(self: *App, t: *Tab, code: u21, mods: input.Mods) !void {
        try self.ensureLayout(t);
        const view: u32 = self.viewRows();
        // Anything but moving through links ends the highlight.
        if (code != Key.tab and code != Key.enter) clearFocus(t);
        if (mods.ctrl) {
            switch (code) {
                'c' => if (t.selection) |s| try self.copySelection(t, s) else self.requestQuit(),
                'q' => self.requestQuit(),
                'r' => try self.setMode(t, .edit),
                'f' => self.startPrompt(.find),
                'o' => self.startPrompt(.open),
                'w' => self.closeTab(),
                'd' => self.scrollBy(t, @intCast(view / 2)),
                'u' => self.scrollBy(t, -@as(i32, @intCast(view / 2))),
                'z' => try self.suspendRequest(),
                else => {},
            }
            return;
        }
        switch (code) {
            // Too easy to press by reflex to end a session, so it only says what does.
            'q' => self.say("Ctrl+Q quits, Ctrl+W closes the tab", .{}),
            'e', 'i' => try self.setMode(t, .edit),
            'j', Key.down => self.scrollBy(t, 1),
            'k', Key.up => self.scrollBy(t, -1),
            ' ', Key.page_down, 'f' => self.scrollBy(t, @intCast(view -| 2)),
            'b', Key.page_up => self.scrollBy(t, -@as(i32, @intCast(view -| 2))),
            'd' => self.scrollBy(t, @intCast(view / 2)),
            'u' => self.scrollBy(t, -@as(i32, @intCast(view / 2))),
            'g', Key.home => self.scrollTo(t, 0),
            'G', Key.end => self.scrollTo(t, self.maxTop(t)),
            Key.tab => self.focusLink(t, mods.shift),
            Key.enter => {
                if (t.focus != 0) {
                    const url = t.layout.?.links.items[t.focus - 1].url;
                    clearFocus(t);
                    try self.follow(url);
                }
            },
            '/' => self.startPrompt(.find),
            'o' => self.startPrompt(.open),
            'n' => try self.findNext(t, false, false),
            'N' => try self.findNext(t, true, false),
            '[' => self.switchTab(-1),
            ']' => self.switchTab(1),
            't' => self.nextPalette(),
            'r' => try self.reload(t),
            '?' => {
                if (std.mem.eql(u8, t.name, "help")) {
                    self.closeTab();
                } else {
                    const text = if (self.settings.experimental_edit) help_text ++ "\n" ++ help_editor_text else help_text;
                    _ = try self.openText("help", text, true);
                }
            },
            Key.escape => {
                self.query.clearRetainingCapacity();
                self.match_rows.clearRetainingCapacity();
                t.selection = null;
            },
            else => {},
        }
    }

    fn suspendRequest(self: *App) !void {
        self.want_suspend = true;
    }

    fn scrollBy(self: *App, t: *Tab, by: i32) void {
        const target: i64 = @as(i64, t.top) + by;
        self.scrollTo(t, @intCast(@max(target, 0)));
    }

    fn switchTab(self: *App, by: i32) void {
        const n: i32 = @intCast(self.tabs.items.len);
        if (n < 2) return;
        self.active = @intCast(@mod(@as(i32, @intCast(self.active)) + by, n));
        self.screen.invalidate();
    }

    fn nextPalette(self: *App) void {
        self.settings.palette = (self.settings.palette + 1) % theme.palettes.len;
        self.screen.th.palette = self.settings.palette;
        for (self.tabs.items) |t| t.layout_gen = 0; // heading images carry the old color
        self.screen.invalidate();
        self.say("Palette: {s}", .{theme.palettes[self.settings.palette].name});
        self.saveConfig();
    }

    fn editKey(self: *App, t: *Tab, code: u21, mods: input.Mods) !void {
        const e = &t.ed;
        const w: u32 = self.textWidth();
        const view: u32 = self.viewRows();
        const t0 = trace.now();
        defer _ = trace.end(.edit, t0);
        const sh = mods.shift;
        if (mods.ctrl) {
            switch (code) {
                's' => try self.save(t),
                'q' => self.requestQuit(),
                'r' => try self.setMode(t, .preview),
                'z' => _ = try e.undo(),
                'y' => _ = try e.redo(),
                'b' => try e.toggleWrap("**"),
                'i' => try e.toggleWrap("*"),
                'k' => try e.insertLink(),
                't' => {
                    const new = try tidy.run(self.gpa, e.text());
                    defer self.gpa.free(new);
                    if (!std.mem.eql(u8, new, e.text())) try e.replaceAll(new);
                    self.say("Tidied", .{});
                },
                'f' => self.startPrompt(.find),
                'o' => self.startPrompt(.open),
                'g' => try self.findNext(t, sh, false),
                'a' => e.selectAll(),
                'c' => {
                    if (e.selectedText()) |s| try self.copy(s) else self.requestQuit();
                },
                'x' => {
                    if (e.selectedText()) |s| {
                        try self.copy(s);
                        try e.backspace();
                    }
                },
                'v' => {
                    if (self.clip.items.len > 0) try e.insert(self.clip.items, .other);
                },
                'w' => self.closeTab(),
                Key.left => e.wordLeft(sh),
                Key.right => e.wordRight(sh),
                Key.home => e.moveTo(0, sh),
                Key.end => e.moveTo(@intCast(e.text().len), sh),
                else => {},
            }
        } else if (mods.alt) {
            switch (code) {
                'i' => try e.toggleWrap("*"),
                'c' => try e.toggleWrap("`"),
                Key.left, 'b' => e.wordLeft(sh),
                Key.right, 'f' => e.wordRight(sh),
                else => {},
            }
        } else switch (code) {
            Key.escape => {
                if (e.selection() != null) e.anchor = null else try self.setMode(t, .preview);
            },
            Key.left => e.left(sh),
            Key.right => e.right(sh),
            Key.up => try e.vertical(false, w, sh),
            Key.down => try e.vertical(true, w, sh),
            Key.home => e.home(sh),
            Key.end => e.end(sh),
            Key.page_up => for (0..view -| 1) |_| try e.vertical(false, w, sh),
            Key.page_down => for (0..view -| 1) |_| try e.vertical(true, w, sh),
            Key.backspace => try e.backspace(),
            Key.delete => try e.deleteForward(),
            Key.enter => try e.newline(),
            Key.tab => try e.insert("    ", .other),
            else => {
                if (code >= 0x20 and code <= 0x10FFFF) {
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(code, &b) catch return;
                    try e.insert(b[0..n], .insert);
                }
            },
        }
        if (t.mode == .edit and self.tabs.items.len > 0) try e.reveal(w, view);
    }

    fn copy(self: *App, s: []const u8) !void {
        self.clip.clearRetainingCapacity();
        try self.clip.appendSlice(self.gpa, s);
        // OSC 52 puts it on the system clipboard, even over SSH.
        const enc = std.base64.standard.Encoder;
        const n = enc.calcSize(s.len);
        try self.out.appendSlice(self.gpa, "\x1b]52;c;");
        try self.out.ensureUnusedCapacity(self.gpa, n);
        _ = enc.encode(self.out.unusedCapacitySlice()[0..n], s);
        self.out.items.len += n;
        try self.out.appendSlice(self.gpa, "\x1b\\");
        self.say("Copied", .{});
    }

    fn promptKey(self: *App, code: u21, mods: input.Mods) !void {
        const t = self.tab();
        switch (self.prompt) {
            .confirm_close, .confirm_quit => {
                const quitting = self.prompt == .confirm_quit;
                switch (code) {
                    'y', 'Y' => {
                        self.prompt = .none;
                        try self.save(t);
                        if (self.prompt != .none or t.ed.dirty()) return;
                        if (quitting) self.requestQuit() else self.dropTab();
                    },
                    'n', 'N' => {
                        self.prompt = .none;
                        t.ed.saved_generation = t.ed.generation;
                        if (quitting) self.requestQuit() else self.dropTab();
                    },
                    Key.escape => self.prompt = .none,
                    else => {},
                }
                return;
            },
            else => {},
        }
        if (mods.ctrl and code == 'c') {
            self.prompt = .none;
            return;
        }
        self.prompt_hint.clearRetainingCapacity();
        switch (code) {
            Key.escape => self.prompt = .none,
            Key.tab => if (self.prompt == .open) try self.completeOpen(),
            Key.enter => {
                const p = self.prompt;
                self.prompt = .none;
                switch (p) {
                    .find => {
                        self.query.clearRetainingCapacity();
                        try self.query.appendSlice(self.gpa, self.prompt_text.items);
                        if (t.mode == .preview) {
                            try self.ensureLayout(t);
                            try self.updateMatches(t);
                        }
                        try self.findNext(t, false, true);
                        if (t.mode == .edit) try t.ed.reveal(self.textWidth(), self.viewRows());
                    },
                    .save_as => {
                        if (self.prompt_text.items.len == 0) return;
                        const z = try self.gpa.dupeSentinel(u8, self.prompt_text.items, 0);
                        if (t.path) |old| self.gpa.free(old);
                        t.path = z;
                        t.name = std.fs.path.basename(z);
                        t.read_only = false;
                        try self.save(t);
                    },
                    .open => try self.openPrompted(),
                    else => {},
                }
            },
            Key.backspace => {
                const s = self.prompt_text.items;
                var n = s.len;
                while (n > 0) {
                    n -= 1;
                    if (s[n] & 0xC0 != 0x80) break;
                }
                self.prompt_text.shrinkRetainingCapacity(n);
            },
            else => {
                if (code >= 0x20 and code <= 0x10FFFF and !mods.ctrl) {
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(code, &b) catch return;
                    try self.prompt_text.appendSlice(self.gpa, b[0..n]);
                }
            },
        }
    }

    /// True for the mouse moving without changing anything on screen. There can be a lot of these,
    /// so the terminal loop skips the frame.
    pub fn idleMotion(self: *const App, e: input.Event) bool {
        if (e != .mouse) return false;
        const m = e.mouse;
        return m.motion and m.button == .none and self.hoverAt(m) == self.hover;
    }

    fn mouse(self: *App, m: input.Mouse) !void {
        // Only motion counts. A click must not reveal the button it's landing on, or a terminal
        // that doesn't report hover would close tabs from a cell showing nothing.
        if (m.motion) self.hover = self.hoverAt(m);
        const t = self.tab();
        const w: u32 = self.textWidth();
        const bar = self.barRows();
        if (m.button == .wheel_up or m.button == .wheel_down) {
            const by: i32 = if (m.button == .wheel_down) 3 else -3;
            clearFocus(t);
            if (t.mode == .preview) {
                try self.ensureLayout(t);
                self.scrollBy(t, by);
            } else try t.ed.scroll(by, w);
            return;
        }
        if (bar > 0 and m.y == 0 and m.press and !m.motion) return self.clickTabBar(m);
        // A drag can leave the view, and that's how it scrolls.
        // A press is always a new start, in case the last release happened outside the window.
        if (t.mode == .preview and self.drag_from != null and (m.motion or !m.press)) return self.previewDrag(t, m);
        if (m.y < bar or m.y >= bar + self.viewRows()) return;
        const y = m.y - bar;
        const x0 = self.leftMargin();
        if (t.mode == .edit) {
            if (m.button != .left) return;
            if (!m.press) {
                self.dragging = false;
                return;
            }
            const pos = try t.ed.posAt(m.x -| x0, y, w);
            t.ed.moveTo(pos, m.motion and self.dragging);
            self.dragging = true;
            return;
        }
        if (m.button != .left or !m.press or m.motion) return;
        try self.ensureLayout(t);
        t.selection = null;
        self.drag_from = self.pointAt(t, m);
    }

    /// The cell under the mouse, in layout rows. Past either end of the view, a drag scrolls.
    fn pointAt(self: *App, t: *Tab, m: input.Mouse) selection.Point {
        const bar = self.barRows();
        const view = self.viewRows();
        if (m.y < bar) self.scrollBy(t, -1);
        if (m.y >= bar + view) self.scrollBy(t, 1);
        const y = @min(m.y -| bar, view -| 1);
        const last: u32 = @intCast(t.layout.?.rows.items.len -| 1);
        return .{ .row = @min(t.top + y, last), .col = m.x -| self.leftMargin() };
    }

    fn previewDrag(self: *App, t: *Tab, m: input.Mouse) !void {
        if (m.button != .left) return;
        try self.ensureLayout(t);
        const from = self.drag_from orelse return;
        const at = self.pointAt(t, m);
        if (m.press) {
            if (t.selection != null or at.row != from.row or at.col != from.col) t.selection = .{ .anchor = from, .head = at };
            return;
        }
        self.drag_from = null;
        if (t.selection) |s| return self.copySelection(t, s);
        try self.clickPreview(t, m);
    }

    fn copySelection(self: *App, t: *Tab, s: Selection) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try s.text(self.gpa, &t.layout.?, &text);
        if (text.items.len > 0) try self.copy(text.items);
    }

    /// A click, meaning the button came up where it went down.
    fn clickPreview(self: *App, t: *Tab, m: input.Mouse) !void {
        const bar = self.barRows();
        if (m.y < bar or m.y >= bar + self.viewRows()) return;
        const l = &t.layout.?;
        const row = t.top + m.y - bar;
        if (row >= l.rows.items.len) return;
        var col: u32 = self.leftMargin();
        for (l.rowSpans(l.rows.items[row])) |s| {
            if (m.x >= col and m.x < col + s.width) {
                if (s.link != 0) {
                    t.focus = s.link;
                    clearFocus(t);
                    try self.follow(l.links.items[s.link - 1].url);
                }
                return;
            }
            col += s.width;
        }
    }

    const TabHit = struct { tab: usize, close: bool };

    /// The tab at column x of the bar, and whether x is its close button. Each tab is its name and
    /// three cells: the unsaved mark, the close button and a gap.
    fn tabAt(self: *const App, x: u16) ?TabHit {
        var col: u32 = 1;
        for (self.tabs.items, 0..) |t, i| {
            const name = t.nameCols();
            if (x >= col and x < col + name + 3) return .{ .tab = i, .close = x == col + name + 1 };
            col += name + 3;
        }
        return null;
    }

    fn hoverAt(self: *const App, m: input.Mouse) ?usize {
        if (self.barRows() == 0 or m.y != 0) return null;
        const hit = self.tabAt(m.x) orelse return null;
        return hit.tab;
    }

    fn clickTabBar(self: *App, m: input.Mouse) void {
        // A prompt is about the tab it opened on, and answering it mustn't land on another.
        if (self.prompt != .none) return;
        const hit = self.tabAt(m.x) orelse return;
        if (hit.close and m.button == .left and self.hover == hit.tab) {
            self.closeTabAt(hit.tab);
            // The next tab has slid under the mouse, which hasn't moved.
            self.hover = self.hoverAt(m);
            return;
        }
        self.active = hit.tab;
        self.screen.invalidate();
    }

    // Painting.

    /// Builds the next frame and appends what changed to out.
    pub fn frame(self: *App) !void {
        const t0 = trace.now();
        const tick = self.hud_tick;
        self.hud_tick = false;
        defer if (tick) trace.skipFrame() else {
            _ = trace.end(.frame, t0);
            trace.record(self.cause, self.screen.sent_rows, self.last_bytes);
            self.cause = .none;
        };
        if (self.tabs.items.len == 0) return;
        const t = self.tab();
        const sc = &self.screen;
        const before_len = self.out.items.len;

        if (t.mode == .preview) try self.ensureLayout(t);
        const paint0 = trace.now();
        sc.begin();
        self.store.frame += 1;
        const base = sc.th.base();
        if (self.barRows() > 0) try self.paintTabBar(base);
        var cursor: ?screen_mod.Cursor = null;
        switch (t.mode) {
            .preview => try self.paintPreview(t, base),
            .edit => {
                const finish = RowEnd{ .app = self, .base = base, .view = self.viewRows() };
                try t.ed.paint(sc, self.leftMargin(), self.textWidth(), self.viewRows(), base, self.query.items, sc.cols -| 1, finish);
                if (try t.ed.cursorCell(self.textWidth(), self.viewRows())) |c| {
                    cursor = .{ .x = self.leftMargin() + c.x, .y = c.y + self.barRows() };
                }
            },
        }
        if (self.frameRows() > 0) try self.paintRule(base);
        try self.paintStatus(t, base, &cursor);
        if (self.hudRows() > 0) try self.paintHud(t, base);
        if (self.frameRows() > 0) {
            sc.row(sc.cols);
            try sc.endRow(base);
        }
        sc.end();
        _ = trace.end(.paint, paint0);

        const flush0 = trace.now();
        const hint = if (t.mode == .edit or self.store.mode == .direct) 0 else self.scroll_hint;
        self.scroll_hint = 0;
        const bar = self.barRows();
        try sc.flush(&self.out, cursor, hint, bar, bar + self.viewRows());
        _ = trace.end(.flush, flush0);

        if (self.store.mode == .direct and t.mode == .preview) try self.placeDirect(t);
        if (t.mode != self.shown_mode) {
            self.shown_mode = t.mode;
            // A bar cursor while editing, the terminal's own otherwise.
            try self.out.appendSlice(self.gpa, if (t.mode == .edit) "\x1b[5 q" else "\x1b[0 q");
        }
        self.last_bytes = self.out.items.len - before_len;
    }

    fn paintTabBar(self: *App, base: Style) !void {
        const sc = &self.screen;
        sc.row(sc.cols);
        try sc.pad(base, 1);
        for (self.tabs.items, 0..) |t, i| {
            var st = base;
            st.fg = Color.role(if (i == self.active) .text else .dim);
            st.attrs.bold = i == self.active;
            st.attrs.underline = i == self.active;
            if (t.url != null) try sc.text(base, web_icon);
            try sc.text(st, t.name);
            if (t.ed.dirty()) try sc.text(st, "*") else try sc.text(base, " ");
            if (self.hover == i) {
                var close = base;
                close.fg = Color.role(.muted);
                try sc.text(close, "×");
            } else try sc.text(base, " ");
            try sc.text(base, " ");
        }
        try sc.endRow(base);
    }

    /// A thin line across the window, as near as a terminal gets to a single pixel.
    fn paintRule(self: *App, base: Style) !void {
        const sc = &self.screen;
        sc.row(sc.cols);
        var st = base;
        st.fg = Color.role(.dim);
        try sc.text(st, md.thin_buf);
        try sc.endRow(base);
    }

    fn paintPreview(self: *App, t: *Tab, base: Style) !void {
        const sc = &self.screen;
        const l = &t.layout.?;
        const view = self.viewRows();
        const x0 = self.leftMargin();
        const total: u32 = @intCast(l.rows.items.len);

        var y: u16 = 0;
        while (y < view) : (y += 1) {
            sc.row(sc.cols -| 1);
            const idx = t.top + y;
            if (idx < total) {
                const r = l.rows.items[idx];
                try sc.padTo(base, x0);
                try self.paintRow(t, l, r, idx, base);
                if (r.image != 0) try self.paintImageRow(r);
                if (!(r.fill.kind == .role and r.fill.value == 0)) {
                    var st = base;
                    st.bg = r.fill;
                    try sc.padTo(st, x0 + self.textWidth());
                }
            }
            try self.rowEnd(base, y, view, total, t.top);
        }
    }

    fn paintRow(self: *App, t: *Tab, l: *const md.Layout, r: md.Row, index: u32, base: Style) !void {
        const sc = &self.screen;
        const q = self.query.items;
        const selected = if (t.selection) |s| s.cells(index) else null;
        var col: u32 = 0;
        for (l.rowSpans(r)) |s| {
            var st = s.style;
            if (st.bg.kind == .role and st.bg.value == 0) st.bg = base.bg;
            if (s.link != 0 and s.link == t.focus) st.attrs.reverse = true;
            const url = if (s.link != 0) l.links.items[s.link - 1].url else "";
            const linked = url.len > 0 and schemeOf(url) != null and safeUrl(url) and sc.th.color;
            if (linked) {
                try sc.raw("\x1b]8;;");
                try sc.raw(url);
                try sc.raw("\x1b\\");
            }
            if (selected) |range| {
                const i = selection.cellOffset(s.text, range[0] -| col);
                const j = selection.cellOffset(s.text, range[1] -| col);
                var hit = st;
                hit.attrs.reverse = !st.attrs.reverse;
                try sc.text(st, s.text[0..i]);
                try sc.text(hit, s.text[i..j]);
                try sc.text(st, s.text[j..]);
            } else if (q.len == 0) {
                try sc.text(st, s.text);
            } else {
                var i: usize = 0;
                while (editor.indexOfFold(s.text, i, q)) |m| {
                    try sc.text(st, s.text[i..m]);
                    var hit = st;
                    hit.bg = Color.role(.accent);
                    if (theme.palettes[sc.th.palette].rgb != null) hit.fg = Color.role(.bg) else hit.attrs.reverse = false;
                    try sc.text(hit, s.text[m .. m + q.len]);
                    i = m + q.len;
                }
                try sc.text(st, s.text[i..]);
            }
            if (linked) try sc.raw("\x1b]8;;\x1b\\");
            col += s.width;
        }
    }

    fn paintImageRow(self: *App, r: md.Row) !void {
        const sc = &self.screen;
        const idx = r.image - 1;
        const im = &self.store.items.items[idx];
        // Upload on first sight, so a long document only pays for what's seen.
        const t0 = trace.now();
        try self.store.prepare(&self.out, idx, r.image_cols, r.image_rows);
        if (!im.sent) return;
        _ = trace.end(.image, t0);
        if (self.store.mode == .placeholder) {
            try self.store.placeholderRow(&sc.bytes, sc.gpa, idx, r.image_row, r.image_cols);
            sc.col += r.image_cols;
            sc.style = null;
        } else {
            try sc.pad(sc.th.base(), r.image_cols);
        }
    }

    /// Places each visible image for terminals without placeholders.
    fn placeDirect(self: *App, t: *Tab) !void {
        const l = &t.layout.?;
        const view = self.viewRows();
        const bar = self.barRows();
        const total: u32 = @intCast(l.rows.items.len);
        const seen = try self.gpa.alloc(bool, self.store.items.items.len);
        defer self.gpa.free(seen);
        @memset(seen, false);
        var y: u16 = 0;
        while (y < view and t.top + y < total) : (y += 1) {
            const r = l.rows.items[t.top + y];
            if (r.image == 0 or seen[r.image - 1]) continue;
            seen[r.image - 1] = true;
            const rows = r.image_rows;
            const count = @min(rows - r.image_row, view - y);
            var x: u16 = self.leftMargin();
            for (l.rowSpans(r)) |s| x += @intCast(s.width);
            try self.store.placeDirect(&self.out, r.image - 1, x, y + bar, r.image_row, count, rows, r.image_cols);
        }
        for (seen, 0..) |s, i| if (!s) try self.store.hideDirect(&self.out, @intCast(i));
    }

    fn rowEnd(self: *App, base: Style, y: u32, view: u32, total: u32, top: u32) !void {
        const sc = &self.screen;
        if (total > view and sc.th.color) {
            const thumb = @max(view * view / total, 1);
            const span = view - thumb;
            const pos = @as(u64, top) * span / @max(total - view, 1);
            sc.limit = sc.cols;
            try sc.padTo(base, sc.cols - 1);
            var st = base;
            st.fg = Color.role(.dim);
            try sc.text(st, if (y >= pos and y < pos + thumb) "┃" else " ");
        }
        try sc.endRow(base);
    }

    /// A dim label and its value, with a gap after.
    fn hudPair(self: *App, base: Style, label: []const u8, value: []const u8, value_role: theme.Role) !void {
        const sc = &self.screen;
        var st = base;
        st.fg = Color.role(.dim);
        try sc.text(st, label);
        try sc.pad(st, 1);
        st.fg = Color.role(value_role);
        try sc.text(st, value);
        try sc.pad(base, 3);
    }

    /// Three rows under the status line: frame times and their recent history, the frame rates they
    /// meet, and what the last frame cost.
    /// Writes the recent frames to a file to attach to a bug report. It says what the machine was
    /// doing and nothing about the document: no names, no text, no keys.
    fn saveFrameLog(self: *App) !void {
        const t = self.tab();
        const g = self.gpa;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(g);
        const terminal = if (std.c.getenv("TERM_PROGRAM")) |v| std.mem.span(v) else "unknown";
        const rows = if (t.layout) |l| l.rows.items.len else 0;
        var head: [256]u8 = undefined;
        try out.appendSlice(g, std.fmt.bufPrint(&head, "# tmd frame log\n\ntmd {s} on {s}, {d} x {d} cells. Document: {d} bytes, {d} rows. Images: {s}.\n\n", .{
            build_options.version, terminal, self.screen.cols, self.screen.rows, t.ed.text().len, rows, @tagName(self.store.mode),
        }) catch "# tmd frame log\n\n");
        try trace.report(g, &out);
        try out.appendSlice(g, "\n## Last frames\n\nTimes are in milliseconds, and frames in bold missed 60 fps.\n\n");
        try trace.frameLog(g, &out);

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const dir = if (std.c.getenv("TMPDIR")) |v| std.mem.trimEnd(u8, std.mem.span(v), "/") else "/tmp";
        const path = try std.fmt.allocPrintSentinel(g, "{s}/tmd-frames-{d}.md", .{ dir, ts.sec }, 0);
        defer g.free(path);
        files.writeNew(path, out.items) catch {
            self.say("Can't write the frame log", .{});
            return;
        };
        self.say("Frame log: {s}", .{path});
    }

    fn paintHud(self: *App, t: *Tab, base: Style) !void {
        const sc = &self.screen;
        const x0 = self.leftMargin();
        const end = x0 + self.textWidth();
        var buf: [64]u8 = undefined;
        var buf2: [32]u8 = undefined;

        sc.row(end);
        try sc.padTo(base, x0);
        const f = trace.recentStats(.frame, 120);
        const late = f.p99 > budget_us;
        try self.hudPair(base, "frame", std.fmt.bufPrint(&buf, "{f} ms", .{trace.ms(f.p50, 2)}) catch "", .text);
        try self.hudPair(base, "p99", std.fmt.bufPrint(&buf, "{f} ms", .{trace.ms(f.p99, 2)}) catch "", if (late) .accent else .code);
        try self.paintSparkline(base, end);
        try sc.endRow(base);

        sc.row(end);
        try sc.padTo(base, x0);
        try self.hudPair(base, "fps", std.fmt.bufPrint(&buf, "{d}", .{trace.drawnFps()}) catch "", .text);
        try self.hudPair(base, "max", std.fmt.bufPrint(&buf, "{d}", .{1_000_000 / @max(f.p99, 1)}) catch "", if (late) .accent else .code);
        const slow = trace.slowFrames();
        try self.hudPair(base, "slow", std.fmt.bufPrint(&buf, "{d}", .{slow}) catch "", if (slow > 0) .accent else .code);
        try self.hudPair(base, "F11", "save log", .dim);
        try sc.endRow(base);

        sc.row(end);
        try sc.padTo(base, x0);
        const sent = std.fmt.bufPrint(&buf, "{d} rows, {s}", .{ sc.sent_rows, formatBytes(&buf2, self.last_bytes) }) catch "";
        try self.hudPair(base, "sent", sent, .text);
        try self.hudPair(base, "layout", std.fmt.bufPrint(&buf, "{f} ms", .{trace.ms(trace.stats(.layout).max, 1)}) catch "", .text);
        try self.hudPair(base, "peak", formatBytes(&buf, maxRssKb() * 1024), .text);
        const rows = if (t.layout) |l| l.rows.items.len else 0;
        try self.hudPair(base, "file", std.fmt.bufPrint(&buf, "{s}, {d} rows", .{ formatBytes(&buf2, t.ed.text().len), rows }) catch "", .text);
        try sc.endRow(base);
    }

    /// The frame rates the recent p99 frame fits, met ones lit and the rest dimmed. This is tmd's
    /// own work per frame: what the screen shows still depends on the terminal and display.

    /// Recent frames, newest on the right, up to column end. The scale is logarithmic: frames vary
    /// from microseconds to milliseconds, and a slow one should stand out from either.
    fn paintSparkline(self: *App, base: Style, end: u16) !void {
        const sc = &self.screen;
        var vals: [160]u32 = undefined;
        const room = @min(end -| sc.col, vals.len);
        const bars = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
        for (trace.recent(.frame, vals[0..room])) |us| {
            const level = @min(@as(u32, std.math.log2_int(u32, us + 1)) * 8 / 15, 7);
            var st = base;
            st.fg = Color.role(if (us > budget_us) .accent else .code);
            try sc.text(st, bars[level]);
        }
    }

    fn paintStatus(self: *App, t: *Tab, base: Style, cursor: *?screen_mod.Cursor) !void {
        const sc = &self.screen;
        sc.row(sc.cols);
        var st = base;
        st.fg = Color.role(.dim);
        const x0 = self.leftMargin();
        try sc.padTo(base, x0);
        var buf: [256]u8 = undefined;
        switch (self.prompt) {
            .find, .save_as, .open => {
                var text = base;
                text.fg = Color.role(.text);
                const label = switch (self.prompt) {
                    .find => "Find: ",
                    .open => "Open: ",
                    else => "Save as: ",
                };
                try sc.text(st, label);
                try sc.text(text, self.prompt_text.items);
                cursor.* = .{ .x = sc.col, .y = sc.y };
                if (self.prompt_hint.items.len > 0) {
                    try sc.pad(base, 3);
                    try sc.text(st, self.prompt_hint.items);
                }
                try sc.endRow(base);
                return;
            },
            .confirm_close, .confirm_quit => {
                var text = base;
                text.fg = Color.role(.accent);
                try sc.text(text, std.fmt.bufPrint(&buf, "Save changes to {s}? y yes, n no, Esc cancel", .{t.name}) catch "Save changes?");
                try sc.endRow(base);
                return;
            },
            .none => {},
        }
        if (self.message.len > 0) {
            var text = base;
            text.fg = Color.role(.muted);
            try sc.text(text, self.message);
            try sc.endRow(base);
            return;
        }
        if (t.url) |u| {
            // The address says where this came from, but the position still has to fit beside it.
            const stop = selection.cellOffset(u, self.textWidth() -| 24);
            try sc.text(st, u[0..stop]);
            if (stop < u.len) try sc.text(st, "…");
        } else try sc.text(st, t.name);
        if (t.ed.dirty()) try sc.text(st, " *");
        var right: []const u8 = "";
        if (t.mode == .preview) {
            const l = &t.layout.?;
            const n: u32 = @intCast(l.rows.items.len);
            const max = n -| self.viewRows();
            const pct = if (max == 0) 100 else @as(u64, t.top) * 100 / max;
            const hint = if (self.settings.experimental_edit) "e edit  " else "";
            right = std.fmt.bufPrint(&buf, "{d}%  {s}? help", .{ pct, hint }) catch "";
        } else {
            const line = t.ed.lineOf(t.ed.cursor);
            right = std.fmt.bufPrint(&buf, "line {d}/{d}  Esc preview  ^S save", .{ line + 1, t.ed.lineCount() }) catch "";
        }
        const rw: u16 = @intCast(width.of(right));
        const end = x0 + self.textWidth();
        if (end > rw + sc.col) {
            try sc.padTo(base, end - rw);
            try sc.text(st, right);
        }
        try sc.endRow(base);
    }

    pub fn saveConfig(self: *App) void {
        const p = self.config_path orelse return;
        var buf: [1024]u8 = undefined;
        const s = self.settings;
        const text = std.fmt.bufPrint(&buf, "palette = {s}\nwidth = {d}\nopen = {s}\nimages = {s}\nbig_headings = {s}\n{s}{s}{s}{s}", .{
            theme.palettes[s.palette].name,
            s.max_width,
            @tagName(s.open_in),
            if (s.images) "on" else "off",
            if (s.big_headings) "on" else "off",
            if (s.heading_font != null) "heading_font = " else "",
            if (s.heading_font) |f| f else "",
            if (s.heading_font != null) "\n" else "",
            if (s.experimental_edit) "experimental_edit = on\n" else "",
        }) catch return;
        // The directory may not exist yet.
        if (std.fs.path.dirname(p)) |dir| {
            if (self.gpa.dupeSentinel(u8, dir, 0)) |z| {
                defer self.gpa.free(z);
                _ = std.c.mkdir(z.ptr, 0o755);
            } else |_| {}
        }
        files.writeAtomic(self.gpa, p, text) catch {};
    }

};

const RowEnd = struct {
    app: *App,
    base: Style,
    view: u32,

    pub fn call(self: RowEnd, sc: *Screen, y: u32) !void {
        _ = sc;
        const t = self.app.tab();
        try self.app.rowEnd(self.base, y, self.view, t.ed.lineCount(), t.ed.top_line);
    }
};

const budget_us = 16_700;

fn formatBytes(buf: []u8, n: u64) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "";
    if (n < 1024 * 1024) return std.fmt.bufPrint(buf, "{f} KB", .{trace.ms(n * 1000 / 1024, 1)}) catch "";
    return std.fmt.bufPrint(buf, "{f} MB", .{trace.ms(n * 1000 / (1024 * 1024), 1)}) catch "";
}

fn maxRssKb() u64 {
    var ru: std.c.rusage = undefined;
    if (std.c.getrusage(0, &ru) != 0) return 0;
    const v: u64 = @intCast(ru.maxrss);
    return if (@import("builtin").os.tag == .macos) v / 1024 else v;
}

/// Ends a link's highlight, remembering where it was.
fn clearFocus(t: *Tab) void {
    if (t.focus != 0) t.last_link = t.focus;
    t.focus = 0;
}

fn schemeOf(url: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    if (colon < 2) return null;
    for (url[0..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return url[0..colon];
}

/// Whether a URL can go in an escape sequence: no control characters, including the C1 ones, which
/// some terminals act on as raw bytes and others as UTF-8.
fn safeUrl(url: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(url)) return false;
    for (url, 0..) |c, i| {
        if (c < 0x20 or c == 0x7f) return false;
        if (c == 0xc2 and url[i + 1] < 0xa0) return false;
    }
    return true;
}

/// Whether a local file is safe to hand to the system's opener, which would run a script or an app.
/// Link text can say anything, so a click isn't enough to go on.
fn safeToOpen(path: []const u8) bool {
    const exts = [_][]const u8{ ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".csv", ".tsv", ".html", ".htm", ".mp3", ".mp4", ".mov", ".wav" };
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(path, e)) return true;
    return false;
}

fn normalizeNewlines(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len);
    for (s, 0..) |c, i| {
        if (c == '\r') {
            if (i + 1 < s.len and s[i + 1] == '\n') continue;
            out.appendAssumeCapacity('\n');
        } else out.appendAssumeCapacity(c);
    }
    return out.toOwnedSlice(gpa);
}
