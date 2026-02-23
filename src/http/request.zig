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

/// Request path (e.g., "/api/users") with query string stripped.
/// This is a zero-copy slice into the connection's read buffer.
path: []const u8,

/// Raw query string without the leading '?' (e.g., "page=1&limit=10").
/// Zero-copy slice into the connection's read buffer. Null if no query string.
raw_query: ?[]const u8 = null,

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

/// Cached parsed query parameters (populated lazily on first access).
query_params_cache: ?[]const QueryParam = null,

/// Maximum allowed request body size (default: 1MB).
/// Bodies larger than this are rejected with error.BodyTooLarge.
pub const max_body_size = 1024 * 1024;

/// A single path parameter (e.g., `:id` -> Param{ .key = "id", .value = "42" })
pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

/// A single query parameter (e.g., `page=1` -> QueryParam{ .key = "page", .value = "1" })
pub const QueryParam = struct {
    key: []const u8,
    value: []const u8,
};

/// Maximum number of query parameters supported per request.
const max_query_params = 32;

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
// ============================================================================
// Query parameter parsing (Step 16)
// ============================================================================

/// Get a single query parameter by name (first match).
///
/// Lazily parses the query string on first call. Returns null if
/// the parameter doesn't exist or if there is no query string.
///
/// Values are percent-decoded. If the raw value contains no encoded
/// characters, the returned slice points directly into the read buffer
/// (zero-copy). Otherwise, a decoded copy is allocated in the request arena.
///
/// Example:
///   // Request: GET /api/users?page=2&sort=name
///   const page = request.queryParam("page"); // -> "2"
///   const sort = request.queryParam("sort"); // -> "name"
///   const missing = request.queryParam("x"); // -> null
pub fn queryParam(self: *Request, name: []const u8) ?[]const u8 {
    const params = self.ensureQueryParams();
    for (params) |p| {
        if (mem.eql(u8, p.key, name)) return p.value;
    }
    return null;
}

/// Get all values for a query parameter name.
///
/// Returns an arena-allocated slice of all values matching the given key.
/// Useful for multi-value parameters like `?tag=a&tag=b`.
///
/// Returns an empty slice if no values match or if there is no query string.
pub fn queryParamAll(self: *Request, name: []const u8) []const []const u8 {
    const params = self.ensureQueryParams();
    // Count matches first.
    var count: usize = 0;
    for (params) |p| {
        if (mem.eql(u8, p.key, name)) count += 1;
    }
    if (count == 0) return &.{};

    // Allocate result in the request arena.
    const result = self.arena.alloc([]const u8, count) catch return &.{};
    var idx: usize = 0;
    for (params) |p| {
        if (mem.eql(u8, p.key, name)) {
            result[idx] = p.value;
            idx += 1;
        }
    }
    return result;
}

/// Ensure query params are parsed (lazy initialization).
/// Returns the cached slice, parsing on first call.
fn ensureQueryParams(self: *Request) []const QueryParam {
    if (self.query_params_cache) |cached| return cached;

    const parsed = parseQueryString(self.raw_query orelse {
        self.query_params_cache = &.{};
        return &.{};
    }, self.arena);
    self.query_params_cache = parsed;
    return parsed;
}

/// Parse a raw query string (without leading '?') into key-value pairs.
///
/// Handles:
///   - `key=value` pairs separated by `&`
///   - `key` without value (value defaults to empty string)
///   - `key=` with empty value
///   - Percent-decoding of keys and values (`%20` → space, `+` → space)
///   - Up to `max_query_params` parameters (extras silently dropped)
fn parseQueryString(raw: []const u8, allocator: std.mem.Allocator) []const QueryParam {
    if (raw.len == 0) return &.{};

    var buf: [max_query_params]QueryParam = undefined;
    var count: usize = 0;

    var pairs = mem.splitScalar(u8, raw, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        if (count >= max_query_params) break;

        if (mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            const raw_key = pair[0..eq_pos];
            const raw_value = pair[eq_pos + 1 ..];
            buf[count] = .{
                .key = percentDecode(allocator, raw_key) catch raw_key,
                .value = percentDecode(allocator, raw_value) catch raw_value,
            };
        } else {
            // Key with no value (e.g., "flag" in "?flag&other=1")
            buf[count] = .{
                .key = percentDecode(allocator, pair) catch pair,
                .value = "",
            };
        }
        count += 1;
    }

    if (count == 0) return &.{};

    // Copy from stack buffer to arena-allocated slice.
    return allocator.dupe(QueryParam, buf[0..count]) catch &.{};
}

/// URL percent-decode a string.
///
/// Decodes `%XX` hex pairs and `+` → space (application/x-www-form-urlencoded).
/// If the input contains no encoded characters, returns the original slice
/// (zero-copy). Otherwise, allocates a decoded copy using the provided allocator.
///
/// Examples:
///   percentDecode(alloc, "hello")      → "hello" (original slice, no alloc)
///   percentDecode(alloc, "hello%20world") → "hello world" (new allocation)
///   percentDecode(alloc, "a+b")        → "a b" (new allocation)
pub fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // Fast path: check if any decoding is needed.
    if (!needsDecoding(input)) return input;

    // Decoded output is always <= input length.
    const buf = try allocator.alloc(u8, input.len);
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            if (hexToNibble(input[i + 1])) |hi| {
                if (hexToNibble(input[i + 2])) |lo| {
                    buf[out_idx] = (@as(u8, hi) << 4) | @as(u8, lo);
                    out_idx += 1;
                    i += 3;
                    continue;
                }
            }
            // Invalid hex pair — keep the '%' literal.
            buf[out_idx] = '%';
            out_idx += 1;
            i += 1;
        } else if (input[i] == '+') {
            buf[out_idx] = ' ';
            out_idx += 1;
            i += 1;
        } else {
            buf[out_idx] = input[i];
            out_idx += 1;
            i += 1;
        }
    }

    // Shrink to actual decoded length (no realloc needed — arena doesn't reclaim).
    return buf[0..out_idx];
}

/// Check if a string contains any percent-encoded or '+' characters.
inline fn needsDecoding(input: []const u8) bool {
    for (input) |c| {
        if (c == '%' or c == '+') return true;
    }
    return false;
}

/// Convert a hex ASCII character to its 4-bit value.
/// Returns null for non-hex characters.
inline fn hexToNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @truncate(c - '0'),
        'A'...'F' => @truncate(c - 'A' + 10),
        'a'...'f' => @truncate(c - 'a' + 10),
        else => null,
    };
}
/// Create a Request from std.http.Server.Request.Head and its raw buffer.
///
/// Splits the request target at '?' to separate the path from the query string.
/// This ensures `path` never contains query parameters, so the router matches
/// correctly and handlers access query params via `queryParam()` / `queryParamAll()`.
pub fn fromHttpHead(
    head: http.Server.Request.Head,
    head_buffer: []const u8,
    arena: std.mem.Allocator,
) Request {
    // Split target into path and query string at the '?' boundary.
    const target = head.target;
    const path, const raw_query = if (mem.indexOfScalar(u8, target, '?')) |qi|
        .{ target[0..qi], if (qi + 1 < target.len) target[qi + 1 ..] else null }
    else
        .{ target, null };

    return .{
        .method = head.method,
        .path = path,
        .raw_query = raw_query,
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

// ---- Query parameter tests (Step 16) ----

test "percentDecode - no encoding (zero-copy)" {
    const gpa = std.testing.allocator;
    const input = "hello";
    const result = try percentDecode(gpa, input);
    // Should return the same slice (no allocation).
    try std.testing.expectEqual(input.ptr, result.ptr);
    try std.testing.expectEqualStrings("hello", result);
}

test "percentDecode - hex pairs" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try percentDecode(arena, "hello%20world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "percentDecode - plus as space" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try percentDecode(arena, "hello+world");
    try std.testing.expectEqualStrings("hello world", result);
}

test "percentDecode - mixed encoding" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try percentDecode(arena, "a%2Fb%3Dc+d");
    try std.testing.expectEqualStrings("a/b=c d", result);
}

test "percentDecode - invalid hex pair kept as literal" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try percentDecode(arena, "100%ZZdone");
    try std.testing.expectEqualStrings("100%ZZdone", result);
}

test "percentDecode - percent at end of string" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try percentDecode(arena, "trail%");
    try std.testing.expectEqualStrings("trail%", result);
}

test "percentDecode - empty string" {
    const gpa = std.testing.allocator;
    const result = try percentDecode(gpa, "");
    try std.testing.expectEqualStrings("", result);
}

test "percentDecode - lowercase hex" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try percentDecode(arena, "%2f%2F");
    try std.testing.expectEqualStrings("//", result);
}

test "queryParam - basic key=value" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/api/users",
        .raw_query = "page=1&limit=10",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    try std.testing.expectEqualStrings("1", request.queryParam("page").?);
    try std.testing.expectEqualStrings("10", request.queryParam("limit").?);
    try std.testing.expect(request.queryParam("missing") == null);
}

test "queryParam - no query string" {
    const gpa = std.testing.allocator;
    var request: Request = .{
        .method = .GET,
        .path = "/api/users",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = gpa,
        .head_buffer = "",
    };

    try std.testing.expect(request.queryParam("page") == null);
}

test "queryParam - percent-encoded value" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/search",
        .raw_query = "q=hello%20world&lang=en",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    try std.testing.expectEqualStrings("hello world", request.queryParam("q").?);
    try std.testing.expectEqualStrings("en", request.queryParam("lang").?);
}

test "queryParam - key without value" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/flags",
        .raw_query = "verbose&debug&format=json",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    try std.testing.expectEqualStrings("", request.queryParam("verbose").?);
    try std.testing.expectEqualStrings("", request.queryParam("debug").?);
    try std.testing.expectEqualStrings("json", request.queryParam("format").?);
}

test "queryParam - empty value" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/test",
        .raw_query = "key=",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    try std.testing.expectEqualStrings("", request.queryParam("key").?);
}

test "queryParam - lazy caching" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/test",
        .raw_query = "a=1",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    // Cache should be null before first access.
    try std.testing.expect(request.query_params_cache == null);

    _ = request.queryParam("a");

    // Cache should be populated after first access.
    try std.testing.expect(request.query_params_cache != null);
    try std.testing.expectEqual(@as(usize, 1), request.query_params_cache.?.len);
}

test "queryParamAll - multiple values" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/filter",
        .raw_query = "tag=zig&tag=http&tag=json&sort=name",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    const tags = request.queryParamAll("tag");
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("zig", tags[0]);
    try std.testing.expectEqualStrings("http", tags[1]);
    try std.testing.expectEqualStrings("json", tags[2]);

    const sorts = request.queryParamAll("sort");
    try std.testing.expectEqual(@as(usize, 1), sorts.len);
    try std.testing.expectEqualStrings("name", sorts[0]);
}

test "queryParamAll - no matches" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/test",
        .raw_query = "a=1",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    const result = request.queryParamAll("missing");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "queryParam - plus decoding in query" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/search",
        .raw_query = "q=hello+world&name=foo+bar",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    try std.testing.expectEqualStrings("hello world", request.queryParam("q").?);
    try std.testing.expectEqualStrings("foo bar", request.queryParam("name").?);
}

test "fromHttpHead - splits path and query" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Simulate what std.http.Server gives us: a target with query string.
    const request = Request.fromHttpHead(.{
        .method = .GET,
        .target = "/api/users?page=2&limit=5",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .expect = null,
        .transfer_encoding = .none,
        .transfer_compression = .identity,
    }, "", arena);

    try std.testing.expectEqualStrings("/api/users", request.path);
    try std.testing.expectEqualStrings("page=2&limit=5", request.raw_query.?);
}

test "fromHttpHead - no query string" {
    const gpa = std.testing.allocator;

    const request = Request.fromHttpHead(.{
        .method = .GET,
        .target = "/api/users",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .expect = null,
        .transfer_encoding = .none,
        .transfer_compression = .identity,
    }, "", gpa);

    try std.testing.expectEqualStrings("/api/users", request.path);
    try std.testing.expect(request.raw_query == null);
}

test "fromHttpHead - trailing question mark" {
    const gpa = std.testing.allocator;

    const request = Request.fromHttpHead(.{
        .method = .GET,
        .target = "/api/users?",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .expect = null,
        .transfer_encoding = .none,
        .transfer_compression = .identity,
    }, "", gpa);

    try std.testing.expectEqualStrings("/api/users", request.path);
    try std.testing.expect(request.raw_query == null);
}

test "queryParam - empty query string" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var request: Request = .{
        .method = .GET,
        .path = "/test",
        .raw_query = "",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = arena,
        .head_buffer = "",
    };

    try std.testing.expect(request.queryParam("anything") == null);
}

test "parseQueryString - encoded key and value" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const params = parseQueryString("my%20key=my%20value", arena);
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("my key", params[0].key);
    try std.testing.expectEqualStrings("my value", params[0].value);
}
