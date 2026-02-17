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
│  - Parses CLI args (port, host)                 │
│  - Creates Io instance from process.Init        │
│  - Starts the Server                            │
└───────────────────┬─────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────┐
│              Server (server.zig)                 │
│  - Binds to address via std.Io.net.listen()     │
│  - Accept loop                                  │
│  - Submits connections to thread pool           │
│  - Manages server lifecycle                     │
└───────────────────┬─────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────┐
│         Thread Pool (thread_pool.zig)            │
│  - Fixed number of pre-spawned worker threads   │
│  - Bounded Io.Queue for connection dispatch     │
│  - Backpressure when queue is full              │
│  - Graceful shutdown via queue close            │
└───────────────────┬─────────────────────────────┘
                    │ (per connection, from pool worker)
┌───────────────────▼─────────────────────────────┐
│         Connection (connection.zig)              │
│  - Wraps std.http.Server for HTTP parsing       │
│  - Keep-alive loop (multiple requests/conn)     │
│  - Arena-per-request allocation                 │
│  - Buffered I/O with stack-allocated buffers    │
└───────────────────┬─────────────────────────────┘
                    │ (per request)
┌───────────────────▼─────────────────────────────┐
│            Router (router.zig)                   │
│  - Comptime route table generation              │
│  - Path parameter extraction                    │
│  - Method-based dispatch                        │
│  - O(routes) matching with early exit           │
└───────────────────┬─────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────┐
│        Request / Response Layer                  │
│  request.zig:                                    │
│  - Zero-copy header access                      │
│  - Arena allocator per request                  │
│  response.zig:                                   │
│  - Vectored writes (header + body combined)     │
│  - Comptime status line generation              │
│  - Content-Length auto-calculation              │
└─────────────────────────────────────────────────┘
```

## Module Dependency Graph

```
http.zig (module root)
├── server.zig      → thread_pool.zig, connection.zig, router.zig
├── thread_pool.zig → connection.zig, router.zig
├── connection.zig  → request.zig, response.zig, router.zig, parser.zig
├── router.zig      → request.zig, response.zig
├── request.zig     → parser.zig
├── response.zig    → (std.http only)
└── parser.zig      → (std.http, SIMD)
```

## Key Design Decisions

### 1. Build on std.http.Server
Zig 0.16's `std.http.Server` already has excellent HTTP/1.1 parsing with zero-copy header access. Rather than reimplementing, we wrap it and add routing, connection management, and performance layers.

### 2. Thread Pool
Connections are dispatched to a fixed-size thread pool backed by a bounded `Io.Queue`. This avoids the overhead of spawning (and tearing down) an OS thread per connection. The pool size defaults to CPU count but is configurable via `--threads`. When the queue is full, the accept loop blocks, providing natural backpressure. Each worker thread handles one connection at a time, running the keep-alive loop internally so a single worker can serve many sequential requests.

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

## File Layout

```
src/
├── http/
│   ├── http.zig          — Module root, re-exports all public types
│   ├── server.zig        — TCP accept loop, thread pool dispatch
│   ├── thread_pool.zig   — Fixed-size thread pool with Io.Queue
│   ├── connection.zig    — Per-connection HTTP handling, keep-alive
│   ├── router.zig        — Comptime route table, path matching
│   ├── request.zig       — HTTP request wrapper with arena
│   ├── response.zig      — HTTP response builder with vectored writes
│   └── parser.zig        — SIMD-accelerated HTTP parsing utilities
├── http_server_main.zig  — Executable entry point
├── main.zig              — Original learn-zig entry point
└── root.zig              — Library root
docs/
├── PROGRESS.md           — Step-by-step progress tracker
├── ARCHITECTURE.md       — This file
├── PERFORMANCE.md        — Performance techniques reference
└── API.md                — API documentation
build.zig                 — Build configuration
build.zig.zon             — Package metadata
```

## Threading Model

```
Main Thread (owns allocator + Io)
│
├─ Server.start(allocator, io, config)
│   ├─ stores allocator in Server struct
│   └─ ThreadPool.init(allocator, io, router, pool_config)
│       └─ spawns N worker threads (default: CPU count)
│
├─ Accept Loop (blocking)
│   ├─ accept() → pool.submit(stream)  ← push to bounded queue
│   ├─ accept() → pool.submit(stream)
│   └─ accept() → pool.submit(stream)  (blocks if queue full)
│
Worker 1              Worker 2              Worker 3
│                     │                     │
├─ getOneUncancelable() ← blocks on queue
├─ Connection.handle(allocator, stream, ...)
├─ ArenaAllocator.init(allocator)  ← explicit backing allocator
├─ Read request       ├─ Read request       ├─ Read request
├─ Parse headers      ├─ Parse headers      ├─ Parse headers
├─ Route match        ├─ Route match        ├─ Route match
├─ Call handler       ├─ Call handler        ├─ Call handler
├─ Write response     ├─ Write response     ├─ Write response
├─ arena.deinit()     ├─ arena.deinit()     ├─ arena.deinit()
├─ (keep-alive loop)  ├─ (keep-alive loop)  ├─ Close
├─ Close              └─ Close
└─ back to getOneUncancelable()  ← reused for next connection
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
