//! HTTP scraping engine with job lifecycle management.
//!
//! Manages the scrape pipeline:
//!   1. Create a job → status=pending
//!   2. For each enabled site: fetch HTML, extract data, store raw JSON
//!   3. Update job progress atomically (for htmx polling)
//!   4. Finalize job → status=completed/failed
//!
//! The scraper runs fetches through the Zig Io runtime for non-blocking I/O.
//! Progress is tracked via atomic counters readable from any handler fiber.

const std = @import("std");
const Types = @import("types.zig");
const Sites = @import("sites.zig");
const Parser = @import("parser.zig");

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

/// Fetch HTML content from a URL using a simple HTTP GET.
/// Returns the response body as an arena-allocated string.
///
/// This is a simplified HTTP client that works for basic scraping.
/// In production, you'd want proper redirect following, cookie handling, etc.
pub fn fetchUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    _ = url;
    // For now, return a placeholder that simulates fetched content.
    // The real implementation will use std.http.Client when available,
    // or raw TCP + TLS through the Io runtime.
    //
    // The placeholder allows the full pipeline (UI, progress, DB storage)
    // to be developed and tested end-to-end before wiring in real HTTP.
    return try std.fmt.allocPrint(allocator,
        \\<html><body>
        \\<h1>Football Scores</h1>
        \\<div class="match">
        \\  <span class="home">Arsenal</span>
        \\  <span class="score">2 - 1</span>
        \\  <span class="away">Chelsea</span>
        \\</div>
        \\<div class="match">
        \\  <span class="home">Liverpool</span>
        \\  <span class="score">3 - 0</span>
        \\  <span class="away">Manchester United</span>
        \\</div>
        \\<div class="standings">
        \\  <table>
        \\    <tr><td>1</td><td>Arsenal</td><td>38</td><td>89</td></tr>
        \\    <tr><td>2</td><td>Liverpool</td><td>38</td><td>82</td></tr>
        \\    <tr><td>3</td><td>Manchester City</td><td>38</td><td>79</td></tr>
        \\  </table>
        \\</div>
        \\</body></html>
    , .{});
}

/// Run a scrape operation for a single site.
/// Fetches all endpoints, extracts data, and returns results.
pub fn scrapeSite(
    allocator: std.mem.Allocator,
    site: *const Sites.Site,
) !ScrapeResult {
    // Fetch the main page
    const full_url = if (site.endpoints.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ site.base_url, site.endpoints[0].path })
    else
        try std.fmt.allocPrint(allocator, "{s}", .{site.base_url});

    const html_content = fetchUrl(allocator, full_url) catch |err| {
        return .{
            .site_id = site.id,
            .url = full_url,
            .success = false,
            .error_message = try std.fmt.allocPrint(allocator, "Fetch failed: {}", .{err}),
        };
    };
    defer allocator.free(html_content);

    // Extract data using the parser
    const score_elements = Parser.extractAllTagContents(
        allocator,
        html_content,
        "<span class=\"score\">",
        "</span>",
    ) catch &.{};
    defer if (score_elements.len > 0) allocator.free(score_elements);

    // Build the extracted JSON summary
    const extracted_json = Parser.buildExtractedJson(
        allocator,
        site.id,
        site.category,
        score_elements.len,
        score_elements,
    ) catch null;

    return .{
        .site_id = site.id,
        .url = full_url,
        .success = true,
        .extracted_json = extracted_json,
        .items_found = score_elements.len,
    };
}

/// Run a full scrape job across all enabled sites.
/// Updates the global `progress` atomically for htmx polling.
///
/// Returns a list of per-site results.
pub fn runScrapeJob(
    allocator: std.mem.Allocator,
    site_state: *const Sites.SiteState,
) ![]ScrapeResult {
    // Count enabled sites
    var enabled_count: i32 = 0;
    for (Sites.default_sites, 0..) |_, idx| {
        if (site_state.enabled_flags[idx]) enabled_count += 1;
    }

    // Initialize progress
    const job_id: i32 = progress.job_id.load(.monotonic) + 1;
    progress.reset(job_id, enabled_count);

    var results = std.ArrayList(ScrapeResult){};

    // Scrape each enabled site
    for (&Sites.default_sites, 0..) |*site, idx| {
        if (!site_state.enabled_flags[idx]) continue;

        progress.advanceSite();

        const result = try scrapeSite(allocator, site);
        try results.append(allocator, result);

        if (result.success) {
            progress.siteCompleted();
        } else {
            progress.siteError();
        }
    }

    // Finalize
    if (progress.errors_count.load(.monotonic) == enabled_count) {
        progress.fail();
    } else {
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
    const allocator = std.testing.allocator;
    const site = Sites.getSiteById("espn_fc").?;
    const result = try scrapeSite(allocator, site);
    defer allocator.free(result.url);
    defer if (result.extracted_json) |j| allocator.free(j);
    try std.testing.expect(result.success);
}
