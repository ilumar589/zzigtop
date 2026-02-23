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
const Static = @import("static.zig");

const Server = @This();

/// Atomic server statistics — safe for cross-fiber/cross-thread access.
///
/// All counters use relaxed ordering since they are purely informational
/// (no happens-before relationships required for correctness).
pub const Stats = struct {
    /// Number of currently active connections.
    active_connections: std.atomic.Value(u64) = .init(0),
    /// Total number of HTTP requests processed since server start.
    total_requests: std.atomic.Value(u64) = .init(0),
    /// Total number of connections accepted since server start.
    total_connections: std.atomic.Value(u64) = .init(0),
};

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
    /// Idle timeout between requests on a keep-alive connection (seconds).
    /// When a connection is idle for this long, it is closed to free resources.
    /// 0 = no timeout (wait indefinitely). Default: 30s.
    idle_timeout_s: u32 = 30,
    /// Maximum time for a handler to complete a request (seconds).
    /// If a handler exceeds this, it is canceled and a 503 is sent.
    /// 0 = no timeout. Default: 10s.
    request_timeout_s: u32 = 10,
    /// Interval for metrics reporter logging (seconds).
    /// 0 = disable metrics reporter. Default: 10s.
    metrics_interval_s: u32 = 10,
    /// Static file serving configuration.
    /// When set, unmatched routes fall back to serving files from this directory.
    /// null = disable static file serving (unmatched routes return 404).
    static_config: ?Static.Config = null,
};

/// The underlying TCP server.
tcp_server: net.Server,
/// The router for this server.
router: *const Router,
/// Allocator used for per-connection arenas.
allocator: std.mem.Allocator,
/// Idle timeout in seconds (0 = no timeout).
idle_timeout_s: u32,
/// Request timeout in seconds (0 = no timeout).
request_timeout_s: u32,
/// Metrics reporter interval in seconds (0 = disabled).
metrics_interval_s: u32,
/// Static file serving configuration (null = disabled).
static_config: ?Static.Config,
/// Atomic server statistics (shared with connections).
stats: Stats = .{},

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
        .idle_timeout_s = config.idle_timeout_s,
        .request_timeout_s = config.request_timeout_s,
        .metrics_interval_s = config.metrics_interval_s,
        .static_config = config.static_config,
    };
}

/// Run the accept loop with async dispatch and graceful shutdown.
///
/// Each accepted connection is spawned as an async task via
/// Io.Group.async(). The Io runtime schedules these tasks across
/// its worker threads/fibers.
///
/// **Graceful shutdown:** When the caller cancels the Future returned
/// by `io.async(server.run, ...)`, the accept loop receives
/// `error.Canceled` and stops accepting new connections. The deferred
/// `group.cancel(io)` then cancels all in-flight connections. Each
/// connection uses `CancelProtection` to finish writing its current
/// response before closing. `group.cancel()` awaits all children,
/// so `run()` returns only after all connections have drained.
///
/// This is the Zig equivalent of Kotlin's:
///   `scope.cancel()` + `scope.join()` — all children are guaranteed
///   complete when the scope exits.
pub fn run(self: *Server, io: Io) Io.Cancelable!void {
    var group: Io.Group = .init;
    defer group.cancel(io); // ← structured: cancel + await all children

    // Spawn background metrics reporter (if enabled).
    if (self.metrics_interval_s > 0) {
        group.async(io, metricsReporter, .{ io, &self.stats, self.metrics_interval_s });
    }

    while (true) {
        // Accept a new connection (blocks until one arrives).
        const stream = self.tcp_server.accept(io) catch |err| {
            switch (err) {
                error.Canceled => {
                    // Shutdown signal received — stop accepting.
                    // Deferred group.cancel() will drain in-flight connections.
                    break;
                },
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
        _ = self.stats.total_connections.fetchAdd(1, .monotonic);
        group.async(io, Connection.handleAsync, .{ stream, io, self.router, self.allocator, self.idle_timeout_s, self.request_timeout_s, &self.stats, self.static_config });
    }

    // At this point, the accept loop has exited (shutdown requested).
    // The deferred group.cancel(io) runs, which:
    // 1. Sends error.Canceled to all in-flight connection tasks
    // 2. Awaits all tasks to complete (they finish writing current responses)
    // 3. Returns — all connections are drained, server is clean
}

/// Background metrics reporter — periodically logs server statistics.
///
/// Runs as a child of the server's Io.Group scope. Automatically
/// canceled during graceful shutdown when group.cancel() is called.
/// This is the Zig equivalent of Kotlin's:
///   `launch { while(isActive) { delay(10.seconds); logMetrics() } }`
fn metricsReporter(io: Io, stats: *Stats, interval_s: u32) Io.Cancelable!void {
    while (true) {
        try io.sleep(Io.Duration.fromSeconds(@as(i64, interval_s)), .awake);
        const active = stats.active_connections.load(.monotonic);
        const total_req = stats.total_requests.load(.monotonic);
        const total_conn = stats.total_connections.load(.monotonic);
        std.debug.print("[metrics] active_connections={d} total_requests={d} total_connections={d}\n", .{ active, total_req, total_conn });
    }
}

/// Clean up server resources.
pub fn deinit(self: *Server, io: Io) void {
    self.tcp_server.deinit(io);
}
