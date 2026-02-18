//! High-Performance HTTP/1 Server — Entry Point
//!
//! Usage:
//!   zig build run-server                             # Debug, port 8080
//!   zig build run-server -Doptimize=ReleaseFast      # Max performance
//!   zig build run-server -- --port 3000               # Custom port

const std = @import("std");
const http = @import("learn_zig").http;

/// Comptime-defined routes — compiled into an optimized match table.
const router = http.Router.init(.{
    .{ .GET, "/", handleIndex },
    .{ .GET, "/health", handleHealth },
    .{ .GET, "/hello/:name", handleHello },
    .{ .POST, "/echo", handleEcho },
    .{ .GET, "/dashboard/:id", handleDashboard },
    .{ .GET, "/metrics", handleMetrics },
});

/// Module-level pointer to server stats (set once during startup).
/// Used by the `/metrics` handler to read atomic counters.
var server_stats: ?*http.Server.Stats = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    // ---- Parse command line arguments ----
    var port: u16 = 8080;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
            i += 1;
        }
    }

    // ---- Start server ----
    std.debug.print(
        \\
        \\  +--------------------------------------------+
        \\  |   Zig HTTP/1 Server                        |
        \\  |   Listening on http://127.0.0.1:{d:<5}      |
        \\  |   Async I/O pool (auto-scaled)             |
        \\  |   Press Ctrl+C to stop                     |
        \\  +--------------------------------------------+
        \\
        \\
    , .{port});

    var server = try http.Server.start(init.gpa, io, .{
        .port = port,
        .router = &router,
        .reuse_address = true,
    });
    defer server.deinit(io);
    server_stats = &server.stats;

    // Run the accept loop — returns when shutdown is requested.
    // On graceful shutdown, run() returns error.Canceled.
    server.run(io) catch |err| switch (err) {
        error.Canceled => {
            std.debug.print("\nServer shutting down gracefully...\n", .{});
        },
    };
}

// ============================================================================
// Request Handlers
// ============================================================================

/// GET / — Welcome page
fn handleIndex(_: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    try response.sendText(.ok,
        \\Welcome to the Zig HTTP/1 Server!
        \\
        \\Available routes:
        \\  GET  /               - This page
        \\  GET  /health         - Health check
        \\  GET  /hello/:name    - Greeting
        \\  POST /echo           - Echo request
        \\  GET  /dashboard/:id  - Concurrent fan-out demo
        \\  GET  /metrics        - Server statistics (JSON)
    );
}

/// GET /health — Health check endpoint
fn handleHealth(_: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    try response.sendJson(.ok, "{\"status\":\"ok\"}");
}

/// GET /hello/:name — Parameterized greeting
fn handleHello(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const name = request.pathParam("name") orelse "world";
    // Allocate on the request arena — freed automatically when request ends.
    const body = try std.fmt.allocPrint(request.arena, "Hello, {s}!\n", .{name});
    try response.sendText(.ok, body);
}

/// POST /echo — Echo the request method and path
fn handleEcho(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const body = try std.fmt.allocPrint(
        request.arena,
        "Method: {s}\nPath: {s}\n",
        .{ @tagName(request.method), request.path },
    );
    try response.sendText(.ok, body);
}

// ============================================================================
// Structured Concurrency Demo (11b-5)
// ============================================================================

/// Simulated async data fetch — represents a database or API call.
/// Runs as a concurrent task via io.async().
fn fetchProfile(io: std.Io, user_id: []const u8, arena: std.mem.Allocator) anyerror![]const u8 {
    // Simulate network latency
    io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    return try std.fmt.allocPrint(arena, "User({s})", .{user_id});
}

/// Simulated async notification count fetch.
fn fetchNotifications(io: std.Io, user_id: []const u8, arena: std.mem.Allocator) anyerror![]const u8 {
    // Simulate network latency
    io.sleep(std.Io.Duration.fromMilliseconds(3), .awake) catch {};
    return try std.fmt.allocPrint(arena, "notifications({s})=7", .{user_id});
}

/// GET /dashboard/:id — Fan-out concurrency demo.
///
/// Demonstrates the structured concurrency pattern:
///   1. Spawn two concurrent sub-tasks (fetchProfile + fetchNotifications)
///   2. Await both results (fan-in)
///   3. Combine and respond
///
/// This is the Zig equivalent of Kotlin's:
///   coroutineScope {
///       val profile = async { fetchProfile(userId) }
///       val notifs  = async { fetchNotifications(userId) }
///       render(profile.await(), notifs.await())
///   }
///
/// Both sub-tasks are bounded by this handler's lifetime. If the handler
/// is canceled (request timeout or shutdown), sub-task futures are
/// automatically cleaned up via `.cancel()`.
fn handleDashboard(request: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    const user_id = request.pathParam("id") orelse "anonymous";

    // Fan-out: spawn two concurrent sub-tasks.
    var profile_future = io.async(fetchProfile, .{ io, user_id, request.arena });
    var notifs_future = io.async(fetchNotifications, .{ io, user_id, request.arena });

    // Fan-in: await both results. Order doesn't matter — both run concurrently.
    // If either task errors, we still cancel the other to avoid leaking.
    const profile = profile_future.await(io) catch |err| {
        if (notifs_future.cancel(io)) |_| {} else |_| {}
        return err;
    };
    const notifs = notifs_future.await(io) catch |err| {
        return err;
    };

    const body = try std.fmt.allocPrint(
        request.arena,
        "Dashboard for {s}\n  Profile: {s}\n  {s}\n",
        .{ user_id, profile, notifs },
    );
    try response.sendText(.ok, body);
}

// ============================================================================
// Metrics Endpoint (11b-6)
// ============================================================================

/// GET /metrics — Server statistics as JSON.
///
/// Reads atomic counters from the server's Stats struct.
/// Safe to call from any fiber — all counters use relaxed atomics.
fn handleMetrics(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const stats = server_stats orelse {
        try response.sendText(.service_unavailable, "Stats not available");
        return;
    };

    const active = stats.active_connections.load(.monotonic);
    const total_req = stats.total_requests.load(.monotonic);
    const total_conn = stats.total_connections.load(.monotonic);

    const body = try std.fmt.allocPrint(
        request.arena,
        \\{{"active_connections":{d},"total_requests":{d},"total_connections":{d}}}
    ,
        .{ active, total_req, total_conn },
    );

    try response.sendJson(.ok, body);
}
