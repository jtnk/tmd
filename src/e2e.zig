//! End-to-end tests: tmd's real output goes through Ghostty's terminal emulator, and the assertions
//! are about the emulator's resulting state, so they hold for what a terminal actually shows.
const std = @import("std");
const vt = @import("ghostty-vt");
const build_options = @import("build_options");
const app_mod = @import("app.zig");
const input = @import("input.zig");
const md = @import("layout").md;
const width = @import("layout").width;
const files = @import("layout").files;
const App = app_mod.App;
const testing = std.testing;
const gpa = testing.allocator;

extern fn tm_decode(data: [*]const u8, len: c_int, w: *c_int, h: *c_int) ?[*]u8;
extern fn tm_free(p: ?*anyopaque) void;

/// The Ghostty app brings its own PNG decoder, and the library leaves that to the embedder.
fn decodePng(a: std.mem.Allocator, data: []const u8) vt.sys.DecodeError!vt.sys.Image {
    var w: c_int = 0;
    var h: c_int = 0;
    const px = tm_decode(data.ptr, @intCast(data.len), &w, &h) orelse return error.InvalidData;
    defer tm_free(px);
    const n: usize = @intCast(w * h * 4);
    return .{ .width = @intCast(w), .height = @intCast(h), .data = try a.dupe(u8, px[0..n]) };
}

const Rig = struct {
    app: App,
    tio: vt.TinyIo,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    dec: input.Decoder,

    fn create(cols: u16, rows: u16) !*Rig {
        vt.sys.decode_png = decodePng;
        const r = try gpa.create(Rig);
        r.app = App.init(gpa);
        r.app.spawn = false;
        r.app.store.big_headings = false;
        r.app.settings.experimental_edit = true;
        try r.app.resize(cols, rows);
        r.tio = .init;
        r.term = try vt.Terminal.init(r.tio.io(), gpa, .{ .cols = cols, .rows = rows });
        r.stream = r.term.vtStream();
        r.dec = .{ .gpa = gpa };
        // As tmd sets the terminal up.
        r.stream.nextSlice("\x1b[?1049h\x1b[?7l\x1b[?2027h");
        return r;
    }

    fn destroy(r: *Rig) void {
        r.dec.deinit();
        r.stream.deinit();
        r.term.deinit(gpa);
        r.app.deinit();
        gpa.destroy(r);
    }

    fn pump(r: *Rig) !void {
        try r.app.frame();
        r.stream.nextSlice(r.app.out.items);
        r.app.out.clearRetainingCapacity();
    }

    fn keys(r: *Rig, bytes: []const u8) !void {
        try r.dec.feed(bytes);
        while (try r.dec.next()) |e| {
            try r.app.event(e);
            try r.pump();
        }
    }

    fn screen(r: *Rig) ![]const u8 {
        return r.term.plainString(gpa);
    }

    fn expectShows(r: *Rig, s: []const u8) !void {
        const text = try r.screen();
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, s) == null) {
            std.debug.print("\nscreen lacks \"{s}\":\n{s}\n", .{ s, text });
            return error.TestExpectedEqual;
        }
    }

    fn expectHides(r: *Rig, s: []const u8) !void {
        const text = try r.screen();
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, s) != null) {
            std.debug.print("\nscreen has \"{s}\":\n{s}\n", .{ s, text });
            return error.TestExpectedEqual;
        }
    }
};

test "preview hides symbols, editor shows them, and the same text stays in view" {
    var r = try Rig.create(60, 12);
    defer r.destroy();
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    for (0..40) |i| {
        var b: [64]u8 = undefined;
        try doc.appendSlice(gpa, try std.fmt.bufPrint(&b, "## Section {d}\n\nSome **bold** text\n\n", .{i}));
    }
    _ = try r.app.openText("doc", doc.items, false);
    try r.pump();
    try r.expectShows("Section 0");
    try r.expectHides("**");
    try r.expectHides("##");

    try r.keys("GG");
    try r.expectShows("Section 39");
    try r.keys("g");
    try r.keys("dddd");
    const row = r.app.tab().layout.?.rows.items[r.app.tab().top];
    try r.keys("e");
    try r.expectShows("**bold**");
    try testing.expectEqual(r.app.tab().ed.lineOf(row.src), r.app.tab().ed.top_line);
    try r.keys("\x1b");
    try r.dec.feed("");
    if (r.dec.timeout()) |e| try r.app.event(e);
    try r.pump();
    try r.expectHides("**");
}

test "row diffing and terminal scrolling end up identical to a full repaint" {
    const text = try files.read(gpa, "testdata/03-lists-and-quotes.md", 1 << 20);
    defer gpa.free(text);
    var r = try Rig.create(70, 15);
    defer r.destroy();
    r.app.screen.th.palette = 1;
    _ = try r.app.openText("doc", text, false);
    try r.pump();

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    const moves = [_][]const u8{ "j", "k", "jjj", "kk", " ", "b", "d", "u", "g", "G" };
    for (0..200) |_| {
        try r.keys(moves[rand.uintLessThan(usize, moves.len)]);
        const got = try r.screen();
        defer gpa.free(got);

        // What the terminal should show: the same position painted onto a blank terminal.
        var fresh = try Rig.create(70, 15);
        defer fresh.destroy();
        fresh.app.screen.th.palette = 1;
        const t = try fresh.app.openText("doc", text, false);
        try fresh.pump();
        t.top = r.app.tab().top;
        fresh.app.screen.invalidate();
        try fresh.pump();
        const want = try fresh.screen();
        defer gpa.free(want);
        try testing.expectEqualStrings(want, got);
    }
}

test "scrolling in the editor sends a row, and ends up identical to a full repaint" {
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    for (0..80) |i| {
        var b: [160]u8 = undefined;
        // Blank lines to match anywhere, and lines long enough to wrap, so a line can be several rows.
        try doc.appendSlice(gpa, try std.fmt.bufPrint(&b, "line {d} **bold**\n\n", .{i}));
        if (i % 3 == 0) try doc.appendSlice(gpa, "a long line that has to wrap onto another row of the editor and then onto another one too\n");
    }
    var r = try Rig.create(50, 15);
    defer r.destroy();
    _ = try r.app.openText("doc", doc.items, false);
    try r.pump();
    try r.keys("e");

    const check = struct {
        fn same(rig: *Rig) !void {
            const shown = try rig.screen();
            defer gpa.free(shown);
            rig.app.screen.invalidate();
            rig.term.fullReset();
            rig.stream.nextSlice("\x1b[?1049h\x1b[?7l\x1b[?2027h");
            try rig.pump();
            const fresh = try rig.screen();
            defer gpa.free(fresh);
            try testing.expectEqualStrings(fresh, shown);
        }
    };

    for (0..60) |_| {
        try r.keys("\x1b[B");
        try check.same(r);
    }
    // Once the cursor is at the bottom of the view, a line down is a scroll, and sends far less than
    // the view.
    try r.app.frame();
    r.app.out.clearRetainingCapacity();
    try r.app.event(.{ .key = .{ .code = input.Key.down } });
    try r.app.frame();
    r.stream.nextSlice(r.app.out.items);
    try testing.expect(r.app.out.items.len < 400);
    try testing.expect(std.mem.indexOf(u8, r.app.out.items, "S\x1b[r") != null);
    r.app.out.clearRetainingCapacity();
    try check.same(r);

    for (0..40) |_| {
        try r.keys("\x1b[A");
        try check.same(r);
    }
    for ([_][]const u8{ "\x1b[6~", "\x1b[5~", "x", "\r", "\x7f", "\x1b[6~", "\x1b[6~", "\x1b[5~" }) |k| {
        try r.keys(k);
        try check.same(r);
    }
}

test "layout agrees with the terminal about the width of every row" {
    const pages = [_][:0]const u8{
        "testdata/01-text.md",               "testdata/02-tables.md",
        "testdata/03-lists-and-quotes.md",   "testdata/04-code.md",
        "testdata/05-links.md",              "testdata/06-edge-cases.md",
        "testdata/07-editing-playground.md", "testdata/quickstart.md",
        "testdata/09-gallery.md",
    };
    var tio: vt.TinyIo = .init;
    var term = try vt.Terminal.init(tio.io(), gpa, .{ .cols = 300, .rows = 4 });
    defer term.deinit(gpa);
    var s = term.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[?2027h");
    for (pages) |p| {
        const text = try files.read(gpa, p, 1 << 20);
        defer gpa.free(text);
        for ([_]u16{ 40, 73, 120 }) |w| {
            var l = try md.layout(gpa, text, .{ .width = w });
            defer l.deinit();
            for (l.rows.items) |row| {
                s.nextSlice("\x1b[2J\x1b[H");
                var total: u32 = 0;
                for (l.rowSpans(row)) |span| {
                    total += span.width;
                    s.nextSlice(span.text);
                }
                try testing.expectEqual(@as(usize, total), term.screens.active.cursor.x);
                // Rows fit the column, except a table too wide to shrink any further.
                if (std.mem.indexOf(u8, p, "tables") == null) try testing.expect(total <= w);
            }
        }
    }
}

test "a hostile document can't touch the terminal" {
    var r = try Rig.create(60, 10);
    defer r.destroy();
    const evil =
        "# \x1b]0;pwned\x07Title\n\n" ++
        "text \x1b[2J\x1b[Hmore \x1b]52;c;cHduZWQ=\x07 and \u{9b}31m c1\n\n" ++
        "[x](http://a\x1b]0;pwned\x07b)\n\n" ++
        "| \x1b[?1049l | b |\n|---|---|\n| \x07 | c |\n\n" ++
        "```ansi\n\x1b]0;pwned\x07\x1b[?1049lok\n```\n";
    _ = try r.app.openText("evil", evil, false);
    try r.pump();
    try r.expectShows("Title");
    try r.expectShows("more");
    // Still on the alternate screen, with no title set.
    try testing.expect(r.term.screens.active_key == .alternate);
    try testing.expect(r.term.getTitle() == null);
}

test "a character that joins what follows it can't carry a sequence to the terminal" {
    // In its own short document, so that all of it is on screen.
    var r = try Rig.create(100, 20);
    defer r.destroy();
    const evil = "a \u{0600}\x1b]0;pwned\x07\u{0600}\x1b]52;c;cHduZWQ=\u{0600}\x1b\\ b\n\n" ++
        "[c1](http://a\u{9b}31m.example)\n";
    _ = try r.app.openText("evil", evil, false);
    try r.app.frame();
    try testing.expect(std.mem.indexOf(u8, r.app.out.items, "c1") != null);
    for ([_][]const u8{ "\x1b]0;", "\x1b]52;", "\u{9b}" }) |seq| {
        try testing.expect(std.mem.indexOf(u8, r.app.out.items, seq) == null);
    }
    r.stream.nextSlice(r.app.out.items);
    r.app.out.clearRetainingCapacity();
    try testing.expect(r.term.getTitle() == null);
}

test "editing: type, undo, save, reload" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/tmd-e2e-{d}.md", .{std.c.getpid()});
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    defer _ = std.c.unlink(z.ptr);

    var r = try Rig.create(50, 10);
    defer r.destroy();
    const t = try r.app.open(path);
    try testing.expectEqual(app_mod.Mode.edit, t.mode);
    try r.keys("# Hi\rsome text");
    try r.expectShows("# Hi");
    try r.keys("\x1a");
    try testing.expectEqualStrings("# Hi\nsome ", t.ed.text());
    try r.keys("\x19");
    try testing.expectEqualStrings("# Hi\nsome text", t.ed.text());
    try testing.expect(t.ed.dirty());
    try r.keys("\x13");
    try testing.expect(!t.ed.dirty());
    const saved = try files.read(gpa, z.ptr, 1024);
    defer gpa.free(saved);
    try testing.expectEqualStrings("# Hi\nsome text", saved);
}

test "quitting with unsaved changes asks first" {
    var r = try Rig.create(50, 10);
    defer r.destroy();
    _ = try r.app.openText("doc", "text\n", false);
    try r.pump();
    try r.keys("ex");
    try r.keys("\x11");
    try testing.expect(!r.app.quit);
    try r.expectShows("Save changes");
    try r.keys("n");
    try testing.expect(r.app.quit);
}

test "links: tab to one and follow it into a new tab, and open web links" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.open("testdata/quickstart.md");
    try r.pump();
    // With no graphics the hero image is a link too, so the first page is the second stop.
    try r.keys("\t\t\r");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try r.expectShows("Gallery");
    try r.keys("\x17");
    try testing.expectEqual(@as(usize, 1), r.app.tabs.items.len);

    const t = try r.app.openText("web", "[site](https://example.com) and [bad](javascript:alert)\n", false);
    t.dir = ".";
    try r.pump();
    try r.keys("\t\r");
    try testing.expectEqualStrings("https://example.com", r.app.opened.items);
    r.app.opened.clearRetainingCapacity();
    try r.keys("\t\r");
    try testing.expectEqual(@as(usize, 0), r.app.opened.items.len);
}

test "ctrl+w closes a tab, ctrl+q quits, and plain q and w do neither" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.openText("one", "first\n", false);
    _ = try r.app.openText("two", "second\n", false);
    try r.pump();
    try r.keys("qw");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try testing.expect(!r.app.quit);
    try r.keys("q");
    try r.expectShows("Ctrl+Q quits");

    // The same keys as the kitty keyboard protocol sends them.
    try r.keys("\x1b[119;5u");
    try testing.expectEqual(@as(usize, 1), r.app.tabs.items.len);
    try testing.expect(!r.app.quit);
    try r.keys("\x1b[113;5u");
    try testing.expect(r.app.quit);
}

// The tab bar of "one" and "two": one's close button is at column 6, two's at 12, counting from 1.
const hover_one = "\x1b[<35;2;1M";
const hover_two = "\x1b[<35;9;1M";
const hover_body = "\x1b[<35;30;10M";
const click_close_one = "\x1b[<0;6;1M\x1b[<0;6;1m";
const click_close_two = "\x1b[<0;12;1M\x1b[<0;12;1m";

fn tabRig() !*Rig {
    const r = try Rig.create(80, 20);
    _ = try r.app.openText("one", "first\n", false);
    _ = try r.app.openText("two", "second\n", false);
    try r.pump();
    return r;
}

fn showsClose(r: *Rig) !bool {
    const s = try r.screen();
    defer gpa.free(s);
    return std.mem.indexOf(u8, s, "×") != null;
}

test "a tab shows a close button only while the mouse is over it" {
    var r = try tabRig();
    defer r.destroy();
    try testing.expect(!try showsClose(r));
    try r.keys(hover_one);
    try r.expectShows("one × two");
    try r.keys(hover_two);
    try r.expectShows("one   two ×");
    try r.keys(hover_body);
    try testing.expect(!try showsClose(r));
}

test "the close button closes the tab under it, and leaves the view alone" {
    var r = try tabRig();
    defer r.destroy();
    _ = try r.app.openText("three", "third\n", false);
    try r.pump();
    const active = r.app.tab();
    try r.keys(hover_one);
    try r.keys(click_close_one);
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try testing.expectEqual(active, r.app.tab());
    try r.expectShows("third");
    // "two" slid under the mouse, so it can go next without the mouse moving.
    try r.expectShows("two ×");
    try r.keys("\x1b[<0;6;1M");
    try testing.expectEqual(@as(usize, 1), r.app.tabs.items.len);
    try testing.expectEqual(active, r.app.tab());
    try testing.expect(!r.app.quit);
    try testing.expect(!try showsClose(r));
}

test "a click can't close a tab from a button that isn't showing" {
    var r = try tabRig();
    defer r.destroy();
    // A terminal that doesn't report hover: the click selects the tab, as anywhere else on it.
    try r.keys(click_close_one);
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), r.app.active);
    // Over one tab, on another's button.
    try r.keys(hover_one);
    try r.keys(click_close_two);
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    // Only the left button closes.
    try r.keys(hover_one);
    try r.keys("\x1b[<2;6;1M\x1b[<2;6;1m");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
}

test "the close button asks first about unsaved changes, and waits for an open prompt" {
    var r = try tabRig();
    defer r.destroy();
    try r.app.tabs.items[0].ed.insert("changed", .other);
    try r.pump();
    try r.keys(hover_one);
    try r.expectShows("one*×");
    try r.keys(click_close_one);
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try testing.expectEqual(@as(usize, 0), r.app.active);
    try testing.expectEqual(app_mod.Prompt.confirm_close, r.app.prompt);
    // While that's open, another tab's button does nothing.
    try r.keys(hover_two);
    try r.keys(click_close_two);
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
}

test "mouse movement that changes nothing skips the frame" {
    var r = try tabRig();
    defer r.destroy();
    const move = struct {
        fn at(x: u16, y: u16) input.Event {
            return .{ .mouse = .{ .button = .none, .x = x, .y = y, .press = true, .motion = true, .mods = .{} } };
        }
    }.at;
    try testing.expect(r.app.idleMotion(move(30, 10)));
    try testing.expect(!r.app.idleMotion(move(1, 0)));
    try r.app.event(move(1, 0));
    try testing.expect(r.app.idleMotion(move(2, 0)));
    try testing.expect(!r.app.idleMotion(move(8, 0)));
    try testing.expect(!r.app.idleMotion(move(30, 10)));
    // A drag selects in the editor, so it always gets a frame.
    var drag = move(30, 10);
    drag.mouse.button = .left;
    try testing.expect(!r.app.idleMotion(drag));
    try testing.expect(!r.app.idleMotion(.{ .focus = true }));
}

fn selectRig(text: []const u8) !*Rig {
    const r = try Rig.create(40, 12);
    _ = try r.app.openText("doc", text, false);
    try r.pump();
    return r;
}

/// Presses at one cell and releases at another, counting from 0 within the text column.
fn dragCells(r: *Rig, x0: u16, y0: u16, x1: u16, y1: u16) !void {
    const m = r.app.leftMargin();
    var b: [80]u8 = undefined;
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};{d}M\x1b[<32;{d};{d}M\x1b[<0;{d};{d}m", .{ m + x0 + 1, y0 + 1, m + x1 + 1, y1 + 1, m + x1 + 1, y1 + 1 }));
}

test "dragging selects text, shows it, and copies it" {
    var r = try selectRig("hello world\n");
    defer r.destroy();
    try dragCells(r, 0, 0, 4, 0);
    try testing.expectEqualStrings("hello", r.app.clip.items);
    try r.expectShows("Copied");
    try testing.expect(std.mem.indexOf(u8, r.app.screen.bytes.items, ";7m") != null);
    try r.app.event(.{ .key = .{ .code = input.Key.escape } });
    try r.pump();
    try testing.expect(r.app.tab().selection == null);
    try testing.expect(std.mem.indexOf(u8, r.app.screen.bytes.items, ";7m") == null);
}

test "copying reaches the system clipboard, and the document can't trigger it" {
    var r = try selectRig("hello\n");
    defer r.destroy();
    try dragCells(r, 0, 0, 4, 0);
    try r.app.frame();
    r.app.out.clearRetainingCapacity();
    // Selected text copies again on request, and Ctrl+C only quits once nothing is selected.
    try r.app.event(.{ .key = .{ .code = 'c', .mods = .{ .ctrl = true } } });
    try testing.expect(std.mem.indexOf(u8, r.app.out.items, "\x1b]52;c;aGVsbG8=\x1b\\") != null);
    try testing.expect(!r.app.quit);
    r.app.out.clearRetainingCapacity();
    try r.app.event(.{ .key = .{ .code = input.Key.escape } });
    try r.app.event(.{ .key = .{ .code = 'c', .mods = .{ .ctrl = true } } });
    try testing.expect(r.app.quit);
}

test "a link follows on release, and a drag across it doesn't follow it" {
    var r = try selectRig("[link](https://a.example) text\n");
    defer r.destroy();
    try dragCells(r, 0, 0, 3, 0);
    try testing.expectEqualStrings("", r.app.opened.items);
    try testing.expectEqualStrings("link", r.app.clip.items);
    const m = r.app.leftMargin();
    var b: [40]u8 = undefined;
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1M", .{m + 2}));
    try testing.expectEqualStrings("", r.app.opened.items);
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1m", .{m + 2}));
    try testing.expectEqualStrings("https://a.example", r.app.opened.items);
}

test "a drag past the view scrolls, and the selection stays with the text" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..40) |i| try text.print(gpa, "line {d}\n\n", .{i});
    var r = try selectRig(text.items);
    defer r.destroy();
    const m = r.app.leftMargin();
    var b: [40]u8 = undefined;
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1M", .{m + 1}));
    for (0..3) |_| try r.keys(try std.fmt.bufPrint(&b, "\x1b[<32;{d};40M", .{m + 7}));
    try testing.expectEqual(@as(u32, 3), r.app.tab().top);
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};40m", .{m + 7}));
    try testing.expect(std.mem.startsWith(u8, r.app.clip.items, "line 0\n\nline 1\n\n"));
}

test "a large heading copies as its words" {
    var r = try Rig.create(60, 16);
    defer r.destroy();
    r.app.store.mode = .placeholder;
    r.app.store.big_headings = true;
    r.app.store.font_path = build_options.test_font ++ "";
    _ = try r.app.openText("doc", "# Big title\n\nafter it\n", false);
    try r.pump();
    try testing.expect(r.app.tab().layout.?.rows.items[0].image != 0);
    const rows: u16 = @intCast(r.app.tab().layout.?.rowForOffset(13));
    try dragCells(r, 0, 0, 7, rows);
    try testing.expectEqualStrings("Big title\n\nafter it", r.app.clip.items);
}

test "a resize drops the selection, and a new press isn't taken for the old drag" {
    var r = try selectRig("hello world\n");
    defer r.destroy();
    try dragCells(r, 0, 0, 4, 0);
    try r.app.resize(30, 12);
    try r.pump();
    try testing.expect(r.app.tab().selection == null);

    // The release happened outside the window, so it never came.
    const m = r.app.leftMargin();
    var b: [40]u8 = undefined;
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1M\x1b[<32;{d};1M", .{ m + 1, m + 3 }));
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1M", .{m + 7}));
    try testing.expect(r.app.tab().selection == null);
    try testing.expectEqual(@as(u32, 6), r.app.drag_from.?.col);
}

test "a page from the web can't reach this disk" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    r.app.store.mode = .placeholder;
    const doc = "![pic](testdata/images/gradient.png)\n\n[local](testdata/01-text.md)\n";

    // As a local file, both of these resolve.
    const local = try r.app.openText("local.md", doc, true);
    try r.pump();
    try testing.expect(local.layout.?.rows.items[0].image != 0);

    const page = try r.app.openText("page.md", doc, true);
    page.url = try gpa.dupe(u8, "https://a.example/docs/page.md");
    r.app.active = 1;
    try r.pump();
    for (page.layout.?.rows.items) |row| try testing.expectEqual(@as(u32, 0), row.image);

    try r.keys("\t\t\r");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try testing.expect(std.mem.endsWith(u8, r.app.opened.items, "a.example/docs/testdata/01-text.md"));
}

test "a page from the web has an icon, and shows its address in the footer" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.openText("one", "first\n", false);
    const page = try r.app.openText("page.md", "second\n", true);
    page.url = try gpa.dupe(u8, "https://a.example/docs/page.md");
    r.app.active = 1;
    try r.pump();
    try r.expectShows("🌐 page.md");
    try r.expectShows("https://a.example/docs/page.md");
    try r.expectShows("100%");

    // The icon takes cells, so the close button is further along: this tab starts at column 8
    // counting from 1, then 3 for the icon, 7 for the name and the mark's cell.
    try r.keys("\x1b[<35;16;1M");
    try r.expectShows("page.md ×");
    try r.keys("\x1b[<0;19;1M\x1b[<0;19;1m");
    try testing.expectEqual(@as(usize, 1), r.app.tabs.items.len);
}

test "a long address leaves room for the position" {
    var r = try Rig.create(60, 20);
    defer r.destroy();
    const page = try r.app.openText("page.md", "text\n", true);
    var long: [300]u8 = undefined;
    @memset(&long, 'a');
    page.url = try std.fmt.allocPrint(gpa, "https://a.example/{s}", .{long});
    try r.pump();
    try r.expectShows("…");
    try r.expectShows("100%");
}

test "a line and a blank row frame the status row, unless the window is short" {
    var r = try tabRig();
    defer r.destroy();
    const text = try r.screen();
    defer gpa.free(text);
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| try rows.append(gpa, l);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "────────────────────────────────────────────────────────────────────────────────"));
    // Nothing under the tabs.
    try testing.expect(std.mem.indexOf(u8, rows.items[1], "─") == null);
    try testing.expect(std.mem.indexOf(u8, rows.items[17], "────────────────────────────────────────────────────────────────────────────────") != null);
    try testing.expect(std.mem.indexOf(u8, rows.items[18], "two") != null);

    var small = try Rig.create(40, 6);
    defer small.destroy();
    _ = try small.app.openText("one", "first\n", false);
    _ = try small.app.openText("two", "second\n", false);
    try small.pump();
    const s = try small.screen();
    defer gpa.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "──────────") == null);
}

test "links that leave tmd show the arrow in the app" {
    var r = try selectRig("[out](https://a.example) and [in](b.md)\n");
    defer r.destroy();
    try r.expectShows("out↗ and in");
}

test "o opens a file in a new tab, and says when it can't" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    r.app.settings.experimental_edit = false;
    _ = try r.app.openText("one", "first\n", false);
    try r.pump();
    try r.keys("o");
    try r.expectShows("Open: ");
    try r.keys("testdata/01-text.md\r");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), r.app.active);
    try r.expectShows("01-text.md");

    // A file that's already open comes forward instead of opening twice.
    r.app.active = 0;
    try r.pump();
    try r.keys("otestdata/01-text.md\r");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try testing.expectEqual(@as(usize, 1), r.app.active);

    try r.keys("o/nonexistent/x.md\r");
    try r.expectShows("No such file: /nonexistent/x.md");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);

    // Nothing typed, nothing opened, and Esc backs out.
    try r.keys("o\r");
    try testing.expectEqual(app_mod.Prompt.none, r.app.prompt);
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
}

test "tab completes paths at the Open prompt, and shows what's left to choose" {
    var r = try Rig.create(100, 20);
    defer r.destroy();
    _ = try r.app.openText("one", "first\n", false);
    try r.pump();
    try r.keys("otestdata/0\t");
    try r.expectShows("01-text.md");
    try testing.expectEqualStrings("testdata/0", r.app.prompt_text.items);
    // Typing narrows it, and the choices go until the next Tab.
    try r.keys("1");
    try r.expectHides("02-tables.md");
    try r.keys("\t");
    try testing.expectEqualStrings("testdata/01-text.md", r.app.prompt_text.items);
    try r.keys("\r");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);

    // A URL has nothing to complete from, and stays as typed.
    try r.keys("ohttps://a.example/x\t");
    try testing.expectEqualStrings("https://a.example/x", r.app.prompt_text.items);
}

test "a prompt stays with its tab, so a click can't move the answer to another" {
    var r = try tabRig();
    defer r.destroy();
    try r.app.tabs.items[0].ed.insert("changed", .other);
    try r.app.tabs.items[1].ed.insert("also changed", .other);
    r.app.active = 0;
    try r.pump();
    try r.app.event(.{ .key = .{ .code = 'w', .mods = .{ .ctrl = true } } });
    try testing.expectEqual(app_mod.Prompt.confirm_close, r.app.prompt);
    try r.keys("\x1b[<0;9;1M\x1b[<0;9;1m");
    try testing.expectEqual(@as(usize, 0), r.app.active);
}

test "a link to a local file opens only if it can't run anything" {
    var r = try selectRig("[a](testdata/images/gradient.png) [run](build.zig)\n");
    defer r.destroy();
    const m = r.app.leftMargin();
    var b: [40]u8 = undefined;
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1M\x1b[<0;{d};1m", .{ m + 1, m + 1 }));
    try testing.expect(std.mem.endsWith(u8, r.app.opened.items, "gradient.png"));
    r.app.opened.clearRetainingCapacity();
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1M\x1b[<0;{d};1m", .{ m + 5, m + 5 }));
    try testing.expectEqualStrings("", r.app.opened.items);
    try r.expectShows("Not opening build.zig");
}

test "a link to a device doesn't hang or quit" {
    var r = try selectRig("[z](/dev/zero.md) [y](/dev/zero)\n");
    defer r.destroy();
    const m = r.app.leftMargin();
    var b: [40]u8 = undefined;
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1M\x1b[<0;{d};1m", .{ m + 1, m + 1 }));
    try r.expectShows("Not found");
    try testing.expect(!r.app.quit);
}

test "ctrl+backtick cycles tabs from preview and the editor, however it arrives" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.openText("one", "first\n", false);
    _ = try r.app.openText("two", "second\n", false);
    _ = try r.app.openText("three", "third\n", false);
    r.app.active = 0;
    try r.pump();
    try r.keys("\x1b[96;5u"); // kitty protocol
    try testing.expectEqual(@as(usize, 1), r.app.active);
    try r.keys("\x00"); // legacy terminals
    try testing.expectEqual(@as(usize, 2), r.app.active);
    try r.keys("\x1b[96;5u"); // wraps around
    try testing.expectEqual(@as(usize, 0), r.app.active);
    try r.keys("\x1b[96;6u"); // with Shift, backwards
    try testing.expectEqual(@as(usize, 2), r.app.active);

    // In the editor it switches tabs and types nothing.
    try r.keys("e");
    const before = r.app.tab().ed.generation;
    const editing = r.app.tab();
    try r.keys("\x1b[96;5u");
    try testing.expectEqual(@as(usize, 0), r.app.active);
    try testing.expectEqual(before, editing.ed.generation);
}

fn expectNoHighlight(r: *Rig) !void {
    try testing.expectEqual(@as(u32, 0), r.app.tab().focus);
    try testing.expect(std.mem.indexOf(u8, r.app.screen.bytes.items, ";7m") == null);
}

test "the link highlight only lasts while tabbing" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.openText("doc", "[one](https://a.example) and [two](https://b.example) and [three](https://c.example)\n", false);
    try r.pump();

    // Tabbing shows it, and any other key ends it.
    try r.keys("\t");
    try testing.expect(std.mem.indexOf(u8, r.app.screen.bytes.items, ";7m") != null);
    try r.keys("j");
    try expectNoHighlight(r);

    // Following leaves nothing behind, and Tab carries on from that link.
    try r.keys("\t\r");
    try testing.expectEqualStrings("https://b.example", r.app.opened.items);
    try expectNoHighlight(r);
    try r.keys("\t");
    try testing.expectEqual(@as(u32, 3), r.app.tab().focus);
    try r.keys("\x1b[A");
    try expectNoHighlight(r);

    // So does a click, on the first press and after coming back.
    const x = r.app.leftMargin() + 1;
    var b: [32]u8 = undefined;
    try r.keys(try std.fmt.bufPrint(&b, "\x1b[<0;{d};1M\x1b[<0;{d};1m", .{ x + 1, x + 1 }));
    try testing.expectEqualStrings("https://a.example", r.app.opened.items);
    try expectNoHighlight(r);
}

test "coming back from a followed page shows no highlight" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.open("testdata/quickstart.md");
    try r.pump();
    try r.keys("\t\t\r");
    try testing.expectEqual(@as(usize, 2), r.app.tabs.items.len);
    try r.keys("\x17");
    try testing.expectEqual(@as(usize, 1), r.app.tabs.items.len);
    try r.pump();
    try expectNoHighlight(r);
}

test "the HUD sits under the status line and gives its rows back" {
    var r = try Rig.create(100, 20);
    defer r.destroy();
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    for (0..60) |_| try doc.appendSlice(gpa, "line\n\n");
    _ = try r.app.openText("doc.md", doc.items, false);
    try r.pump();

    try r.keys("\x1b[24~");
    try testing.expect(r.app.hud);
    const text = try r.screen();
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var at: usize = 0;
    var status: ?usize = null;
    var frame: ?usize = null;
    var sent: ?usize = null;
    while (lines.next()) |l| : (at += 1) {
        if (std.mem.indexOf(u8, l, "doc.md") != null) status = at;
        if (std.mem.indexOf(u8, l, "frame ") != null) frame = at;
        if (std.mem.indexOf(u8, l, "sent ") != null) sent = at;
    }
    try testing.expectEqual(@as(usize, 15), status.?);
    try testing.expectEqual(@as(usize, 16), frame.?);
    try testing.expectEqual(@as(usize, 18), sent.?);
    try r.expectShows("max ");
    try r.expectShows("slow ");
    try r.expectShows("F11 save log");

    // Scrolling under it still matches what a repaint would show.
    try r.keys("jjj");
    try r.expectShows("sent ");

    // A prompt goes on the status row, not the screen's last.
    try r.keys("/");
    const c = r.term.screens.active.cursor;
    try testing.expectEqual(@as(usize, 15), c.y);
    try r.keys("\x1b[27u");
    try testing.expectEqual(.none, r.app.prompt);

    try r.keys("\x1b[24~");
    try testing.expect(!r.app.hud);
    try r.expectHides("sent ");
}

test "the HUD counts the frames really drawn, and refreshing it doesn't count" {
    const trace = @import("trace.zig");
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.openText("doc.md", "text\n", false);
    r.app.hud = true;
    try r.pump();
    try r.keys("jjjj");
    const drawn = trace.drawnFps();
    try testing.expect(drawn >= 5);
    r.app.hud_tick = true;
    try r.pump();
    try testing.expect(trace.drawnFps() <= drawn);
    try testing.expect(!r.app.hud_tick);
}

test "the frame log says what happened, and nothing about the document" {
    const trace = @import("trace.zig");
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.openText("private-name.md", "secret words\n", false);
    try r.pump();
    try r.keys("e");
    try r.keys("zqxjv");
    const slow = trace.slowFrames();
    try r.app.event(.{ .key = .{ .code = input.Key.f1 + 10 } });
    try testing.expectEqual(slow, trace.slowFrames());
    const message = r.app.message;
    try testing.expect(std.mem.startsWith(u8, message, "Frame log: "));
    const path = try gpa.dupeSentinel(u8, message["Frame log: ".len..], 0);
    defer gpa.free(path);
    defer _ = std.c.unlink(path.ptr);

    const text = try @import("layout").files.read(gpa, path.ptr, 1024 * 1024);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "| key |") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Layout") != null);
    for ([_][]const u8{ "private-name", "secret", "zqxjv" }) |s| {
        try testing.expect(std.mem.indexOf(u8, text, s) == null);
    }
}

test "very short windows drop the HUD and tab bar rather than overrun" {
    var r = try Rig.create(60, 10);
    defer r.destroy();
    _ = try r.app.openText("one", "a\n", false);
    _ = try r.app.openText("two", "b\n", false);
    r.app.hud = true;
    for ([_]u16{ 1, 2, 3, 4, 7, 8, 9, 10 }) |rows| {
        try r.app.resize(60, rows);
        try r.app.frame();
        try testing.expect(r.app.screen.y <= rows);
        r.app.out.clearRetainingCapacity();
    }
}

test "frame rate targets follow the p99 budget" {
    const trace = @import("trace.zig");
    try testing.expectEqual(@as(u32, 1000), trace.bestFps(900));
    try testing.expectEqual(@as(u32, 720), trace.bestFps(1200));
    try testing.expectEqual(@as(u32, 60), trace.bestFps(16_000));
    try testing.expectEqual(@as(u32, 0), trace.bestFps(20_000));
    try testing.expectEqual(@as(u32, 16_666), trace.fpsBudgetUs(60));
}

test "editing is hidden unless switched on" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    r.app.settings.experimental_edit = false;

    // A file that doesn't exist can't start an empty editor.
    try testing.expectError(error.NotFound, r.app.open("/tmp/tmd-does-not-exist.md"));

    const t = try r.app.openText("doc.md", "**bold** text\n", false);
    try r.pump();
    try r.expectHides("e edit");
    try r.keys("e");
    try r.keys("i");
    try r.keys("\x12"); // Ctrl+R
    try testing.expectEqual(app_mod.Mode.preview, t.mode);
    try r.expectHides("**");

    // Help doesn't mention it either.
    try r.keys("?");
    try r.expectHides("Editor");
    try r.expectHides("Edit,");

    // Switched on, it all comes back.
    try r.keys("\x17");
    r.app.settings.experimental_edit = true;
    r.app.screen.invalidate();
    try r.pump();
    try r.expectShows("e edit");
    try r.keys("e");
    try testing.expectEqual(app_mod.Mode.edit, t.mode);
}

test "resizing keeps the focused link" {
    var r = try Rig.create(80, 20);
    defer r.destroy();
    _ = try r.app.open("testdata/quickstart.md");
    try r.pump();
    try r.keys("\t\t\t");
    try testing.expectEqual(@as(u32, 3), r.app.tab().focus);
    try r.app.resize(70, 14);
    try r.pump();
    try r.keys("\t");
    try testing.expectEqual(@as(u32, 4), r.app.tab().focus);
}

test "find highlights and jumps" {
    var r = try Rig.create(60, 10);
    defer r.destroy();
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    for (0..50) |_| try doc.appendSlice(gpa, "filler\n\n");
    try doc.appendSlice(gpa, "the needle here\n\n");
    for (0..50) |_| try doc.appendSlice(gpa, "filler\n\n");
    _ = try r.app.openText("doc", doc.items, false);
    try r.pump();
    try r.keys("/needle\r");
    try r.expectShows("the needle here");
}

test "images become placeholder cells backed by an image in the terminal" {
    var r = try Rig.create(80, 30);
    defer r.destroy();
    r.app.store.mode = .placeholder;
    _ = try r.app.open("testdata/08-images-and-ansi.md");
    try r.pump();

    const kitty = &r.term.screens.active.kitty_images;
    try testing.expect(kitty.images.count() >= 1);
    try testing.expect(kitty.placements.count() >= 1);
    const text = try r.screen();
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\u{10EEEE}") != null);
    try r.expectHides("Gradient");

    // Images upload as they come into view, and only once.
    try r.keys("GG");
    const uploaded = r.app.store.sentCount();
    try testing.expectEqual(@as(usize, 3), uploaded);
    try testing.expectEqual(uploaded, kitty.images.count());
    try r.keys("ggGG");
    try testing.expectEqual(uploaded, r.app.store.sentCount());
    try testing.expectEqual(uploaded, kitty.images.count());
}

fn useTestFont(r: *Rig) void {
    r.app.store.big_headings = true;
    r.app.store.font_path = build_options.test_font ++ "";
    r.app.store.mode = .placeholder;
}

test "large headings are images a few rows tall, and find still reaches them" {
    var r = try Rig.create(80, 24);
    defer r.destroy();
    useTestFont(r);
    _ = try r.app.openText("doc", "# Big title\n\nbody text\n\n## Smaller\n\n### Three stays text\n", false);
    try r.pump();

    const l = &r.app.tab().layout.?;
    try testing.expectEqual(@as(u16, 3), l.rows.items[0].image_rows);
    try testing.expect(l.rows.items[0].image != 0);
    try r.expectShows("body text");
    try r.expectHides("Big title");
    try r.expectShows("Three stays text");
    const kitty = &r.term.screens.active.kitty_images;
    try testing.expectEqual(@as(usize, 2), kitty.images.count());

    try r.keys("/smaller\r");
    try testing.expectEqual(@as(usize, 1), r.app.match_rows.items.len);
}

test "a long heading wraps onto several images, inside the column" {
    var r = try Rig.create(50, 24);
    defer r.destroy();
    useTestFont(r);
    _ = try r.app.openText("doc", "# A heading that is much too long to fit on one line of this\n", false);
    try r.pump();
    const l = &r.app.tab().layout.?;
    try testing.expect(l.rows.items.len > 3);
    for (l.rows.items) |row| try testing.expect(row.image_cols <= r.app.settings.max_width and row.image_cols <= 50);
}

test "headings a font can't draw, or with links, stay as text" {
    var r = try Rig.create(80, 24);
    defer r.destroy();
    useTestFont(r);
    _ = try r.app.openText("doc", "# 你好世界\n\n# See [this](http://a)\n\n# Good\n", false);
    try r.pump();
    try r.expectShows("你好世界");
    try r.expectShows("See this");
    try r.expectHides("Good");
}

test "off-screen images are evicted under the budget and come back" {
    var r = try Rig.create(60, 12);
    defer r.destroy();
    useTestFont(r);
    r.app.store.budget = 400 * 1024;
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    for (0..60) |i| {
        var b: [96]u8 = undefined;
        try doc.appendSlice(gpa, try std.fmt.bufPrint(&b, "# Heading number {d}\n\nfiller\n\nfiller\n\nfiller\n\n", .{i}));
    }
    _ = try r.app.openText("doc", doc.items, false);
    try r.pump();
    for (0..80) |_| try r.keys(" ");
    try testing.expect(r.app.store.used_bytes <= r.app.store.budget);
    try testing.expect(r.app.store.sentCount() < 60);
    // Everything on screen is really in the terminal.
    const kitty = &r.term.screens.active.kitty_images;
    try testing.expectEqual(r.app.store.sentCount(), kitty.images.count());
    try r.keys("g");
    const first = r.app.store.items.items[r.app.tab().layout.?.rows.items[0].image - 1];
    try testing.expect(first.sent);
    try testing.expect(kitty.imageById(first.id) != null);
}

test "changing palette redraws headings in the new color" {
    var r = try Rig.create(60, 12);
    defer r.destroy();
    useTestFont(r);
    _ = try r.app.openText("doc", "# Title\n", false);
    try r.pump();
    const before = r.app.tab().layout.?.rows.items[0].image;
    try r.keys("t");
    const after = r.app.tab().layout.?.rows.items[0].image;
    try testing.expect(before != after);
    try testing.expect(r.app.store.items.items[before - 1].rgb != r.app.store.items.items[after - 1].rgb);
}

test "with no graphics, images fall back to their alt text" {
    var r = try Rig.create(80, 30);
    defer r.destroy();
    _ = try r.app.open("testdata/08-images-and-ansi.md");
    try r.pump();
    try r.expectShows("Gradient");
    const text = try r.screen();
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\u{10EEEE}") == null);
}

test "direct placements follow the view" {
    var r = try Rig.create(80, 12);
    defer r.destroy();
    r.app.store.mode = .direct;
    _ = try r.app.open("testdata/08-images-and-ansi.md");
    try r.pump();
    const kitty = &r.term.screens.active.kitty_images;
    try testing.expect(kitty.placements.count() >= 1);
    try r.keys("GG");
    try r.keys("gg");
    try testing.expect(kitty.placements.count() >= 1);

    // An SVG is uploaded at its display size, so crops must use that and not the source size.
    for (r.app.store.items.items) |im| {
        if (im.sent) try testing.expect(im.sent_w > 0 and im.sent_h > 0);
    }
}

test "narrow windows and tiny heights don't crash" {
    var r = try Rig.create(80, 24);
    defer r.destroy();
    _ = try r.app.open("testdata/02-tables.md");
    try r.pump();
    for ([_][2]u16{ .{ 1, 1 }, .{ 2, 2 }, .{ 10, 1 }, .{ 5, 40 }, .{ 200, 3 }, .{ 80, 24 } }) |s| {
        try r.app.resize(s[0], s[1]);
        try r.app.frame();
        r.app.out.clearRetainingCapacity();
        try r.app.event(.{ .key = .{ .code = 'j' } });
        try r.app.frame();
        r.app.out.clearRetainingCapacity();
        try r.app.event(.{ .key = .{ .code = 'e' } });
        try r.app.frame();
        r.app.out.clearRetainingCapacity();
        try r.app.event(.{ .key = .{ .code = input.Key.escape } });
        try r.app.frame();
        r.app.out.clearRetainingCapacity();
    }
}

fn widestImage(r: *Rig) u16 {
    var cols: u16 = 0;
    for (r.app.tab().layout.?.rows.items) |row| {
        if (row.image != 0) cols = @max(cols, row.image_cols);
    }
    return cols;
}

test "images are the same size however a pane started" {
    // Already sized, as when launched from a shell.
    var settled = try Rig.create(100, 40);
    defer settled.destroy();
    useTestFont(settled);
    settled.app.store.points = true;
    _ = try settled.app.store.setCell(&settled.app.out, 14, 28);
    _ = try settled.app.open("testdata/quickstart.md");
    try settled.pump();

    // The first command in a new pane: defaults at first, and the real size just after.
    var early = try Rig.create(100, 40);
    defer early.destroy();
    useTestFont(early);
    early.app.store.points = true;
    _ = try early.app.store.setCell(&early.app.out, 8, 16);
    _ = try early.app.open("testdata/quickstart.md");
    try early.pump();
    const uploaded = early.app.store.sentCount();
    try testing.expect(uploaded > 0);
    try testing.expect(try early.app.store.setCell(&early.app.out, 14, 28));
    try early.app.resize(100, 40);
    try early.pump();

    try testing.expectEqual(widestImage(settled), widestImage(early));
    try testing.expectEqual(@as(u32, 2), early.app.store.scale);
    try testing.expectEqual(@as(u32, 7), early.app.store.cell_w);
    // The old uploads went, rather than piling up behind the new ones.
    const kitty = &early.term.screens.active.kitty_images;
    try testing.expectEqual(early.app.store.sentCount(), kitty.images.count());
    try testing.expectEqual(settled.app.store.sentCount(), early.app.store.sentCount());
}

test "a high-density cell only halves when sizing in points" {
    var r = try Rig.create(80, 24);
    defer r.destroy();
    _ = try r.app.store.setCell(&r.app.out, 14, 28);
    try testing.expectEqual(@as(u32, 14), r.app.store.cell_w);
    try testing.expectEqual(@as(u32, 1), r.app.store.scale);
    try testing.expect(!try r.app.store.setCell(&r.app.out, 14, 28));
    r.app.store.points = true;
    try testing.expect(try r.app.store.setCell(&r.app.out, 14, 28));
    try testing.expectEqual(@as(u32, 7), r.app.store.cell_w);
    try testing.expect(try r.app.store.setCell(&r.app.out, 9, 18));
    try testing.expectEqual(@as(u32, 9), r.app.store.cell_w);
    try testing.expectEqual(@as(u32, 1), r.app.store.scale);
}

test "a new cell size lays images out again, even at the same window size" {
    var r = try Rig.create(100, 40);
    defer r.destroy();
    useTestFont(r);
    _ = try r.app.store.setCell(&r.app.out, 8, 16);
    _ = try r.app.open("testdata/quickstart.md");
    try r.pump();
    const before = widestImage(r);
    try testing.expect(before > 69);

    try testing.expect(try r.app.store.setCell(&r.app.out, 14, 28));
    try r.app.resize(100, 40);
    try r.pump();
    // hero.svg is 960 pixels wide, and images never grow past their own pixels.
    try testing.expectEqual(@as(u16, 69), widestImage(r));
}
