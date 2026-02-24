//! HTTP scraping engine with job lifecycle management.
//!
//! Manages the scrape pipeline:
//!   1. Create a job → status=pending
//!   2. For each enabled site: fetch HTML via std.http.Client, extract data, store raw JSON
//!   3. Update job progress atomically (for htmx polling)
//!   4. Finalize job → status=completed/failed
//!
//! The scraper runs fetches through the Zig Io runtime for non-blocking I/O.
//! Progress is tracked via atomic counters readable from any handler fiber.

const std = @import("std");
const Types = @import("types.zig");
const Sites = @import("sites.zig");
const Parser = @import("parser.zig");
const Io = std.Io;

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[scraper] " ++ fmt ++ "\n", args);
}

// ============================================================================
// Job Progress (atomic, readable from htmx polling handlers)
// ============================================================================

/// Atomic progress state for the currently running scrape job.
/// Readable from any fiber/thread without locks.
pub const Progress = struct {
    /// Current job ID (0 = no job running).
    job_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    /// Job status: 0=idle, 1=running, 2=completed, 3=failed.
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Total sites to scrape in this job.
    total_sites: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    /// Sites completed so far.
    completed_sites: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    /// Errors encountered so far.
    errors_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    /// Index of the site currently being scraped.
    current_site_index: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    pub const STATUS_IDLE = 0;
    pub const STATUS_RUNNING = 1;
    pub const STATUS_COMPLETED = 2;
    pub const STATUS_FAILED = 3;

    /// Reset progress for a new job.
    pub fn reset(self: *Progress, job_id: i32, total: i32) void {
        self.job_id.store(job_id, .monotonic);
        self.total_sites.store(total, .monotonic);
        self.completed_sites.store(0, .monotonic);
        self.errors_count.store(0, .monotonic);
        self.current_site_index.store(0, .monotonic);
        self.status.store(STATUS_RUNNING, .monotonic);
    }

    /// Mark one site as completed.
    pub fn siteCompleted(self: *Progress) void {
        _ = self.completed_sites.fetchAdd(1, .monotonic);
    }

    /// Record an error.
    pub fn siteError(self: *Progress) void {
        _ = self.errors_count.fetchAdd(1, .monotonic);
        _ = self.completed_sites.fetchAdd(1, .monotonic);
    }

    /// Advance to next site index.
    pub fn advanceSite(self: *Progress) void {
        _ = self.current_site_index.fetchAdd(1, .monotonic);
    }

    /// Mark job as completed.
    pub fn complete(self: *Progress) void {
        self.status.store(STATUS_COMPLETED, .monotonic);
    }

    /// Mark job as failed.
    pub fn fail(self: *Progress) void {
        self.status.store(STATUS_FAILED, .monotonic);
    }

    /// Get a snapshot of current progress (for JSON/template rendering).
    pub fn snapshot(self: *const Progress) ProgressSnapshot {
        return .{
            .job_id = self.job_id.load(.monotonic),
            .status = self.status.load(.monotonic),
            .total_sites = self.total_sites.load(.monotonic),
            .completed_sites = self.completed_sites.load(.monotonic),
            .errors_count = self.errors_count.load(.monotonic),
            .current_site_index = self.current_site_index.load(.monotonic),
        };
    }
};

/// Non-atomic snapshot of progress (safe to pass to templates).
pub const ProgressSnapshot = struct {
    job_id: i32 = 0,
    status: u8 = 0,
    total_sites: i32 = 0,
    completed_sites: i32 = 0,
    errors_count: i32 = 0,
    current_site_index: i32 = -1,

    pub fn isRunning(self: *const ProgressSnapshot) bool {
        return self.status == Progress.STATUS_RUNNING;
    }

    pub fn isCompleted(self: *const ProgressSnapshot) bool {
        return self.status == Progress.STATUS_COMPLETED;
    }

    pub fn isFailed(self: *const ProgressSnapshot) bool {
        return self.status == Progress.STATUS_FAILED;
    }

    pub fn percentComplete(self: *const ProgressSnapshot) u8 {
        if (self.total_sites == 0) return 0;
        const pct = @divTrunc(self.completed_sites * 100, self.total_sites);
        return @intCast(@min(pct, 100));
    }
};

/// Global scraper progress — readable from any handler.
pub var progress = Progress{};

// ============================================================================
// Scrape Result (per-site)
// ============================================================================

/// Result of scraping one site/endpoint.
pub const ScrapeResult = struct {
    site_id: []const u8,
    url: []const u8,
    success: bool,
    extracted_json: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    items_found: usize = 0,
};

// ============================================================================
// Scraper Engine
// ============================================================================

/// Maximum response body size (2 MB).
const MAX_BODY_SIZE: usize = 2 * 1024 * 1024;

/// Browser-like User-Agent to avoid bot detection.
const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

/// Fetch HTML content from a URL using `std.http.Client`.
/// Returns the response body as an arena-allocated string.
///
/// Uses the Zig Io runtime for async-capable, non-blocking HTTP.
/// Follows up to 3 redirects, limits body to 2 MB, and sets a
/// browser User-Agent header.
pub fn fetchUrl(allocator: std.mem.Allocator, io: Io, url: []const u8) ![]const u8 {
    log("  GET {s}", .{url});

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch |err| {
        log("  ERROR: invalid URI: {}", .{err});
        return err;
    };

    const redirect_buf = try allocator.alloc(u8, 8192);
    defer allocator.free(redirect_buf);

    var req = client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = USER_AGENT },
            .accept_encoding = .{ .override = "identity" },
        },
        .redirect_behavior = @enumFromInt(@as(u16, 3)),
    }) catch |err| {
        log("  ERROR: request open failed: {}", .{err});
        return err;
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        log("  ERROR: send failed: {}", .{err});
        return err;
    };

    var response = req.receiveHead(redirect_buf) catch |err| {
        log("  ERROR: receive head failed: {}", .{err});
        return err;
    };

    const status = response.head.status;
    log("  STATUS: {d} {s}", .{ @intFromEnum(status), @tagName(status) });

    if (status != .ok and status != .not_modified) {
        // Drain body so the connection can be reused/closed cleanly
        var body_reader = response.reader(&.{});
        _ = body_reader.discardRemaining() catch {};
        return error.HttpError;
    }

    // Read entire body into allocated buffer
    var body_reader = response.reader(&.{});
    const body = body_reader.allocRemaining(allocator, Io.Limit.limited(MAX_BODY_SIZE)) catch |err| {
        log("  ERROR: body read failed: {}", .{err});
        return err;
    };

    log("  OK: {d} bytes", .{body.len});
    return body;
}

/// Per-site extraction strategies — maps site IDs to HTML patterns
/// that are known to contain useful data on that site.
const SitePattern = struct {
    /// CSS-like open tag pattern (literal HTML substring).
    open: []const u8,
    /// Closing tag/text pattern.
    close: []const u8,
    /// Human label for logging.
    label: []const u8,
};

/// Get extraction patterns for a given site. Falls back to generic
/// patterns (table cells, headings) when the site has no specific config.
fn patternsForSite(site_id: []const u8) []const SitePattern {
    // Site-specific extraction patterns (most to least specific)
    const worldfootball_patterns = [_]SitePattern{
        .{ .open = "<td class=\"hell\"", .close = "</td>", .label = "table-cell" },
        .{ .open = "<td class=\"dunkel\"", .close = "</td>", .label = "table-cell-alt" },
        .{ .open = "<td>", .close = "</td>", .label = "td" },
    };
    const fbref_patterns = [_]SitePattern{
        .{ .open = "<td data-stat=\"", .close = "</td>", .label = "stat-cell" },
        .{ .open = "<th data-stat=\"", .close = "</th>", .label = "stat-header" },
    };
    const espn_patterns = [_]SitePattern{
        .{ .open = "<span class=\"Table__Team\">", .close = "</span>", .label = "team" },
        .{ .open = "<td class=\"Table__TD\">", .close = "</td>", .label = "table-cell" },
    };
    const bbc_patterns = [_]SitePattern{
        .{ .open = "<span class=\"gs-u-display-none gs-u-display-block@m qa-full-team-name sp-c-fixture__team-name--time\">", .close = "</span>", .label = "team" },
        .{ .open = "<span class=\"sp-c-fixture__number", .close = "</span>", .label = "score" },
    };

    if (std.mem.eql(u8, site_id, "worldfootball")) return &worldfootball_patterns;
    if (std.mem.eql(u8, site_id, "fbref")) return &fbref_patterns;
    if (std.mem.eql(u8, site_id, "espn_fc")) return &espn_patterns;
    if (std.mem.eql(u8, site_id, "bbc_sport")) return &bbc_patterns;

    // Generic fallback — extract table cells and headings
    const generic = [_]SitePattern{
        .{ .open = "<td>", .close = "</td>", .label = "td" },
        .{ .open = "<td ", .close = "</td>", .label = "td-attr" },
        .{ .open = "<th>", .close = "</th>", .label = "th" },
        .{ .open = "<h2>", .close = "</h2>", .label = "h2" },
        .{ .open = "<h3>", .close = "</h3>", .label = "h3" },
    };
    return &generic;
}

/// Run a scrape operation for a single site.
/// Fetches each endpoint, extracts data, and returns a combined result.
pub fn scrapeSite(
    allocator: std.mem.Allocator,
    io: Io,
    site: *const Sites.Site,
) !ScrapeResult {
    log("Scraping site: {s} ({s})", .{ site.name, site.id });

    // Build the URL for the first endpoint (or base URL)
    const full_url = if (site.endpoints.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ site.base_url, site.endpoints[0].path })
    else
        try std.fmt.allocPrint(allocator, "{s}", .{site.base_url});

    const html_content = fetchUrl(allocator, io, full_url) catch |err| {
        log("  FAILED: {s} — {}", .{ site.name, err });
        return .{
            .site_id = site.id,
            .url = full_url,
            .success = false,
            .error_message = try std.fmt.allocPrint(allocator, "Fetch failed: {}", .{err}),
        };
    };

    log("  Fetched {d} bytes from {s}", .{ html_content.len, site.name });

    // Try JSON-LD extraction first (structured data many sites emit)
    const json_ld = Parser.extractJsonLd(allocator, html_content) catch &.{};
    if (json_ld.len > 0) {
        log("  Found {d} JSON-LD blocks", .{json_ld.len});
    }

    // Run site-specific patterns
    const patterns = patternsForSite(site.id);
    var total_items: usize = 0;
    var all_items = std.ArrayList([]const u8){};
    defer {
        if (all_items.items.len > 0) allocator.free(all_items.items);
    }

    for (patterns) |pattern| {
        const tag_open = if (std.mem.endsWith(u8, pattern.open, ">"))
            pattern.open
        else blk: {
            // Pattern like `<td class="x"` — need to find the closing > first, content follows
            break :blk pattern.open;
        };
        _ = tag_open;

        const elements = Parser.extractAllTagContents(
            allocator,
            html_content,
            pattern.open,
            pattern.close,
        ) catch continue;

        if (elements.len > 0) {
            log("  Pattern [{s}]: {d} matches", .{ pattern.label, elements.len });
            total_items += elements.len;
            // Keep first 50 items max per pattern for the JSON summary
            const limit = @min(elements.len, 50);
            for (elements[0..limit]) |elem| {
                all_items.append(allocator, elem) catch break;
            }
            if (elements.len > 50) {
                allocator.free(elements);
            }
        }
    }

    log("  Total items extracted: {d} from {s}", .{ total_items, site.name });

    // Combine JSON-LD + pattern items into extracted JSON
    var combined = std.ArrayList([]const u8){};
    for (json_ld) |jl| {
        combined.append(allocator, jl) catch {};
    }
    for (all_items.items) |item| {
        combined.append(allocator, item) catch {};
    }
    const combined_slice = combined.toOwnedSlice(allocator) catch &.{};

    const extracted_json = Parser.buildExtractedJson(
        allocator,
        site.id,
        site.category,
        total_items + json_ld.len,
        combined_slice,
    ) catch null;

    return .{
        .site_id = site.id,
        .url = full_url,
        .success = true,
        .extracted_json = extracted_json,
        .items_found = total_items + json_ld.len,
    };
}

/// Run a full scrape job across all enabled sites.
/// Updates the global `progress` atomically for htmx polling.
///
/// Returns a list of per-site results.
pub fn runScrapeJob(
    allocator: std.mem.Allocator,
    io: Io,
    site_state: *const Sites.SiteState,
) ![]ScrapeResult {
    log("=== Starting scrape job ===", .{});

    // Count enabled sites
    var enabled_count: i32 = 0;
    for (Sites.default_sites, 0..) |_, idx| {
        if (site_state.enabled_flags[idx]) enabled_count += 1;
    }
    log("Enabled sites: {d}/{d}", .{ enabled_count, Sites.default_sites.len });

    // Initialize progress
    const job_id: i32 = progress.job_id.load(.monotonic) + 1;
    progress.reset(job_id, enabled_count);

    var results = std.ArrayList(ScrapeResult){};

    // Scrape each enabled site
    for (&Sites.default_sites, 0..) |*site, idx| {
        if (!site_state.enabled_flags[idx]) continue;

        progress.advanceSite();
        log("--- Site {d}/{d}: {s} ---", .{ progress.completed_sites.load(.monotonic) + 1, enabled_count, site.name });

        const result = scrapeSite(allocator, io, site) catch |err| {
            log("  FATAL error scraping {s}: {}", .{ site.name, err });
            progress.siteError();
            try results.append(allocator, .{
                .site_id = site.id,
                .url = site.base_url,
                .success = false,
                .error_message = try std.fmt.allocPrint(allocator, "Fatal: {}", .{err}),
            });
            continue;
        };

        try results.append(allocator, result);

        if (result.success) {
            log("  OK: {s} — {d} items", .{ site.name, result.items_found });
            progress.siteCompleted();
        } else {
            log("  FAIL: {s} — {s}", .{ site.name, result.error_message orelse "unknown" });
            progress.siteError();
        }
    }

    // Finalize
    if (progress.errors_count.load(.monotonic) == enabled_count) {
        log("=== Job FAILED (all sites errored) ===", .{});
        progress.fail();
    } else {
        log("=== Job COMPLETED ({d} ok, {d} errors) ===", .{
            enabled_count - progress.errors_count.load(.monotonic),
            progress.errors_count.load(.monotonic),
        });
        progress.complete();
    }

    return results.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "Progress reset and snapshot" {
    var p = Progress{};
    p.reset(1, 5);

    const snap = p.snapshot();
    try std.testing.expectEqual(@as(i32, 1), snap.job_id);
    try std.testing.expectEqual(Progress.STATUS_RUNNING, snap.status);
    try std.testing.expectEqual(@as(i32, 5), snap.total_sites);
    try std.testing.expectEqual(@as(i32, 0), snap.completed_sites);
}

test "Progress siteCompleted" {
    var p = Progress{};
    p.reset(1, 3);
    p.siteCompleted();
    p.siteCompleted();

    const snap = p.snapshot();
    try std.testing.expectEqual(@as(i32, 2), snap.completed_sites);
}

test "ProgressSnapshot percentComplete" {
    var snap = ProgressSnapshot{
        .total_sites = 10,
        .completed_sites = 3,
    };
    try std.testing.expectEqual(@as(u8, 30), snap.percentComplete());
}

test "ProgressSnapshot percentComplete zero" {
    var snap = ProgressSnapshot{};
    try std.testing.expectEqual(@as(u8, 0), snap.percentComplete());
}

test "scrapeSite returns result" {
    // NOTE: This test requires real network + Io runtime.
    // Kept as a compile-check only (no real fetch in unit tests).
    // Integration testing is done via the running server.
    const allocator = std.testing.allocator;
    _ = allocator;
    const site = Sites.getSiteById("espn_fc").?;
    _ = site;
    // Cannot call scrapeSite without an Io runtime — skip at unit-test level.
}
