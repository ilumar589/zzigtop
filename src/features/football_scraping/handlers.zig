//! HTTP route handlers for the football scraper feature.
//!
//! Provides handlers for:
//! - Dashboard page (full page + htmx fragments)
//! - Site management (list, toggle enable/disable)
//! - Scrape control (start job, poll progress)
//! - Results viewing (competitions, teams, matches, players, injuries)
//! - Reports (job history, error details)
//! - JSON API endpoints
//!
//! All handlers follow the standard zzigtop signature:
//!   fn(request, response, io) anyerror!void
//!
//! htmx detection: If `HX-Request: true` header is present, handlers return
//! HTML fragments. Otherwise, they return full pages wrapped in the layout.

const std = @import("std");
const http = @import("../../http/http.zig");
const html = @import("../../html/html.zig");
const db_mod = @import("../../db/db.zig");
const Types = @import("types.zig");
const Sites = @import("sites.zig");
const Scraper = @import("scraper.zig");
const Parser = @import("parser.zig");
const Repository = @import("repository.zig");
const Templates = @import("templates.zig");

const Request = http.Request;
const Response = http.Response;
const Htmx = html.Htmx;
const Io = std.Io;

// ============================================================================
// Module-level State
// ============================================================================

/// Global reference to the database (set during server startup).
/// Null if DB is not available (--no-db mode).
var global_db: ?*db_mod.Database = null;

/// Runtime site enable/disable state.
var site_state = Sites.SiteState.init();

/// Set the global database reference. Called once during server init.
pub fn setDatabase(database: ?*db_mod.Database) void {
    global_db = database;
}

/// Get the site state (for scraper engine).
pub fn getSiteState() *Sites.SiteState {
    return &site_state;
}

// ============================================================================
// Helpers
// ============================================================================

/// Wrap content in the full page layout, or return as-is for htmx requests.
fn wrapInLayout(request: *Request, arena: std.mem.Allocator, title: []const u8, content: []const u8) ![]const u8 {
    if (Htmx.isHtmxRequest(request)) {
        return content;
    }
    return try Templates.page_layout.render(arena, .{
        .title = title,
        .content = content,
    });
}

/// Get a repository instance, or return null if no database is connected.
/// Callers are responsible for sending an appropriate fallback response.
fn getRepo(_: *Response) ?Repository {
    const database = global_db orelse return null;
    return Repository.init(database);
}

/// Format an i32 as a string in the request arena.
fn intToStr(arena: std.mem.Allocator, value: i32) ![]const u8 {
    return try std.fmt.allocPrint(arena, "{d}", .{value});
}

// ============================================================================
// Dashboard Handlers
// ============================================================================

/// GET /scraper — Dashboard page.
pub fn handleDashboard(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    // Get stats (with DB or fallback defaults)
    var stats = Types.DashboardStats{};
    if (global_db) |database| {
        var repo = Repository.init(database);
        stats = repo.getDashboardStats(arena) catch Types.DashboardStats{};
    }

    // Count enabled sites from in-memory state
    var enabled_count: i32 = 0;
    for (site_state.enabled_flags) |f| {
        if (f) enabled_count += 1;
    }
    stats.enabled_sites = enabled_count;

    // Build progress fragment
    const snap = Scraper.progress.snapshot();
    const progress_html = if (snap.status == Scraper.Progress.STATUS_RUNNING)
        try buildProgressHtml(arena, &snap)
    else
        try Templates.progress_idle.render(arena, .{});

    const content = try Templates.dashboard_content.render(arena, .{
        .enabled_sites = try intToStr(arena, stats.enabled_sites),
        .total_jobs = try intToStr(arena, stats.total_jobs),
        .total_competitions = try intToStr(arena, stats.total_competitions),
        .total_teams = try intToStr(arena, stats.total_teams),
        .total_matches = try intToStr(arena, stats.total_matches),
        .total_errors = try intToStr(arena, stats.total_errors),
        .last_scrape = stats.last_scrape_at orelse "Never",
        .progress_html = progress_html,
    });

    const body = try wrapInLayout(request, arena, "Dashboard", content);
    try response.sendHtml(.ok, body);
}

/// GET /scraper/dashboard-content — Dashboard content fragment (htmx).
pub fn handleDashboardContent(request: *Request, response: *Response, io: Io) anyerror!void {
    return handleDashboard(request, response, io);
}

// ============================================================================
// Progress Handlers
// ============================================================================

/// Build the progress HTML fragment from a snapshot.
fn buildProgressHtml(arena: std.mem.Allocator, snap: *const Scraper.ProgressSnapshot) ![]const u8 {
    const status_class = if (snap.isRunning()) "running" else if (snap.isCompleted()) "completed" else if (snap.isFailed()) "failed" else "idle";
    const status_text = if (snap.isRunning()) "Running" else if (snap.isCompleted()) "Completed" else if (snap.isFailed()) "Failed" else "Idle";

    return try Templates.progress_fragment.render(arena, .{
        .is_running = snap.isRunning(),
        .status_class = @as([]const u8, status_class),
        .status_text = @as([]const u8, status_text),
        .completed = try intToStr(arena, snap.completed_sites),
        .total = try intToStr(arena, snap.total_sites),
        .percent = try intToStr(arena, @as(i32, snap.percentComplete())),
        .has_errors = snap.errors_count > 0,
        .errors = try intToStr(arena, snap.errors_count),
    });
}

/// GET /scraper/progress — Polled progress fragment.
pub fn handleProgress(request: *Request, response: *Response, _: Io) anyerror!void {
    const snap = Scraper.progress.snapshot();

    if (snap.status == Scraper.Progress.STATUS_IDLE) {
        const body = try Templates.progress_idle.render(request.arena, .{});
        try response.sendHtml(.ok, body);
        return;
    }

    const body = try buildProgressHtml(request.arena, &snap);
    try response.sendHtml(.ok, body);
}

// ============================================================================
// Scrape Control
// ============================================================================

/// POST /scraper/start — Start a new scrape job.
pub fn handleStartScrape(request: *Request, response: *Response, io: Io) anyerror!void {
    const arena = request.arena;

    std.debug.print("[handler] POST /scraper/start — beginning scrape job\n", .{});

    // Check if a job is already running
    const snap = Scraper.progress.snapshot();
    if (snap.isRunning()) {
        std.debug.print("[handler] Job already running (id={d}), returning current progress\n", .{snap.job_id});
        const body = try buildProgressHtml(arena, &snap);
        try response.sendHtml(.ok, body);
        return;
    }

    // Create DB job BEFORE scraping starts
    var db_job_id: ?i32 = null;
    if (global_db) |database| {
        var repo = Repository.init(database);
        // Count enabled sites
        var enabled: i32 = 0;
        for (site_state.enabled_flags) |f| {
            if (f) enabled += 1;
        }
        if (repo.createJob(enabled, arena)) |maybe_job| {
            if (maybe_job) |job| {
                db_job_id = job.id;
                std.debug.print("[handler] Created DB job id={d}\n", .{job.id});
            }
        } else |err| {
            std.debug.print("[handler] WARNING: failed to create DB job: {}\n", .{err});
        }
    }

    // Run the scrape (synchronous — runs in the handler's fiber)
    std.debug.print("[handler] Starting scrape across enabled sites...\n", .{});
    const results = Scraper.runScrapeJob(arena, io, &site_state) catch |err| {
        std.debug.print("[handler] runScrapeJob FAILED: {}\n", .{err});
        // Mark DB job as failed
        if (db_job_id) |jid| {
            if (global_db) |database| {
                var repo = Repository.init(database);
                repo.completeJob(jid, "failed", null) catch {};
            }
        }
        const body = try buildProgressHtml(arena, &Scraper.progress.snapshot());
        try response.sendHtml(.ok, body);
        return;
    };

    std.debug.print("[handler] Scrape complete: {d} site results\n", .{results.len});

    // Store results in DB if available
    if (global_db) |database| {
        var repo = Repository.init(database);
        // Use pre-created job ID, or create one now as fallback
        var jid = db_job_id;
        if (jid == null) {
            if (repo.createJob(@intCast(results.len), arena)) |maybe_job| {
                if (maybe_job) |job| jid = job.id;
            } else |err| {
                std.debug.print("[handler] WARNING: fallback createJob failed: {}\n", .{err});
            }
        }
        if (jid) |job_id| {
            for (results) |result| {
                std.debug.print("[handler] Storing result: site={s} success={} items={d}\n", .{
                    result.site_id, result.success, result.items_found,
                });
                repo.storeRawScrapeData(.{
                    .job_id = job_id,
                    .site_id = result.site_id,
                    .url = result.url,
                    .extracted_json = result.extracted_json,
                    .status = if (result.success) "success" else "error",
                    .error_message = result.error_message,
                }) catch |err| {
                    std.debug.print("[handler] WARNING: store raw data failed: {}\n", .{err});
                };
            }

            const final_status = if (Scraper.progress.snapshot().isFailed()) "failed" else "completed";
            std.debug.print("[handler] Completing job {d} with status={s}\n", .{ job_id, final_status });
            repo.completeJob(job_id, final_status, null) catch |err| {
                std.debug.print("[handler] WARNING: completeJob failed: {}\n", .{err});
            };
        }
    }

    // Return the final progress state
    const final_snap = Scraper.progress.snapshot();
    const body = try buildProgressHtml(arena, &final_snap);
    try response.sendHtml(.ok, body);
}

// ============================================================================
// Site Management Handlers
// ============================================================================

/// GET /scraper/sites — Site management page.
pub fn handleSites(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    const site_rows_html = try buildSiteRowsHtml(arena);
    const content = try Templates.sites_content.render(arena, .{
        .site_rows_html = site_rows_html,
    });

    const body = try wrapInLayout(request, arena, "Sites", content);
    try response.sendHtml(.ok, body);
}

/// GET /scraper/sites-content — Site content fragment (htmx).
pub fn handleSitesContent(request: *Request, response: *Response, io: Io) anyerror!void {
    return handleSites(request, response, io);
}

/// Build HTML for all site rows.
fn buildSiteRowsHtml(arena: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8){};

    for (Sites.default_sites, 0..) |site, idx| {
        const enabled = site_state.enabled_flags[idx];
        const row_html = try Templates.site_row.render(arena, .{
            .id = site.id,
            .name = site.name,
            .base_url = site.base_url,
            .category = site.category,
            .description = site.description,
            .enabled = enabled,
        });
        try buf.appendSlice(arena, row_html);
    }

    return buf.toOwnedSlice(arena);
}

/// PUT /scraper/api/sites/:id/toggle — Toggle a site's enabled status.
pub fn handleToggleSite(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;
    const site_id = request.pathParam("id") orelse {
        try response.sendText(.bad_request, "Missing site ID");
        return;
    };

    // Toggle the site
    const current = site_state.isEnabled(site_id);
    if (!site_state.setEnabled(site_id, !current)) {
        try response.sendText(.not_found, "Site not found");
        return;
    }

    // Return the updated row
    if (Sites.getSiteById(site_id)) |site| {
        const row_html = try Templates.site_row.render(arena, .{
            .id = site.id,
            .name = site.name,
            .base_url = site.base_url,
            .category = site.category,
            .description = site.description,
            .enabled = !current,
        });
        try response.sendHtml(.ok, row_html);
    } else {
        try response.sendText(.not_found, "Site not found");
    }
}

// ============================================================================
// Results Handlers
// ============================================================================

/// GET /scraper/results — Results page.
pub fn handleResults(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;
    const content = try Templates.results_content.render(arena, .{});
    const body = try wrapInLayout(request, arena, "Results", content);
    try response.sendHtml(.ok, body);
}

/// GET /scraper/results-content — Results content fragment (htmx).
pub fn handleResultsContent(request: *Request, response: *Response, io: Io) anyerror!void {
    return handleResults(request, response, io);
}

/// GET /scraper/results/competitions — Competitions data table.
pub fn handleResultsCompetitions(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    if (getRepo(response)) |repo_val| {
        var repo = repo_val;
        const comps = repo.getAllCompetitions(arena) catch &.{};

        // Render using a simplified approach — build JSON-like data
        const body = try Templates.competitions_table.render(arena, .{
            .competitions = comps,
            .empty = comps.len == 0,
        });
        try response.sendHtml(.ok, body);
    } else {
        try response.sendHtml(.ok, "<p class=\"empty-state\">Database not available.</p>");
    }
}

/// GET /scraper/results/teams — Teams data table.
pub fn handleResultsTeams(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    if (getRepo(response)) |repo_val| {
        var repo = repo_val;
        const teams = repo.getAllTeams(arena) catch &.{};
        const body = try Templates.teams_table.render(arena, .{
            .teams = teams,
            .empty = teams.len == 0,
        });
        try response.sendHtml(.ok, body);
    } else {
        try response.sendHtml(.ok, "<p class=\"empty-state\">Database not available.</p>");
    }
}

/// GET /scraper/results/matches — Matches data table.
pub fn handleResultsMatches(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    if (getRepo(response)) |repo_val| {
        var repo = repo_val;
        const matches = repo.getRecentMatches(50, arena) catch &.{};
        const body = try Templates.matches_table.render(arena, .{
            .matches = matches,
            .empty = matches.len == 0,
        });
        try response.sendHtml(.ok, body);
    } else {
        try response.sendHtml(.ok, "<p class=\"empty-state\">Database not available.</p>");
    }
}

/// GET /scraper/results/players — Players data table.
pub fn handleResultsPlayers(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    if (getRepo(response)) |repo_val| {
        var repo = repo_val;
        const players = repo.getAllPlayers(arena) catch &.{};
        const body = try Templates.players_table.render(arena, .{
            .players = players,
            .empty = players.len == 0,
        });
        try response.sendHtml(.ok, body);
    } else {
        try response.sendHtml(.ok, "<p class=\"empty-state\">Database not available.</p>");
    }
}

/// GET /scraper/results/injuries — Injuries data table.
pub fn handleResultsInjuries(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    if (getRepo(response)) |repo_val| {
        var repo = repo_val;
        const injuries = repo.getAllInjuries(arena) catch &.{};
        const body = try Templates.injuries_table.render(arena, .{
            .injuries = injuries,
            .empty = injuries.len == 0,
        });
        try response.sendHtml(.ok, body);
    } else {
        try response.sendHtml(.ok, "<p class=\"empty-state\">Database not available.</p>");
    }
}

// ============================================================================
// Reports Handlers
// ============================================================================

/// GET /scraper/reports — Reports page.
pub fn handleReports(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;
    const content = try Templates.reports_content.render(arena, .{});
    const body = try wrapInLayout(request, arena, "Reports", content);
    try response.sendHtml(.ok, body);
}

/// GET /scraper/reports-content — Reports content fragment (htmx).
pub fn handleReportsContent(request: *Request, response: *Response, io: Io) anyerror!void {
    return handleReports(request, response, io);
}

/// GET /scraper/reports/jobs — Job history table fragment.
pub fn handleReportsJobs(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    if (getRepo(response)) |repo_val| {
        var repo = repo_val;
        const jobs = repo.getRecentJobs(20, arena) catch &.{};
        const body = try Templates.jobs_table.render(arena, .{
            .jobs = jobs,
            .empty = jobs.len == 0,
        });
        try response.sendHtml(.ok, body);
    } else {
        try response.sendHtml(.ok, "<p class=\"empty-state\">Database not available.</p>");
    }
}

/// GET /scraper/recent-jobs — Mini job list for dashboard.
pub fn handleRecentJobs(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    if (getRepo(response)) |repo_val| {
        var repo = repo_val;
        const jobs = repo.getRecentJobs(5, arena) catch &.{};
        const body = try Templates.recent_jobs_fragment.render(arena, .{
            .has_jobs = jobs.len > 0,
            .jobs = jobs,
        });
        try response.sendHtml(.ok, body);
    } else {
        try response.sendHtml(.ok, "<p class=\"empty-state\">Database not available.</p>");
    }
}

/// GET /scraper/reports/job/:id — Job detail fragment (errors + raw data).
pub fn handleJobDetail(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    const id_str = request.pathParam("id") orelse {
        try response.sendText(.bad_request, "Missing job ID");
        return;
    };
    const job_id = std.fmt.parseInt(i32, id_str, 10) catch {
        try response.sendText(.bad_request, "Invalid job ID");
        return;
    };

    if (getRepo(response)) |repo_val| {
        var repo = repo_val;

        // Get the job itself
        const job = repo.getJob(job_id, arena) catch null;
        const job_status = if (job) |j| j.status else "unknown";
        const job_total = if (job) |j| j.total_sites else 0;
        const job_completed = if (job) |j| j.completed_sites else 0;
        const job_errors = if (job) |j| j.errors_count else 0;

        // Get errors for this job
        const errs = repo.getJobErrors(job_id, arena) catch &.{};

        const body = try Templates.job_detail_fragment.render(arena, .{
            .job_id = try intToStr(arena, job_id),
            .status = job_status,
            .total_sites = try intToStr(arena, job_total),
            .completed_sites = try intToStr(arena, job_completed),
            .errors_count = try intToStr(arena, job_errors),
            .has_errors = errs.len > 0,
            .errors = errs,
        });
        try response.sendHtml(.ok, body);
    } else {
        try response.sendHtml(.ok, "<p class=\"empty-state\">Database not available.</p>");
    }
}

// ============================================================================
// JSON API Handlers
// ============================================================================

/// GET /scraper/api/sites — List all sites as JSON.
pub fn handleApiSites(request: *Request, response: *Response, _: Io) anyerror!void {
    const arena = request.arena;

    // Build site list with enabled status
    const SiteInfo = struct {
        id: []const u8,
        name: []const u8,
        base_url: []const u8,
        enabled: bool,
        category: []const u8,
    };

    var sites_list: [Sites.default_sites.len]SiteInfo = undefined;
    for (Sites.default_sites, 0..) |site, idx| {
        sites_list[idx] = .{
            .id = site.id,
            .name = site.name,
            .base_url = site.base_url,
            .enabled = site_state.enabled_flags[idx],
            .category = site.category,
        };
    }

    _ = arena;
    try response.sendJsonValue(.ok, sites_list[0..Sites.default_sites.len]);
}

/// GET /scraper/api/jobs — List recent jobs as JSON.
pub fn handleApiJobs(request: *Request, response: *Response, _: Io) anyerror!void {
    const snap = Scraper.progress.snapshot();
    _ = request;
    try response.sendJsonValue(.ok, .{
        .current_job_id = snap.job_id,
        .status = @as(u8, snap.status),
        .total_sites = snap.total_sites,
        .completed_sites = snap.completed_sites,
        .errors_count = snap.errors_count,
        .percent_complete = @as(u8, snap.percentComplete()),
    });
}

/// GET /scraper/api/progress — Current job progress as JSON.
pub fn handleApiProgress(_: *Request, response: *Response, _: Io) anyerror!void {
    const snap = Scraper.progress.snapshot();
    try response.sendJsonValue(.ok, .{
        .job_id = snap.job_id,
        .status = @as(u8, snap.status),
        .total_sites = snap.total_sites,
        .completed_sites = snap.completed_sites,
        .errors_count = snap.errors_count,
        .percent_complete = @as(u8, snap.percentComplete()),
        .is_running = snap.isRunning(),
        .is_completed = snap.isCompleted(),
    });
}
