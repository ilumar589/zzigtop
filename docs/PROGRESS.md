# High-Performance HTTP/1 Server in Zig

## Project Progress Tracker

> **Last Updated:** 2026-02-17  
> **Zig Version:** 0.16.0-dev.2535+b5bd49460  
> **Status:** STEP 11 IN PROGRESS — Async I/O pool complete, structured concurrency next

---

## Steps Overview

| Step | Description | Status |
|------|------------|--------|
| 1 | Project scaffolding & documentation structure | ✅ COMPLETE |
| 2 | HTTP types & status codes (`http_types.zig`) | ✅ COMPLETE |
| 3 | Zero-copy HTTP/1 header parser (`parser.zig`) | ✅ COMPLETE |
| 4 | Request type with arena-per-request (`request.zig`) | ✅ COMPLETE |
| 5 | Response builder with vectored writes (`response.zig`) | ✅ COMPLETE |
| 6 | Comptime route matching (`router.zig`) | ✅ COMPLETE |
| 7 | Connection handler with keep-alive (`connection.zig`) | ✅ COMPLETE |
| 8 | Core server with thread-per-connection (`server.zig`) | ✅ COMPLETE |
| 9 | Build integration & main entry point | ✅ COMPLETE |
| 10 | Testing, benchmarking & tuning | ✅ COMPLETE |
| 11a | Async I/O pool (Io.Group dispatch) | ✅ COMPLETE |
| 11b | Structured concurrency (timeouts, graceful shutdown, parallel handlers) | 🔲 NOT STARTED |

---

## Step 1: Project Scaffolding (COMPLETE)

**What was done:**
- Created `docs/` directory with documentation files
- Created `src/http/` directory for server modules
- Established file structure

**Files created:**
- `docs/PROGRESS.md` — This file (progress tracker)
- `docs/ARCHITECTURE.md` — Design document
- `docs/PERFORMANCE.md` — Performance techniques reference
- `docs/API.md` — API documentation
- `src/http/server.zig` — Core server
- `src/http/parser.zig` — Zero-copy HTTP/1 parser
- `src/http/request.zig` — Request type
- `src/http/response.zig` — Response builder
- `src/http/router.zig` — Comptime router
- `src/http/connection.zig` — Connection handler
- `src/http/http.zig` — Module root (re-exports)

---

## Step 2: HTTP Types & Status Codes (COMPLETE)

**What was done:**
- Leveraged `std.http.Method`, `std.http.Status` from Zig stdlib (already comprehensive)
- Our parser module re-exports these types
- Created `http_types.zig` with our custom `Header` type using zero-copy slices

**Design Decision:** Zig 0.16's `std.http` already has excellent type definitions for Method, Status, TransferEncoding, ContentEncoding, etc. We reuse these instead of duplicating.

---

## Step 3: Zero-Copy HTTP/1 Parser (COMPLETE)

**What was done:**
- Created `parser.zig` with SIMD-accelerated newline scanning using `@Vector`
- Parser returns slices into the original read buffer (zero allocations)
- Uses `@branchHint(.unlikely)` on error paths
- Processes 16 bytes at a time for CRLF detection

**Performance tricks applied:**
- `@Vector(16, u8)` for parallel byte scanning
- Zero-copy: all parsed strings are slices into the read buffer
- `@branchHint(.unlikely)` for error/edge-case branches
- Inline hot functions with `inline`

---

## Step 4: Request Type (COMPLETE)

**What was done:**
- Arena-per-request pattern: each request gets an arena allocator
- All request data freed in one bulk operation when request completes
- Header iteration without allocation (slices into buffer)

**Performance tricks applied:**
- Arena allocator per request (O(1) bulk deallocation)
- Zero-copy header access (no string duplication)

---

## Step 5: Response Builder (COMPLETE)

**What was done:**
- Response type with pre-formatted status line caching
- Vectored write support (combines multiple buffers in single syscall)
- Content-Length auto-calculation
- Keep-alive header management

**Performance tricks applied:**
- Comptime-generated status line lookup table
- Vectored writes via `writeVecAll()` (single syscall for full response)
- Pre-allocated header buffer to avoid per-response allocation

---

## Step 6: Comptime Router (COMPLETE)

**What was done:**
- Comptime route table generation using Zig's compile-time evaluation
- Routes are resolved at compile time into optimized match structures
- Support for path parameters (`:id` syntax)
- Method-based dispatch

**Performance tricks applied:**
- All route matching logic resolved at comptime
- No heap allocation for routing
- Static dispatch to handler functions
- Comptime string comparison optimization

---

## Step 7: Connection Handler (COMPLETE)

**What was done:**
- Keep-alive connection reuse
- Configurable timeouts  
- Clean connection lifecycle management
- Uses `std.http.Server` for protocol-level parsing

**Performance tricks applied:**
- Connection reuse (amortized TCP handshake cost)
- Buffered I/O with configurable buffer sizes
- Stack-allocated buffers (no heap allocation for I/O)

---

## Step 8: Core Server (COMPLETE)

**What was done:**
- Thread-per-connection model using `std.Thread.spawn`
- Configurable listen backlog
- Graceful accept loop
- Address reuse enabled
- Explicit allocator parameter threaded from `main` → `Server` → connection threads

**Performance tricks applied:**
- SO_REUSEADDR for fast restarts
- Configurable backlog for burst handling
- **Fixed-size thread pool** with `Io.Queue`-based bounded work queue (replaced thread-per-connection)
- Configurable worker count (default: CPU count) and queue depth
- No hardcoded allocators — caller controls allocation strategy

---

## Step 9: Build Integration (COMPLETE)

**What was done:**
- Added `http_server` executable to `build.zig`
- Updated `root.zig` to export HTTP module
- Created server entry point `src/http_server_main.zig`
- Added `zig build run-server` step

**Build commands:**
```
zig build run-server               # Debug mode
zig build run-server -Doptimize=ReleaseFast  # Max performance
```

---

## Step 10: Testing & Benchmarking (COMPLETE)

**What was done:**
- Added comprehensive unit tests across all modules (62 module tests + 2 exe tests = 64 total)
- Fixed test discovery: `root.zig` test block now references `http` module so all sub-module tests are discovered
- Fixed comptime test calls: `compilePattern()` and `Router.init()` in tests now use `comptime` keyword
- Registered `Request` and `Response` modules in `http.zig` test block
- Created integration test executable (`src/integration_test.zig`) with 10 end-to-end tests
- Created benchmark executable (`src/benchmark.zig`) with built-in performance measurement
- Added `zig build integration-test` and `zig build benchmark` build steps

**Test breakdown by module:**
| Module | Tests | Coverage |
|--------|-------|----------|
| `parser.zig` | 32 | findByte (6), findCRLF (7), findHeaderEnd (5), parseRequestLine (8), parseHeaderLine (6) |
| `router.zig` | 15 | compilePattern (6), dispatch: static/param/multi-param/method/edge cases (9) |
| `request.zig` | 5 | pathParam found/not-found/empty/second-param, default fields |
| `response.zig` | 7 | setStatus, setBody, addHeader single/multiple/overflow, defaults, setBodyWithType |
| `root.zig` | 1 | basic add |
| `main.zig` | 2 | simple test, fuzz example |

**Integration tests (10/10 passing):**
| Test | What it verifies |
|------|-----------------|
| GET / - 200 OK | Root route returns 200 with welcome text |
| GET /health - JSON | JSON response with correct content-type |
| GET /hello/:name | Path parameter extraction |
| POST /echo | POST method and path echoing |
| GET /nonexistent - 404 | Unknown routes return 404 |
| DELETE / - wrong method | Wrong method returns 404 |
| Keep-alive reuse | Two requests on one TCP connection |
| Content-Length present | Response includes Content-Length header |
| Different param values | Path params work with various inputs |
| HTTP/1.0 request | Backwards compatibility with HTTP/1.0 |

**Benchmark results (ReleaseFast, Windows, thread pool):**

*Connection-per-request (each request opens a new TCP connection):*
| Benchmark | Threads | Requests | Throughput | Avg Latency | Min Latency |
|-----------|---------|----------|------------|-------------|-------------|
| GET / (conn-per-req) | 4 | 40,000 | ~22,265 req/s | 177μs | 129μs |
| GET /json (conn-per-req) | 4 | 40,000 | ~22,940 req/s | 174μs | 134μs |

*Keep-alive (connection reuse — amortized TCP handshake):*
| Benchmark | Threads | Requests | Throughput | Avg Latency | Min Latency |
|-----------|---------|----------|------------|-------------|-------------|
| GET / (keep-alive) | 4 | 40,000 | ~144,680 req/s | 27μs | 19μs |
| GET /json (keep-alive) | 4 | 40,000 | ~150,318 req/s | 26μs | 18μs |
| GET /param/:id (keep-alive) | 4 | 40,000 | ~89,148 req/s | 45μs | 22μs |
| GET / (keep-alive, 16t) | 16 | 80,000 | ~364,749 req/s | 42μs | 24μs |

*Thread pool eliminated thread-spawn overhead: conn-per-req improved from ~13K to ~22K req/s (~73% faster). Keep-alive throughput unchanged at ~150K req/s.*

**Build commands:**
```
zig build test                    # Run 64 unit tests
zig build integration-test        # Run 10 integration tests
zig build benchmark -Doptimize=ReleaseFast  # Run benchmarks
```

**Bug found & fixed:**
- Tests in `parser.zig`, `router.zig` were never being discovered/run by `zig build test` — http module tests were dead code. Fixed by adding `_ = http;` to root.zig test block and `_ = Request; _ = Response;` to http.zig test block.

**Files created:**
- `src/integration_test.zig` — End-to-end HTTP integration tests
- `src/benchmark.zig` — Built-in performance benchmark
- `src/http/thread_pool.zig` — Fixed-size thread pool with bounded `Io.Queue` work queue

---

## How to Resume Work

If context is full or work is interrupted, read this file first to understand:
1. What step we're on (check the table above)
2. What files exist (check the file list in each step)
3. What the next step requires

Then read `docs/ARCHITECTURE.md` for the overall design, and the specific source files for the current step.

---

## Step 11a: Async I/O Pool — Io.Group Dispatch (COMPLETE)

**What was done:**
- **Replaced the custom `ThreadPool`** with Zig's built-in `Io.Group.async()` dispatch
- Each accepted connection is spawned as an async task via `group.async(io, Connection.handleAsync, .{...})`
- The Io runtime manages concurrency automatically:
  - **Evented backend** (Linux io_uring / macOS kqueue): stackful fibers + work-stealing
  - **Threaded backend** (Windows / fallback): dynamic thread pool (lazy spawn up to CPU_COUNT-1)
- Arena allocation changed from per-thread to per-connection (fiber-safe — fibers may migrate between OS threads)
- Removed `--threads` CLI flag (Io runtime auto-scales)
- Removed `thread_pool_size` / `max_pending_connections` from `Server.Config`
- Marked old `thread_pool.zig` as superseded (kept for reference)

**Files modified:**
- `src/http/connection.zig` — Added `handleAsync()` (returns `Io.Cancelable!void`), refactored core into `handleInner()`
- `src/http/server.zig` — Replaced ThreadPool with `Io.Group`, simplified Config
- `src/http/http.zig` — Removed ThreadPool export
- `src/http_server_main.zig` — Removed `--threads` arg, updated banner
- `src/http/thread_pool.zig` — Added "SUPERSEDED" header comment
- `docs/ARCHITECTURE.md` — Updated diagrams and threading model

**Performance impact (ReleaseFast, Windows — Threaded backend):**

| Benchmark | Before (ThreadPool) | After (Io.Group) | Change |
|-----------|---------------------|-------------------|--------|
| GET / (conn-per-req) | ~22K req/s | ~23,693 req/s | +7% |
| GET / (keep-alive, 4t) | ~142K req/s | ~156,142 req/s | +10% |
| GET / (keep-alive, 16t) | ~373K req/s | ~430,359 req/s | +15% |
| GET /param/:id (keep-alive) | ~133K req/s | ~152,355 req/s | +15% |

**Key insight:** Zero code manages threads anymore. The Io runtime (same one backing `std.process.Init`) handles all scheduling. On Linux/macOS with the Evented backend, this gives real work-stealing with fibers — thousands of concurrent connections on a few OS threads.

---

## Step 11b: Structured Concurrency (NOT STARTED)

### Goal

Evolve from "fire-and-forget `Group.async()`" to a **structured concurrency** model where:
- Every async task has a well-defined lifetime scope
- Cancellation propagates cleanly from parent → children
- Timeouts are first-class and composable
- Handlers can spawn parallel sub-tasks safely
- Graceful shutdown drains in-flight work

### Available Io Primitives

| Primitive | Purpose | Error Model |
|-----------|---------|-------------|
| `Io.Group` | Unordered task set, cancel/await all | Tasks return `Cancelable!void` only |
| `Io.Select(U)` | Spawn N tasks, collect results via union | Full result types via union variants |
| `io.select(.{...})` | Race N futures, first wins | Returns winning future's result |
| `io.async(fn, args)` → `Future(T)` | Single async task | Full result type preserved |
| `io.sleep(duration, clock)` | Cancelable sleep | Returns `Cancelable!void` |
| `Clock.Timestamp.wait(ts, io)` | Sleep until deadline | Returns `Cancelable!void` |
| `CancelProtection` | Block cancel in critical sections | `io.swapCancelProtection(.blocked)` |
| `io.recancel()` | Re-arm cancel signal | For partial-work-then-propagate |
| `io.checkCancel()` | Manual cancel point | For CPU-bound loops |
| `Io.Queue(T)` | Bounded MPMC channel | Closed + Canceled errors |

### Planned Sub-Steps

#### 11b-1: Connection Timeouts

**Add idle timeout and header-read timeout per connection.**

Use `io.select()` to race the HTTP read against a sleep:
```zig
// Race header read against timeout
var read_future = io.async(receiveHead, .{&http_server});
var timeout_future = io.async(Io.sleep, .{io, Duration.fromSeconds(30), .awake});
switch (try io.select(.{ .request = &read_future, .timeout = &timeout_future })) {
    .request => |head| { /* process */ },
    .timeout => { /* close connection, send 408 */ },
}
```

**Files to modify:** `connection.zig` — wrap the `receiveHead()` call
**Deliverable:** Connections that sit idle > N seconds get closed with 408 Request Timeout

#### 11b-2: Request-Level Timeouts

**Enforce a max duration for handler execution.**

Wrap each handler call in a `select` against a deadline:
```zig
var handler_future = io.async(match.handler, .{&request, &response});
var deadline = io.async(Io.sleep, .{io, Duration.fromSeconds(10), .awake});
switch (try io.select(.{ .ok = &handler_future, .timeout = &deadline })) {
    .ok => {},
    .timeout => { handler_future.cancel(io); send503(); },
}
```

**Files to modify:** `connection.zig` — wrap handler dispatch
**Deliverable:** Handlers that exceed the timeout get canceled, client gets 503

#### 11b-3: Graceful Shutdown

**On shutdown signal, stop accepting new connections and drain in-flight work.**

Architecture:
1. Spawn the accept loop as an `io.async()` (so we get a `Future` we can cancel)
2. Listen for a shutdown signal (platform-specific or via a sentinel)
3. On signal: cancel the accept future → accept loop exits → `group.await()` drains in-flight connections
4. Connections in keep-alive receive `error.Canceled` at their next I/O point and exit cleanly

```zig
pub fn run(self: *Server, io: Io) void {
    var group: Io.Group = .init;
    defer group.cancel(io);        // step 3: cancels all connections

    // Accept loop — exits when canceled
    while (true) {
        const stream = self.tcp_server.accept(io) catch |err| switch (err) {
            error.Canceled => break,  // shutdown requested
            // ...
        };
        group.async(io, Connection.handleAsync, .{stream, io, self.router, self.allocator});
    }

    // Drain: wait for in-flight connections to finish
    group.await(io) catch {};
}
```

**Files to modify:** `server.zig`, `http_server_main.zig`
**Deliverable:** Clean server shutdown with no abruptly killed connections

#### 11b-4: Parallel Handler Sub-Tasks

**Allow request handlers to spawn sub-tasks via `Io.Group` or `io.async()`.**

Pass `Io` to handlers so they can do concurrent work:
```zig
fn handleDashboard(request: *http.Request, response: *http.Response, io: Io) anyerror!void {
    // Fan-out: fetch user profile and notifications concurrently
    var profile_future = io.async(fetchProfile, .{request.pathParam("id").?, io});
    var notifs_future  = io.async(fetchNotifs, .{request.pathParam("id").?, io});

    const profile = profile_future.await(io);
    const notifs  = notifs_future.await(io);

    const body = try renderDashboard(request.arena, profile, notifs);
    try response.sendText(.ok, body);
}
```

**Files to modify:**
- `router.zig` — handler signature gains `io: Io` parameter
- `connection.zig` — pass `io` to handler calls
- `http_server_main.zig` — update handler signatures
- All existing handlers — add `io: Io` param (can `_ = io;` if unused)

**Deliverable:** Handlers can do parallel I/O; example `/dashboard` route with fan-out

#### 11b-5: Health & Metrics Monitoring

**Spawn a concurrent monitoring task alongside the accept loop.**

Use `Group` or `Select` to run a periodic stats reporter:
```zig
group.async(io, reportMetrics, .{io, &stats});  // periodic: active conns, req/s, etc.
```

Track: active connections (atomic counter), total requests served, uptime.

**Files to modify:** `server.zig` — add metrics struct, `connection.zig` — inc/dec counters
**Deliverable:** Periodic log output with server metrics; `/metrics` endpoint

### Implementation Order

```
11b-1  Connection Timeouts    ← simplest select() usage, immediate value
  ↓
11b-2  Request Timeouts       ← builds on same pattern, cancel handler
  ↓
11b-3  Graceful Shutdown      ← requires accept loop restructure
  ↓
11b-4  Parallel Handlers      ← handler signature change (breaking), most impactful
  ↓
11b-5  Health & Metrics       ← polish, adds observability
```

### Key Design Constraints

1. **Group tasks return `Cancelable!void` only** — no custom error propagation. Use `Select(U)` or `Future(T)` when you need result types.
2. **`handleAsync` must propagate `error.Canceled`** — if any Io op returns `Canceled`, the function must also return it (assertion-enforced).
3. **CancelProtection** needed around response flush — don't cancel mid-write (partial HTTP response = protocol violation).
4. **No signal handling in std.Io** — graceful shutdown needs either a sentinel mechanism or platform-specific signal code.
5. **Arenas are per-connection, not per-thread** — fibers migrate between OS threads, so thread-local state is unsound.
