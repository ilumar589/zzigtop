//! HTTP Request wrapper providing arena-per-request allocation
//! and zero-copy access to parsed request data.
//!
//! Supports JSON body parsing via `std.json.parseFromSliceLeaky`,
//! which allocates into the per-request arena for O(1) bulk cleanup.

const std = @import("std");
const http = std.http;
const mem = std.mem;
const json = std.json;

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

/// The raw request body (populated after readBody() is called).
/// Arena-allocated — freed automatically when the request arena resets.
body: ?[]const u8 = null,

/// Maximum allowed request body size (default: 1MB).
/// Bodies larger than this are rejected with error.BodyTooLarge.
pub const max_body_size = 1024 * 1024;

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

/// Read and return the request body.
///
/// If the body has already been read, returns the cached value.
/// The body is allocated in the request arena — freed in bulk
/// when the arena resets (O(1), no per-allocation bookkeeping).
///
/// Returns `error.NoBody` if the request method does not carry a body
/// (e.g., GET, HEAD) or if Content-Length is 0.
pub fn readBody(self: *Request, body_reader: *std.Io.Reader) ![]const u8 {
    // Return cached body if already read.
    if (self.body) |b| return b;

    // No Content-Length or zero — no body to read.
    const length = self.content_length orelse return error.NoBody;
    if (length == 0) return error.NoBody;
    if (length > max_body_size) return error.BodyTooLarge;

    // Read the full body into arena-allocated memory.
    const len: usize = @intCast(length);
    const buf = try self.arena.alloc(u8, len);
    var total_read: usize = 0;
    while (total_read < len) {
        var read_buf = [_][]u8{buf[total_read..]};
        const n = body_reader.readVec(&read_buf) orelse break;
        if (n == 0) break;
        total_read += n;
    }
    if (total_read != len) return error.IncompleteBody;

    self.body = buf;
    return buf;
}

/// Parse the request body as JSON into a typed Zig struct.
///
/// Uses `std.json.parseFromSliceLeaky` which allocates into the
/// request arena — string values are slices into the body buffer
/// when possible (zero-copy), and all allocations are freed in
/// one O(1) arena reset when the request completes.
///
/// Requires that `readBody()` has been called first to populate
/// the body, or the body field has been set directly.
///
/// Example:
///   const User = struct { name: []const u8, age: u32 };
///   const user = try request.jsonBody(User);
pub fn jsonBody(self: *Request, comptime T: type) !T {
    const body = self.body orelse return error.NoBody;
    return json.parseFromSliceLeaky(T, self.arena, body, .{
        .ignore_unknown_fields = true,
    });
}

/// JSON parsing error type (convenience alias).
pub const JsonError = json.ParseError(json.Scanner);

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

// ---- JSON body tests ----

test "jsonBody - parse simple struct" {
    const gpa = std.testing.allocator;
    const body_bytes = "{\"name\":\"Alice\",\"age\":30}";

    var request: Request = .{
        .method = .POST,
        .path = "/api/users",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = "application/json",
        .content_length = body_bytes.len,
        .arena = gpa,
        .head_buffer = "",
        .body = body_bytes,
    };
    _ = &request;

    const User = struct {
        name: []const u8,
        age: u32,
    };

    const user = try request.jsonBody(User);
    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(u32, 30), user.age);
}

test "jsonBody - ignore unknown fields" {
    const gpa = std.testing.allocator;
    const body_bytes = "{\"name\":\"Bob\",\"age\":25,\"extra\":true}";

    var request: Request = .{
        .method = .POST,
        .path = "/api/users",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = "application/json",
        .content_length = body_bytes.len,
        .arena = gpa,
        .head_buffer = "",
        .body = body_bytes,
    };
    _ = &request;

    const User = struct {
        name: []const u8,
        age: u32,
    };

    const user = try request.jsonBody(User);
    try std.testing.expectEqualStrings("Bob", user.name);
    try std.testing.expectEqual(@as(u32, 25), user.age);
}

test "jsonBody - optional fields" {
    const gpa = std.testing.allocator;
    const body_bytes = "{\"name\":\"Charlie\"}";

    var request: Request = .{
        .method = .POST,
        .path = "/api/users",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = "application/json",
        .content_length = body_bytes.len,
        .arena = gpa,
        .head_buffer = "",
        .body = body_bytes,
    };
    _ = &request;

    const User = struct {
        name: []const u8,
        age: ?u32 = null,
    };

    const user = try request.jsonBody(User);
    try std.testing.expectEqualStrings("Charlie", user.name);
    try std.testing.expectEqual(@as(?u32, null), user.age);
}

test "jsonBody - no body returns error" {
    const gpa = std.testing.allocator;
    var request: Request = .{
        .method = .POST,
        .path = "/api/users",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = "application/json",
        .content_length = null,
        .arena = gpa,
        .head_buffer = "",
    };
    _ = &request;

    const User = struct { name: []const u8 };
    const result = request.jsonBody(User);
    try std.testing.expectError(error.NoBody, result);
}

test "jsonBody - nested struct" {
    const gpa = std.testing.allocator;
    const body_bytes = "{\"user\":{\"name\":\"Diana\"},\"count\":5}";

    var request: Request = .{
        .method = .POST,
        .path = "/api/data",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = "application/json",
        .content_length = body_bytes.len,
        .arena = gpa,
        .head_buffer = "",
        .body = body_bytes,
    };
    _ = &request;

    const Inner = struct { name: []const u8 };
    const Outer = struct {
        user: Inner,
        count: u32,
    };

    const data = try request.jsonBody(Outer);
    try std.testing.expectEqualStrings("Diana", data.user.name);
    try std.testing.expectEqual(@as(u32, 5), data.count);
}

test "jsonBody - array field" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body_bytes = "{\"tags\":[\"zig\",\"http\",\"json\"]}";

    var request: Request = .{
        .method = .POST,
        .path = "/api/data",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = "application/json",
        .content_length = body_bytes.len,
        .arena = arena,
        .head_buffer = "",
        .body = body_bytes,
    };
    _ = &request;

    const Data = struct {
        tags: []const []const u8,
    };

    const data = try request.jsonBody(Data);
    try std.testing.expectEqual(@as(usize, 3), data.tags.len);
    try std.testing.expectEqualStrings("zig", data.tags[0]);
    try std.testing.expectEqualStrings("http", data.tags[1]);
    try std.testing.expectEqualStrings("json", data.tags[2]);
}
