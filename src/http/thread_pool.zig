//! CPU-bound task pool.
//!
//! Dedicated OS thread pool for offloading CPU-intensive work from
//! the I/O runtime's fibers/threads. Keeps connection handling
//! responsive while heavy computation runs on separate threads.
//!
//! Use cases:
//!   - Password hashing (bcrypt, argon2)
//!   - Data compression / decompression
//!   - Image processing / resizing
//!   - Template rendering
//!   - Cryptographic operations
//!   - Complex data transformations
//!
//! Architecture:
//!
//!   ┌─────────────────┐         ┌──────────────────────┐
//!   │  I/O fiber       │  submit │  CPU Worker Thread   │
//!   │  (handler)       ├───────►│  FixedBufferAlloc    │
//!   │                  │  Queue  │  scratch space       │
//!   │  spin-wait  ◄────┼────────┤  signals completion  │
//!   └─────────────────┘         └──────────────────────┘
//!
//! Each worker gets a FixedBufferAllocator for bounded scratch space,
//! avoiding heap allocation for temporary CPU work buffers. The scratch
//! allocator is reset between tasks — memory doesn't persist across tasks.
//!
//! The pool uses a bounded queue with backpressure. When all CPU workers
//! are busy and the queue is full, submit() blocks the caller until a
//! slot opens (natural backpressure prevents task overload).
//!
//! Graceful shutdown: close the queue → workers finish current task →
//! all threads join → resources freed.

const std = @import("std");
const Io = std.Io;

const CpuPool = @This();

// ============================================================================
// Public types
// ============================================================================

/// A CPU-bound task to execute on a worker thread.
pub const Task = struct {
    /// Work function executed on a CPU worker thread.
    ///
    /// Parameters:
    ///   - `ctx`: Opaque context pointer (caller-owned, must outlive execution).
    ///   - `scratch`: FixedBufferAllocator-backed allocator, reset per task.
    ///                Use for temporary buffers that don't need to outlive the task.
    ///                Returns error.OutOfMemory if scratch space is exhausted.
    run_fn: *const fn (ctx: *anyopaque, scratch: std.mem.Allocator) void,

    /// Opaque context pointer passed to `run_fn`.
    context: *anyopaque,

    /// Optional completion signal.
    ///
    /// When non-null, the worker stores 1 (with release ordering) after
    /// the task completes. The submitter can spin on this value with
    /// acquire ordering to detect completion.
    ///
    /// This is set automatically by `submitAndWait()`. For manual
    /// fire-and-forget usage via `submit()`, leave as null or provide
    /// your own atomic flag.
    completion: ?*std.atomic.Value(u32) = null,
};

/// Pool configuration.
pub const Config = struct {
    /// Number of CPU worker threads.
    /// 0 = auto-detect: max(1, CPU_COUNT / 2).
    ///
    /// Rule of thumb: use half the CPU cores for CPU work, leaving
    /// the other half for I/O runtime threads. This avoids
    /// oversubscription and keeps connection handling responsive.
    num_threads: u32 = 0,

    /// Maximum tasks waiting in the queue before backpressure kicks in.
    /// When full, submit() blocks until a worker finishes a task.
    max_pending: u32 = 256,

    /// Scratch buffer size per worker thread (bytes).
    ///
    /// Each worker gets a FixedBufferAllocator backed by this much memory.
    /// Choose based on the largest temporary allocation your CPU tasks need.
    /// Tasks that exceed this limit receive error.OutOfMemory from the
    /// scratch allocator and should handle it gracefully.
    scratch_size: usize = 64 * 1024, // 64 KB default
};

// ============================================================================
// Internal state
// ============================================================================

/// Heap-allocated shared state. Workers hold a stable *Inner pointer.
const Inner = struct {
    /// Bounded, thread-safe task queue (Io-aware blocking).
    queue: Io.Queue(Task),
    /// Backing buffer for the queue.
    queue_buffer: []Task,
    /// Worker thread handles (for joining on shutdown).
    workers: []std.Thread,
    /// Per-worker scratch buffers (heap-allocated once, reused forever).
    scratch_buffers: [][]u8,
    /// Allocator for freeing resources on shutdown.
    allocator: std.mem.Allocator,
    /// I/O context for queue operations.
    io: Io,
};

/// Pointer to heap-allocated inner state.
inner: *Inner,
/// Allocator used to free Inner on shutdown.
allocator: std.mem.Allocator,

// ============================================================================
// Lifecycle
// ============================================================================

/// Initialize the CPU pool and spawn worker threads.
///
/// Workers start immediately and block on the empty queue.
/// The pool is ready for task submission as soon as init() returns.
pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) !CpuPool {
    // Resolve thread count: 0 = auto (half of CPU cores, minimum 1).
    const num_threads: u32 = if (config.num_threads > 0)
        config.num_threads
    else blk: {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        break :blk @intCast(@max(cpu_count / 2, 1));
    };

    const max_pending = @max(config.max_pending, num_threads);

    // ---- Allocate resources ----

    const queue_buffer = try allocator.alloc(Task, max_pending);
    errdefer allocator.free(queue_buffer);

    const workers = try allocator.alloc(std.Thread, num_threads);
    errdefer allocator.free(workers);

    const scratch_buffers = try allocator.alloc([]u8, num_threads);
    errdefer allocator.free(scratch_buffers);

    // Allocate per-worker scratch buffers.
    var allocated_scratches: u32 = 0;
    errdefer {
        for (scratch_buffers[0..allocated_scratches]) |buf| allocator.free(buf);
    }
    for (scratch_buffers) |*buf| {
        buf.* = try allocator.alloc(u8, config.scratch_size);
        allocated_scratches += 1;
    }

    // Heap-allocate Inner so workers get a stable pointer.
    const inner = try allocator.create(Inner);
    errdefer allocator.destroy(inner);

    inner.* = .{
        .queue = Io.Queue(Task).init(queue_buffer),
        .queue_buffer = queue_buffer,
        .workers = workers,
        .scratch_buffers = scratch_buffers,
        .allocator = allocator,
        .io = io,
    };

    // ---- Spawn worker threads ----

    var spawned: u32 = 0;
    errdefer {
        inner.queue.close(io);
        for (inner.workers[0..spawned]) |w| w.join();
    }

    for (0..num_threads) |i| {
        inner.workers[i] = try std.Thread.spawn(.{}, workerFn, .{ inner, inner.scratch_buffers[i] });
        spawned += 1;
    }

    return .{
        .inner = inner,
        .allocator = allocator,
    };
}

/// Gracefully shut down the pool.
///
/// 1. Closes the queue (unblocks waiting workers with error.Closed)
/// 2. Joins all worker threads (waits for current tasks to finish)
/// 3. Frees all resources (scratch buffers, queue buffer, thread handles)
pub fn shutdown(self: *CpuPool, io: Io) void {
    const inner = self.inner;

    // Signal all workers to stop.
    inner.queue.close(io);

    // Wait for all workers to finish their current task and exit.
    for (inner.workers) |w| w.join();

    // Free resources.
    for (inner.scratch_buffers) |buf| self.allocator.free(buf);
    self.allocator.free(inner.scratch_buffers);
    self.allocator.free(inner.workers);
    self.allocator.free(inner.queue_buffer);
    self.allocator.destroy(inner);
}

// ============================================================================
// Task submission
// ============================================================================

/// Submit a task to the pool.
///
/// If the queue is full, blocks until a worker finishes and frees a slot
/// (backpressure). If the pool is shutting down, the task is not executed
/// but its completion flag is signaled to prevent callers from hanging.
pub fn submit(self: *CpuPool, task: Task) void {
    self.inner.queue.putOneUncancelable(self.inner.io, task) catch {
        // Queue closed (shutting down). Signal completion so caller doesn't hang.
        if (task.completion) |c| c.store(1, .release);
    };
}

/// Submit a task and spin-wait until it completes.
///
/// Creates a stack-local completion flag, submits the task, and spins
/// with `spinLoopHint()` until the worker signals completion.
///
/// Suitable for short CPU tasks (< 10ms). For longer tasks, prefer
/// `submit()` with an explicit completion flag and periodic polling.
///
/// On the threaded I/O backend (Windows), this blocks the calling OS
/// thread. On the evented backend, consider wrapping the call in
/// `io.async()` to avoid blocking the I/O fiber.
pub fn submitAndWait(
    self: *CpuPool,
    run_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    context: *anyopaque,
) void {
    var done: std.atomic.Value(u32) = .init(0);
    self.submit(.{
        .run_fn = run_fn,
        .context = context,
        .completion = &done,
    });
    // Spin-wait with CPU hint to reduce power consumption.
    // Maps to PAUSE (x86) / YIELD (ARM) / WFE (ARM64).
    while (done.load(.acquire) == 0) {
        std.atomic.spinLoopHint();
    }
}

// ============================================================================
// Worker thread
// ============================================================================

/// Worker thread entry point.
///
/// Loops forever pulling tasks from the bounded queue. Each task gets a
/// fresh FixedBufferAllocator over the pre-allocated scratch buffer — the
/// bump pointer resets to zero between tasks, giving every task the full
/// scratch capacity with zero overhead.
///
/// The worker exits when the queue is closed during shutdown.
fn workerFn(inner: *Inner, scratch_buf: []u8) void {
    while (true) {
        // Block until a task is available (or queue is closed → shutdown).
        const task = inner.queue.getOneUncancelable(inner.io) catch {
            // error.Closed → pool is shutting down.
            break;
        };

        // Create a fresh FixedBufferAllocator for this task's scratch space.
        // Re-created each iteration so the bump pointer resets to 0.
        var fba = std.heap.FixedBufferAllocator.init(scratch_buf);

        // Execute the CPU-bound work.
        task.run_fn(task.context, fba.allocator());

        // Signal completion if requested.
        if (task.completion) |c| c.store(1, .release);
    }
}
