//! Football Scraping feature module root.
//!
//! Re-exports all public types for the football web scraping feature.
//! This module provides:
//! - **Types** — Data models for competitions, teams, players, matches, injuries
//! - **Sites** — Registry of football data sources with configuration
//! - **Scraper** — HTTP fetching engine with job tracking
//! - **Parser** — HTML content extraction and data normalization
//! - **Repository** — Database CRUD for raw and normalized data
//! - **Handlers** — HTTP route handlers for UI and API endpoints
//! - **Templates** — Comptime HTML templates for htmx UI

/// Data types for football entities (Competition, Team, Match, Player, etc.).
pub const Types = @import("types.zig");

/// Registry of football data source sites.
pub const Sites = @import("sites.zig");

/// HTTP scraping engine with job lifecycle management.
pub const Scraper = @import("scraper.zig");

/// HTML content extraction and normalization.
pub const Parser = @import("parser.zig");

/// Database repository for raw scrape data and normalized tables.
pub const Repository = @import("repository.zig");

/// HTTP route handlers for the scraper UI and API.
pub const Handlers = @import("handlers.zig");

/// Comptime HTML templates for the scraper UI fragments.
pub const Templates = @import("templates.zig");

test {
    _ = Types;
    _ = Sites;
    _ = Scraper;
    _ = Parser;
    _ = Repository;
    _ = Handlers;
    _ = Templates;
}
