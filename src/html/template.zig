//! Comptime HTML template engine.
//!
//! Templates are parsed at compile time into an optimized render function.
//! At runtime, rendering is a straight-line sequence of buffer writes —
//! no parsing, no allocations beyond the output buffer.
//!
//! ## Template Syntax
//!
//! | Syntax                        | Description                              |
//! |-------------------------------|------------------------------------------|
//! | `{{name}}`                    | Variable — HTML-escaped                  |
//! | `{{&name}}`                   | Variable — raw / unescaped               |
//! | `{{.}}`                       | Current context value (in `#each` loops) |
//! | `{{#each field}}...{{/each}}` | Iterate over a slice field               |
//! | `{{#if field}}...{{/if}}`     | Conditional (truthy check)               |
//! | `{{#if field}}...{{else}}...{{/if}}` | Conditional with else branch      |
//!
//! ## Usage
//!
//! ```zig
//! const Template = @import("html").Template;
//!
//! // Compile template at comptime — zero runtime parsing cost.
//! const card = Template.compile(
//!     \\<div class="card">
//!     \\  <h2>{{name}}</h2>
//!     \\  {{#if active}}<span class="badge">Active</span>{{/if}}
//!     \\  <ul>
//!     \\    {{#each roles}}<li>{{.}}</li>{{/each}}
//!     \\  </ul>
//!     \\</div>
//! );
//!
//! // Render at runtime with typed data.
//! const html = try card.render(allocator, .{
//!     .name = "Alice",
//!     .active = true,
//!     .roles = &[_][]const u8{ "admin", "editor" },
//! });
//! ```
//!
//! ## htmx Integration
//!
//! Templates work naturally with htmx. Define full-page and partial
//! templates separately, then choose which to render:
//!
//! ```zig
//! const user_row = Template.compile(
//!     \\<tr hx-get="/users/{{id}}" hx-target="#detail">
//!     \\  <td>{{name}}</td><td>{{email}}</td>
//!     \\</tr>
//! );
//!
//! const user_table = Template.compile(
//!     \\<table id="users" hx-get="/users" hx-trigger="load">
//!     \\  {{#each users}}
//!     \\  <tr><td>{{name}}</td><td>{{email}}</td></tr>
//!     \\  {{/each}}
//!     \\</table>
//! );
//! ```
//!
//! ## Performance
//!
//! - **Zero runtime parsing** — template structure resolved at comptime
//! - **Type-safe** — field access verified at comptime via `@field`
//! - **Inline rendering** — `inline for` unrolls node traversal
//! - **Arena-friendly** — single output buffer, freed in bulk with request

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

// ============================================================================
// Comptime Node Types
// ============================================================================

/// A parsed template node. Only exists at comptime.
const Node = struct {
    tag: Tag,
    /// Literal text content (for `.literal`).
    literal: []const u8 = "",
    /// Field name for variable / block access.
    field_name: []const u8 = "",
    /// Child nodes (for `.each`, `.conditional`).
    children: []const Node = &.{},
    /// Else-branch children (for `.conditional`).
    else_children: []const Node = &.{},

    const Tag = enum {
        /// Raw text — written directly to output.
        literal,
        /// `{{name}}` — HTML-escaped variable.
        variable,
        /// `{{&name}}` — raw/unescaped variable.
        raw_variable,
        /// `{{.}}` — current context value (for each loops with primitives).
        this,
        /// `{{#each field}}...{{/each}}` — iteration over a slice.
        each,
        /// `{{#if field}}...{{else}}...{{/if}}` — conditional rendering.
        conditional,
    };
};

// ============================================================================
// Public API
// ============================================================================

/// Compile a template string at comptime into a renderable type.
///
/// Returns a type with a `render` method and a `renderWriter` method.
/// The template is parsed once at compile time; rendering is a simple
/// sequence of buffer writes at runtime.
///
/// Usage:
///   const Tmpl = Template.compile("Hello, {{name}}!");
///   const html = try Tmpl.render(allocator, .{ .name = "World" });
pub fn compile(comptime source: []const u8) type {
    @setEvalBranchQuota(100_000);
    const nodes = comptime parseAll(source);
    return CompiledTemplate(nodes);
}

/// A compiled template type parameterized by its comptime node tree.
fn CompiledTemplate(comptime nodes: []const Node) type {
    return struct {
        /// Render the template with the given data into an arena-allocated string.
        ///
        /// All output is written to a single growable buffer backed by `allocator`.
        /// Ideal for per-request arenas — the entire output is freed in one O(1) reset.
        pub fn render(allocator: Allocator, data: anytype) Allocator.Error![]const u8 {
            var buf = std.ArrayList(u8){};
            try renderNodes(nodes, &buf, allocator, data);
            return buf.toOwnedSlice(allocator);
        }

        /// Render the template directly to any writer (socket, file, etc.).
        ///
        /// Useful for streaming responses without buffering the entire output.
        pub fn renderWriter(writer: anytype, data: anytype) !void {
            try renderNodesToWriter(nodes, writer, data);
        }
    };
}

// ============================================================================
// Runtime Rendering
// ============================================================================

/// Render a comptime-known node tree into a growable byte buffer.
fn renderNodes(comptime nodes: []const Node, buf: *std.ArrayList(u8), allocator: Allocator, data: anytype) Allocator.Error!void {
    inline for (nodes) |node| {
        switch (node.tag) {
            .literal => {
                try buf.appendSlice(allocator, node.literal);
            },
            .variable => {
                const val = @field(data, node.field_name);
                try writeEscaped(buf, allocator, val);
            },
            .raw_variable => {
                const val = @field(data, node.field_name);
                try writeValue(buf, allocator, val);
            },
            .this => {
                try writeEscaped(buf, allocator, data);
            },
            .each => {
                const items = @field(data, node.field_name);
                for (items) |item| {
                    try renderNodes(node.children, buf, allocator, item);
                }
            },
            .conditional => {
                if (isTruthy(@field(data, node.field_name))) {
                    try renderNodes(node.children, buf, allocator, data);
                } else {
                    try renderNodes(node.else_children, buf, allocator, data);
                }
            },
        }
    }
}

/// Render a comptime-known node tree to any writer.
fn renderNodesToWriter(comptime nodes: []const Node, writer: anytype, data: anytype) !void {
    inline for (nodes) |node| {
        switch (node.tag) {
            .literal => {
                try writer.writeAll(node.literal);
            },
            .variable => {
                const val = @field(data, node.field_name);
                try writeEscapedToWriter(writer, val);
            },
            .raw_variable => {
                const val = @field(data, node.field_name);
                try writeValueToWriter(writer, val);
            },
            .this => {
                try writeEscapedToWriter(writer, data);
            },
            .each => {
                const items = @field(data, node.field_name);
                for (items) |item| {
                    try renderNodesToWriter(node.children, writer, item);
                }
            },
            .conditional => {
                if (isTruthy(@field(data, node.field_name))) {
                    try renderNodesToWriter(node.children, writer, data);
                } else {
                    try renderNodesToWriter(node.else_children, writer, data);
                }
            },
        }
    }
}

// ============================================================================
// Value Rendering
// ============================================================================

/// Check at comptime whether a type can be coerced to `[]const u8`.
/// Handles `[]const u8`, `*const [N:0]u8` (string literals), `[:0]const u8`, etc.
fn isStringLike(comptime T: type) bool {
    if (T == []const u8) return true;
    const info = @typeInfo(T);
    if (info == .pointer) {
        // Slice of u8 (e.g. [:0]const u8)
        if (info.pointer.size == .slice and info.pointer.child == u8) return true;
        // Pointer to array of u8 (e.g. *const [5:0]u8 — string literals)
        if (@typeInfo(info.pointer.child) == .array) {
            const arr = @typeInfo(info.pointer.child).array;
            if (arr.child == u8) return true;
        }
    }
    return false;
}

/// Write a value to the buffer WITHOUT HTML escaping.
fn writeValue(buf: *std.ArrayList(u8), allocator: Allocator, value: anytype) Allocator.Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (comptime isStringLike(T)) {
        // Coerce any string-like type to []const u8
        const s: []const u8 = value;
        try buf.appendSlice(allocator, s);
    } else if (T == bool) {
        try buf.appendSlice(allocator, if (value) "true" else "false");
    } else if (info == .optional) {
        if (value) |v| {
            try writeValue(buf, allocator, v);
        }
    } else if (info == .int or info == .comptime_int) {
        var num_buf: [20]u8 = undefined;
        const slice = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch "?";
        try buf.appendSlice(allocator, slice);
    } else if (info == .float or info == .comptime_float) {
        var num_buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch "NaN";
        try buf.appendSlice(allocator, slice);
    } else if (info == .@"enum") {
        try buf.appendSlice(allocator, @tagName(value));
    } else {
        // Compile error for unsupported types
        @compileError("Template: cannot render type '" ++ @typeName(T) ++ "'. Supported: []const u8, bool, int, float, enum, optional");
    }
}

/// Write a value to the buffer WITH HTML escaping.
fn writeEscaped(buf: *std.ArrayList(u8), allocator: Allocator, value: anytype) Allocator.Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (comptime isStringLike(T)) {
        const s: []const u8 = value;
        try escapeHtml(buf, allocator, s);
    } else if (info == .optional) {
        if (value) |v| {
            try writeEscaped(buf, allocator, v);
        }
    } else {
        // Non-string types don't contain HTML special chars — write directly
        try writeValue(buf, allocator, value);
    }
}

/// Write a value to a writer WITHOUT HTML escaping.
fn writeValueToWriter(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (comptime isStringLike(T)) {
        const s: []const u8 = value;
        try writer.writeAll(s);
    } else if (T == bool) {
        try writer.writeAll(if (value) "true" else "false");
    } else if (info == .optional) {
        if (value) |v| {
            try writeValueToWriter(writer, v);
        }
    } else if (info == .int or info == .comptime_int) {
        try writer.print("{d}", .{value});
    } else if (info == .float or info == .comptime_float) {
        try writer.print("{d}", .{value});
    } else if (info == .@"enum") {
        try writer.writeAll(@tagName(value));
    } else {
        @compileError("Template: cannot render type '" ++ @typeName(T) ++ "'");
    }
}

/// Write a value to a writer WITH HTML escaping.
fn writeEscapedToWriter(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (comptime isStringLike(T)) {
        const s: []const u8 = value;
        try escapeHtmlToWriter(writer, s);
    } else if (info == .optional) {
        if (value) |v| {
            try writeEscapedToWriter(writer, v);
        }
    } else {
        try writeValueToWriter(writer, value);
    }
}

/// Escape HTML special characters: < > & " '
fn escapeHtml(buf: *std.ArrayList(u8), allocator: Allocator, input: []const u8) Allocator.Error!void {
    for (input) |c| {
        switch (c) {
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#x27;"),
            else => try buf.append(allocator, c),
        }
    }
}

/// Escape HTML special characters to a writer.
fn escapeHtmlToWriter(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#x27;"),
            else => try writer.writeByte(c),
        }
    }
}

// ============================================================================
// Truthy Check
// ============================================================================

/// Determine if a value is "truthy" for conditional rendering.
///
/// - `bool`: direct value
/// - `?T` (optional): `!= null`
/// - `[]T` (slice): `.len > 0`
/// - integers: `!= 0`
/// - `[]const u8`: `.len > 0`
/// - everything else: `true`
fn isTruthy(value: anytype) bool {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (T == bool) return value;
    if (T == []const u8) return value.len > 0;
    if (info == .optional) return value != null;
    if (info == .pointer and info.pointer.size == .slice) return value.len > 0;
    if (info == .int or info == .comptime_int) return value != 0;

    // Structs, enums, etc. are always truthy
    return true;
}

// ============================================================================
// Comptime Template Parser
// ============================================================================

/// Parse an entire template string at comptime into a node tree.
fn parseAll(comptime source: []const u8) []const Node {
    comptime {
        const result = parseNodes(source, 0, null);
        if (result.pos != source.len) {
            @compileError("Template: unexpected content after parsing (internal error)");
        }
        return result.nodes;
    }
}

/// Result from parsing a sequence of nodes.
const ParseResult = struct {
    nodes: []const Node,
    pos: usize,
};

/// Parse nodes from `source[pos..]` until we hit `end_tag` or end of input.
///
/// `end_tag` is the block name we're looking for in a closing tag
/// (e.g., "each" matches `{{/each}}`). null means parse to end of input.
fn parseNodes(comptime source: []const u8, comptime start_pos: usize, comptime end_tag: ?[]const u8) ParseResult {
    comptime {
        var nodes: []const Node = &.{};
        var pos: usize = start_pos;

        while (pos < source.len) {
            // Check for closing tag first (e.g., {{/each}}, {{/if}})
            if (end_tag) |tag| {
                if (startsWith(source[pos..], "{{/")) {
                    const close_start = pos + 3;
                    const close_end = findStr(source[close_start..], "}}") orelse
                        @compileError("Template: unclosed {{/ tag");
                    const close_name = trim(source[close_start .. close_start + close_end]);
                    if (strEql(close_name, tag)) {
                        return .{
                            .nodes = nodes,
                            .pos = close_start + close_end + 2,
                        };
                    }
                }
            }

            // Check for {{else}} (only valid inside #if blocks)
            if (end_tag != null and startsWith(source[pos..], "{{else}}")) {
                return .{
                    .nodes = nodes,
                    .pos = pos, // Caller will handle the {{else}}
                };
            }

            // Check for tag opening {{
            if (startsWith(source[pos..], "{{")) {
                const tag_content_start = pos + 2;
                const tag_end = findStr(source[tag_content_start..], "}}") orelse
                    @compileError("Template: unclosed {{ tag");
                const content = trim(source[tag_content_start .. tag_content_start + tag_end]);
                const after_tag = tag_content_start + tag_end + 2;

                if (startsWith(content, "#each ")) {
                    // {{#each field}}...{{/each}}
                    const field = trim(content["#each ".len..]);
                    if (field.len == 0) @compileError("Template: {{#each}} requires a field name");
                    const body = parseNodes(source, after_tag, "each");
                    nodes = nodes ++ &[_]Node{.{
                        .tag = .each,
                        .field_name = field,
                        .children = body.nodes,
                    }};
                    pos = body.pos;
                } else if (startsWith(content, "#if ")) {
                    // {{#if field}}...{{else}}...{{/if}}
                    const field = trim(content["#if ".len..]);
                    if (field.len == 0) @compileError("Template: {{#if}} requires a field name");

                    // Parse true branch (stops at {{else}} or {{/if}})
                    const true_branch = parseNodes(source, after_tag, "if");

                    // Check if we stopped at {{else}} or {{/if}}
                    if (startsWith(source[true_branch.pos..], "{{else}}")) {
                        // Parse else branch
                        const else_start = true_branch.pos + "{{else}}".len;
                        const else_branch = parseNodes(source, else_start, "if");
                        nodes = nodes ++ &[_]Node{.{
                            .tag = .conditional,
                            .field_name = field,
                            .children = true_branch.nodes,
                            .else_children = else_branch.nodes,
                        }};
                        pos = else_branch.pos;
                    } else {
                        // No else branch
                        nodes = nodes ++ &[_]Node{.{
                            .tag = .conditional,
                            .field_name = field,
                            .children = true_branch.nodes,
                        }};
                        pos = true_branch.pos;
                    }
                } else if (strEql(content, ".")) {
                    // {{.}} — current context value
                    nodes = nodes ++ &[_]Node{.{ .tag = .this }};
                    pos = after_tag;
                } else if (content.len > 0 and content[0] == '&') {
                    // {{&name}} — raw/unescaped variable
                    const field = trim(content[1..]);
                    if (field.len == 0) @compileError("Template: {{&}} requires a field name");
                    nodes = nodes ++ &[_]Node{.{
                        .tag = .raw_variable,
                        .field_name = field,
                    }};
                    pos = after_tag;
                } else if (content.len > 0 and content[0] != '#' and content[0] != '/') {
                    // {{name}} — escaped variable
                    nodes = nodes ++ &[_]Node{.{
                        .tag = .variable,
                        .field_name = content,
                    }};
                    pos = after_tag;
                } else {
                    @compileError("Template: unknown directive '{{" ++ content ++ "}}'");
                }
            } else {
                // Literal text — consume until next {{ or end
                const lit_start = pos;
                while (pos < source.len and !startsWith(source[pos..], "{{")) {
                    pos += 1;
                }
                if (pos > lit_start) {
                    nodes = nodes ++ &[_]Node{.{
                        .tag = .literal,
                        .literal = source[lit_start..pos],
                    }};
                }
            }
        }

        // If we expected a closing tag but reached end of input, error
        if (end_tag) |tag| {
            @compileError("Template: unclosed block — expected {{/" ++ tag ++ "}}");
        }

        return .{
            .nodes = nodes,
            .pos = pos,
        };
    }
}

// ============================================================================
// Comptime String Helpers
// ============================================================================

/// Check if `haystack` starts with `prefix` (comptime only).
fn startsWith(comptime haystack: []const u8, comptime prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return strEql(haystack[0..prefix.len], prefix);
}

/// Find the first occurrence of `needle` in `haystack` (comptime only).
/// Returns the index, or null if not found.
fn findStr(comptime haystack: []const u8, comptime needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (strEql(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Comptime string equality.
fn strEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

/// Trim leading and trailing whitespace (comptime only).
fn trim(comptime s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) {
        start += 1;
    }
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) {
        end -= 1;
    }
    return s[start..end];
}

// ============================================================================
// Tests
// ============================================================================

test "literal only" {
    const Tmpl = compile("<h1>Hello</h1>");
    const result = try Tmpl.render(std.testing.allocator, .{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<h1>Hello</h1>", result);
}

test "variable interpolation" {
    const Tmpl = compile("Hello, {{name}}!");
    const result = try Tmpl.render(std.testing.allocator, .{ .name = "World" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "HTML escaping" {
    const Tmpl = compile("{{content}}");
    const result = try Tmpl.render(std.testing.allocator, .{ .content = "<script>alert('xss')</script>" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;", result);
}

test "raw variable — no escaping" {
    const Tmpl = compile("{{&content}}");
    const result = try Tmpl.render(std.testing.allocator, .{ .content = "<b>bold</b>" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<b>bold</b>", result);
}

test "integer variable" {
    const Tmpl = compile("Count: {{count}}");
    const result = try Tmpl.render(std.testing.allocator, .{ .count = @as(u32, 42) });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Count: 42", result);
}

test "boolean variable" {
    const Tmpl = compile("Active: {{active}}");
    const result = try Tmpl.render(std.testing.allocator, .{ .active = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Active: true", result);
}

test "optional variable — present" {
    const Tmpl = compile("Email: {{email}}");
    const email: ?[]const u8 = "alice@example.com";
    const result = try Tmpl.render(std.testing.allocator, .{ .email = email });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Email: alice@example.com", result);
}

test "optional variable — null" {
    const Tmpl = compile("Email: {{email}}");
    const email: ?[]const u8 = null;
    const result = try Tmpl.render(std.testing.allocator, .{ .email = email });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Email: ", result);
}

test "each loop — string slice" {
    const Tmpl = compile("{{#each items}}<li>{{.}}</li>{{/each}}");
    const items = [_][]const u8{ "a", "b", "c" };
    const result = try Tmpl.render(std.testing.allocator, .{ .items = &items });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<li>a</li><li>b</li><li>c</li>", result);
}

test "each loop — struct slice" {
    const Item = struct { name: []const u8, price: u32 };
    const Tmpl = compile("{{#each products}}{{name}}=${{price}} {{/each}}");
    const products = [_]Item{
        .{ .name = "Pen", .price = 2 },
        .{ .name = "Book", .price = 15 },
    };
    const result = try Tmpl.render(std.testing.allocator, .{ .products = &products });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Pen=$2 Book=$15 ", result);
}

test "each loop — empty slice" {
    const Tmpl = compile("{{#each items}}<li>{{.}}</li>{{/each}}");
    const items = [_][]const u8{};
    const result = try Tmpl.render(std.testing.allocator, .{ .items = &items });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "if — true" {
    const Tmpl = compile("{{#if show}}<p>Visible</p>{{/if}}");
    const result = try Tmpl.render(std.testing.allocator, .{ .show = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<p>Visible</p>", result);
}

test "if — false" {
    const Tmpl = compile("{{#if show}}<p>Visible</p>{{/if}}");
    const result = try Tmpl.render(std.testing.allocator, .{ .show = false });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "if/else — true branch" {
    const Tmpl = compile("{{#if admin}}<b>Admin</b>{{else}}<i>User</i>{{/if}}");
    const result = try Tmpl.render(std.testing.allocator, .{ .admin = true });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<b>Admin</b>", result);
}

test "if/else — false branch" {
    const Tmpl = compile("{{#if admin}}<b>Admin</b>{{else}}<i>User</i>{{/if}}");
    const result = try Tmpl.render(std.testing.allocator, .{ .admin = false });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<i>User</i>", result);
}

test "if with optional — non-null" {
    const Tmpl = compile("{{#if email}}Has email{{else}}No email{{/if}}");
    const email: ?[]const u8 = "a@b.com";
    const result = try Tmpl.render(std.testing.allocator, .{ .email = email });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Has email", result);
}

test "if with optional — null" {
    const Tmpl = compile("{{#if email}}Has email{{else}}No email{{/if}}");
    const email: ?[]const u8 = null;
    const result = try Tmpl.render(std.testing.allocator, .{ .email = email });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("No email", result);
}

test "if with slice — non-empty" {
    const Tmpl = compile("{{#if items}}Has items{{else}}Empty{{/if}}");
    const items = [_]u8{ 1, 2 };
    const result = try Tmpl.render(std.testing.allocator, .{ .items = @as([]const u8, &items) });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Has items", result);
}

test "if with slice — empty" {
    const Tmpl = compile("{{#if items}}Has items{{else}}Empty{{/if}}");
    const items = [_]u8{};
    const result = try Tmpl.render(std.testing.allocator, .{ .items = @as([]const u8, &items) });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Empty", result);
}

test "nested blocks — each inside if" {
    const Tmpl = compile("{{#if show}}{{#each items}}<li>{{.}}</li>{{/each}}{{/if}}");
    const items = [_][]const u8{ "x", "y" };
    const result = try Tmpl.render(std.testing.allocator, .{ .show = true, .items = &items });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<li>x</li><li>y</li>", result);
}

test "complex template — htmx user table" {
    const User = struct { name: []const u8, email: []const u8 };
    const Tmpl = compile(
        \\<table id="users" hx-get="/api/users" hx-trigger="load">
        \\  <thead><tr><th>Name</th><th>Email</th></tr></thead>
        \\  <tbody>
        \\    {{#each users}}<tr hx-get="/api/users/detail" hx-target="#detail">
        \\      <td>{{name}}</td><td>{{email}}</td>
        \\    </tr>{{/each}}
        \\  </tbody>
        \\</table>
    );
    const users = [_]User{
        .{ .name = "Alice", .email = "alice@test.com" },
        .{ .name = "Bob", .email = "bob@test.com" },
    };
    const result = try Tmpl.render(std.testing.allocator, .{ .users = &users });
    defer std.testing.allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "Alice") != null);
    try std.testing.expect(mem.indexOf(u8, result, "bob@test.com") != null);
    try std.testing.expect(mem.indexOf(u8, result, "hx-get") != null);
}

test "whitespace in tags" {
    const Tmpl = compile("{{ name }}");
    const result = try Tmpl.render(std.testing.allocator, .{ .name = "Alice" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Alice", result);
}

test "multiple variables" {
    const Tmpl = compile("{{first}} {{last}} ({{age}})");
    const result = try Tmpl.render(std.testing.allocator, .{
        .first = "John",
        .last = "Doe",
        .age = @as(u32, 30),
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("John Doe (30)", result);
}

test "XSS prevention in variables" {
    const Tmpl = compile("<input value=\"{{val}}\">");
    const result = try Tmpl.render(std.testing.allocator, .{ .val = "\" onclick=\"alert(1)" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<input value=\"&quot; onclick=&quot;alert(1)\">", result);
}

test "raw bypasses escaping" {
    const Tmpl = compile("<div>{{&html}}</div>");
    const result = try Tmpl.render(std.testing.allocator, .{ .html = "<p>Safe HTML from server</p>" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<div><p>Safe HTML from server</p></div>", result);
}
