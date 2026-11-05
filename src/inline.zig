//! Inline Markdown: emphasis, code spans, links, images, autolinks, escapes and entities. Text is cut
//! into tokens, and tokens that are pure syntax stay in the list marked as such, so the preview can
//! drop them while the editor shows them dimmed: one parser serves both.
const std = @import("std");

pub const Kind = enum { text, syntax, delim, bracket, br };

pub const Tok = struct {
    text: []const u8,
    kind: Kind = .text,
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    code: bool = false,
    image: bool = false,
    /// Index into links, plus one.
    link: u32 = 0,
    // Delimiter runs: chars still literal, and which way they can pair.
    count: u32 = 0,
    orig: u32 = 0,
    can_open: bool = false,
    can_close: bool = false,
};

pub const Refs = std.StringHashMapUnmanaged([]const u8);

/// The bytes Scanner.scan has a case for.
const special = blk: {
    var t: [256]bool = @splat(false);
    for ("\\`*_~![]<&\nhw") |c| t[c] = true;
    break :blk t;
};

pub const Scanner = struct {
    a: std.mem.Allocator,
    toks: *std.ArrayList(Tok),
    links: *std.ArrayList([]const u8),
    refs: ?*const Refs = null,
    /// Keep the source exact: don't decode entities or escapes.
    source: bool = false,
    /// How many images were found.
    images: u32 = 0,
    brackets: std.ArrayList(u32) = .empty,

    fn push(self: *Scanner, t: Tok) !void {
        try self.toks.append(self.a, t);
    }

    fn flush(self: *Scanner, text: []const u8, start: usize, i: usize) !void {
        if (i > start) try self.push(.{ .text = text[start..i] });
    }

    pub fn scan(self: *Scanner, text: []const u8) !void {
        const first = self.toks.items.len;
        self.brackets.clearRetainingCapacity();
        var i: usize = 0;
        var start: usize = 0;
        while (i < text.len) {
            // Most bytes mean nothing here, and this is the hottest loop in layout.
            while (i < text.len and !special[text[i]]) i += 1;
            if (i == text.len) break;
            const c = text[i];
            switch (c) {
                '\\' => {
                    if (i + 1 < text.len and isPunct(text[i + 1])) {
                        try self.flush(text, start, i);
                        try self.push(.{ .text = text[i .. i + 1], .kind = .syntax });
                        try self.push(.{ .text = text[i + 1 .. i + 2] });
                        i += 2;
                        start = i;
                    } else if (i + 1 < text.len and text[i + 1] == '\n') {
                        try self.flush(text, start, i);
                        try self.push(.{ .text = "", .kind = .br });
                        i += 2;
                        start = i;
                    } else i += 1;
                },
                '`' => {
                    const run = runLen(text, i);
                    if (closingTicks(text, i + run, run)) |close| {
                        try self.flush(text, start, i);
                        try self.push(.{ .text = text[i .. i + run], .kind = .syntax });
                        var body = text[i + run .. close];
                        if (!self.source and body.len > 2 and body[0] == ' ' and body[body.len - 1] == ' ') body = body[1 .. body.len - 1];
                        try self.push(.{ .text = body, .code = true });
                        try self.push(.{ .text = text[close .. close + run], .kind = .syntax });
                        i = close + run;
                        start = i;
                    } else i += run;
                },
                '*', '_', '~' => {
                    const run = runLen(text, i);
                    if (c == '~' and run != 2) {
                        i += run;
                        continue;
                    }
                    try self.flush(text, start, i);
                    const before: u8 = if (i > 0) text[i - 1] else ' ';
                    const after: u8 = if (i + run < text.len) text[i + run] else ' ';
                    const left = !isSpace(after) and (!isPunct(after) or isSpace(before) or isPunct(before));
                    const right = !isSpace(before) and (!isPunct(before) or isSpace(after) or isPunct(after));
                    try self.push(.{
                        .text = text[i .. i + run],
                        .kind = .delim,
                        .count = @intCast(run),
                        .orig = @intCast(run),
                        .can_open = if (c == '_') left and (!right or isPunct(before)) else left,
                        .can_close = if (c == '_') right and (!left or isPunct(after)) else right,
                    });
                    i += run;
                    start = i;
                },
                '!', '[' => {
                    const image = c == '!';
                    if (image and (i + 1 >= text.len or text[i + 1] != '[')) {
                        i += 1;
                        continue;
                    }
                    try self.flush(text, start, i);
                    const n: usize = if (image) 2 else 1;
                    try self.brackets.append(self.a, @intCast(self.toks.items.len));
                    try self.push(.{ .text = text[i .. i + n], .kind = .bracket, .image = image });
                    i += n;
                    start = i;
                },
                ']' => {
                    try self.flush(text, start, i);
                    start = i;
                    i = try self.closeBracket(text, i);
                    if (i > start) start = i else {
                        i += 1;
                    }
                },
                '<' => {
                    if (autolink(text[i..])) |len| {
                        try self.flush(text, start, i);
                        const url = text[i + 1 .. i + len - 1];
                        try self.push(.{ .text = text[i .. i + 1], .kind = .syntax });
                        try self.pushLink(url, url);
                        try self.push(.{ .text = text[i + len - 1 .. i + len], .kind = .syntax });
                        i += len;
                        start = i;
                    } else i += 1;
                },
                '&' => {
                    if (!self.source) {
                        if (entity(text[i..])) |e| {
                            try self.flush(text, start, i);
                            try self.push(.{ .text = e.text });
                            i += e.len;
                            start = i;
                            continue;
                        }
                    }
                    i += 1;
                },
                '\n' => {
                    var end = i;
                    while (end > start and text[end - 1] == ' ') end -= 1;
                    try self.flush(text, start, end);
                    if (i - end >= 2) {
                        try self.push(.{ .text = "", .kind = .br });
                    } else {
                        try self.push(.{ .text = " " });
                    }
                    i += 1;
                    start = i;
                },
                'h', 'w' => {
                    const boundary = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
                    if (boundary) {
                        if (bareUrl(text[i..])) |len| {
                            try self.flush(text, start, i);
                            const url = text[i .. i + len];
                            try self.pushLink(url, url);
                            i += len;
                            start = i;
                            continue;
                        }
                    }
                    i += 1;
                },
                else => i += 1,
            }
        }
        try self.flush(text, start, text.len);
        // Unmatched brackets are ordinary text.
        for (self.brackets.items) |b| self.toks.items[b].kind = .text;
        self.emphasis(first, self.toks.items.len);
    }

    fn pushLink(self: *Scanner, text: []const u8, url: []const u8) !void {
        try self.links.append(self.a, url);
        try self.push(.{ .text = text, .link = @intCast(self.links.items.len) });
    }

    /// Handles a ']' at i. Returns where scanning continues, or i if this isn't a link.
    fn closeBracket(self: *Scanner, text: []const u8, i: usize) !usize {
        const open = self.brackets.pop() orelse return i;
        var end: usize = i + 1;
        var url: ?[]const u8 = null;
        if (i + 1 < text.len and text[i + 1] == '(') {
            if (destination(text, i + 2)) |d| {
                url = d.url;
                end = d.end;
            }
        }
        if (url == null) if (self.refs) |refs| {
            var label: []const u8 = rawBetween(self.toks.items, text, open, i);
            if (i + 1 < text.len and text[i + 1] == '[') {
                if (std.mem.indexOfScalarPos(u8, text, i + 2, ']')) |close| {
                    if (close > i + 2) label = text[i + 2 .. close];
                    end = close + 1;
                }
            }
            var key: [128]u8 = undefined;
            if (label.len <= key.len) url = refs.get(std.ascii.lowerString(key[0..label.len], label));
        };
        if (url == null) {
            self.toks.items[open].kind = .text;
            return i;
        }
        const image = self.toks.items[open].image;
        self.emphasis(open + 1, self.toks.items.len);
        try self.links.append(self.a, url.?);
        const id: u32 = @intCast(self.links.items.len);
        self.toks.items[open].kind = .syntax;
        for (self.toks.items[open + 1 ..]) |*t| {
            t.link = id;
            t.image = image;
        }
        if (image) self.images += 1;
        try self.push(.{ .text = text[i..end], .kind = .syntax });
        return end;
    }

    /// Pairs delimiter runs in toks[lo..hi], styling the tokens between each pair.
    fn emphasis(self: *Scanner, lo: usize, hi: usize) void {
        const t = self.toks.items;
        var c = lo;
        while (c < hi) : (c += 1) {
            if (t[c].kind != .delim) continue;
            while (t[c].can_close and t[c].count > 0) {
                const ch = t[c].text[0];
                var o = c;
                var looked: u32 = 0;
                const found: ?usize = while (o > lo and looked < 64) {
                    o -= 1;
                    if (t[o].kind != .delim) continue;
                    looked += 1;
                    if (t[o].text[0] != ch or !t[o].can_open or t[o].count == 0) continue;
                    if ((t[o].can_close or t[c].can_open) and
                        (t[o].orig + t[c].orig) % 3 == 0 and
                        !(t[o].orig % 3 == 0 and t[c].orig % 3 == 0)) continue;
                    break o;
                } else null;
                const opener = found orelse break;
                const n: u32 = if (ch == '~') 2 else if (t[opener].count >= 2 and t[c].count >= 2) 2 else 1;
                if (t[opener].count < n or t[c].count < n) break;
                for (t[opener + 1 .. c]) |*tok| switch (ch) {
                    '~' => tok.strike = true,
                    else => if (n == 2) {
                        tok.bold = true;
                    } else {
                        tok.italic = true;
                    },
                };
                t[opener].count -= n;
                t[c].count -= n;
                // Runs inside a matched pair can't pair with anything outside it.
                for (t[opener + 1 .. c]) |*tok| if (tok.kind == .delim) {
                    tok.can_open = false;
                    tok.can_close = false;
                };
            }
        }
    }
};

/// The source text between a bracket token and the ']' at end.
fn rawBetween(toks: []const Tok, text: []const u8, open: u32, end: usize) []const u8 {
    const o = toks[open].text;
    const start = @intFromPtr(o.ptr) + o.len - @intFromPtr(text.ptr);
    return text[start..end];
}

fn runLen(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len and text[j] == text[i]) j += 1;
    return j - i;
}

fn closingTicks(text: []const u8, from: usize, run: usize) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, text, i, '`')) |p| {
        const r = runLen(text, p);
        if (r == run) return p;
        i = p + r;
    }
    return null;
}

const Dest = struct { url: []const u8, end: usize };

/// A link destination and optional title, starting just after '('.
fn destination(text: []const u8, from: usize) ?Dest {
    var i = from;
    while (i < text.len and text[i] == ' ') i += 1;
    var url: []const u8 = undefined;
    if (i < text.len and text[i] == '<') {
        const close = std.mem.indexOfScalarPos(u8, text, i, '>') orelse return null;
        url = text[i + 1 .. close];
        i = close + 1;
    } else {
        const start = i;
        var depth: u32 = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
            } else if (c == '(') {
                depth += 1;
            } else if (c == ')') {
                if (depth == 0) break;
                depth -= 1;
            } else if (c == ' ' or c == '\n') {
                // CommonMark ends the destination here, but people write paths with spaces in
                // them: only a title or the closing parenthesis ends it.
                var j = i;
                while (j < text.len and (text[j] == ' ' or text[j] == '\n')) j += 1;
                if (j >= text.len or text[j] == ')' or text[j] == '"' or text[j] == '\'') break;
            }
        }
        url = text[start..i];
    }
    while (i < text.len and (text[i] == ' ' or text[i] == '\n')) i += 1;
    if (i < text.len and (text[i] == '"' or text[i] == '\'')) {
        const q = text[i];
        const close = std.mem.indexOfScalarPos(u8, text, i + 1, q) orelse return null;
        i = close + 1;
        while (i < text.len and text[i] == ' ') i += 1;
    }
    if (i >= text.len or text[i] != ')') return null;
    return .{ .url = url, .end = i + 1 };
}

/// The length of an autolink such as <https://example.com> or <me@example.com> at the start of s.
fn autolink(s: []const u8) ?usize {
    const close = std.mem.indexOfScalar(u8, s, '>') orelse return null;
    const body = s[1..close];
    if (body.len == 0) return null;
    for (body) |c| if (c <= ' ' or c == '<') return null;
    const scheme = std.mem.indexOfScalar(u8, body, ':');
    if (scheme) |n| if (n >= 2 and n <= 32) return close + 1;
    if (std.mem.indexOfScalar(u8, body, '@') != null and std.mem.indexOfScalar(u8, body, '.') != null) return close + 1;
    return null;
}

fn bareUrl(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, "https://") and !std.mem.startsWith(u8, s, "http://") and
        !std.mem.startsWith(u8, s, "www.")) return null;
    var n: usize = 0;
    while (n < s.len and s[n] > ' ' and s[n] != '<' and s[n] != '>' and s[n] != '`') n += 1;
    while (n > 0 and std.mem.indexOfScalar(u8, ".,;:!?*_~\"')]", s[n - 1]) != null) n -= 1;
    return if (n > 8) n else null;
}

const Entity = struct { text: []const u8, len: usize };

fn entity(s: []const u8) ?Entity {
    const names = [_]struct { []const u8, []const u8 }{
        .{ "&amp;", "&" },    .{ "&lt;", "<" },     .{ "&gt;", ">" },
        .{ "&quot;", "\"" },  .{ "&#39;", "'" },    .{ "&nbsp;", "\u{00A0}" },
        .{ "&copy;", "©" },   .{ "&mdash;", "—" },  .{ "&ndash;", "–" },
        .{ "&hellip;", "…" }, .{ "&rarr;", "→" },   .{ "&larr;", "←" },
    };
    for (names) |n| if (std.mem.startsWith(u8, s, n[0])) return .{ .text = n[1], .len = n[0].len };
    return null;
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\t' or c == '\r';
}

pub fn isPunct(c: u8) bool {
    return (c >= 0x21 and c <= 0x2f) or (c >= 0x3a and c <= 0x40) or (c >= 0x5b and c <= 0x60) or (c >= 0x7b and c <= 0x7e);
}

const testing = std.testing;

fn visible(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var toks: std.ArrayList(Tok) = .empty;
    var links: std.ArrayList([]const u8) = .empty;
    var s = Scanner{ .a = a, .toks = &toks, .links = &links };
    try s.scan(src);
    var out: std.ArrayList(u8) = .empty;
    for (toks.items) |t| {
        switch (t.kind) {
            .syntax => {},
            .br => try out.append(a, '|'),
            .delim => try out.appendSlice(a, t.text[0..t.count]),
            else => {
                if (t.bold) try out.append(a, 'B');
                if (t.italic) try out.append(a, 'I');
                if (t.strike) try out.append(a, 'S');
                if (t.code) try out.append(a, 'C');
                if (t.link != 0) try out.append(a, 'L');
                try out.appendSlice(a, t.text);
            },
        }
    }
    return out.items;
}

test "inline forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a Bb c", try visible(a, "a **b** c"));
    try testing.expectEqualStrings("Ii", try visible(a, "*i*"));
    try testing.expectEqualStrings("BIx", try visible(a, "***x***"));
    try testing.expectEqualStrings("Sgone", try visible(a, "~~gone~~"));
    try testing.expectEqualStrings("Ccode", try visible(a, "`code`"));
    try testing.expectEqualStrings("Ca`b", try visible(a, "`` a`b ``"));
    try testing.expectEqualStrings("Ltext", try visible(a, "[text](http://x)"));
    try testing.expectEqualStrings("**unclosed", try visible(a, "**unclosed"));
    try testing.expectEqualStrings("*not*", try visible(a, "\\*not\\*"));
    try testing.expectEqualStrings("snake_case_word", try visible(a, "snake_case_word"));
    try testing.expectEqualStrings("2 * 3 * 4", try visible(a, "2 * 3 * 4"));
    try testing.expectEqualStrings("a & b", try visible(a, "a &amp; b"));
    try testing.expectEqualStrings("see Lhttps://a.b/c.", try visible(a, "see https://a.b/c."));
    try testing.expectEqualStrings("[not a link]", try visible(a, "[not a link]"));
    try testing.expectEqualStrings("Lspaced", try visible(a, "[spaced](notes/with spaces.md)"));
    try testing.expectEqualStrings("Ltitled", try visible(a, "[titled](a.md \"The title\")"));
    try testing.expectEqualStrings("a|b", try visible(a, "a  \nb"));
    try testing.expectEqualStrings("a b", try visible(a, "a\nb"));
}

test "a pathological run of markers stays fast" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, 200_000);
    for (big, 0..) |*c, i| c.* = if (i % 2 == 0) '*' else 'a';
    _ = try visible(a, big);
}
