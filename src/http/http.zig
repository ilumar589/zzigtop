//! HTTP server module root.
//!
//! Re-exports all public types from the HTTP server implementation.

/// Async TCP server with `Io.Group` dispatch and keep-alive.
pub const Server = @import("server.zig");
/// Per-connection state machine (read → parse → route → respond).
pub const Connection = @import("connection.zig");
/// Comptime route table with parameter capture.
pub const Router = @import("router.zig");
/// Parsed HTTP request (method, path, headers, body).
pub const Request = @import("request.zig");
/// Response builder with vectored I/O writes.
pub const Response = @import("response.zig");
/// SIMD-accelerated HTTP/1 parsing utilities.
pub const parser = @import("parser.zig");
/// `Io.CpuGroup`-based thread pool for CPU-bound work.
pub const CpuPool = @import("thread_pool.zig");
/// Static file serving with MIME detection and path sanitisation.
pub const Static = @import("static.zig");
/// Comptime middleware pipeline (logging, CORS, security headers, etc.).
pub const Middleware = @import("middleware.zig");

// Re-export common std.http types for convenience
const std = @import("std");
/// HTTP method (GET, POST, PUT, DELETE, …).
pub const Method = std.http.Method;
/// HTTP response status code (200, 404, 500, …).
pub const Status = std.http.Status;
/// HTTP version (HTTP/1.0, HTTP/1.1).
pub const Version = std.http.Version;
/// A single HTTP header name/value pair.
pub const Header = std.http.Header;

test {
    // Run all tests in submodules
    _ = parser;
    _ = Router;
    _ = Request;
    _ = Response;
    _ = Static;
    _ = Middleware;
}
