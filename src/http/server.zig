//! TCP server with thread-per-connection model.
//!
//! Listens on a TCP port and spawns a new thread for each
//! incoming connection. Each thread runs the connection handler
//! which manages keep-alive, parsing, routing, and response.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const mem = std.mem;

const Router = @import("router.zig");
const Connection = @import("connection.zig");

const Server = @This();

/// Server configuration.
pub const Config = struct {
    /// TCP port to listen on.
    port: u16 = 8080,
    /// Bind address (default: 0.0.0.0 = all interfaces).
    host: [4]u8 = .{ 0, 0, 0, 0 },
    /// Kernel connection backlog.
    backlog: u31 = 128,
    /// Enable SO_REUSEADDR for fast server restarts.
    reuse_address: bool = true,
    /// The router to use for dispatching requests.
    router: *const Router,
};

/// The underlying TCP server.
tcp_server: net.Server,
/// The router for this server.
router: *const Router,
/// Allocator used for per-request arenas and internal allocations.
allocator: std.mem.Allocator,

/// Start listening on the configured address.
///
/// Returns a Server ready for `run()` to be called.
pub fn start(allocator: std.mem.Allocator, io: Io, config: Config) !Server {
    const address: net.IpAddress = .{
        .ip4 = .{
            .bytes = config.host,
            .port = config.port,
        },
    };

    const tcp_server = try net.IpAddress.listen(address, io, .{
        .kernel_backlog = config.backlog,
        .reuse_address = config.reuse_address,
    });

    return .{
        .tcp_server = tcp_server,
        .router = config.router,
        .allocator = allocator,
    };
}

/// Run the accept loop.
///
/// Blocks forever, accepting incoming connections and spawning
/// a new thread for each one. Each thread handles the full
/// lifecycle of that connection (keep-alive, multiple requests).
pub fn run(self: *Server, io: Io) void {
    while (true) {
        // Accept a new connection (blocks until one arrives).
        const stream = self.tcp_server.accept(io) catch |err| {
            switch (err) {
                error.ConnectionAborted => {
                    @branchHint(.unlikely);
                    continue;
                },
                else => {
                    @branchHint(.unlikely);
                    std.debug.print("Accept error: {}\n", .{err});
                    continue;
                },
            }
        };

        // Spawn a detached thread to handle this connection.
        // The thread owns the stream and will close it when done.
        const thread = std.Thread.spawn(.{}, connectionThread, .{
            stream,
            io,
            self.router,
            self.allocator,
        }) catch |err| {
            @branchHint(.unlikely);
            std.debug.print("Thread spawn error: {}\n", .{err});
            stream.close(io);
            continue;
        };

        // Detach — we don't join connection threads.
        thread.detach();
    }
}

/// Entry point for a connection-handling thread.
fn connectionThread(stream: net.Stream, io: Io, router: *const Router, allocator: std.mem.Allocator) void {
    Connection.handle(allocator, stream, io, router);
}

/// Clean up server resources.
pub fn deinit(self: *Server, io: Io) void {
    self.tcp_server.deinit(io);
}
