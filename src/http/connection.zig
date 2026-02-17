//! Per-connection HTTP handler.
//!
//! Manages the lifecycle of a single TCP connection:
//! - Buffered I/O with stack-allocated buffers
//! - HTTP/1.1 keep-alive loop (multiple requests per connection)
//! - Per-connection arena reset between requests (O(1) via retain_capacity)
//! - Delegates to std.http.Server for protocol parsing
//! - Async-compatible: works with Io.Group for work-stealing dispatch
//!
//! Architecture:
//!   Each accepted connection is spawned as an async task via Io.Group.
//!   On the Evented backend (Linux io_uring / macOS kqueue), this runs as
//!   a stackful fiber with automatic work-stealing between OS threads.
//!   On the Threaded backend (Windows / fallback), it runs on a dynamically
//!   managed pooled thread (lazy spawn, up to CPU_COUNT-1 threads).

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

/// Handle a connection as an async task (compatible with Io.Group).
///
/// This is the entry point for the async dispatch model. Each accepted
/// connection is spawned as a task via `group.async(io, handleAsync, .{...})`.
///
/// Creates a per-connection arena (fiber-safe — no thread-local state).
/// On evented backends, fibers may migrate between OS threads via
/// work-stealing, so thread-local arenas would be unsound.
/// The arena is reset with `.retain_capacity` between requests for
/// O(1) memory reuse without syscalls.
///
/// The `Io.Cancelable!void` return type allows the Io.Group to request
/// cancellation during graceful shutdown.
pub fn handleAsync(
    stream: Io.net.Stream,
    io: Io,
    router: *const Router,
    allocator: std.mem.Allocator,
) Io.Cancelable!void {
    defer stream.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    handleInner(&arena_state, stream, io, router);
}

/// Synchronous entry point — for direct use without Io.Group.
///
/// Takes a pre-existing arena (caller-owned) and handles the
/// connection lifecycle. Used by the legacy thread pool path.
pub fn handle(
    arena_state: *std.heap.ArenaAllocator,
    stream: Io.net.Stream,
    io: Io,
    router: *const Router,
) void {
    defer stream.close(io);
    handleInner(arena_state, stream, io, router);
}

/// Core keep-alive loop (shared by async and sync entry points).
///
/// 1. Creates buffered reader/writer over the TCP stream
/// 2. Initializes std.http.Server for protocol parsing
/// 3. Loops over requests (keep-alive)
/// 4. For each request: resets arena, routes to handler, sends response
/// 5. Returns when connection closes or keep-alive ends
///
/// All I/O buffers are stack-allocated for maximum performance.
fn handleInner(
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

        // ---- Reset per-connection arena for this request ----
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
