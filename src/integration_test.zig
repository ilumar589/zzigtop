//! Integration tests for the HTTP/1 server.
//!
//! This is a standalone executable that:
//! 1. Starts the HTTP server on a test port in a background thread
//! 2. Sends real HTTP requests using raw TCP
//! 3. Validates the responses
//! 4. Reports pass/fail and exits
//!
//! Run with: zig build integration-test

const std = @import("std");
const http = @import("learn_zig").http;
const Io = std.Io;
const net = Io.net;

/// Test port — use a high port to avoid conflicts.
const test_port: u16 = 18_080;

// ============================================================================
// Test Handlers (same as http_server_main.zig for consistency)
// ============================================================================

fn handleIndex(_: *http.Request, response: *http.Response) anyerror!void {
    try response.sendText(.ok, "Welcome!");
}

fn handleHealth(_: *http.Request, response: *http.Response) anyerror!void {
    try response.sendJson(.ok, "{\"status\":\"ok\"}");
}

fn handleHello(request: *http.Request, response: *http.Response) anyerror!void {
    const name = request.pathParam("name") orelse "world";
    const body = try std.fmt.allocPrint(request.arena, "Hello, {s}!", .{name});
    try response.sendText(.ok, body);
}

fn handleEcho(request: *http.Request, response: *http.Response) anyerror!void {
    const body = try std.fmt.allocPrint(
        request.arena,
        "Method: {s}\nPath: {s}\n",
        .{ @tagName(request.method), request.path },
    );
    try response.sendText(.ok, body);
}

/// Comptime router for integration tests.
const router = http.Router.init(.{
    .{ .GET, "/", handleIndex },
    .{ .GET, "/health", handleHealth },
    .{ .GET, "/hello/:name", handleHello },
    .{ .POST, "/echo", handleEcho },
});

// ============================================================================
// Test infrastructure
// ============================================================================

var tests_passed: u32 = 0;
var tests_failed: u32 = 0;
var tests_total: u32 = 0;

fn reportResult(name: []const u8, passed: bool, detail: []const u8) void {
    tests_total += 1;
    if (passed) {
        tests_passed += 1;
        std.debug.print("  \x1b[32mPASS\x1b[0m {s}\n", .{name});
    } else {
        tests_failed += 1;
        std.debug.print("  \x1b[31mFAIL\x1b[0m {s}: {s}\n", .{ name, detail });
    }
}

/// Send a raw HTTP request over TCP and return the full response bytes.
fn sendRequest(io: Io, request_bytes: []const u8, buf: []u8) ![]const u8 {
    const address: net.IpAddress = .{
        .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = test_port,
        },
    };

    const stream = try net.IpAddress.connect(address, io, .{ .mode = .stream });
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);

    // Send the request
    try writer.interface.writeAll(request_bytes);
    try writer.interface.flush();

    // Read the response using readVec
    var total: usize = 0;
    while (total < buf.len) {
        var iov = [1][]u8{buf[total..]};
        const n = reader.interface.readVec(&iov) catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => return err,
            }
        };
        if (n == 0) break;
        total += n;

        // Check if we've received the full response (look for body completion).
        // For simplicity, once we have the header-end marker and enough body, stop.
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |header_end| {
            // Try to find Content-Length
            const headers_str = buf[0..header_end];
            if (findContentLength(headers_str)) |content_len| {
                const body_start = header_end + 4;
                const body_received = total - body_start;
                if (body_received >= content_len) break;
            } else {
                // No Content-Length — assume response is complete after headers + some data
                break;
            }
        }
    }

    return buf[0..total];
}

fn findContentLength(headers: []const u8) ?usize {
    // Simple scan for "content-length: <num>"
    var i: usize = 0;
    while (i < headers.len) {
        // Find start of a line
        const line_start = i;
        const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse headers.len;
        const line = headers[line_start..line_end];

        if (line.len > 16 and std.ascii.eqlIgnoreCase(line[0..16], "content-length: ")) {
            return std.fmt.parseInt(usize, line[16..], 10) catch null;
        }

        i = if (line_end + 2 <= headers.len) line_end + 2 else headers.len;
    }
    return null;
}

/// Check that the response contains an expected status code.
fn expectStatus(response: []const u8, expected_code: u16) bool {
    // Status line format: "HTTP/1.1 200 OK\r\n"
    if (response.len < 12) return false;
    const status_start = std.mem.indexOf(u8, response, " ") orelse return false;
    const code_str = response[status_start + 1 ..][0..3];
    const actual_code = std.fmt.parseInt(u16, code_str, 10) catch return false;
    return actual_code == expected_code;
}

/// Check that the response body contains an expected string.
fn expectBodyContains(response: []const u8, expected: []const u8) bool {
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return false;
    const body = response[body_start + 4 ..];
    return std.mem.indexOf(u8, body, expected) != null;
}

/// Check that a response header contains a specific value.
fn expectHeaderContains(response: []const u8, header_name: []const u8, expected_value: []const u8) bool {
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return false;
    const headers = response[0..header_end];

    // Scan each header line
    var i: usize = 0;
    while (i < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse headers.len;
        const line = headers[i..line_end];

        // Check if this line starts with the header name (case-insensitive)
        if (line.len > header_name.len + 2) {
            if (std.ascii.eqlIgnoreCase(line[0..header_name.len], header_name) and line[header_name.len] == ':') {
                const value = std.mem.trim(u8, line[header_name.len + 1 ..], " ");
                if (std.mem.indexOf(u8, value, expected_value) != null) return true;
            }
        }

        i = if (line_end + 2 <= headers.len) line_end + 2 else headers.len;
    }
    return false;
}

// ============================================================================
// Integration Tests
// ============================================================================

fn runTests(io: Io) void {
    var buf: [16384]u8 = undefined;

    // --- Test 1: GET / returns 200 with welcome text ---
    {
        const response = sendRequest(io, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buf) catch {
            reportResult("GET / - 200 OK", false, "connection failed");
            return;
        };

        const status_ok = expectStatus(response, 200);
        const body_ok = expectBodyContains(response, "Welcome!");
        reportResult("GET / - 200 OK", status_ok and body_ok, if (!status_ok) "wrong status" else "wrong body");
    }

    // --- Test 2: GET /health returns JSON ---
    {
        const response = sendRequest(io, "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buf) catch {
            reportResult("GET /health - JSON", false, "connection failed");
            return;
        };

        const status_ok = expectStatus(response, 200);
        const body_ok = expectBodyContains(response, "\"status\":\"ok\"");
        const ct_ok = expectHeaderContains(response, "content-type", "application/json");
        const all_ok = status_ok and body_ok and ct_ok;
        reportResult("GET /health - JSON response", all_ok, if (!status_ok) "wrong status" else if (!body_ok) "wrong body" else "wrong content-type");
    }

    // --- Test 3: GET /hello/:name with path parameter ---
    {
        const response = sendRequest(io, "GET /hello/Zig HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buf) catch {
            reportResult("GET /hello/:name - param", false, "connection failed");
            return;
        };

        const status_ok = expectStatus(response, 200);
        const body_ok = expectBodyContains(response, "Hello, Zig!");
        reportResult("GET /hello/:name - param extraction", status_ok and body_ok, if (!status_ok) "wrong status" else "wrong body");
    }

    // --- Test 4: POST /echo ---
    {
        const response = sendRequest(io, "POST /echo HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", &buf) catch {
            reportResult("POST /echo", false, "connection failed");
            return;
        };

        const status_ok = expectStatus(response, 200);
        const body_ok = expectBodyContains(response, "Method: POST") and expectBodyContains(response, "Path: /echo");
        reportResult("POST /echo - method and path", status_ok and body_ok, if (!status_ok) "wrong status" else "wrong body");
    }

    // --- Test 5: 404 for unknown route ---
    {
        const response = sendRequest(io, "GET /nonexistent HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buf) catch {
            reportResult("GET /nonexistent - 404", false, "connection failed");
            return;
        };

        const status_ok = expectStatus(response, 404);
        const body_ok = expectBodyContains(response, "Not Found");
        reportResult("GET /nonexistent - 404 Not Found", status_ok and body_ok, if (!status_ok) "wrong status" else "wrong body");
    }

    // --- Test 6: Wrong method returns 404 ---
    {
        const response = sendRequest(io, "DELETE / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buf) catch {
            reportResult("DELETE / - 404", false, "connection failed");
            return;
        };

        const status_ok = expectStatus(response, 404);
        reportResult("DELETE / - wrong method returns 404", status_ok, "expected 404");
    }

    // --- Test 7: Keep-alive - two requests on same connection ---
    {
        const address: net.IpAddress = .{
            .ip4 = .{
                .bytes = .{ 127, 0, 0, 1 },
                .port = test_port,
            },
        };

        const stream = net.IpAddress.connect(address, io, .{ .mode = .stream }) catch {
            reportResult("Keep-alive - reuse", false, "connection failed");
            return;
        };
        defer stream.close(io);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;

        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);

        // First request (keep-alive by default in HTTP/1.1)
        writer.interface.writeAll("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n") catch {
            reportResult("Keep-alive - reuse", false, "write failed");
            return;
        };
        writer.interface.flush() catch {
            reportResult("Keep-alive - reuse", false, "flush failed");
            return;
        };

        // Read the first response
        var total1: usize = 0;
        while (total1 < buf.len) {
            var iov1 = [1][]u8{buf[total1..]};
            const n = reader.interface.readVec(&iov1) catch break;
            if (n == 0) break;
            total1 += n;
            if (std.mem.indexOf(u8, buf[0..total1], "\r\n\r\n")) |hdr_end| {
                if (findContentLength(buf[0..hdr_end])) |cl| {
                    if (total1 - hdr_end - 4 >= cl) break;
                } else break;
            }
        }

        const first_ok = total1 > 0 and expectStatus(buf[0..total1], 200);

        // Second request on the same connection
        writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n") catch {
            reportResult("Keep-alive - reuse", false, "second write failed");
            return;
        };
        writer.interface.flush() catch {
            reportResult("Keep-alive - reuse", false, "second flush failed");
            return;
        };

        var total2: usize = 0;
        while (total2 < buf.len) {
            var iov2 = [1][]u8{buf[total2..]};
            const n = reader.interface.readVec(&iov2) catch break;
            if (n == 0) break;
            total2 += n;
            if (std.mem.indexOf(u8, buf[0..total2], "\r\n\r\n")) |hdr_end| {
                if (findContentLength(buf[0..hdr_end])) |cl| {
                    if (total2 - hdr_end - 4 >= cl) break;
                } else break;
            }
        }

        const second_ok = total2 > 0 and expectStatus(buf[0..total2], 200) and expectBodyContains(buf[0..total2], "Welcome!");

        reportResult("Keep-alive - two requests on one connection", first_ok and second_ok, if (!first_ok) "first request failed" else "second request failed");
    }

    // --- Test 8: Content-Length header is present ---
    {
        const response = sendRequest(io, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buf) catch {
            reportResult("Content-Length present", false, "connection failed");
            return;
        };

        const has_cl = expectHeaderContains(response, "content-length", "");
        reportResult("Content-Length header present", has_cl, "missing content-length");
    }

    // --- Test 9: Different path params ---
    {
        const response = sendRequest(io, "GET /hello/World HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &buf) catch {
            reportResult("GET /hello/World", false, "connection failed");
            return;
        };

        const body_ok = expectBodyContains(response, "Hello, World!");
        reportResult("GET /hello/World - different param value", body_ok, "wrong body");
    }

    // --- Test 10: HTTP/1.0 with Connection: close ---
    {
        const response = sendRequest(io, "GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n", &buf) catch {
            reportResult("HTTP/1.0 request", false, "connection failed");
            return;
        };

        const status_ok = expectStatus(response, 200);
        reportResult("HTTP/1.0 request works", status_ok, "wrong status");
    }
}

// ============================================================================
// Entry point
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    std.debug.print(
        \\
        \\  ╔══════════════════════════════════════════╗
        \\  ║   HTTP Server Integration Tests          ║
        \\  ╚══════════════════════════════════════════╝
        \\
        \\
    , .{});

    // Start the server in a background thread.
    std.debug.print("Starting server on port {d}...\n", .{test_port});

    var server = try http.Server.start(init.gpa, io, .{
        .port = test_port,
        .router = &router,
        .reuse_address = true,
    });
    defer server.deinit(io);

    // Run the accept loop in a background thread.
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server, sio: Io) void {
            s.run(sio);
        }
    }.run, .{ &server, io });
    _ = server_thread; // We'll just let this thread die when the process exits.

    // Give the server a moment to start accepting connections.
    Io.sleep(io, Io.Duration.fromMilliseconds(100), .awake) catch {};

    std.debug.print("Running tests...\n\n", .{});

    // Run all integration tests.
    runTests(io);

    // Print summary.
    std.debug.print(
        \\
        \\  ──────────────────────────────────────────
        \\  Results: {d}/{d} passed, {d} failed
        \\  ──────────────────────────────────────────
        \\
    , .{ tests_passed, tests_total, tests_failed });

    if (tests_failed > 0) {
        std.debug.print("\n  \x1b[31mSome tests failed!\x1b[0m\n\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n  \x1b[32mAll integration tests passed!\x1b[0m\n\n", .{});
    }
}
