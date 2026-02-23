//! Built-in HTTP server benchmark.
//!
//! Spawns the HTTP server on a test port and hammers it with concurrent
//! requests from multiple threads, measuring throughput and latency.
//!
//! Run with:
//!   zig build benchmark -Doptimize=ReleaseFast
//!
//! For external benchmarks, start the server and use:
//!   bombardier -c 100 -d 10s http://127.0.0.1:8080/health
//!   wrk -t4 -c100 -d10s http://127.0.0.1:8080/health

const std = @import("std");
const http = @import("zzigtop").http;
const Io = std.Io;
const net = Io.net;

const bench_port: u16 = 18_090;

// ============================================================================
// Handlers (minimal — we're measuring server overhead, not handler logic)
// ============================================================================

fn handlePlain(_: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    try response.sendText(.ok, "OK");
}

fn handleJson(_: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    try response.sendJson(.ok, "{\"status\":\"ok\"}");
}

fn handleParam(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const id = request.pathParam("id") orelse "0";
    const body = try std.fmt.allocPrint(request.arena, "id={s}", .{id});
    try response.sendText(.ok, body);
}

const router = http.Router.init(.{
    .{ .GET, "/", handlePlain },
    .{ .GET, "/json", handleJson },
    .{ .GET, "/param/:id", handleParam },
});

// ============================================================================
// Benchmark configuration
// ============================================================================

const BenchConfig = struct {
    /// Number of concurrent client threads.
    num_threads: u32 = 4,
    /// Total requests per thread.
    requests_per_thread: u32 = 10_000,
    /// Request path to benchmark.
    path: []const u8 = "/",
    /// Name for display.
    name: []const u8 = "GET /",
    /// Whether to reuse the TCP connection (keep-alive) across requests.
    keep_alive: bool = false,
};

const benchmarks = [_]BenchConfig{
    // -- Connection-per-request (baseline) --
    .{ .name = "GET / (conn-per-req)", .path = "/", .num_threads = 4, .requests_per_thread = 10_000 },
    .{ .name = "GET /json (conn-per-req)", .path = "/json", .num_threads = 4, .requests_per_thread = 10_000 },
    // -- Keep-alive (connection reuse) --
    .{ .name = "GET / (keep-alive)", .path = "/", .num_threads = 4, .requests_per_thread = 10_000, .keep_alive = true },
    .{ .name = "GET /json (keep-alive)", .path = "/json", .num_threads = 4, .requests_per_thread = 10_000, .keep_alive = true },
    .{ .name = "GET /param/:id (keep-alive)", .path = "/param/42", .num_threads = 4, .requests_per_thread = 10_000, .keep_alive = true },
    .{ .name = "GET / (keep-alive, 16 threads)", .path = "/", .num_threads = 16, .requests_per_thread = 5_000, .keep_alive = true },
};

// ============================================================================
// Benchmark worker
// ============================================================================

/// Aggregated latency/throughput results from a single benchmark worker.
const WorkerResult = struct {
    successful: u64 = 0,
    failed: u64 = 0,
    total_latency_ns: u64 = 0,
    min_latency_ns: u64 = std.math.maxInt(u64),
    max_latency_ns: u64 = 0,
};

/// Connection-per-request benchmark worker.
fn benchmarkWorker(io: Io, path: []const u8, num_requests: u32) WorkerResult {
    var result: WorkerResult = .{};
    var buf: [4096]u8 = undefined;

    // Build the request bytes once
    var req_buf: [512]u8 = undefined;
    const request_bytes = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{path}) catch return result;

    for (0..num_requests) |_| {
        const start = Io.Timestamp.now(io, .awake);

        const success = blk: {
            const address: net.IpAddress = .{
                .ip4 = .{
                    .bytes = .{ 127, 0, 0, 1 },
                    .port = bench_port,
                },
            };

            const stream = net.IpAddress.connect(address, io, .{ .mode = .stream }) catch break :blk false;
            defer stream.close(io);

            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;

            var reader = stream.reader(io, &read_buffer);
            var writer = stream.writer(io, &write_buffer);

            writer.interface.writeAll(request_bytes) catch break :blk false;
            writer.interface.flush() catch break :blk false;

            // Read until connection close
            var total: usize = 0;
            while (total < buf.len) {
                var iov = [1][]u8{buf[total..]};
                const n = reader.interface.readVec(&iov) catch break;
                if (n == 0) break;
                total += n;
            }

            break :blk total > 0 and buf[9] == '2'; // "HTTP/1.1 2xx"
        };

        const end = Io.Timestamp.now(io, .awake);
        const latency: u64 = @intCast(start.durationTo(end).nanoseconds);

        if (success) {
            result.successful += 1;
            result.total_latency_ns += latency;
            if (latency < result.min_latency_ns) result.min_latency_ns = latency;
            if (latency > result.max_latency_ns) result.max_latency_ns = latency;
        } else {
            result.failed += 1;
        }
    }

    return result;
}

/// Keep-alive benchmark worker — reuses a single TCP connection for all requests.
fn keepaliveBenchmarkWorker(io: Io, path: []const u8, num_requests: u32) WorkerResult {
    var result: WorkerResult = .{};
    var buf: [8192]u8 = undefined;

    var req_buf: [512]u8 = undefined;
    const request_bytes = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{path}) catch return result;

    const address: net.IpAddress = .{
        .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = bench_port,
        },
    };

    const stream = net.IpAddress.connect(address, io, .{ .mode = .stream }) catch return result;
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;

    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);

    for (0..num_requests) |_| {
        const start = Io.Timestamp.now(io, .awake);

        const success = blk: {
            writer.interface.writeAll(request_bytes) catch break :blk false;
            writer.interface.flush() catch break :blk false;

            // Read until we have the full response (headers + body).
            // We need to parse Content-Length to know where the response ends.
            var total: usize = 0;
            while (total < buf.len) {
                var iov = [1][]u8{buf[total..]};
                const n = reader.interface.readVec(&iov) catch break;
                if (n == 0) break;
                total += n;

                // Check if we have the complete response
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |hdr_end| {
                    const body_start = hdr_end + 4;
                    if (findContentLengthInHeaders(buf[0..hdr_end])) |cl| {
                        if (total - body_start >= cl) break;
                    } else {
                        break; // No Content-Length, assume done
                    }
                }
            }

            break :blk total > 0 and buf[9] == '2';
        };

        const end = Io.Timestamp.now(io, .awake);
        const latency: u64 = @intCast(start.durationTo(end).nanoseconds);

        if (success) {
            result.successful += 1;
            result.total_latency_ns += latency;
            if (latency < result.min_latency_ns) result.min_latency_ns = latency;
            if (latency > result.max_latency_ns) result.max_latency_ns = latency;
        } else {
            result.failed += 1;
        }
    }

    return result;
}

/// Parse Content-Length from raw header bytes.
fn findContentLengthInHeaders(headers: []const u8) ?usize {
    var i: usize = 0;
    while (i < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse headers.len;
        const line = headers[i..line_end];

        if (line.len > 16 and std.ascii.eqlIgnoreCase(line[0..16], "content-length: ")) {
            return std.fmt.parseInt(usize, line[16..], 10) catch null;
        }

        i = if (line_end + 2 <= headers.len) line_end + 2 else headers.len;
    }
    return null;
}

/// Run a full benchmark pass: spawn worker threads, collect results, print stats.
fn runBenchmark(io: Io, config: BenchConfig) void {
    std.debug.print("  {s}\n", .{config.name});
    std.debug.print("    Threads: {d}, Requests/thread: {d}, Total: {d}\n", .{
        config.num_threads,
        config.requests_per_thread,
        @as(u64, config.num_threads) * config.requests_per_thread,
    });

    const total_requests: u64 = @as(u64, config.num_threads) * config.requests_per_thread;

    // Spawn worker threads
    var threads: [64]std.Thread = undefined;
    var results: [64]WorkerResult = undefined;

    const wall_start = Io.Timestamp.now(io, .awake);

    for (0..config.num_threads) |i| {
        threads[i] = std.Thread.spawn(.{}, struct {
            fn run(sio: Io, path: []const u8, n: u32, out: *WorkerResult, ka: bool) void {
                out.* = if (ka) keepaliveBenchmarkWorker(sio, path, n) else benchmarkWorker(sio, path, n);
            }
        }.run, .{ io, config.path, config.requests_per_thread, &results[i], config.keep_alive }) catch {
            std.debug.print("    \x1b[31mFailed to spawn thread {d}\x1b[0m\n", .{i});
            return;
        };
    }

    // Wait for all threads
    for (0..config.num_threads) |i| {
        threads[i].join();
    }

    const wall_end = Io.Timestamp.now(io, .awake);
    const wall_ns: u64 = @intCast(wall_start.durationTo(wall_end).nanoseconds);

    // Aggregate results
    var total_successful: u64 = 0;
    var total_failed: u64 = 0;
    var total_latency: u64 = 0;
    var min_latency: u64 = std.math.maxInt(u64);
    var max_latency: u64 = 0;

    for (0..config.num_threads) |i| {
        total_successful += results[i].successful;
        total_failed += results[i].failed;
        total_latency += results[i].total_latency_ns;
        if (results[i].min_latency_ns < min_latency) min_latency = results[i].min_latency_ns;
        if (results[i].max_latency_ns > max_latency) max_latency = results[i].max_latency_ns;
    }

    const avg_latency = if (total_successful > 0) total_latency / total_successful else 0;
    const wall_secs = @as(f64, @floatFromInt(wall_ns)) / 1_000_000_000.0;
    const rps = @as(f64, @floatFromInt(total_successful)) / wall_secs;

    std.debug.print("    Results:\n", .{});
    std.debug.print("      Requests:   {d}/{d} successful ({d} failed)\n", .{ total_successful, total_requests, total_failed });
    std.debug.print("      Wall time:  {d:.2}s\n", .{wall_secs});
    std.debug.print("      Throughput: {d:.0} req/s\n", .{rps});
    var avg_buf: [32]u8 = undefined;
    var min_buf: [32]u8 = undefined;
    var max_buf: [32]u8 = undefined;
    const avg_str = formatDurationBuf(avg_latency, &avg_buf);
    const min_str = formatDurationBuf(min_latency, &min_buf);
    const max_str = formatDurationBuf(max_latency, &max_buf);
    std.debug.print("      Latency:    avg={s}  min={s}  max={s}\n", .{
        avg_str,
        min_str,
        max_str,
    });
    std.debug.print("\n", .{});
}

/// Format a nanosecond duration into a human-readable string (e.g. "12.34ms").
fn formatDurationBuf(ns: u64, buf: []u8) []const u8 {
    if (ns >= 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch "?";
    } else if (ns >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch "?";
    } else if (ns >= 1_000) {
        return std.fmt.bufPrint(buf, "{d:.2}us", .{@as(f64, @floatFromInt(ns)) / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "?";
    }
}

// ============================================================================
// Entry point
// ============================================================================

/// Benchmark entry point — starts the server, runs all benchmark passes, and prints a summary.
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    std.debug.print(
        \\
        \\  ╔══════════════════════════════════════════╗
        \\  ║   HTTP Server Benchmark                  ║
        \\  ╚══════════════════════════════════════════╝
        \\
        \\
    , .{});

    // Start the server (ReleaseFast recommended for meaningful results).
    std.debug.print("Starting server on port {d}...\n", .{bench_port});

    var server = try http.Server.start(init.gpa, io, .{
        .port = bench_port,
        .router = &router,
        .reuse_address = true,
        .metrics_interval_s = 0, // Disable metrics logging during benchmarks
    });
    defer server.deinit(io);

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *http.Server, sio: Io) void {
            s.run(sio) catch {};
        }
    }.run, .{ &server, io });
    _ = server_thread;

    // Let the server warm up.
    Io.sleep(io, Io.Duration.fromMilliseconds(200), .awake) catch {};

    std.debug.print("Running benchmarks...\n\n", .{});

    for (&benchmarks) |*bench| {
        runBenchmark(io, bench.*);
    }

    std.debug.print(
        \\  ──────────────────────────────────────────
        \\  Benchmark complete.
        \\
        \\  For more thorough benchmarks, use external tools:
        \\    bombardier -c 100 -d 10s http://127.0.0.1:8080/health
        \\    wrk -t4 -c100 -d10s http://127.0.0.1:8080/health
        \\  ──────────────────────────────────────────
        \\
    , .{});
}
