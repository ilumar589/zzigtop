# Architecture: High-Performance HTTP/1 Server

## Overview

A from-scratch HTTP/1.1 server built in Zig 0.16, designed to maximize performance using Zig's unique language features. The server builds on top of Zig's `std.http.Server` for protocol-level parsing while adding high-performance routing, connection management, and response building.

## Zig Version

- **Version:** 0.16.0-dev.2535+b5bd49460
- **Key API:** Uses the new `std.process.Init` main signature and `std.Io` abstraction

## System Architecture

```
┌─────────────────────────────────────────────────┐
│                  Main Entry Point               │
│           (src/http_server_main.zig)             │
│  - Parses CLI args (port, --no-db, etc.)        │
│  - Receives Io instance from process.Init       │
│  - Initializes Database (optional)              │
│  - Starts the Server                            │
└───────────────────┬─────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
┌───────▼───────────────────┐ ┌─▼──────────────────────────────┐
│   Server (server.zig)     │ │  Database Layer (src/db/)      │
│  - TCP accept loop        │ │  database.zig — Pool wrapper   │
│  - Io.Group async dispatch│ │  user_repository.zig — CRUD    │
│  - Auto-scaled workers    │ │  Uses pg.zig (zigster64 fork)  │
└───────────┬───────────────┘ │  Binary protocol ($1,$2,...)   │
            │ Io.Group.async()│  Parameterized query safety    │
┌───────────▼───────────────┐ └─▲──────────────────────────────┘
│  Connection (connection)  │   │ handlers call UserRepository
│  - Per-connection arena   │   │
│  - HTTP parsing           │───┘
│  - Keep-alive loop        │
└───────────┬───────────────┘
            │ (per request)
┌───────────▼───────────────────────────────────────┐
│            Router (router.zig)                     │
│  - Comptime route table generation                │
│  - Path parameter extraction (:id, :name)         │
│  - Method-based dispatch                          │
└───────────┬───────────────────────────────────────┘
            │
┌───────────▼───────────────────────────────────────┐
│        Request / Response Layer                    │
│  request.zig: Zero-copy headers, arena per req    │
│  response.zig: Vectored writes, comptime status   │
└───────────────────────────────────────────────────┘
```

## Module Dependency Graph

```
root.zig (package root)
├── http.zig (HTTP module root)
│   ├── server.zig      → connection.zig, router.zig
│   ├── connection.zig  → request.zig, response.zig, router.zig, parser.zig
│   ├── router.zig      → request.zig, response.zig
│   ├── request.zig     → parser.zig
│   ├── response.zig    → (std.http only)
│   └── parser.zig      → (std.http, SIMD)
└── db.zig (Database module root)
    ├── database.zig    → pg.zig (connection pool wrapper)
    └── user_repository.zig → database.zig, pg.zig
```

## Key Design Decisions

### 1. Build on std.http.Server
Zig 0.16's `std.http.Server` already has excellent HTTP/1.1 parsing with zero-copy header access. Rather than reimplementing, we wrap it and add routing, connection management, and performance layers.

### 2. Async I/O Pool (Work-Stealing)
Connections are dispatched as async tasks via `Io.Group.async()`. The Zig `std.Io` runtime manages all concurrency:

- **Evented backend** (Linux io_uring / macOS kqueue): Each connection runs as a stackful fiber (4MB stack). Fibers yield on I/O and are resumed by the runtime. Work-stealing balances load across OS threads — idle threads steal ready fibers from busy threads.

- **Threaded backend** (Windows / fallback): Tasks run on a dynamic thread pool. Threads are spawned lazily (not pre-allocated), up to CPU_COUNT-1. When all threads are busy, new tasks run inline on the accept thread (natural backpressure). No manual thread count configuration needed.

This replaces the earlier fixed-size thread pool (`thread_pool.zig`) with the runtime's built-in scheduler, which is more efficient and requires zero configuration.

### 3. Arena-per-Request
Each HTTP request gets a dedicated arena allocator. All allocations during request processing (route params, parsed data, response building) use this arena. When the request completes, the entire arena is freed in a single O(1) operation.

### 3a. Explicit Allocator Parameters
No allocator is ever hardcoded. The backing allocator for per-request arenas is
passed explicitly through the entire call chain:
`main (init.gpa)` → `Server.start(allocator, ...)` → stored in `Server.allocator`
→ forwarded to each spawned connection thread → `Connection.handle(allocator, ...)`
→ used as the backing for `ArenaAllocator`. This makes the server testable (use
`std.testing.allocator` for leak detection) and flexible (swap allocators without
code changes).

### 4. Zero-Copy Everywhere
HTTP headers, URI, method — all are stored as slices pointing into the read buffer. No string copying or allocation for parsing.

### 5. Comptime Routing
Routes are defined at compile time. The compiler generates an optimized matching structure with no runtime overhead for route table construction.

### 6. Vectored Writes
Response status line + headers + body are combined into a single vectored write syscall, reducing system call overhead.

### 7. Database Layer Separation
The database module (`src/db/`) is completely independent of the HTTP module. This enables:
- **Reusability:** CLI tools, migrations, or batch jobs can use `Database` + `UserRepository` without the HTTP server.
- **Testability:** DB integration tests run directly against PostgreSQL without starting an HTTP server.
- **SQL injection safety at the protocol level:** All queries use PostgreSQL's parameterized query protocol (`$1`, `$2`, ...). User data is never interpolated into SQL strings — it travels via the binary wire protocol.

### 8. Connection Pool (pg.zig)
Uses `zigster64/pg.zig#zig16` — a Zig 0.16 compatible fork of `karlseguin/pg.zig`. The pool manages a fixed number of connections and handles reconnection automatically.
- Pool size configurable (default: 5)
- Timeout via `Io.Duration` (async-aware)
- Connections returned to pool on `Result.deinit()` or explicit `release()`

## File Layout

```
src/
├── db/
│   ├── db.zig            — Database module root, re-exports types
│   ├── database.zig      — pg.Pool wrapper with Config struct
│   └── user_repository.zig — Type-safe CRUD for users table
├── http/
│   ├── http.zig          — HTTP module root, re-exports all public types
│   ├── server.zig        — TCP accept loop, Io.Group async dispatch
│   ├── connection.zig    — Per-connection HTTP handling, keep-alive
│   ├── router.zig        — Comptime route table, path matching
│   ├── request.zig       — HTTP request wrapper with arena
│   ├── response.zig      — HTTP response builder with vectored writes
│   ├── parser.zig        — SIMD-accelerated HTTP parsing utilities
│   └── thread_pool.zig   — Legacy fixed-size thread pool (superseded)
├── http_server_main.zig  — Executable entry point (HTTP server + REST API)
├── db_integration_test.zig — Database integration tests (requires PostgreSQL)
├── integration_test.zig  — HTTP integration tests
├── benchmark.zig         — Performance benchmarks
├── main.zig              — Original learn-zig entry point
└── root.zig              — Library root (exports http + db modules)
docker/
├── compose.yml           — PostgreSQL 16 container definition
└── init.sql              — Schema + seed data (auto-runs on first up)
docs/
├── PROGRESS.md           — Step-by-step progress tracker
├── ARCHITECTURE.md       — This file
├── PERFORMANCE.md        — Performance techniques reference
└── API.md                — API documentation
build.zig                 — Build configuration
build.zig.zon             — Package metadata (includes pg.zig dependency)
```

## Threading Model

```
Main Thread (owns allocator + Io from std.process.Init)
│
├─ Server.start(allocator, io, config)
│   └─ Binds TCP listener (no threads spawned here)
│
├─ Accept Loop (server.run)
│   ├─ accept() → group.async(Connection.handleAsync, {stream, io, router, alloc})
│   ├─ accept() → group.async(...)   ← Io runtime spawns fibers/threads on demand
│   └─ accept() → group.async(...)   ← runs inline if all workers busy (backpressure)
│
│   Io Runtime (automatic)
│   ├─ Evented: stackful fibers, work-stealing across OS threads
│   └─ Threaded: dynamic thread pool, lazy spawn up to CPU_COUNT-1
│
Task 1 (fiber/thread)    Task 2                Task 3
│                         │                     │
├─ ArenaAllocator.init()  ← per-connection arena (fiber-safe)
├─ Read request           ├─ Read request       ├─ Read request
├─ Parse headers          ├─ Parse headers      ├─ Parse headers
├─ Route match            ├─ Route match        ├─ Route match
├─ Call handler           ├─ Call handler        ├─ Call handler
├─ Write response         ├─ Write response     ├─ Write response
├─ arena.reset()          ├─ arena.reset()      ├─ arena.reset()
├─ (keep-alive loop)      ├─ (keep-alive loop)  ├─ Close
├─ Close                  └─ Close              └─ arena.deinit()
└─ arena.deinit()         ← task completes, Io runtime reclaims resources
```

## Memory Model

```
Per-Connection (stack-allocated):
├── Read buffer:   [8192]u8  — HTTP request data
├── Write buffer:  [8192]u8  — HTTP response data
└── Parser state:  ~128 bytes

Per-Request (arena-allocated, backed by explicit allocator):
├── Route params:  []Param  — Extracted path parameters
├── Handler data:  varies   — Whatever the handler allocates
└── Freed in bulk when request completes
```

## Data Flow for a Single Request

1. **Accept:** `Server.accept()` returns a `Stream` (TCP connection)
2. **Buffer:** Create stack-allocated read/write buffers
3. **Read:** `std.http.Server.receiveHead()` reads and parses HTTP head
4. **Route:** `Router.dispatch()` matches path → handler at comptime-generated table
5. **Handle:** Handler receives `Request`, writes to `Response` 
6. **Write:** `Response.send()` flushes vectored buffers to socket
7. **Keep-alive:** If Connection: keep-alive, loop back to step 3
8. **Close:** Stream is closed, thread exits
