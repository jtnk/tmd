//! Raster backend: draw a laid-out Graph to an RGBA canvas and encode a PNG.
//! Shapes use signed-distance-field coverage for anti-aliasing (no supersample);
//! text is rasterised by stb_truetype. The font is passed in as bytes so the
//! caller owns that choice — standalone merz embeds one, tmd can feed its own.
const std = @import("std");
const model = @import("model.zig");
const layout = @import("layout.zig");

const ctt = @import("ctt");

extern fn merz_encode_png(rgba: [*]const u8, w: c_int, h: c_int, out_len: *c_int) ?[*]u8;
extern fn merz_free(p: ?*anyopaque) void;

pub const Error = error{ BadFont, EncodeFailed, TooLarge } || std.mem.Allocator.Error;

/// Upper bound on the diagram canvas (~ 2500x1600). A diagram larger than this isn't readable in
/// a terminal anyway, and the cap keeps a pathological graph from allocating a huge canvas.
const max_pixels: usize = 4_000_000;

const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    fn hex(v: u32) Color {
        return .{
            .r = @floatFromInt((v >> 16) & 0xff),
            .g = @floatFromInt((v >> 8) & 0xff),
            .b = @floatFromInt(v & 0xff),
        };
    }
};

const bg = Color.hex(0xffffff);
const node_fill = Color.hex(0xECECFF);
const node_stroke = Color.hex(0x9370DB);
const edge_stroke = Color.hex(0x334155);
const text_fill = Color.hex(0x1e293b);

const font_px: f32 = 14.0;
const label_px: f32 = 12.0;
const stroke_w: f32 = 1.5;
const thick_w: f32 = 3.0;
const arrow_len: f32 = 11.0;
const arrow_half: f32 = 5.0;

const Canvas = struct {
    w: usize,
    h: usize,
    px: []f32, // RGB, 3 per pixel
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, w: usize, h: usize, fill: Color) !Canvas {
        const px = try gpa.alloc(f32, w * h * 3);
        var i: usize = 0;
        while (i < px.len) : (i += 3) {
            px[i] = fill.r;
            px[i + 1] = fill.g;
            px[i + 2] = fill.b;
        }
        return .{ .w = w, .h = h, .px = px, .gpa = gpa };
    }

    fn deinit(self: *Canvas) void {
        self.gpa.free(self.px);
    }

    /// Alpha-composite `c` over the pixel at (x,y) with coverage `a` in [0,1].
    fn cover(self: *Canvas, x: i64, y: i64, c: Color, a: f32) void {
        if (a <= 0) return;
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const i = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 3;
        const ca = @min(a, 1.0);
        self.px[i] = self.px[i] * (1 - ca) + c.r * ca;
        self.px[i + 1] = self.px[i + 1] * (1 - ca) + c.g * ca;
        self.px[i + 2] = self.px[i + 2] * (1 - ca) + c.b * ca;
    }

    /// Pack to tight RGBA bytes (opaque).
    fn toRgba(self: *Canvas, gpa: std.mem.Allocator) ![]u8 {
        const out = try gpa.alloc(u8, self.w * self.h * 4);
        var p: usize = 0;
        var o: usize = 0;
        while (p < self.px.len) : (p += 3) {
            out[o] = toByte(self.px[p]);
            out[o + 1] = toByte(self.px[p + 1]);
            out[o + 2] = toByte(self.px[p + 2]);
            out[o + 3] = 255;
            o += 4;
        }
        return out;
    }
};

fn toByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 255) + 0.5);
}

/// Coverage from a signed distance (negative inside): ~1 inside, ~0 outside,
/// a one-pixel smooth ramp across the boundary.
fn coverage(d: f32) f32 {
    return std.math.clamp(0.5 - d, 0, 1);
}

pub fn renderPng(gpa: std.mem.Allocator, g: *model.Graph, bounds: layout.Bounds, font_bytes: []const u8) Error![]u8 {
    const w: usize = @intFromFloat(@ceil(bounds.w));
    const h: usize = @intFromFloat(@ceil(bounds.h));
    if (w == 0 or h == 0 or w > 100_000 or h > 100_000 or w * h > max_pixels) return Error.TooLarge;

    var font: ctt.stbtt_fontinfo = undefined;
    const off = ctt.stbtt_GetFontOffsetForIndex(font_bytes.ptr, 0);
    if (ctt.stbtt_InitFont(&font, font_bytes.ptr, off) == 0) return Error.BadFont;

    var canvas = try Canvas.init(gpa, w, h, bg);
    defer canvas.deinit();

    for (g.edges.items) |e| drawEdge(&canvas, &font, g, e);
    for (g.nodes.items) |n| drawNode(&canvas, &font, n);

    const rgba = try canvas.toRgba(gpa);
    defer gpa.free(rgba);

    var len: c_int = 0;
    const p = merz_encode_png(rgba.ptr, @intCast(w), @intCast(h), &len) orelse return Error.EncodeFailed;
    defer merz_free(p);
    return gpa.dupe(u8, p[0..@intCast(len)]);
}

// ------------------------------------------------------------------ shapes

fn drawNode(canvas: *Canvas, font: *ctt.stbtt_fontinfo, n: model.Node) void {
    switch (n.shape) {
        .rect, .subroutine, .cylinder => roundRect(canvas, n.x, n.y, n.w, n.h, 4),
        .round => roundRect(canvas, n.x, n.y, n.w, n.h, 10),
        .stadium => roundRect(canvas, n.x, n.y, n.w, n.h, n.h / 2),
        .circle => ellipse(canvas, n.x, n.y, n.w / 2, n.h / 2),
        .diamond => {
            var pts = [_]P{
                .{ .x = n.x, .y = n.y - n.h / 2 },
                .{ .x = n.x + n.w / 2, .y = n.y },
                .{ .x = n.x, .y = n.y + n.h / 2 },
                .{ .x = n.x - n.w / 2, .y = n.y },
            };
            polygon(canvas, &pts);
        },
        .hexagon, .asymmetric => {
            const c = n.h / 2;
            const x = n.x - n.w / 2;
            const y = n.y - n.h / 2;
            var pts = [_]P{
                .{ .x = x + c, .y = y },
                .{ .x = x + n.w - c, .y = y },
                .{ .x = x + n.w, .y = n.y },
                .{ .x = x + n.w - c, .y = y + n.h },
                .{ .x = x + c, .y = y + n.h },
                .{ .x = x, .y = n.y },
            };
            polygon(canvas, &pts);
        },
    }
    if (n.shape == .subroutine) {
        const x = n.x - n.w / 2;
        capsule(canvas, x + 6, n.y - n.h / 2, x + 6, n.y + n.h / 2, stroke_w / 2, node_stroke, .solid);
        capsule(canvas, x + n.w - 6, n.y - n.h / 2, x + n.w - 6, n.y + n.h / 2, stroke_w / 2, node_stroke, .solid);
    }
    drawText(canvas, font, n.label, n.x, n.y, font_px, text_fill);
}

fn bbox(canvas: *Canvas, cx: f32, cy: f32, hw: f32, hh: f32) [4]i64 {
    const pad: f32 = 2;
    return .{
        @max(0, @as(i64, @intFromFloat(@floor(cx - hw - pad)))),
        @max(0, @as(i64, @intFromFloat(@floor(cy - hh - pad)))),
        @min(@as(i64, @intCast(canvas.w)), @as(i64, @intFromFloat(@ceil(cx + hw + pad)))),
        @min(@as(i64, @intCast(canvas.h)), @as(i64, @intFromFloat(@ceil(cy + hh + pad)))),
    };
}

fn roundRect(canvas: *Canvas, cx: f32, cy: f32, w: f32, h: f32, r: f32) void {
    const hw = w / 2;
    const hh = h / 2;
    const b = bbox(canvas, cx, cy, hw, hh);
    var y = b[1];
    while (y < b[3]) : (y += 1) {
        var x = b[0];
        while (x < b[2]) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = sdRoundRect(px, py, cx, cy, hw, hh, r);
            canvas.cover(x, y, node_fill, coverage(d));
            canvas.cover(x, y, node_stroke, coverage(@abs(d) - stroke_w / 2));
        }
    }
}

fn ellipse(canvas: *Canvas, cx: f32, cy: f32, rx: f32, ry: f32) void {
    const b = bbox(canvas, cx, cy, rx, ry);
    var y = b[1];
    while (y < b[3]) : (y += 1) {
        var x = b[0];
        while (x < b[2]) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = sdEllipse(px, py, cx, cy, rx, ry);
            canvas.cover(x, y, node_fill, coverage(d));
            canvas.cover(x, y, node_stroke, coverage(@abs(d) - stroke_w / 2));
        }
    }
}

const P = struct { x: f32, y: f32 };

fn polygon(canvas: *Canvas, pts: []const P) void {
    var minx: f32 = pts[0].x;
    var miny: f32 = pts[0].y;
    var maxx: f32 = pts[0].x;
    var maxy: f32 = pts[0].y;
    for (pts) |p| {
        minx = @min(minx, p.x);
        miny = @min(miny, p.y);
        maxx = @max(maxx, p.x);
        maxy = @max(maxy, p.y);
    }
    const cx = (minx + maxx) / 2;
    const cy = (miny + maxy) / 2;
    const b = bbox(canvas, cx, cy, (maxx - minx) / 2, (maxy - miny) / 2);
    var y = b[1];
    while (y < b[3]) : (y += 1) {
        var x = b[0];
        while (x < b[2]) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = sdPolygon(pts, px, py);
            canvas.cover(x, y, node_fill, coverage(d));
            canvas.cover(x, y, node_stroke, coverage(@abs(d) - stroke_w / 2));
        }
    }
}

// ------------------------------------------------------------------ edges

fn drawEdge(canvas: *Canvas, font: *ctt.stbtt_fontinfo, g: *model.Graph, e: model.Edge) void {
    const a = g.nodes.items[e.from];
    const b = g.nodes.items[e.to];
    const p0 = borderPoint(a, b.x, b.y);
    const p1 = borderPoint(b, a.x, a.y);

    const hw: f32 = if (e.style == .thick) thick_w / 2 else stroke_w / 2;

    // Stop the line at the base of the arrowhead so it doesn't poke through.
    var end = p1;
    if (e.arrow) {
        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len > arrow_len) {
            end = .{ .x = p1.x - dx / len * arrow_len, .y = p1.y - dy / len * arrow_len };
        }
    }

    capsule(canvas, p0.x, p0.y, end.x, end.y, hw, edge_stroke, e.style);
    if (e.arrow) arrowhead(canvas, p0, p1);

    if (e.label.len > 0) {
        const mx = (p0.x + p1.x) / 2;
        const my = (p0.y + p1.y) / 2;
        // A soft background pad so the label reads over the line.
        roundRectColor(canvas, mx, my, @as(f32, @floatFromInt(labelWidth(font, e.label, label_px))) + 8, 16, 3, bg, 0.92);
        drawText(canvas, font, e.label, mx, my, label_px, text_fill);
    }
}

fn capsule(canvas: *Canvas, ax: f32, ay: f32, bx: f32, by: f32, hw: f32, color: Color, style: model.EdgeStyle) void {
    if (style == .dotted) {
        const dx = bx - ax;
        const dy = by - ay;
        const len = @sqrt(dx * dx + dy * dy);
        if (len == 0) return;
        const ux = dx / len;
        const uy = dy / len;
        const dash: f32 = 2.5;
        const gap: f32 = 3.0;
        var s: f32 = 0;
        while (s < len) : (s += dash + gap) {
            const e = @min(s + dash, len);
            segCapsule(canvas, ax + ux * s, ay + uy * s, ax + ux * e, ay + uy * e, hw, color);
        }
        return;
    }
    segCapsule(canvas, ax, ay, bx, by, hw, color);
}

fn segCapsule(canvas: *Canvas, ax: f32, ay: f32, bx: f32, by: f32, hw: f32, color: Color) void {
    const minx = @min(ax, bx) - hw - 2;
    const miny = @min(ay, by) - hw - 2;
    const maxx = @max(ax, bx) + hw + 2;
    const maxy = @max(ay, by) + hw + 2;
    const x0 = @max(0, @as(i64, @intFromFloat(@floor(minx))));
    const y0 = @max(0, @as(i64, @intFromFloat(@floor(miny))));
    const x1 = @min(@as(i64, @intCast(canvas.w)), @as(i64, @intFromFloat(@ceil(maxx))));
    const y1 = @min(@as(i64, @intCast(canvas.h)), @as(i64, @intFromFloat(@ceil(maxy))));
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = sdSegment(px, py, ax, ay, bx, by) - hw;
            canvas.cover(x, y, color, coverage(d));
        }
    }
}

fn arrowhead(canvas: *Canvas, from: P, tip: P) void {
    const dx = tip.x - from.x;
    const dy = tip.y - from.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const ux = dx / len;
    const uy = dy / len;
    const px = -uy; // perpendicular
    const py = ux;
    const base_x = tip.x - ux * arrow_len;
    const base_y = tip.y - uy * arrow_len;
    var pts = [_]P{
        .{ .x = tip.x, .y = tip.y },
        .{ .x = base_x + px * arrow_half, .y = base_y + py * arrow_half },
        .{ .x = base_x - px * arrow_half, .y = base_y - py * arrow_half },
    };
    fillPolyColor(canvas, &pts, edge_stroke);
}

fn roundRectColor(canvas: *Canvas, cx: f32, cy: f32, w: f32, h: f32, r: f32, color: Color, alpha: f32) void {
    const hw = w / 2;
    const hh = h / 2;
    const b = bbox(canvas, cx, cy, hw, hh);
    var y = b[1];
    while (y < b[3]) : (y += 1) {
        var x = b[0];
        while (x < b[2]) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = sdRoundRect(px, py, cx, cy, hw, hh, r);
            canvas.cover(x, y, color, coverage(d) * alpha);
        }
    }
}

fn fillPolyColor(canvas: *Canvas, pts: []const P, color: Color) void {
    var minx: f32 = pts[0].x;
    var miny: f32 = pts[0].y;
    var maxx: f32 = pts[0].x;
    var maxy: f32 = pts[0].y;
    for (pts) |p| {
        minx = @min(minx, p.x);
        miny = @min(miny, p.y);
        maxx = @max(maxx, p.x);
        maxy = @max(maxy, p.y);
    }
    const x0 = @max(0, @as(i64, @intFromFloat(@floor(minx - 2))));
    const y0 = @max(0, @as(i64, @intFromFloat(@floor(miny - 2))));
    const x1 = @min(@as(i64, @intCast(canvas.w)), @as(i64, @intFromFloat(@ceil(maxx + 2))));
    const y1 = @min(@as(i64, @intCast(canvas.h)), @as(i64, @intFromFloat(@ceil(maxy + 2))));
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = sdPolygon(pts, px, py);
            canvas.cover(x, y, color, coverage(d));
        }
    }
}

// ------------------------------------------------------------------ text (stb_truetype)

/// Iterates codepoints, substituting U+FFFD for any invalid byte sequence. Labels come straight
/// from the diagram source, which may not be valid UTF-8 (a hostile or mis-encoded document), so
/// decoding must never fail the way std.unicode's iterator does.
const Codepoints = struct {
    bytes: []const u8,
    i: usize = 0,
    fn next(self: *Codepoints) ?u21 {
        if (self.i >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + len > self.bytes.len) {
            self.i += 1;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.i .. self.i + len]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        self.i += len;
        return cp;
    }
};

fn labelWidth(font: *ctt.stbtt_fontinfo, text: []const u8, px: f32) i64 {
    const scale = ctt.stbtt_ScaleForPixelHeight(font, px);
    var total: f32 = 0;
    var it = Codepoints{ .bytes = text };
    while (it.next()) |cp| {
        var adv: c_int = 0;
        var lsb: c_int = 0;
        ctt.stbtt_GetCodepointHMetrics(font, @intCast(cp), &adv, &lsb);
        total += @as(f32, @floatFromInt(adv)) * scale;
    }
    return @intFromFloat(total);
}

fn drawText(canvas: *Canvas, font: *ctt.stbtt_fontinfo, text: []const u8, cx: f32, cy: f32, px: f32, color: Color) void {
    const scale = ctt.stbtt_ScaleForPixelHeight(font, px);

    var ascent: c_int = 0;
    var descent: c_int = 0;
    var linegap: c_int = 0;
    ctt.stbtt_GetFontVMetrics(font, &ascent, &descent, &linegap);
    const asc = @as(f32, @floatFromInt(ascent)) * scale;
    const desc = @as(f32, @floatFromInt(descent)) * scale; // negative
    const text_h = asc - desc;

    const width: f32 = @floatFromInt(labelWidth(font, text, px));
    var penx = cx - width / 2;
    const baseline = cy - text_h / 2 + asc;

    var it = Codepoints{ .bytes = text };
    while (it.next()) |cp| {
        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        ctt.stbtt_GetCodepointBitmapBox(font, @intCast(cp), scale, scale, &ix0, &iy0, &ix1, &iy1);
        const gw: usize = @intCast(ix1 - ix0);
        const gh: usize = @intCast(iy1 - iy0);
        if (gw > 0 and gh > 0) {
            const buf = canvas.gpa.alloc(u8, gw * gh) catch return;
            defer canvas.gpa.free(buf);
            ctt.stbtt_MakeCodepointBitmap(font, buf.ptr, @intCast(gw), @intCast(gh), @intCast(gw), scale, scale, @intCast(cp));
            const gx: i64 = @as(i64, @intFromFloat(@round(penx))) + ix0;
            const gy: i64 = @as(i64, @intFromFloat(@round(baseline))) + iy0;
            var j: usize = 0;
            while (j < gh) : (j += 1) {
                var i: usize = 0;
                while (i < gw) : (i += 1) {
                    const a = @as(f32, @floatFromInt(buf[j * gw + i])) / 255.0;
                    canvas.cover(gx + @as(i64, @intCast(i)), gy + @as(i64, @intCast(j)), color, a);
                }
            }
        }
        var adv: c_int = 0;
        var lsb: c_int = 0;
        ctt.stbtt_GetCodepointHMetrics(font, @intCast(cp), &adv, &lsb);
        penx += @as(f32, @floatFromInt(adv)) * scale;
    }
}

// ------------------------------------------------------------------ geometry

fn borderPoint(n: model.Node, tx: f32, ty: f32) P {
    const dx = tx - n.x;
    const dy = ty - n.y;
    if (dx == 0 and dy == 0) return .{ .x = n.x, .y = n.y };
    const hw = n.w / 2;
    const hh = n.h / 2;
    var scale: f32 = std.math.inf(f32);
    if (dx != 0) scale = @min(scale, hw / @abs(dx));
    if (dy != 0) scale = @min(scale, hh / @abs(dy));
    return .{ .x = n.x + dx * scale, .y = n.y + dy * scale };
}

fn sdRoundRect(px: f32, py: f32, cx: f32, cy: f32, hw: f32, hh: f32, r: f32) f32 {
    const qx = @abs(px - cx) - hw + r;
    const qy = @abs(py - cy) - hh + r;
    const ax = @max(qx, 0);
    const ay = @max(qy, 0);
    return @sqrt(ax * ax + ay * ay) + @min(@max(qx, qy), 0) - r;
}

fn sdEllipse(px: f32, py: f32, cx: f32, cy: f32, rx: f32, ry: f32) f32 {
    const nx = (px - cx) / rx;
    const ny = (py - cy) / ry;
    const k = @sqrt(nx * nx + ny * ny);
    return (k - 1.0) * @min(rx, ry);
}

fn sdSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const pax = px - ax;
    const pay = py - ay;
    const bax = bx - ax;
    const bay = by - ay;
    const denom = bax * bax + bay * bay;
    const h = if (denom == 0) 0 else std.math.clamp((pax * bax + pay * bay) / denom, 0, 1);
    const dx = pax - bax * h;
    const dy = pay - bay * h;
    return @sqrt(dx * dx + dy * dy);
}

/// Signed distance to a polygon boundary, negative inside (even-odd rule).
fn sdPolygon(pts: []const P, px: f32, py: f32) f32 {
    var d: f32 = std.math.inf(f32);
    var inside = false;
    var j: usize = pts.len - 1;
    for (pts, 0..) |p, i| {
        d = @min(d, sdSegment(px, py, p.x, p.y, pts[j].x, pts[j].y));
        const cond = (p.y > py) != (pts[j].y > py);
        if (cond) {
            const t = (py - p.y) / (pts[j].y - p.y);
            if (px < p.x + t * (pts[j].x - p.x)) inside = !inside;
        }
        j = i;
    }
    return if (inside) -d else d;
}

