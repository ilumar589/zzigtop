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
| 11b | Structured concurrency (Kotlin-style scoped lifetimes) | 🔲 NOT STARTED |
| | 11b-1: Handler signature — pass `Io` to handlers | 🔲 |
| | 11b-2: Connection scope — idle timeout via `io.select()` | 🔲 |
| | 11b-3: Request timeout — `withTimeout` around handlers | 🔲 |
| | 11b-4: Graceful shutdown — cancel/drain server scope | 🔲 |
| | 11b-5: Handler concurrency — `io.async()` fan-out | 🔲 |
| | 11b-6: Background tasks — metrics, health monitoring | 🔲 |
| | 11b-7: Integration tests — verify SC guarantees | 🔲 |

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

#### 11b-1: Handler Signature Change (Foundation)

**Why first:** Every subsequent step needs `Io` inside handlers or connection logic.
In Kotlin, every coroutine function has access to the `CoroutineScope`. Here, `Io`
is the equivalent — it's the handle to the async runtime.

**Change `HandlerFn` signature:**
```zig
// Before:
pub const HandlerFn = *const fn (*Request, *Response) anyerror!void;

// After:
pub const HandlerFn = *const fn (*Request, *Response, Io) anyerror!void;
```

**Files to modify:**
| File | Change |
|------|--------|
| `router.zig` | `HandlerFn` type adds `Io` parameter |
| `connection.zig` | Pass `io` when calling `match.handler(&request, &response, io)` |
| `http_server_main.zig` | All 4 handlers gain `io: Io` (use `_ = io;` for now) |
| `request.zig` | Optionally store `io` in Request for convenience |
| `integration_test.zig` | Update test handler signatures |
| `benchmark.zig` | Update benchmark handler signatures |

**Deliverable:** All handlers receive `Io`, enabling structured concurrency in later steps.

---

#### 11b-2: Connection Scope with Idle Timeout

**Model: `coroutineScope { }` per connection with a `withTimeout` on idle reads.**

Each connection becomes its own scope. Inside that scope, an idle-timeout task
races against the `receiveHead()` call:

```zig
// Kotlin equivalent:
// coroutineScope {
//     withTimeout(30.seconds) {
//         val request = receiveHead()
//     }
// }

// Zig equivalent:
pub fn handleAsync(stream: Io.net.Stream, io: Io, ...) Io.Cancelable!void {
    defer stream.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    // Connection scope — all request processing happens here
    handleRequests(&arena_state, stream, io, router);
}

fn handleRequests(arena_state: ..., stream: ..., io: Io, router: ...) void {
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var stream_writer = stream.writer(io, &write_buffer);
    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        // withTimeout(idle_timeout) { receiveHead() }
        var read_future  = io.async(receiveHeadWrapper, .{&http_server});
        var sleep_future = io.async(sleepFn, .{ io, idle_timeout });

        const head = switch (io.select(.{ .request = &read_future, .timeout = &sleep_future })) {
            .request => |result| result catch break,  // parse error → close
            .timeout => break,                         // idle timeout → close
        } catch break;  // canceled

        sleep_future.cancel(io);  // cancel whichever didn't fire

        // ... handle request ...
    }
}
```

**Config additions to `Server.Config`:**
```zig
/// Idle timeout between requests on a keep-alive connection (seconds).
/// 0 = no timeout. Default: 30s.
idle_timeout_s: u32 = 30,
```

**Files to modify:**
| File | Change |
|------|--------|
| `connection.zig` | Wrap `receiveHead()` in `io.select()` vs `io.sleep()` |
| `server.zig` | Add `idle_timeout_s` to Config, pass to connection |

**Deliverable:** Idle connections auto-close after 30s. Freed resources for other connections.

---

#### 11b-3: Request-Level Timeout

**Model: `withTimeout(10.seconds) { handler(request, response) }`**

Wrap each handler invocation in a select against a deadline. If the handler
takes too long, cancel it and send 503:

```zig
// Kotlin:  withTimeout(10.seconds) { handler(req, res) }

// Zig:
var handler_future = io.async(match.handler, .{ &request, &response, io });
var deadline_future = io.async(sleepFn, .{ io, request_timeout });

switch (io.select(.{ .ok = &handler_future, .timeout = &deadline_future })) {
    .ok => |result| {
        deadline_future.cancel(io);
        result catch { sendInternalError(&http_request) catch {}; };
    },
    .timeout => {
        handler_future.cancel(io);
        // CancelProtection around error response — don't let shutdown
        // interrupt our 503 write
        const old = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old);
        send503(&stream_writer.interface) catch {};
    },
}
```

**Config additions:**
```zig
/// Maximum time for a handler to complete (seconds). 0 = no timeout.
request_timeout_s: u32 = 10,
```

**Files to modify:**
| File | Change |
|------|--------|
| `connection.zig` | Wrap handler call in `io.select()` vs deadline |
| `server.zig` | Add `request_timeout_s` to Config |

**Deliverable:** Slow handlers are canceled after N seconds; client gets 503.

---

#### 11b-4: Graceful Shutdown

**Model: Kotlin's `scope.cancel()` + `scope.join()` pattern.**

The server scope (`Io.Group`) owns all connections. On shutdown:
1. Cancel the accept loop (it sees `error.Canceled` on `accept()`)
2. In-flight connections receive cancel at their next Io call
3. Connections use `CancelProtection` to finish writing the current response
4. `group.await()` blocks until all connections have drained

```zig
// Server.run — now returns when shutdown is requested
pub fn run(self: *Server, io: Io) Io.Cancelable!void {
    var group: Io.Group = .init;
    defer group.cancel(io);  // ensures cleanup on any exit

    while (true) {
        const stream = self.tcp_server.accept(io) catch |err| switch (err) {
            error.Canceled => break,          // ← shutdown signal
            error.ConnectionAborted => continue,
            else => { log(err); continue; },
        };
        group.async(io, Connection.handleAsync, .{ stream, io, ... });
    }

    // Drain: wait for all in-flight connections to finish
    group.await(io) catch {};  // swallow Canceled from children
}
```

**Connection cancel-safety:**
```zig
fn handleInner(...) void {
    while (true) {
        var http_request = http_server.receiveHead() catch |err| switch (err) {
            error.Canceled => break,  // shutdown → exit keep-alive loop
            // ...
        };

        // ... route + call handler ...

        // CancelProtection: finish writing response even during shutdown
        {
            const old = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(old);
            response.flush() catch {};
        }
    }
}
```

**Shutdown trigger options:**
| Approach | Mechanism | Platform |
|----------|-----------|----------|
| External cancel | Caller cancels the `Future` returned by `io.async(server.run, ...)` | All |
| Sentinel event | `Io.Event` set by signal handler thread | All |
| Signal FD | `posix.signalfd` → readable when SIGTERM received | Linux |
| Ctrl+C handler | Background thread with `SetConsoleCtrlHandler` | Windows |

**Files to modify:**
| File | Change |
|------|--------|
| `server.zig` | `run()` returns `Io.Cancelable!void`, handle `error.Canceled` in accept |
| `connection.zig` | `CancelProtection` around response flush; handle `Canceled` in read loop |
| `http_server_main.zig` | Spawn `server.run` as `io.async()`, set up shutdown trigger |

**Deliverable:** `Ctrl+C` or external signal drains in-flight requests cleanly.

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
