//! Images through the kitty graphics protocol. The preferred path uses Unicode placeholders: the
//! image is uploaded once and then exists as ordinary cells in the grid, so it scrolls, clips and
//! diffs exactly like text. Terminals without placeholders get direct placements, re-placed as the
//! view moves. PNG files are sent as they are; everything else is decoded and scaled first.
const std = @import("std");
const files = @import("layout").files;
const diacritics = @import("diacritics.zig").table;
const md = @import("layout").md;
const fetch = @import("fetch.zig");
const merz = @import("merz");

// vendor/decoders.c
const c = struct {
    extern fn tm_info(data: [*]const u8, len: c_int, w: *c_int, h: *c_int) c_int;
    extern fn tm_decode(data: [*]const u8, len: c_int, w: *c_int, h: *c_int) ?[*]u8;
    extern fn tm_free(p: ?*anyopaque) void;
    extern fn tm_svg_size(svg: [*:0]u8, w: *c_int, h: *c_int) c_int;
    extern fn tm_svg_render(svg: [*:0]u8, out_w: c_int, w: *c_int, h: *c_int) ?[*]u8;
    extern fn tm_font_load(data: [*]const u8) c_int;
    extern fn tm_text_width(cps: [*]const c_int, n: c_int, px: f32) c_int;
    extern fn tm_text_render(cps: [*]const c_int, n: c_int, px: f32, out: [*]u8, w: c_int, h: c_int) void;
};

/// Bold sans fonts to look for, first found wins. heading_font in the config overrides them.
const fonts = [_][:0]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
    "/usr/share/fonts/noto/NotoSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Verdana Bold.ttf",
};

/// A cell this tall in device pixels means a high-density display: text that size at normal density
/// would be unusually large.
const dense_cell_h = 24;

/// Height in rows of a large heading, by level.
fn headingRows(level: u32) u16 {
    return if (level == 1) 3 else 2;
}

pub const Mode = enum { off, placeholder, direct };

/// Whether images hosted on the web load: never, always, or once the host is approved.
pub const RemoteMode = enum { ask, off, on };

const Kind = enum { png, raster, svg, text };

const max_file = 64 * 1024 * 1024;
const max_pixels = 64 * 1024 * 1024;

pub const Image = struct {
    path: [:0]const u8,
    kind: Kind,
    w: u32,
    h: u32,
    id: u32,
    sent: bool = false,
    failed: bool = false,
    /// A downloaded web image, kept in a temp file that is unlinked on exit.
    tmp: bool = false,
    /// The frame this image was last on screen.
    used: u64 = 0,
    /// Pixel size of what was uploaded, which may be scaled from the source.
    sent_w: u32 = 0,
    sent_h: u32 = 0,
    // Large headings: the text, its level and color.
    text: []const u8 = "",
    level: u32 = 0,
    rgb: u24 = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    // Where a direct placement currently is.
    at_y: i32 = -1,
    at_x: u16 = 0,
    at_first: u16 = 0,
    at_count: u16 = 0,
};

const no_width = std.math.maxInt(u32);

pub const Store = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Image) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    mode: Mode = .off,
    cell_w: u32 = 10,
    cell_h: u32 = 20,
    tmux: bool = false,
    /// Directory relative paths resolve against.
    dir: []const u8 = ".",
    id_base: u32 = 0,
    /// The current frame, for choosing what to evict.
    frame: u64 = 0,
    /// Pixels are kept under this many bytes of the terminal's memory by dropping images that are
    /// off screen; they upload again if they come back. Terminals limit this, some silently.
    budget: usize = 256 * 1024 * 1024,
    used_bytes: usize = 0,
    /// Device pixels per cell_w and cell_h. Layout counts in cell_w and cell_h, and uploads are
    /// drawn at this multiple of them, so they land on the display's own pixels.
    scale: u32 = 1,
    /// Size images in points on a high-density display, as pages do, rather than in device pixels.
    points: bool = false,
    /// Changes with the cell size, so layouts made for the old one get made again.
    cell_gen: u32 = 0,
    big_headings: bool = true,
    heading_rgb: u24 = 0xBD93F9,
    font_path: ?[:0]const u8 = null,
    font: ?[]u8 = null,
    font_tried: bool = false,
    /// The document came from the web, so its relative paths mean nothing on this disk.
    no_files: bool = false,
    /// The page's URL, if any, so relative image paths resolve to absolute ones.
    base_url: ?[]const u8 = null,
    /// Whether web-hosted images load: ask (per host), off, or on.
    remote_mode: RemoteMode = .ask,
    /// Off in tests and the benchmark, so an image is never fetched in a child process there.
    spawn: bool = true,
    /// Hosts approved this session. Keys owned.
    approved: std.StringHashMapUnmanaged(void) = .empty,
    /// Web images already fetched, keyed by absolute URL. Keys owned; the image's temp file is path.
    remote_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// Mermaid diagrams already rendered, keyed by block source. Keys owned; the PNG is a temp file.
    mermaid_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// Web images this layout wanted but couldn't load without approval, and one of their hosts.
    blocked: u32 = 0,
    blocked_host_buf: [255]u8 = undefined,
    blocked_host_len: usize = 0,
    /// Names the temp files downloaded images go in.
    tmp_seq: u32 = 0,
    /// Heading widths in columns, by level and text. They don't depend on the window, so a resize
    /// doesn't pay for the font's kerning table again. no_width marks text the font can't draw.
    widths: std.StringHashMapUnmanaged(u32) = .empty,
    /// The cell size the widths were measured at.
    widths_cell: [3]u32 = .{ 0, 0, 0 },

    pub fn deinit(self: *Store) void {
        for (self.items.items) |i| {
            if (i.tmp) _ = std.c.unlink(i.path.ptr);
            self.gpa.free(i.path);
            if (i.text.len > 0) self.gpa.free(i.text);
        }
        if (self.font) |f| self.gpa.free(f);
        self.items.deinit(self.gpa);
        self.index.deinit(self.gpa);
        self.freeKeys(&self.approved);
        self.approved.deinit(self.gpa);
        self.freeKeys(&self.remote_index);
        self.remote_index.deinit(self.gpa);
        self.freeKeys(&self.mermaid_index);
        self.mermaid_index.deinit(self.gpa);
        self.clearWidths();
        self.widths.deinit(self.gpa);
    }

    fn freeKeys(self: *Store, map: anytype) void {
        var it = map.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
    }

    fn clearWidths(self: *Store) void {
        var it = self.widths.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.widths.clearRetainingCapacity();
    }

    /// Uses a cell size given in device pixels, and says whether it changed. Uploads made for the old
    /// size go too, since they were drawn for cells that no longer exist.
    pub fn setCell(self: *Store, out: *std.ArrayList(u8), w: u32, h: u32) !bool {
        const scale: u32 = if (self.points and h >= dense_cell_h) 2 else 1;
        const cw = @max(w / scale, 1);
        const ch = @max(h / scale, 1);
        if (cw == self.cell_w and ch == self.cell_h and scale == self.scale) return false;
        try self.deleteAll(out);
        self.forgetSent();
        self.cell_w = cw;
        self.cell_h = ch;
        self.scale = scale;
        self.cell_gen +%= 1;
        return true;
    }

    pub fn source(self: *Store) md.Images {
        return .{ .ctx = self, .fit = fitOpaque, .measure = measureOpaque, .heading = headingOpaque, .mermaid = mermaidOpaque };
    }

    fn loadFont(self: *Store) bool {
        if (self.mode == .off or !self.big_headings) return false;
        return self.ensureFont();
    }

    /// Loads a sans font for the rasterisers (large headings and mermaid diagrams), once. Unlike
    /// loadFont this ignores big_headings, since a diagram needs a font even when headings stay plain.
    fn ensureFont(self: *Store) bool {
        if (self.font_tried) return self.font != null;
        self.font_tried = true;
        if (self.font_path) |p| {
            if (self.tryFont(p)) return true;
        }
        for (fonts) |p| if (self.tryFont(p)) return true;
        return false;
    }

    fn tryFont(self: *Store, path: [:0]const u8) bool {
        const data = files.read(self.gpa, path.ptr, max_file) catch return false;
        if (c.tm_font_load(data.ptr) == 0) {
            self.gpa.free(data);
            return false;
        }
        self.font = data;
        return true;
    }

    fn headingPx(self: *const Store, level: u32) f32 {
        const h: f32 = @floatFromInt(headingRows(level) * self.cell_h * self.scale);
        return h * 0.8;
    }

    /// Columns text needs as a large heading, or null if it can't be drawn.
    fn measure(self: *Store, text: []const u8, level: u32) ?u16 {
        if (!self.loadFont()) return null;
        const cell = [3]u32{ self.cell_w, self.cell_h, self.scale };
        if (!std.mem.eql(u32, &cell, &self.widths_cell)) {
            self.clearWidths();
            self.widths_cell = cell;
        }
        // Text past this is more codepoints than a heading can have, which measureText refuses.
        var buf: [1 + 512 * 4]u8 = undefined;
        if (text.len + 1 > buf.len) return self.measureText(text, level);
        buf[0] = @intCast(level);
        @memcpy(buf[1..][0..text.len], text);
        const key = buf[0 .. text.len + 1];
        if (self.widths.get(key)) |w| return if (w == no_width) null else @intCast(w);

        const cols = self.measureText(text, level);
        const owned = self.gpa.dupe(u8, key) catch return cols;
        self.widths.put(self.gpa, owned, cols orelse no_width) catch self.gpa.free(owned);
        return cols;
    }

    fn measureText(self: *Store, text: []const u8, level: u32) ?u16 {
        var cps: [512]c_int = undefined;
        const n = codepoints(text, &cps) orelse return null;
        const w = c.tm_text_width(&cps, @intCast(n), self.headingPx(level));
        if (w < 0) return null;
        const cell = self.cell_w * self.scale;
        return @intCast(@min((@as(u32, @intCast(w)) + cell - 1) / cell, 60000));
    }

    fn measureOpaque(ctx: *anyopaque, text: []const u8, level: u32) ?u16 {
        const self: *Store = @ptrCast(@alignCast(ctx));
        return self.measure(text, level);
    }

    fn headingOpaque(ctx: *anyopaque, text: []const u8, level: u32, cols: u16) ?md.Images.Fit {
        const self: *Store = @ptrCast(@alignCast(ctx));
        return self.heading(text, level, cols) catch null;
    }

    fn heading(self: *Store, text: []const u8, level: u32, cols: u16) !md.Images.Fit {
        const rows = headingRows(level);
        const key = try std.fmt.allocPrintSentinel(self.gpa, "\x00{d}:{x}:{d}:{d}:{s}", .{ level, self.heading_rgb, self.cell_w, self.cell_h, text }, 0);
        if (self.index.get(key)) |i| {
            self.gpa.free(key);
            return .{ .image = i + 1, .cols = cols, .rows = rows };
        }
        errdefer self.gpa.free(key);
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);
        const n: u32 = @intCast(self.items.items.len);
        try self.items.append(self.gpa, .{
            .path = key,
            .kind = .text,
            .w = @as(u32, cols) * self.cell_w * self.scale,
            .h = @as(u32, rows) * self.cell_h * self.scale,
            .id = self.id_base + n + 1,
            .text = owned,
            .level = level,
            .rgb = self.heading_rgb,
        });
        try self.index.put(self.gpa, key, n);
        return .{ .image = n + 1, .cols = cols, .rows = rows };
    }

    /// Draws a heading as RGBA: its color, with the glyphs' coverage as alpha.
    fn renderHeading(self: *Store, im: *const Image) ![]u8 {
        var cps: [512]c_int = undefined;
        const n = codepoints(im.text, &cps) orelse return error.DecodeFailed;
        const count = @as(usize, im.w) * im.h;
        const alpha = try self.gpa.alloc(u8, count);
        defer self.gpa.free(alpha);
        @memset(alpha, 0);
        c.tm_text_render(&cps, @intCast(n), self.headingPx(im.level), alpha.ptr, @intCast(im.w), @intCast(im.h));
        const px = try self.gpa.alloc(u8, count * 4);
        for (alpha, 0..) |a, i| {
            px[i * 4] = @intCast(im.rgb >> 16);
            px[i * 4 + 1] = @intCast((im.rgb >> 8) & 255);
            px[i * 4 + 2] = @intCast(im.rgb & 255);
            px[i * 4 + 3] = a;
        }
        return px;
    }

    /// Drops the images least recently seen until need more bytes fit.
    fn makeRoom(self: *Store, out: *std.ArrayList(u8), need: usize) !void {
        var buf: [64]u8 = undefined;
        while (self.used_bytes + need > self.budget) {
            var oldest: ?*Image = null;
            for (self.items.items) |*im| {
                if (!im.sent or im.used >= self.frame) continue;
                if (oldest == null or im.used < oldest.?.used) oldest = im;
            }
            const im = oldest orelse return;
            try self.command(out, try std.fmt.bufPrint(&buf, "a=d,d=I,i={d},q=2", .{im.id}));
            self.used_bytes -|= @as(usize, im.sent_w) * im.sent_h * 4;
            im.sent = false;
            im.cols = 0;
            im.rows = 0;
            im.at_y = -1;
        }
    }

    fn fitOpaque(ctx: *anyopaque, url: []const u8, cols: u16, rows: u16) ?md.Images.Fit {
        const self: *Store = @ptrCast(@alignCast(ctx));
        return self.fit(url, cols, rows) catch null;
    }

    fn fit(self: *Store, url: []const u8, max_cols: u16, max_rows: u16) !?md.Images.Fit {
        if (self.mode == .off) return null;
        const idx = (try self.lookup(url)) orelse return null;
        return self.fitIndex(idx, max_cols, max_rows);
    }

    /// Sizes an already-registered image to fit within max_cols by max_rows, never upscaling past
    /// the image's own pixels.
    fn fitIndex(self: *Store, idx: u32, max_cols: u16, max_rows: u16) md.Images.Fit {
        const im = self.items.items[idx];
        const cw = self.cell_w;
        const ch = self.cell_h;
        var cols: u32 = @min(max_cols, (im.w + cw - 1) / cw);
        var rows: u32 = @intCast((@as(u64, cols) * cw * im.h / im.w + ch - 1) / ch);
        const limit: u32 = @min(max_rows, diacritics.len - 1);
        if (rows > limit) {
            rows = limit;
            cols = @intCast((@as(u64, rows) * ch * im.w / im.h + cw - 1) / cw);
        }
        return .{ .image = idx + 1, .cols = @intCast(@max(@min(cols, max_cols), 1)), .rows = @intCast(@max(rows, 1)) };
    }

    fn mermaidOpaque(ctx: *anyopaque, src: []const u8, cols: u16, rows: u16) ?md.Images.Fit {
        const self: *Store = @ptrCast(@alignCast(ctx));
        return self.mermaid(src, cols, rows) catch null;
    }

    fn mermaid(self: *Store, src: []const u8, max_cols: u16, max_rows: u16) !?md.Images.Fit {
        if (self.mode == .off) return null;
        const idx = (try self.renderMermaid(src)) orelse return null;
        return self.fitIndex(idx, max_cols, max_rows);
    }

    /// Renders a mermaid block to a PNG in a temp file and registers it, once per distinct source.
    /// Returns null when there's no usable font or the diagram can't be parsed or drawn.
    fn renderMermaid(self: *Store, src: []const u8) !?u32 {
        if (self.mermaid_index.get(src)) |i| return i;
        if (!self.ensureFont()) return null;
        const font = self.font orelse return null;
        const png = merz.renderPng(self.gpa, src, font) catch return null;
        defer self.gpa.free(png);
        const path = try self.tempFile(png);
        errdefer {
            _ = std.c.unlink(path.ptr);
            self.gpa.free(path);
        }
        const info = identify(self.gpa, path) orelse {
            _ = std.c.unlink(path.ptr);
            self.gpa.free(path);
            return null;
        };
        const key = try self.gpa.dupe(u8, src);
        errdefer self.gpa.free(key);
        const n: u32 = @intCast(self.items.items.len);
        try self.items.append(self.gpa, .{
            .path = path,
            .kind = info.kind,
            .w = info.w,
            .h = info.h,
            .id = self.id_base + n + 1,
            .tmp = true,
        });
        try self.mermaid_index.put(self.gpa, key, n);
        return n;
    }

    fn lookup(self: *Store, url: []const u8) !?u32 {
        if (url.len == 0 or std.mem.startsWith(u8, url, "data:")) return null;
        if (try self.remoteUrl(url)) |abs| {
            defer self.gpa.free(abs);
            return self.lookupRemote(abs);
        }
        if (self.no_files) return null;
        const path = try self.resolve(url);
        errdefer self.gpa.free(path);
        if (self.index.get(path)) |i| {
            self.gpa.free(path);
            return i;
        }
        const info = identify(self.gpa, path) orelse {
            self.gpa.free(path);
            return null;
        };
        const n: u32 = @intCast(self.items.items.len);
        try self.items.append(self.gpa, .{
            .path = path,
            .kind = info.kind,
            .w = info.w,
            .h = info.h,
            .id = self.id_base + n + 1,
        });
        try self.index.put(self.gpa, path, n);
        return n;
    }

    /// The absolute http(s) URL an image resolves to, or null when it's an ordinary local path.
    /// Caller frees a returned slice.
    fn remoteUrl(self: *Store, url: []const u8) !?[]u8 {
        if (std.mem.indexOf(u8, url, "://") != null) {
            return if (fetch.isUrl(url)) try self.gpa.dupe(u8, url) else null;
        }
        const base = self.base_url orelse return null;
        const abs = try fetch.resolve(self.gpa, base, url);
        if (!fetch.isUrl(abs)) {
            self.gpa.free(abs);
            return null;
        }
        return abs;
    }

    fn remoteAllowed(self: *const Store, host: []const u8) bool {
        return switch (self.remote_mode) {
            .off => false,
            .on => true,
            .ask => self.approved.contains(host),
        };
    }

    /// An approved web image, fetched once and cached; otherwise null, with the want recorded so the
    /// status row can offer to load it. The request is the user's, never the document's.
    fn lookupRemote(self: *Store, abs: []const u8) !?u32 {
        if (self.remote_index.get(abs)) |i| return i;
        const host = fetch.hostOf(abs);
        if (!self.spawn or !self.remoteAllowed(host)) {
            self.blocked += 1;
            if (self.blocked_host_len == 0) {
                const n = @min(host.len, self.blocked_host_buf.len);
                @memcpy(self.blocked_host_buf[0..n], host[0..n]);
                self.blocked_host_len = n;
            }
            return null;
        }
        const path = self.fetchRemote(abs) catch return null;
        errdefer {
            _ = std.c.unlink(path.ptr);
            self.gpa.free(path);
        }
        const info = identify(self.gpa, path) orelse {
            _ = std.c.unlink(path.ptr);
            self.gpa.free(path);
            return null;
        };
        const key = try self.gpa.dupe(u8, abs);
        errdefer self.gpa.free(key);
        const n: u32 = @intCast(self.items.items.len);
        try self.items.append(self.gpa, .{
            .path = path,
            .kind = info.kind,
            .w = info.w,
            .h = info.h,
            .id = self.id_base + n + 1,
            .tmp = true,
        });
        try self.remote_index.put(self.gpa, key, n);
        return n;
    }

    fn fetchRemote(self: *Store, abs: []const u8) ![:0]const u8 {
        const bytes = try fetch.getBytes(self.gpa, abs);
        defer self.gpa.free(bytes);
        return self.tempFile(bytes);
    }

    /// Writes bytes to a fresh temp file (unlinked on exit) and returns its owned path.
    fn tempFile(self: *Store, bytes: []const u8) ![:0]const u8 {
        const path = try std.fmt.allocPrintSentinel(self.gpa, "{s}/tmd-{d}-{d}", .{ tmpDir(), std.c.getpid(), self.tmp_seq }, 0);
        errdefer self.gpa.free(path);
        self.tmp_seq += 1;
        // A leftover from a recycled pid would block the exclusive create.
        _ = std.c.unlink(path.ptr);
        try files.writeNew(path, bytes);
        return path;
    }

    /// Approves loading web images from a host for the rest of the session.
    pub fn approveHost(self: *Store, host: []const u8) !void {
        if (host.len == 0 or self.approved.contains(host)) return;
        const owned = try self.gpa.dupe(u8, host);
        errdefer self.gpa.free(owned);
        try self.approved.put(self.gpa, owned, {});
    }

    /// A host of an image this layout couldn't load without approval.
    pub fn blockedHost(self: *const Store) []const u8 {
        return self.blocked_host_buf[0..self.blocked_host_len];
    }

    fn resolve(self: *Store, url: []const u8) ![:0]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        if (url[0] != '/') {
            try buf.appendSlice(self.gpa, self.dir);
            try buf.append(self.gpa, '/');
        }
        try percentDecode(self.gpa, &buf, url);
        return self.gpa.dupeSentinel(u8, buf.items, 0);
    }

    /// Wraps a graphics command for tmux, if there is one in the way.
    fn command(self: *Store, out: *std.ArrayList(u8), body: []const u8) !void {
        const g = self.gpa;
        if (self.tmux) {
            try out.appendSlice(g, "\x1bPtmux;\x1b\x1b_G");
            try out.appendSlice(g, body);
            try out.appendSlice(g, "\x1b\x1b\\\x1b\\");
        } else {
            try out.appendSlice(g, "\x1b_G");
            try out.appendSlice(g, body);
            try out.appendSlice(g, "\x1b\\");
        }
    }

    fn transmit(self: *Store, out: *std.ArrayList(u8), im: *Image, cols: u16, rows: u16) !void {
        var head_buf: [96]u8 = undefined;
        var head: []const u8 = undefined;
        var bytes: []const u8 = undefined;
        var free_pixels: ?[*]u8 = null;
        var owned: ?[]u8 = null;
        defer {
            if (free_pixels) |p| c.tm_free(p);
            if (owned) |o| self.gpa.free(o);
        }
        const target_w = @as(u32, cols) * self.cell_w * self.scale;
        const target_h = @as(u32, rows) * self.cell_h * self.scale;
        im.sent_w = im.w;
        im.sent_h = im.h;

        switch (im.kind) {
            .png => {
                owned = try files.read(self.gpa, im.path.ptr, max_file);
                bytes = owned.?;
                head = try std.fmt.bufPrint(&head_buf, "a=t,f=100,i={d},q=2", .{im.id});
            },
            .raster => {
                const file = try files.read(self.gpa, im.path.ptr, max_file);
                defer self.gpa.free(file);
                var w: c_int = 0;
                var h: c_int = 0;
                const px = c.tm_decode(file.ptr, @intCast(file.len), &w, &h) orelse return error.DecodeFailed;
                free_pixels = px;
                const uw: u32 = @intCast(w);
                const uh: u32 = @intCast(h);
                if (uw > target_w * 2 and target_w > 0) {
                    const sw = @max(target_w, 1);
                    const sh = @max(target_h, 1);
                    owned = try shrink(self.gpa, px[0 .. uw * uh * 4], uw, uh, sw, sh);
                    bytes = owned.?;
                    im.sent_w = sw;
                    im.sent_h = sh;
                    head = try std.fmt.bufPrint(&head_buf, "a=t,f=32,s={d},v={d},i={d},q=2", .{ sw, sh, im.id });
                } else {
                    bytes = px[0 .. uw * uh * 4];
                    head = try std.fmt.bufPrint(&head_buf, "a=t,f=32,s={d},v={d},i={d},q=2", .{ uw, uh, im.id });
                }
            },
            .text => {
                owned = try self.renderHeading(im);
                bytes = owned.?;
                head = try std.fmt.bufPrint(&head_buf, "a=t,f=32,s={d},v={d},i={d},q=2", .{ im.w, im.h, im.id });
            },
            .svg => {
                const file = try files.read(self.gpa, im.path.ptr, max_file);
                defer self.gpa.free(file);
                const z = try self.gpa.dupeSentinel(u8, file, 0);
                defer self.gpa.free(z);
                var w: c_int = 0;
                var h: c_int = 0;
                const px = c.tm_svg_render(z.ptr, @intCast(@max(target_w, 1)), &w, &h) orelse return error.DecodeFailed;
                free_pixels = px;
                const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
                bytes = px[0..n];
                im.sent_w = @intCast(w);
                im.sent_h = @intCast(h);
                head = try std.fmt.bufPrint(&head_buf, "a=t,f=32,s={d},v={d},i={d},q=2", .{ w, h, im.id });
            },
        }

        // The protocol wants payloads of at most 4096 base64 bytes per escape sequence.
        const enc = std.base64.standard.Encoder;
        var chunk: [4096 + 128]u8 = undefined;
        var pos: usize = 0;
        var first = true;
        while (first or pos < bytes.len) {
            const n = @min(bytes.len - pos, 3072);
            const more = pos + n < bytes.len;
            var w: usize = 0;
            if (first) {
                @memcpy(chunk[0..head.len], head);
                w = head.len;
                chunk[w] = ',';
                w += 1;
            }
            const tail = if (more) "m=1;" else "m=0;";
            @memcpy(chunk[w..][0..tail.len], tail);
            w += tail.len;
            w += enc.encode(chunk[w..], bytes[pos..][0..n]).len;
            try self.command(out, chunk[0..w]);
            pos += n;
            first = false;
        }
        im.sent = true;
    }

    /// Makes an image ready to show at this size. Uploads it the first time; a later size change
    /// only replaces the placement.
    pub fn prepare(self: *Store, out: *std.ArrayList(u8), idx: u32, cols: u16, rows: u16) !void {
        const im = &self.items.items[idx];
        if (im.failed) return;
        im.used = self.frame;
        if (!im.sent) {
            const need = @as(usize, im.w) * im.h * 4;
            try self.makeRoom(out, need);
            self.transmit(out, im, cols, rows) catch {
                im.failed = true;
                return;
            };
            self.used_bytes += @as(usize, im.sent_w) * im.sent_h * 4;
        }
        if (self.mode != .placeholder or (im.cols == cols and im.rows == rows)) return;
        var buf: [96]u8 = undefined;
        if (im.cols != 0) try self.command(out, try std.fmt.bufPrint(&buf, "a=d,d=i,i={d},q=2", .{im.id}));
        try self.command(out, try std.fmt.bufPrint(&buf, "a=p,U=1,i={d},c={d},r={d},q=2", .{ im.id, cols, rows }));
        im.cols = cols;
        im.rows = rows;
    }

    /// The cells for one row of an image in placeholder mode. The foreground color carries the
    /// image id; only the first cell needs its position, and the rest continue from it.
    pub fn placeholderRow(self: *Store, out: *std.ArrayList(u8), g: std.mem.Allocator, idx: u32, row: u16, cols: u16) !void {
        const id = self.items.items[idx].id;
        var buf: [32]u8 = undefined;
        try out.appendSlice(g, try std.fmt.bufPrint(&buf, "\x1b[0;38;2;{d};{d};{d}m", .{ (id >> 16) & 255, (id >> 8) & 255, id & 255 }));
        try appendCp(out, g, 0x10EEEE);
        try appendCp(out, g, diacritics[row]);
        try appendCp(out, g, diacritics[0]);
        for (1..cols) |_| try appendCp(out, g, 0x10EEEE);
    }

    /// Moves a direct placement to show image rows [first, first+count) at screen cell (x, y).
    pub fn placeDirect(self: *Store, out: *std.ArrayList(u8), idx: u32, x: u16, y: u16, first: u16, count: u16, rows: u16, cols: u16) !void {
        const im = &self.items.items[idx];
        if (im.failed) return;
        if (im.at_y == y and im.at_x == x and im.at_first == first and im.at_count == count) return;
        im.at_y = y;
        im.at_x = x;
        im.at_first = first;
        im.at_count = count;
        const py = im.sent_h * first / rows;
        const ph = @max(im.sent_h * count / rows, 1);
        var buf: [128]u8 = undefined;
        try out.appendSlice(self.gpa, try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }));
        try self.command(out, try std.fmt.bufPrint(&buf, "a=p,i={d},p=1,c={d},r={d},x=0,y={d},w={d},h={d},C=1,q=2", .{ im.id, cols, count, py, im.sent_w, ph }));
    }

    /// Removes the placement of an image that left the view.
    pub fn hideDirect(self: *Store, out: *std.ArrayList(u8), idx: u32) !void {
        const im = &self.items.items[idx];
        if (im.at_y < 0) return;
        im.at_y = -1;
        var buf: [64]u8 = undefined;
        try self.command(out, try std.fmt.bufPrint(&buf, "a=d,d=i,i={d},q=2", .{im.id}));
    }

    pub fn sentCount(self: *const Store) usize {
        var n: usize = 0;
        for (self.items.items) |im| {
            if (im.sent) n += 1;
        }
        return n;
    }

    /// Frees everything tmd put in the terminal's image memory.
    /// The terminal's copies are gone, as they are after a suspend, so everything uploads again as
    /// it comes back into view.
    pub fn forgetSent(self: *Store) void {
        for (self.items.items) |*im| {
            im.sent = false;
            im.cols = 0;
            im.rows = 0;
            im.at_y = -1;
        }
        self.used_bytes = 0;
    }

    pub fn deleteAll(self: *Store, out: *std.ArrayList(u8)) !void {
        var buf: [64]u8 = undefined;
        for (self.items.items) |im| {
            if (im.sent) try self.command(out, try std.fmt.bufPrint(&buf, "a=d,d=I,i={d},q=2", .{im.id}));
        }
    }
};

fn tmpDir() []const u8 {
    if (std.c.getenv("TMPDIR")) |d| {
        const s = std.mem.span(d);
        if (s.len > 0) return std.mem.trimEnd(u8, s, "/");
    }
    return "/tmp";
}

fn codepoints(text: []const u8, out: []c_int) ?usize {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return null).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n == out.len) return null;
        out[n] = cp;
        n += 1;
    }
    return if (n > 0) n else null;
}

fn appendCp(out: *std.ArrayList(u8), g: std.mem.Allocator, cp: u21) !void {
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch return;
    try out.appendSlice(g, b[0..n]);
}

fn percentDecode(g: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                if (b != 0) try out.append(g, b);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(g, s[i]);
        i += 1;
    }
}

pub fn decodePercent(g: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(g);
    try percentDecode(g, &out, s);
    return out.toOwnedSlice(g);
}

const Info = struct { kind: Kind, w: u32, h: u32 };

fn identify(g: std.mem.Allocator, path: [:0]const u8) ?Info {
    var head_buf: [256 * 1024]u8 = undefined;
    const head = files.readHead(path.ptr, &head_buf) catch return null;
    if (head.len == 0) return null;
    var w: c_int = 0;
    var h: c_int = 0;
    if (c.tm_info(head.ptr, @intCast(head.len), &w, &h) != 0 and w > 0 and h > 0) {
        if (@as(u64, @intCast(w)) * @as(u64, @intCast(h)) > max_pixels) return null;
        const png = std.mem.startsWith(u8, head, "\x89PNG");
        return .{ .kind = if (png) .png else .raster, .w = @intCast(w), .h = @intCast(h) };
    }
    if (std.mem.indexOf(u8, head[0..@min(head.len, 4096)], "<svg") != null) {
        const file = files.read(g, path.ptr, max_file) catch return null;
        defer g.free(file);
        const z = g.dupeSentinel(u8, file, 0) catch return null;
        defer g.free(z);
        if (c.tm_svg_size(z.ptr, &w, &h) == 0) return null;
        return .{ .kind = .svg, .w = @intCast(w), .h = @intCast(h) };
    }
    return null;
}

/// Box-filters RGBA pixels down to tw x th.
fn shrink(g: std.mem.Allocator, px: []const u8, w: u32, h: u32, tw: u32, th: u32) ![]u8 {
    const out = try g.alloc(u8, @as(usize, tw) * th * 4);
    for (0..th) |y| {
        const y0 = y * h / th;
        const y1 = @max((y + 1) * h / th, y0 + 1);
        for (0..tw) |x| {
            const x0 = x * w / tw;
            const x1 = @max((x + 1) * w / tw, x0 + 1);
            var sum: [4]u32 = @splat(0);
            var n: u32 = 0;
            for (y0..y1) |sy| {
                for (x0..x1) |sx| {
                    const p = px[(sy * w + sx) * 4 ..][0..4];
                    for (0..4) |k| sum[k] += p[k];
                    n += 1;
                }
            }
            const o = out[(y * tw + x) * 4 ..][0..4];
            for (0..4) |k| o[k] = @intCast(sum[k] / n);
        }
    }
    return out;
}

const testing = std.testing;
const build_options = @import("build_options");

test "a mermaid block renders to a cached diagram image" {
    const gpa = testing.allocator;
    const path = try gpa.allocSentinel(u8, build_options.test_font.len, 0);
    defer gpa.free(path);
    @memcpy(path, build_options.test_font);
    const font = try files.read(gpa, path.ptr, max_file);

    var s = Store{ .gpa = gpa, .mode = .placeholder, .cell_w = 10, .cell_h = 20 };
    s.font = font; // deinit frees it
    s.font_tried = true;
    defer s.deinit();

    const src = "flowchart TD\n A[Start] --> B((End))";
    const fit = (try s.mermaid(src, 80, 24)) orelse return error.NotRendered;
    try testing.expect(fit.cols >= 1 and fit.rows >= 1);
    try testing.expectEqual(@as(usize, 1), s.items.items.len);
    try testing.expectEqual(Kind.png, s.items.items[0].kind);
    try testing.expect(s.items.items[0].tmp);

    // The same source is served from cache, not rendered again.
    const again = (try s.mermaid(src, 40, 24)).?;
    try testing.expectEqual(fit.image, again.image);
    try testing.expectEqual(@as(usize, 1), s.items.items.len);

    // Invalid UTF-8 in a label must not crash the rasteriser; it still renders.
    const bad = "flowchart TD\n A[\xff\xfe bad\x80utf] --> B((\xc3end))";
    const bf = (try s.mermaid(bad, 80, 24)) orelse return error.NotRendered;
    try testing.expect(bf.cols >= 1 and bf.rows >= 1);

    // A diagram type merz doesn't handle returns null, so the document shows it as code.
    try testing.expectEqual(@as(?md.Images.Fit, null), try s.mermaid("sequenceDiagram\n A->>B: hi", 80, 24));
    // A pathological fan-out is refused (too large), also falling back to code.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "flowchart TD\n");
    for (0..5000) |i| {
        var line: [32]u8 = undefined;
        try big.appendSlice(gpa, try std.fmt.bufPrint(&line, " ROOT --> N{d}\n", .{i}));
    }
    try testing.expectEqual(@as(?md.Images.Fit, null), try s.mermaid(big.items, 80, 24));
}

test "web images wait for the host to be approved" {
    var s = Store{ .gpa = testing.allocator, .mode = .placeholder };
    defer s.deinit();
    s.base_url = "https://ex.com/docs/page.md";

    // A relative image resolves against the page and so needs approval; it isn't fetched.
    try testing.expectEqual(@as(?u32, null), try s.lookup("img/a.png"));
    try testing.expectEqual(@as(u32, 1), s.blocked);
    try testing.expectEqualStrings("ex.com", s.blockedHost());

    // An absolute image on another host blocks too, and the first host is the one offered.
    try testing.expectEqual(@as(?u32, null), try s.lookup("https://cdn.net/b.png"));
    try testing.expectEqual(@as(u32, 2), s.blocked);
    try testing.expectEqualStrings("ex.com", s.blockedHost());

    // Approving a host is remembered, and a different host still isn't allowed.
    try s.approveHost("ex.com");
    try testing.expect(s.remoteAllowed("ex.com"));
    try testing.expect(!s.remoteAllowed("cdn.net"));
    try testing.expectEqual(@as(usize, 0), s.items.items.len);
}

test "off never loads web images, on always allows them" {
    var s = Store{ .gpa = testing.allocator, .mode = .placeholder, .remote_mode = .off };
    defer s.deinit();
    s.base_url = "https://ex.com/a.md";
    try testing.expect(!s.remoteAllowed("ex.com"));
    s.remote_mode = .on;
    try testing.expect(s.remoteAllowed("anywhere.example"));
}

test "a local path is not treated as remote" {
    var s = Store{ .gpa = testing.allocator, .mode = .placeholder };
    defer s.deinit();
    // No base URL, so a relative path stays local (and simply finds no file here).
    try testing.expectEqual(@as(?u32, null), try s.lookup("pic.png"));
    try testing.expectEqual(@as(u32, 0), s.blocked);
    // With a base URL, a root-relative path is still remote.
    s.base_url = "https://ex.com/docs/page.md";
    _ = try s.lookup("/logo.png");
    try testing.expectEqual(@as(u32, 1), s.blocked);
}
