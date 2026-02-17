//! *** SUPERSEDED — kept for reference ***
//!
//! This fixed-size thread pool has been replaced by Io.Group async dispatch
//! in server.zig. The new approach uses Zig's built-in Io runtime:
//!   - Evented backend: stackful fibers + work-stealing
//!   - Threaded backend: dynamic thread pool (lazy spawn)
//!
//! The code below is preserved as a reference for manual thread pool
//! implementation using Io.Queue(T) and std.Thread.
//!
//! -----------------------------------------------------------------------
//!
//! Fixed-size thread pool for connection handling.
//!
//! Instead of spawning a new OS thread per connection (which is expensive
//! and limits scalability), this pool pre-spawns a configurable number of
//! worker threads that pull connections from a bounded, thread-safe queue.
//!
//! Features:
//! - Configurable worker count (defaults to CPU count)
//! - Bounded connection queue with backpressure (when full, accept blocks)
//! - Graceful shutdown via queue close
//! - Workers handle keep-alive internally (many requests per connection)
//!
//! The inner state is heap-allocated so worker threads always hold a
//! stable pointer, even when the outer handle is returned by value.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Connection = @import("connection.zig");
const Router = @import("router.zig");

const ThreadPool = @This();

/// A pending connection job for a worker to handle.
const Job = struct {
    stream: net.Stream,
};

/// Thread pool configuration.
pub const Config = struct {
    /// Number of worker threads. 0 = auto-detect (CPU count).
    num_threads: u32 = 0,
    /// Maximum connections waiting in the queue.
    /// When full, the accept loop blocks (backpressure).
    max_pending: u32 = 128,
};

/// Heap-allocated inner state. Worker threads hold a stable *Inner pointer.
const Inner = struct {
    /// The bounded, thread-safe connection queue.
    queue: Io.Queue(Job),
    /// Backing buffer for the queue.
    queue_buffer: []Job,
    /// Worker thread handles (for joining on shutdown).
    workers: []std.Thread,
    /// The router shared by all workers.
    router: *const Router,
    /// Allocator for per-request arenas.
    allocator: std.mem.Allocator,
    /// I/O context shared across threads.
    io: Io,
};

/// Pointer to the heap-allocated inner state.
inner: *Inner,
/// Allocator used to free the Inner on shutdown.
allocator: std.mem.Allocator,

/// Initialize the thread pool and spawn worker threads.
///
/// The inner state is heap-allocated so that worker threads receive a
/// pointer that remains valid even when the ThreadPool handle is
/// returned by value from a function.
pub fn init(
    allocator: std.mem.Allocator,
    io: Io,
    router: *const Router,
    config: Config,
) !ThreadPool {
    // Resolve thread count: 0 = CPU count, minimum 1.
    const num_threads: u32 = if (config.num_threads > 0)
        config.num_threads
    else blk: {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        break :blk @intCast(@max(cpu_count, 1));
    };

    const max_pending = @max(config.max_pending, num_threads);

    // Allocate the queue backing buffer.
    const queue_buffer = try allocator.alloc(Job, max_pending);
    errdefer allocator.free(queue_buffer);

    // Allocate thread handle array.
    const workers = try allocator.alloc(std.Thread, num_threads);
    errdefer allocator.free(workers);

    // Heap-allocate the inner state so that &inner is stable.
    const inner = try allocator.create(Inner);
    errdefer allocator.destroy(inner);

    inner.* = .{
        .queue = Io.Queue(Job).init(queue_buffer),
        .queue_buffer = queue_buffer,
        .workers = workers,
        .router = router,
        .allocator = allocator,
        .io = io,
    };

    // Spawn worker threads — they receive *Inner which is heap-stable.
    var spawned: u32 = 0;
    errdefer {
        inner.queue.close(io);
        for (inner.workers[0..spawned]) |w| w.join();
    }

    for (inner.workers) |*w| {
        w.* = try std.Thread.spawn(.{}, workerFn, .{inner});
        spawned += 1;
    }

    return .{
        .inner = inner,
        .allocator = allocator,
    };
}

/// Submit a new connection (stream) to the pool.
///
/// If the queue is full, this blocks until a worker finishes a previous
/// connection and takes from the queue (backpressure on the accept loop).
pub fn submit(self: *ThreadPool, stream: net.Stream) void {
    self.inner.queue.putOneUncancelable(self.inner.io, .{ .stream = stream }) catch {
        // Queue is closed (shutting down) — close the stream.
        stream.close(self.inner.io);
    };
}

/// Gracefully shut down the pool.
///
/// Closes the queue (unblocking all waiting workers), then joins
/// all worker threads.
pub fn shutdown(self: *ThreadPool, io: Io) void {
    const inner = self.inner;

    // Signal all workers to stop.
    inner.queue.close(io);

    // Wait for all workers to finish their current connection and exit.
    for (inner.workers) |w| w.join();

    // Free resources.
    self.allocator.free(inner.workers);
    self.allocator.free(inner.queue_buffer);
    self.allocator.destroy(inner);
}

/// Worker thread entry point.
///
/// Each worker owns a persistent ArenaAllocator that is reset between
/// requests (O(1) with `.retain_capacity`), avoiding repeated heap
/// alloc/free through the backing allocator.
///
/// The worker loops forever, pulling connections from the queue and
/// handling them (including the keep-alive request loop). The worker
/// exits when the queue is closed during shutdown.
fn workerFn(inner: *Inner) void {
    // Thread-local arena — lives for the entire lifetime of this worker.
    // `.retain_capacity` reset between requests reuses memory without syscalls.
    var arena_state: std.heap.ArenaAllocator = .init(inner.allocator);
    defer arena_state.deinit();

    while (true) {
        // Block until a connection is available (or queue is closed).
        const job = inner.queue.getOneUncancelable(inner.io) catch {
            // error.Closed → pool is shutting down.
            break;
        };

        // Handle the full lifecycle of this connection.
        // Connection.handle runs the keep-alive loop internally,
        // so one connection may serve many HTTP requests.
        // The arena is reset (not freed) between each request inside handle().
        Connection.handle(&arena_state, job.stream, inner.io, inner.router);
    }
}
