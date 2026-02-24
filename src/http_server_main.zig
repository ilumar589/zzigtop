//! High-Performance HTTP/1 Server — Entry Point
//!
//! Usage:
//!   zig build run-server                             # Debug, port 8080
//!   zig build run-server -Doptimize=ReleaseFast      # Max performance
//!   zig build run-server -- --port 3000               # Custom port
//!   zig build run-server -- --static-dir assets       # Custom static root
//!   zig build run-server -- --no-static               # Disable static files

const std = @import("std");
const http = @import("zzigtop").http;
const db = @import("zzigtop").db;
const html = @import("zzigtop").html;
const scraper_handlers = @import("zzigtop").football_scraping.Handlers;
const Middleware = http.Middleware;
const pg = @import("pg");

/// Global middleware stack applied to all routes.
/// Logs every request and adds standard security headers.
fn withMiddleware(comptime handler: Middleware.HandlerFn) Middleware.HandlerFn {
    return Middleware.chain(handler, &.{ Middleware.logging, Middleware.securityHeaders });
}

/// API middleware: logging + CORS + security + no-cache.
const api_cors = Middleware.Cors.init(.{});
fn withApiMiddleware(comptime handler: Middleware.HandlerFn) Middleware.HandlerFn {
    return Middleware.chain(handler, &.{ Middleware.logging, api_cors, Middleware.securityHeaders, Middleware.noCache });
}

/// Comptime-defined routes — compiled into an optimized match table.
/// Routes use middleware wrappers for cross-cutting concerns:
///   - `withMiddleware`: logging + security headers (general routes)
///   - `withApiMiddleware`: logging + CORS + security + no-cache (API routes)
const router = http.Router.init(.{
    .{ .GET, "/", withMiddleware(handleIndex) },
    .{ .GET, "/health", withMiddleware(handleHealth) },
    .{ .GET, "/hello/:name", withMiddleware(handleHello) },
    .{ .POST, "/echo", withMiddleware(handleEcho) },
    .{ .POST, "/api/echo-json", withApiMiddleware(handleEchoJson) },
    .{ .GET, "/dashboard/:id", withMiddleware(handleDashboard) },
    .{ .GET, "/metrics", withApiMiddleware(handleMetrics) },
    .{ .GET, "/search", withApiMiddleware(handleSearch) },
    // ---- REST API: Users (Step 13) — with CORS + no-cache ----
    .{ .GET, "/api/users", withApiMiddleware(handleListUsers) },
    .{ .GET, "/api/users/:id", withApiMiddleware(handleGetUser) },
    .{ .POST, "/api/users", withApiMiddleware(handleCreateUser) },
    .{ .PUT, "/api/users/:id", withApiMiddleware(handleUpdateUser) },
    .{ .DELETE, "/api/users/:id", withApiMiddleware(handleDeleteUser) },
    // ---- CORS Preflight for API routes ----
    .{ .OPTIONS, "/api/users", Middleware.Cors.preflight(.{}) },
    .{ .OPTIONS, "/api/users/:id", Middleware.Cors.preflight(.{}) },
    .{ .OPTIONS, "/api/echo-json", Middleware.Cors.preflight(.{}) },
    // ---- htmx + Template Demo (Step 17) ----
    .{ .GET, "/htmx", withMiddleware(handleHtmxDemo) },
    .{ .GET, "/htmx/time", withMiddleware(handleHtmxTime) },
    .{ .POST, "/htmx/counter", withMiddleware(handleHtmxCounter) },
    .{ .GET, "/htmx/users", withMiddleware(handleHtmxUsers) },
    .{ .GET, "/htmx/search", withMiddleware(handleHtmxSearch) },
    // ---- Football Scraper (Step 18) — with logging + security ----
    .{ .GET, "/scraper", withMiddleware(scraper_handlers.handleDashboard) },
    .{ .GET, "/scraper/dashboard-content", withMiddleware(scraper_handlers.handleDashboardContent) },
    .{ .POST, "/scraper/start", withMiddleware(scraper_handlers.handleStartScrape) },
    .{ .GET, "/scraper/progress", withMiddleware(scraper_handlers.handleProgress) },
    .{ .GET, "/scraper/sites", withMiddleware(scraper_handlers.handleSites) },
    .{ .GET, "/scraper/sites-content", withMiddleware(scraper_handlers.handleSitesContent) },
    .{ .PUT, "/scraper/api/sites/:id/toggle", withApiMiddleware(scraper_handlers.handleToggleSite) },
    .{ .GET, "/scraper/results", withMiddleware(scraper_handlers.handleResults) },
    .{ .GET, "/scraper/results-content", withMiddleware(scraper_handlers.handleResultsContent) },
    .{ .GET, "/scraper/results/competitions", withMiddleware(scraper_handlers.handleResultsCompetitions) },
    .{ .GET, "/scraper/results/teams", withMiddleware(scraper_handlers.handleResultsTeams) },
    .{ .GET, "/scraper/results/matches", withMiddleware(scraper_handlers.handleResultsMatches) },
    .{ .GET, "/scraper/results/players", withMiddleware(scraper_handlers.handleResultsPlayers) },
    .{ .GET, "/scraper/results/injuries", withMiddleware(scraper_handlers.handleResultsInjuries) },
    .{ .GET, "/scraper/reports", withMiddleware(scraper_handlers.handleReports) },
    .{ .GET, "/scraper/reports-content", withMiddleware(scraper_handlers.handleReportsContent) },
    .{ .GET, "/scraper/reports/jobs", withMiddleware(scraper_handlers.handleReportsJobs) },
    .{ .GET, "/scraper/reports/job/:id", withMiddleware(scraper_handlers.handleJobDetail) },
    .{ .GET, "/scraper/recent-jobs", withMiddleware(scraper_handlers.handleRecentJobs) },
    .{ .GET, "/scraper/api/sites", withApiMiddleware(scraper_handlers.handleApiSites) },
    .{ .GET, "/scraper/api/jobs", withApiMiddleware(scraper_handlers.handleApiJobs) },
    .{ .GET, "/scraper/api/progress", withApiMiddleware(scraper_handlers.handleApiProgress) },
});

/// Module-level pointer to server stats (set once during startup).
/// Used by the `/metrics` handler to read atomic counters.
var server_stats: ?*http.Server.Stats = null;

/// Module-level pointer to the database (set once during startup).
/// Used by `/api/users` handlers. Null if `--no-db` flag is passed.
var global_db: ?*db.Database = null;

/// Module-level static file config (set once during startup).
/// Used by handleIndex to serve index.html from the correct directory.
/// Null if `--no-static` flag is passed.
var global_static_config: ?http.Static.Config = null;

/// HTTP server entry point — parses CLI flags, starts the server, and blocks.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();

    // ---- Parse command line arguments ----
    var port: u16 = 8080;
    var no_db = false;
    var db_host: []const u8 = "127.0.0.1";
    var db_port: u16 = 5432;
    var static_dir: []const u8 = "public";
    var no_static = false;
    var idle_timeout_s: u32 = 30;
    var request_timeout_s: u32 = 10;
    var backlog: u31 = 128;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-db")) {
            no_db = true;
        } else if (std.mem.eql(u8, args[i], "--no-static")) {
            no_static = true;
        } else if (std.mem.eql(u8, args[i], "--static-dir") and i + 1 < args.len) {
            static_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--db-host") and i + 1 < args.len) {
            db_host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--db-port") and i + 1 < args.len) {
            db_port = std.fmt.parseInt(u16, args[i + 1], 10) catch 5432;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--idle-timeout") and i + 1 < args.len) {
            idle_timeout_s = std.fmt.parseInt(u32, args[i + 1], 10) catch 30;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--request-timeout") and i + 1 < args.len) {
            request_timeout_s = std.fmt.parseInt(u32, args[i + 1], 10) catch 10;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--backlog") and i + 1 < args.len) {
            backlog = std.fmt.parseInt(u31, args[i + 1], 10) catch 128;
            i += 1;
        }
    }

    // ---- Initialize database (unless --no-db) ----
    var database: ?db.Database = null;
    if (!no_db) {
        database = db.Database.init(init.gpa, io, .{
            .host = db_host,
            .port = db_port,
        }) catch |err| blk: {
            std.debug.print("Warning: Database connection failed: {}. Running without DB.\n", .{err});
            std.debug.print("  Start PostgreSQL: cd docker && docker compose up -d\n", .{});
            std.debug.print("  Or run with --no-db to suppress this warning.\n\n", .{});
            break :blk null;
        };
        if (database != null) {
            global_db = &database.?;
            // Share DB reference with football scraper feature
            scraper_handlers.setDatabase(&database.?);
        }
    }

    // ---- Start server ----
    const db_status: []const u8 = if (database != null) "connected" else "disabled";
    const static_status: []const u8 = if (no_static) "disabled" else static_dir;
    std.debug.print(
        \\
        \\  +--------------------------------------------+
        \\  |   Zig HTTP/1 Server                        |
        \\  |   Listening on http://127.0.0.1:{d:<5}      |
        \\  |   Async I/O pool (auto-scaled)             |
        \\  |   Database: {s:<20}          |
        \\  |   Static:   {s:<20}          |
        \\  |   Press Ctrl+C to stop                     |
        \\  +--------------------------------------------+
        \\
        \\
    , .{ port, db_status, static_status });

    const static_config: ?http.Static.Config = if (no_static) null else .{
        .root_dir = static_dir,
    };

    var server = try http.Server.start(init.gpa, io, .{
        .port = port,
        .router = &router,
        .reuse_address = true,
        .backlog = backlog,
        .idle_timeout_s = idle_timeout_s,
        .request_timeout_s = request_timeout_s,
        .static_config = static_config,
    });
    defer server.deinit(io);
    defer if (database != null) {
        database.?.deinit();
        global_db = null;
    };
    server_stats = &server.stats;
    global_static_config = static_config;

    // Run the accept loop — returns when shutdown is requested.
    // On graceful shutdown, run() returns error.Canceled.
    server.run(io) catch |err| switch (err) {
        error.Canceled => {
            std.debug.print("\nServer shutting down gracefully...\n", .{});
        },
    };
}

// ============================================================================
// Request Handlers
// ============================================================================

/// GET / — Serve the static index.html dashboard page.
/// Uses the global static config (respects --static-dir CLI flag).
fn handleIndex(_: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    if (global_static_config) |sc| {
        if (response.sendStaticFile(sc, "/index.html", io)) return;
    }
    try response.sendText(.not_found, "index.html not found");
}

/// GET /health — Health check endpoint
fn handleHealth(_: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    try response.sendJson(.ok, "{\"status\":\"ok\"}");
}

/// GET /hello/:name — Parameterized greeting
fn handleHello(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const name = request.pathParam("name") orelse "world";
    // Allocate on the request arena — freed automatically when request ends.
    const body = try std.fmt.allocPrint(request.arena, "Hello, {s}!\n", .{name});
    try response.sendText(.ok, body);
}

/// POST /echo — Echo the request method and path
fn handleEcho(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const body = try std.fmt.allocPrint(
        request.arena,
        "Method: {s}\nPath: {s}\nQuery: {s}\n",
        .{ @tagName(request.method), request.path, request.raw_query orelse "(none)" },
    );
    try response.sendText(.ok, body);
}

/// GET /search?q=hello+world&page=1&limit=10 — Query parameter demo.
///
/// Demonstrates the query parameter API:
///   - `queryParam("key")` for single-value lookup (lazy-parsed, cached)
///   - Values are automatically percent-decoded (`%20` → space, `+` → space)
///   - Returns null for missing parameters (use `orelse` for defaults)
///   - All allocations use the per-request arena (freed in bulk)
fn handleSearch(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const query = request.queryParam("q") orelse "";
    const page = request.queryParam("page") orelse "1";
    const limit = request.queryParam("limit") orelse "20";

    const body = try std.fmt.allocPrint(
        request.arena,
        \\{{"query":"{s}","page":{s},"limit":{s},"path":"{s}"}}
    ,
        .{ query, page, limit, request.path },
    );
    try response.sendJson(.ok, body);
}

/// POST /api/echo-json — Parse JSON body and echo it back as typed JSON.
///
/// Demonstrates the full JSON round-trip:
///   1. Client sends: {"name": "Alice", "age": 30}
///   2. Server parses into `EchoPayload` struct (zero-copy strings)
///   3. Server builds response struct and serializes back to JSON
///   4. Client receives: {"received_name": "Alice", "received_age": 30, "echoed": true}
///
/// All allocations go through the per-request arena — freed in one
/// O(1) bulk reset when the request completes.
fn handleEchoJson(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const EchoPayload = struct {
        name: []const u8,
        age: ?u32 = null,
    };

    // Set body from content-length for JSON parsing.
    // In a full implementation, readBody() would read from the stream.
    // Here we parse whatever body is already available.
    const payload = request.jsonBody(EchoPayload) catch {
        try response.sendText(.bad_request, "Invalid JSON body. Expected: {\"name\": \"...\", \"age\": 30}");
        return;
    };

    // Build typed response and serialize.
    const result = .{
        .received_name = payload.name,
        .received_age = payload.age,
        .echoed = true,
    };
    try response.sendJsonValue(.ok, result);
}

// ============================================================================
// Structured Concurrency Demo (11b-5)
// ============================================================================

/// Simulated async data fetch — represents a database or API call.
/// Runs as a concurrent task via io.async().
fn fetchProfile(io: std.Io, user_id: []const u8, arena: std.mem.Allocator) anyerror![]const u8 {
    // Simulate network latency
    io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    return try std.fmt.allocPrint(arena, "User({s})", .{user_id});
}

/// Simulated async notification count fetch.
fn fetchNotifications(io: std.Io, user_id: []const u8, arena: std.mem.Allocator) anyerror![]const u8 {
    // Simulate network latency
    io.sleep(std.Io.Duration.fromMilliseconds(3), .awake) catch {};
    return try std.fmt.allocPrint(arena, "notifications({s})=7", .{user_id});
}

/// GET /dashboard/:id — Fan-out concurrency demo.
///
/// Demonstrates the structured concurrency pattern:
///   1. Spawn two concurrent sub-tasks (fetchProfile + fetchNotifications)
///   2. Await both results (fan-in)
///   3. Combine and respond
///
/// This is the Zig equivalent of Kotlin's:
///   coroutineScope {
///       val profile = async { fetchProfile(userId) }
///       val notifs  = async { fetchNotifications(userId) }
///       render(profile.await(), notifs.await())
///   }
///
/// Both sub-tasks are bounded by this handler's lifetime. If the handler
/// is canceled (request timeout or shutdown), sub-task futures are
/// automatically cleaned up via `.cancel()`.
fn handleDashboard(request: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    const user_id = request.pathParam("id") orelse "anonymous";

    // Fan-out: spawn two concurrent sub-tasks.
    var profile_future = io.async(fetchProfile, .{ io, user_id, request.arena });
    var notifs_future = io.async(fetchNotifications, .{ io, user_id, request.arena });

    // Fan-in: await both results. Order doesn't matter — both run concurrently.
    // If either task errors, we still cancel the other to avoid leaking.
    const profile = profile_future.await(io) catch |err| {
        if (notifs_future.cancel(io)) |_| {} else |_| {}
        return err;
    };
    const notifs = notifs_future.await(io) catch |err| {
        return err;
    };

    const body = try std.fmt.allocPrint(
        request.arena,
        "Dashboard for {s}\n  Profile: {s}\n  {s}\n",
        .{ user_id, profile, notifs },
    );
    try response.sendText(.ok, body);
}

// ============================================================================
// Metrics Endpoint (11b-6)
// ============================================================================

/// GET /metrics — Server statistics as JSON.
///
/// Reads atomic counters from the server's Stats struct.
/// Safe to call from any fiber — all counters use relaxed atomics.
fn handleMetrics(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const stats = server_stats orelse {
        try response.sendText(.service_unavailable, "Stats not available");
        return;
    };

    const active = stats.active_connections.load(.monotonic);
    const total_req = stats.total_requests.load(.monotonic);
    const total_conn = stats.total_connections.load(.monotonic);

    const body = try std.fmt.allocPrint(
        request.arena,
        \\{{"active_connections":{d},"total_requests":{d},"total_connections":{d}}}
    ,
        .{ active, total_req, total_conn },
    );

    try response.sendJson(.ok, body);
}

// ============================================================================
// REST API: Users (Step 13 — PostgreSQL)
// ============================================================================

/// Helper: get user repository from the global database, or send 503.
fn getUserRepo(response: *http.Response) ?db.UserRepository {
    const database = global_db orelse {
        response.sendText(.service_unavailable, "Database not connected. Start PostgreSQL: cd docker && docker compose up -d") catch {};
        return null;
    };
    return db.UserRepository.init(database);
}

/// Helper: parse `:id` path parameter as i32, or send 400.
fn parseUserId(request: *http.Request, response: *http.Response) ?i32 {
    const id_str = request.pathParam("id") orelse {
        response.sendText(.bad_request, "Missing user ID") catch {};
        return null;
    };
    return std.fmt.parseInt(i32, id_str, 10) catch {
        response.sendJsonValue(.bad_request, .{ .@"error" = "Invalid user ID — must be an integer" }) catch {};
        return null;
    };
}

/// GET /api/users — List all users as a JSON array.
///
/// Queries all users from PostgreSQL, maps each row to a User struct
/// using pg.zig's `row.to()`, collects into an ArrayList, and serializes.
/// All allocations go through the per-request arena.
fn handleListUsers(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    var repo = getUserRepo(response) orelse return;
    var result = try repo.getAll();
    defer result.deinit();

    var users: std.ArrayList(db.UserRepository.User) = .empty;
    while (try result.next()) |row| {
        try users.append(request.arena, try row.to(db.UserRepository.User, .{ .allocator = request.arena }));
    }
    try response.sendJsonValue(.ok, users.items);
}

/// GET /api/users/:id — Get a single user by ID.
///
/// Returns 404 if the user doesn't exist.
fn handleGetUser(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    var repo = getUserRepo(response) orelse return;
    const id = parseUserId(request, response) orelse return;

    if (try repo.getById(id, request.arena)) |user| {
        try response.sendJsonValue(.ok, user);
    } else {
        try response.sendJsonValue(.not_found, .{ .@"error" = "User not found" });
    }
}

/// POST /api/users — Create a new user from JSON body.
///
/// Expects: {"name": "...", "email": "...", "age": 30}
/// Returns: 201 Created with the new user (including generated ID).
fn handleCreateUser(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    var repo = getUserRepo(response) orelse return;

    const input = request.jsonBody(db.UserRepository.CreateUserInput) catch {
        try response.sendJsonValue(.bad_request, .{
            .@"error" = "Invalid JSON body. Expected: {\"name\": \"...\", \"email\": \"...\", \"age\": 30}",
        });
        return;
    };

    if (try repo.create(input, request.arena)) |user| {
        try response.sendJsonValue(.created, user);
    } else {
        try response.sendJsonValue(.internal_server_error, .{ .@"error" = "Failed to create user" });
    }
}

/// PUT /api/users/:id — Update an existing user.
///
/// Expects: {"name": "...", "email": "...", "age": 30}
/// Returns: 200 OK with the updated user, or 404 if not found.
fn handleUpdateUser(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    var repo = getUserRepo(response) orelse return;
    const id = parseUserId(request, response) orelse return;

    const input = request.jsonBody(db.UserRepository.CreateUserInput) catch {
        try response.sendJsonValue(.bad_request, .{
            .@"error" = "Invalid JSON body. Expected: {\"name\": \"...\", \"email\": \"...\", \"age\": 30}",
        });
        return;
    };

    if (try repo.update(id, input, request.arena)) |user| {
        try response.sendJsonValue(.ok, user);
    } else {
        try response.sendJsonValue(.not_found, .{ .@"error" = "User not found" });
    }
}

/// DELETE /api/users/:id — Delete a user by ID.
///
/// Returns: 200 OK with confirmation, or 404 if not found.
fn handleDeleteUser(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    var repo = getUserRepo(response) orelse return;
    const id = parseUserId(request, response) orelse return;

    if (try repo.delete(id)) {
        try response.sendJsonValue(.ok, .{ .deleted = true });
    } else {
        try response.sendJsonValue(.not_found, .{ .@"error" = "User not found" });
    }
}

// ============================================================================
// htmx + Comptime Template Demo (Step 17)
// ============================================================================

/// Atomic click counter for the htmx demo.
var htmx_counter = std.atomic.Value(u32).init(0);

// ---- Comptime Templates (parsed at compile time, zero runtime overhead) ----

/// Template: server time fragment (polled every 2s by htmx).
const time_template = html.Template.compile(
    \\<span>{{time}}</span>
);

/// Template: click counter value fragment.
const counter_template = html.Template.compile(
    \\{{count}}
);

/// Template: user table rows rendered via {{#each}}.
const user_rows_template = html.Template.compile(
    \\{{#each users}}<tr class="fade-in">
    \\  <td>{{name}}</td>
    \\  <td>{{email}}</td>
    \\  <td>{{#if active}}<span class="badge">Active</span>{{else}}<span class="badge badge-inactive">Inactive</span>{{/if}}</td>
    \\</tr>
    \\{{/each}}
);

/// Template: search result rows.
const search_results_template = html.Template.compile(
    \\{{#if has_query}}{{#if has_results}}<table style="width:100%">
    \\  {{#each results}}<tr class="fade-in"><td>{{name}}</td><td>{{email}}</td></tr>
    \\  {{/each}}</table>{{else}}<p style="color:#666;">No results for "{{query}}"</p>{{/if}}{{/if}}
);

/// Demo user data for the htmx templates.
const DemoUser = struct {
    name: []const u8,
    email: []const u8,
    active: bool,
};

const demo_users = [_]DemoUser{
    .{ .name = "Alice Chen", .email = "alice@example.com", .active = true },
    .{ .name = "Bob Smith", .email = "bob@example.com", .active = true },
    .{ .name = "Carol Wu", .email = "carol@example.com", .active = false },
    .{ .name = "Dave Jones", .email = "dave@example.com", .active = true },
    .{ .name = "Eve Brown", .email = "eve@example.com", .active = false },
};

/// GET /htmx — Serve the htmx demo page.
fn handleHtmxDemo(_: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    if (global_static_config) |sc| {
        if (response.sendStaticFile(sc, "/htmx-demo.html", io)) return;
    }
    try response.sendText(.not_found, "htmx-demo.html not found. Ensure --static-dir points to public/");
}

/// GET /htmx/time — Returns the current server time as an HTML fragment.
/// Polled by htmx every 2 seconds.
fn handleHtmxTime(request: *http.Request, response: *http.Response, io: std.Io) anyerror!void {
    const now = std.Io.Clock.now(.real, io);
    const epoch_secs: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
    const secs: i64 = @mod(epoch_secs, 86400);
    const hours: i64 = @divTrunc(secs, 3600);
    const mins: i64 = @divTrunc(@mod(secs, 3600), 60);
    const s: i64 = @mod(secs, 60);

    const time_str = try std.fmt.allocPrint(
        request.arena,
        "{d:0>2}:{d:0>2}:{d:0>2} UTC",
        .{ hours, mins, s },
    );

    const body = try time_template.render(request.arena, .{ .time = time_str });
    try response.sendHtml(.ok, body);
}

/// POST /htmx/counter — Increment the counter and return the new value.
fn handleHtmxCounter(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const count = htmx_counter.fetchAdd(1, .monotonic) + 1;

    var buf: [12]u8 = undefined;
    const count_str = try std.fmt.bufPrint(&buf, "{d}", .{count});

    const body = try counter_template.render(request.arena, .{ .count = count_str });
    try response.sendHtml(.ok, body);
}

/// GET /htmx/users — Return user table rows as an HTML fragment.
/// Rendered using a comptime template with {{#each}}.
fn handleHtmxUsers(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const body = try user_rows_template.render(request.arena, .{ .users = &demo_users });
    try response.sendHtml(.ok, body);
}

/// GET /htmx/search?q=... — Search users and return results as HTML fragment.
/// Demonstrates comptime templates with htmx live search.
fn handleHtmxSearch(request: *http.Request, response: *http.Response, _: std.Io) anyerror!void {
    const query = request.queryParam("q") orelse "";

    if (query.len == 0) {
        try response.sendHtml(.ok, "");
        return;
    }

    // Filter demo users by name (case-insensitive substring match).
    var matches: [demo_users.len]DemoUser = undefined;
    var match_count: usize = 0;
    for (&demo_users) |user| {
        if (containsIgnoreCase(user.name, query) or containsIgnoreCase(user.email, query)) {
            matches[match_count] = user;
            match_count += 1;
        }
    }

    const body = try search_results_template.render(request.arena, .{
        .has_query = query.len > 0,
        .has_results = match_count > 0,
        .query = query,
        .results = matches[0..match_count],
    });
    try response.sendHtml(.ok, body);
}

/// Case-insensitive substring search.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}
