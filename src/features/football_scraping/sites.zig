//! Football data source site registry.
//!
//! Defines the list of football websites that can be scraped, along with
//! their URLs and metadata. Sites can be enabled/disabled at runtime
//! via the UI. The registry is initialized at comptime with defaults
//! and managed at runtime through the database.

const std = @import("std");
const Types = @import("types.zig");

/// A configured scraping source site.
pub const Site = struct {
    /// Unique identifier (e.g., "espn_fc").
    id: []const u8,
    /// Human-readable display name.
    name: []const u8,
    /// Base URL for the site.
    base_url: []const u8,
    /// Whether this site is enabled for scraping.
    enabled: bool = true,
    /// Category of data this site primarily provides.
    category: []const u8,
    /// Description of what data can be extracted.
    description: []const u8,
    /// Specific URLs to scrape for different data types.
    endpoints: []const Endpoint = &.{},
};

/// A specific URL endpoint within a site to scrape.
pub const Endpoint = struct {
    /// What type of data this endpoint provides.
    data_type: DataType,
    /// URL path (appended to site's base_url).
    path: []const u8,
    /// Human description of this endpoint.
    description: []const u8,
};

/// Types of data that can be scraped.
pub const DataType = enum {
    scores,
    standings,
    fixtures,
    teams,
    players,
    injuries,
    transfers,
    stats,

    pub fn toString(self: DataType) []const u8 {
        return switch (self) {
            .scores => "scores",
            .standings => "standings",
            .fixtures => "fixtures",
            .teams => "teams",
            .players => "players",
            .injuries => "injuries",
            .transfers => "transfers",
            .stats => "stats",
        };
    }
};

/// Default set of football data source sites.
/// These are compiled into the binary and used to seed the database.
pub const default_sites = [_]Site{
    .{
        .id = "espn_fc",
        .name = "ESPN FC",
        .base_url = "https://www.espn.com/soccer",
        .category = "scores,standings,transfers",
        .description = "Major leagues scores, standings, and transfer news",
        .endpoints = &.{
            .{ .data_type = .scores, .path = "/scoreboard", .description = "Today's scores" },
            .{ .data_type = .standings, .path = "/standings", .description = "League standings" },
            .{ .data_type = .fixtures, .path = "/schedule", .description = "Upcoming fixtures" },
        },
    },
    .{
        .id = "bbc_sport",
        .name = "BBC Sport Football",
        .base_url = "https://www.bbc.com/sport/football",
        .category = "scores,results,tables",
        .description = "UK and European football results, fixtures, and tables",
        .endpoints = &.{
            .{ .data_type = .scores, .path = "/scores-fixtures", .description = "Scores and fixtures" },
            .{ .data_type = .standings, .path = "/tables", .description = "League tables" },
            .{ .data_type = .teams, .path = "/teams", .description = "Team information" },
        },
    },
    .{
        .id = "transfermarkt",
        .name = "Transfermarkt",
        .base_url = "https://www.transfermarkt.com",
        .category = "transfers,injuries,players",
        .description = "Transfer values, injury reports, and player profiles",
        .endpoints = &.{
            .{ .data_type = .injuries, .path = "/verletzungen/aktuelle-verletzungen/verletzte-spieler", .description = "Current injuries" },
            .{ .data_type = .transfers, .path = "/transfers", .description = "Latest transfers" },
            .{ .data_type = .players, .path = "/spieler-statistik/wertvollstespieler/marktwertetop", .description = "Most valuable players" },
        },
    },
    .{
        .id = "flashscore",
        .name = "Flashscore",
        .base_url = "https://www.flashscore.com/football",
        .category = "scores,live",
        .description = "Live scores and real-time match results",
        .endpoints = &.{
            .{ .data_type = .scores, .path = "/", .description = "Live and recent scores" },
        },
    },
    .{
        .id = "soccerway",
        .name = "Soccerway",
        .base_url = "https://www.soccerway.com",
        .category = "matches,standings,teams",
        .description = "Comprehensive match data and statistics",
        .endpoints = &.{
            .{ .data_type = .scores, .path = "/matches/today/", .description = "Today's matches" },
            .{ .data_type = .standings, .path = "/national/england/premier-league/", .description = "League standings" },
        },
    },
    .{
        .id = "worldfootball",
        .name = "WorldFootball.net",
        .base_url = "https://www.worldfootball.net",
        .category = "standings,results,history",
        .description = "Historical data, standings, and comprehensive results",
        .endpoints = &.{
            .{ .data_type = .standings, .path = "/competition/eng-premier-league/", .description = "Premier League" },
            .{ .data_type = .scores, .path = "/schedule/eng-premier-league/", .description = "Schedule and results" },
        },
    },
    .{
        .id = "fbref",
        .name = "FBRef",
        .base_url = "https://fbref.com",
        .category = "stats,players,teams",
        .description = "Advanced statistics, player data, and team analysis",
        .endpoints = &.{
            .{ .data_type = .stats, .path = "/en/comps/9/Premier-League-Stats", .description = "Premier League stats" },
            .{ .data_type = .players, .path = "/en/comps/9/stats/Premier-League-Stats", .description = "Player statistics" },
        },
    },
    .{
        .id = "sofascore",
        .name = "SofaScore",
        .base_url = "https://www.sofascore.com/football",
        .category = "scores,ratings,live",
        .description = "Live scores, player ratings, and match statistics",
        .endpoints = &.{
            .{ .data_type = .scores, .path = "/livescore", .description = "Live scores" },
            .{ .data_type = .standings, .path = "/tournament/premier-league/17", .description = "Standings" },
        },
    },
};

/// Get a site by ID from the default registry.
pub fn getSiteById(id: []const u8) ?*const Site {
    for (&default_sites) |*site| {
        if (std.mem.eql(u8, site.id, id)) return site;
    }
    return null;
}

/// Get all enabled sites from the default registry.
pub fn getEnabledSites(buf: []Site) usize {
    var count: usize = 0;
    for (default_sites) |site| {
        if (site.enabled and count < buf.len) {
            buf[count] = site;
            count += 1;
        }
    }
    return count;
}

/// Get the total number of default sites.
pub fn siteCount() usize {
    return default_sites.len;
}

// ============================================================================
// Runtime Site State
// ============================================================================

/// Runtime state for site enable/disable (backed by DB in production).
/// This provides an in-memory fallback when DB is not available.
pub const SiteState = struct {
    enabled_flags: [default_sites.len]bool = .{true} ** default_sites.len,

    pub fn init() SiteState {
        return .{};
    }

    pub fn setEnabled(self: *SiteState, site_id: []const u8, enabled: bool) bool {
        for (&default_sites, 0..) |*site, idx| {
            if (std.mem.eql(u8, site.id, site_id)) {
                self.enabled_flags[idx] = enabled;
                return true;
            }
        }
        return false;
    }

    pub fn isEnabled(self: *const SiteState, site_id: []const u8) bool {
        for (&default_sites, 0..) |*site, idx| {
            if (std.mem.eql(u8, site.id, site_id)) {
                return self.enabled_flags[idx];
            }
        }
        return false;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "default_sites count" {
    try std.testing.expectEqual(@as(usize, 8), default_sites.len);
}

test "getSiteById found" {
    const site = getSiteById("espn_fc");
    try std.testing.expect(site != null);
    try std.testing.expectEqualStrings("ESPN FC", site.?.name);
}

test "getSiteById not found" {
    const site = getSiteById("nonexistent");
    try std.testing.expect(site == null);
}

test "SiteState toggle" {
    var state = SiteState.init();
    try std.testing.expect(state.isEnabled("espn_fc"));

    _ = state.setEnabled("espn_fc", false);
    try std.testing.expect(!state.isEnabled("espn_fc"));

    _ = state.setEnabled("espn_fc", true);
    try std.testing.expect(state.isEnabled("espn_fc"));
}
