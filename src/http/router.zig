//! Comptime HTTP router.
//!
//! Routes are defined at compile time and compiled into a static match table.
//! Path parameters (`:name`) are extracted during matching.
//! No heap allocation is performed during routing.

const std = @import("std");
const http = std.http;
const mem = std.mem;
const Io = std.Io;
const Request = @import("request.zig");
const Response = @import("response.zig");

const Router = @This();

/// Handler function type — receives request, response, and Io handle.
///
/// The `Io` parameter gives handlers access to the async runtime,
/// enabling structured concurrency patterns:
///   - `io.async(fn, args)` for fan-out sub-tasks
///   - `io.sleep(duration, clock)` for delays
///   - `io.select(.{...})` for racing / timeouts
///   - `io.checkCancel()` for cooperative cancellation
///
/// This is the Zig equivalent of Kotlin's `suspend fun` — every
/// handler runs within a cancellation scope and can spawn children.
pub const HandlerFn = *const fn (*Request, *Response, Io) anyerror!void;

/// A single compiled route entry.
pub const Route = struct {
    /// HTTP method this route matches.
    method: http.Method,
    /// The pattern string, e.g., "/users/:id/posts"
    pattern: []const u8,
    /// Compiled pattern segments for matching.
    segments: []const Segment,
    /// The handler function to call.
    handler: HandlerFn,
};

/// A segment of a route pattern.
pub const Segment = union(enum) {
    /// Literal path segment (exact match required).
    literal: []const u8,
    /// Parameter segment (captures value, key is the param name without ':').
    param: []const u8,
};

/// Maximum number of routes supported.
const max_routes = 64;
/// Maximum path parameters per route.
const max_params = 8;

/// The compiled route table (generated at comptime).
routes: []const Route,

/// Result of a successful route match.
pub const Match = struct {
    /// The handler function for the matched route.
    handler: HandlerFn,
    /// Captured path parameters (e.g. `:id` → `"42"`).
    params: []const Request.Param,
};

/// Compile a route pattern into segments at comptime.
fn compilePattern(comptime pattern: []const u8) []const Segment {
    comptime {
        var segments: []const Segment = &.{};
        var iter = mem.splitScalar(u8, pattern, '/');

        while (iter.next()) |segment| {
            if (segment.len == 0) continue; // Skip empty segments (leading /)
            if (segment[0] == ':') {
                // Parameter segment
                segments = segments ++ &[_]Segment{.{ .param = segment[1..] }};
            } else {
                // Literal segment
                segments = segments ++ &[_]Segment{.{ .literal = segment }};
            }
        }
        return segments;
    }
}

/// Create a router from comptime route definitions.
///
/// Usage:
/// ```
/// const router = Router.init(.{
///     .{ .GET,  "/",           indexHandler  },
///     .{ .GET,  "/users/:id",  userHandler   },
///     .{ .POST, "/api/echo",   echoHandler   },
/// });
/// ```
pub fn init(comptime route_defs: anytype) Router {
    comptime {
        const defs = route_defs;
        var routes: []const Route = &.{};

        for (defs) |def| {
            const method: http.Method = def[0];
            const pattern: []const u8 = def[1];
            const handler: HandlerFn = def[2];

            routes = routes ++ &[_]Route{.{
                .method = method,
                .pattern = pattern,
                .segments = compilePattern(pattern),
                .handler = handler,
            }};
        }

        return .{ .routes = routes };
    }
}

/// Match a request method and path against the route table.
///
/// Returns the matching handler and extracted path parameters.
/// Uses the provided allocator (should be the request arena) for parameter storage.
pub fn dispatch(
    self: *const Router,
    method: http.Method,
    path: []const u8,
    allocator: std.mem.Allocator,
) ?Match {
    for (self.routes) |route| {
        // Method must match
        if (route.method != method) continue;

        // Try to match path segments
        if (matchPath(route.segments, path, allocator)) |params| {
            return .{
                .handler = route.handler,
                .params = params,
            };
        }
    }
    return null;
}

/// Try to match a path against a compiled pattern.
/// Returns extracted parameters on success, null on failure.
fn matchPath(
    segments: []const Segment,
    path: []const u8,
    allocator: std.mem.Allocator,
) ?[]const Request.Param {
    var path_iter = mem.splitScalar(u8, path, '/');
    var params_buf: [max_params]Request.Param = undefined;
    var param_count: usize = 0;
    var seg_idx: usize = 0;

    while (path_iter.next()) |part| {
        if (part.len == 0) continue; // Skip empty segments

        if (seg_idx >= segments.len) return null; // Path has more segments than pattern

        const segment = segments[seg_idx];
        switch (segment) {
            .literal => |lit| {
                if (!mem.eql(u8, lit, part)) return null; // Literal mismatch
            },
            .param => |key| {
                if (param_count >= max_params) return null; // Too many params
                params_buf[param_count] = .{ .key = key, .value = part };
                param_count += 1;
            },
        }
        seg_idx += 1;
    }

    // All pattern segments must be consumed
    if (seg_idx != segments.len) return null;

    // Copy params to arena-allocated slice
    if (param_count == 0) return &.{};

    const params = allocator.dupe(Request.Param, params_buf[0..param_count]) catch return null;
    return params;
}

// ---- Tests ----

fn dummyHandler(_: *Request, _: *Response, _: Io) anyerror!void {}
fn otherHandler(_: *Request, _: *Response, _: Io) anyerror!void {}

// ---------------------------------------------------------------------------
// compilePattern tests
// ---------------------------------------------------------------------------

test "compile pattern - static" {
    const segments = comptime compilePattern("/api/users");
    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqualStrings("api", segments[0].literal);
    try std.testing.expectEqualStrings("users", segments[1].literal);
}

test "compile pattern - with params" {
    const segments = comptime compilePattern("/users/:id/posts/:post_id");
    try std.testing.expectEqual(@as(usize, 4), segments.len);
    try std.testing.expectEqualStrings("users", segments[0].literal);
    try std.testing.expectEqualStrings("id", segments[1].param);
    try std.testing.expectEqualStrings("posts", segments[2].literal);
    try std.testing.expectEqualStrings("post_id", segments[3].param);
}

test "compile pattern - root path" {
    const segments = comptime compilePattern("/");
    try std.testing.expectEqual(@as(usize, 0), segments.len);
}

test "compile pattern - single segment" {
    const segments = comptime compilePattern("/health");
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqualStrings("health", segments[0].literal);
}

test "compile pattern - param only" {
    const segments = comptime compilePattern("/:id");
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqualStrings("id", segments[0].param);
}

test "compile pattern - deeply nested" {
    const segments = comptime compilePattern("/a/b/c/d/e");
    try std.testing.expectEqual(@as(usize, 5), segments.len);
    try std.testing.expectEqualStrings("a", segments[0].literal);
    try std.testing.expectEqualStrings("e", segments[4].literal);
}

// ---------------------------------------------------------------------------
// Router dispatch tests
// ---------------------------------------------------------------------------

test "router dispatch - static route" {
    const router = comptime Router.init(.{
        .{ .GET, "/", dummyHandler },
        .{ .GET, "/api/health", dummyHandler },
    });

    const gpa = std.testing.allocator;

    // "/" should match
    {
        const match = router.dispatch(.GET, "/", gpa);
        try std.testing.expect(match != null);
    }

    // "/api/health" should match
    {
        const match = router.dispatch(.GET, "/api/health", gpa);
        try std.testing.expect(match != null);
    }

    // Wrong method should not match
    {
        const match = router.dispatch(.POST, "/api/health", gpa);
        try std.testing.expect(match == null);
    }

    // Unknown path should not match
    {
        const match = router.dispatch(.GET, "/unknown", gpa);
        try std.testing.expect(match == null);
    }
}

test "router dispatch - parameterized route" {
    const router = comptime Router.init(.{
        .{ .GET, "/users/:id", dummyHandler },
    });

    const gpa = std.testing.allocator;

    const match = router.dispatch(.GET, "/users/42", gpa);
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 1), match.?.params.len);
    try std.testing.expectEqualStrings("id", match.?.params[0].key);
    try std.testing.expectEqualStrings("42", match.?.params[0].value);

    // Don't forget to free the arena-allocated params in test
    gpa.free(match.?.params);
}

test "router dispatch - multiple params" {
    const router = comptime Router.init(.{
        .{ .GET, "/users/:user_id/posts/:post_id", dummyHandler },
    });

    const gpa = std.testing.allocator;

    const match = router.dispatch(.GET, "/users/7/posts/99", gpa);
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 2), match.?.params.len);

    try std.testing.expectEqualStrings("user_id", match.?.params[0].key);
    try std.testing.expectEqualStrings("7", match.?.params[0].value);
    try std.testing.expectEqualStrings("post_id", match.?.params[1].key);
    try std.testing.expectEqualStrings("99", match.?.params[1].value);

    gpa.free(match.?.params);
}

test "router dispatch - extra path segments don't match" {
    const router = comptime Router.init(.{
        .{ .GET, "/api", dummyHandler },
    });
    const gpa = std.testing.allocator;

    // "/api/extra" has more segments than pattern "/api"
    const match = router.dispatch(.GET, "/api/extra", gpa);
    try std.testing.expect(match == null);
}

test "router dispatch - fewer path segments don't match" {
    const router = comptime Router.init(.{
        .{ .GET, "/api/health", dummyHandler },
    });
    const gpa = std.testing.allocator;

    // "/api" has fewer segments than pattern "/api/health"
    const match = router.dispatch(.GET, "/api", gpa);
    try std.testing.expect(match == null);
}

test "router dispatch - method-specific matching" {
    const router = comptime Router.init(.{
        .{ .GET, "/data", dummyHandler },
        .{ .POST, "/data", otherHandler },
    });
    const gpa = std.testing.allocator;

    // GET should match the first handler
    {
        const match = router.dispatch(.GET, "/data", gpa);
        try std.testing.expect(match != null);
        try std.testing.expectEqual(match.?.handler, dummyHandler);
    }

    // POST should match the second handler
    {
        const match = router.dispatch(.POST, "/data", gpa);
        try std.testing.expect(match != null);
        try std.testing.expectEqual(match.?.handler, otherHandler);
    }

    // DELETE has no route
    {
        const match = router.dispatch(.DELETE, "/data", gpa);
        try std.testing.expect(match == null);
    }
}

test "router dispatch - root path returns empty params" {
    const router = comptime Router.init(.{
        .{ .GET, "/", dummyHandler },
    });
    const gpa = std.testing.allocator;

    const match = router.dispatch(.GET, "/", gpa);
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 0), match.?.params.len);
}

test "router dispatch - param with various values" {
    const router = comptime Router.init(.{
        .{ .GET, "/items/:id", dummyHandler },
    });
    const gpa = std.testing.allocator;

    // Numeric value
    {
        const match = router.dispatch(.GET, "/items/123", gpa).?;
        try std.testing.expectEqualStrings("123", match.params[0].value);
        gpa.free(match.params);
    }

    // Alphanumeric value
    {
        const match = router.dispatch(.GET, "/items/abc-def", gpa).?;
        try std.testing.expectEqualStrings("abc-def", match.params[0].value);
        gpa.free(match.params);
    }

    // UUID-like value
    {
        const match = router.dispatch(.GET, "/items/550e8400-e29b-41d4-a716-446655440000", gpa).?;
        try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", match.params[0].value);
        gpa.free(match.params);
    }
}

test "router dispatch - multiple routes first match wins" {
    const router = comptime Router.init(.{
        .{ .GET, "/users/:id", dummyHandler },
        .{ .GET, "/users/:name", otherHandler },
    });
    const gpa = std.testing.allocator;

    // First matching route should win
    const match = router.dispatch(.GET, "/users/alice", gpa).?;
    try std.testing.expectEqual(match.handler, dummyHandler);
    try std.testing.expectEqualStrings("id", match.params[0].key);
    gpa.free(match.params);
}
