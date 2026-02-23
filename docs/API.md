# API Documentation

> **Zig Version:** 0.16.0-dev.2535+b5bd49460
> **Last Updated:** 2026-02-23

---

## Quick Start

```zig
const std = @import("std");
const http = @import("learn_zig").http;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Define routes at comptime — compiled into an optimized match table.
    const router = http.Router.init(.{
        .{ .GET, "/", handleIndex },
        .{ .GET, "/hello/:name", handleHello },
        .{ .POST, "/api/echo", handleEcho },
    });

    // Start the server — Io runtime auto-scales worker threads/fibers.
    var server = try http.Server.start(init.gpa, io, .{
        .port = 8080,
        .router = &router,
        .static_config = .{ .root_dir = "public" },
    });
    defer server.deinit(io);

    std.debug.print("Listening on http://127.0.0.1:8080\n", .{});

    // Run accept loop (blocks until canceled).
    server.run(io) catch |err| switch (err) {
        error.Canceled => std.debug.print("Shutting down.\n", .{}),
    };
}

/// Handler signature: (request, response, io) -> anyerror!void
/// The `io` parameter gives access to structured concurrency (async, sleep, select).
fn handleIndex(_: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    try response.sendHtml(.ok, "<h1>Hello from Zig!</h1>");
}

fn handleHello(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const name = request.pathParam("name") orelse "world";
    const body = try std.fmt.allocPrint(request.arena, "Hello, {s}!", .{name});
    try response.sendText(.ok, body);
}

fn handleEcho(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const body = try std.fmt.allocPrint(
        request.arena,
        "Method: {s}\nPath: {s}\n",
        .{ @tagName(request.method), request.path },
    );
    try response.sendText(.ok, body);
}
```

---

## Building & Running

```bash
# Build and run the HTTP server
zig build run-server

# With optimization
zig build run-server -Doptimize=ReleaseFast

# Custom port, static directory, or disable features
zig build run-server -- --port 3000
zig build run-server -- --static-dir assets
zig build run-server -- --no-static
zig build run-server -- --no-db

# Run unit tests (90 tests)
zig build test --summary all

# Run integration tests (requires server NOT running on port 18080)
zig build integration-test

# Run database integration tests (requires PostgreSQL)
cd docker && docker compose up -d
zig build db-integration-test

# Run benchmark
zig build benchmark
```

### CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port <n>` | `8080` | TCP port to listen on |
| `--static-dir <dir>` | `public` | Directory for static files |
| `--no-static` | — | Disable static file serving |
| `--no-db` | — | Disable PostgreSQL connection |
| `--db-host <host>` | `127.0.0.1` | PostgreSQL host |
| `--db-port <n>` | `5432` | PostgreSQL port |

---

## Core Types

### `http.Server`

Async TCP server with `Io.Group` work-stealing dispatch. Listens for TCP
connections and spawns each as an async task managed by the Io runtime.

```zig
pub fn start(allocator: std.mem.Allocator, io: Io, config: Config) !Server;
pub fn run(self: *Server, io: Io) Io.Cancelable!void;
pub fn deinit(self: *Server, io: Io) void;
```

**Config fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | `u16` | `8080` | TCP port to listen on |
| `host` | `[4]u8` | `{0,0,0,0}` | Bind address (0.0.0.0 = all interfaces) |
| `backlog` | `u31` | `128` | Kernel connection backlog |
| `reuse_address` | `bool` | `true` | SO_REUSEADDR for fast restarts |
| `router` | `*const Router` | required | Comptime route table |
| `idle_timeout_s` | `u32` | `30` | Keep-alive idle timeout (seconds, 0 = no timeout) |
| `request_timeout_s` | `u32` | `10` | Max handler execution time (seconds, 0 = no timeout) |
| `metrics_interval_s` | `u32` | `10` | Background metrics log interval (0 = disabled) |
| `static_config` | `?Static.Config` | `null` | Static file serving config (null = disabled) |

**Stats (atomic counters):**

| Field | Description |
|-------|-------------|
| `active_connections` | Currently open connections |
| `total_requests` | Total HTTP requests served since start |
| `total_connections` | Total TCP connections accepted since start |

---

### `http.Router`

Comptime-generated route table. Routes are defined at compile time — no heap
allocation during routing.

```zig
pub fn init(comptime routes: anytype) Router;
pub fn dispatch(self: *const Router, method: Method, path: []const u8) ?Match;
```

**Route definition format:**
```zig
const router = http.Router.init(.{
    .{ .GET, "/", handleIndex },
    .{ .GET, "/users/:id", handleGetUser },     // :id captures a segment
    .{ .GET, "/files/:dir/:name", handler },     // Multiple params
    .{ .POST, "/api/users", handleCreateUser },
    .{ .PUT, "/api/users/:id", handleUpdateUser },
    .{ .DELETE, "/api/users/:id", handleDeleteUser },
});
```

**Handler function signature:**
```zig
pub const HandlerFn = *const fn (*Request, *Response, std.Io) anyerror!void;
```

The `Io` parameter gives handlers access to the async runtime for
structured concurrency patterns (fan-out, timeouts, sleep, cancellation).

---

### `http.Request`

Represents an incoming HTTP request with arena-per-request allocation
and zero-copy access to parsed data.

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `method` | `std.http.Method` | HTTP method (GET, POST, etc.) |
| `path` | `[]const u8` | Request path with query string stripped (zero-copy) |
| `raw_query` | `?[]const u8` | Raw query string without `?` (zero-copy, null if none) |
| `version` | `std.http.Version` | HTTP version (1.0 or 1.1) |
| `keep_alive` | `bool` | Whether client wants keep-alive |
| `content_type` | `?[]const u8` | Content-Type header value (zero-copy) |
| `content_length` | `?u64` | Content-Length value if present |
| `arena` | `std.mem.Allocator` | Per-request arena (freed automatically) |
| `body` | `?[]const u8` | Raw body (populated after `readBody()`) |
| `params` | `[]const Param` | Route parameters from router |

**Methods:**

```zig
/// Get a path parameter by name. Returns null if not found.
pub fn pathParam(self: *const Request, name: []const u8) ?[]const u8;

/// Get a single query parameter by name (first match). Lazy-parsed on first call.
/// Values are percent-decoded. Zero-copy when no decoding is needed.
pub fn queryParam(self: *Request, name: []const u8) ?[]const u8;

/// Get all values for a query parameter name (e.g., ?tag=a&tag=b).
/// Returns an arena-allocated slice. Empty slice if no matches.
pub fn queryParamAll(self: *Request, name: []const u8) []const []const u8;

/// URL percent-decode a string (%XX → byte, + → space).
/// Returns original slice if no decoding needed (zero-copy).
pub fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8;

/// Read the request body from the stream. Caches the result.
/// Returns error.NoBody for GET/HEAD or if Content-Length is 0.
/// Returns error.BodyTooLarge if body exceeds 1MB.
pub fn readBody(self: *Request, body_reader: *std.Io.Reader) ![]const u8;

/// Parse the request body as JSON into a typed Zig struct.
/// Uses arena allocation — freed in bulk when request completes.
pub fn jsonBody(self: *Request, comptime T: type) !T;

/// Iterate over all HTTP headers (zero-copy).
pub fn headerIterator(self: *const Request) std.http.HeaderIterator;

/// Get a specific header value by name (case-insensitive).
pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8;
```

**Query parameter example:**
```zig
/// GET /api/users?page=2&limit=10&sort=name
fn handleListUsers(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const page = request.queryParam("page") orelse "1";
    const limit = request.queryParam("limit") orelse "20";
    const sort = request.queryParam("sort") orelse "id";
    // page="2", limit="10", sort="name"
}

/// GET /search?q=hello+world  →  request.queryParam("q") = "hello world"
/// GET /filter?tag=a&tag=b    →  request.queryParamAll("tag") = {"a", "b"}
```

**JSON parsing example:**
```zig
fn handleCreateUser(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const User = struct { name: []const u8, email: []const u8, age: ?i32 = null };

    const user = request.jsonBody(User) catch {
        try response.sendText(.bad_request, "Invalid JSON");
        return;
    };

    // user.name, user.email are zero-copy slices into the body buffer
    const msg = try std.fmt.allocPrint(request.arena, "Created: {s}", .{user.name});
    try response.sendText(.created, msg);
}
```

---

### `http.Response`

Response builder that flushes headers + body in a single vectored write.

**Fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `status` | `std.http.Status` | `.ok` | HTTP status code |
| `body` | `[]const u8` | `""` | Response body content |
| `arena` | `std.mem.Allocator` | — | Arena for response-lifetime allocations |
| `keep_alive` | `bool` | `true` | Connection: keep-alive or close |
| `version` | `std.http.Version` | `HTTP/1.1` | HTTP version for status line |

**Methods:**

```zig
/// Set the HTTP status code.
pub fn setStatus(self: *Response, status: std.http.Status) void;

/// Set the response body.
pub fn setBody(self: *Response, body: []const u8) void;

/// Set body and content type in one call.
pub fn setBodyWithType(self: *Response, body: []const u8, content_type: []const u8) !void;

/// Add a response header (up to 32 extra headers).
pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void;

/// Flush status line + headers + body to the socket (vectored write).
pub fn flush(self: *Response) !void;
```

**Convenience methods (set content-type + flush in one call):**

```zig
/// Send a plain text response.
pub fn sendText(self: *Response, status: std.http.Status, body: []const u8) !void;

/// Send a JSON string response.
pub fn sendJson(self: *Response, status: std.http.Status, body: []const u8) !void;

/// Serialize any Zig value as JSON and send it.
pub fn sendJsonValue(self: *Response, status: std.http.Status, value: anytype) !void;

/// Send an HTML response.
pub fn sendHtml(self: *Response, status: std.http.Status, body: []const u8) !void;

/// Try to serve a static file. Returns true if found and served.
pub fn sendStaticFile(self: *Response, config: Static.Config, path: []const u8, io: Io) bool;
```

**`sendJsonValue` example (struct → JSON):**
```zig
fn handleGetUser(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const result = .{ .id = @as(i32, 1), .name = "Alice", .active = true };
    try response.sendJsonValue(.ok, result);
    // Sends: {"id":1,"name":"Alice","active":true}
}
```

---

### `http.Static`

Static file handler. Serves files from a configurable document root with
path traversal prevention, comptime MIME type mapping, and Cache-Control headers.

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `root_dir` | `[]const u8` | required | Document root (relative to CWD or absolute) |
| `max_file_size` | `usize` | 10 MB | Maximum file size (rejects larger files) |
| `cache_max_age_s` | `u32` | `3600` | Cache-Control max-age (0 = no cache header) |
| `index_file` | `?[]const u8` | `"index.html"` | Auto-resolve for directory paths (null = disabled) |

**Security:** Rejects paths containing `..`, null bytes, backslashes, and `.` segments.
All paths must start with `/`. Query strings and fragments are stripped.

**Usage:** Configure via `Server.Config.static_config`. Unmatched routes automatically
fall back to static file serving. Or call directly from a handler:

```zig
fn handleIndex(_: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    if (response.sendStaticFile(.{ .root_dir = "public" }, "/index.html", io)) return;
    try response.sendText(.not_found, "Not found");
}
```

**Supported MIME types:** html, htm, css, js, mjs, json, png, jpg, jpeg, gif, svg,
ico, webp, avif, woff, woff2, ttf, otf, eot, xml, txt, md, map, wasm, pdf.
Unknown extensions default to `application/octet-stream`.

---

### `http.CpuPool`

Generic CPU work pool for compute-heavy tasks that should not block the I/O runtime.

Each worker gets a `FixedBufferAllocator` (64KB by default) for bounded scratch space,
reset per task (O(1) bump pointer reset, zero syscalls).

```zig
pub fn init(allocator: Allocator, io: Io, config: Config) !CpuPool;
pub fn deinit(self: *CpuPool) void;
pub fn submit(self: *CpuPool, io: Io, comptime func: anytype, args: anytype) !ReturnType;
```

---

## Database Module

### `db.Database`

Connection pool wrapper around `pg.zig` (PostgreSQL driver).

```zig
pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) !Database;
pub fn deinit(self: *Database) void;
pub fn query(self: *Database, sql: []const u8, values: anytype) !*Result;
pub fn exec(self: *Database, sql: []const u8, values: anytype) !?i64;
pub fn row(self: *Database, sql: []const u8, values: anytype) !?QueryRow;
pub fn acquire(self: *Database) !*pg.Conn;
pub fn release(self: *Database, conn: *pg.Conn) void;
```

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `host` | `[]const u8` | `"127.0.0.1"` | PostgreSQL host |
| `port` | `u16` | `5432` | PostgreSQL port |
| `username` | `[]const u8` | `"ziglearn"` | Database user |
| `password` | `[]const u8` | `"ziglearn"` | Database password |
| `database` | `[]const u8` | `"ziglearn"` | Database name |
| `pool_size` | `u16` | `5` | Number of pooled connections |
| `timeout_seconds` | `u16` | `10` | Connection timeout |

All queries use PostgreSQL's parameterized protocol (`$1`, `$2`, ...) — user data
is **never** interpolated into SQL strings (SQL injection safe at protocol level).

### `db.UserRepository`

Type-safe CRUD for the `users` table.

```zig
pub fn init(db: *Database) UserRepository;
pub fn getAll(self: *UserRepository) !*pg.Result;
pub fn getById(self: *UserRepository, id: i32, arena: std.mem.Allocator) !?User;
pub fn create(self: *UserRepository, input: CreateUserInput, arena: std.mem.Allocator) !?User;
pub fn update(self: *UserRepository, id: i32, input: CreateUserInput, arena: std.mem.Allocator) !?User;
pub fn delete(self: *UserRepository, id: i32) !bool;
```

**Types:**
```zig
pub const User = struct { id: i32, name: []const u8, email: []const u8, age: ?i32 = null };
pub const CreateUserInput = struct { name: []const u8, email: []const u8, age: ?i32 = null };
```

---

## HTTP Endpoints

### Built-in Routes

| Method | Path | Handler | Description |
|--------|------|---------|-------------|
| GET | `/` | `handleIndex` | Serves `public/index.html` (static file) |
| GET | `/health` | `handleHealth` | Health check → `{"status":"ok"}` |
| GET | `/hello/:name` | `handleHello` | Greeting with path parameter |
| POST | `/echo` | `handleEcho` | Echoes method, path, and query string |
| POST | `/api/echo-json` | `handleEchoJson` | JSON round-trip demo |
| GET | `/search` | `handleSearch` | Query parameter demo (`?q=...&page=1&limit=10`) |
| GET | `/dashboard/:id` | `handleDashboard` | Fan-out concurrency demo |
| GET | `/metrics` | `handleMetrics` | Server stats (atomic counters) |

### REST API: Users (requires PostgreSQL)

| Method | Path | Description | Request Body | Response |
|--------|------|-------------|-------------|----------|
| GET | `/api/users` | List all users | — | `[{"id":1,"name":"...","email":"...","age":30}]` |
| GET | `/api/users/:id` | Get user by ID | — | `{"id":1,...}` or 404 |
| POST | `/api/users` | Create user | `{"name":"...","email":"...","age":30}` | 201 with created user |
| PUT | `/api/users/:id` | Update user | `{"name":"...","email":"...","age":30}` | 200 with updated user or 404 |
| DELETE | `/api/users/:id` | Delete user | — | `{"deleted":true}` or 404 |

### Static Files (fallback)

Any request that does not match a route falls back to static file serving
from the configured directory (default: `public/`). Disabled with `--no-static`.

```
GET /style.css        → public/style.css    (text/css)
GET /js/app.js        → public/js/app.js    (application/javascript)
GET /images/logo.png  → public/images/logo.png (image/png)
GET /subdir/          → public/subdir/index.html (auto-resolve)
```

---

## Structured Concurrency

Handlers receive `std.Io` enabling Kotlin-style structured concurrency:

```zig
/// Fan-out: spawn concurrent sub-tasks, await both.
fn handleDashboard(request: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    const user_id = request.pathParam("id") orelse "anon";

    // Spawn two concurrent tasks
    var profile = io.async(fetchProfile, .{ io, user_id, request.arena });
    var notifs  = io.async(fetchNotifications, .{ io, user_id, request.arena });

    // Await both (cancellation-safe)
    const p = profile.await(io) catch |err| {
        if (notifs.cancel(io)) |_| {} else |_| {}
        return err;
    };
    const n = notifs.await(io) catch |err| return err;

    const body = try std.fmt.allocPrint(request.arena, "{s} / {s}", .{ p, n });
    try response.sendText(.ok, body);
}
```

**Available `Io` operations in handlers:**
- `io.async(fn, args)` — Spawn concurrent sub-task
- `io.sleep(duration, clock)` — Non-blocking sleep
- `io.select(.{...})` — Race / timeout
- `io.checkCancel()` — Cooperative cancellation check

**Timeouts:** Requests exceeding `request_timeout_s` (default: 10s) are
automatically canceled with 503 Service Unavailable.

---

## Memory Model

All per-request allocations use the **arena-per-request** pattern:

1. Each request gets a dedicated `ArenaAllocator`
2. Route params, parsed JSON, response headers, file content — all arena-allocated
3. When the request completes, the arena resets in one O(1) operation
4. No manual `free()` calls — leaks are structurally impossible

```
Request lifecycle:
  arena.init() → parse → route → handle → respond → arena.reset()
                         ↑                    ↑
                   All of these allocate from the arena
```

The backing allocator flows through the entire stack:
`main(init.gpa)` → `Server.start(allocator)` → `Connection.handle(allocator)`
→ `ArenaAllocator.init(allocator)` → `request.arena` / `response.arena`

---

## Performance Notes

- **Zero-copy parsing:** Headers, URI, method are slices into the read buffer
- **Comptime routing:** Route table generated at compile time (no runtime hash maps)
- **Vectored writes:** Response flushed in one syscall via `writeVecAll`
- **SIMD scanning:** `@Vector(16, u8)` for newline/byte scanning in parser
- **Arena allocation:** O(1) cleanup per request, no per-allocation bookkeeping
- **Io-native I/O:** File reads, DB queries, sleep all go through the Io runtime
- **Branch hints:** `@branchHint(.unlikely)` on error paths

See [PERFORMANCE.md](PERFORMANCE.md) for 18 detailed technique breakdowns.

---

## File Layout

```
src/
├── root.zig              — Package root (exports http + db modules)
├── main.zig              — Default entry point (not the server)
├── http_server_main.zig  — HTTP server entry point + all handlers
├── integration_test.zig  — HTTP integration tests (standalone executable)
├── db_integration_test.zig — DB integration tests (standalone executable)
├── benchmark.zig         — Built-in HTTP benchmark tool
├── http/
│   ├── http.zig          — Module root (re-exports all HTTP types)
│   ├── server.zig        — TCP listener + async dispatch
│   ├── connection.zig    — Per-connection lifecycle (timeouts, keep-alive)
│   ├── router.zig        — Comptime route matching
│   ├── request.zig       — Request type (arena, JSON, headers)
│   ├── response.zig      — Response builder (vectored writes, JSON)
│   ├── parser.zig        — SIMD HTTP/1 parser (zero-copy)
│   ├── static.zig        — Static file handler (MIME, security, caching)
│   └── thread_pool.zig   — CPU work pool (FixedBufferAllocator per worker)
└── db/
    ├── db.zig            — Database module root
    ├── database.zig      — Connection pool wrapper (pg.zig)
    └── user_repository.zig — User CRUD (parameterized queries)
```
