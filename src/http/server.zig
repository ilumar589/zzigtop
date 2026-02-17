//! TCP server with configurable thread pool.
//!
//! Listens on a TCP port and dispatches incoming connections to a
//! fixed-size thread pool. Each worker thread handles the full
//! lifecycle of a connection (keep-alive, parsing, routing, response).
//! This avoids the cost of spawning a new OS thread per connection.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const mem = std.mem;

const Router = @import("router.zig");
const Connection = @import("connection.zig");
const ThreadPool = @import("thread_pool.zig");

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
    /// Number of worker threads. 0 = auto-detect (CPU count).
    thread_pool_size: u32 = 0,
    /// Maximum connections waiting in the thread pool queue.
    max_pending_connections: u32 = 128,
};

/// The underlying TCP server.
tcp_server: net.Server,
/// The router for this server.
router: *const Router,
/// Allocator used for per-request arenas and internal allocations.
allocator: std.mem.Allocator,
/// Thread pool for handling connections.
pool: ThreadPool,

/// Start listening on the configured address.
///
/// Returns a Server ready for `run()` to be called.
/// Spawns worker threads immediately.
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

    var server: Server = .{
        .tcp_server = tcp_server,
        .router = config.router,
        .allocator = allocator,
        .pool = undefined,
    };

    server.pool = try ThreadPool.init(allocator, io, config.router, .{
        .num_threads = config.thread_pool_size,
        .max_pending = config.max_pending_connections,
    });

    return server;
}

/// Run the accept loop.
///
/// Blocks forever, accepting incoming connections and submitting
/// them to the thread pool for handling. If the pool queue is full,
/// the accept loop blocks until a worker becomes available
/// (natural backpressure).
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

        // Submit to the thread pool (blocks if queue is full).
        self.pool.submit(stream);
    }
}

/// Clean up server resources.
pub fn deinit(self: *Server, io: Io) void {
    self.pool.shutdown(io);
    self.tcp_server.deinit(io);
}
