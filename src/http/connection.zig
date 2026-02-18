//! Per-connection HTTP handler.
//!
//! Manages the lifecycle of a single TCP connection:
//! - Buffered I/O with stack-allocated buffers
//! - HTTP/1.1 keep-alive loop (multiple requests per connection)
//! - Per-connection arena reset between requests (O(1) via retain_capacity)
//! - Idle timeout: io.select() races receiveHead vs sleep (Kotlin withTimeout)
//! - Request timeout: io.select() races handler vs deadline
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
const Server = @import("server.zig");

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
    idle_timeout_s: u32,
    request_timeout_s: u32,
    stats: ?*Server.Stats,
) Io.Cancelable!void {
    defer stream.close(io);
    // Track active connections.
    if (stats) |s| _ = s.active_connections.fetchAdd(1, .monotonic);
    defer if (stats) |s| {
        _ = s.active_connections.fetchSub(1, .monotonic);
    };

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    handleInner(&arena_state, stream, io, router, idle_timeout_s, request_timeout_s, stats);
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
    idle_timeout_s: u32,
    request_timeout_s: u32,
) void {
    defer stream.close(io);
    handleInner(arena_state, stream, io, router, idle_timeout_s, request_timeout_s, null);
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
    idle_timeout_s: u32,
    request_timeout_s: u32,
    stats: ?*Server.Stats,
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
        // Receive and parse the HTTP request head, with idle timeout.
        // Returns null on timeout, connection close, parse error, or cancel.
        var http_request = receiveWithTimeout(
            &http_server,
            io,
            idle_timeout_s,
            &stream_writer.interface,
        ) orelse break;

        // Count this request in server stats.
        if (stats) |s| _ = s.total_requests.fetchAdd(1, .monotonic);

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

            // Call the handler with optional request timeout.
            switch (dispatchHandler(
                match.handler,
                &request,
                &response,
                &http_request,
                io,
                request_timeout_s,
                &stream_writer.interface,
            )) {
                .ok => {},
                .handler_error => {
                    if (!request.keep_alive) break;
                    continue;
                },
                .timeout, .canceled => break,
            }
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

// ============================================================================
// Structured concurrency helpers
// ============================================================================

/// Sleep for the given number of seconds — compatible with io.async().
/// Used for both idle timeout (11b-2) and request timeout (11b-3).
fn sleepSeconds(io: Io, timeout_s: u32) Io.Cancelable!void {
    return io.sleep(Io.Duration.fromSeconds(@as(i64, timeout_s)), .awake);
}

/// Wrapper for http.Server.receiveHead() — compatible with io.async().
/// Runs as a concurrent task that yields on I/O.
fn receiveHeadAsync(server: *http.Server) http.Server.ReceiveHeadError!http.Server.Request {
    return server.receiveHead();
}

/// Call a handler function pointer — compatible with io.async().
/// Wraps the dynamic dispatch so it can be raced against a timeout.
fn callHandlerWrapper(
    handler: Router.HandlerFn,
    request: *Request,
    response: *Response,
    io: Io,
) anyerror!void {
    return handler(request, response, io);
}

/// Result of handler dispatch (with optional timeout).
const DispatchResult = enum {
    /// Handler completed successfully.
    ok,
    /// Handler returned an error (500 already sent).
    handler_error,
    /// Handler timed out (503 already sent).
    timeout,
    /// Canceled by server shutdown.
    canceled,
};

/// Call the matched handler with optional request timeout.
///
/// When `request_timeout_s > 0`, races the handler against a deadline
/// using `io.select()` — the Zig equivalent of Kotlin's:
///   `withTimeout(10.seconds) { handler(request, response) }`
///
/// On timeout: cancels the handler, sends 503 with CancelProtection
/// (ensures the error response is written even during shutdown).
fn dispatchHandler(
    handler: Router.HandlerFn,
    request: *Request,
    response: *Response,
    http_request: *http.Server.Request,
    io: Io,
    request_timeout_s: u32,
    error_writer: *Io.Writer,
) DispatchResult {
    // Fast path: no timeout — direct call.
    if (request_timeout_s == 0) {
        handler(request, response, io) catch {
            sendInternalError(http_request) catch {};
            return .handler_error;
        };
        return .ok;
    }

    // Race handler against request timeout using io.select().
    // Zig equivalent of Kotlin's: withTimeout(10.seconds) { handler(req, res) }
    var handler_future = io.async(callHandlerWrapper, .{ handler, request, response, io });
    var deadline_future = io.async(sleepSeconds, .{ io, request_timeout_s });

    const selected = io.select(.{ .ok = &handler_future, .timeout = &deadline_future }) catch {
        // error.Canceled — server shutdown in progress.
        handler_future.cancel(io) catch {};
        deadline_future.cancel(io) catch {};
        return .canceled;
    };

    switch (selected) {
        .ok => |result| {
            // Handler completed before timeout — cancel the deadline.
            deadline_future.cancel(io) catch {};
            result catch {
                sendInternalError(http_request) catch {};
                return .handler_error;
            };
            return .ok;
        },
        .timeout => {
            // Handler took too long — cancel it and send 503.
            handler_future.cancel(io) catch {};
            // CancelProtection: ensure the 503 response is written completely
            // even if a server shutdown cancel arrives during the write.
            // Equivalent to Kotlin's withContext(NonCancellable) { ... }
            const old = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(old);
            sendErrorResponse(error_writer, .service_unavailable, "Request Timeout") catch {};
            return .timeout;
        },
    }
}

/// Receive the next HTTP request head with optional idle timeout.
///
/// Uses `io.select()` to race `receiveHead()` against `io.sleep()`,
/// equivalent to Kotlin's `withTimeout(30.seconds) { receiveHead() }`.
///
///   - On success: returns the parsed request.
///   - On idle timeout: returns null (connection was idle too long).
///   - On parse error: sends 400, returns null.
///   - On connection close: returns null.
///   - On cancel (shutdown): returns null.
fn receiveWithTimeout(
    http_server: *http.Server,
    io: Io,
    idle_timeout_s: u32,
    error_writer: *Io.Writer,
) ?http.Server.Request {
    // Fast path: no timeout configured — direct call.
    if (idle_timeout_s == 0) {
        return http_server.receiveHead() catch |err| {
            if (err == error.HttpHeadersInvalid) {
                @branchHint(.unlikely);
                sendErrorResponse(error_writer, .bad_request, "Bad Request") catch {};
            }
            return null;
        };
    }

    // Race receiveHead() against idle timeout using io.select().
    // This is the Zig equivalent of Kotlin's:
    //   withTimeout(30.seconds) { receiveHead() }
    var read_future = io.async(receiveHeadAsync, .{http_server});
    var sleep_future = io.async(sleepSeconds, .{ io, idle_timeout_s });

    const selected = io.select(.{ .request = &read_future, .timeout = &sleep_future }) catch {
        // error.Canceled — server shutdown in progress.
        // Cancel both futures and wait for them to complete.
        if (read_future.cancel(io)) |_| {} else |_| {}
        sleep_future.cancel(io) catch {};
        return null;
    };

    switch (selected) {
        .request => |result| {
            // Request arrived before timeout — cancel the idle timer.
            sleep_future.cancel(io) catch {};
            return result catch |err| {
                if (err == error.HttpHeadersInvalid) {
                    @branchHint(.unlikely);
                    sendErrorResponse(error_writer, .bad_request, "Bad Request") catch {};
                }
                return null;
            };
        },
        .timeout => {
            // Idle timeout fired — cancel the pending read and close.
            if (read_future.cancel(io)) |_| {} else |_| {}
            return null;
        },
    }
}
