//! HTTP Request wrapper providing arena-per-request allocation
//! and zero-copy access to parsed request data.

const std = @import("std");
const http = std.http;
const mem = std.mem;

const Request = @This();

/// HTTP method (GET, POST, etc.)
method: http.Method,

/// Request path (e.g., "/api/users")
/// This is a zero-copy slice into the connection's read buffer.
path: []const u8,

/// HTTP version (1.0 or 1.1)
version: http.Version,

/// Whether the client wants to keep the connection alive.
keep_alive: bool,

/// Content-Type header value (zero-copy slice).
content_type: ?[]const u8,

/// Content-Length value if present.
content_length: ?u64,

/// Arena allocator for this request's lifetime.
/// Everything allocated with this is freed when the request completes.
arena: std.mem.Allocator,

/// Raw header buffer for iteration.
head_buffer: []const u8,

/// Route parameters extracted by the router.
/// Populated after routing; keys and values are slices into the path.
params: []const Param = &.{},

/// A single path parameter (e.g., `:id` -> Param{ .key = "id", .value = "42" })
pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

/// Get a path parameter by name.
/// Returns null if the parameter doesn't exist.
pub fn pathParam(self: *const Request, name: []const u8) ?[]const u8 {
    for (self.params) |p| {
        if (mem.eql(u8, p.key, name)) return p.value;
    }
    return null;
}

/// Iterate over all HTTP headers in the request.
/// Zero-copy: returned names/values point into the read buffer.
pub fn headerIterator(self: *const Request) http.HeaderIterator {
    return http.HeaderIterator.init(self.head_buffer);
}

/// Get the value of a specific header by name (case-insensitive).
pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
    var it = self.headerIterator();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return header.value;
        }
    }
    return null;
}

/// Create a Request from std.http.Server.Request.Head and its raw buffer.
pub fn fromHttpHead(
    head: http.Server.Request.Head,
    head_buffer: []const u8,
    arena: std.mem.Allocator,
) Request {
    return .{
        .method = head.method,
        .path = head.target,
        .version = head.version,
        .keep_alive = head.keep_alive,
        .content_type = head.content_type,
        .content_length = head.content_length,
        .arena = arena,
        .head_buffer = head_buffer,
    };
}

// ---- Tests ----

test "pathParam - found" {
    const gpa = std.testing.allocator;
    var request: Request = .{
        .method = .GET,
        .path = "/users/42",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = gpa,
        .head_buffer = "",
        .params = &.{
            .{ .key = "id", .value = "42" },
            .{ .key = "name", .value = "alice" },
        },
    };
    _ = &request;

    const val = request.pathParam("id");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("42", val.?);
}

test "pathParam - not found" {
    const gpa = std.testing.allocator;
    var request: Request = .{
        .method = .GET,
        .path = "/users/42",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = gpa,
        .head_buffer = "",
        .params = &.{
            .{ .key = "id", .value = "42" },
        },
    };
    _ = &request;

    try std.testing.expect(request.pathParam("missing") == null);
}

test "pathParam - empty params" {
    const gpa = std.testing.allocator;
    var request: Request = .{
        .method = .GET,
        .path = "/",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = gpa,
        .head_buffer = "",
    };
    _ = &request;

    try std.testing.expect(request.pathParam("anything") == null);
}

test "pathParam - second param" {
    const gpa = std.testing.allocator;
    var request: Request = .{
        .method = .GET,
        .path = "/users/7/posts/99",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = gpa,
        .head_buffer = "",
        .params = &.{
            .{ .key = "user_id", .value = "7" },
            .{ .key = "post_id", .value = "99" },
        },
    };
    _ = &request;

    const val = request.pathParam("post_id");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("99", val.?);
}

test "default field values" {
    const gpa = std.testing.allocator;
    const request: Request = .{
        .method = .POST,
        .path = "/api/data",
        .version = .@"HTTP/1.0",
        .keep_alive = false,
        .content_type = "application/json",
        .content_length = 128,
        .arena = gpa,
        .head_buffer = "",
    };

    try std.testing.expectEqual(http.Method.POST, request.method);
    try std.testing.expectEqualStrings("/api/data", request.path);
    try std.testing.expectEqual(http.Version.@"HTTP/1.0", request.version);
    try std.testing.expect(!request.keep_alive);
    try std.testing.expectEqualStrings("application/json", request.content_type.?);
    try std.testing.expectEqual(@as(u64, 128), request.content_length.?);
    try std.testing.expectEqual(@as(usize, 0), request.params.len);
}
