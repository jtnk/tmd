//! Loading Markdown from the web. tmd has no network code of its own, as TLS would cost more than
//! the rest of the binary, so it asks curl. Nothing here runs unless the user gave a URL or followed
//! a link: a document can't make a request by itself.
const std = @import("std");
const c = std.c;
const files = @import("files.zig");

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub const Error = error{ NoCurl, FetchFailed, NotMarkdown, HttpError } || std.mem.Allocator.Error;

/// A page, and the URL that finally answered, which is what relative links resolve against.
pub const Page = struct { text: []u8, url: []u8 };

const max_page = 64 * 1024 * 1024;

pub fn isUrl(s: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, "https://") or std.ascii.startsWithIgnoreCase(s, "http://");
}

/// What a failed load should say, or null if the error isn't about loading.
pub fn describe(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.NoCurl => "loading URLs needs curl",
        error.FetchFailed, error.HttpError => "couldn't load",
        error.NotMarkdown => "no Markdown at",
        else => null,
    };
}

/// The URL without its query and fragment.
pub fn pathOf(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfAny(u8, url, "?#") orelse url.len];
}

/// A short name for a tab: the last part of the path, or the host.
pub fn nameOf(url: []const u8) []const u8 {
    const p = std.mem.trimEnd(u8, pathOf(url), "/");
    return p[(std.mem.lastIndexOfScalar(u8, p, '/') orelse return p) + 1 ..];
}

/// Where sites that publish Markdown keep it, when the page itself only offers HTML. Pages append
/// .md, and directories use index.html.md, which is the llms.txt convention.
fn alternatives(a: std.mem.Allocator, url: []const u8) ![]const []const u8 {
    const clean = pathOf(url);
    const host = (std.mem.indexOf(u8, clean, "://") orelse return &.{}) + 3;
    const slash = std.mem.indexOfScalarPos(u8, clean, host, '/') orelse clean.len;
    const path = clean[slash..];
    var out: std.ArrayList([]const u8) = .empty;
    if (path.len <= 1 or path[path.len - 1] == '/') {
        const base = std.mem.trimEnd(u8, clean, "/");
        try out.append(a, try std.fmt.allocPrint(a, "{s}/index.md", .{base}));
        try out.append(a, try std.fmt.allocPrint(a, "{s}/index.html.md", .{base}));
        return out.items;
    }
    const last = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0) + 1 ..];
    const html = std.ascii.endsWithIgnoreCase(last, ".html") or std.ascii.endsWithIgnoreCase(last, ".htm");
    if (std.mem.indexOfScalar(u8, last, '.') != null and !html) return out.items;
    try out.append(a, try std.fmt.allocPrint(a, "{s}.md", .{clean}));
    if (!html) try out.append(a, try std.fmt.allocPrint(a, "{s}/index.html.md", .{clean}));
    return out.items;
}

fn looksLikeHtml(body: []const u8) bool {
    const t = std.mem.trimStart(u8, body[0..@min(body.len, 512)], " \t\r\n");
    return std.ascii.startsWithIgnoreCase(t, "<!doctype html") or std.ascii.startsWithIgnoreCase(t, "<html");
}

fn isMarkdownReply(content_type: []const u8, body: []const u8, url: []const u8) bool {
    if (std.ascii.findIgnoreCase(content_type, "markdown") != null) return true;
    if (looksLikeHtml(body) or std.ascii.findIgnoreCase(content_type, "html") != null) return false;
    const p = pathOf(url);
    const named = std.ascii.endsWithIgnoreCase(p, ".md") or std.ascii.endsWithIgnoreCase(p, ".markdown");
    return named or std.ascii.findIgnoreCase(content_type, "text/plain") != null;
}

const Reply = struct { body: []u8, meta: []u8 };

fn request(gpa: std.mem.Allocator, url: []const u8) Error!Reply {
    const z = try gpa.dupeSentinel(u8, url, 0);
    defer gpa.free(z);
    var out: [2]c.fd_t = undefined;
    var err: [2]c.fd_t = undefined;
    if (c.pipe(&out) != 0) return error.FetchFailed;
    if (c.pipe(&err) != 0) {
        _ = c.close(out[0]);
        _ = c.close(out[1]);
        return error.FetchFailed;
    }
    const argv = [_:null]?[*:0]const u8{
        // -g: brackets and braces in a link are its address, not a pattern of requests to make.
        "curl", "-q", "-sfLg",
        // A redirect can't reach file:// or anything else that isn't the web.
        "--proto", "=http,https", "--proto-redir", "=http,https",
        "--max-redirs", "5", "--max-time", "20", "--max-filesize", std.fmt.comptimePrint("{d}", .{max_page}),
        "-A", "tmd",
        "-H", "Accept: text/markdown, text/plain;q=0.9, */*;q=0.1",
        "-w", "%{stderr}%{url_effective}\\n%{content_type}",
        "--url", z.ptr,
    };
    // The app ignores SIGCHLD so links can open in children nobody waits for, but this one has to
    // be waited for: with it ignored, its exit status is gone.
    var dfl = std.mem.zeroes(c.Sigaction);
    dfl.handler = .{ .handler = c.SIG.DFL };
    var old_chld: c.Sigaction = undefined;
    _ = c.sigaction(.CHLD, &dfl, &old_chld);
    defer _ = c.sigaction(.CHLD, &old_chld, null);

    const pid = c.fork();
    if (pid == 0) {
        const dev = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        if (dev >= 0) _ = c.dup2(dev, 0);
        _ = c.dup2(out[1], 1);
        _ = c.dup2(err[1], 2);
        for ([_]c.fd_t{ out[0], out[1], err[0], err[1] }) |fd| _ = c.close(fd);
        _ = execvp("curl", &argv);
        c._exit(127);
    }
    _ = c.close(out[1]);
    _ = c.close(err[1]);
    defer _ = c.close(out[0]);
    defer _ = c.close(err[0]);
    if (pid < 0) return error.FetchFailed;

    // curl writes to stderr only once the body is done, so one pipe at a time can't block.
    const body = files.readFd(gpa, out[0], max_page) catch null;
    errdefer if (body) |b| gpa.free(b);
    // Too much to read: curl would otherwise sit blocked on the pipe, where its timeout can't fire.
    if (body == null) _ = c.kill(pid, .TERM);
    const meta = files.readFd(gpa, err[0], 16 * 1024) catch null;
    errdefer if (meta) |m| gpa.free(m);
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) < 0) return error.FetchFailed;
    const code = (status >> 8) & 0xff;
    if (code == 127) return error.NoCurl;
    // curl says 22 for an error from the server, which only means this address has nothing. Anything
    // else is the network, and the other addresses would each wait out the same timeout.
    if (code == 22) return error.HttpError;
    if (status != 0 or body == null or meta == null) return error.FetchFailed;
    return .{ .body = body.?, .meta = meta.? };
}

/// Loads the Markdown for a URL: the page itself if it offers Markdown, or else where sites keep it.
pub fn get(gpa: std.mem.Allocator, url: []const u8) Error!Page {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var got_html = false;
    const others = try alternatives(arena.allocator(), url);
    for (0..others.len + 1) |i| {
        const r = request(gpa, if (i == 0) url else others[i - 1]) catch |e| switch (e) {
            error.HttpError => continue,
            else => return e,
        };
        defer gpa.free(r.meta);
        var lines = std.mem.splitScalar(u8, r.meta, '\n');
        const final = lines.next() orelse "";
        const content_type = lines.next() orelse "";
        if (!isUrl(final) or !isMarkdownReply(content_type, r.body, final)) {
            gpa.free(r.body);
            got_html = true;
            continue;
        }
        errdefer gpa.free(r.body);
        return .{ .text = r.body, .url = try gpa.dupe(u8, final) };
    }
    return if (got_html) error.NotMarkdown else error.FetchFailed;
}

/// The absolute URL of a link in a page at base.
pub fn resolve(gpa: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    if (isUrl(rel)) return gpa.dupe(u8, rel);
    const page = pathOf(base);
    const scheme_end = std.mem.indexOf(u8, page, "://") orelse return gpa.dupe(u8, rel);
    if (std.mem.startsWith(u8, rel, "//")) return std.fmt.allocPrint(gpa, "{s}:{s}", .{ page[0..scheme_end], rel });
    const host_end = std.mem.indexOfScalarPos(u8, page, scheme_end + 3, '/') orelse page.len;
    const tail_at = std.mem.indexOfAny(u8, rel, "?#") orelse rel.len;
    const target = rel[0..tail_at];
    // Only a query or fragment: the same page.
    if (target.len == 0) return std.fmt.allocPrint(gpa, "{s}{s}", .{ page, rel });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var parts: std.ArrayList([]const u8) = .empty;
    if (target[0] != '/') {
        var it = std.mem.splitScalar(u8, page[host_end..], '/');
        while (it.next()) |p| try parts.append(a, p);
        _ = parts.pop(); // the page's own name
    }
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 1) _ = parts.pop();
        } else if (!std.mem.eql(u8, p, ".")) {
            try parts.append(a, p);
        }
    }
    const path = try std.mem.join(a, "/", parts.items);
    const lead: []const u8 = if (path.len > 0 and path[0] == '/') "" else "/";
    return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ page[0..host_end], lead, path, rel[tail_at..] });
}

const testing = std.testing;

fn expectAlternatives(url: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try alternatives(arena.allocator(), url);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "a page without Markdown has somewhere else to look" {
    try expectAlternatives("https://a.io/docs/page", &.{ "https://a.io/docs/page.md", "https://a.io/docs/page/index.html.md" });
    try expectAlternatives("https://a.io/docs/page?x=1#y", &.{ "https://a.io/docs/page.md", "https://a.io/docs/page/index.html.md" });
    try expectAlternatives("https://a.io/docs/", &.{ "https://a.io/docs/index.md", "https://a.io/docs/index.html.md" });
    try expectAlternatives("https://a.io", &.{ "https://a.io/index.md", "https://a.io/index.html.md" });
    try expectAlternatives("https://a.io/page.html", &.{"https://a.io/page.html.md"});
    try expectAlternatives("https://a.io/page.md", &.{});
    try expectAlternatives("https://a.io/logo.png", &.{});
}

test "only Markdown counts as an answer" {
    try testing.expect(isMarkdownReply("text/markdown; charset=utf-8", "# Hi", "https://a.io/x"));
    try testing.expect(isMarkdownReply("text/plain", "# Hi", "https://a.io/x"));
    try testing.expect(isMarkdownReply("application/octet-stream", "# Hi", "https://a.io/x.md"));
    try testing.expect(!isMarkdownReply("text/html", "<!doctype html><p>", "https://a.io/x"));
    try testing.expect(!isMarkdownReply("text/html", "<p>hi", "https://a.io/x.md"));
    // Servers mislabel error pages and single-page apps.
    try testing.expect(!isMarkdownReply("text/plain", "  <!DOCTYPE html><p>", "https://a.io/x.md"));
    try testing.expect(!isMarkdownReply("application/json", "{}", "https://a.io/x"));
}

fn expectResolve(base: []const u8, rel: []const u8, want: []const u8) !void {
    const got = try resolve(testing.allocator, base, rel);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "links resolve against the page, and never above the site" {
    try expectResolve("https://a.io/docs/page.md", "other.md", "https://a.io/docs/other.md");
    try expectResolve("https://a.io/docs/page.md", "./other.md", "https://a.io/docs/other.md");
    try expectResolve("https://a.io/docs/page.md", "../up.md", "https://a.io/up.md");
    try expectResolve("https://a.io/docs/page.md", "../../../../etc/passwd", "https://a.io/etc/passwd");
    try expectResolve("https://a.io/docs/page.md", "/root.md#top", "https://a.io/root.md#top");
    try expectResolve("https://a.io/docs/page.md?v=1", "b.md?q=2", "https://a.io/docs/b.md?q=2");
    try expectResolve("https://a.io", "b.md", "https://a.io/b.md");
    try expectResolve("https://a.io/docs/page.md?v=1", "?p=2", "https://a.io/docs/page.md?p=2");
    try expectResolve("https://a.io/docs/", "b.md", "https://a.io/docs/b.md");
    try expectResolve("https://a.io/x.md", "//b.io/y.md", "https://b.io/y.md");
    try expectResolve("https://a.io/x.md", "https://b.io/y.md", "https://b.io/y.md");
}

test "tabs are named after the page, or the site" {
    try testing.expectEqualStrings("page.md", nameOf("https://a.io/docs/page.md?x=1"));
    try testing.expectEqualStrings("docs", nameOf("https://a.io/docs/"));
    try testing.expectEqualStrings("a.io", nameOf("https://a.io/"));
}
