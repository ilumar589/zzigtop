# High-Performance HTTP/1 Server in Zig

## Project Progress Tracker

> **Last Updated:** 2026-02-15  
> **Zig Version:** 0.16.0-dev.2535+b5bd49460  
> **Status:** STEP 10 IN PROGRESS — Unit tests complete (64/64 passing), benchmarking next

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
| 10 | Testing, benchmarking & tuning | � IN PROGRESS |

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
- Thread spawning per connection (simple, effective)
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

## Step 10: Testing & Benchmarking (IN PROGRESS)

**What was done:**
- Added comprehensive unit tests across all modules (62 module tests + 2 exe tests = 64 total)
- Fixed test discovery: `root.zig` test block now references `http` module so all sub-module tests are discovered
- Fixed comptime test calls: `compilePattern()` and `Router.init()` in tests now use `comptime` keyword
- Registered `Request` and `Response` modules in `http.zig` test block

**Test breakdown by module:**
| Module | Tests | Coverage |
|--------|-------|----------|
| `parser.zig` | 32 | findByte (6), findCRLF (7), findHeaderEnd (5), parseRequestLine (8), parseHeaderLine (6) |
| `router.zig` | 15 | compilePattern (6), dispatch: static/param/multi-param/method/edge cases (9) |
| `request.zig` | 5 | pathParam found/not-found/empty/second-param, default fields |
| `response.zig` | 7 | setStatus, setBody, addHeader single/multiple/overflow, defaults, setBodyWithType |
| `root.zig` | 1 | basic add |
| `main.zig` | 2 | simple test, fuzz example |

**Bug found & fixed:**
- Tests in `parser.zig`, `router.zig` were never being discovered/run by `zig build test` — http module tests were dead code. Fixed by adding `_ = http;` to root.zig test block and `_ = Request; _ = Response;` to http.zig test block.

**Still TODO:**
- [ ] Benchmark with wrk/bombardier
- [ ] Profile with perf/VTune
- [ ] Comparison against other servers
- [ ] Integration test with full HTTP request/response cycle

---

## How to Resume Work

If context is full or work is interrupted, read this file first to understand:
1. What step we're on (check the table above)
2. What files exist (check the file list in each step)
3. What the next step requires

Then read `docs/ARCHITECTURE.md` for the overall design, and the specific source files for the current step.
