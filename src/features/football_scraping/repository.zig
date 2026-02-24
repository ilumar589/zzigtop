//! Database repository for the football scraping feature.
//!
//! Provides CRUD operations for:
//! - Scrape jobs (tracking scrape runs)
//! - Raw scrape data (HTML/JSON storage)
//! - Normalized football data (competitions, teams, matches, etc.)
//!
//! All queries use PostgreSQL's parameterized protocol ($1, $2, ...)
//! for SQL injection safety at the protocol level.

const std = @import("std");
const Types = @import("types.zig");

/// Database interface — matches the zzigtop db.Database API.
/// This allows the repository to work with any conforming database.
const Database = @import("../../db/database.zig");

const Repository = @This();

db: *Database,

/// Initialize with a database reference.
pub fn init(database: *Database) Repository {
    return .{ .db = database };
}

// ============================================================================
// Scrape Jobs
// ============================================================================

/// Create a new scrape job. Returns the job ID.
pub fn createJob(self: *Repository, total_sites: i32, arena: std.mem.Allocator) !?Types.ScrapeJob {
    if (try self.db.row(
        \\INSERT INTO scrape_jobs (status, total_sites, started_at)
        \\VALUES ('running', $1, NOW())
        \\RETURNING id, status, total_sites, completed_sites, errors_count, started_at::text
    , .{total_sites})) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(Types.ScrapeJob, .{ .map = .name, .allocator = arena }) catch return null;
    }
    return null;
}

/// Update job progress.
pub fn updateJobProgress(self: *Repository, job_id: i32, completed: i32, errors: i32) !void {
    _ = try self.db.exec(
        \\UPDATE scrape_jobs
        \\SET completed_sites = $2, errors_count = $3
        \\WHERE id = $1
    , .{ job_id, completed, errors });
}

/// Complete a job (set status and completion time).
pub fn completeJob(self: *Repository, job_id: i32, status: []const u8, summary: ?[]const u8) !void {
    _ = try self.db.exec(
        \\UPDATE scrape_jobs
        \\SET status = $2, completed_at = NOW(), results_summary = $3
        \\WHERE id = $1
    , .{ job_id, status, summary });
}

/// Get a job by ID.
pub fn getJob(self: *Repository, job_id: i32, arena: std.mem.Allocator) !?Types.ScrapeJob {
    if (try self.db.row(
        \\SELECT id, status, total_sites, completed_sites, errors_count, results_summary,
        \\  started_at::text, completed_at::text
        \\FROM scrape_jobs WHERE id = $1
    , .{job_id})) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(Types.ScrapeJob, .{ .map = .name, .allocator = arena }) catch return null;
    }
    return null;
}

/// Get recent jobs (most recent first, limited).
pub fn getRecentJobs(self: *Repository, limit: i32, arena: std.mem.Allocator) ![]Types.JobReport {
    var result = try self.db.query(
        \\SELECT id as job_id, status, total_sites, completed_sites, errors_count,
        \\  started_at::text, completed_at::text,
        \\  EXTRACT(EPOCH FROM (completed_at - started_at))::int as duration_seconds
        \\FROM scrape_jobs
        \\ORDER BY id DESC
        \\LIMIT $1
    , .{limit});
    defer result.deinit();

    var jobs = std.ArrayList(Types.JobReport){};
    while (try result.next()) |row| {
        try jobs.append(arena, try row.to(Types.JobReport, .{ .map = .name, .allocator = arena }));
    }
    return jobs.toOwnedSlice(arena);
}

// ============================================================================
// Raw Scrape Data
// ============================================================================

/// Store raw scrape data from one site fetch.
pub fn storeRawScrapeData(self: *Repository, input: Types.CreateRawScrapeInput) !void {
    _ = try self.db.exec(
        \\INSERT INTO raw_scrape_data (job_id, site_id, url, extracted_json, status, error_message, scraped_at)
        \\VALUES ($1, $2, $3, $4, $5, $6, NOW())
    , .{ input.job_id, input.site_id, input.url, input.extracted_json, input.status, input.error_message });
}

/// Get raw scrape data for a job.
pub fn getRawDataByJob(self: *Repository, job_id: i32, arena: std.mem.Allocator) ![]Types.RawScrapeData {
    var result = try self.db.query(
        \\SELECT id, job_id, site_id, url, extracted_json, scraped_at::text, status, error_message
        \\FROM raw_scrape_data
        \\WHERE job_id = $1
        \\ORDER BY id
    , .{job_id});
    defer result.deinit();

    var data = std.ArrayList(Types.RawScrapeData){};
    while (try result.next()) |row| {
        try data.append(arena, try row.to(Types.RawScrapeData, .{ .map = .name, .allocator = arena }));
    }
    return data.toOwnedSlice(arena);
}

/// Get errors from a specific job.
pub fn getJobErrors(self: *Repository, job_id: i32, arena: std.mem.Allocator) ![]Types.SiteError {
    var result = try self.db.query(
        \\SELECT site_id, site_id as site_name, url, error_message
        \\FROM raw_scrape_data
        \\WHERE job_id = $1 AND status = 'error'
        \\ORDER BY id
    , .{job_id});
    defer result.deinit();

    var errors = std.ArrayList(Types.SiteError){};
    while (try result.next()) |row| {
        try errors.append(arena, try row.to(Types.SiteError, .{ .map = .name, .allocator = arena }));
    }
    return errors.toOwnedSlice(arena);
}

// ============================================================================
// Competitions
// ============================================================================

/// Insert or update a competition (upsert by name+season).
pub fn upsertCompetition(self: *Repository, input: Types.CreateCompetitionInput, arena: std.mem.Allocator) !?Types.Competition {
    if (try self.db.row(
        \\INSERT INTO competitions (name, country, season, site_source)
        \\VALUES ($1, $2, $3, $4)
        \\ON CONFLICT (name, season) DO UPDATE SET
        \\  country = EXCLUDED.country,
        \\  site_source = EXCLUDED.site_source
        \\RETURNING id, name, country, season, site_source
    , .{ input.name, input.country, input.season, input.site_source })) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(Types.Competition, .{ .map = .name, .allocator = arena }) catch return null;
    }
    return null;
}

/// Get all competitions.
pub fn getAllCompetitions(self: *Repository, arena: std.mem.Allocator) ![]Types.Competition {
    var result = try self.db.query(
        "SELECT id, name, country, season, site_source FROM competitions ORDER BY name",
        .{},
    );
    defer result.deinit();

    var comps = std.ArrayList(Types.Competition){};
    while (try result.next()) |row| {
        try comps.append(arena, try row.to(Types.Competition, .{ .map = .name, .allocator = arena }));
    }
    return comps.toOwnedSlice(arena);
}

// ============================================================================
// Teams
// ============================================================================

/// Insert or update a team (upsert by name).
pub fn upsertTeam(self: *Repository, input: Types.CreateTeamInput, arena: std.mem.Allocator) !?Types.Team {
    if (try self.db.row(
        \\INSERT INTO teams (name, short_name, country, competition_id, logo_url)
        \\VALUES ($1, $2, $3, $4, $5)
        \\ON CONFLICT (name) DO UPDATE SET
        \\  short_name = COALESCE(EXCLUDED.short_name, teams.short_name),
        \\  country = COALESCE(EXCLUDED.country, teams.country),
        \\  competition_id = COALESCE(EXCLUDED.competition_id, teams.competition_id),
        \\  logo_url = COALESCE(EXCLUDED.logo_url, teams.logo_url)
        \\RETURNING id, name, short_name, country, competition_id, logo_url
    , .{ input.name, input.short_name, input.country, input.competition_id, input.logo_url })) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(Types.Team, .{ .map = .name, .allocator = arena }) catch return null;
    }
    return null;
}

/// Get all teams.
pub fn getAllTeams(self: *Repository, arena: std.mem.Allocator) ![]Types.Team {
    var result = try self.db.query(
        "SELECT id, name, short_name, country, competition_id, logo_url FROM teams ORDER BY name",
        .{},
    );
    defer result.deinit();

    var teams = std.ArrayList(Types.Team){};
    while (try result.next()) |row| {
        try teams.append(arena, try row.to(Types.Team, .{ .map = .name, .allocator = arena }));
    }
    return teams.toOwnedSlice(arena);
}

// ============================================================================
// Matches
// ============================================================================

/// Insert a match.
pub fn insertMatch(self: *Repository, input: Types.CreateMatchInput, arena: std.mem.Allocator) !?Types.Match {
    if (try self.db.row(
        \\INSERT INTO matches (competition_id, home_team_id, away_team_id, match_date, status, home_score, away_score, venue, matchday)
        \\VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        \\RETURNING id, competition_id, home_team_id, away_team_id, match_date::text, status, home_score, away_score, venue, matchday
    , .{ input.competition_id, input.home_team_id, input.away_team_id, input.match_date, input.status, input.home_score, input.away_score, input.venue, input.matchday })) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(Types.Match, .{ .map = .name, .allocator = arena }) catch return null;
    }
    return null;
}

/// Get recent matches.
pub fn getRecentMatches(self: *Repository, limit: i32, arena: std.mem.Allocator) ![]Types.Match {
    var result = try self.db.query(
        \\SELECT id, competition_id, home_team_id, away_team_id, match_date::text, status, home_score, away_score, venue, matchday
        \\FROM matches ORDER BY id DESC LIMIT $1
    , .{limit});
    defer result.deinit();

    var matches = std.ArrayList(Types.Match){};
    while (try result.next()) |row| {
        try matches.append(arena, try row.to(Types.Match, .{ .map = .name, .allocator = arena }));
    }
    return matches.toOwnedSlice(arena);
}

// ============================================================================
// Players
// ============================================================================

/// Insert or update a player.
pub fn upsertPlayer(self: *Repository, input: Types.CreatePlayerInput, arena: std.mem.Allocator) !?Types.Player {
    if (try self.db.row(
        \\INSERT INTO players (name, team_id, position, number, nationality)
        \\VALUES ($1, $2, $3, $4, $5)
        \\ON CONFLICT (name, team_id) DO UPDATE SET
        \\  position = COALESCE(EXCLUDED.position, players.position),
        \\  number = COALESCE(EXCLUDED.number, players.number),
        \\  nationality = COALESCE(EXCLUDED.nationality, players.nationality)
        \\RETURNING id, name, team_id, position, number, nationality
    , .{ input.name, input.team_id, input.position, input.number, input.nationality })) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(Types.Player, .{ .map = .name, .allocator = arena }) catch return null;
    }
    return null;
}

/// Get all players.
pub fn getAllPlayers(self: *Repository, arena: std.mem.Allocator) ![]Types.Player {
    var result = try self.db.query(
        "SELECT id, name, team_id, position, number, nationality FROM players ORDER BY name",
        .{},
    );
    defer result.deinit();

    var players = std.ArrayList(Types.Player){};
    while (try result.next()) |row| {
        try players.append(arena, try row.to(Types.Player, .{ .map = .name, .allocator = arena }));
    }
    return players.toOwnedSlice(arena);
}

// ============================================================================
// Injuries
// ============================================================================

/// Insert an injury report.
pub fn insertInjury(self: *Repository, player_id: ?i32, team_id: ?i32, injury_type: ?[]const u8, expected_return: ?[]const u8, site_source: ?[]const u8) !void {
    _ = try self.db.exec(
        \\INSERT INTO injuries (player_id, team_id, injury_type, expected_return, reported_at, site_source)
        \\VALUES ($1, $2, $3, $4, NOW(), $5)
    , .{ player_id, team_id, injury_type, expected_return, site_source });
}

/// Get all current injuries.
pub fn getAllInjuries(self: *Repository, arena: std.mem.Allocator) ![]Types.Injury {
    var result = try self.db.query(
        "SELECT id, player_id, team_id, injury_type, expected_return, reported_at::text, site_source FROM injuries ORDER BY id DESC",
        .{},
    );
    defer result.deinit();

    var injuries = std.ArrayList(Types.Injury){};
    while (try result.next()) |row| {
        try injuries.append(arena, try row.to(Types.Injury, .{ .map = .name, .allocator = arena }));
    }
    return injuries.toOwnedSlice(arena);
}

// ============================================================================
// Standings
// ============================================================================

/// Get standings for a competition.
pub fn getStandings(self: *Repository, competition_id: i32, arena: std.mem.Allocator) ![]Types.Standing {
    var result = try self.db.query(
        \\SELECT id, competition_id, team_id, position, played, won, drawn, lost, goals_for, goals_against, points
        \\FROM standings WHERE competition_id = $1 ORDER BY position
    , .{competition_id});
    defer result.deinit();

    var standings = std.ArrayList(Types.Standing){};
    while (try result.next()) |row| {
        try standings.append(arena, try row.to(Types.Standing, .{ .map = .name, .allocator = arena }));
    }
    return standings.toOwnedSlice(arena);
}

// ============================================================================
// Dashboard Statistics
// ============================================================================

/// Get counts for the dashboard overview.
pub fn getDashboardStats(self: *Repository, arena: std.mem.Allocator) !Types.DashboardStats {
    var stats = Types.DashboardStats{};

    // Count competitions
    if (try self.db.row("SELECT COUNT(*)::int as cnt FROM competitions", .{})) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        const CountResult = struct { cnt: i32 };
        if (qr.to(CountResult, .{ .map = .name, .allocator = arena })) |r| {
            stats.total_competitions = r.cnt;
        } else |_| {}
    }

    // Count teams
    if (try self.db.row("SELECT COUNT(*)::int as cnt FROM teams", .{})) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        const CountResult = struct { cnt: i32 };
        if (qr.to(CountResult, .{ .map = .name, .allocator = arena })) |r| {
            stats.total_teams = r.cnt;
        } else |_| {}
    }

    // Count matches
    if (try self.db.row("SELECT COUNT(*)::int as cnt FROM matches", .{})) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        const CountResult = struct { cnt: i32 };
        if (qr.to(CountResult, .{ .map = .name, .allocator = arena })) |r| {
            stats.total_matches = r.cnt;
        } else |_| {}
    }

    // Count jobs
    if (try self.db.row("SELECT COUNT(*)::int as cnt FROM scrape_jobs", .{})) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        const CountResult = struct { cnt: i32 };
        if (qr.to(CountResult, .{ .map = .name, .allocator = arena })) |r| {
            stats.total_jobs = r.cnt;
        } else |_| {}
    }

    return stats;
}
