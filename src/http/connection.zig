//! Per-connection HTTP handler.
//!
//! Manages the lifecycle of a single TCP connection:
//! - Buffered I/O with stack-allocated buffers
//! - HTTP/1.1 keep-alive loop (multiple requests per connection)
//! - Thread-local arena reset between requests (O(1) via retain_capacity)
//! - Delegates to std.http.Server for protocol parsing

const std = @import("std");
const http = std.http;
const mem = std.mem;
const Io = std.Io;

const Request = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("router.zig");

const Connection = @This();

/// Connection configuration.
pub const Config = struct {
    /// Size of the read buffer (must hold entire HTTP header).
    read_buffer_size: usize = 8192,
    /// Size of the write buffer for response output.
    write_buffer_size: usize = 8192,
};

/// Handle a single connection's lifetime.
///
/// This function:
/// 1. Creates buffered reader/writer over the TCP stream
/// 2. Initializes std.http.Server for protocol parsing
/// 3. Loops over requests (keep-alive)
/// 4. For each request: resets thread arena, routes to handler, sends response
/// 5. Cleans up when connection closes
///
/// The arena is owned by the worker thread and reset between requests
/// with `.retain_capacity` — an O(1) operation that reuses existing
/// memory without touching the backing allocator.
///
/// All I/O buffers are stack-allocated for maximum performance.
pub fn handle(
    arena_state: *std.heap.ArenaAllocator,
    stream: Io.net.Stream,
    io: Io,
    router: *const Router,
) void {
    // Stack-allocated I/O buffers — no heap allocation for connection I/O.
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;

    // Create buffered reader/writer over the TCP stream.
    var stream_reader = stream.reader(io, &read_buffer);
    var stream_writer = stream.writer(io, &write_buffer);

    // Initialize the HTTP/1 protocol handler.
    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    // ---- Keep-alive request loop ----
    while (true) {
        // Receive and parse the HTTP request head.
        var http_request = http_server.receiveHead() catch |err| {
            switch (err) {
                error.HttpHeadersInvalid => {
                    @branchHint(.unlikely);
                    // Send 400 Bad Request
                    sendErrorResponse(&stream_writer.interface, .bad_request, "Bad Request") catch {};
                },
                // Connection closed or read error — just exit the loop
                else => {},
            }
            break;
        };

        // ---- Reset thread-local arena for this request ----
        // retain_capacity keeps the underlying memory pages allocated,
        // just resets the bump pointer. Future allocations reuse the
        // same memory without any syscalls. Over time the arena converges
        // to a single chunk that fits all request data.
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();

        // Build our Request wrapper.
        var request = Request.fromHttpHead(
            http_request.head,
            http_request.head_buffer,
            arena,
        );

        // ---- Route dispatch ----
        if (router.dispatch(request.method, request.path, arena)) |match| {
            // Set path parameters from route matching.
            request.params = match.params;

            // Build response object.
            var response = Response.init(
                &stream_writer.interface,
                arena,
                request.keep_alive,
                request.version,
            );

            // Call the handler.
            match.handler(&request, &response) catch {
                // Handler returned an error — send 500.
                sendInternalError(&http_request) catch {};
                if (!request.keep_alive) break;
                continue;
            };

            // If handler didn't flush, flush now.
            // (Handler may have already called response.flush() or sendText())
        } else {
            // No route matched — 404 Not Found.
            http_request.respond("Not Found", .{
                .status = .not_found,
                .keep_alive = request.keep_alive,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                },
            }) catch {};
        }

        // If client doesn't want keep-alive, we're done.
        if (!request.keep_alive) break;
    }

    // Close the TCP stream.
    stream.close(io);
}

/// Send a simple error response when we don't have a full HTTP request context.
fn sendErrorResponse(
    writer: *Io.Writer,
    status: http.Status,
    body: []const u8,
) !void {
    const phrase = status.phrase() orelse "Error";
    try writer.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(status), phrase });
    try writer.writeAll("connection: close\r\n");
    try writer.print("content-length: {d}\r\n", .{body.len});
    try writer.writeAll("content-type: text/plain\r\n\r\n");
    try writer.writeAll(body);
    try writer.flush();
}

/// Send a 500 Internal Server Error using the HTTP server's respond method.
fn sendInternalError(http_request: *http.Server.Request) !void {
    try http_request.respond("Internal Server Error", .{
        .status = .internal_server_error,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        },
    });
}
