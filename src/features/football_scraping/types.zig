//! Data types for the football scraping feature.
//!
//! These types represent the normalized data model for football information
//! collected from multiple sources. They map directly to database tables
//! and are used throughout the scraper pipeline:
//!   scrape → raw JSON → parse → typed structs → DB insert
//!
//! All string fields in returned structs should be considered borrowed
//! from either a database result row or a JSON parse buffer. Use an
//! arena allocator to ensure lifetime safety.

const std = @import("std");

// ============================================================================
// Scrape Infrastructure Types
// ============================================================================

/// Status of a scrape job.
pub const JobStatus = enum {
    pending,
    running,
    completed,
    failed,

    pub fn toString(self: JobStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
        };
    }

    pub fn fromString(s: []const u8) ?JobStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return null;
    }
};

/// Status of an individual scrape task (one URL fetch).
pub const ScrapeStatus = enum {
    success,
    @"error",

    pub fn toString(self: ScrapeStatus) []const u8 {
        return switch (self) {
            .success => "success",
            .@"error" => "error",
        };
    }
};

/// A scrape job — represents one batch scraping run across multiple sites.
pub const ScrapeJob = struct {
    id: i32 = 0,
    status: []const u8 = "pending",
    started_at: ?[]const u8 = null,
    completed_at: ?[]const u8 = null,
    total_sites: i32 = 0,
    completed_sites: i32 = 0,
    errors_count: i32 = 0,
    results_summary: ?[]const u8 = null,
};

/// A raw scrape result — one fetched page with extracted data.
pub const RawScrapeData = struct {
    id: i32 = 0,
    job_id: i32 = 0,
    site_id: []const u8 = "",
    url: []const u8 = "",
    extracted_json: ?[]const u8 = null,
    scraped_at: ?[]const u8 = null,
    status: []const u8 = "success",
    error_message: ?[]const u8 = null,
};

/// Input for creating a raw scrape data record.
pub const CreateRawScrapeInput = struct {
    job_id: i32,
    site_id: []const u8,
    url: []const u8,
    extracted_json: ?[]const u8 = null,
    status: []const u8 = "success",
    error_message: ?[]const u8 = null,
};

// ============================================================================
// Normalized Football Data Types
// ============================================================================

/// A football competition (league, cup, tournament).
pub const Competition = struct {
    id: i32 = 0,
    name: []const u8 = "",
    country: ?[]const u8 = null,
    season: ?[]const u8 = null,
    site_source: ?[]const u8 = null,
};

/// Input for creating/updating a competition.
pub const CreateCompetitionInput = struct {
    name: []const u8,
    country: ?[]const u8 = null,
    season: ?[]const u8 = null,
    site_source: ?[]const u8 = null,
};

/// A football team.
pub const Team = struct {
    id: i32 = 0,
    name: []const u8 = "",
    short_name: ?[]const u8 = null,
    country: ?[]const u8 = null,
    competition_id: ?i32 = null,
    logo_url: ?[]const u8 = null,
};

/// Input for creating/updating a team.
pub const CreateTeamInput = struct {
    name: []const u8,
    short_name: ?[]const u8 = null,
    country: ?[]const u8 = null,
    competition_id: ?i32 = null,
    logo_url: ?[]const u8 = null,
};

/// A football player.
pub const Player = struct {
    id: i32 = 0,
    name: []const u8 = "",
    team_id: ?i32 = null,
    position: ?[]const u8 = null,
    number: ?i32 = null,
    nationality: ?[]const u8 = null,
};

/// Input for creating/updating a player.
pub const CreatePlayerInput = struct {
    name: []const u8,
    team_id: ?i32 = null,
    position: ?[]const u8 = null,
    number: ?i32 = null,
    nationality: ?[]const u8 = null,
};

/// Match status.
pub const MatchStatus = enum {
    scheduled,
    live,
    completed,
    postponed,
    cancelled,

    pub fn toString(self: MatchStatus) []const u8 {
        return switch (self) {
            .scheduled => "scheduled",
            .live => "live",
            .completed => "completed",
            .postponed => "postponed",
            .cancelled => "cancelled",
        };
    }

    pub fn fromString(s: []const u8) ?MatchStatus {
        if (std.mem.eql(u8, s, "scheduled")) return .scheduled;
        if (std.mem.eql(u8, s, "live")) return .live;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "postponed")) return .postponed;
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        return null;
    }
};

/// A football match.
pub const Match = struct {
    id: i32 = 0,
    competition_id: ?i32 = null,
    home_team_id: ?i32 = null,
    away_team_id: ?i32 = null,
    match_date: ?[]const u8 = null,
    status: []const u8 = "scheduled",
    home_score: ?i32 = null,
    away_score: ?i32 = null,
    venue: ?[]const u8 = null,
    matchday: ?i32 = null,
};

/// Input for creating/updating a match.
pub const CreateMatchInput = struct {
    competition_id: ?i32 = null,
    home_team_id: ?i32 = null,
    away_team_id: ?i32 = null,
    match_date: ?[]const u8 = null,
    status: []const u8 = "scheduled",
    home_score: ?i32 = null,
    away_score: ?i32 = null,
    venue: ?[]const u8 = null,
    matchday: ?i32 = null,
};

/// A match event (goal, card, substitution).
pub const MatchEvent = struct {
    id: i32 = 0,
    match_id: ?i32 = null,
    event_type: []const u8 = "",
    minute: ?i32 = null,
    player_id: ?i32 = null,
    team_id: ?i32 = null,
    details: ?[]const u8 = null,
};

/// A player injury report.
pub const Injury = struct {
    id: i32 = 0,
    player_id: ?i32 = null,
    team_id: ?i32 = null,
    injury_type: ?[]const u8 = null,
    expected_return: ?[]const u8 = null,
    reported_at: ?[]const u8 = null,
    site_source: ?[]const u8 = null,
};

/// League standings entry for one team.
pub const Standing = struct {
    id: i32 = 0,
    competition_id: ?i32 = null,
    team_id: ?i32 = null,
    position: ?i32 = null,
    played: i32 = 0,
    won: i32 = 0,
    drawn: i32 = 0,
    lost: i32 = 0,
    goals_for: i32 = 0,
    goals_against: i32 = 0,
    points: i32 = 0,
};

/// Input for creating/updating a standings entry.
pub const CreateStandingInput = struct {
    competition_id: ?i32 = null,
    team_id: ?i32 = null,
    position: ?i32 = null,
    played: i32 = 0,
    won: i32 = 0,
    drawn: i32 = 0,
    lost: i32 = 0,
    goals_for: i32 = 0,
    goals_against: i32 = 0,
    points: i32 = 0,
};

// ============================================================================
// Aggregate / Report Types
// ============================================================================

/// Summary statistics for the scraper dashboard.
pub const DashboardStats = struct {
    total_sites: i32 = 0,
    enabled_sites: i32 = 0,
    total_jobs: i32 = 0,
    last_scrape_at: ?[]const u8 = null,
    total_competitions: i32 = 0,
    total_teams: i32 = 0,
    total_players: i32 = 0,
    total_matches: i32 = 0,
    total_injuries: i32 = 0,
    total_errors: i32 = 0,
};

/// Report entry for a scrape job result.
pub const JobReport = struct {
    job_id: i32 = 0,
    status: []const u8 = "",
    started_at: ?[]const u8 = null,
    completed_at: ?[]const u8 = null,
    total_sites: i32 = 0,
    completed_sites: i32 = 0,
    errors_count: i32 = 0,
    duration_seconds: ?i32 = null,
};

/// Per-site error detail in a report.
pub const SiteError = struct {
    site_id: []const u8 = "",
    site_name: []const u8 = "",
    url: []const u8 = "",
    error_message: []const u8 = "",
    scraped_at: ?[]const u8 = null,
};

// ============================================================================
// Tests
// ============================================================================

test "JobStatus round-trip" {
    const status = JobStatus.running;
    const str = status.toString();
    try std.testing.expectEqualStrings("running", str);
    const parsed = JobStatus.fromString(str);
    try std.testing.expectEqual(JobStatus.running, parsed.?);
}

test "MatchStatus round-trip" {
    const status = MatchStatus.completed;
    const str = status.toString();
    try std.testing.expectEqualStrings("completed", str);
    const parsed = MatchStatus.fromString(str);
    try std.testing.expectEqual(MatchStatus.completed, parsed.?);
}

test "ScrapeJob default values" {
    const job = ScrapeJob{};
    try std.testing.expectEqual(@as(i32, 0), job.id);
    try std.testing.expectEqualStrings("pending", job.status);
    try std.testing.expectEqual(@as(i32, 0), job.total_sites);
}

test "Competition default values" {
    const comp = Competition{};
    try std.testing.expectEqual(@as(i32, 0), comp.id);
    try std.testing.expectEqualStrings("", comp.name);
    try std.testing.expect(comp.country == null);
}
