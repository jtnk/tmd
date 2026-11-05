//! The editor: one contiguous buffer and a table of line starts. An insert moves at most the whole
//! file, which even at 2MB is well under a tenth of a frame, so no gap buffer or rope is needed and
//! the text stays a plain slice for layout, search and saving.
const std = @import("std");
const theme = @import("theme.zig");
const width = @import("width.zig");
const inl = @import("inline.zig");
const md = @import("md.zig");
const screen_mod = @import("screen.zig");
const Screen = screen_mod.Screen;
const Style = theme.Style;
const Color = theme.Color;

const Edit = struct {
    pos: u32,
    removed: []u8,
    inserted: []u8,
    before: u32,
    after: u32,
    /// Typing and backspacing merge into one undo step.
    kind: Kind,
};

pub const Kind = enum { other, insert, delete };

pub const Run = struct { start: u32, end: u32, style: Style };

pub const Editor = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    starts: std.ArrayList(u32) = .empty,
    cursor: u32 = 0,
    /// The other end of the selection.
    anchor: ?u32 = null,
    goal: ?u32 = null,
    top_line: u32 = 0,
    top_sub: u32 = 0,
    undo_stack: std.ArrayList(Edit) = .empty,
    redo_stack: std.ArrayList(Edit) = .empty,
    /// Changes with every edit, so a stale layout can be noticed.
    generation: u64 = 1,
    saved_generation: u64 = 1,
    // Scratch, reused every frame.
    breaks: std.ArrayList(u32) = .empty,
    runs: std.ArrayList(Run) = .empty,

    pub fn deinit(self: *Editor) void {
        const g = self.gpa;
        self.clearHistory();
        self.undo_stack.deinit(g);
        self.redo_stack.deinit(g);
        self.buf.deinit(g);
        self.starts.deinit(g);
        self.breaks.deinit(g);
        self.runs.deinit(g);
    }

    fn clearHistory(self: *Editor) void {
        for ([_]*std.ArrayList(Edit){ &self.undo_stack, &self.redo_stack }) |st| {
            for (st.items) |e| {
                self.gpa.free(e.removed);
                self.gpa.free(e.inserted);
            }
            st.clearRetainingCapacity();
        }
    }

    pub fn load(self: *Editor, content: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.gpa, content);
        self.clearHistory();
        self.cursor = 0;
        self.anchor = null;
        self.top_line = 0;
        self.top_sub = 0;
        self.generation += 1;
        self.saved_generation = self.generation;
        try self.reindex();
    }

    fn reindex(self: *Editor) !void {
        self.starts.clearRetainingCapacity();
        try self.starts.append(self.gpa, 0);
        for (self.buf.items, 0..) |c, i| {
            if (c == '\n') try self.starts.append(self.gpa, @intCast(i + 1));
        }
    }

    pub fn dirty(self: *const Editor) bool {
        return self.generation != self.saved_generation;
    }

    pub fn markSaved(self: *Editor) void {
        self.saved_generation = self.generation;
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn lineCount(self: *const Editor) u32 {
        return @intCast(self.starts.items.len);
    }

    pub fn lineOf(self: *const Editor, pos: u32) u32 {
        var lo: usize = 0;
        var hi: usize = self.starts.items.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.starts.items[mid] <= pos) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    pub fn lineEnd(self: *const Editor, i: u32) u32 {
        if (i + 1 < self.starts.items.len) return self.starts.items[i + 1] - 1;
        return @intCast(self.buf.items.len);
    }

    pub fn line(self: *const Editor, i: u32) []const u8 {
        return self.buf.items[self.starts.items[i]..self.lineEnd(i)];
    }

    // Editing.

    fn apply(self: *Editor, pos: u32, del: u32, ins: []const u8) !void {
        const g = self.gpa;
        try self.buf.replaceRange(g, pos, del, ins);
        const delta: i64 = @as(i64, @intCast(ins.len)) - del;
        const first = self.lineOf(pos) + 1;
        // Line starts inside the replaced range go, the rest shift.
        var stop = first;
        const items = self.starts.items;
        while (stop < items.len and items[stop] <= pos + del) stop += 1;
        var added: u32 = 0;
        for (ins) |c| if (c == '\n') {
            added += 1;
        };
        var news: std.ArrayList(u32) = .empty;
        defer news.deinit(g);
        try news.ensureTotalCapacity(g, added);
        for (ins, 0..) |c, i| if (c == '\n') news.appendAssumeCapacity(pos + @as(u32, @intCast(i)) + 1);
        try self.starts.replaceRange(g, first, stop - first, news.items);
        for (self.starts.items[first + added ..]) |*s| s.* = @intCast(@as(i64, s.*) + delta);
        self.generation += 1;
    }

    /// Replaces del bytes at pos with ins, as one undoable step.
    pub fn replace(self: *Editor, pos: u32, del: u32, ins: []const u8, kind: Kind) !void {
        const g = self.gpa;
        const before = self.cursor;
        const after: u32 = pos + @as(u32, @intCast(ins.len));
        for (self.redo_stack.items) |e| {
            g.free(e.removed);
            g.free(e.inserted);
        }
        self.redo_stack.clearRetainingCapacity();

        const merged = self.merge(pos, del, ins, kind);
        if (!merged) {
            const removed = try g.dupe(u8, self.buf.items[pos .. pos + del]);
            errdefer g.free(removed);
            const inserted = try g.dupe(u8, ins);
            errdefer g.free(inserted);
            try self.undo_stack.append(g, .{ .pos = pos, .removed = removed, .inserted = inserted, .before = before, .after = after, .kind = kind });
        }
        try self.apply(pos, del, ins);
        self.cursor = after;
        self.anchor = null;
        self.goal = null;
    }

    fn merge(self: *Editor, pos: u32, del: u32, ins: []const u8, kind: Kind) bool {
        const g = self.gpa;
        if (kind == .other or self.undo_stack.items.len == 0) return false;
        const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
        if (last.kind != kind) return false;
        if (kind == .insert and del == 0 and last.pos + last.inserted.len == pos and ins.len > 0 and ins[ins.len - 1] != '\n') {
            // Each word is its own step.
            if (last.inserted.len > 0 and last.inserted[last.inserted.len - 1] == ' ' and ins[0] != ' ') return false;
            const grown = g.realloc(last.inserted, last.inserted.len + ins.len) catch return false;
            @memcpy(grown[grown.len - ins.len ..], ins);
            last.inserted = grown;
            last.after = pos + @as(u32, @intCast(ins.len));
            return true;
        }
        if (kind == .delete and ins.len == 0 and pos + del == last.pos and last.inserted.len == 0) {
            const grown = g.alloc(u8, del + last.removed.len) catch return false;
            @memcpy(grown[0..del], self.buf.items[pos .. pos + del]);
            @memcpy(grown[del..], last.removed);
            g.free(last.removed);
            last.removed = grown;
            last.pos = pos;
            last.after = pos;
            return true;
        }
        return false;
    }

    pub fn undo(self: *Editor) !bool {
        const e = self.undo_stack.pop() orelse return false;
        try self.apply(e.pos, @intCast(e.inserted.len), e.removed);
        try self.redo_stack.append(self.gpa, e);
        self.cursor = e.before;
        self.anchor = null;
        self.goal = null;
        return true;
    }

    pub fn redo(self: *Editor) !bool {
        const e = self.redo_stack.pop() orelse return false;
        try self.apply(e.pos, @intCast(e.removed.len), e.inserted);
        try self.undo_stack.append(self.gpa, e);
        self.cursor = e.after;
        self.anchor = null;
        self.goal = null;
        return true;
    }

    pub fn selection(self: *const Editor) ?[2]u32 {
        const a = self.anchor orelse return null;
        if (a == self.cursor) return null;
        return .{ @min(a, self.cursor), @max(a, self.cursor) };
    }

    pub fn selectedText(self: *const Editor) ?[]const u8 {
        const s = self.selection() orelse return null;
        return self.buf.items[s[0]..s[1]];
    }

    pub fn insert(self: *Editor, s: []const u8, kind: Kind) !void {
        if (self.selection()) |sel| {
            self.cursor = sel[1];
            try self.replace(sel[0], sel[1] - sel[0], s, .other);
        } else {
            try self.replace(self.cursor, 0, s, kind);
        }
    }

    pub fn backspace(self: *Editor) !void {
        if (self.selection()) |sel| return self.replace(sel[0], sel[1] - sel[0], "", .other);
        if (self.cursor == 0) return;
        const p = self.prevCluster(self.cursor);
        try self.replace(p, self.cursor - p, "", .delete);
    }

    pub fn deleteForward(self: *Editor) !void {
        if (self.selection()) |sel| return self.replace(sel[0], sel[1] - sel[0], "", .other);
        if (self.cursor >= self.buf.items.len) return;
        const n = self.nextCluster(self.cursor);
        try self.replace(self.cursor, n - self.cursor, "", .other);
    }

    /// Enter, continuing a list or quote the way the line above started.
    pub fn newline(self: *Editor) !void {
        const l = self.line(self.lineOf(self.cursor));
        var lead: []const u8 = "";
        var buf: [64]u8 = undefined;
        if (md.listMarker(l)) |m| {
            const content = l[@min(m.content, l.len)..];
            if (md.isBlank(content)) {
                // A second Enter on an empty item ends the list.
                const start = self.starts.items[self.lineOf(self.cursor)];
                self.cursor = start + @as(u32, @intCast(l.len));
                return self.replace(start, @intCast(l.len), "", .other);
            }
            const indent = l[0..@min(m.indent, l.len)];
            if (m.ordered) {
                lead = std.fmt.bufPrint(&buf, "{s}{d}{c} ", .{ indent, m.number + 1, m.ch }) catch "";
            } else {
                lead = std.fmt.bufPrint(&buf, "{s}{c} ", .{ indent, m.ch }) catch "";
            }
        }
        var ins: [66]u8 = undefined;
        ins[0] = '\n';
        @memcpy(ins[1..][0..lead.len], lead);
        try self.insert(ins[0 .. lead.len + 1], .other);
    }

    /// Wraps the selection in a marker, or unwraps it if it's already wrapped.
    pub fn toggleWrap(self: *Editor, marker: []const u8) !void {
        const m: u32 = @intCast(marker.len);
        const sel = self.selection() orelse {
            var b: [8]u8 = undefined;
            @memcpy(b[0..m], marker);
            @memcpy(b[m..][0..m], marker);
            const at = self.cursor;
            try self.replace(at, 0, b[0 .. m * 2], .other);
            self.cursor = at + m;
            return;
        };
        const s = self.buf.items;
        if (sel[0] >= m and sel[1] + m <= s.len and
            std.mem.eql(u8, s[sel[0] - m .. sel[0]], marker) and std.mem.eql(u8, s[sel[1] .. sel[1] + m], marker))
        {
            const inner = try self.gpa.dupe(u8, s[sel[0]..sel[1]]);
            defer self.gpa.free(inner);
            try self.replace(sel[0] - m, sel[1] - sel[0] + 2 * m, inner, .other);
            self.anchor = sel[0] - m;
            self.cursor = sel[1] - m;
            return;
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, marker);
        try out.appendSlice(self.gpa, s[sel[0]..sel[1]]);
        try out.appendSlice(self.gpa, marker);
        try self.replace(sel[0], sel[1] - sel[0], out.items, .other);
        self.anchor = sel[0] + m;
        self.cursor = sel[1] + m;
    }

    /// [selection]() with the cursor between the parentheses.
    pub fn insertLink(self: *Editor) !void {
        const sel = self.selection() orelse [2]u32{ self.cursor, self.cursor };
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try out.append(self.gpa, '[');
        try out.appendSlice(self.gpa, self.buf.items[sel[0]..sel[1]]);
        try out.appendSlice(self.gpa, "]()");
        try self.replace(sel[0], sel[1] - sel[0], out.items, .other);
        self.cursor -= 1;
    }

    /// Replaces the whole text as one undoable step, keeping the cursor on the same line.
    pub fn replaceAll(self: *Editor, new: []const u8) !void {
        const l = self.lineOf(self.cursor);
        const before = self.cursor;
        try self.replace(0, @intCast(self.buf.items.len), new, .other);
        self.cursor = self.starts.items[@min(l, self.lineCount() - 1)];
        self.undo_stack.items[self.undo_stack.items.len - 1].before = before;
    }

    // Movement.

    fn prevCluster(self: *const Editor, pos: u32) u32 {
        const start = self.starts.items[self.lineOf(pos)];
        if (pos == start) return pos - 1; // the newline
        var i = start;
        const l = self.buf.items[start..pos];
        var last = start;
        while (i < pos) {
            last = i;
            i += width.next(l[i - start ..]).len;
        }
        return last;
    }

    fn nextCluster(self: *const Editor, pos: u32) u32 {
        const s = self.buf.items;
        if (s[pos] == '\n') return pos + 1;
        return @min(pos + width.next(s[pos..self.lineEnd(self.lineOf(pos))]).len, @as(u32, @intCast(s.len)));
    }

    fn select(self: *Editor, extend: bool) void {
        if (extend) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else self.anchor = null;
    }

    pub fn left(self: *Editor, extend: bool) void {
        if (!extend) if (self.selection()) |s| {
            self.cursor = s[0];
            self.anchor = null;
            return;
        };
        self.select(extend);
        self.goal = null;
        if (self.cursor > 0) self.cursor = self.prevCluster(self.cursor);
    }

    pub fn right(self: *Editor, extend: bool) void {
        if (!extend) if (self.selection()) |s| {
            self.cursor = s[1];
            self.anchor = null;
            return;
        };
        self.select(extend);
        self.goal = null;
        if (self.cursor < self.buf.items.len) self.cursor = self.nextCluster(self.cursor);
    }

    pub fn wordLeft(self: *Editor, extend: bool) void {
        self.select(extend);
        self.goal = null;
        const s = self.buf.items;
        var p = self.cursor;
        while (p > 0 and !isWord(s[p - 1])) p -= 1;
        while (p > 0 and isWord(s[p - 1])) p -= 1;
        self.cursor = p;
    }

    pub fn wordRight(self: *Editor, extend: bool) void {
        self.select(extend);
        self.goal = null;
        const s = self.buf.items;
        var p = self.cursor;
        while (p < s.len and !isWord(s[p])) p += 1;
        while (p < s.len and isWord(s[p])) p += 1;
        self.cursor = p;
    }

    pub fn home(self: *Editor, extend: bool) void {
        self.select(extend);
        self.goal = null;
        self.cursor = self.starts.items[self.lineOf(self.cursor)];
    }

    pub fn end(self: *Editor, extend: bool) void {
        self.select(extend);
        self.goal = null;
        self.cursor = self.lineEnd(self.lineOf(self.cursor));
    }

    pub fn moveTo(self: *Editor, pos: u32, extend: bool) void {
        self.select(extend);
        self.goal = null;
        self.cursor = @min(pos, @as(u32, @intCast(self.buf.items.len)));
    }

    pub fn selectAll(self: *Editor) void {
        self.anchor = 0;
        self.cursor = @intCast(self.buf.items.len);
    }

    /// One visual row up or down, holding the column.
    pub fn vertical(self: *Editor, down: bool, w: u32, extend: bool) !void {
        self.select(extend);
        const l = self.lineOf(self.cursor);
        try self.wrapLine(l, w);
        const sub = self.subOf(self.cursor - self.starts.items[l]);
        const row_start = self.breaks.items[sub];
        const col = cellWidth(self.line(l)[row_start .. self.cursor - self.starts.items[l]]);
        const goal = self.goal orelse col;
        self.goal = goal;

        var tl = l;
        var ts = sub;
        if (down) {
            if (sub + 1 < self.breaks.items.len) {
                ts += 1;
            } else if (l + 1 < self.lineCount()) {
                tl += 1;
                ts = 0;
            } else {
                self.cursor = self.lineEnd(l);
                return;
            }
        } else {
            if (sub > 0) {
                ts -= 1;
            } else if (l > 0) {
                tl -= 1;
                try self.wrapLine(tl, w);
                ts = @intCast(self.breaks.items.len - 1);
            } else {
                self.cursor = 0;
                return;
            }
        }
        try self.wrapLine(tl, w);
        const text_line = self.line(tl);
        const from = self.breaks.items[ts];
        const to: u32 = if (ts + 1 < self.breaks.items.len) self.breaks.items[ts + 1] else @intCast(text_line.len);
        self.cursor = self.starts.items[tl] + from + byteAtCol(text_line[from..to], goal, ts + 1 < self.breaks.items.len);
    }

    fn subOf(self: *const Editor, off: u32) u32 {
        var s: u32 = 0;
        while (s + 1 < self.breaks.items.len and self.breaks.items[s + 1] <= off) s += 1;
        return s;
    }

    /// Fills breaks with the byte offset of each visual row of line i.
    pub fn wrapLine(self: *Editor, i: u32, w: u32) !void {
        self.breaks.clearRetainingCapacity();
        try self.breaks.append(self.gpa, 0);
        const s = self.line(i);
        var col: u32 = 0;
        var pos: u32 = 0;
        var row_start: u32 = 0;
        var brk: u32 = 0;
        var brk_col: u32 = 0;
        while (pos < s.len) {
            const c = cell(s[pos..]);
            if (col + c.width > w and col > 0) {
                if (brk > row_start) {
                    col -= brk_col;
                    row_start = brk;
                } else {
                    col = 0;
                    row_start = pos;
                }
                try self.breaks.append(self.gpa, row_start);
                brk = 0;
            }
            col += c.width;
            pos += c.len;
            if (s[pos - 1] == ' ') {
                brk = pos;
                brk_col = col;
            }
        }
    }

    /// Where the cursor is on screen, relative to the text area.
    pub fn cursorCell(self: *Editor, w: u32, view: u32) !?screen_mod.Cursor {
        const cl = self.lineOf(self.cursor);
        if (cl < self.top_line) return null;
        var y: u32 = 0;
        var l = self.top_line;
        var sub = self.top_sub;
        while (l < cl) : (l += 1) {
            try self.wrapLine(l, w);
            y += @as(u32, @intCast(self.breaks.items.len)) -| sub;
            sub = 0;
            if (y >= view) return null;
        }
        try self.wrapLine(cl, w);
        const off = self.cursor - self.starts.items[cl];
        const s = self.subOf(off);
        if (s < sub) return null;
        y += s - sub;
        if (y >= view) return null;
        const x = cellWidth(self.line(cl)[self.breaks.items[s]..off]);
        return .{ .x = @intCast(@min(x, w)), .y = @intCast(y) };
    }

    /// Scrolls the least distance that brings the cursor into a view of the given height.
    pub fn reveal(self: *Editor, w: u32, view: u32) !void {
        const cl = self.lineOf(self.cursor);
        try self.wrapLine(cl, w);
        const cs = self.subOf(self.cursor - self.starts.items[cl]);
        if (cl < self.top_line or (cl == self.top_line and cs < self.top_sub)) {
            self.top_line = cl;
            self.top_sub = cs;
            return;
        }
        var l = cl;
        var s = cs;
        var n = view -| 1;
        while (n > 0) : (n -= 1) {
            if (s > 0) {
                s -= 1;
            } else if (l > 0) {
                l -= 1;
                try self.wrapLine(l, w);
                s = @intCast(self.breaks.items.len - 1);
            } else break;
        }
        if (self.top_line < l or (self.top_line == l and self.top_sub < s)) {
            self.top_line = l;
            self.top_sub = s;
        }
    }

    /// Scrolls the view by rows without moving the cursor.
    pub fn scroll(self: *Editor, by: i32, w: u32) !void {
        var n = by;
        while (n > 0) : (n -= 1) {
            try self.wrapLine(self.top_line, w);
            if (self.top_sub + 1 < self.breaks.items.len) {
                self.top_sub += 1;
            } else if (self.top_line + 1 < self.lineCount()) {
                self.top_line += 1;
                self.top_sub = 0;
            } else break;
        }
        while (n < 0) : (n += 1) {
            if (self.top_sub > 0) {
                self.top_sub -= 1;
            } else if (self.top_line > 0) {
                self.top_line -= 1;
                try self.wrapLine(self.top_line, w);
                self.top_sub = @intCast(self.breaks.items.len - 1);
            } else break;
        }
    }

    /// The document offset under a screen cell of the text area.
    pub fn posAt(self: *Editor, x: u32, y: u32, w: u32) !u32 {
        var l = self.top_line;
        var sub = self.top_sub;
        var row: u32 = 0;
        while (true) {
            try self.wrapLine(l, w);
            const n: u32 = @intCast(self.breaks.items.len);
            if (row + (n - sub) > y) {
                const s = sub + (y - row);
                const t = self.line(l);
                const from = self.breaks.items[s];
                const more = s + 1 < n;
                const to: u32 = if (more) self.breaks.items[s + 1] else @intCast(t.len);
                return self.starts.items[l] + from + byteAtCol(t[from..to], x, more);
            }
            row += n - sub;
            sub = 0;
            if (l + 1 >= self.lineCount()) return @intCast(self.buf.items.len);
            l += 1;
        }
    }

    /// Next case-insensitive match at or after from, wrapping around.
    pub fn find(self: *const Editor, query: []const u8, from: u32, back: bool) ?u32 {
        const s = self.buf.items;
        if (query.len == 0 or s.len < query.len) return null;
        if (back) {
            var i: usize = @min(from, s.len - query.len);
            var left_n: usize = s.len + 1;
            while (left_n > 0) : (left_n -= 1) {
                if (std.ascii.eqlIgnoreCase(s[i..][0..query.len], query)) return @intCast(i);
                i = if (i == 0) s.len - query.len else i - 1;
            }
            return null;
        }
        if (indexOfFold(s, from, query)) |p| return @intCast(p);
        if (indexOfFold(s, 0, query)) |p| return @intCast(p);
        return null;
    }

    // Painting.

    /// Whether line i starts inside a fenced code block. A scan from the top costs microseconds and
    /// can't go stale.
    fn fenceAt(self: *const Editor, i: u32) ?md.Fence {
        var open: ?md.Fence = null;
        var l: u32 = 0;
        while (l < i) : (l += 1) {
            const start = self.starts.items[l];
            // Almost no line can be a fence: check its first byte before looking closer.
            var p = start;
            const s = self.buf.items;
            while (p < s.len and s[p] == ' ') p += 1;
            if (p >= s.len or (s[p] != '`' and s[p] != '~')) continue;
            const t = self.line(l);
            if (open) |f| {
                if (md.fenceClose(t, f)) open = null;
            } else {
                open = md.fenceOpen(std.mem.trimStart(u8, t, " "));
            }
        }
        return open;
    }

    fn addRun(self: *Editor, start: usize, end_: usize, st: Style) !void {
        if (end_ > start) try self.runs.append(self.gpa, .{ .start = @intCast(start), .end = @intCast(end_), .style = st });
    }

    /// Live styling of one line, with its Markdown symbols kept and dimmed.
    fn styleLine(self: *Editor, a: std.mem.Allocator, s: []const u8, in_fence: bool) !void {
        self.runs.clearRetainingCapacity();
        const dim = Style{ .fg = Color.role(.dim) };
        const t = std.mem.trimStart(u8, s, " ");
        const lead = s.len - t.len;
        if (in_fence) return self.addRun(0, s.len, .{ .fg = Color.role(.code) });
        if (md.fenceOpen(t) != null) return self.addRun(0, s.len, dim);
        if (md.isRule(t)) return self.addRun(0, s.len, dim);

        var base = Style{};
        var i: usize = lead;
        if (md.atxHeading(t)) |h| {
            base = .{ .fg = Color.role(.heading), .attrs = .{ .bold = true } };
            try self.addRun(0, lead + h.level, dim);
            i = lead + h.level;
        } else {
            while (i < s.len and s[i] == '>') {
                i += 1;
                if (i < s.len and s[i] == ' ') i += 1;
                base.fg = Color.role(.muted);
            }
            if (i > lead) try self.addRun(0, i, dim);
            if (md.listMarker(s[i..])) |m| {
                try self.addRun(i, i + m.content, .{ .fg = Color.role(.muted) });
                i += m.content;
            }
        }
        if (i > s.len) i = s.len;

        // Inline: same scanner as the preview.
        var toks: std.ArrayList(inl.Tok) = .empty;
        var urls: std.ArrayList([]const u8) = .empty;
        var sc = inl.Scanner{ .a = a, .toks = &toks, .links = &urls, .source = true };
        try sc.scan(s[i..]);
        const base_ptr = @intFromPtr(s.ptr);
        for (toks.items) |tok| {
            if (tok.text.len == 0) continue;
            const p = @intFromPtr(tok.text.ptr);
            if (p < base_ptr or p > base_ptr + s.len) continue;
            const off = p - base_ptr;
            var st = base;
            st.attrs.bold = st.attrs.bold or tok.bold;
            st.attrs.italic = st.attrs.italic or tok.italic;
            st.attrs.strike = st.attrs.strike or tok.strike;
            if (tok.code) {
                st.fg = Color.role(.code);
                st.bg = Color.role(.code_bg);
            } else if (tok.link != 0) {
                st.fg = Color.role(.link);
                st.attrs.underline = true;
            }
            if (tok.kind == .syntax or (tok.kind == .delim and tok.count < tok.orig)) st = dim;
            try self.addRun(off, off + tok.text.len, st);
        }
    }

    /// Reverses the part of the current runs inside [a, b).
    fn overlay(self: *Editor, a: u32, b: u32, add: theme.Attrs, bg: ?Color) !void {
        var out: std.ArrayList(Run) = .empty;
        defer out.deinit(self.gpa);
        for (self.runs.items) |r| {
            if (r.end <= a or r.start >= b) {
                try out.append(self.gpa, r);
                continue;
            }
            if (r.start < a) try out.append(self.gpa, .{ .start = r.start, .end = a, .style = r.style });
            var st = r.style;
            st.attrs.reverse = add.reverse;
            if (bg) |c| st.bg = c;
            try out.append(self.gpa, .{ .start = @max(r.start, a), .end = @min(r.end, b), .style = st });
            if (r.end > b) try out.append(self.gpa, .{ .start = b, .end = r.end, .style = r.style });
        }
        self.runs.clearRetainingCapacity();
        try self.runs.appendSlice(self.gpa, out.items);
    }

    /// Paints view rows of text. x0 is the text column's left edge, and base the row background.
    pub fn paint(self: *Editor, sc: *Screen, x0: u16, w: u32, view: u32, base: Style, query: []const u8, limit: u16, finish: anytype) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var fence = self.fenceAt(self.top_line);
        var l = self.top_line;
        var sub = self.top_sub;
        var y: u32 = 0;
        while (y < view) {
            if (l >= self.lineCount()) {
                sc.row(limit);
                try finish.call(sc, y);
                y += 1;
                continue;
            }
            const s = self.line(l);
            const t = std.mem.trimStart(u8, s, " ");
            var in_fence = fence != null;
            if (fence) |f| {
                if (md.fenceClose(s, f)) {
                    fence = null;
                    in_fence = false;
                }
            } else if (md.fenceOpen(t)) |f| fence = f;

            _ = arena.reset(.retain_capacity);
            try self.styleLine(arena.allocator(), s, in_fence);
            try self.fillGaps(@intCast(s.len));
            const ls = self.starts.items[l];
            if (query.len > 0) {
                var from: usize = 0;
                while (indexOfFold(s, from, query)) |m| {
                    try self.overlay(@intCast(m), @intCast(m + query.len), .{}, Color.role(.accent));
                    from = m + query.len;
                }
            }
            if (self.selection()) |sel| {
                const a = @max(sel[0], ls) - ls;
                const b = @min(sel[1], ls + @as(u32, @intCast(s.len)));
                if (sel[0] < ls + s.len and sel[1] > ls and b > ls) try self.overlay(a, b - ls, .{ .reverse = true }, null);
            }
            try self.wrapLine(l, w);
            const rows: u32 = @intCast(self.breaks.items.len);
            while (sub < rows and y < view) : (sub += 1) {
                const from = self.breaks.items[sub];
                const to: u32 = if (sub + 1 < rows) self.breaks.items[sub + 1] else @intCast(s.len);
                sc.row(limit);
                try sc.padTo(base, x0);
                try self.paintRow(sc, s, from, to, base);
                try finish.call(sc, y);
                y += 1;
            }
            if (sub >= rows) {
                l += 1;
                sub = 0;
            } else break;
        }
    }

    /// Text between styled tokens gets the plain style, so runs tile the line.
    fn fillGaps(self: *Editor, len: u32) !void {
        var out: std.ArrayList(Run) = .empty;
        defer out.deinit(self.gpa);
        var at: u32 = 0;
        for (self.runs.items) |r| {
            if (r.start < at) continue;
            if (r.start > at) try out.append(self.gpa, .{ .start = at, .end = r.start, .style = .{} });
            try out.append(self.gpa, r);
            at = r.end;
        }
        if (at < len) try out.append(self.gpa, .{ .start = at, .end = len, .style = .{} });
        self.runs.clearRetainingCapacity();
        try self.runs.appendSlice(self.gpa, out.items);
    }

    fn paintRow(self: *Editor, sc: *Screen, s: []const u8, from: u32, to: u32, base: Style) !void {
        for (self.runs.items) |r| {
            if (r.end <= from or r.start >= to) continue;
            var st = r.style;
            if (st.bg.kind == .role and st.bg.value == 0) st.bg = base.bg;
            const seg = s[@max(r.start, from)..@min(r.end, to)];
            var i: usize = 0;
            while (i < seg.len) {
                const tab = std.mem.indexOfScalarPos(u8, seg, i, '\t') orelse seg.len;
                try sc.text(st, seg[i..tab]);
                if (tab < seg.len) try sc.pad(st, tab_width);
                i = tab + 1;
            }
        }
    }
};

const tab_width = 4;

/// Case-insensitive (for ASCII) substring search.
pub fn indexOfFold(s: []const u8, from: usize, query: []const u8) ?usize {
    if (query.len == 0 or s.len < query.len) return null;
    const lo = std.ascii.toLower(query[0]);
    const up = std.ascii.toUpper(query[0]);
    var i = from;
    const last = s.len - query.len;
    while (i <= last) : (i += 1) {
        if (s[i] != lo and s[i] != up) continue;
        if (std.ascii.eqlIgnoreCase(s[i..][0..query.len], query)) return i;
    }
    return null;
}

const Cell = struct { len: u32, width: u32 };

fn cell(s: []const u8) Cell {
    // Printable ASCII, unless a combining mark follows it, which is what this runs on nearly always.
    if (s[0] >= 0x20 and s[0] < 0x7f and (s.len == 1 or s[1] < 0x80)) return .{ .len = 1, .width = 1 };
    if (s[0] == '\t') return .{ .len = 1, .width = tab_width };
    const c = width.next(s);
    // Control characters are drawn as a dot.
    return .{ .len = c.len, .width = if (s[0] < 0x20 or s[0] == 0x7f) 1 else c.width };
}

fn cellWidth(s: []const u8) u32 {
    var w: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = cell(s[i..]);
        w += c.width;
        i += c.len;
    }
    return w;
}

/// The byte in s at column col. The row's last byte can't be chosen when a wrapped row follows,
/// since that position belongs to the next row.
fn byteAtCol(s: []const u8, col: u32, wrapped: bool) u32 {
    var w: u32 = 0;
    var i: u32 = 0;
    while (i < s.len) {
        const c = cell(s[i..]);
        if (w + c.width > col) return i;
        if (wrapped and i + c.len >= s.len) return i;
        w += c.width;
        i += c.len;
    }
    return i;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

const testing = std.testing;

test "editing keeps the line table right" {
    var e = Editor{ .gpa = testing.allocator };
    defer e.deinit();
    try e.load("one\ntwo\nthree");
    try testing.expectEqual(@as(u32, 3), e.lineCount());
    e.moveTo(3, false);
    try e.insert("\nnew", .other);
    try testing.expectEqualStrings("one\nnew\ntwo\nthree", e.text());
    try testing.expectEqual(@as(u32, 4), e.lineCount());
    try testing.expectEqualStrings("two", e.line(2));
    e.anchor = 2;
    e.cursor = 9;
    try e.backspace();
    try testing.expectEqualStrings("onwo\nthree", e.text());
    try testing.expectEqual(@as(u32, 2), e.lineCount());
    try testing.expectEqualStrings("three", e.line(1));
}

test "undo and redo, with typing merged into steps" {
    var e = Editor{ .gpa = testing.allocator };
    defer e.deinit();
    try e.load("");
    for ("hello") |c| try e.insert(&[_]u8{c}, .insert);
    try e.insert(" ", .insert);
    for ("world") |c| try e.insert(&[_]u8{c}, .insert);
    try testing.expectEqualStrings("hello world", e.text());
    try testing.expect(e.dirty());
    _ = try e.undo();
    try testing.expectEqualStrings("hello ", e.text());
    _ = try e.undo();
    try testing.expectEqualStrings("", e.text());
    _ = try e.redo();
    _ = try e.redo();
    try testing.expectEqualStrings("hello world", e.text());
    try testing.expectEqual(@as(u32, 11), e.cursor);
    e.moveTo(5, false);
    try e.backspace();
    try e.backspace();
    try testing.expectEqualStrings("hel world", e.text());
    _ = try e.undo();
    try testing.expectEqualStrings("hello world", e.text());
}

test "wrapping markers toggles" {
    var e = Editor{ .gpa = testing.allocator };
    defer e.deinit();
    try e.load("a word b");
    e.anchor = 2;
    e.cursor = 6;
    try e.toggleWrap("**");
    try testing.expectEqualStrings("a **word** b", e.text());
    try testing.expectEqualStrings("word", e.selectedText().?);
    try e.toggleWrap("**");
    try testing.expectEqualStrings("a word b", e.text());
    try e.insertLink();
    try testing.expectEqualStrings("a [word]() b", e.text());
    try testing.expectEqual(@as(u32, 9), e.cursor);
}

test "lists continue on enter" {
    var e = Editor{ .gpa = testing.allocator };
    defer e.deinit();
    try e.load("- item");
    e.moveTo(6, false);
    try e.newline();
    try testing.expectEqualStrings("- item\n- ", e.text());
    try e.newline();
    try testing.expectEqualStrings("- item\n", e.text());
    try e.load("3. x");
    e.moveTo(4, false);
    try e.newline();
    try testing.expectEqualStrings("3. x\n4. ", e.text());
}

test "visual rows and cursor mapping" {
    var e = Editor{ .gpa = testing.allocator };
    defer e.deinit();
    try e.load("aaaa bbbb cccc\nd");
    try e.wrapLine(0, 6);
    try testing.expectEqual(@as(usize, 3), e.breaks.items.len);
    e.moveTo(1, false);
    try e.vertical(true, 6, false);
    try testing.expectEqual(@as(u32, 6), e.cursor);
    try e.vertical(true, 6, false);
    try testing.expectEqual(@as(u32, 11), e.cursor);
    try e.vertical(true, 6, false);
    try testing.expectEqual(@as(u32, 16), e.cursor);
    const c = (try e.cursorCell(6, 10)).?;
    try testing.expectEqual(@as(u16, 3), c.y);
    try testing.expectEqual(@as(u32, 5), try e.posAt(0, 1, 6));
}

test "find wraps, both ways" {
    var e = Editor{ .gpa = testing.allocator };
    defer e.deinit();
    try e.load("Foo bar foo");
    try testing.expectEqual(@as(u32, 8), e.find("foo", 1, false).?);
    try testing.expectEqual(@as(u32, 0), e.find("foo", 9, false).?);
    try testing.expectEqual(@as(u32, 0), e.find("foo", 7, true).?);
    try testing.expect(e.find("nope", 0, false) == null);
}
