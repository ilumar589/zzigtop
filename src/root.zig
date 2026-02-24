//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// High-performance HTTP/1 server module.
pub const http = @import("http/http.zig");

/// Database connection pool and repository types.
pub const db = @import("db/db.zig");

/// Comptime HTML template engine and htmx integration.
pub const html = @import("html/html.zig");

/// Football web scraping feature module.
pub const football_scraping = @import("features/football_scraping/football_scraping.zig");

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

/// Add two 32-bit integers (scaffolding example used by `build.zig` tests).
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test {
    // Pull in tests from all submodules
    _ = http;
    _ = html;
    _ = football_scraping;
}
