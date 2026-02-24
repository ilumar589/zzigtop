# Football Scraping Feature — Implementation Plan

> **Created:** 2026-02-24  
> **Location:** `src/features/football_scraping/`  
> **Status:** IN PROGRESS

---

## Overview

A web scraping module that collects football (soccer) data from multiple public sites —
championships, match results, team rosters, player injuries, scores, and standings.
Data flows through a pipeline: **scrape → raw JSON storage → standardization → relational DB**.

The entire process is controlled via the existing htmx + comptime template UI with:
- Site selection (which sources to scrape)
- Live scraping progress (htmx polling)
- Data analysis dashboard
- Problem/success reports

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                     UI Layer (htmx + Templates)                      │
│  /scraper                — Dashboard (site list, controls, reports)   │
│  /scraper/start          — POST: kick off scrape jobs                │
│  /scraper/progress       — GET: htmx-polled progress fragment        │
│  /scraper/results        — GET: analysis data / report view          │
│  /scraper/sites          — GET: site list with toggle controls       │
│  /scraper/reports        — GET: problem/success report list          │
│  /scraper/api/sites      — GET/PUT: JSON API for site config        │
│  /scraper/api/jobs       — GET: JSON API for scrape job status      │
│  /scraper/api/data/:type — GET: JSON API for scraped data           │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────────────┐
│                   Handler Layer (handlers.zig)                        │
│  - Route handlers that bridge UI ↔ scraper engine                    │
│  - htmx detection (full page vs fragment)                            │
│  - Template rendering with scraper state data                        │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────────────┐
│                  Scraper Engine (scraper.zig)                         │
│  - HTTP client (std.http.Client or raw TCP via Io)                   │
│  - HTML content fetching per configured site                         │
│  - Raw response storage as JSON blobs                                │
│  - Job tracking (status, progress, errors)                           │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────────────┐
│                  Parser / Extractor (parser.zig)                     │
│  - Site-specific extraction logic (per-source parsers)               │
│  - HTML text pattern matching (lightweight, no full DOM)             │
│  - Data normalization → standardized types                           │
└────────────────────┬─────────────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────────────┐
│                  Data Layer (repository.zig)                          │
│  - Raw scrape storage (JSON blobs + metadata)                        │
│  - Normalized relational tables:                                     │
│    competitions, teams, players, matches,                            │
│    match_events, injuries, standings                                 │
│  - Scrape job tracking table                                         │
│  - Report generation queries                                         │
└──────────────────────────────────────────────────────────────────────┘
```

---

## File Structure

```
src/features/football_scraping/
├── football_scraping.zig   — Module root (re-exports all public types)
├── types.zig               — Data types (Competition, Team, Match, Player, etc.)
├── scraper.zig             — HTTP fetching engine + job management
├── parser.zig              — HTML content extraction + normalization
├── repository.zig          — Database CRUD (raw + normalized tables)
├── handlers.zig            — HTTP route handlers (UI + API)
├── templates.zig           — Comptime HTML templates (htmx fragments)
└── sites.zig               — Site registry (URLs, selectors, metadata)
```

---

## Data Model

### Scrape Sites (configuration)

| Field | Type | Description |
|-------|------|-------------|
| id | TEXT | Unique site identifier (e.g. "espn", "bbc_sport") |
| name | TEXT | Display name |
| base_url | TEXT | Base URL for scraping |
| enabled | BOOLEAN | Whether to include in scrape runs |
| category | TEXT | What data this site provides |
| last_scraped_at | TIMESTAMP | Last successful scrape |

### Scrape Jobs (tracking)

| Field | Type | Description |
|-------|------|-------------|
| id | SERIAL | Job ID |
| status | TEXT | pending / running / completed / failed |
| started_at | TIMESTAMP | When the job started |
| completed_at | TIMESTAMP | When the job finished |
| total_sites | INT | Number of sites to scrape |
| completed_sites | INT | Sites finished so far |
| errors_count | INT | Number of errors encountered |
| results_summary | JSONB | Summary of what was found |

### Raw Scrape Data

| Field | Type | Description |
|-------|------|-------------|
| id | SERIAL | Row ID |
| job_id | INT | FK to scrape_jobs |
| site_id | TEXT | Which site this came from |
| url | TEXT | Exact URL scraped |
| raw_content | TEXT | Raw HTML content |
| extracted_json | JSONB | Parsed data as JSON |
| scraped_at | TIMESTAMP | When this was fetched |
| status | TEXT | success / error |
| error_message | TEXT | Error details if failed |

### Normalized Tables

**competitions**
- id SERIAL, name TEXT, country TEXT, season TEXT, site_source TEXT

**teams**
- id SERIAL, name TEXT, short_name TEXT, country TEXT, competition_id FK, logo_url TEXT

**players**
- id SERIAL, name TEXT, team_id FK, position TEXT, number INT, nationality TEXT

**matches**
- id SERIAL, competition_id FK, home_team_id FK, away_team_id FK,
  match_date TIMESTAMP, status TEXT (scheduled/live/completed),
  home_score INT, away_score INT, venue TEXT, matchday INT

**match_events**
- id SERIAL, match_id FK, event_type TEXT (goal/card/sub), minute INT,
  player_id FK, team_id FK, details TEXT

**injuries**
- id SERIAL, player_id FK, team_id FK, injury_type TEXT, expected_return TEXT,
  reported_at TIMESTAMP, site_source TEXT

**standings**
- id SERIAL, competition_id FK, team_id FK, position INT, played INT,
  won INT, drawn INT, lost INT, goals_for INT, goals_against INT, points INT

---

## Scraping Sources

Initial target sites (public, scrapable football data):

| ID | Name | URL | Data Types |
|----|------|-----|------------|
| espn_fc | ESPN FC | https://www.espn.com/soccer/ | Scores, standings, transfers |
| bbc_sport | BBC Sport Football | https://www.bbc.com/sport/football | Results, fixtures, tables |
| transfermarkt | Transfermarkt | https://www.transfermarkt.com/ | Transfers, market values, injuries |
| flashscore | Flashscore | https://www.flashscore.com/football/ | Live scores, results |
| soccerway | Soccerway | https://www.soccerway.com/ | Comprehensive match data |
| worldfootball | WorldFootball.net | https://www.worldfootball.net/ | Historical data, standings |
| fbref | FBRef | https://fbref.com/ | Advanced stats, player data |
| sofascore | SofaScore | https://www.sofascore.com/football | Live scores, ratings |

---

## UI Pages (htmx)

### 1. Dashboard (`/scraper`)
- Overview cards: total sites, last scrape time, data counts
- Quick-start scrape button
- Recent job history mini-table
- Error count badge

### 2. Site Management (`/scraper/sites` — htmx fragment)
- Table of all configured sites
- Toggle enable/disable per site (htmx PUT)
- Last scraped timestamp
- Status indicator (healthy/error)

### 3. Scrape Progress (`/scraper/progress` — htmx polling)
- Progress bar (completed_sites / total_sites)
- Per-site status cards (pending → running → done/error)
- Live log of current activity
- Auto-polls every 2 seconds during active scrape

### 4. Results & Analysis (`/scraper/results`)
- Tabbed view: Competitions | Matches | Teams | Players | Injuries
- Summary statistics per data type
- Filter by competition, date range
- Raw JSON viewer for debugging

### 5. Reports (`/scraper/reports`)
- Job history with success/failure counts
- Error details per job (expandable)
- Data quality metrics (missing fields, parse failures)
- Site reliability scores

---

## Implementation Steps

### Step 18-1: Module scaffolding + types
- Create `src/features/football_scraping/` directory
- Define all data types in `types.zig`
- Create module root `football_scraping.zig`
- Wire into `root.zig`

### Step 18-2: Database schema + repository
- Add migration SQL to `docker/init.sql`
- Implement `repository.zig` with CRUD for all tables
- Scrape job creation/update/query

### Step 18-3: Site registry
- Define site configurations in `sites.zig`
- Site enable/disable logic
- URL generation per site

### Step 18-4: Scraper engine
- HTTP fetching with Io runtime
- Job lifecycle (create → run → complete/fail)
- Progress tracking with atomic counters
- Error capture and reporting
- Raw content storage

### Step 18-5: Content parser
- Site-specific extraction functions
- HTML text pattern matching
- JSON extraction from page content
- Data normalization to standard types

### Step 18-6: Comptime templates
- Dashboard page template
- Site management table template
- Progress bar + status fragments
- Results tables
- Report views

### Step 18-7: Route handlers
- Wire all `/scraper/*` routes
- htmx detection (fragment vs full page)
- API endpoints for JSON access
- Scrape job start/monitor handlers

### Step 18-8: Integration with server
- Add routes to `http_server_main.zig` router
- Add feature module to `root.zig`
- Update build.zig if needed
- Static assets (CSS for scraper UI)

### Step 18-9: Testing + documentation
- Unit tests for parser functions
- Integration tests for repository
- Update PROGRESS.md
- Update API.md with new endpoints

---

## Key Design Decisions

1. **Feature isolation**: Everything lives under `src/features/football_scraping/` — 
   the feature is self-contained and doesn't pollute the core HTTP/DB modules.

2. **Two-phase storage**: Raw HTML/JSON stored first (forensic trail), then 
   normalized into relational tables. This enables re-parsing without re-scraping.

3. **htmx for progress**: The scraping progress UI uses htmx polling 
   (`hx-trigger="every 2s"`) to show live updates without WebSockets.

4. **Comptime templates**: All HTML fragments are compiled at build time
   using the existing template engine — zero runtime parsing overhead.

5. **Arena-friendly**: All per-request allocations use the existing 
   arena-per-request pattern. Scraper results are stored in DB, not in memory.

6. **Io-native HTTP client**: Uses `std.http.Client` through the Io runtime
   for non-blocking HTTP fetches during scraping.
