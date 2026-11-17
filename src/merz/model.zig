//! The graph a Mermaid flowchart describes: nodes, the edges between them, and
//! the slots layout fills in. The parser builds one of these; layout positions
//! it; a renderer draws it. Nothing here knows about Mermaid syntax or SVG.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Which way ranks flow. TD/TB are the same thing (top-down).
pub const Dir = enum { td, bt, lr, rl };

pub const Shape = enum {
    rect, // [label]
    round, // (label)
    stadium, // ([label])
    circle, // ((label))
    diamond, // {label}
    hexagon, // {{label}}
    subroutine, // [[label]]
    cylinder, // [(label)]
    asymmetric, // >label]
};

pub const EdgeStyle = enum { solid, dotted, thick };

/// Caps that keep a hostile or pathological diagram from blowing up layout and the canvas.
/// Past these, building the graph fails with error.TooComplex and the caller shows the block
/// as source instead of a diagram. Labels are truncated rather than rejected.
pub const max_nodes = 400;
pub const max_edges = 800;
pub const max_label = 128;

pub const Error = error{TooComplex};

/// Truncate a label to max_label bytes, backing off to a UTF-8 boundary so a multi-byte
/// character isn't split (the rasteriser tolerates it either way).
fn clampLabel(label: []const u8) []const u8 {
    if (label.len <= max_label) return label;
    var end: usize = max_label;
    while (end > 0 and label[end] & 0xC0 == 0x80) end -= 1;
    return label[0..end];
}

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape = .rect,

    // Filled in by layout. Coordinates are the node's centre.
    rank: i32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Edge = struct {
    from: u32, // index into Graph.nodes
    to: u32,
    label: []const u8 = "",
    style: EdgeStyle = .solid,
    arrow: bool = true,
};

pub const Graph = struct {
    gpa: Allocator,
    dir: Dir = .td,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    /// node id -> index into nodes, so repeated mentions resolve to one node.
    index: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(gpa: Allocator) Graph {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |n| {
            self.gpa.free(n.id);
            self.gpa.free(n.label);
        }
        for (self.edges.items) |e| {
            if (e.label.len > 0) self.gpa.free(e.label);
        }
        self.nodes.deinit(self.gpa);
        self.edges.deinit(self.gpa);
        self.index.deinit(self.gpa);
    }

    /// Resolve an id to a node index, creating the node the first time. A later
    /// mention that carries its own shape/label (explicit) updates the node, so
    /// `A --> B` then `A[Start]` still names A once, now labelled.
    pub fn intern(self: *Graph, id: []const u8, label: []const u8, shape: Shape, explicit: bool) !u32 {
        if (self.index.get(id)) |idx| {
            if (explicit) {
                const n = &self.nodes.items[idx];
                const new_label = try self.gpa.dupe(u8, clampLabel(label));
                self.gpa.free(n.label);
                n.label = new_label;
                n.shape = shape;
            }
            return idx;
        }
        if (self.nodes.items.len >= max_nodes) return Error.TooComplex;
        const idx: u32 = @intCast(self.nodes.items.len);
        const id_owned = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(id_owned);
        const label_owned = try self.gpa.dupe(u8, clampLabel(label));
        errdefer self.gpa.free(label_owned);
        try self.nodes.append(self.gpa, .{ .id = id_owned, .label = label_owned, .shape = shape });
        try self.index.put(self.gpa, id_owned, idx);
        return idx;
    }

    pub fn addEdge(self: *Graph, from: u32, to: u32, label: []const u8, style: EdgeStyle, arrow: bool) !void {
        if (self.edges.items.len >= max_edges) return Error.TooComplex;
        const label_owned = if (label.len > 0) try self.gpa.dupe(u8, clampLabel(label)) else "";
        try self.edges.append(self.gpa, .{
            .from = from,
            .to = to,
            .label = label_owned,
            .style = style,
            .arrow = arrow,
        });
    }
};
