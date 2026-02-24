# Performance Techniques Reference

This document details every performance optimization used in the HTTP/1 server,
explaining what each technique does, why it matters, and how it's implemented in Zig.

## Benchmark Results

Measured with **wrk** (compiled from source) using HTTP pipelining (16-depth),
running on Docker Desktop with 16 CPU cores. Server built with ReleaseFast on
Alpine Linux.

| Test | Connections | Requests/sec | Avg Latency |
|------|-------------|-------------:|-------------|
| **Plaintext pipelined** | 16 | **2,463,200** | 82 μs |
| Plaintext pipelined | 128 | 950,993 | — |
| Plaintext pipelined | 256 | 999,527 | — |
| Plaintext no-pipeline | 16 | 413,046 | 95 μs |
| Plaintext no-pipeline | 128 | 130,303 | — |
| JSON /metrics | 16 | 13,543 | 22 ms |
| Dynamic /hello/bench | 16 | 5,478 | 25 ms |
| Query /search | 16 | 17,529 | 20 ms |
| Latency (1 conn) | 1 | 21,852 | p50=42μs, p99=79μs |
| Latency (10 conn) | 10 | 119,171 | p50=77μs, p99=106μs |

**Context (TechEmpower Round 22, 28-core hardware):**
- Kestrel (aspcore raw): 7,006,142 req/s
- Go gnet: 7,013,961 req/s
- Go net/http: 681,653 req/s
- Node.js: 454,082 req/s

To reproduce: `.\run-bench.ps1` (requires Docker Desktop).

---

## 1. Arena Allocator Per Request

**File:** `connection.zig`, `request.zig`

**What:** Each HTTP request gets its own arena allocator. All allocations during
request processing go through this arena. When the request is done, the entire
arena is freed in a single O(1) operation.

**Why:** Traditional malloc/free has overhead per allocation (metadata, fragmentation,
thread synchronization). An arena allocates from a contiguous block and frees
everything at once — no per-object bookkeeping.

**Zig implementation:**
```zig
// The backing allocator is passed explicitly from main → server → connection.
// Create arena for this request, backed by the caller-provided allocator.
var arena_state: std.heap.ArenaAllocator = .init(allocator);
defer arena_state.deinit(); // O(1) bulk free

const arena = arena_state.allocator();
// All request processing uses `arena`
```

**Impact:** Eliminates hundreds of malloc/free calls per request. Reduces allocator
lock contention in multi-threaded scenarios. The backing allocator is explicit,
not hardcoded — callers control allocation strategy (e.g., `init.gpa` in production,
`std.testing.allocator` in tests).

---

## 2. Zero-Copy HTTP Parsing

**File:** `parser.zig`

**What:** HTTP method, URI, headers are never copied from the read buffer. Instead,
we store `[]const u8` slices that point directly into the read buffer.

**Why:** Copying strings is expensive — it requires allocation, memcpy, and later
deallocation. Zero-copy parsing eliminates all of this.

**Zig implementation:**
```zig
// Parsed header is just slices into `buffer`
const Header = struct {
    name: []const u8,   // Points into read buffer
    value: []const u8,  // Points into read buffer
};
```

**Impact:** Zero allocations for header parsing. Parsing becomes pure pointer
arithmetic.

---

## 3. SIMD-Accelerated Byte Scanning

**File:** `parser.zig`

**What:** Uses Zig's `@Vector(16, u8)` to scan for special characters (CR, LF,
colon, space) 16 bytes at a time instead of one byte at a time.

**Why:** Modern CPUs have 128-bit+ SIMD registers. Processing 16 bytes per
instruction is 16x throughput for scanning operations.

**Zig implementation:**
```zig
fn containsByte(comptime needle: u8, chunk: @Vector(16, u8)) bool {
    const needles: @Vector(16, u8) = @splat(needle);
    return @reduce(.Or, chunk == needles);
}

fn findCRLF(data: []const u8) ?usize {
    // Process 16 bytes at a time with SIMD
    while (i + 16 <= data.len) {
        const chunk: @Vector(16, u8) = data[i..][0..16].*;
        if (containsByte('\r', chunk)) {
            // Found potential CRLF, check precisely
        }
        i += 16;
    }
}
```

**Impact:** Header scanning throughput increased ~10-16x for large headers.

---

## 4. Comptime Route Table Generation

**File:** `router.zig`

**What:** Routes are defined at compile time using Zig's comptime evaluation.
The compiler generates static arrays and matching logic — no runtime data
structure construction.

**Why:** Runtime route matching typically involves hash tables or tries that
must be built at startup. Comptime eliminates this entirely.

**Zig implementation:**
```zig
const router = Router.init(.{
    .{ .GET, "/",        indexHandler },
    .{ .GET, "/api/user", userHandler },
    .{ .POST, "/api/data", dataHandler },
});
// At compile time, this generates optimized matching code
```

**Impact:** Zero startup cost. Route matching compiles down to a series of
comparisons — no heap allocation, no hash computation.

---

## 5. Vectored Writes (writev)

**File:** `response.zig`

**What:** Instead of writing status line, headers, and body as separate `write()`
calls, we combine them into a single vectored write using `writeVecAll()`.

**Why:** Each `write()` syscall has kernel entry/exit overhead. Vectored writes
send multiple buffers in a single syscall.

**Zig implementation:**
```zig
// Combine status line + headers + body in one syscall
var vecs: [4][]const u8 = .{
    status_line,
    header_block,
    "\r\n",
    body,
};
try writer.writeVecAll(&vecs);
```

**Impact:** Reduces syscall count from 3-4 to 1 per response. Significant for
small responses where syscall overhead dominates.

---

## 6. Stack-Allocated I/O Buffers

**File:** `connection.zig`

**What:** Read and write buffers are allocated on the stack (as local arrays)
rather than on the heap.

**Why:** Stack allocation is free — it's just a pointer adjustment. No malloc
overhead, no fragmentation, guaranteed cache locality.

**Zig implementation:**
```zig
var read_buffer: [8192]u8 = undefined;
var write_buffer: [8192]u8 = undefined;
```

**Impact:** Eliminates buffer allocation/deallocation overhead per connection.
Buffers are cache-friendly due to stack locality.

---

## 7. Branch Prediction Hints

**File:** `parser.zig`, `connection.zig`

**What:** Zig's `@branchHint(.unlikely)` tells the compiler which branch is
rarely taken, allowing it to optimize the common path.

**Why:** CPUs use branch prediction pipelines. When the compiler knows which
path is common, it can lay out code for optimal instruction cache usage.

**Zig implementation:**
```zig
if (isError) {
    @branchHint(.unlikely);
    return error.BadRequest;
}
// Fast path continues here without a jump
```

**Impact:** Reduces branch mispredictions on error paths. Keeps the hot path
in contiguous cache lines.

---

## 8. Connection Keep-Alive

**File:** `connection.zig`

**What:** HTTP/1.1 connections default to keep-alive. Multiple requests are
served over the same TCP connection.

**Why:** TCP connection establishment (3-way handshake) is expensive. Reusing
connections amortizes this cost across multiple requests.

**Implementation:** After sending a response, check the `keep_alive` field
from the parsed request head. If true, loop back and wait for the next request.

**Impact:** Eliminates TCP handshake overhead for subsequent requests. Critical
for API servers handling many requests from the same client.

---

## 9. SO_REUSEADDR

**File:** `server.zig`

**What:** Socket option that allows immediate rebinding to a port after server
restart.

**Why:** Without this, restarting the server requires waiting for TIME_WAIT
to expire (typically 60-120 seconds).

**Implementation:** Set via `reuse_address: true` in listen options.

**Impact:** Development convenience + production reliability for fast restarts.

---

## 10. Comptime Status Line Generation

**File:** `response.zig`

**What:** Common HTTP status lines ("HTTP/1.1 200 OK\r\n") are generated at
compile time as static strings.

**Why:** Formatting status lines at runtime requires integer-to-string
conversion and string concatenation. Comptime eliminates this.

**Zig implementation:**
```zig
fn statusLine(comptime status: std.http.Status) []const u8 {
    return comptime blk: {
        // Generated at compile time, stored as static data
        break :blk "HTTP/1.1 " ++ statusCodeStr(status) ++ " " ++ 
                   (status.phrase() orelse "Unknown") ++ "\r\n";
    };
}
```

**Impact:** Response sending avoids all formatting — just memcpy of a static string.

---

## 11. Inline Hot Functions

**File:** Various

**What:** Small, frequently-called functions are marked `inline` to eliminate
function call overhead.

**Why:** Function calls involve stack frame setup, register saving, and a jump.
For very small functions (byte comparisons, buffer index calculations), this
overhead can exceed the function's actual work.

**Zig note:** Zig allows `inline fn` but the compiler may also auto-inline.
Explicit `inline` is used for critical-path functions where we want to guarantee
inlining.

**Impact:** Eliminates function call overhead on hot paths. Enables further
optimizations (constant propagation, dead code elimination) at the call site.

---

## 12. Structure of Arrays (SoA) Layout

**What:** Instead of storing an array of structs (AoS), decompose data into
separate arrays for each primitive field. Each array holds only one field type,
packed contiguously in memory.

**Why:** When an operation touches only one or two fields of a struct, AoS
layout wastes cache lines loading unused fields. SoA ensures every byte in a
cache line is relevant data, maximizing throughput for field-specific scans,
SIMD operations, and prefetcher efficiency.

**Example — Array of Structs (AoS) — wasteful:**
```zig
const Point = struct {
    x: f32,
    y: f32,
    z: f32,
    label: u8,
};
// All fields interleaved in memory: x₀ y₀ z₀ l₀ x₁ y₁ z₁ l₁ ...
var points: [1024]Point = undefined;
```

If you only need to sum all `x` values, each cache line fetch pulls in `y`, `z`,
and `label` too — 75% wasted bandwidth.

**Example — Structure of Arrays (SoA) — optimal:**
```zig
const Points = struct {
    xs: []f32,   // x₀ x₁ x₂ x₃ ... contiguous
    ys: []f32,   // y₀ y₁ y₂ y₃ ... contiguous
    zs: []f32,   // z₀ z₁ z₂ z₃ ... contiguous
    labels: []u8, // l₀ l₁ l₂ l₃ ... contiguous
};
```

Now summing all `x` values reads only `xs` — every byte in every cache line is
a useful `f32`. The hardware prefetcher excels at sequential access, and SIMD
can process 4× `f32` (or 8× with AVX) per instruction with no gather overhead.

**Key rule: decompose to the smallest primitives.** Don't stop at splitting a
struct into two sub-structs — go all the way down to `[]f32`, `[]u32`, `[]u8`,
etc. This maximizes the density of useful data per cache line and makes SIMD
vectorisation trivial.

**When to use SoA:**
- Hot loops that access only a subset of fields
- SIMD processing (contiguous same-type arrays vectorise naturally)
- Large collections (N > ~64) where cache effects dominate
- Columnar scans, filtering, or aggregation

**When AoS is fine:**
- Small collections where everything fits in cache
- Operations that always touch all fields together
- Data primarily accessed by individual record (e.g., lookup by ID)

**Impact:** Up to 2-4× throughput improvement for field-specific operations
due to reduced cache misses and enabling auto-vectorisation. The benefit grows
with collection size and the ratio of unused-to-used fields per operation.

---

## 13. Arena-Backed JSON Parsing (parseFromSliceLeaky)

**File:** `request.zig`

**What:** JSON request bodies are deserialized into typed Zig structs using
`std.json.parseFromSliceLeaky()`, which allocates all parse state and output
into the per-request arena allocator.

**Why:** The standard `parseFromSlice()` creates its own internal `ArenaAllocator`
with a separate `Parsed(T)` wrapper that must be individually freed. Since we
already have a per-request arena, the "Leaky" variant avoids this double-arena
overhead — all allocations go directly into our existing arena and are freed in
one O(1) bulk reset.

**Zig implementation:**
```zig
pub fn jsonBody(self: *Request, comptime T: type) !T {
    const body = self.body orelse return error.NoBody;
    return std.json.parseFromSliceLeaky(T, self.arena, body, .{
        .ignore_unknown_fields = true,
    });
}
```

**Performance characteristics:**
- **Zero-copy strings:** When parsing from a `[]const u8` slice, string values
  in the resulting struct are slices pointing directly into the original body
  buffer (`.alloc_if_needed` default). No string duplication for most fields.
- **Arena bump allocation:** All temporary parse state (stack, intermediate
  values) uses the arena's bump pointer — just a pointer increment per alloc.
- **O(1) cleanup:** Everything is freed when the arena resets between requests.
  No per-field destructor calls, no reference counting.
- **No separate Parsed(T) wrapper:** Avoids the overhead of allocating and
  managing a separate ArenaAllocator for each parse operation.

**Impact:** JSON parsing adds near-zero overhead beyond the parsing work itself.
No malloc/free calls, no fragmentation, no GC pauses.

---

## 14. Arena-Backed JSON Serialization (Stringify.valueAlloc)

**File:** `response.zig`

**What:** Zig structs are serialized to JSON using `std.json.Stringify.valueAlloc()`,
which writes the JSON bytes into arena-allocated memory, then sent as the
response body via the existing vectored write path.

**Why:** Serializing to an intermediate `[]const u8` buffer (rather than streaming
directly to the socket) allows us to compute `Content-Length` before sending headers.
Using the arena for this buffer means no allocation overhead — just a bump pointer.

**Zig implementation:**
```zig
pub fn sendJsonValue(self: *Response, status: http.Status, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(self.arena, value, .{});
    self.status = status;
    self.body = body;
    try self.addHeader("content-type", "application/json; charset=utf-8");
    try self.flush();
}
```

**Performance characteristics:**
- **Comptime-driven serialization:** `Stringify.write()` uses comptime reflection
  to generate field-specific serialization code at compile time — no runtime
  type inspection, no virtual dispatch.
- **Arena buffer reuse:** The serialized JSON lives in the arena. Between requests,
  `arena.reset(.retain_capacity)` resets the pointer without freeing pages —
  subsequent requests reuse the same memory.
- **Single vectored write:** The serialized body goes through the existing
  `flush()` path which combines status line + headers + body in one `writev`.

**Impact:** JSON serialization is essentially a comptime-generated `memcpy` into
arena memory, followed by a single syscall to write the full response.

---

## 15. Connection Pool Performance

**File:** `src/db/database.zig`, `src/db/user_repository.zig`

**What:** Database connections are pre-opened in a fixed-size pool. Each query
acquires a connection, executes, and returns it — no TCP handshake or
authentication per query. The pool is async-aware via `std.Io`.

**Why:** PostgreSQL connection setup involves TCP connect + TLS negotiation +
authentication + parameter exchange — typically 5-20ms. With pooling, only the
first `pool_size` connections pay this cost; subsequent queries reuse them.

**Zig implementation:**
```zig
// Pool wraps pg.Pool — init opens `pool_size` connections upfront
pub fn init(allocator: Allocator, io: Io, config: Config) !Database {
    const pool = try pg.Pool.init(allocator, io, .{
        .size = config.pool_size,            // Fixed pool (default: 5)
        .timeout = Io.Duration.fromSeconds(config.timeout_seconds),
        .connect = .{ .host = config.host, .port = config.port },
        .auth = .{ .username = ..., .database = ..., .password = ... },
    });
    return .{ .pool = pool };
}

// Queries auto-acquire/release through the pool
pub fn query(self: *Database, sql: []const u8, values: anytype) !*Result {
    return self.pool.query(sql, values);
}
```

**Performance characteristics:**
- **Amortized connection cost:** 5 connections opened once at startup; all HTTP
  requests share them without re-connecting.
- **Parameterized queries (binary protocol):** Data sent as binary parameters
  (`$1`, `$2`, ...), not interpolated strings. This eliminates SQL parsing
  overhead for repeated queries and provides SQL injection safety for free.
- **Arena-friendly results:** `UserRepository` methods accept an arena allocator
  for string duplication. Row data is duped once and then freed in bulk with the
  request arena — no per-field deallocation.
- **Async-aware timeout:** `Io.Duration` integrates with Zig's I/O runtime so
  pool acquisition yields the fiber/thread instead of busy-waiting.

**Impact:** Database queries add ~0.5-2ms latency per request (network round-trip)
instead of 5-20ms (if connecting per request). The binary protocol also avoids
query re-parsing overhead on the PostgreSQL side.

---

## 16. FixedBufferAllocator for Bounded Scratch Space

**File:** `thread_pool.zig` (CPU worker scratch), applicable anywhere

**What:** Use `std.heap.FixedBufferAllocator` when you need an `Allocator`
interface but know the maximum allocation size at design time. The FBA
wraps a fixed buffer (stack-allocated or pre-allocated on the heap) and
provides zero-overhead bump allocation with no heap interaction.

**Why:** Arena allocators are excellent for request lifetimes, but they
still interact with the backing heap allocator when they need new pages.
FixedBufferAllocator avoids this entirely — all memory comes from a
pre-existing buffer. This is ideal for:
- CPU task scratch space (worker threads with known bounded size)
- Formatting into a bounded buffer via the Allocator interface
- Library functions that require an `Allocator` but produce bounded output
- Hot paths where even arena page-allocation overhead matters

**Zig implementation:**
```zig
// Stack-backed: zero heap interaction
var buf: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);
const allocator = fba.allocator();

// Use allocator normally — bumps a pointer, no syscalls
const data = try allocator.alloc(u8, 256);
// ... use data ...

// No free needed — buffer is on the stack (or reset FBA to reuse)
fba.reset(); // O(1): just resets the bump pointer to 0
```

**In the CPU pool:**
```zig
// Each worker thread gets a pre-allocated scratch buffer.
// FixedBufferAllocator is re-created per task (automatic reset).
fn workerFn(inner: *Inner, scratch_buf: []u8) void {
    while (true) {
        const task = inner.queue.getOneUncancelable(inner.io) catch break;
        var fba = std.heap.FixedBufferAllocator.init(scratch_buf);
        task.run_fn(task.context, fba.allocator());
    }
}
```

**When to use which allocator:**

| Scenario | Allocator |
|---|---|
| Request lifetime, variable size | `ArenaAllocator` |
| Known max size, library needs `Allocator` | `FixedBufferAllocator` |
| CPU task temp buffers (pooled workers) | `FixedBufferAllocator` |
| Stack buffer sufficient, no `Allocator` needed | Raw `[N]u8` array |
| Long-lived objects across requests | General purpose (`init.gpa`) |

**Impact:** Eliminates all allocator overhead. No heap metadata, no
fragmentation, no lock contention. The bump pointer is a single
`usize` increment — the fastest possible allocation strategy.

---

## 17. CPU Work Pool (Offloading CPU-Bound Tasks)

**File:** `thread_pool.zig`

**What:** A dedicated pool of OS threads for CPU-intensive work, separate
from the I/O runtime's connection-handling threads/fibers. Handlers submit
CPU tasks to this pool, keeping I/O fibers free to handle connections.

**Why:** The I/O runtime (`Io.Group`) is optimized for tasks that mostly wait
on I/O (network, disk). CPU-bound work blocks the fiber/thread, preventing
it from handling other connections. On the Windows threaded backend, this is
especially severe — each blocked thread is one fewer connection handler.
A separate CPU pool ensures:
- Connection handling stays responsive under CPU load
- CPU threads can be sized independently of I/O capacity
- Natural backpressure when CPU capacity is exhausted

**Architecture:**
```
I/O Runtime (connections)          CPU Pool (computation)
┌─────────────┐                    ┌──────────────────┐
│ Fiber/Thread │──submit(task)────►│ Worker 1 (FBA)   │
│ (handler)    │                   │                  │
│              │◄──completion──────│                  │
├─────────────┤                    ├──────────────────┤
│ Fiber/Thread │──submit(task)────►│ Worker 2 (FBA)   │
│ (handler)    │                   │                  │
│              │◄──completion──────│                  │
└─────────────┘                    └──────────────────┘
   Io.Group                          std.Thread pool
```

**Usage pattern:**
```zig
const CpuPool = http.CpuPool;

// Server startup:
var cpu_pool = try CpuPool.init(allocator, io, .{
    .num_threads = 4,          // Half of CPU cores
    .scratch_size = 64 * 1024, // 64KB scratch per worker
});
defer cpu_pool.shutdown(io);

// In a handler — submit + wait:
fn handleHash(request: *Request, response: *Response, io: std.Io) !void {
    var ctx = HashContext{ .data = request.body orelse "" };
    cpu_pool.submitAndWait(&HashContext.compute, @ptrCast(&ctx));
    try response.sendText(.ok, &ctx.result);
}
```

**Thread count guideline:**
- CPU pool: `CPU_COUNT / 2` threads (for compute)
- I/O runtime: remaining cores (for connections)
- Total active threads ≈ CPU_COUNT (avoids oversubscription)

**Impact:** Prevents CPU-heavy handlers from starving connection handling.
Under mixed workloads (I/O + CPU), overall throughput improves because
I/O fibers remain available to accept and serve lightweight requests.

---

## 18. Static File Serving (Zero-Cost Fallback)

**Files:** `static.zig`, `connection.zig`, `response.zig`

**What:** Static files (HTML, CSS, JS, images) are served from a configurable
document root directory when no comptime route matches a request.

**Why this is fast:**

1. **Zero route overhead:** Static file lookup only happens when `Router.dispatch()`
   returns null. API routes never pay any static-file cost.

2. **Comptime MIME table:** Extension-to-Content-Type mapping is a comptime array
   with `inline for`. The compiler generates an optimal comparison chain — no
   hash table, no heap allocations, no runtime initialization.

   ```zig
   inline for (mime_table) |entry| {
       if (eqlIgnoreCaseComptime(ext, entry.ext)) return entry.content_type;
   }
   ```

3. **Arena-allocated reads:** File contents are allocated from the per-request
   arena, freed in bulk when the request completes (arena reset). This eliminates
   manual `free()` calls and makes all code paths — including error returns —
   leak-free. Originally used `page_allocator` with manual free, which was
   migrated during the memory safety audit (Step 15-8) after finding 3 critical
   bugs: leaks on error paths, `@constCast` UB on empty files, and fragile
   lifecycle management.

4. **O(n) path validation:** Path sanitization is a single linear scan — no regex,
   no allocations. Rejects `..` traversal, null bytes, and backslashes.

5. **Bounded file size:** `max_file_size` (default 10MB) prevents accidental
   serving of huge files that would exhaust memory.

6. **Cache-Control headers:** `Cache-Control: public, max-age=3600` tells browsers
   to cache assets, reducing repeat requests to zero server work.

7. **Io-native file I/O:** Uses `Io.Dir`/`Io.File` APIs (`openDir`, `openFile`,
   `readPositionalAll`, `stat`) which go through the Zig I/O runtime. On evented
   backends, file reads can yield to serve other connections.

**Cost when NOT used:** `static_config: null` (the default) — the fallback is a
single `if (static_config) |sc|` branch per unmatched request. Zero overhead
for servers that only serve API routes.

---

## Techniques NOT Used (and Why)

### io_uring / IOCP
These are platform-specific async I/O APIs. Zig 0.16's `std.Io` abstracts over
them — on Linux, it uses io_uring when available (with epoll fallback). The Docker
benchmark setup enables this via `seccomp:unconfined` since Docker's default
seccomp profile blocks the io_uring_* syscalls.

**Note:** The `io.select()` API (used to race a read against a timeout) has a bug
where fibers get permanently stuck after the client disconnects. Setting
`--idle-timeout 0 --request-timeout 0` takes a direct-call fast path that avoids
`io.select` entirely, which is why the Docker benchmark uses these flags.

### Memory-Mapped Static Files
Considered for future implementation. Would use `mmap` to serve static files
without copying from kernel to userspace.

### Sendfile
The `std.Io.Writer` supports `sendFile` but it's marked as TODO in the
current Zig 0.16 dev version for network streams.

### Custom Memory Pool
For this server, arena-per-request is simpler and nearly as fast. A fixed-block
pool would help if we had many same-sized objects with overlapping lifetimes.
