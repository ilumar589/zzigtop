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
});

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

    // Run the accept loop — blocks forever.
    server.run(io);
}

// ============================================================================
// Request Handlers
// ============================================================================

/// GET / — Welcome page
fn handleIndex(_: *http.Request, response: *http.Response) anyerror!void {
    try response.sendText(.ok,
        \\Welcome to the Zig HTTP/1 Server!
        \\
        \\Available routes:
        \\  GET  /           - This page
        \\  GET  /health     - Health check
        \\  GET  /hello/:name - Greeting
        \\  POST /echo       - Echo request body
    );
}

/// GET /health — Health check endpoint
fn handleHealth(_: *http.Request, response: *http.Response) anyerror!void {
    try response.sendJson(.ok, "{\"status\":\"ok\"}");
}

/// GET /hello/:name — Parameterized greeting
fn handleHello(request: *http.Request, response: *http.Response) anyerror!void {
    const name = request.pathParam("name") orelse "world";
    // Allocate on the request arena — freed automatically when request ends.
    const body = try std.fmt.allocPrint(request.arena, "Hello, {s}!\n", .{name});
    try response.sendText(.ok, body);
}

/// POST /echo — Echo the request method and path
fn handleEcho(request: *http.Request, response: *http.Response) anyerror!void {
    const body = try std.fmt.allocPrint(
        request.arena,
        "Method: {s}\nPath: {s}\n",
        .{ @tagName(request.method), request.path },
    );
    try response.sendText(.ok, body);
}
