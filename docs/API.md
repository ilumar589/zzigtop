# API Documentation

## Quick Start

```zig
const std = @import("std");
const http = @import("learn_zig").http;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Define routes at comptime
    const router = http.Router.init(.{
        .{ .GET, "/", handleIndex },
        .{ .GET, "/hello/:name", handleHello },
        .{ .POST, "/api/echo", handleEcho },
    });

    // Create and start server
    var server = try http.Server.start(gpa, io, .{
        .port = 8080,
        .router = &router,
    });
    defer server.deinit(io);

    std.debug.print("Server listening on :8080\n", .{});

    // Run accept loop (blocks)
    server.run(io);
}

fn handleIndex(request: *http.Request, response: *http.Response) !void {
    try response.setBody("Welcome to Zig HTTP Server!");
}

fn handleHello(request: *http.Request, response: *http.Response) !void {
    const name = request.pathParam("name") orelse "world";
    // Uses arena allocator — freed automatically when request completes
    const body = try std.fmt.allocPrint(request.arena, "Hello, {s}!", .{name});
    try response.setBody(body);
}

fn handleEcho(request: *http.Request, response: *http.Response) !void {
    try response.setStatus(.ok);
    try response.setBody(request.body orelse "");
}
```

## Core Types

### `http.Server`

The main server type. Listens for TCP connections and dispatches them to handlers.

```zig
const Server = struct {
    // Start listening on the given address.
    // `allocator` is stored and forwarded to each connection thread
    // as the backing allocator for per-request arenas.
    pub fn start(allocator: Allocator, io: Io, config: Config) !Server;
    
    // Run the accept loop (blocks forever)
    pub fn run(self: *Server, gpa: Allocator, io: Io) void;
    
    // Clean up resources
    pub fn deinit(self: *Server, io: Io) void;
};
```

**Config fields:**
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | `u16` | `8080` | TCP port to listen on |
| `host` | `[4]u8` | `{0,0,0,0}` | Bind address (0.0.0.0 = all interfaces) |
| `backlog` | `u31` | `128` | Kernel connection backlog |
| `router` | `*const Router` | required | Route table |
| `read_buffer_size` | `usize` | `8192` | Per-connection read buffer |
| `write_buffer_size` | `usize` | `8192` | Per-connection write buffer |

### `http.Router`

Comptime-generated route table.

```zig
const Router = struct {
    // Create router from comptime route definitions
    pub fn init(comptime routes: anytype) Router;
    
    // Match a request to a handler (called internally)
    pub fn dispatch(self: *const Router, method: Method, path: []const u8) ?Match;
};
```

**Route definition format:**
```zig
.{ .METHOD, "/path/pattern", handlerFn }
```

**Path parameters:**
```zig
.{ .GET, "/users/:id", handler }          // :id captures a segment
.{ .GET, "/files/:dir/:name", handler }   // Multiple params
```

### `http.Request`

Represents an incoming HTTP request.

```zig
const Request = struct {
    method: std.http.Method,
    path: []const u8,
    version: std.http.Version,
    keep_alive: bool,
    content_type: ?[]const u8,
    content_length: ?u64,
    arena: std.mem.Allocator,
    
    // Get a path parameter by name
    pub fn pathParam(self: *const Request, name: []const u8) ?[]const u8;
    
    // Iterate over all headers
    pub fn headers(self: *const Request) HeaderIterator;
};
```

### `http.Response`

Response builder that flushes to the client.

```zig
const Response = struct {
    // Set HTTP status code
    pub fn setStatus(self: *Response, status: std.http.Status) void;
    
    // Add a response header
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void;
    
    // Set response body (auto-sets Content-Length)
    pub fn setBody(self: *Response, body: []const u8) !void;
    
    // Send the response (called internally after handler returns)
    pub fn flush(self: *Response) !void;
};
```

## Building & Running

```powershell
# Build and run (debug)
zig build run-server

# Build with max performance
zig build run-server -Doptimize=ReleaseFast

# Build only
zig build -Doptimize=ReleaseFast

# Run the built binary directly
.\zig-out\bin\http_server.exe
```

## Handler Function Signature

All handlers must conform to:

```zig
fn handler(request: *http.Request, response: *http.Response) HandlerError!void
```

Where `HandlerError` allows returning standard errors.

## Performance Notes

- Handlers receive an arena allocator via `request.arena` — use it freely, 
  all memory is freed when the request completes
- Avoid storing references to request data beyond the handler's lifetime 
  (data lives in the connection's read buffer)
- For static responses, use comptime strings — they're free
- Keep handlers non-blocking; each connection has its own thread
