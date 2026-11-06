//! File access over libc, with atomic saves and text decoding.
const std = @import("std");
const c = std.c;

// vendor/decoders.c: the layout of struct stat differs by platform, so C reads it.
extern fn tm_file_mode(path: [*:0]const u8) c_int;
extern fn tm_is_regular(path: [*:0]const u8) c_int;

pub const Error = error{ NotFound, ReadFailed, WriteFailed, TooBig } || std.mem.Allocator.Error;

fn openRead(path: [*:0]const u8) Error!c.fd_t {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return error.NotFound;
    return fd;
}

pub fn readFd(gpa: std.mem.Allocator, fd: c.fd_t, max: usize) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    while (true) {
        try buf.ensureUnusedCapacity(gpa, 64 * 1024);
        const dest = buf.unusedCapacitySlice();
        const n = c.read(fd, dest.ptr, dest.len);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        buf.items.len += @intCast(n);
        if (buf.items.len > max) return error.TooBig;
    }
    return buf.toOwnedSlice(gpa);
}

pub fn read(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize) Error![]u8 {
    const fd = try openRead(path);
    defer _ = c.close(fd);
    return readFd(gpa, fd, max);
}

/// The first bytes of a file, up to buf.len.
pub fn readHead(path: [*:0]const u8, buf: []u8) Error![]u8 {
    const fd = try openRead(path);
    defer _ = c.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = c.read(fd, buf[n..].ptr, buf.len - n);
        if (r < 0) return error.ReadFailed;
        if (r == 0) break;
        n += @intCast(r);
    }
    return buf[0..n];
}

pub fn isFolder(path: [*:0]const u8) bool {
    const d = c.opendir(path) orelse return false;
    _ = c.closedir(d);
    return true;
}

/// True for an ordinary file. A link in a document could point at a device or a pipe, which reading
/// would never finish.
pub fn isFile(path: [*:0]const u8) bool {
    return tm_is_regular(path) != 0;
}

fn writeAll(fd: c.fd_t, bytes: []const u8) Error!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        i += @intCast(n);
    }
}

/// Writes through a temporary file and a rename, so a crash can't leave half a document. Symlinks
/// are followed, and the file keeps its permissions.
/// Creates a file that mustn't exist yet, readable only by this user. For names in a shared folder,
/// where a link planted under the name would otherwise be followed.
pub fn writeNew(path: [:0]const u8, bytes: []const u8) Error!void {
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.WriteFailed;
    defer _ = c.close(fd);
    try writeAll(fd, bytes);
}

pub fn writeAtomic(gpa: std.mem.Allocator, path: [:0]const u8, bytes: []const u8) Error!void {
    var real_buf: [4096]u8 = undefined;
    const real: [*:0]const u8 = c.realpath(path.ptr, &real_buf) orelse path.ptr;
    const target = std.mem.span(real);

    const existing = tm_file_mode(real);
    const mode: c.mode_t = if (existing >= 0) @intCast(existing) else 0o644;

    const tmp = try std.fmt.allocPrintSentinel(gpa, "{s}.tmd-{d}~", .{ target, c.getpid() }, 0);
    defer gpa.free(tmp);
    const fd = c.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, mode);
    if (fd < 0) return error.WriteFailed;
    errdefer _ = c.unlink(tmp.ptr);
    {
        defer _ = c.close(fd);
        try writeAll(fd, bytes);
        _ = c.fchmod(fd, mode);
        if (c.fsync(fd) != 0) return error.WriteFailed;
    }
    if (c.rename(tmp.ptr, real) != 0) return error.WriteFailed;
}

pub const Text = struct { bytes: []u8, crlf: bool };

/// Normalizes file contents for editing: UTF-8 (Latin-1 if it isn't valid), no BOM, LF line ends.
/// Looks for the \r alone, which a single byte's search does much faster than two bytes' would.
fn hasCrlf(s: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '\r')) |p| {
        if (p + 1 < s.len and s[p + 1] == '\n') return true;
        i = p + 1;
    }
    return false;
}

pub fn decode(gpa: std.mem.Allocator, raw: []u8) !Text {
    var s = raw;
    defer gpa.free(raw);
    if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) s = s[3..];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (std.unicode.utf8ValidateSlice(s)) {
        try out.appendSlice(gpa, s);
    } else {
        try out.ensureTotalCapacity(gpa, s.len * 2);
        for (s) |b| {
            if (b < 0x80) {
                out.appendAssumeCapacity(b);
            } else {
                out.appendAssumeCapacity(0xC0 | (b >> 6));
                out.appendAssumeCapacity(0x80 | (b & 0x3F));
            }
        }
    }
    const crlf = hasCrlf(out.items);
    if (crlf) {
        var w: usize = 0;
        for (out.items, 0..) |b, i| {
            if (b == '\r' and i + 1 < out.items.len and out.items[i + 1] == '\n') continue;
            out.items[w] = b;
            w += 1;
        }
        out.items.len = w;
    }
    return .{ .bytes = try out.toOwnedSlice(gpa), .crlf = crlf };
}

test "finding a Windows line ending" {
    const t = std.testing;
    for ([_][]const u8{ "\r\n", "a\r\n", "\r\nb", "a\rb\r\nc", "\r\r\n" }) |s| try t.expect(hasCrlf(s));
    for ([_][]const u8{ "", "\r", "\n", "a\r", "\n\r", "a\rb\nc", "\r\r" }) |s| try t.expect(!hasCrlf(s));
}

test "decoding" {
    const t = std.testing;
    const d = try decode(t.allocator, try t.allocator.dupe(u8, "\xEF\xBB\xBFa\r\nb"));
    defer t.allocator.free(d.bytes);
    try t.expectEqualStrings("a\nb", d.bytes);
    try t.expect(d.crlf);
    const l = try decode(t.allocator, try t.allocator.dupe(u8, "caf\xE9"));
    defer t.allocator.free(l.bytes);
    try t.expectEqualStrings("café", l.bytes);
}

test "only ordinary files count as files" {
    try std.testing.expect(isFile("build.zig"));
    try std.testing.expect(!isFile("src"));
    try std.testing.expect(!isFile("/dev/zero"));
    try std.testing.expect(!isFile("/no/such/file"));
}

test "a new file refuses to follow what's already there" {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "/tmp/tmd-new-{d}", .{c.getpid()}, 0);
    defer _ = c.unlink(path.ptr);
    _ = c.unlink(path.ptr);
    _ = c.symlink("/tmp/tmd-victim-does-not-exist", path.ptr);
    try std.testing.expectError(error.WriteFailed, writeNew(path, "x"));
    _ = c.unlink(path.ptr);
    try writeNew(path, "x");
    try std.testing.expectError(error.WriteFailed, writeNew(path, "y"));
}
