# High-Performance HTTP/1 Server in Zig

## Project Progress Tracker

> **Last Updated:** 2026-02-22  
> **Zig Version:** 0.16.0-dev.2535+b5bd49460  
> **Status:** STEP 14 COMPLETE — CPU work pool + FixedBufferAllocator

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
| 11b | Structured concurrency (Kotlin-style scoped lifetimes) | ✅ COMPLETE |
| | 11b-1: Handler signature — pass `Io` to handlers | ✅ COMPLETE |
| | 11b-2: Connection scope — idle timeout via `io.select()` | ✅ COMPLETE |
| | 11b-3: Request timeout — `withTimeout` around handlers | ✅ COMPLETE |
| | 11b-4: Graceful shutdown — cancel/drain server scope | ✅ COMPLETE |
| | 11b-5: Handler concurrency — `io.async()` fan-out | ✅ COMPLETE |
| | 11b-6: Background tasks — metrics, health monitoring | ✅ COMPLETE |
| | 11b-7: Integration tests — verify SC guarantees | ✅ COMPLETE |
| 12 | JSON body parsing & struct serialization | ✅ COMPLETE |
| | 12-1: Request body reading (`readBody`) | ✅ COMPLETE |
| | 12-2: JSON → struct deserialization (`jsonBody(T)`) | ✅ COMPLETE |
| | 12-3: Struct → JSON response (`sendJsonValue`) | ✅ COMPLETE |
| | 12-4: Handler demos & tests | ✅ COMPLETE |
| 13 | PostgreSQL database integration | ✅ COMPLETE |
| | 13-1: Add pg.zig dependency & build integration | ✅ COMPLETE |
| | 13-2: Docker Compose setup (PostgreSQL 16) | ✅ COMPLETE |
| | 13-3: Database module (`database.zig` — pool wrapper) | ✅ COMPLETE |
| | 13-4: User repository (CRUD with parameterized queries) | ✅ COMPLETE |
| | 13-5: REST API handlers (JSON + DB) | ✅ COMPLETE |
| | 13-6: Integration tests & documentation | ✅ COMPLETE |
| 14 | CPU work pool + FixedBufferAllocator | ✅ COMPLETE |
| | 14-1: Refactor thread_pool.zig → CpuPool (generic CPU task pool) | ✅ COMPLETE |
| | 14-2: FixedBufferAllocator per worker (bounded scratch space) | ✅ COMPLETE |
| | 14-3: Export CpuPool from http module | ✅ COMPLETE |
| | 14-4: Documentation (PERFORMANCE.md, ARCHITECTURE.md) | ✅ COMPLETE |

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

### Vision

Redesign the entire server around **structured concurrency**, inspired by
[Kotlin coroutines](https://kotlinlang.org/docs/coroutines-basics.html) and
[JEP 453 (Java)](https://openjdk.org/jeps/453). The key principle:

> **Every concurrent operation has a well-defined scope.
> When the scope ends, all child operations are guaranteed to be complete (or canceled).**

This replaces "fire-and-forget" with a hierarchy where:
- The _server scope_ owns all _connection scopes_
- Each _connection scope_ owns its _request scopes_
- Each _request scope_ owns any _handler sub-tasks_
- Cancellation flows top-down; completion flows bottom-up

### Kotlin ↔ Zig Mapping

| Kotlin Concept | Zig `std.Io` Equivalent | Notes |
|----------------|------------------------|-------|
| `CoroutineScope { }` | `Io.Group` + `defer group.cancel(io)` | Group = scope boundary; defer = automatic cleanup |
| `launch { }` | `group.async(io, fn, args)` | Fire-and-forget child task (returns `Cancelable!void`) |
| `async { } / .await()` | `io.async(fn, args)` → `future.await(io)` | Result-bearing child task |
| `withTimeout(ms) { }` | `io.select(.{ .result = &op, .timeout = &sleep })` | Race operation against deadline |
| `coroutineScope { }` | Nested `Io.Group { defer cancel; ...; await; }` | Suspends parent until all children complete |
| `supervisorScope { }` | Separate Group per child (isolate failures) | Child errors don't cancel siblings |
| `Dispatchers.IO / Default` | Io runtime (Evented/Threaded backend) | Automatic — no manual dispatcher selection |
| `Job.cancel()` | `future.cancel(io)` / `group.cancel(io)` | Cooperative cancellation |
| `isActive / ensureActive()` | `io.checkCancel()` | Manual cancellation checkpoint |
| `NonCancellable` | `io.swapCancelProtection(.blocked)` | Critical sections immune to cancel |
| `yield()` | `io.checkCancel()` (closest equivalent) | Cancellation point in CPU-bound loops |
| `Channel<T>` | `Io.Queue(T)` | Bounded MPMC with backpressure |
| `select { }` | `io.select(.{...})` / `Io.Select(U)` | First-ready wins |
| `Flow<T>` | No direct equivalent | Could build with `Queue` + producer task |

### Scope Hierarchy

```
Server Scope (Io.Group — lifetime: entire server process)
│
├── Accept Loop Task (runs until shutdown / cancel)
│
├── Background Tasks (metrics reporter, health checker, etc.)
│
├── Connection Scope 1 (Io.Group — lifetime: one TCP connection)
│   ├── Idle Timeout Task (io.sleep → cancel connection if idle)
│   │
│   ├── Request Scope 1.1 (lifetime: one HTTP request)
│   │   ├── Handler execution (with request timeout)
│   │   ├── Handler Sub-Task A (io.async → fan-out)
│   │   └── Handler Sub-Task B (io.async → fan-out)
│   │
│   ├── Request Scope 1.2 (keep-alive, next request)
│   │   └── Handler execution
│   │
│   └── (connection close or idle timeout)
│
├── Connection Scope 2 ...
├── Connection Scope 3 ...
└── (shutdown → group.cancel → cascades to all)
```

### Cancellation Flow

```
                Shutdown signal
                     │
              ┌──────▼──────┐
              │ Server Scope │ ── group.cancel(io)
              │  (Io.Group)  │
              └──────┬───────┘
                     │ error.Canceled propagates to every child
         ┌───────────┼───────────┐
         ▼           ▼           ▼
   ┌───────────┐ ┌────────┐ ┌────────┐
   │ Accept    │ │ Conn 1 │ │ Conn 2 │
   │ (breaks)  │ │        │ │        │
   └───────────┘ └───┬────┘ └───┬────┘
                     │           │
              CancelProtection   │
              around flush()     │
                     │     ┌─────┴─────┐
              finishes     │ Handler   │ ← gets error.Canceled
              response     │ sub-tasks │   at next Io call
                     │     └───────────┘
              closes stream
```

### Available Io Primitives

| Primitive | Purpose | Error Model |
|-----------|---------|-------------|
| `Io.Group` | Scope boundary — cancel/await all children | Tasks must return `Cancelable!void` |
| `Io.Select(U)` | Spawn N tasks, collect results via tagged union | Full result types preserved |
| `io.select(.{...})` | Race N futures, first wins | Returns winning future's result |
| `io.async(fn, args)` → `Future(T)` | Single result-bearing child task | Full result type preserved |
| `io.concurrent(fn, args)` → `Future(T)` | Like async but **guaranteed** separate thread | Can fail: `ConcurrencyUnavailable` |
| `io.sleep(duration, clock)` | Cancelable timer | `Cancelable!void` |
| `Clock.Timestamp.wait(ts, io)` | Sleep until absolute deadline | `Cancelable!void` |
| `io.swapCancelProtection(.blocked)` | Critical section (NonCancellable) | Blocks `error.Canceled` delivery |
| `io.recancel()` | Re-arm cancel after partial handling | Deferred propagation |
| `io.checkCancel()` | Manual cancel checkpoint | For CPU-bound loops |
| `Io.Queue(T)` | Bounded MPMC channel (like Kotlin Channel) | `Closed + Canceled` errors |

### Implementation Plan — 7 Sub-Steps

The steps build on each other. Each is independently testable/committable.

```
11b-1  Handler Signature      ← pass Io to handlers (foundation for everything)
  ↓
11b-2  Connection Scope       ← Io.Group per connection, idle timeout
  ↓
11b-3  Request Timeout        ← withTimeout pattern around handler calls
  ↓
11b-4  Graceful Shutdown      ← server scope cancel → drain connections
  ↓
11b-5  Handler Concurrency    ← handlers use io.async() for fan-out
  ↓
11b-6  Background Tasks       ← metrics, health monitoring in server scope
  ↓
11b-7  Integration Tests      ← test timeout, shutdown, concurrency behavior
```

---

#### 11b-1: Handler Signature Change (COMPLETE)

**Why first:** Every subsequent step needs `Io` inside handlers or connection logic.
In Kotlin, every coroutine function has access to the `CoroutineScope`. Here, `Io`
is the equivalent — it's the handle to the async runtime.

**What was done:**
- Changed `HandlerFn` from `*const fn (*Request, *Response) anyerror!void` to
  `*const fn (*Request, *Response, Io) anyerror!void`
- Added `Io` import to `router.zig`
- Updated `connection.zig` to pass `io` when calling handlers
- Updated all 4 handlers in `http_server_main.zig` (accept `_: std.Io` for now)
- Updated all 4 handlers in `integration_test.zig`
- Updated all 3 handlers in `benchmark.zig`
- Updated test dummy handlers in `router.zig`

**Files modified:**
| File | Change |
|------|--------|
| `router.zig` | `HandlerFn` type adds `Io` parameter; import `Io`; test handlers updated |
| `connection.zig` | Pass `io` when calling `match.handler(&request, &response, io)` |
| `http_server_main.zig` | All 4 handlers gain `_: std.Io` parameter |
| `integration_test.zig` | All 4 test handlers gain `_: std.Io` parameter |
| `benchmark.zig` | All 3 benchmark handlers gain `_: std.Io` parameter |

**Verification:** All 64 unit tests pass. All executables build cleanly.

**Deliverable:** All handlers receive `Io`, enabling structured concurrency in later steps.

---

#### 11b-2: Connection Scope with Idle Timeout (COMPLETE)

**Model: `coroutineScope { }` per connection with a `withTimeout` on idle reads.**

**What was done:**
- Added `idle_timeout_s: u32 = 30` to `Server.Config` and `Server` struct
- Created `receiveWithTimeout()` function in `connection.zig` using `io.select()` to
  race `receiveHead()` against `io.sleep()` — the Zig equivalent of Kotlin's
  `withTimeout(30.seconds) { receiveHead() }`
- When `idle_timeout_s > 0`: spawns two concurrent tasks (`receiveHeadAsync` and
  `idleSleep`) and uses `io.select()` to pick the winner. Loser is canceled.
- When `idle_timeout_s == 0`: fast path — direct `receiveHead()` call (no timeout)
- Properly handles cancellation (server shutdown): cancels both futures, returns null
- Error union discipline: uses `if/else` for non-void results, `catch {}` for void

**Files modified:**
| File | Change |
|------|--------|
| `connection.zig` | Added `receiveWithTimeout()`, `receiveHeadAsync()`, `idleSleep()`; `idle_timeout_s` param on all entry points |
| `server.zig` | Added `idle_timeout_s` to Config + Server; passes to `Connection.handleAsync` |

**Verification:** All 64 unit tests pass. All 10 integration tests pass. All executables build.

**Deliverable:** Idle keep-alive connections auto-close after 30s, freeing resources.

---

#### 11b-3: Request-Level Timeout (COMPLETE)

**Model: `withTimeout(10.seconds) { handler(request, response) }`**

**What was done:**
- Renamed `idleSleep` → `sleepSeconds` (shared by idle and request timeouts)
- Added `callHandlerWrapper` function for dispatching handler via `io.async()`
- Added `DispatchResult` enum (`ok`, `handler_error`, `timeout`, `canceled`)
- Added `dispatchHandler` function that races handler vs deadline via `io.select()`
- On timeout: cancels handler, sends 503 with `CancelProtection` (immune to shutdown cancel)
- Added `request_timeout_s: u32 = 10` to `Server.Config` and `Server` struct
- Passed `request_timeout_s` through entire call chain

**Files modified:**
| File | Change |
|------|--------|
| `connection.zig` | Added `dispatchHandler`, `callHandlerWrapper`, `DispatchResult`; `request_timeout_s` param throughout |
| `server.zig` | Added `request_timeout_s` to Config + Server; passes to `Connection.handleAsync` |

**Verification:** All 64 unit tests pass. All 10 integration tests pass. All executables build.

**Deliverable:** Slow handlers are canceled after N seconds; client gets 503 Service Unavailable.

---

#### 11b-4: Graceful Shutdown (COMPLETE)

**Model: Kotlin's `scope.cancel()` + `scope.join()` pattern.**

**What was done:**
- Changed `Server.run()` return type from `void` to `Io.Cancelable!void`
- Added `error.Canceled` handling in the accept loop — stops accepting on shutdown
- `defer group.cancel(io)` ensures all in-flight connections are canceled and awaited
- Connections already use `CancelProtection` around 503 writes (from 11b-3)
- Updated `http_server_main.zig` to handle `error.Canceled` gracefully with a message
- Updated `integration_test.zig` and `benchmark.zig` to `catch {}` on `run()`

**Shutdown flow:**
1. Caller cancels the server's accept task (via external signal or future cancel)
2. `accept()` returns `error.Canceled` → accept loop breaks
3. `defer group.cancel(io)` runs → sends `error.Canceled` to all connection tasks
4. Each connection finishes its current response (CancelProtection on writes)
5. `group.cancel()` awaits all tasks → returns when all are drained
6. `run()` returns `error.Canceled` → caller prints graceful shutdown message

**Files modified:**
| File | Change |
|------|--------|
| `server.zig` | `run()` returns `Cancelable!void`, handles `error.Canceled` in accept |
| `http_server_main.zig` | Handles `error.Canceled` from `run()` |
| `integration_test.zig` | Background server thread catches `run()` error |
| `benchmark.zig` | Background server thread catches `run()` error |

**Verification:** All 64 unit tests pass. All 10 integration tests pass. All executables build.

**Deliverable:** Server shuts down gracefully — drains in-flight requests before exiting.

---

#### 11b-5: Handler Concurrency (Fan-Out / Fan-In)

**Model: Kotlin `coroutineScope { async { } + async { } }` inside a handler.**

Handlers can spawn concurrent sub-tasks bounded by the request's lifetime.
When the handler returns (or is canceled), all sub-tasks are guaranteed complete:

```zig
// Kotlin:
// suspend fun handleDashboard(req: Request): Response {
//     coroutineScope {
//         val profile = async { fetchProfile(req.userId) }
//         val notifs  = async { fetchNotifications(req.userId) }
//         render(profile.await(), notifs.await())
//     }
// }

// Zig:
fn handleDashboard(request: *Request, response: *Response, io: Io) anyerror!void {
    const user_id = request.pathParam("id") orelse return error.BadRequest;

    // Fan-out: two concurrent fetches
    var profile_future = io.async(fetchProfile, .{ user_id, io, request.arena });
    var notifs_future  = io.async(fetchNotifications, .{ user_id, io, request.arena });

    // Fan-in: await both (order doesn't matter, both run concurrently)
    const profile = profile_future.await(io);
    const notifs  = notifs_future.await(io);

    // Combine results
    const body = try std.fmt.allocPrint(
        request.arena,
        "Profile: {s}\nNotifications: {d}\n",
        .{ profile.name, notifs.count },
    );
    try response.sendText(.ok, body);
}
```

**For fire-and-forget sub-tasks** (logging, analytics), use a request-scoped Group:

```zig
fn handleOrder(request: *Request, response: *Response, io: Io) anyerror!void {
    var tasks: Io.Group = .init;
    defer tasks.cancel(io);  // ← structured: all children done when handler returns

    // Fire-and-forget: send analytics event
    tasks.async(io, sendAnalyticsEvent, .{ "order_placed", request.path, io });

    // Main work
    const order = try processOrder(request, io);
    try response.sendJson(.ok, order);

    // Await fire-and-forget tasks before returning
    tasks.await(io) catch {};
}
```

**Files to modify:**
| File | Change |
|------|--------|
| `http_server_main.zig` | Add example `/dashboard` route with fan-out |
| (no framework changes needed) | Handlers already receive `Io` from 11b-1 |

**Deliverable:** Example handler demonstrating concurrent sub-tasks with structured lifetime.

**What was done:**
- Added `/dashboard/:id` route to `http_server_main.zig` demonstrating the fan-out/fan-in pattern
- `fetchProfile()` and `fetchNotifications()` simulate concurrent async data fetches with `io.sleep()` latency
- `handleDashboard()` spawns both via `io.async()`, awaits both results, combines into a single response
- Error handling properly cancels the remaining future if one fails
- Updated welcome page (`/`) to list the new route
- All 64 unit tests pass, all 10 integration tests pass, all executables build
- No framework changes needed — handlers already receive `Io` from 11b-1

---

#### 11b-6: Background Tasks & Metrics

**Model: Kotlin's long-lived `launch { }` inside a scope.**

Background tasks (metrics collection, periodic cleanup) run as children of the
server scope. They're automatically canceled on shutdown:

```zig
pub fn run(self: *Server, io: Io) Io.Cancelable!void {
    var group: Io.Group = .init;
    defer group.cancel(io);

    // Background task: periodic metrics reporter
    group.async(io, metricsReporter, .{ io, &self.stats });

    // Accept loop
    while (true) {
        const stream = self.tcp_server.accept(io) catch |err| switch (err) {
            error.Canceled => break,
            // ...
        };
        // Increment active connections
        _ = self.stats.active_connections.fetchAdd(1, .monotonic);
        group.async(io, Connection.handleAsync, .{ stream, io, ..., &self.stats });
    }

    group.await(io) catch {};
}

fn metricsReporter(io: Io, stats: *Stats) Io.Cancelable!void {
    while (true) {
        try io.sleep(Duration.fromSeconds(10), .awake);  // yields Canceled on shutdown
        const active = stats.active_connections.load(.monotonic);
        const total = stats.total_requests.load(.monotonic);
        std.debug.print("[metrics] active={d} total={d}\n", .{ active, total });
    }
}
```

**Stats struct (atomic for cross-fiber/thread safety):**
```zig
pub const Stats = struct {
    active_connections: std.atomic.Value(u64) = .init(0),
    total_requests: std.atomic.Value(u64) = .init(0),
    start_time: Io.Timestamp = undefined,
};
```

**Optional: `/metrics` endpoint** returning JSON stats (uses handler `Io` from 11b-1).

**Files to modify:**
| File | Change |
|------|--------|
| `server.zig` | Add `Stats` struct, spawn metrics reporter in server scope |
| `connection.zig` | Increment/decrement active connections, count requests |
| `http_server_main.zig` | Optional `/metrics` route |

**Deliverable:** Real-time server metrics logged every 10s; `/metrics` JSON endpoint.

**What was done:**
- Added `Stats` struct to `server.zig` with atomic counters: `active_connections`, `total_requests`, `total_connections`
- `metricsReporter()` background task spawned in server scope via `group.async()` — periodically logs stats, automatically canceled on shutdown
- Connection handler increments `active_connections` on connect (decrements on disconnect via `defer`) and `total_requests` per parsed request
- Server increments `total_connections` on accept
- Added `metrics_interval_s` config option (default 10s, 0 = disable)
- Added `/metrics` route returning JSON: `{"active_connections":N,"total_requests":N,"total_connections":N}`
- Module-level `server_stats` pointer provides handler access to Stats without framework changes
- Disabled metrics logging in integration tests and benchmarks to avoid noise
- All 64 unit tests pass, all 10 integration tests pass, all executables build

---

#### 11b-7: Structured Concurrency Integration Tests

**Add tests that verify the structured concurrency guarantees:**

| Test | What it verifies |
|------|-----------------|
| Idle timeout fires | Connection closed after N seconds of inactivity |
| Idle timeout doesn't fire | Active connection stays open past timeout window |
| Request timeout fires | Slow handler returns 503 |
| Graceful shutdown drains | In-flight request completes before server exits |
| Cancel propagation | Server cancel → connection cancel → handler cancel chain |
| Handler fan-out | Concurrent sub-tasks complete before response |
| Handler fan-out cancel | Sub-tasks canceled when handler times out |
| Metrics counting | Active connections counter is accurate |

**Files to create/modify:**
| File | Change |
|------|--------|
| `integration_test.zig` | Add 8+ new structured concurrency tests |
| `benchmark.zig` | Optional: timeout-aware benchmarks |

**Deliverable:** Comprehensive test suite proving structured concurrency invariants.

**What was done:**
- Created second test server on port 18081 with short timeouts (`idle_timeout_s=3`, `request_timeout_s=2`)
- Added SC-specific handlers: `handleSlow` (sleeps 5s, triggers timeout), `handleFast` (instant), `handleFanOut` (concurrent sub-tasks)
- 6 new structured concurrency tests:
  1. **Request timeout fires → 503**: Slow handler exceeds 2s timeout, gets 503 with "Request Timeout"
  2. **Fast handler under timeout → 200**: Quick handler completes before deadline
  3. **Fan-out sub-tasks complete**: `io.async()` spawns two concurrent tasks, both results present in response
  4. **Server stable after timeouts**: Server continues accepting after timeout/cancel activity
  5. **Timeout yields 503 then closes**: Connection properly closes after request timeout
  6. **Active conn not timed out**: Active connections don't trigger idle timeout
- Total test count: 16/16 pass (10 original + 6 SC tests)
- All 64 unit tests pass, all executables build

---

### Architecture After Step 11b (Target State)

```
┌──────────────────── Server Scope (Io.Group) ────────────────────┐
│                                                                  │
│  ┌─────────────┐  ┌──────────────┐                              │
│  │ Accept Loop │  │ Metrics Task │  (background, periodic)      │
│  │ (cancelable)│  │  (cancelable)│                              │
│  └──────┬──────┘  └──────────────┘                              │
│         │                                                        │
│    accept()                                                      │
│         │                                                        │
│  ┌──────▼──── Connection Scope (per-conn lifetime) ──────────┐  │
│  │                                                            │  │
│  │  ┌─────────────────┐                                      │  │
│  │  │ Idle Timeout     │  io.select(read vs sleep)           │  │
│  │  │ (30s default)    │                                      │  │
│  │  └─────────────────┘                                      │  │
│  │                                                            │  │
│  │  ┌──── Request Scope (per-request lifetime) ──────────┐   │  │
│  │  │                                                     │   │  │
│  │  │  ┌──────────────┐  io.select(handler vs deadline)  │   │  │
│  │  │  │ Req Timeout  │  (10s default)                   │   │  │
│  │  │  └──────────────┘                                  │   │  │
│  │  │                                                     │   │  │
│  │  │  Handler(request, response, io)                    │   │  │
│  │  │  ├── io.async(subTaskA)  ← fan-out                 │   │  │
│  │  │  ├── io.async(subTaskB)  ← fan-out                 │   │  │
│  │  │  └── future.await()      ← fan-in                  │   │  │
│  │  │                                                     │   │  │
│  │  │  CancelProtection { response.flush() }             │   │  │
│  │  │                                                     │   │  │
│  │  └─── arena.reset(.retain_capacity) ──────────────────┘   │  │
│  │                                                            │  │
│  │  (keep-alive → next Request Scope)                        │  │
│  │                                                            │  │
│  └─── stream.close() ── arena.deinit() ──────────────────────┘  │
│                                                                  │
│  (shutdown → group.cancel() → cascades to all)                  │
└──────────────────────────────────────────────────────────────────┘
```

### Key Design Principles

1. **Scoped lifetime = `defer group.cancel(io)`** — every Group is created with
   a defer that ensures all children are cleaned up, even on early return or error.
   This is the Zig equivalent of Kotlin's `coroutineScope { }`.

2. **No orphaned tasks** — unlike `go func()` in Go, every async task is a child
   of a Group or tracked as a Future. Nothing escapes its scope.

3. **Cancel propagation is cooperative** — tasks receive `error.Canceled` at their
   next Io operation. They must propagate it (enforced by assertion). This matches
   Kotlin's cooperative cancellation via `isActive/ensureActive()`.

4. **CancelProtection for critical sections** — response writes must complete
   atomically (partial HTTP responses corrupt the protocol). Wrap them in
   `io.swapCancelProtection(.blocked)`, equivalent to Kotlin's `withContext(NonCancellable)`.

5. **Timeouts via racing** — `io.select(.{op, sleep})` is the universal timeout
   pattern, equivalent to Kotlin's `withTimeout()`. No special timeout API needed.

6. **Arenas are per-connection, not per-thread** — fibers migrate between OS threads
   in the Evented backend. Thread-local state is unsound. Arenas travel with the
   fiber/task stack.

---

## Step 12: JSON Body Parsing & Struct Serialization (IN PROGRESS)

**Goal:** Enable handlers to parse incoming JSON request bodies into typed Zig
structs, and serialize Zig structs back as JSON responses — using `std.json`
from the standard library with arena-per-request for zero-cost cleanup.

### Design

**Zig's `std.json` standard library provides:**
- `std.json.parseFromSliceLeaky(T, allocator, slice, opts)` — deserialize JSON
  bytes into a Zig struct `T`. The "Leaky" variant skips individual cleanup
  tracking — perfect for arena allocators where everything is freed in bulk.
- `std.json.Stringify` — streaming serializer that writes any Zig struct/value
  directly to an `Io.Writer`. No intermediate `[]const u8` buffer needed.

### Sub-steps

#### 12-1: Request Body Reading (`readBody`)

**File:** `request.zig`, `connection.zig`

**What:** Add `Request.readBody()` that reads the full request body into an
arena-allocated `[]const u8`. Requires passing a body `*Io.Reader` from the
connection layer into the Request.

**How body reading works in `std.http.Server`:**
```zig
// After receiveHead(), get a body reader:
const body_reader: *Io.Reader = http_request.readerExpectNone(&body_buffer);
// Read all content into arena:
const body: []const u8 = body_reader.allocRemaining(arena, max_body_size);
```

**Key design choice:** The body reader is obtained from `http.Server.Request`
and consumes the underlying TCP stream. It must be called once per request and
before sending the response. We store the resulting `[]const u8` on the Request
so handlers can access it repeatedly.

**Performance:**
- Body is read into the arena (O(1) bulk free at request end)
- `allocRemaining()` reads directly into arena-allocated memory (single copy
  from kernel → userspace → arena, no intermediate buffer)
- Max body size is configurable (default 1MB) to prevent OOM attacks

#### 12-2: JSON → Struct Deserialization (`jsonBody(T)`)

**File:** `request.zig`

**What:** Add `Request.jsonBody(comptime T: type) !T` that:
1. Reads the body (if not already read)
2. Validates `Content-Type: application/json`
3. Calls `std.json.parseFromSliceLeaky(T, arena, body, .{})`

**Zig implementation plan:**
```zig
pub fn jsonBody(self: *Request, comptime T: type) !T {
    const body = self.body orelse return error.NoBody;
    return std.json.parseFromSliceLeaky(T, self.arena, body, .{
        .ignore_unknown_fields = true,
    });
}
```

**Performance:**
- `parseFromSliceLeaky` allocates into the request arena — all temporary
  parse state and the resulting struct are freed in one O(1) arena reset
- String values in the parsed struct are slices into `body` when possible
  (`.alloc_if_needed` default for `parseFromSlice`) — zero-copy for most strings
- No separate `Parsed(T)` wrapper with its own arena — we reuse the request arena
- `ignore_unknown_fields = true` for forward compatibility (clients can add fields)

#### 12-3: Struct → JSON Response (`sendJsonValue`)

**File:** `response.zig`

**What:** Add `Response.sendJsonValue(status, value)` that serializes any Zig
struct directly to the HTTP response as JSON.

**Challenge:** We need to know Content-Length before sending headers, but
`Stringify` is a streaming writer. Two approaches:

- **Option A:** Serialize to an arena-allocated buffer first, then send with
  known Content-Length. Simple, but requires buffering the entire JSON.
- **Option B:** Use chunked transfer encoding to stream without knowing length.
  More complex, but zero-copy streaming.

**Chosen: Option A** — serialize to arena buffer, then send. Reasons:
- Most JSON API responses are small (< 64KB)
- Keeps Content-Length header (simpler for clients)
- Arena allocation is nearly free (bump pointer)
- Matches existing `sendJson()` pattern

**Zig implementation plan:**
```zig
pub fn sendJsonValue(self: *Response, status: http.Status, value: anytype) !void {
    const body = try std.json.valueAlloc(self.arena, value, .{});
    self.status = status;
    self.body = body;
    try self.addHeader("content-type", "application/json; charset=utf-8");
    try self.flush();
}
```

**Performance:**
- `std.json.Stringify.valueAlloc()` serializes into arena memory
- Arena buffer reused across requests (retain_capacity)
- Single vectored write for the full response (existing `flush()` path)
- No `std.fmt` formatting overhead — Stringify writes directly

#### 12-4: Handler Demos & Tests

**File:** `http_server_main.zig`, `request.zig`, `response.zig`

**What:**
- Add `POST /api/echo-json` handler that parses JSON body and echoes it back
- Add unit tests for `readBody()`, `jsonBody(T)`, `sendJsonValue()`
- Update integration tests

**Example handler:**
```zig
const CreateUser = struct {
    name: []const u8,
    email: []const u8,
    age: ?u32 = null,
};

fn handleCreateUser(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const user = try request.jsonBody(CreateUser);
    // user.name, user.email, user.age are now typed fields
    // user.name is a slice into the request body buffer (zero-copy!)
    const result = .{ .id = 1, .name = user.name, .created = true };
    try response.sendJsonValue(.created, result);
}
```

### Performance Summary

| Operation | Allocation | Copies | Cleanup |
|-----------|-----------|--------|---------|
| Body read | Arena bump | 1 (kernel→arena) | O(1) arena reset |
| JSON parse | Arena bump (leaky) | 0 (slices into body) | O(1) arena reset |
| JSON serialize | Arena bump | 1 (struct→buffer) | O(1) arena reset |
| Full response | Vectored write | 1 (buffer→socket) | O(1) arena reset |

Everything goes through the per-request arena. No malloc, no free, no GC.
---

## Step 13: PostgreSQL Database Integration (COMPLETE)

### Overview

Add a full database layer to the HTTP server using **pg.zig** — a native,
pure-Zig PostgreSQL driver. This step introduces:

- A connection pool backed by `pg.Pool`
- Docker Compose for local PostgreSQL 16
- A repository pattern for type-safe CRUD operations
- REST API handlers wiring JSON (Step 12) to the database
- **SQL injection prevention** via PostgreSQL's native parameterized query
  protocol (parameters are sent as binary data, never interpolated into SQL)

### Implementation Notes (Completed Sub-Steps)

#### Zig 0.16 Compatibility Issue & Resolution

pg.zig `master` targets Zig 0.15 and is **incompatible** with Zig 0.16.0-dev:
- `std.Thread.Mutex` → moved to `std.atomic.Mutex`
- `@Type` builtin → removed/changed (used in metrics.zig dependency)
- `Step.Compile.addLibraryPath()` → `Module.addLibraryPath()`

**Solution:** Switched to the **zigster64/pg.zig `zig16` branch** — an active
community fork (28 commits ahead of master, PR #107) that ports all pg.zig
dependencies (metrics.zig, buffer) to Zig 0.16's new async I/O (`std.Io`) and
updated stdlib APIs.

```powershell
zig fetch --save git+https://github.com/zigster64/pg.zig#zig16
```

#### API Differences (zig16 branch vs master)

| API | pg.zig master (Zig 0.15) | pg.zig zig16 |
|-----|--------------------------|--------------|
| `Pool.init()` | `(allocator, opts)` | `(allocator, io, opts)` — **requires `std.Io`** |
| `Pool.Opts.timeout` | `u32` (milliseconds) | `Io.Duration` (`.fromSeconds(10)`) |
| `pool.query()` | Returns `Result` (value) | Returns `*Result` (pointer) |
| `pool.exec()` | Returns `?usize` | Returns `?i64` |
| `pool.row()` | Returns `?QueryRow` | Returns `?QueryRow` (value, use `var qr = qr_val;` for mutability) |
| `Conn.open()` | `(allocator, opts)` | `(allocator, io, opts)` |
| `std.ArrayList` | `.init(allocator)` | `.empty` + `.append(allocator, item)` (Zig 0.16 stdlib change) |

#### 13-1: pg.zig Dependency ✅

- Added `zigster64/pg.zig#zig16` to `build.zig.zon` via `zig fetch --save`
- Added `pg_dep` and `pg_module` to `build.zig`, imported to both `mod` and `http_server_exe`
- All transitive dependencies (buffer, metrics) resolve and compile on Zig 0.16

#### 13-2: Docker Compose ✅

- Created `docker/compose.yml` — PostgreSQL 16 with healthcheck
- Created `docker/init.sql` — `users` table + 3 seed rows (Alice, Bob, Charlie)
- Port 5432, credentials: ziglearn/ziglearn

#### 13-3: Database Module ✅

- Created `src/http/database.zig` — thin wrapper around `pg.Pool`
- `Config` struct with sensible defaults matching Docker Compose setup
- `init(allocator, io, config)` accepts `std.Io` for the async runtime
- Convenience methods: `query()`, `exec()`, `row()`, `acquire()`, `release()`

#### 13-4: User Repository ✅

- Created `src/http/user_repository.zig`
- `User` struct: `id: i32, name: []const u8, email: []const u8, age: ?i32`
- CRUD: `getAll()`, `getById()`, `create()`, `update()`, `delete()`
- **All queries use `$1`, `$2` parameterized placeholders** — zero SQL string interpolation
- String fields duped into caller's arena via `qr.to(User, .{ .allocator = arena })`
- `var qr = qr_val;` pattern for mutable QueryRow access (Zig 0.16 const-capture semantics)

#### 13-5: REST API Handlers ✅

- 5 new routes registered in comptime router:
  - `GET /api/users`, `POST /api/users`
  - `GET /api/users/:id`, `PUT /api/users/:id`, `DELETE /api/users/:id`
- CLI arguments: `--no-db`, `--db-host`, `--db-port`
- Graceful DB fallback: if PostgreSQL unreachable, server starts without DB (503 on DB routes)
- `global_db` module-level `?*http.Database` set during startup
- Helper: `getUserRepo()` returns `?UserRepository` or sends 503
- Helper: `parseUserId()` parses `:id` param as `i32` or sends 400
- Updated index handler to list REST API routes
- Startup banner shows DB status (connected/disabled)

### Why pg.zig?

| Criterion | pg.zig | libpq (C bindings) |
|-----------|--------|--------------------|
| Language | Pure Zig | C via `@cImport` |
| Stars | 492 | N/A (PostgreSQL official) |
| Connection Pool | Built-in (`pg.Pool`) | External (PgBouncer) |
| Parameterized Queries | `$1`, `$2` binary protocol | `PQexecParams` |
| Row → Struct Mapping | `row.to(T, .{})` | Manual |
| Prepared Stmt Cache | Built-in (`cache_name`) | Manual |
| Transactions | `conn.begin/commit/rollback` | Raw SQL |
| Zig Version | 0.15+ (actively updated) | Any (C ABI stable) |
| Windows Support | ✅ (PR #98 merged) | Requires libpq DLL |
| Dependencies | Zero | libpq, potentially OpenSSL |

**Decision: pg.zig** — pure Zig, zero external dependencies, built-in pooling,
type-safe row mapping, and actively maintained (last commit: 4 days ago).

### SQL Injection Prevention Strategy

pg.zig uses **PostgreSQL's extended query protocol** where SQL and parameters
are sent in separate protocol messages. The flow is:

```
Client → Server:  Parse("SELECT * FROM users WHERE id = $1")
Client → Server:  Bind(parameters: [42])    ← binary data, NOT string interpolation
Client → Server:  Execute
Server → Client:  DataRow(...)
```

Parameters **never touch the SQL parser**. Even if a user sends
`'; DROP TABLE users; --` as a parameter, PostgreSQL treats it as a literal
string value, not SQL. This is the gold standard for injection prevention —
superior to string escaping.

**Rules we enforce:**
1. **All queries use `$1`, `$2`, ... placeholders** — no string concatenation
2. **No `std.fmt` for SQL** — never `std.fmt.bufPrint("WHERE id = {d}", .{id})`
3. **pg.zig binds values via the binary protocol** — type-checked at bind time
4. **Column reads are type-strict** — `row.get(i32, 0)` fails on type mismatch

### Async Integration Analysis

**How pg.zig works with `std.Io`:**

pg.zig uses `std.net.Stream` for TCP communication. On Zig 0.16:

- **Threaded backend (Windows):** Each HTTP handler runs on a thread pool
  thread. pg.zig's blocking socket calls execute normally — the thread blocks
  during DB I/O, but other connections continue on other threads. This is the
  standard thread-per-request model used by most database drivers.

- **Evented backend (Linux io_uring / macOS kqueue):** Zig's fiber scheduler
  intercepts socket syscalls. When pg.zig calls `read()` on its socket, the
  runtime suspends the fiber and resumes it when data arrives. This gives us
  **non-blocking DB I/O for free** — no code changes needed.

**Connection pool thread safety:** `pg.Pool` is designed for multi-threaded use.
`acquire()` and `release()` are thread-safe. The pool runs one background thread
for reconnecting failed connections.

### Sub-Steps

#### 13-1: Add pg.zig Dependency & Build Integration

**What:** Add pg.zig as a Zig package dependency and wire it into the build.

**Commands:**
```powershell
cd c:\Projects\Personal\learn-zig-main
zig fetch --save git+https://github.com/karlseguin/pg.zig#master
```

**build.zig.zon changes:** `zig fetch --save` auto-adds the dependency with hash.

**build.zig changes:** Add pg module to http_server_exe:
```zig
const pg_module = b.dependency("pg", .{
    .target = target,
    .optimize = optimize,
}).module("pg");

// Add to http_server_exe's imports:
.imports = &.{
    .{ .name = "learn_zig", .module = mod },
    .{ .name = "pg", .module = pg_module },
},
```

#### 13-2: Docker Compose Setup (PostgreSQL 16)

**Files to create:**
- `docker/compose.yml` — PostgreSQL 16 service
- `docker/init.sql` — Schema initialization (runs on first `docker compose up`)

**docker/compose.yml:**
```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: "ziglearn"
      POSTGRES_PASSWORD: "ziglearn"
      POSTGRES_DB: "ziglearn"
    ports:
      - "5432:5432"
    volumes:
      - "./init.sql:/docker-entrypoint-initdb.d/init.sql:ro"
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ziglearn"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  pgdata:
```

**docker/init.sql:**
```sql
-- Users table for CRUD demo
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    age INT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Seed data
INSERT INTO users (name, email, age) VALUES
    ('Alice', 'alice@example.com', 30),
    ('Bob', 'bob@example.com', 25),
    ('Charlie', 'charlie@example.com', 35);
```

**Usage:**
```powershell
cd docker
docker compose up -d       # Start PostgreSQL in background
docker compose down        # Stop
docker compose down -v     # Stop and delete data volume
```

#### 13-3: Database Module (`src/http/database.zig`)

**What:** Thin wrapper around `pg.Pool` for server lifecycle integration.

**Design:**
```zig
const pg = @import("pg");

pub const Database = struct {
    pool: *pg.Pool,

    pub const Config = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 5432,
        username: []const u8 = "ziglearn",
        password: []const u8 = "ziglearn",
        database: []const u8 = "ziglearn",
        pool_size: u32 = 10,
        timeout: u32 = 10_000,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Database {
        const pool = try pg.Pool.init(allocator, .{
            .size = config.pool_size,
            .connect = .{
                .port = config.port,
                .host = config.host,
            },
            .auth = .{
                .username = config.username,
                .database = config.database,
                .password = config.password,
                .timeout = config.timeout,
            },
        });
        return .{ .pool = pool };
    }

    pub fn deinit(self: *Database) void {
        self.pool.deinit();
    }

    /// Convenience: execute a query and return result
    pub fn query(self: *Database, sql: []const u8, args: anytype) !pg.Result {
        return self.pool.query(sql, args);
    }

    /// Convenience: execute a command (INSERT/UPDATE/DELETE)
    pub fn exec(self: *Database, sql: []const u8, args: anytype) !?usize {
        return self.pool.exec(sql, args);
    }

    /// Convenience: get a single row
    pub fn row(self: *Database, sql: []const u8, args: anytype) !?pg.QueryRow {
        return self.pool.row(sql, args);
    }
};
```

**Lifecycle integration:** Database is initialized in `main()` and passed to
the server, which passes it to handlers via closures or a context struct.

#### 13-4: User Repository (CRUD with Parameterized Queries)

**File:** `src/http/user_repository.zig`

**What:** Type-safe CRUD operations for the `users` table. Every query uses
`$1`, `$2` parameterized placeholders.

**Design:**
```zig
pub const User = struct {
    id: i32,
    name: []const u8,
    email: []const u8,
    age: ?i32 = null,
};

pub const CreateUserInput = struct {
    name: []const u8,
    email: []const u8,
    age: ?i32 = null,
};

pub const UserRepository = struct {
    db: *Database,

    pub fn getAll(self: *UserRepository) !pg.Result {
        return self.db.query(
            "SELECT id, name, email, age FROM users ORDER BY id",
            .{},
        );
    }

    pub fn getById(self: *UserRepository, id: i32) !?User {
        var query_row = try self.db.row(
            "SELECT id, name, email, age FROM users WHERE id = $1",
            .{id},
        ) orelse return null;
        defer query_row.deinit() catch {};
        return query_row.to(User, .{}) catch return null;
    }

    pub fn create(self: *UserRepository, input: CreateUserInput) !?User {
        var query_row = try self.db.row(
            "INSERT INTO users (name, email, age) VALUES ($1, $2, $3) RETURNING id, name, email, age",
            .{ input.name, input.email, input.age },
        ) orelse return null;
        defer query_row.deinit() catch {};
        return query_row.to(User, .{}) catch return null;
    }

    pub fn update(self: *UserRepository, id: i32, input: CreateUserInput) !?User {
        var query_row = try self.db.row(
            "UPDATE users SET name = $1, email = $2, age = $3 WHERE id = $4 RETURNING id, name, email, age",
            .{ input.name, input.email, input.age, id },
        ) orelse return null;
        defer query_row.deinit() catch {};
        return query_row.to(User, .{}) catch return null;
    }

    pub fn delete(self: *UserRepository, id: i32) !bool {
        const affected = try self.db.exec(
            "DELETE FROM users WHERE id = $1",
            .{id},
        );
        return (affected orelse 0) > 0;
    }
};
```

**SQL Injection Safety:**
- Every SQL string is a compile-time literal — no runtime string building
- All user data flows through `$1`, `$2`, ... parameters
- pg.zig sends parameters via PostgreSQL's binary protocol
- Type checking at bind time (e.g., passing a string where `i32` expected → error)

#### 13-5: REST API Handlers (JSON + DB)

**File:** `src/http_server_main.zig` (new routes + handlers)

**New routes:**
```
GET    /api/users       → listUsers    (returns JSON array)
GET    /api/users/:id   → getUser      (returns JSON object or 404)
POST   /api/users       → createUser   (JSON body → DB → 201 JSON)
PUT    /api/users/:id   → updateUser   (JSON body → DB → 200 JSON)
DELETE /api/users/:id   → deleteUser   (DB → 204 No Content)
```

**Handler pattern:**
```zig
fn handleListUsers(request: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    _ = io;
    const repo = getUserRepo(request);  // get from request context
    var result = try repo.getAll();
    defer result.deinit();

    var users = std.ArrayList(User).init(request.arena);
    while (try result.next()) |row| {
        try users.append(try row.to(User, .{ .allocator = request.arena }));
    }
    try response.sendJsonValue(.ok, users.items);
}

fn handleCreateUser(request: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    _ = io;
    const body = try request.readBody(io.reader());  // read from network
    _ = body;
    const input = try request.jsonBody(CreateUserInput);
    const repo = getUserRepo(request);
    if (try repo.create(input)) |user| {
        try response.sendJsonValue(.created, user);
    } else {
        try response.sendJsonValue(.internal_server_error, .{ .@"error" = "Failed to create user" });
    }
}
```

**Context passing:** The `Database` / `UserRepository` needs to be accessible
from handlers. Options:
- **Option A:** Store `*Database` in a global/server-level context passed through
  the router (requires modifying handler signature or router)
- **Option B:** Use a closure that captures the database pointer
- **Option C:** Thread-local or connection-level context

We'll evaluate the best approach during implementation. The router currently
passes `(request, response, io)` — we may need to add an `app_context` parameter
or use the server's allocator to store the DB handle.

#### 13-6: Integration Tests & Documentation

**Status:** ✅ COMPLETE

**Database Integration Tests** (`src/db_integration_test.zig`):

| # | Test | What it verifies |
|---|------|-----------------|
| 1 | DB connection — acquire/release | Pool init succeeded, connections work |
| 2 | List seed users (≥ 3) | Seed data from `init.sql` is present |
| 3 | Create user → verify fields | INSERT RETURNING works, ID > 0, fields match |
| 4 | Get user by ID → verify fields | SELECT WHERE id=$1, all columns correct |
| 5 | List all users → count +1 | Row count increased after create |
| 6 | Update user → verify changed | UPDATE RETURNING, name/email/age changed |
| 7 | Get nonexistent user → null | SELECT with bad ID returns null (no crash) |
| 8 | Delete user → verify removed | DELETE + subsequent GET returns null |
| 9 | SQL injection → stored literally | `'; DROP TABLE users; --` stored as string, table intact |
| 10 | Unique constraint → error/null | Duplicate email INSERT rejected by UNIQUE constraint |

**Run:** `zig build db-integration-test` (requires `cd docker && docker compose up -d`)

**File reorganization:** Moved database files from `src/http/` to `src/db/`:
- `src/db/db.zig` — module root, re-exports `Database` + `UserRepository`
- `src/db/database.zig` — `pg.Pool` wrapper with `Config` struct
- `src/db/user_repository.zig` — type-safe CRUD for `users` table
- `src/root.zig` — now exports both `http` and `db` modules
- `src/http_server_main.zig` — imports `db` module separately from `http`

**Documentation updates:**
- `docs/ARCHITECTURE.md` — Added DB layer to system diagram, updated module dependency graph and file layout
- `docs/PERFORMANCE.md` — Added Section 15: Connection Pool Performance
- `BUILD_AND_RUN.md` — Added Docker setup instructions, `--no-db` flag, `db-integration-test` command

### File Plan

| File | Action | Description |
|------|--------|-------------|
| `build.zig.zon` | MODIFY | Add pg.zig dependency |
| `build.zig` | MODIFY | Wire pg module into executables + db-integration-test step |
| `docker/compose.yml` | CREATE | PostgreSQL 16 container |
| `docker/init.sql` | CREATE | Schema + seed data |
| `src/db/db.zig` | CREATE | DB module root — re-exports Database + UserRepository |
| `src/db/database.zig` | CREATE | Pool wrapper + config |
| `src/db/user_repository.zig` | CREATE | Type-safe CRUD operations |
| `src/root.zig` | MODIFY | Export db module |
| `src/http/http.zig` | MODIFY | Remove DB exports (moved to src/db/) |
| `src/http_server_main.zig` | MODIFY | Add REST routes + handlers, import db module |
| `src/db_integration_test.zig` | CREATE | 10 DB integration tests (requires PostgreSQL) |
| `docs/PERFORMANCE.md` | MODIFY | Section 15: Connection pool performance |
| `docs/ARCHITECTURE.md` | MODIFY | DB layer diagram + module dependency graph |
| `BUILD_AND_RUN.md` | MODIFY | Docker instructions + db-integration-test docs |

### Performance Considerations

| Aspect | Strategy |
|--------|----------|
| Connection reuse | `pg.Pool` keeps N connections open (default 10) |
| Query overhead | Parameterized queries: Parse → Bind → Execute (3 round-trips, cacheable) |
| Cached prepared stmts | `cache_name` option skips Parse+Describe after first execution |
| Row mapping | `row.to(T, .{})` is zero-alloc for scalar fields; strings need `.dupe = true` or arena allocator |
| Memory | Pass request arena to `queryOpts(.{.allocator = arena})` — all query results freed in one O(1) reset |
| Pooling thread-safety | `pg.Pool.acquire/release` are thread-safe — safe for concurrent handlers |
| Reconnection | Pool runs background thread to reconnect failed connections automatically |