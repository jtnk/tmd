//! The frame writer. Each row is built as bytes and hashed, and only rows whose hash changed are
//! sent, so an idle or scrolling viewer writes almost nothing. Scrolls use the terminal's own
//! scroll, leaving just the newly exposed rows to send.
const std = @import("std");
const theme = @import("theme.zig");
const width = @import("width.zig");
const Style = theme.Style;

pub const Cursor = struct { x: u16, y: u16 };

pub const Screen = struct {
    gpa: std.mem.Allocator,
    cols: u16 = 0,
    rows: u16 = 0,
    th: theme.Theme = .{},
    /// The current frame's row bytes.
    bytes: std.ArrayList(u8) = .empty,
    starts: []u32 = &.{},
    cur: []u64 = &.{},
    prev: []u64 = &.{},
    // The row being built.
    y: u16 = 0,
    col: u16 = 0,
    limit: u16 = 0,
    style: ?Style = null,
    /// Rows sent by the last flush, for the HUD.
    sent_rows: u32 = 0,

    pub fn deinit(self: *Screen) void {
        self.bytes.deinit(self.gpa);
        self.gpa.free(self.starts);
        self.gpa.free(self.cur);
        self.gpa.free(self.prev);
    }

    pub fn resize(self: *Screen, cols: u16, rows: u16) !void {
        self.cols = cols;
        self.rows = rows;
        self.starts = try self.gpa.realloc(self.starts, @as(usize, rows) + 1);
        self.cur = try self.gpa.realloc(self.cur, rows);
        self.prev = try self.gpa.realloc(self.prev, rows);
        self.invalidate();
    }

    /// Forgets what the terminal shows, so the next flush sends everything.
    pub fn invalidate(self: *Screen) void {
        @memset(self.prev, 0);
    }

    pub fn begin(self: *Screen) void {
        self.bytes.clearRetainingCapacity();
        self.y = 0;
    }

    /// Starts the next row. Text past limit columns is cut (the HUD and scrollbar use the rest).
    pub fn row(self: *Screen, limit: u16) void {
        self.starts[self.y] = @intCast(self.bytes.items.len);
        self.col = 0;
        self.limit = @min(limit, self.cols);
        self.style = null;
    }

    pub fn setStyle(self: *Screen, s: Style) !void {
        if (self.style) |c| if (c.eql(s)) return;
        self.style = s;
        try self.th.sgr(&self.bytes, self.gpa, s);
    }

    pub fn raw(self: *Screen, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.gpa, bytes);
    }

    /// Writes document text. Control characters never reach the terminal: a hostile file can't
    /// move the cursor, retitle the window or write to the clipboard.
    pub fn text(self: *Screen, s: Style, str: []const u8) !void {
        try self.setStyle(s);
        var i: usize = 0;
        while (i < str.len and self.col < self.limit) {
            const c = str[i];
            if (c >= 0x20 and c < 0x7f and (i + 1 == str.len or str[i + 1] < 0x80)) {
                var j = i + 1;
                const room = self.limit - self.col;
                while (j < str.len and j - i < room and str[j] >= 0x20 and str[j] < 0x7f and (j + 1 == str.len or str[j + 1] < 0x80)) j += 1;
                try self.bytes.appendSlice(self.gpa, str[i..j]);
                self.col += @intCast(j - i);
                i = j;
                continue;
            }
            const cl = width.next(str[i..]);
            const stop = i + cl.len;
            const unsafe = c < 0x20 or c == 0x7f or (c == 0xc2 and i + 1 < str.len and str[i + 1] < 0xa0);
            if (unsafe) {
                try self.bytes.appendSlice(self.gpa, "\u{00B7}");
                self.col += 1;
            } else if (self.col + cl.width <= self.limit) {
                if (std.unicode.utf8ValidateSlice(str[i..stop])) {
                    try self.bytes.appendSlice(self.gpa, str[i..stop]);
                } else {
                    try self.bytes.appendSlice(self.gpa, "\u{FFFD}");
                }
                self.col += cl.width;
            } else break;
            i = stop;
        }
    }

    /// n blank cells.
    pub fn pad(self: *Screen, s: Style, n: u16) !void {
        if (n == 0) return;
        try self.setStyle(s);
        const count = @min(n, self.limit -| self.col);
        try self.bytes.appendNTimes(self.gpa, ' ', count);
        self.col += count;
    }

    /// Moves to column x, leaving the cells between blank.
    pub fn padTo(self: *Screen, s: Style, x: u16) !void {
        if (x > self.col) try self.pad(s, x - self.col);
    }

    /// Clears the rest of the row in style s and finishes it.
    pub fn endRow(self: *Screen, s: Style) !void {
        if (self.col < self.cols and self.th.color) {
            try self.setStyle(s);
            try self.bytes.appendSlice(self.gpa, "\x1b[K");
        }
        self.y += 1;
    }

    pub fn end(self: *Screen) void {
        self.starts[self.y] = @intCast(self.bytes.items.len);
        for (0..self.y) |i| {
            const h = std.hash.Wyhash.hash(0, self.bytes.items[self.starts[i]..self.starts[i + 1]]);
            self.cur[i] = h | 1; // 0 means unknown
        }
    }

    /// Sends the frame. scroll is how many rows the content in rows [top, bottom) moved up (negative
    /// for down), a hint that the terminal can move them itself.
    pub fn flush(
        self: *Screen,
        out: *std.ArrayList(u8),
        cursor: ?Cursor,
        scroll: i32,
        top: u16,
        bottom: u16,
    ) !void {
        const g = self.gpa;
        var buf: [40]u8 = undefined;
        self.sent_rows = 0;
        var changed = false;
        for (self.prev[0..self.y], self.cur[0..self.y]) |p, c| changed = changed or p != c;

        if (changed) {
            try out.appendSlice(g, "\x1b[?2026h\x1b[?25l");
            if (scroll != 0 and @abs(scroll) < bottom - top) try self.terminalScroll(out, scroll, top, bottom);
            var y: u16 = 0;
            while (y < self.y) : (y += 1) {
                if (self.prev[y] == self.cur[y]) continue;
                try out.appendSlice(g, try std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{y + 1}));
                try out.appendSlice(g, self.bytes.items[self.starts[y]..self.starts[y + 1]]);
                self.sent_rows += 1;
            }
            try out.appendSlice(g, "\x1b[0m");
            @memcpy(self.prev[0..self.y], self.cur[0..self.y]);
        }
        if (cursor) |c| {
            if (!changed) try out.appendSlice(g, "\x1b[?2026h");
            try out.appendSlice(g, try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H\x1b[?25h", .{ c.y + 1, c.x + 1 }));
            try out.appendSlice(g, "\x1b[?2026l");
        } else if (changed) {
            try out.appendSlice(g, "\x1b[?2026l");
        }
    }

    fn terminalScroll(self: *Screen, out: *std.ArrayList(u8), scroll: i32, top: u16, bottom: u16) !void {
        const n: u16 = @intCast(@abs(scroll));
        const span = bottom - top - n;
        // Only worth it if the rows really did just move.
        var same: u32 = 0;
        var i: u16 = 0;
        while (i < span) : (i += 1) {
            const dst = if (scroll > 0) top + i else top + n + i;
            const src = if (scroll > 0) top + n + i else top + i;
            if (self.prev[src] == self.cur[dst]) same += 1;
        }
        if (same * 2 < span) return;

        var buf: [48]u8 = undefined;
        const dir: u8 = if (scroll > 0) 'S' else 'T';
        try out.appendSlice(self.gpa, try std.fmt.bufPrint(&buf, "\x1b[{d};{d}r\x1b[{d}{c}\x1b[r", .{ top + 1, bottom, n, dir }));
        if (scroll > 0) {
            std.mem.copyForwards(u64, self.prev[top .. top + span], self.prev[top + n .. bottom]);
            @memset(self.prev[top + span .. bottom], 0);
        } else {
            std.mem.copyBackwards(u64, self.prev[top + n .. bottom], self.prev[top .. top + span]);
            @memset(self.prev[top .. top + n], 0);
        }
    }
};
