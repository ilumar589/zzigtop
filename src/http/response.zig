//! HTTP Response builder.
//!
//! Builds a response with status, headers, and body, then flushes
//! everything in a single vectored write for maximum throughput.
//!
//! Supports typed JSON serialization via `std.json.Stringify.valueAlloc`,
//! which serializes any Zig struct directly into arena-allocated bytes.

const std = @import("std");
const http = std.http;
const mem = std.mem;
const Io = std.Io;
const json = std.json;

const Response = @This();

/// The underlying writer to the client socket.
writer: *Io.Writer,

/// HTTP status code for this response.
status: http.Status = .ok,

/// The response body content.
body: []const u8 = "",

/// Extra headers storage (fixed-size, no allocation).
extra_header_buf: [max_extra_headers]http.Header = undefined,
extra_header_count: usize = 0,

/// Arena allocator for response-lifetime allocations.
arena: std.mem.Allocator,

/// Whether to send Connection: keep-alive or close.
keep_alive: bool = true,

/// HTTP version to use in the status line.
version: http.Version = .@"HTTP/1.1",

const max_extra_headers = 32;

/// Set the HTTP status code.
pub fn setStatus(self: *Response, status: http.Status) void {
    self.status = status;
}

/// Add a response header. Up to 32 extra headers are supported per response.
pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
    if (self.extra_header_count >= max_extra_headers) return error.TooManyHeaders;
    self.extra_header_buf[self.extra_header_count] = .{ .name = name, .value = value };
    self.extra_header_count += 1;
}

/// Set the response body. Automatically sets Content-Length.
pub fn setBody(self: *Response, body: []const u8) void {
    self.body = body;
}

/// Set the response body and a specific content type.
pub fn setBodyWithType(self: *Response, body: []const u8, content_type: []const u8) !void {
    self.body = body;
    try self.addHeader("content-type", content_type);
}

/// Send the response to the client.
///
/// Uses `std.http.Server.Request.respond()` style output:
/// status line + headers + body in vectored writes for minimal syscall overhead.
pub fn flush(self: *Response) !void {
    const out = self.writer;

    // ---- Status line ----
    const phrase = self.status.phrase() orelse "Unknown";
    try out.print("{s} {d} {s}\r\n", .{
        @tagName(self.version),
        @intFromEnum(self.status),
        phrase,
    });

    // ---- Connection header ----
    switch (self.version) {
        .@"HTTP/1.0" => {
            if (self.keep_alive) try out.writeAll("connection: keep-alive\r\n");
        },
        .@"HTTP/1.1" => {
            if (!self.keep_alive) try out.writeAll("connection: close\r\n");
        },
    }

    // ---- Content-Length ----
    try out.print("content-length: {d}\r\n", .{self.body.len});

    // ---- Extra headers (vectored write for each) ----
    for (self.extra_header_buf[0..self.extra_header_count]) |header| {
        var vecs: [4][]const u8 = .{ header.name, ": ", header.value, "\r\n" };
        try out.writeVecAll(&vecs);
    }

    // ---- End of headers ----
    try out.writeAll("\r\n");

    // ---- Body ----
    if (self.body.len > 0) {
        try out.writeAll(self.body);
    }

    // ---- Flush to socket ----
    try out.flush();
}

/// Create a Response wrapping a writer.
pub fn init(writer: *Io.Writer, arena: std.mem.Allocator, keep_alive: bool, version: http.Version) Response {
    return .{
        .writer = writer,
        .arena = arena,
        .keep_alive = keep_alive,
        .version = version,
    };
}

/// Send a simple text response with a status code and body.
/// Convenience function for handlers.
pub fn sendText(self: *Response, status: http.Status, body: []const u8) !void {
    self.status = status;
    self.body = body;
    try self.addHeader("content-type", "text/plain; charset=utf-8");
    try self.flush();
}

/// Send a JSON response.
pub fn sendJson(self: *Response, status: http.Status, body: []const u8) !void {
    self.status = status;
    self.body = body;
    try self.addHeader("content-type", "application/json; charset=utf-8");
    try self.flush();
}

/// Serialize any Zig value as a JSON response.
///
/// Uses `std.json.Stringify.valueAlloc` to convert the value into
/// an arena-allocated JSON string, then sends it with the correct
/// Content-Type header.
///
/// The serialized JSON lives in the request arena and is freed
/// in one O(1) bulk reset when the request completes.
///
/// Example:
///   const result = .{ .id = 1, .name = "Alice", .active = true };
///   try response.sendJsonValue(.ok, result);
pub fn sendJsonValue(self: *Response, status: http.Status, value: anytype) !void {
    const body = try json.Stringify.valueAlloc(self.arena, value, .{});
    self.status = status;
    self.body = body;
    try self.addHeader("content-type", "application/json; charset=utf-8");
    try self.flush();
}

// ---- Tests ----

test "setStatus" {
    // We can test state mutations without needing a real writer by
    // creating a Response with an undefined writer (we won't call flush).
    var response: Response = .{
        .writer = undefined,
        .arena = std.testing.allocator,
        .keep_alive = true,
        .version = .@"HTTP/1.1",
    };

    try std.testing.expectEqual(http.Status.ok, response.status);
    response.setStatus(.not_found);
    try std.testing.expectEqual(http.Status.not_found, response.status);
}

test "setBody" {
    var response: Response = .{
        .writer = undefined,
        .arena = std.testing.allocator,
        .keep_alive = true,
        .version = .@"HTTP/1.1",
    };

    try std.testing.expectEqualStrings("", response.body);
    response.setBody("Hello, World!");
    try std.testing.expectEqualStrings("Hello, World!", response.body);
}

test "addHeader - single" {
    var response: Response = .{
        .writer = undefined,
        .arena = std.testing.allocator,
        .keep_alive = true,
        .version = .@"HTTP/1.1",
    };

    try response.addHeader("x-custom", "value1");
    try std.testing.expectEqual(@as(usize, 1), response.extra_header_count);
    try std.testing.expectEqualStrings("x-custom", response.extra_header_buf[0].name);
    try std.testing.expectEqualStrings("value1", response.extra_header_buf[0].value);
}

test "addHeader - multiple" {
    var response: Response = .{
        .writer = undefined,
        .arena = std.testing.allocator,
        .keep_alive = true,
        .version = .@"HTTP/1.1",
    };

    try response.addHeader("x-first", "one");
    try response.addHeader("x-second", "two");
    try response.addHeader("x-third", "three");

    try std.testing.expectEqual(@as(usize, 3), response.extra_header_count);
    try std.testing.expectEqualStrings("x-second", response.extra_header_buf[1].name);
    try std.testing.expectEqualStrings("two", response.extra_header_buf[1].value);
}

test "addHeader - overflow" {
    var response: Response = .{
        .writer = undefined,
        .arena = std.testing.allocator,
        .keep_alive = true,
        .version = .@"HTTP/1.1",
    };

    // Fill up all 32 slots
    for (0..max_extra_headers) |_| {
        try response.addHeader("key", "value");
    }

    // 33rd should fail
    const result = response.addHeader("overflow", "fail");
    try std.testing.expectError(error.TooManyHeaders, result);
}

test "default state" {
    var response: Response = .{
        .writer = undefined,
        .arena = std.testing.allocator,
        .keep_alive = true,
        .version = .@"HTTP/1.1",
    };

    try std.testing.expectEqual(http.Status.ok, response.status);
    try std.testing.expectEqualStrings("", response.body);
    try std.testing.expectEqual(@as(usize, 0), response.extra_header_count);
    try std.testing.expect(response.keep_alive);
    try std.testing.expectEqual(http.Version.@"HTTP/1.1", response.version);
}

test "setBodyWithType sets body and adds header" {
    var response: Response = .{
        .writer = undefined,
        .arena = std.testing.allocator,
        .keep_alive = true,
        .version = .@"HTTP/1.1",
    };

    try response.setBodyWithType("<h1>Hi</h1>", "text/html");
    try std.testing.expectEqualStrings("<h1>Hi</h1>", response.body);
    try std.testing.expectEqual(@as(usize, 1), response.extra_header_count);
    try std.testing.expectEqualStrings("content-type", response.extra_header_buf[0].name);
    try std.testing.expectEqualStrings("text/html", response.extra_header_buf[0].value);
}

// ---- JSON serialization tests ----

test "json.Stringify.valueAlloc - simple struct" {
    const gpa = std.testing.allocator;
    const value = .{ .name = "Alice", .age = @as(u32, 30), .active = true };
    const result = try json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30,\"active\":true}", result);
}

test "json.Stringify.valueAlloc - nested struct" {
    const gpa = std.testing.allocator;
    const Inner = struct { x: i32, y: i32 };
    const value = .{ .point = Inner{ .x = 10, .y = 20 }, .label = "origin" };
    const result = try json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"point\":{\"x\":10,\"y\":20},\"label\":\"origin\"}", result);
}

test "json.Stringify.valueAlloc - optional fields" {
    const gpa = std.testing.allocator;
    const Data = struct {
        name: []const u8,
        email: ?[]const u8 = null,
    };
    const value = Data{ .name = "Bob", .email = null };
    const result = try json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"name\":\"Bob\",\"email\":null}", result);
}
