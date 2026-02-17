//! Async TCP server with Io.Group work-stealing dispatch.
//!
//! Listens on a TCP port and dispatches incoming connections via
//! Io.Group.async() — each connection becomes an async task managed
//! by the Io runtime:
//!
//!   - Evented backend (Linux io_uring / macOS kqueue):
//!     Stackful fibers with automatic work-stealing across OS threads.
//!     Thousands of concurrent connections on a handful of threads.
//!
//!   - Threaded backend (Windows / fallback):
//!     Dynamic thread pool — threads spawned lazily up to CPU_COUNT-1.
//!     When all threads are busy, new tasks run inline on the accept
//!     thread (natural backpressure).
//!
//! No manual thread pool sizing needed — the Io runtime auto-scales.

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
/// Allocator used for per-connection arenas.
allocator: std.mem.Allocator,

/// Start listening on the configured address.
///
/// Returns a Server ready for `run()` to be called.
/// No threads are spawned here — the Io runtime manages worker
/// threads/fibers on demand when connections arrive.
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

/// Run the accept loop with async dispatch.
///
/// Each accepted connection is spawned as an async task via
/// Io.Group.async(). The Io runtime schedules these tasks across
/// its worker threads/fibers:
///
///   - On evented backends: fibers yield on I/O, enabling one OS
///     thread to multiplex many connections. Work-stealing balances
///     load across threads.
///
///   - On the threaded backend: tasks run on pooled threads. When
///     all threads are busy, tasks run inline on the accept thread
///     (backpressure).
///
/// Blocks forever. The deferred group.cancel() runs only on
/// abnormal exit, ensuring in-flight connections are cleaned up.
pub fn run(self: *Server, io: Io) void {
    var group: Io.Group = .init;
    defer group.cancel(io);

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

        // Spawn an async task for this connection.
        // The Io runtime decides whether to run it on a fiber,
        // a pooled thread, or inline (if resources exhausted).
        group.async(io, Connection.handleAsync, .{ stream, io, self.router, self.allocator });
    }
}

/// Clean up server resources.
pub fn deinit(self: *Server, io: Io) void {
    self.tcp_server.deinit(io);
}
