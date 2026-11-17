//! A hand-written parser for the flowchart subset of Mermaid: `graph`/`flowchart`
//! with a direction, nodes with the common shape brackets, and edges (solid,
//! dotted, thick) with labels in either the `-->|text|` or `-- text -->` form.
//!
//! What it deliberately skips for now: subgraphs (the grouping is ignored but the
//! inner nodes/edges still parse), classDef/style/click/linkStyle lines, and the
//! other diagram types (sequence, class, state, …) — those report an error.
const std = @import("std");
const model = @import("model.zig");
const Graph = model.Graph;
const Shape = model.Shape;
const EdgeStyle = model.EdgeStyle;

pub const Error = error{ UnsupportedDiagram, EmptyInput } || model.Error || std.mem.Allocator.Error;

const ws = " \t\r\n";

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, ws);
}

/// Parse a whole document into a Graph. Caller owns the result and must deinit it.
pub fn parse(gpa: std.mem.Allocator, src: []const u8) Error!Graph {
    var g = Graph.init(gpa);
    errdefer g.deinit();

    var header_done = false;
    var saw_any = false;

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (std.mem.indexOf(u8, line, "%%")) |p| line = line[0..p]; // strip comment
        line = trim(line);
        if (line.len == 0) continue;

        var stmts = std.mem.splitScalar(u8, line, ';');
        while (stmts.next()) |st_raw| {
            const st = trim(st_raw);
            if (st.len == 0) continue;

            if (!header_done) {
                header_done = true;
                switch (classifyHeader(st)) {
                    .flowchart => |dir| {
                        g.dir = dir;
                        saw_any = true;
                        continue;
                    },
                    .unsupported => return Error.UnsupportedDiagram,
                    .none => {}, // no header line; default .td, fall through as a statement
                }
            }

            saw_any = true;
            try parseStatement(&g, st);
        }
    }

    if (!saw_any) return Error.EmptyInput;
    return g;
}

const Header = union(enum) { flowchart: model.Dir, unsupported, none };

fn classifyHeader(st: []const u8) Header {
    var it = std.mem.tokenizeAny(u8, st, ws);
    const first = it.next() orelse return .none;
    if (std.ascii.eqlIgnoreCase(first, "graph") or std.ascii.eqlIgnoreCase(first, "flowchart")) {
        const dir_word = it.next() orelse return .{ .flowchart = .td };
        return .{ .flowchart = parseDir(dir_word) };
    }
    const unsupported = [_][]const u8{
        "sequenceDiagram", "classDiagram",  "stateDiagram", "stateDiagram-v2",
        "erDiagram",       "gantt",         "pie",          "journey",
        "gitGraph",        "mindmap",       "timeline",     "quadrantChart",
        "requirementDiagram", "C4Context",  "sankey",       "xychart-beta",
    };
    for (unsupported) |u| {
        if (std.ascii.eqlIgnoreCase(first, u)) return .unsupported;
    }
    return .none;
}

fn parseDir(w: []const u8) model.Dir {
    if (std.ascii.eqlIgnoreCase(w, "TD") or std.ascii.eqlIgnoreCase(w, "TB")) return .td;
    if (std.ascii.eqlIgnoreCase(w, "BT")) return .bt;
    if (std.ascii.eqlIgnoreCase(w, "LR")) return .lr;
    if (std.ascii.eqlIgnoreCase(w, "RL")) return .rl;
    return .td;
}

const skip_keywords = [_][]const u8{
    "subgraph", "end", "classDef", "class", "style", "linkStyle", "click", "direction",
};

const NodeSpec = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape,
    explicit: bool,
};

fn parseStatement(g: *Graph, s: []const u8) Error!void {
    // Skip grouping / styling lines; their nodes (if any) show up elsewhere.
    var kw = std.mem.tokenizeAny(u8, s, ws);
    if (kw.next()) |first| {
        for (skip_keywords) |k| {
            if (std.ascii.eqlIgnoreCase(first, k)) return;
        }
    }

    var i: usize = 0;
    const first_node = parseNode(s, &i) orelse return;
    var cur = try g.intern(first_node.id, first_node.label, first_node.shape, first_node.explicit);

    while (true) {
        const save = i;
        const edge = parseEdge(s, &i) orelse break;
        const next_node = parseNode(s, &i) orelse {
            i = save;
            break;
        };
        const next = try g.intern(next_node.id, next_node.label, next_node.shape, next_node.explicit);
        if (edge.reversed)
            try g.addEdge(next, cur, edge.label, edge.style, edge.arrow)
        else
            try g.addEdge(cur, next, edge.label, edge.style, edge.arrow);
        cur = next;
    }
}

fn skipSpaces(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) i.* += 1;
}

const ShapeDelim = struct { open: []const u8, close: []const u8, shape: Shape };

// Longest openers first so `((` wins over `(`.
const shape_delims = [_]ShapeDelim{
    .{ .open = "((", .close = "))", .shape = .circle },
    .{ .open = "([", .close = "])", .shape = .stadium },
    .{ .open = "[[", .close = "]]", .shape = .subroutine },
    .{ .open = "[(", .close = ")]", .shape = .cylinder },
    .{ .open = "{{", .close = "}}", .shape = .hexagon },
    .{ .open = "[", .close = "]", .shape = .rect },
    .{ .open = "(", .close = ")", .shape = .round },
    .{ .open = "{", .close = "}", .shape = .diamond },
    .{ .open = ">", .close = "]", .shape = .asymmetric },
};

fn parseNode(s: []const u8, i: *usize) ?NodeSpec {
    skipSpaces(s, i);
    const start = i.*;
    while (i.* < s.len and (std.ascii.isAlphanumeric(s[i.*]) or s[i.*] == '_')) i.* += 1;
    if (i.* == start) return null;
    const id = s[start..i.*];

    // A shape bracket must sit flush against the id.
    if (i.* < s.len) {
        const rest = s[i.*..];
        for (shape_delims) |d| {
            if (std.mem.startsWith(u8, rest, d.open)) {
                const after_open = i.* + d.open.len;
                if (std.mem.indexOfPos(u8, s, after_open, d.close)) |close_at| {
                    const label = stripLabel(s[after_open..close_at]);
                    i.* = close_at + d.close.len;
                    return .{ .id = id, .label = label, .shape = d.shape, .explicit = true };
                }
            }
        }
    }
    return .{ .id = id, .label = id, .shape = .rect, .explicit = false };
}

fn stripLabel(raw: []const u8) []const u8 {
    var l = trim(raw);
    if (l.len >= 2 and l[0] == '"' and l[l.len - 1] == '"') l = l[1 .. l.len - 1];
    return l;
}

const EdgeSpec = struct {
    style: EdgeStyle,
    arrow: bool,
    reversed: bool,
    label: []const u8,
};

fn isLinkChar(c: u8) bool {
    return c == '-' or c == '.' or c == '=';
}

/// Parse an edge operator sitting between two nodes. Returns null if what's at
/// `i` isn't an edge. Handles: --> --- -.-> ==> === and the <-- reverse form,
/// plus labels as `-->|text|` and `-- text -->`.
fn parseEdge(s: []const u8, i: *usize) ?EdgeSpec {
    skipSpaces(s, i);
    if (i.* >= s.len) return null;

    var style: EdgeStyle = .solid;
    var reversed = false;

    // Leading reverse arrowhead: <-- , <-.- , <==
    if (s[i.*] == '<') {
        reversed = true;
        i.* += 1;
    }

    const run_start = i.*;
    while (i.* < s.len and isLinkChar(s[i.*])) : (i.* += 1) {
        if (s[i.*] == '.') style = .dotted;
        if (s[i.*] == '=') style = .thick;
    }
    if (i.* == run_start and !reversed) return null; // no dashes, not an edge
    if (i.* == run_start) return null; // a lone '<' isn't an edge

    var arrow = reversed; // a reverse edge always has its head
    var label: []const u8 = "";

    if (i.* < s.len and s[i.*] == '>') {
        arrow = true;
        i.* += 1;
        // Optional `|text|` label right after the arrow.
        if (i.* < s.len and s[i.*] == '|') {
            i.* += 1;
            const lstart = i.*;
            while (i.* < s.len and s[i.*] != '|') i.* += 1;
            label = trim(s[lstart..i.*]);
            if (i.* < s.len) i.* += 1; // closing '|'
        }
    } else {
        // No '>' yet: either an open link (---), or the `-- text -->` form where
        // the arrow is on the far side of the label. Look for the next '>'.
        if (std.mem.indexOfScalarPos(u8, s, i.*, '>')) |gt| {
            var op_start = gt;
            while (op_start > i.* and isLinkChar(s[op_start - 1])) op_start -= 1;
            if (op_start < gt) {
                // Pick up dotted/thick from the closing run too.
                for (s[op_start..gt]) |c| {
                    if (c == '.') style = .dotted;
                    if (c == '=') style = .thick;
                }
                label = trim(s[i.*..op_start]);
                arrow = true;
                i.* = gt + 1;
            }
        }
        // else: open link, no arrow, no label.
    }

    return .{ .style = style, .arrow = arrow, .reversed = reversed, .label = label };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "a simple chain parses to nodes and edges" {
    var g = try parse(testing.allocator, "flowchart TD\n A[Start] --> B{Go?} --> C((End))");
    defer g.deinit();
    try testing.expectEqual(model.Dir.td, g.dir);
    try testing.expectEqual(@as(usize, 3), g.nodes.items.len);
    try testing.expectEqual(@as(usize, 2), g.edges.items.len);
    try testing.expectEqualStrings("Start", g.nodes.items[0].label);
    try testing.expectEqual(Shape.diamond, g.nodes.items[1].shape);
    try testing.expectEqual(Shape.circle, g.nodes.items[2].shape);
}

test "edge labels parse in both forms" {
    var g = try parse(testing.allocator, "graph LR\n A -->|yes| B\n A -- no --> C");
    defer g.deinit();
    try testing.expectEqual(model.Dir.lr, g.dir);
    try testing.expectEqual(@as(usize, 2), g.edges.items.len);
    try testing.expectEqualStrings("yes", g.edges.items[0].label);
    try testing.expectEqualStrings("no", g.edges.items[1].label);
}

test "dotted and thick styles are recognised" {
    var g = try parse(testing.allocator, "graph TD\n A -.-> B\n A ==> C\n A --- D");
    defer g.deinit();
    try testing.expectEqual(EdgeStyle.dotted, g.edges.items[0].style);
    try testing.expectEqual(EdgeStyle.thick, g.edges.items[1].style);
    try testing.expectEqual(EdgeStyle.solid, g.edges.items[2].style);
    try testing.expectEqual(false, g.edges.items[2].arrow); // --- has no head
}

test "a repeated id is one node, and a later label sticks" {
    var g = try parse(testing.allocator, "graph TD\n A --> B\n A[Start]");
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), g.nodes.items.len);
    try testing.expectEqualStrings("Start", g.nodes.items[0].label);
}

test "a non-flowchart diagram is refused" {
    try testing.expectError(Error.UnsupportedDiagram, parse(testing.allocator, "sequenceDiagram\n A->>B: hi"));
}

test "a reverse arrow flips direction" {
    var g = try parse(testing.allocator, "graph TD\n A <-- B");
    defer g.deinit();
    // B --> A
    try testing.expectEqual(@as(u32, 1), g.edges.items[0].from);
    try testing.expectEqual(@as(u32, 0), g.edges.items[0].to);
}
