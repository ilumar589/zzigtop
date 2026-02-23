//! HTTP server module root.
//!
//! Re-exports all public types from the HTTP server implementation.

pub const Server = @import("server.zig");
pub const Connection = @import("connection.zig");
pub const Router = @import("router.zig");
pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const parser = @import("parser.zig");
pub const CpuPool = @import("thread_pool.zig");

// Re-export common std.http types for convenience
const std = @import("std");
pub const Method = std.http.Method;
pub const Status = std.http.Status;
pub const Version = std.http.Version;
pub const Header = std.http.Header;

test {
    // Run all tests in submodules
    _ = parser;
    _ = Router;
    _ = Request;
    _ = Response;
}
