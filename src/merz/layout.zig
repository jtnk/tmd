//! Turn a parsed Graph into positioned geometry. A layered (Sugiyama-style)
//! layout: assign each node a rank by longest path from the roots, order nodes
//! within a rank by first appearance, then hand out coordinates along and across
//! the rank axis. The rank axis follows the graph's direction.
//!
//! This is the honest-but-simple version: no crossing minimisation yet, straight
//! edges. It produces recognisable diagrams; prettier routing is a later pass.
const std = @import("std");
const model = @import("model.zig");
const Graph = model.Graph;
const Dir = model.Dir;

pub const Size = struct { w: f32, h: f32 };

const char_w: f32 = 8.0; // approx advance of the 14px label font
const pad_x: f32 = 14.0;
const min_w: f32 = 44.0;
const node_h: f32 = 38.0;
const rank_gap: f32 = 56.0; // between ranks (the flow direction)
const node_gap: f32 = 32.0; // between siblings within a rank
const margin: f32 = 16.0;

/// The overall drawing size, after layout has placed every node.
pub const Bounds = struct { w: f32, h: f32 };

pub fn layout(gpa: std.mem.Allocator, g: *Graph) !Bounds {
    if (g.nodes.items.len == 0) return .{ .w = margin * 2, .h = margin * 2 };

    try assignRanks(gpa, g);
    sizeNodes(g);
    return place(gpa, g);
}

fn assignRanks(gpa: std.mem.Allocator, g: *Graph) !void {
    const n = g.nodes.items.len;
    const ne = g.edges.items.len;

    // Back edges (edges that close a cycle) would make longest-path ranking spin
    // up to the iteration cap, burying a node far from its real rank. Find them
    // with a DFS and leave them out of ranking; they still draw in full.
    const ignored = try gpa.alloc(bool, ne);
    defer gpa.free(ignored);
    @memset(ignored, false);
    const state = try gpa.alloc(u8, n); // 0 unvisited, 1 on-stack, 2 done
    defer gpa.free(state);
    @memset(state, 0);

    var ctx = Dfs{ .g = g, .state = state, .ignored = ignored };
    for (0..n) |s| {
        if (state[s] == 0) ctx.visit(@intCast(s));
    }

    const rank = try gpa.alloc(i32, n);
    defer gpa.free(rank);
    @memset(rank, 0);

    // Longest path over the remaining DAG.
    var pass: usize = 0;
    while (pass < n) : (pass += 1) {
        var changed = false;
        for (g.edges.items, 0..) |e, ei| {
            if (ignored[ei] or e.from == e.to) continue;
            if (rank[e.to] < rank[e.from] + 1) {
                rank[e.to] = rank[e.from] + 1;
                changed = true;
            }
        }
        if (!changed) break;
    }

    for (g.nodes.items, 0..) |*node, idx| node.rank = rank[idx];
}

const Dfs = struct {
    g: *Graph,
    state: []u8,
    ignored: []bool,

    fn visit(self: *Dfs, u: u32) void {
        self.state[u] = 1;
        for (self.g.edges.items, 0..) |e, ei| {
            if (e.from != u or e.from == e.to) continue;
            switch (self.state[e.to]) {
                1 => self.ignored[ei] = true, // back edge: closes a cycle
                0 => self.visit(e.to),
                else => {},
            }
        }
        self.state[u] = 2;
    }
};

fn sizeNodes(g: *Graph) void {
    for (g.nodes.items) |*node| {
        const chars: f32 = @floatFromInt(labelCols(node.label));
        var w = @max(min_w, chars * char_w + 2 * pad_x);
        var h = node_h;
        switch (node.shape) {
            .circle => {
                const d = @max(w, h * 1.6);
                w = d;
                h = d;
            },
            .diamond => {
                w *= 1.3;
                h *= 1.5;
            },
            .hexagon => w += 2 * pad_x,
            .stadium, .round => w += pad_x,
            else => {},
        }
        node.w = w;
        node.h = h;
    }
}

/// Display columns of a label, counting UTF-8 codepoints (ASCII-ish). Good
/// enough for sizing; wide glyphs aren't handled yet.
fn labelCols(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn place(gpa: std.mem.Allocator, g: *Graph) !Bounds {
    const n = g.nodes.items.len;

    var max_rank: i32 = 0;
    for (g.nodes.items) |node| max_rank = @max(max_rank, node.rank);
    const num_ranks: usize = @intCast(max_rank + 1);

    // Extent of each rank along the cross axis, and along the flow axis.
    const flow_size = try gpa.alloc(f32, num_ranks); // thickness of rank in flow dir
    defer gpa.free(flow_size);
    @memset(flow_size, 0);
    const cross_cursor = try gpa.alloc(f32, num_ranks);
    defer gpa.free(cross_cursor);
    @memset(cross_cursor, 0);

    const horizontal = g.dir == .lr or g.dir == .rl;

    // First pass: rank thickness (max node size along the flow axis).
    for (g.nodes.items) |node| {
        const r: usize = @intCast(node.rank);
        const along = if (horizontal) node.w else node.h;
        flow_size[r] = @max(flow_size[r], along);
    }

    // Flow-axis centre of each rank.
    const flow_center = try gpa.alloc(f32, num_ranks);
    defer gpa.free(flow_center);
    {
        var acc: f32 = margin;
        for (0..num_ranks) |r| {
            flow_center[r] = acc + flow_size[r] / 2;
            acc += flow_size[r] + rank_gap;
        }
    }

    // Second pass: lay nodes out across each rank in first-appearance order.
    var max_cross: f32 = 0;
    for (0..n) |idx| {
        const node = &g.nodes.items[idx];
        const r: usize = @intCast(node.rank);
        const across = if (horizontal) node.h else node.w;
        if (cross_cursor[r] == 0) cross_cursor[r] = margin;
        const cross_center = cross_cursor[r] + across / 2;
        cross_cursor[r] += across + node_gap;
        max_cross = @max(max_cross, cross_cursor[r] - node_gap);

        // Map (flow, cross) to (x, y) per direction.
        setPos(node, g.dir, flow_center[r], cross_center);
    }

    // Flow extent (last rank's far edge).
    const flow_extent = flow_center[num_ranks - 1] + flow_size[num_ranks - 1] / 2 + margin;
    const cross_extent = max_cross + margin;

    var bounds: Bounds = undefined;
    if (horizontal) {
        bounds = .{ .w = flow_extent, .h = cross_extent };
    } else {
        bounds = .{ .w = cross_extent, .h = flow_extent };
    }

    // BT and RL flip the flow axis so rank 0 sits at the bottom / right.
    if (g.dir == .bt or g.dir == .rl) flipFlow(g, g.dir, bounds);

    return bounds;
}

fn setPos(node: *model.Node, dir: Dir, flow: f32, cross: f32) void {
    switch (dir) {
        .td, .bt => {
            node.x = cross;
            node.y = flow;
        },
        .lr, .rl => {
            node.x = flow;
            node.y = cross;
        },
    }
}

fn flipFlow(g: *Graph, dir: Dir, b: Bounds) void {
    for (g.nodes.items) |*node| {
        switch (dir) {
            .bt => node.y = b.h - node.y,
            .rl => node.x = b.w - node.x,
            else => {},
        }
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const parse = @import("parser.zig").parse;

test "a chain ranks its nodes in order" {
    var g = try parse(testing.allocator, "flowchart TD\n A --> B --> C");
    defer g.deinit();
    _ = try layout(testing.allocator, &g);
    try testing.expectEqual(@as(i32, 0), g.nodes.items[0].rank);
    try testing.expectEqual(@as(i32, 1), g.nodes.items[1].rank);
    try testing.expectEqual(@as(i32, 2), g.nodes.items[2].rank);
    // Top-down: later ranks sit lower.
    try testing.expect(g.nodes.items[0].y < g.nodes.items[1].y);
    try testing.expect(g.nodes.items[1].y < g.nodes.items[2].y);
}

test "left-right flows along x" {
    var g = try parse(testing.allocator, "flowchart LR\n A --> B");
    defer g.deinit();
    _ = try layout(testing.allocator, &g);
    try testing.expect(g.nodes.items[0].x < g.nodes.items[1].x);
}

test "a back edge does not inflate ranks" {
    // A->B->C with a loop C->B. B must stay rank 1, not get pushed down.
    var g = try parse(testing.allocator, "flowchart TD\n A --> B --> C\n C --> B");
    defer g.deinit();
    _ = try layout(testing.allocator, &g);
    try testing.expectEqual(@as(i32, 0), g.nodes.items[0].rank);
    try testing.expectEqual(@as(i32, 1), g.nodes.items[1].rank);
    try testing.expectEqual(@as(i32, 2), g.nodes.items[2].rank);
}

test "a diamond splits into two ranks below" {
    var g = try parse(testing.allocator, "flowchart TD\n A --> B\n A --> C");
    defer g.deinit();
    const b = try layout(testing.allocator, &g);
    try testing.expect(b.w > 0 and b.h > 0);
    try testing.expectEqual(@as(i32, 1), g.nodes.items[1].rank);
    try testing.expectEqual(@as(i32, 1), g.nodes.items[2].rank);
    // The two children share a rank, so they sit side by side.
    try testing.expect(g.nodes.items[1].x != g.nodes.items[2].x);
    try testing.expectEqual(g.nodes.items[1].y, g.nodes.items[2].y);
}
