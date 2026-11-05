//! Markdown to display rows. Blocks are parsed straight into wrapped rows of styled spans for a given
//! width, with no tree in between. Spans point into the document wherever they can.
const std = @import("std");
const vt = @import("ghostty-vt");
const theme = @import("theme.zig");
const width = @import("width.zig");
const inl = @import("inline.zig");
const Style = theme.Style;
const Color = theme.Color;
const Tok = inl.Tok;

pub const Span = struct {
    text: []const u8,
    style: Style,
    width: u32,
    link: u32 = 0,
};

/// How a row continues the one above it: a new line, or a wrap that took out a space or nothing.
pub const Join = enum(u8) { none, space, tight };

pub const Row = struct {
    first: u32,
    count: u32 = 0,
    /// Byte offset in the document of the block this row came from.
    src: u32,
    /// Background for the rest of the row, for code blocks.
    fill: Color = Color.none,
    /// Image index plus one, drawn after the spans.
    image: u32 = 0,
    image_row: u16 = 0,
    image_rows: u16 = 0,
    image_cols: u16 = 0,
    /// Cells at the start that only decorate the row: quote bars, indents, code padding.
    lead: u16 = 0,
    join: Join = .none,
};

/// text is set when the heading is drawn as an image, so find can still reach it.
pub const Heading = struct { slug: []const u8, row: u32, text: []const u8 = "" };
pub const Link = struct { url: []const u8, row: u32 };

const no_row = std.math.maxInt(u32);

/// What a document needs from the image store.
pub const Images = struct {
    pub const Fit = struct { image: u32, cols: u16, rows: u16 };
    ctx: *anyopaque,
    fit: *const fn (ctx: *anyopaque, url: []const u8, cols: u16, rows: u16) ?Fit,
    /// Columns text takes as a large heading, or null if it can't be drawn large.
    measure: *const fn (ctx: *anyopaque, text: []const u8, level: u32) ?u16,
    heading: *const fn (ctx: *anyopaque, text: []const u8, level: u32, cols: u16) ?Fit,
};

pub const Options = struct {
    /// Width of the text column.
    width: u16,
    /// Images are scaled to fit this many rows.
    max_image_rows: u16 = 24,
    images: ?Images = null,
    /// Mark links that leave tmd with an arrow, for when they can be followed.
    link_marks: bool = false,
};

pub const Layout = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row) = .empty,
    spans: std.ArrayList(Span) = .empty,
    /// Link targets. Span.link indexes this, plus one.
    links: std.ArrayList(Link) = .empty,
    headings: std.ArrayList(Heading) = .empty,

    pub fn deinit(self: *Layout) void {
        self.rows.deinit(self.gpa);
        self.spans.deinit(self.gpa);
        self.links.deinit(self.gpa);
        self.headings.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn rowSpans(self: *const Layout, r: Row) []const Span {
        return self.spans.items[r.first..][0..r.count];
    }

    /// The row showing document offset src, for keeping the same text in view.
    pub fn rowForOffset(self: *const Layout, src: u32) u32 {
        var lo: usize = 0;
        var hi: usize = self.rows.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.rows.items[mid].src < src) lo = mid + 1 else hi = mid;
        }
        return @intCast(@min(lo, self.rows.items.len -| 1));
    }

    pub fn anchor(self: *const Layout, slug: []const u8) ?u32 {
        for (self.headings.items) |h| if (std.ascii.eqlIgnoreCase(h.slug, slug)) return h.row;
        return null;
    }
};

const spaces_buf = repeat(" ", 256);
pub const thin_buf = repeat("─", 400);
const thick_buf = repeat("━", 400);

fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const out = comptime blk: {
        @setEvalBranchQuota(100_000);
        var buf: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        break :blk buf;
    };
    return &out;
}

fn hline(comptime buf: []const u8, n: u32) []const u8 {
    return buf[0 .. @min(n, 400) * 3];
}

const Ctx = struct {
    parent: ?*Ctx = null,
    first: ?Span = null,
    cont: ?Span = null,
    width: u32,
    tight: bool = false,
    depth: u8 = 0,
    style: Style = .{},
};

const Piece = struct { text: []const u8, style: Style, link: u32, image: bool = false };

/// Follows a link that opens outside tmd. It isn't the document's text, so nothing that reads the
/// text back should take it for that: compare by pointer.
pub const link_mark = "\u{2197}";

pub fn isLinkMark(s: []const u8) bool {
    return s.ptr == link_mark.ptr;
}

pub fn isMarkdown(path: []const u8) bool {
    const exts = [_][]const u8{ ".md", ".markdown", ".mdown", ".txt" };
    for (exts) |e| if (std.ascii.endsWithIgnoreCase(path, e)) return true;
    return false;
}

/// Whether following a link leaves tmd: anything but an anchor or a page it can show as a tab.
fn leavesTmd(url: []const u8) bool {
    if (url.len == 0 or url[0] == '#') return false;
    return !isMarkdown(url[0 .. std.mem.indexOfAny(u8, url, "?#") orelse url.len]);
}

const Atom = struct {
    piece: u32,
    start: u32,
    end: u32,
    width: u32,
    kind: enum { word, space, br },
    /// No line break allowed between this and the next atom.
    glue: bool = false,
};

const CellLine = struct { first: u32, count: u32, width: u32 };

/// ASCII that can be part of a word.
const ascii_word = blk: {
    var t: [256]bool = @splat(false);
    for (0..0x80) |c| t[c] = true;
    for (" \t\n") |c| t[c] = false;
    break :blk t;
};

const Builder = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    src: []const u8,
    opts: Options,
    out: *Layout,
    refs: inl.Refs = .empty,
    row: Row = .{ .first = 0, .src = 0 },
    need_gap: bool = false,
    // Reused per paragraph.
    toks: std.ArrayList(Tok) = .empty,
    urls: std.ArrayList([]const u8) = .empty,
    pieces: std.ArrayList(Piece) = .empty,
    atoms: std.ArrayList(Atom) = .empty,
    // In a table cell, rows go here instead of the layout.
    cell: ?*std.ArrayList(CellLine) = null,
    cell_spans: std.ArrayList(Span) = .empty,
    line_width: u32 = 0,

    fn spans(self: *Builder) *std.ArrayList(Span) {
        return if (self.cell != null) &self.cell_spans else &self.out.spans;
    }

    fn off(self: *Builder, s: []const u8) u32 {
        const p = @intFromPtr(s.ptr);
        const base = @intFromPtr(self.src.ptr);
        return if (p >= base and p <= base + self.src.len) @intCast(p - base) else 0;
    }

    fn prefix(self: *Builder, ctx: *Ctx) !void {
        if (ctx.parent) |p| try self.prefix(p);
        if (ctx.first) |f| {
            try self.add(f.text, f.style, f.width, 0);
            ctx.first = null;
        } else if (ctx.cont) |c| {
            try self.add(c.text, c.style, c.width, 0);
        }
    }

    fn begin(self: *Builder, ctx: ?*Ctx, src: u32) !void {
        self.row = .{ .first = @intCast(self.spans().items.len), .src = src };
        self.line_width = 0;
        if (ctx) |c| try self.prefix(c);
        self.row.lead = @intCast(@min(self.line_width, std.math.maxInt(u16)));
        self.line_width = 0;
    }

    fn finish(self: *Builder) !void {
        self.row.count = @intCast(self.spans().items.len - self.row.first);
        if (self.cell) |lines| {
            try lines.append(self.a, .{ .first = self.row.first, .count = self.row.count, .width = self.line_width });
        } else {
            try self.out.rows.append(self.gpa, self.row);
        }
    }

    fn add(self: *Builder, text: []const u8, style: Style, w: u32, link: u32) !void {
        const all = self.spans();
        self.line_width += w;
        if (link != 0 and self.cell == null) {
            const l = &self.out.links.items[link - 1];
            if (l.row == no_row) l.row = @intCast(self.out.rows.items.len);
        }
        if (all.items.len > self.row.first) {
            const last = &all.items[all.items.len - 1];
            const contiguous = @intFromPtr(last.text.ptr) + last.text.len == @intFromPtr(text.ptr);
            if (contiguous and last.link == link and last.style.eql(style)) {
                last.text.len += text.len;
                last.width += w;
                return;
            }
        }
        try all.append(self.gpa, .{ .text = text, .style = style, .width = w, .link = link });
    }

    fn pad(self: *Builder, n: u32, style: Style) !void {
        var left = n;
        while (left > 0) {
            const k = @min(left, spaces_buf.len);
            try self.add(spaces_buf[0..k], style, k, 0);
            left -= k;
        }
    }

    fn gap(self: *Builder, ctx: *Ctx) !void {
        if (self.need_gap and !ctx.tight) {
            try self.begin(ctx, if (self.out.rows.items.len > 0) self.out.rows.items[self.out.rows.items.len - 1].src else 0);
            try self.finish();
        }
        self.need_gap = false;
    }

    // Inlines to pieces.

    fn scanInline(self: *Builder, text: []const u8, base: Style) !void {
        self.toks.clearRetainingCapacity();
        self.urls.clearRetainingCapacity();
        self.pieces.clearRetainingCapacity();
        var s = inl.Scanner{ .a = self.a, .toks = &self.toks, .links = &self.urls, .refs = &self.refs };
        try s.scan(text);

        // Doc-wide link ids.
        const base_link: u32 = @intCast(self.out.links.items.len);
        for (self.urls.items) |u| try self.out.links.append(self.gpa, .{ .url = u, .row = no_row });

        var seen_image: u32 = 0;
        for (self.toks.items) |t| {
            var st = base;
            st.attrs.bold = st.attrs.bold or t.bold;
            st.attrs.italic = st.attrs.italic or t.italic;
            st.attrs.strike = st.attrs.strike or t.strike;
            if (t.code) {
                st.fg = Color.role(.code);
                st.bg = Color.role(.code_bg);
            } else if (t.link != 0) {
                st.fg = Color.role(.link);
                st.attrs.underline = !t.image;
            }
            const link = if (t.link != 0) base_link + t.link else 0;
            switch (t.kind) {
                .syntax => {},
                .br => try self.pieces.append(self.a, .{ .text = "\n", .style = st, .link = 0 }),
                .delim => if (t.count > 0) {
                    // Whatever didn't pair stays as literal text.
                    try self.pieces.append(self.a, .{ .text = t.text[0..t.count], .style = st, .link = link });
                },
                .text, .bracket => {
                    if (t.image and t.link != seen_image) {
                        seen_image = t.link;
                        try self.pieces.append(self.a, .{ .text = "▣ ", .style = st, .link = link, .image = true });
                    }
                    try self.pieces.append(self.a, .{ .text = t.text, .style = st, .link = link, .image = t.image });
                },
            }
        }
        if (self.opts.link_marks) try self.markLinks();
    }

    /// Adds the arrow after the last piece of each link that leaves tmd. A link is often several
    /// pieces, so this looks at them all at once.
    fn markLinks(self: *Builder) !void {
        var i = self.pieces.items.len;
        while (i > 0) : (i -= 1) {
            const p = self.pieces.items[i - 1];
            if (p.link == 0 or p.image) continue;
            if (i < self.pieces.items.len and self.pieces.items[i].link == p.link) continue;
            if (!leavesTmd(self.out.links.items[p.link - 1].url)) continue;
            try self.pieces.insert(self.a, i, .{ .text = link_mark, .style = p.style, .link = p.link });
        }
    }

    fn atomize(self: *Builder) !void {
        self.atoms.clearRetainingCapacity();
        for (self.pieces.items, 0..) |p, pi| {
            const s = p.text;
            const idx: u32 = @intCast(pi);
            // An atom takes at least a byte, so this is enough for all of them.
            try self.atoms.ensureUnusedCapacity(self.a, s.len + 1);
            if (s.len == 1 and s[0] == '\n') {
                self.atoms.appendAssumeCapacity(.{ .piece = idx, .start = 0, .end = 0, .width = 0, .kind = .br });
                continue;
            }
            var i: usize = 0;
            while (i < s.len) {
                if (s[i] == ' ' or s[i] == '\t' or s[i] == '\n') {
                    const st = i;
                    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n')) i += 1;
                    self.atoms.appendAssumeCapacity(.{ .piece = idx, .start = @intCast(st), .end = @intCast(i), .width = 1, .kind = .space });
                    continue;
                }
                const st = i;
                // Nearly all of any word: a byte is a cell.
                while (i < s.len and ascii_word[s[i]]) i += 1;
                var w: u32 = @intCast(i - st);
                while (i < s.len and s[i] != ' ' and s[i] != '\t' and s[i] != '\n') {
                    if (s[i] < 0x80) {
                        w += 1;
                        i += 1;
                        continue;
                    }
                    const c = width.next(s[i..]);
                    // Wide characters break anywhere, as CJK text does.
                    if (c.width == 2) {
                        if (i > st) break;
                        w = 2;
                        i += c.len;
                        break;
                    }
                    w += c.width;
                    i += c.len;
                }
                self.atoms.appendAssumeCapacity(.{ .piece = idx, .start = @intCast(st), .end = @intCast(i), .width = w, .kind = .word });
            }
        }
        // A word split across styles still can't break in the middle.
        var k: usize = 0;
        while (k + 1 < self.atoms.items.len) : (k += 1) {
            const x = &self.atoms.items[k];
            const y = self.atoms.items[k + 1];
            if (x.kind == .word and y.kind == .word and x.piece != y.piece and x.width != 2 and y.width != 2) x.glue = true;
        }
    }

    fn addAtom(self: *Builder, at: Atom) !void {
        const p = self.pieces.items[at.piece];
        try self.add(p.text[at.start..at.end], p.style, at.width, p.link);
    }

    /// An atom too wide for any line: cut it at cluster boundaries.
    fn addHard(self: *Builder, ctx: ?*Ctx, src: u32, at: Atom, w: u32, col: *u32) !void {
        const p = self.pieces.items[at.piece];
        var i: usize = at.start;
        var st = i;
        var run: u32 = 0;
        while (i < at.end) {
            const c = width.next(p.text[i..at.end]);
            if (col.* + run + c.width > w and col.* + run > 0) {
                if (i > st) try self.add(p.text[st..i], p.style, run, p.link);
                try self.finish();
                try self.begin(ctx, src);
                self.row.join = .tight;
                col.* = 0;
                run = 0;
                st = i;
            }
            run += c.width;
            i += c.len;
        }
        if (i > st) try self.add(p.text[st..i], p.style, run, p.link);
        col.* += run;
    }

    /// Word-wraps the current pieces into rows of width w.
    fn wrap(self: *Builder, ctx: ?*Ctx, src: u32, w: u32) !void {
        try self.atomize();
        const atoms = self.atoms.items;
        try self.begin(ctx, src);
        var col: u32 = 0;
        var pending: ?Atom = null;
        var k: usize = 0;
        while (k < atoms.len) {
            const at = atoms[k];
            switch (at.kind) {
                .br => {
                    try self.finish();
                    try self.begin(ctx, src);
                    col = 0;
                    pending = null;
                    k += 1;
                },
                .space => {
                    if (col > 0) pending = at;
                    k += 1;
                },
                .word => {
                    var e = k;
                    var gw = at.width;
                    while (atoms[e].glue and e + 1 < atoms.len) {
                        e += 1;
                        gw += atoms[e].width;
                    }
                    const sp: u32 = if (pending != null) 1 else 0;
                    if (col > 0 and col + sp + gw > w) {
                        try self.finish();
                        try self.begin(ctx, src);
                        self.row.join = if (pending != null) .space else .tight;
                        col = 0;
                        pending = null;
                    }
                    if (pending) |s| {
                        const p = self.pieces.items[s.piece];
                        // The original space when it's a single one, so the span can stay whole.
                        const text = if (s.end - s.start == 1 and p.text[s.start] == ' ') p.text[s.start..s.end] else spaces_buf[0..1];
                        try self.add(text, p.style, 1, 0);
                        col += 1;
                        pending = null;
                    }
                    for (atoms[k .. e + 1]) |x| {
                        if (gw > w) {
                            try self.addHard(ctx, src, x, w, &col);
                        } else {
                            try self.addAtom(x);
                            col += x.width;
                        }
                    }
                    k = e + 1;
                },
            }
        }
        try self.finish();
    }

    // Blocks.

    fn paragraphText(self: *Builder, lines: []const []const u8) ![]const u8 {
        if (lines.len == 1) return std.mem.trimStart(u8, lines[0], " \t");
        var buf: std.ArrayList(u8) = .empty;
        for (lines, 0..) |l, i| {
            if (i > 0) try buf.append(self.a, '\n');
            try buf.appendSlice(self.a, std.mem.trimStart(u8, l, " \t"));
        }
        return buf.items;
    }

    fn paragraph(self: *Builder, lines: []const []const u8, ctx: *Ctx) !void {
        const src = self.off(lines[0]);
        try self.gap(ctx);
        const text = std.mem.trimEnd(u8, try self.paragraphText(lines), " \t");
        const links_before = self.out.links.items.len;
        try self.scanInline(text, ctx.style);
        if (self.loneImage()) |url| {
            if (self.opts.images) |im| {
                const room: u16 = @intCast(@min(ctx.width, 1000));
                if (im.fit(im.ctx, url, room, self.opts.max_image_rows)) |f| {
                    var r: u16 = 0;
                    while (r < f.rows) : (r += 1) {
                        try self.begin(ctx, src);
                        self.row.image = f.image;
                        self.row.image_row = r;
                        self.row.image_rows = f.rows;
                        self.row.image_cols = f.cols;
                        try self.finish();
                    }
                    self.out.links.shrinkRetainingCapacity(links_before);
                    self.need_gap = true;
                    return;
                }
            }
        }
        try self.wrap(ctx, src, ctx.width);
        self.need_gap = true;
    }

    /// The URL if the paragraph is exactly one image.
    fn loneImage(self: *Builder) ?[]const u8 {
        var id: u32 = 0;
        for (self.toks.items) |t| {
            if (t.kind == .syntax) continue;
            if (!t.image or t.link == 0) return null;
            if (id != 0 and id != t.link) return null;
            id = t.link;
        }
        if (id != 0) return self.urls.items[id - 1];
        // An empty alt text leaves nothing but syntax.
        var opener = false;
        for (self.toks.items) |t| {
            if (t.kind == .syntax and t.image) opener = true;
        }
        if (opener and self.urls.items.len == 1) return self.urls.items[0];
        return null;
    }

    fn heading(self: *Builder, level: u32, text: []const u8, src: u32, ctx: *Ctx) !void {
        try self.gap(ctx);
        var st = ctx.style;
        st.fg = Color.role(.heading);
        st.attrs.bold = level <= 4;
        st.attrs.italic = level == 5;
        if (level == 6) st.fg = Color.role(.muted);
        try self.scanInline(text, st);

        var slug: std.ArrayList(u8) = .empty;
        for (self.pieces.items) |p| for (if (isLinkMark(p.text)) "" else p.text) |c| {
            if (c == ' ') {
                try slug.append(self.a, '-');
            } else if (c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
                try slug.append(self.a, std.ascii.toLower(c));
            }
        };
        try self.out.headings.append(self.gpa, .{ .slug = slug.items, .row = @intCast(self.out.rows.items.len) });

        if (level <= 2 and try self.bigHeading(level, ctx, src)) {
            self.need_gap = true;
            return;
        }
        try self.wrap(ctx, src, ctx.width);
        if (level <= 2) {
            try self.begin(ctx, src);
            const line = if (level == 1) hline(thick_buf, ctx.width) else hline(thin_buf, ctx.width);
            try self.add(line, .{ .fg = Color.role(if (level == 1) .heading else .dim) }, @min(ctx.width, 400), 0);
            try self.finish();
        }
        self.need_gap = true;
    }

    /// Draws the heading in pixels, as tall as a few rows, one image per wrapped line. Returns false
    /// if that can't be done, leaving the heading to ordinary text.
    fn bigHeading(self: *Builder, level: u32, ctx: *Ctx, src: u32) !bool {
        const im = self.opts.images orelse return false;
        var plain: std.ArrayList(u8) = .empty;
        for (self.pieces.items) |p| {
            // A link or a code span would lose its meaning as a picture.
            if (p.link != 0 or p.text[0] == '\n') return false;
            try plain.appendSlice(self.a, p.text);
        }
        const text = std.mem.trim(u8, plain.items, " ");
        if (text.len == 0) return false;

        // Break into lines that fit. A word too long for any line falls back to text.
        const Line = struct { text: []const u8, cols: u16 };
        var lines: std.ArrayList(Line) = .empty;
        var rest = text;
        while (rest.len > 0) {
            var end = rest.len;
            while (true) {
                const cols = im.measure(im.ctx, rest[0..end], level) orelse return false;
                if (cols <= ctx.width) {
                    try lines.append(self.a, .{ .text = rest[0..end], .cols = cols });
                    break;
                }
                end = std.mem.lastIndexOfScalar(u8, rest[0..end], ' ') orelse return false;
            }
            rest = std.mem.trimStart(u8, rest[end..], " ");
        }
        for (lines.items) |l| {
            const f = im.heading(im.ctx, l.text, level, l.cols) orelse return false;
            var r: u16 = 0;
            while (r < f.rows) : (r += 1) {
                try self.begin(ctx, src);
                self.row.image = f.image;
                self.row.image_row = r;
                self.row.image_rows = f.rows;
                self.row.image_cols = f.cols;
                try self.finish();
            }
        }
        self.out.headings.items[self.out.headings.items.len - 1].text = text;
        return true;
    }

    fn rule(self: *Builder, src: u32, ctx: *Ctx) !void {
        try self.gap(ctx);
        try self.begin(ctx, src);
        try self.add(hline(thin_buf, ctx.width), .{ .fg = Color.role(.dim) }, @min(ctx.width, 400), 0);
        try self.finish();
        self.need_gap = true;
    }

    fn codeBlock(self: *Builder, lines: []const []const u8, ansi: bool, style: Style, ctx: *Ctx) !void {
        try self.gap(ctx);
        const inner = ctx.width -| 2;
        var st = style;
        st.bg = Color.role(.code_bg);
        for (lines) |raw| {
            const src = self.off(raw);
            if (ansi or std.mem.indexOfScalar(u8, raw, 0x1b) != null) {
                try self.ansiLine(raw, st, inner, ctx, src);
                continue;
            }
            const line = try self.expandTabs(raw);
            try self.begin(ctx, src);
            self.row.fill = Color.role(.code_bg);
            self.row.lead += 1;
            try self.add(spaces_buf[0..1], st, 1, 0);
            // Nearly every line of code: one cell a byte, and short enough not to wrap.
            if (line.len <= inner and isAscii(line)) {
                if (line.len > 0) try self.add(line, st, @intCast(line.len), 0);
                try self.finish();
                continue;
            }
            var i: usize = 0;
            var start: usize = 0;
            var col: u32 = 0;
            while (i < line.len) {
                const c = width.next(line[i..]);
                if (col + c.width > inner and col > 0) {
                    try self.add(line[start..i], st, col, 0);
                    try self.finish();
                    try self.begin(ctx, src);
                    self.row.fill = Color.role(.code_bg);
                    self.row.lead += 1;
                    self.row.join = .tight;
                    try self.add(spaces_buf[0..1], st, 1, 0);
                    start = i;
                    col = 0;
                }
                col += @max(c.width, if (c.len == 1) @as(u8, 1) else 0);
                i += c.len;
            }
            if (i > start) try self.add(line[start..i], st, col, 0);
            try self.finish();
        }
        self.need_gap = true;
    }

    fn expandTabs(self: *Builder, line: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, line, '\t') == null) return line;
        var buf: std.ArrayList(u8) = .empty;
        for (line) |c| {
            if (c == '\t') {
                try buf.appendSlice(self.a, "    ");
            } else try buf.append(self.a, c);
        }
        return buf.items;
    }

    /// A line of terminal output: colors are honored through Ghostty's SGR decoder, a bare CR
    /// restarts the line as a progress bar would, and every other sequence is dropped.
    fn ansiLine(self: *Builder, line: []const u8, base: Style, w: u32, ctx: *Ctx, src: u32) !void {
        self.pieces.clearRetainingCapacity();
        var st = base;
        var i: usize = 0;
        var start: usize = 0;
        while (i < line.len) {
            const c = line[i];
            if (c == 0x1b or c == '\r') {
                if (i > start) try self.pieces.append(self.a, .{ .text = line[start..i], .style = st, .link = 0 });
                if (c == '\r') {
                    self.pieces.clearRetainingCapacity();
                    i += 1;
                } else i = skipEscape(line, i, &st, base);
                start = i;
                continue;
            }
            i += 1;
        }
        if (line.len > start) try self.pieces.append(self.a, .{ .text = line[start..], .style = st, .link = 0 });

        try self.begin(ctx, src);
        self.row.fill = Color.role(.code_bg);
        self.row.lead += 1;
        try self.add(spaces_buf[0..1], base, 1, 0);
        var col: u32 = 0;
        for (self.pieces.items) |p| {
            var j: usize = 0;
            var from: usize = 0;
            var run: u32 = 0;
            while (j < p.text.len) {
                const cl = width.next(p.text[j..]);
                if (col + run + cl.width > w and col + run > 0) {
                    if (j > from) try self.add(p.text[from..j], p.style, run, 0);
                    try self.finish();
                    try self.begin(ctx, src);
                    self.row.fill = Color.role(.code_bg);
                    self.row.lead += 1;
                    self.row.join = .tight;
                    try self.add(spaces_buf[0..1], base, 1, 0);
                    col = 0;
                    run = 0;
                    from = j;
                }
                run += cl.width;
                j += cl.len;
            }
            if (j > from) try self.add(p.text[from..j], p.style, run, 0);
            col += run;
        }
        try self.finish();
    }

    fn quote(self: *Builder, lines: []const []const u8, ctx: *Ctx) !void {
        try self.gap(ctx);
        var st = ctx.style;
        st.fg = Color.role(.muted);
        var child = Ctx{
            .parent = ctx,
            .cont = .{ .text = "▌ ", .style = .{ .fg = Color.role(.dim) }, .width = 2 },
            .width = narrow(ctx.width, 2),
            .depth = ctx.depth,
            .style = st,
        };
        try self.blocks(lines, &child);
        self.need_gap = true;
    }

    fn table(self: *Builder, lines: []const []const u8, ctx: *Ctx) !void {
        try self.gap(ctx);
        const src = self.off(lines[0]);
        const a = self.a;
        const header = try splitRow(a, lines[0]);
        const n = header.len;
        const aligns = try a.alloc(Align, n);
        @memset(aligns, .left);
        const delim = try splitRow(a, lines[1]);
        for (delim, 0..) |d, i| {
            if (i >= n) break;
            const l = d.len > 0 and d[0] == ':';
            const r = d.len > 0 and d[d.len - 1] == ':';
            aligns[i] = if (l and r) .center else if (r) .right else .left;
        }

        // Natural widths, measured from what the cells will display.
        const body = lines[2..];
        const grid = try a.alloc([]const []const u8, body.len + 1);
        grid[0] = header;
        for (body, 1..) |l, i| grid[i] = try splitRow(a, l);
        const want = try a.alloc(u32, n);
        @memset(want, 1);
        // Scanned once, here, and kept for wrapping once the widths are known. Cells are visited in
        // the same order both times, so their links are already in place.
        const scanned = try a.alloc([]const Piece, grid.len * n);
        @memset(scanned, @as([]const Piece, &.{}));
        for (grid, 0..) |row, ri| {
            for (row, 0..) |cell, c| {
                if (c >= n) break;
                try self.scanInline(cell, cellStyle(ctx, ri == 0));
                var w: u32 = 0;
                for (self.pieces.items) |p| w += width.of(p.text);
                want[c] = @max(want[c], w);
                scanned[ri * n + c] = try a.dupe(Piece, self.pieces.items);
            }
        }
        const widths = try fitColumns(a, want, ctx.width);
        // Once a cell wraps, rows differ in height, and without a line between them that reads as
        // uneven spacing.
        const ruled = !std.mem.eql(u32, want, widths);

        const line_style = Style{ .fg = Color.role(.dim) };
        const middle = try self.borderText(widths, "├", "┼", "┤");
        try self.tableBorder(try self.borderText(widths, "┌", "┬", "┐"), ctx, src, line_style);
        for (0..grid.len) |ri| {
            // Wrap every cell, then lay the cell lines side by side.
            var cells = try a.alloc(std.ArrayList(CellLine), n);
            self.cell_spans.clearRetainingCapacity();
            var height: usize = 1;
            for (0..n) |c| {
                cells[c] = .empty;
                self.pieces.clearRetainingCapacity();
                try self.pieces.appendSlice(self.a, scanned[ri * n + c]);
                self.cell = &cells[c];
                try self.wrap(null, src, widths[c]);
                self.cell = null;
                height = @max(height, cells[c].items.len);
            }
            for (0..height) |k| {
                try self.begin(ctx, src);
                try self.add("│", line_style, 1, 0);
                for (0..n) |c| {
                    const cw = widths[c];
                    const have: u32 = if (k < cells[c].items.len) cells[c].items[k].width else 0;
                    const slack = cw -| have;
                    const left: u32 = switch (aligns[c]) {
                        .left => 0,
                        .right => slack,
                        .center => slack / 2,
                    };
                    try self.pad(1 + left, .{});
                    if (k < cells[c].items.len) {
                        const cl = cells[c].items[k];
                        for (self.cell_spans.items[cl.first..][0..cl.count]) |s| try self.add(s.text, s.style, s.width, s.link);
                    }
                    try self.pad(slack - left + 1, .{});
                    try self.add("│", line_style, 1, 0);
                }
                try self.finish();
            }
            if (ri == 0 or (ruled and ri + 1 < grid.len)) try self.tableBorder(middle, ctx, src, line_style);
        }
        try self.tableBorder(try self.borderText(widths, "└", "┴", "┘"), ctx, src, line_style);
        self.need_gap = true;
    }

    const Border = struct { text: []const u8, width: u32 };

    fn borderText(self: *Builder, widths: []const u32, l: []const u8, m: []const u8, r: []const u8) !Border {
        var total: u32 = 1;
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.a, l);
        for (widths, 0..) |w, i| {
            var left = w + 2;
            while (left > 0) {
                const k = @min(left, 400);
                try text.appendSlice(self.a, thin_buf[0 .. k * 3]);
                left -= k;
            }
            total += w + 3;
            try text.appendSlice(self.a, if (i + 1 == widths.len) r else m);
        }
        return .{ .text = text.items, .width = total };
    }

    fn tableBorder(self: *Builder, border: Border, ctx: *Ctx, src: u32, st: Style) !void {
        try self.begin(ctx, src);
        try self.add(border.text, st, border.width, 0);
        try self.finish();
    }

    fn list(self: *Builder, lines: []const []const u8, ctx: *Ctx) !usize {
        const a = self.a;
        const first = listMarker(lines[0]).?;
        var i: usize = 0;

        // Loose if any item is separated by, or contains, a blank line.
        const end = listEnd(lines, first);
        var tight = true;
        for (lines[0..end], 0..) |l, k| {
            if (isBlank(l) and k + 1 < end) tight = false;
        }
        const tight_all = tight or ctx.tight;
        var number = first.number;

        while (i < end) {
            const m = listMarker(lines[i]) orelse break;
            var sub: std.ArrayList([]const u8) = .empty;
            try sub.append(a, lines[i][@min(m.content, lines[i].len)..]);
            var j = i + 1;
            var blank = false;
            while (j < end) : (j += 1) {
                const l = lines[j];
                if (isBlank(l)) {
                    try sub.append(a, l[0..0]);
                    blank = true;
                    continue;
                }
                const ind = indentOf(l);
                if (ind >= m.content) {
                    try sub.append(a, stripIndent(l, m.content));
                    blank = false;
                    continue;
                }
                if (blank or startsBlock(l) or listMarker(l) != null) break;
                try sub.append(a, std.mem.trimStart(u8, l, " \t"));
            }
            while (sub.items.len > 0 and isBlank(sub.items[sub.items.len - 1])) sub.items.len -= 1;

            // The marker.
            var marker: []const u8 = undefined;
            var mw: u32 = 2;
            var checked = false;
            var task = false;
            if (sub.items.len > 0) {
                if (taskBox(sub.items[0])) |c| {
                    task = true;
                    checked = c;
                    sub.items[0] = std.mem.trimStart(u8, sub.items[0][3..], " ");
                }
            }
            if (task) {
                marker = if (checked) "☑ " else "☐ ";
            } else if (m.ordered) {
                marker = try std.fmt.allocPrint(a, "{d}. ", .{number});
                mw = @intCast(marker.len);
            } else {
                marker = switch (ctx.depth % 3) {
                    0 => "• ",
                    1 => "◦ ",
                    else => "▪ ",
                };
            }
            number += 1;
            if (i > 0 and !tight_all) self.need_gap = true else if (i > 0) self.need_gap = false;
            try self.gap(ctx);
            var child = Ctx{
                .parent = ctx,
                .first = .{ .text = marker, .style = .{ .fg = Color.role(.muted) }, .width = mw },
                .cont = .{ .text = spaces_buf[0..mw], .style = .{}, .width = mw },
                .width = narrow(ctx.width, mw),
                .tight = tight_all,
                .depth = ctx.depth + 1,
                .style = ctx.style,
            };
            if (checked) child.style.fg = Color.role(.muted);
            if (sub.items.len == 0 or (sub.items.len == 1 and isBlank(sub.items[0]))) {
                // An empty item still shows its marker.
                try self.begin(&child, self.off(lines[i]));
                try self.finish();
            } else {
                try self.blocks(sub.items, &child);
            }
            i = j;
            while (i < end and isBlank(lines[i])) i += 1;
        }
        self.need_gap = true;
        return end;
    }

    fn blocks(self: *Builder, lines: []const []const u8, ctx: *Ctx) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < lines.len) {
            const line = lines[i];
            if (isBlank(line)) {
                i += 1;
                continue;
            }
            const ind = indentOf(line);
            if (ind >= 4) {
                var codes: std.ArrayList([]const u8) = .empty;
                while (i < lines.len and (isBlank(lines[i]) or indentOf(lines[i]) >= 4)) : (i += 1) {
                    try codes.append(self.a, stripIndent(lines[i], 4));
                }
                while (codes.items.len > 0 and isBlank(codes.items[codes.items.len - 1])) codes.items.len -= 1;
                try self.codeBlock(codes.items, false, .{ .fg = Color.role(.code) }, ctx);
                continue;
            }
            const t = std.mem.trimStart(u8, line, " \t");
            if (fenceOpen(t)) |f| {
                var j = i + 1;
                var body: std.ArrayList([]const u8) = .empty;
                while (j < lines.len) : (j += 1) {
                    const l = stripIndent(lines[j], ind);
                    if (fenceClose(l, f)) break;
                    try body.append(self.a, l);
                }
                // An unclosed fence runs to the end of the document, minus the final newline.
                if (j >= lines.len) {
                    while (body.items.len > 0 and isBlank(body.items[body.items.len - 1])) body.items.len -= 1;
                }
                const info = std.mem.trim(u8, t[f.len..], " \t");
                const ansi = std.mem.eql(u8, info, "ansi") or std.mem.eql(u8, info, "terminal");
                try self.codeBlock(body.items, ansi, .{ .fg = Color.role(.code) }, ctx);
                i = @min(j + 1, lines.len);
                continue;
            }
            if (std.mem.startsWith(u8, t, "<!--")) {
                // Comments don't display.
                var j = i;
                while (j < lines.len and std.mem.indexOf(u8, lines[j], "-->") == null) j += 1;
                i = @min(j + 1, lines.len);
                continue;
            }
            if (atxHeading(t)) |h| {
                try self.heading(h.level, h.text, self.off(line), ctx);
                i += 1;
                continue;
            }
            if (isRule(t)) {
                try self.rule(self.off(line), ctx);
                i += 1;
                continue;
            }
            if (t[0] == '>') {
                var sub: std.ArrayList([]const u8) = .empty;
                while (i < lines.len) : (i += 1) {
                    const l = std.mem.trimStart(u8, lines[i], " ");
                    if (l.len > 0 and l[0] == '>') {
                        var body = l[1..];
                        if (body.len > 0 and body[0] == ' ') body = body[1..];
                        try sub.append(self.a, body);
                    } else if (!isBlank(l) and !startsBlock(l) and sub.items.len > 0 and !isBlank(sub.items[sub.items.len - 1])) {
                        try sub.append(self.a, l); // lazy continuation
                    } else break;
                }
                try self.quote(sub.items, ctx);
                continue;
            }
            if (listMarker(line) != null) {
                i += try self.list(lines[i..], ctx);
                continue;
            }
            if (i + 1 < lines.len and std.mem.indexOfScalar(u8, line, '|') != null and isTableDelimiter(lines[i + 1])) {
                var j = i + 2;
                while (j < lines.len and !isBlank(lines[j]) and std.mem.indexOfScalar(u8, lines[j], '|') != null) j += 1;
                try self.table(lines[i..j], ctx);
                i = j;
                continue;
            }
            if (refDefinition(line) != null) {
                i += 1;
                continue;
            }

            // A paragraph, or a setext heading if an underline ends it.
            var j = i + 1;
            var level: u32 = 0;
            while (j < lines.len) : (j += 1) {
                const l = lines[j];
                if (isBlank(l)) break;
                const u = std.mem.trim(u8, l, " \t");
                if (indentOf(l) < 4 and u.len > 0 and allChar(u, '=')) {
                    level = 1;
                    break;
                }
                if (indentOf(l) < 4 and u.len > 0 and allChar(u, '-')) {
                    level = 2;
                    break;
                }
                if (startsBlock(l)) break;
            }
            if (level != 0) {
                const text = try self.paragraphText(lines[i..j]);
                try self.heading(level, text, self.off(line), ctx);
                i = j + 1;
            } else {
                try self.paragraph(lines[i..j], ctx);
                i = j;
            }
        }
    }
};

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

fn narrow(w: u32, by: u32) u32 {
    return if (w > by + 4) w - by else @max(w, 4) -| @min(by, 2);
}

fn cellStyle(ctx: *Ctx, header: bool) Style {
    var st = ctx.style;
    st.attrs.bold = header;
    return st;
}

/// Consumes one escape sequence at line[i] and returns where the text resumes.
fn skipEscape(line: []const u8, i: usize, st: *Style, base: Style) usize {
    var j = i + 1;
    if (j >= line.len) return j;
    switch (line[j]) {
        '[' => {
            j += 1;
            const start = j;
            while (j < line.len and (line[j] < 0x40 or line[j] > 0x7e)) j += 1;
            if (j < line.len and line[j] == 'm') applySgr(line[start..j], st, base);
            return @min(j + 1, line.len);
        },
        ']', 'P', '_', '^', 'X' => {
            j += 1;
            while (j < line.len) : (j += 1) {
                if (line[j] == 0x07) return j + 1;
                if (line[j] == 0x1b and j + 1 < line.len and line[j + 1] == '\\') return j + 2;
            }
            return j;
        },
        else => return j + 1,
    }
}

fn applySgr(params: []const u8, st: *Style, base: Style) void {
    var nums: [24]u16 = undefined;
    var sep: vt.Parser.Action.CSI.SepList = .empty;
    var n: usize = 0;
    var cur: u32 = 0;
    for (params) |c| {
        if (n >= nums.len) break;
        if (c >= '0' and c <= '9') {
            cur = @min(cur * 10 + (c - '0'), 65535);
        } else if (c == ';' or c == ':') {
            nums[n] = @intCast(cur);
            if (c == ':') sep.set(n);
            n += 1;
            cur = 0;
        } else return;
    }
    if (n < nums.len) {
        nums[n] = @intCast(cur);
        n += 1;
    }
    var p: vt.sgr.Parser = .{ .params = nums[0..n], .params_sep = sep };
    while (p.next()) |attr| switch (attr) {
        .unset => st.* = base,
        .bold => st.attrs.bold = true,
        .reset_bold => {
            st.attrs.bold = false;
            st.attrs.faint = false;
        },
        .faint => st.attrs.faint = true,
        .italic => st.attrs.italic = true,
        .reset_italic => st.attrs.italic = false,
        .underline => |u| st.attrs.underline = u != .none,
        .inverse => st.attrs.reverse = true,
        .reset_inverse => st.attrs.reverse = false,
        .strikethrough => st.attrs.strike = true,
        .reset_strikethrough => st.attrs.strike = false,
        .direct_color_fg => |c| st.fg = Color.rgb(c.r, c.g, c.b),
        .direct_color_bg => |c| st.bg = Color.rgb(c.r, c.g, c.b),
        .@"8_fg", .@"8_bright_fg" => |c| st.fg = Color.index(@intFromEnum(c)),
        .@"8_bg", .@"8_bright_bg" => |c| st.bg = Color.index(@intFromEnum(c)),
        .@"256_fg" => |c| st.fg = Color.index(c),
        .@"256_bg" => |c| st.bg = Color.index(c),
        .reset_fg => st.fg = base.fg,
        .reset_bg => st.bg = base.bg,
        else => {},
    };
}

const Align = enum { left, center, right };

/// Shrinks columns to fit: the narrowest keep their natural width and the widest share the rest.
fn fitColumns(a: std.mem.Allocator, want: []const u32, total: u32) ![]u32 {
    const n: u32 = @intCast(want.len);
    const widths = try a.dupe(u32, want);
    const overhead = 3 * n + 1;
    const room = if (total > overhead + n) total - overhead else n;
    var sum: u32 = 0;
    for (want) |w| sum += w;
    if (sum <= room) return widths;

    var left = room;
    var open = n;
    const done = try a.alloc(bool, n);
    @memset(done, false);
    var changed = true;
    while (changed and open > 0) {
        changed = false;
        const share = @max(left / open, 1);
        for (want, 0..) |w, i| {
            if (!done[i] and w <= share) {
                done[i] = true;
                left -|= w;
                open -= 1;
                changed = true;
            }
        }
    }
    if (open > 0) {
        const share = @max(left / open, 1);
        var extra = left -| share * open;
        for (done, 0..) |d, i| {
            if (d) continue;
            widths[i] = share + @as(u32, if (extra > 0) 1 else 0);
            extra -|= 1;
        }
    }
    return widths;
}

fn splitRow(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var s = std.mem.trim(u8, line, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|' and (s.len < 2 or s[s.len - 2] != '\\')) s = s[0 .. s.len - 1];
    var cells: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    var tick = false;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1,
            '`' => tick = !tick,
            '|' => if (!tick) {
                try cells.append(a, std.mem.trim(u8, s[start..i], " \t"));
                start = i + 1;
            },
            else => {},
        }
    }
    try cells.append(a, std.mem.trim(u8, s[start..], " \t"));
    return cells.items;
}

pub fn isBlank(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn indentOf(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 4 - n % 4;
        } else break;
    }
    return n;
}

fn stripIndent(s: []const u8, cols: u32) []const u8 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < s.len and n < cols) : (i += 1) {
        if (s[i] == ' ') {
            n += 1;
        } else if (s[i] == '\t') {
            n += 4 - n % 4;
        } else break;
    }
    return s[i..];
}

fn allChar(s: []const u8, c: u8) bool {
    for (s) |x| if (x != c) return false;
    return true;
}

pub const Fence = struct { ch: u8, len: usize };

pub fn fenceOpen(t: []const u8) ?Fence {
    if (t.len < 3 or (t[0] != '`' and t[0] != '~')) return null;
    var n: usize = 0;
    while (n < t.len and t[n] == t[0]) n += 1;
    if (n < 3) return null;
    if (t[0] == '`' and std.mem.indexOfScalar(u8, t[n..], '`') != null) return null;
    return .{ .ch = t[0], .len = n };
}

pub fn fenceClose(line: []const u8, f: Fence) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len >= f.len and allChar(t, f.ch);
}

const Atx = struct { level: u32, text: []const u8 };

pub fn atxHeading(t: []const u8) ?Atx {
    var n: u32 = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < t.len and t[n] != ' ' and t[n] != '\t') return null;
    var text = std.mem.trim(u8, t[n..], " \t");
    // A closing run of #s isn't part of the heading.
    var e = text.len;
    while (e > 0 and text[e - 1] == '#') e -= 1;
    if (e == 0) {
        text = text[0..0];
    } else if (e < text.len and text[e - 1] == ' ') {
        text = std.mem.trimEnd(u8, text[0..e], " ");
    }
    return .{ .level = n, .text = text };
}

pub fn isRule(t: []const u8) bool {
    if (t.len < 3 or (t[0] != '-' and t[0] != '*' and t[0] != '_')) return false;
    var n: usize = 0;
    for (t) |c| {
        if (c == t[0]) {
            n += 1;
        } else if (c != ' ' and c != '\t') return false;
    }
    return n >= 3;
}

pub const Marker = struct { ordered: bool, ch: u8, number: u32, indent: u32, content: u32 };

pub fn listMarker(line: []const u8) ?Marker {
    const ind = indentOf(line);
    if (ind >= 4) return null;
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == 0) return null;
    const lead: u32 = @intCast(line.len - t.len);
    if ((t[0] == '-' or t[0] == '*' or t[0] == '+')) {
        if (isRule(t)) return null;
        if (t.len == 1) return .{ .ordered = false, .ch = t[0], .number = 0, .indent = ind, .content = lead + 1 };
        if (t[1] != ' ' and t[1] != '\t') return null;
        return .{ .ordered = false, .ch = t[0], .number = 0, .indent = ind, .content = lead + contentAfter(t, 1) };
    }
    var n: usize = 0;
    while (n < t.len and n < 9 and std.ascii.isDigit(t[n])) n += 1;
    if (n == 0 or n >= t.len or (t[n] != '.' and t[n] != ')')) return null;
    if (n + 1 < t.len and t[n + 1] != ' ' and t[n + 1] != '\t') return null;
    return .{
        .ordered = true,
        .ch = t[n],
        .number = std.fmt.parseInt(u32, t[0..n], 10) catch 1,
        .indent = ind,
        .content = lead + contentAfter(t, n + 1),
    };
}

fn contentAfter(t: []const u8, marker: usize) u32 {
    var i = marker;
    while (i < t.len and t[i] == ' ' and i - marker < 4) i += 1;
    if (i >= t.len or i - marker >= 4) return @intCast(marker + 1);
    return @intCast(i);
}

/// How many of lines belong to the list starting at the first.
fn listEnd(lines: []const []const u8, first: Marker) usize {
    var i: usize = 1;
    var last: usize = 1;
    var blank = false;
    while (i < lines.len) : (i += 1) {
        const l = lines[i];
        if (isBlank(l)) {
            blank = true;
            continue;
        }
        const ind = indentOf(l);
        if (listMarker(l)) |m| {
            if (m.ordered == first.ordered and m.ch == first.ch and ind < first.content) {
                last = i + 1;
                blank = false;
                continue;
            }
            if (ind < first.content) break;
        }
        if (ind >= first.content or ind > first.indent) {
            last = i + 1;
            blank = false;
            continue;
        }
        if (blank or startsBlock(l)) break;
        last = i + 1;
    }
    return last;
}

fn taskBox(s: []const u8) ?bool {
    if (s.len < 3 or s[0] != '[' or s[2] != ']') return null;
    if (s.len > 3 and s[3] != ' ') return null;
    return switch (s[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => null,
    };
}

/// Does this line interrupt a paragraph?
fn startsBlock(line: []const u8) bool {
    if (indentOf(line) >= 4) return false;
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == 0) return false;
    if (t[0] == '>' or fenceOpen(t) != null or atxHeading(t) != null or isRule(t)) return true;
    if (listMarker(line)) |m| return !m.ordered or m.number == 1;
    return false;
}

fn isTableDelimiter(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0 or std.mem.indexOfScalar(u8, t, '-') == null) return false;
    for (t) |c| switch (c) {
        '|', '-', ':', ' ', '\t' => {},
        else => return false,
    };
    return std.mem.indexOfScalar(u8, t, '|') != null;
}

const RefDef = struct { label: []const u8, url: []const u8 };

fn refDefinition(line: []const u8) ?RefDef {
    if (indentOf(line) >= 4) return null;
    const t = std.mem.trimStart(u8, line, " ");
    if (t.len < 5 or t[0] != '[' or t[1] == '^') return null;
    const close = std.mem.indexOfScalar(u8, t, ']') orelse return null;
    if (close < 2 or close + 1 >= t.len or t[close + 1] != ':') return null;
    const rest = std.mem.trim(u8, t[close + 2 ..], " \t");
    if (rest.len == 0) return null;
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    return .{ .label = t[1..close], .url = std.mem.trim(u8, rest[0..end], "<>") };
}

/// Lays out a whole document.
pub fn layout(gpa: std.mem.Allocator, source: []const u8, opts: Options) !Layout {
    var out = Layout{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer out.deinit();
    try build(&out, source, opts);
    return out;
}

/// Lays a document out again over an old layout, keeping its memory: a resize shouldn't have to give
/// all of it back and fault it all in again.
pub fn relayout(out: *Layout, source: []const u8, opts: Options) !void {
    out.rows.clearRetainingCapacity();
    out.spans.clearRetainingCapacity();
    out.links.clearRetainingCapacity();
    out.headings.clearRetainingCapacity();
    _ = out.arena.reset(.retain_capacity);
    try build(out, source, opts);
}

fn build(out: *Layout, source: []const u8, opts: Options) !void {
    const gpa = out.gpa;
    const a = out.arena.allocator();
    var b = Builder{ .gpa = gpa, .a = a, .src = source, .opts = opts, .out = out };
    defer b.cell_spans.deinit(gpa);

    // The arena also holds per-paragraph scratch, so lines are counted first to size it once.
    var lines: std.ArrayList([]const u8) = .empty;
    // Sized for lines of about 30 bytes, so that counting them isn't another pass over the document.
    try lines.ensureTotalCapacity(a, source.len / 32 + 16);
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |l| {
        const line = if (l.len > 0 and l[l.len - 1] == '\r') l[0 .. l.len - 1] else l;
        try lines.append(a, line);
        // A definition starts with a bracket, after at most three spaces.
        if (line.len < 5 or (line[0] != '[' and line[0] != ' ')) continue;
        if (refDefinition(line)) |d| {
            if (d.label.len <= 128) {
                const key = try a.dupe(u8, d.label);
                _ = std.ascii.lowerString(key, key);
                try b.refs.put(a, key, d.url);
            }
        }
    }

    var ctx = Ctx{ .width = @max(opts.width, 8) };
    var body = lines.items;

    // Front matter shows as metadata instead of a rule and a heading.
    if (body.len > 2 and std.mem.eql(u8, body[0], "---")) {
        for (body[1..], 1..) |l, i| {
            if (std.mem.eql(u8, l, "---")) {
                try b.codeBlock(body[1..i], false, .{ .fg = Color.role(.muted) }, &ctx);
                body = body[i + 1 ..];
                break;
            }
        }
    }
    try b.blocks(body, &ctx);

    if (out.rows.items.len == 0) {
        try b.begin(null, 0);
        try b.finish();
    }
}

/// Writes rows as text, for pipes and -p.
pub fn plainRow(l: *const Layout, r: Row, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    for (l.rowSpans(r)) |s| try out.appendSlice(gpa, s.text);
}

const testing = std.testing;

fn render(src: []const u8, w: u16) ![]const u8 {
    var l = try layout(testing.allocator, src, .{ .width = w });
    defer l.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (l.rows.items) |r| {
        try plainRow(&l, r, &out, testing.allocator);
        try out.append(testing.allocator, '\n');
    }
    return out.toOwnedSlice(testing.allocator);
}

fn expectRender(src: []const u8, w: u16, want: []const u8) !void {
    const got = try render(src, w);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "paragraphs wrap and symbols disappear" {
    try expectRender("hello **big** world and more", 12, "hello big\nworld and\nmore\n");
    try expectRender("one\ntwo\n\nthree", 40, "one two\n\nthree\n");
}

test "headings" {
    try expectRender("# Title", 8, "Title\n━━━━━━━━\n");
    try expectRender("## Sub ##\ntext", 8, "Sub\n────────\n\ntext\n");
    try expectRender("### Three", 20, "Three\n");
    try expectRender("Setext\n===\n", 8, "Setext\n━━━━━━━━\n");
    try expectRender("Setext\n---\n", 8, "Setext\n────────\n");
}

test "lists" {
    try expectRender("- a\n- b\n", 20, "• a\n• b\n");
    try expectRender("1. a\n2. b\n", 20, "1. a\n2. b\n");
    try expectRender("- a\n  - b\n- c\n", 20, "• a\n  ◦ b\n• c\n");
    try expectRender("- [ ] a\n- [x] b\n", 20, "☐ a\n☑ b\n");
    try expectRender("- a\n\n- b\n", 20, "• a\n\n• b\n");
    try expectRender("- long words that wrap\n", 12, "• long words\n  that wrap\n");
    try expectRender("- a\nlazy\n", 20, "• a lazy\n");
}

test "quotes" {
    try expectRender("> a\n> b\n\ntext", 20, "▌ a b\n\ntext\n");
    try expectRender("> a\n>\n> b\n", 20, "▌ a\n▌ \n▌ b\n");
    try expectRender("> > deep\n", 20, "▌ ▌ deep\n");
}

test "code" {
    try expectRender("```\n# not *md*\n```\n", 30, " # not *md*\n");
    try expectRender("~~~sh\nx\n~~~\ntext\n", 30, " x\n\ntext\n");
    try expectRender("    indented\n", 30, " indented\n");
    try expectRender("```\nunclosed\n", 30, " unclosed\n");
}

test "ansi blocks keep color and drop everything else" {
    var l = try layout(testing.allocator, "```ansi\n\x1b[31mred\x1b[0m \x1b]0;title\x07x\x1b[2Jy\n```\n", .{ .width = 30 });
    defer l.deinit();
    const sp = l.rowSpans(l.rows.items[0]);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (sp) |s| try text.appendSlice(testing.allocator, s.text);
    try testing.expectEqualStrings(" red xy", text.items);
    try testing.expectEqual(theme.Color.index(1), sp[1].style.fg);
    try expectRender("```ansi\n50%\r100%\n```\n", 30, " 100%\n");
}

test "tables align" {
    try expectRender("| a | b |\n|---|--:|\n| 1 | 22 |\n", 40,
        \\┌───┬────┐
        \\│ a │  b │
        \\├───┼────┤
        \\│ 1 │ 22 │
        \\└───┴────┘
        \\
    );
    try expectRender("| 你好 | e |\n|---|---|\n| x | 🚀 |\n", 40,
        \\┌──────┬────┐
        \\│ 你好 │ e  │
        \\├──────┼────┤
        \\│ x    │ 🚀 │
        \\└──────┴────┘
        \\
    );
}

test "tables wrap to fit" {
    try expectRender("| a | b |\n|---|---|\n| long cell here | x |\n", 16,
        \\┌──────────┬───┐
        \\│ a        │ b │
        \\├──────────┼───┤
        \\│ long     │ x │
        \\│ cell     │   │
        \\│ here     │   │
        \\└──────────┴───┘
        \\
    );
}

test "rows get a line between them once a cell wraps, and only then" {
    try expectRender("| a | b |\n|---|---|\n| long cell here | x |\n| y | z |\n", 16,
        \\┌──────────┬───┐
        \\│ a        │ b │
        \\├──────────┼───┤
        \\│ long     │ x │
        \\│ cell     │   │
        \\│ here     │   │
        \\├──────────┼───┤
        \\│ y        │ z │
        \\└──────────┴───┘
        \\
    );
    try expectRender("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n", 16,
        \\┌───┬───┐
        \\│ a │ b │
        \\├───┼───┤
        \\│ 1 │ 2 │
        \\│ 3 │ 4 │
        \\└───┴───┘
        \\
    );
}

fn expectMarks(src: []const u8, w: u16, want: []const u8) !void {
    var l = try layout(std.testing.allocator, src, .{ .width = w, .link_marks = true });
    defer l.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    for (l.rows.items) |r| {
        try plainRow(&l, r, &out, std.testing.allocator);
        try out.append(std.testing.allocator, '\n');
    }
    try std.testing.expectEqualStrings(want, out.items);
}

test "links that leave tmd are marked, once each, and stay with their last word" {
    try expectMarks("[web](https://a.io) [mail](mailto:a@b.io) [pdf](x.pdf)\n", 40, "web↗ mail↗ pdf↗\n");
    try expectMarks("[here](#top) [page](b.md) [page](b.md#top) [site](https://a.io/b.md)\n", 40, "here page page site\n");
    try expectMarks("[**bold** and *more*](https://a.io)\n", 40, "bold and more↗\n");
    try expectMarks("[one](https://a.io)[two](https://b.io) <https://c.io>\n", 40, "one↗two↗ https://c.io↗\n");
    try expectMarks("aaaa [bbbb](https://a.io)\n", 8, "aaaa\nbbbb↗\n");
    try expectMarks("![pic](p.png)\n", 40, "▣ pic\n");
}

test "the mark stays out of heading anchors" {
    var l = try layout(std.testing.allocator, "## See [docs](https://a.io)\n", .{ .width = 40, .link_marks = true });
    defer l.deinit();
    try std.testing.expectEqualStrings("see-docs", l.headings.items[0].slug);
}

test "rules, comments, references, front matter" {
    try expectRender("---\n", 8, "────────\n");
    try expectRender("a\n\n<!-- hidden -->\n\nb\n", 10, "a\n\nb\n");
    try expectRender("[x][r]\n\n[r]: http://a\n", 10, "x\n");
    try expectRender("---\ntitle: t\n---\nbody\n", 20, " title: t\n\nbody\n");
}

test "layout survives hostile input" {
    const cases = [_][]const u8{ "", "\n\n", ">", "-", "|", "```", "#", "[", "![", "](", "- - -", "|\n|-", ">\n>", "1.", "*", "**", "\x1b[31m", "- \n  ", "\t", "|a|\n|-|\n" };
    for (cases) |c| {
        const r = try render(c, 8);
        testing.allocator.free(r);
    }
}

test "wide text never exceeds the column" {
    var l = try layout(testing.allocator, "你好世界你好世界你好世界 and averyveryveryveryveryverylongword 👩‍💻👩‍💻👩‍💻👩‍💻👩‍💻👩‍💻", .{ .width = 10 });
    defer l.deinit();
    for (l.rows.items) |r| {
        var w: u32 = 0;
        for (l.rowSpans(r)) |s| {
            w += s.width;
            try testing.expectEqual(width.of(s.text), s.width);
        }
        try testing.expect(w <= 10);
    }
}

test "headings anchor and offsets map back" {
    const src = "# One Two\n\ntext\n\n## Three\n";
    var l = try layout(testing.allocator, src, .{ .width = 20 });
    defer l.deinit();
    try testing.expect(l.anchor("one-two") != null);
    try testing.expect(l.anchor("three").? > l.anchor("one-two").?);
    const row = l.rowForOffset(@intCast(std.mem.indexOf(u8, src, "## Three").?));
    try testing.expectEqual(l.anchor("three").?, row);
}
