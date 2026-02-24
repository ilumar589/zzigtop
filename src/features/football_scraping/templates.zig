//! Comptime HTML templates for the football scraper UI.
//!
//! All templates are parsed at compile time using the zzigtop template engine.
//! At runtime, rendering is a straight-line sequence of buffer writes.
//!
//! Templates are organized by page/fragment:
//! - Dashboard (full page + overview fragments)
//! - Site management (site list + toggle controls)
//! - Progress (progress bar + status cards)
//! - Results (data tables)
//! - Reports (job history + error details)

const html = @import("../../html/html.zig");
const Template = html.Template;

// ============================================================================
// Layout
// ============================================================================

/// Full page layout wrapper. Wraps content in a complete HTML document
/// with htmx loaded, navigation, and styles.
pub const page_layout = Template.compile(
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <title>Football Scraper — {{title}}</title>
    \\  <script src="https://unpkg.com/htmx.org@2.0.4"></script>
    \\  <link rel="stylesheet" href="/css/scraper.css">
    \\</head>
    \\<body>
    \\  <nav class="scraper-nav">
    \\    <a href="/scraper" class="nav-brand">Football Scraper</a>
    \\    <div class="nav-links">
    \\      <a href="/scraper" hx-get="/scraper/dashboard-content" hx-target="#main" hx-push-url="/scraper">Dashboard</a>
    \\      <a href="/scraper/sites" hx-get="/scraper/sites-content" hx-target="#main" hx-push-url="/scraper/sites">Sites</a>
    \\      <a href="/scraper/results" hx-get="/scraper/results-content" hx-target="#main" hx-push-url="/scraper/results">Results</a>
    \\      <a href="/scraper/reports" hx-get="/scraper/reports-content" hx-target="#main" hx-push-url="/scraper/reports">Reports</a>
    \\    </div>
    \\  </nav>
    \\  <main id="main" class="scraper-main">
    \\    {{&content}}
    \\  </main>
    \\</body>
    \\</html>
);

// ============================================================================
// Dashboard
// ============================================================================

/// Dashboard overview content (used as htmx fragment or embedded in layout).
pub const dashboard_content = Template.compile(
    \\<div class="dashboard">
    \\  <h1>Football Scraper Dashboard</h1>
    \\  <div class="stats-grid">
    \\    <div class="stat-card">
    \\      <span class="stat-value">{{enabled_sites}}</span>
    \\      <span class="stat-label">Enabled Sites</span>
    \\    </div>
    \\    <div class="stat-card">
    \\      <span class="stat-value">{{total_jobs}}</span>
    \\      <span class="stat-label">Total Jobs</span>
    \\    </div>
    \\    <div class="stat-card">
    \\      <span class="stat-value">{{total_competitions}}</span>
    \\      <span class="stat-label">Competitions</span>
    \\    </div>
    \\    <div class="stat-card">
    \\      <span class="stat-value">{{total_teams}}</span>
    \\      <span class="stat-label">Teams</span>
    \\    </div>
    \\    <div class="stat-card">
    \\      <span class="stat-value">{{total_matches}}</span>
    \\      <span class="stat-label">Matches</span>
    \\    </div>
    \\    <div class="stat-card">
    \\      <span class="stat-value">{{total_errors}}</span>
    \\      <span class="stat-label">Errors</span>
    \\    </div>
    \\  </div>
    \\
    \\  <div class="action-bar">
    \\    <button class="btn btn-primary"
    \\            hx-post="/scraper/start"
    \\            hx-target="#scrape-status"
    \\            hx-swap="innerHTML">
    \\      Start Scraping
    \\    </button>
    \\    <span id="last-scrape">Last scrape: {{last_scrape}}</span>
    \\  </div>
    \\
    \\  <div id="scrape-status">
    \\    {{&progress_html}}
    \\  </div>
    \\
    \\  <div class="recent-jobs">
    \\    <h2>Recent Jobs</h2>
    \\    <div hx-get="/scraper/recent-jobs" hx-trigger="load" hx-swap="innerHTML" id="recent-jobs-table">
    \\      <p class="loading">Loading...</p>
    \\    </div>
    \\  </div>
    \\</div>
);

// ============================================================================
// Progress
// ============================================================================

/// Progress bar fragment — polled by htmx during active scrape.
pub const progress_fragment = Template.compile(
    \\<div class="progress-container"
    \\     {{#if is_running}}hx-get="/scraper/progress" hx-trigger="every 2s" hx-swap="outerHTML"{{/if}}>
    \\  <div class="progress-header">
    \\    <span class="progress-status status-{{status_class}}">{{status_text}}</span>
    \\    <span class="progress-count">{{completed}} / {{total}} sites</span>
    \\  </div>
    \\  <div class="progress-bar">
    \\    <div class="progress-fill" style="width: {{percent}}%"></div>
    \\  </div>
    \\  {{#if has_errors}}<div class="progress-errors">{{errors}} errors encountered</div>{{/if}}
    \\</div>
);

/// Idle state (no job running).
pub const progress_idle = Template.compile(
    \\<div class="progress-idle">
    \\  <p>No scrape job running. Click "Start Scraping" to begin.</p>
    \\</div>
);

// ============================================================================
// Sites
// ============================================================================

/// Site list content.
pub const sites_content = Template.compile(
    \\<div class="sites-page">
    \\  <h1>Scraping Sources</h1>
    \\  <p class="subtitle">Select which football sites to include in scrape runs.</p>
    \\  <table class="data-table">
    \\    <thead>
    \\      <tr>
    \\        <th>Enabled</th>
    \\        <th>Site</th>
    \\        <th>URL</th>
    \\        <th>Category</th>
    \\        <th>Description</th>
    \\      </tr>
    \\    </thead>
    \\    <tbody id="site-rows">
    \\      {{&site_rows_html}}
    \\    </tbody>
    \\  </table>
    \\</div>
);

/// Individual site row.
pub const site_row = Template.compile(
    \\<tr class="site-row {{#if enabled}}site-enabled{{else}}site-disabled{{/if}}">
    \\  <td>
    \\    <button class="toggle-btn {{#if enabled}}toggle-on{{else}}toggle-off{{/if}}"
    \\            hx-put="/scraper/api/sites/{{id}}/toggle"
    \\            hx-target="closest tr"
    \\            hx-swap="outerHTML">
    \\      {{#if enabled}}ON{{else}}OFF{{/if}}
    \\    </button>
    \\  </td>
    \\  <td class="site-name">{{name}}</td>
    \\  <td class="site-url"><a href="{{base_url}}" target="_blank">{{base_url}}</a></td>
    \\  <td>{{category}}</td>
    \\  <td>{{description}}</td>
    \\</tr>
);

// ============================================================================
// Results
// ============================================================================

/// Results page content.
pub const results_content = Template.compile(
    \\<div class="results-page">
    \\  <h1>Scraped Data</h1>
    \\  <div class="tabs">
    \\    <button class="tab active" hx-get="/scraper/results/competitions" hx-target="#results-data" hx-swap="innerHTML">Competitions</button>
    \\    <button class="tab" hx-get="/scraper/results/teams" hx-target="#results-data" hx-swap="innerHTML">Teams</button>
    \\    <button class="tab" hx-get="/scraper/results/matches" hx-target="#results-data" hx-swap="innerHTML">Matches</button>
    \\    <button class="tab" hx-get="/scraper/results/players" hx-target="#results-data" hx-swap="innerHTML">Players</button>
    \\    <button class="tab" hx-get="/scraper/results/injuries" hx-target="#results-data" hx-swap="innerHTML">Injuries</button>
    \\    <button class="tab" hx-get="/scraper/results/raw" hx-target="#results-data" hx-swap="innerHTML">Raw JSON</button>
    \\  </div>
    \\  <div id="results-data" hx-get="/scraper/results/competitions" hx-trigger="load" hx-swap="innerHTML">
    \\    <p class="loading">Loading...</p>
    \\  </div>
    \\</div>
);

/// Competition results table.
pub const competitions_table = Template.compile(
    \\<table class="data-table">
    \\  <thead><tr><th>ID</th><th>Name</th><th>Country</th><th>Season</th><th>Source</th></tr></thead>
    \\  <tbody>
    \\    {{#each competitions}}<tr>
    \\      <td>{{id}}</td><td>{{name}}</td><td>{{country}}</td><td>{{season}}</td><td>{{site_source}}</td>
    \\    </tr>{{/each}}
    \\  </tbody>
    \\</table>
    \\{{#if empty}}<p class="empty-state">No competitions found. Run a scrape to collect data.</p>{{/if}}
);

/// Teams results table.
pub const teams_table = Template.compile(
    \\<table class="data-table">
    \\  <thead><tr><th>ID</th><th>Name</th><th>Short Name</th><th>Country</th></tr></thead>
    \\  <tbody>
    \\    {{#each teams}}<tr>
    \\      <td>{{id}}</td><td>{{name}}</td><td>{{short_name}}</td><td>{{country}}</td>
    \\    </tr>{{/each}}
    \\  </tbody>
    \\</table>
    \\{{#if empty}}<p class="empty-state">No teams found. Run a scrape to collect data.</p>{{/if}}
);

/// Matches results table.
pub const matches_table = Template.compile(
    \\<table class="data-table">
    \\  <thead><tr><th>ID</th><th>Status</th><th>Home Score</th><th>Away Score</th><th>Venue</th></tr></thead>
    \\  <tbody>
    \\    {{#each matches}}<tr>
    \\      <td>{{id}}</td><td>{{status}}</td><td>{{home_score}}</td><td>{{away_score}}</td><td>{{venue}}</td>
    \\    </tr>{{/each}}
    \\  </tbody>
    \\</table>
    \\{{#if empty}}<p class="empty-state">No matches found. Run a scrape to collect data.</p>{{/if}}
);

/// Players results table.
pub const players_table = Template.compile(
    \\<table class="data-table">
    \\  <thead><tr><th>ID</th><th>Name</th><th>Position</th><th>Number</th><th>Nationality</th></tr></thead>
    \\  <tbody>
    \\    {{#each players}}<tr>
    \\      <td>{{id}}</td><td>{{name}}</td><td>{{position}}</td><td>{{number}}</td><td>{{nationality}}</td>
    \\    </tr>{{/each}}
    \\  </tbody>
    \\</table>
    \\{{#if empty}}<p class="empty-state">No players found. Run a scrape to collect data.</p>{{/if}}
);

/// Injuries results table.
pub const injuries_table = Template.compile(
    \\<table class="data-table">
    \\  <thead><tr><th>ID</th><th>Injury</th><th>Expected Return</th><th>Source</th></tr></thead>
    \\  <tbody>
    \\    {{#each injuries}}<tr>
    \\      <td>{{id}}</td><td>{{injury_type}}</td><td>{{expected_return}}</td><td>{{site_source}}</td>
    \\    </tr>{{/each}}
    \\  </tbody>
    \\</table>
    \\{{#if empty}}<p class="empty-state">No injuries found. Run a scrape to collect data.</p>{{/if}}
);

// ============================================================================
// Reports
// ============================================================================

/// Reports page content.
pub const reports_content = Template.compile(
    \\<div class="reports-page">
    \\  <h1>Scrape Reports</h1>
    \\  <div hx-get="/scraper/reports/jobs" hx-trigger="load" hx-swap="innerHTML" id="reports-data">
    \\    <p class="loading">Loading...</p>
    \\  </div>
    \\</div>
);

/// Job history table.
pub const jobs_table = Template.compile(
    \\<table class="data-table">
    \\  <thead>
    \\    <tr>
    \\      <th>Job ID</th>
    \\      <th>Status</th>
    \\      <th>Sites</th>
    \\      <th>Completed</th>
    \\      <th>Errors</th>
    \\      <th>Actions</th>
    \\    </tr>
    \\  </thead>
    \\  <tbody>
    \\    {{#each jobs}}<tr class="job-row status-{{status}}">
    \\      <td>{{job_id}}</td>
    \\      <td><span class="badge badge-{{status}}">{{status}}</span></td>
    \\      <td>{{total_sites}}</td>
    \\      <td>{{completed_sites}}</td>
    \\      <td>{{errors_count}}</td>
    \\      <td>
    \\        <button class="btn btn-small"
    \\                hx-get="/scraper/reports/job/{{job_id}}"
    \\                hx-target="#job-detail"
    \\                hx-swap="innerHTML">
    \\          Details
    \\        </button>
    \\      </td>
    \\    </tr>{{/each}}
    \\  </tbody>
    \\</table>
    \\<div id="job-detail"></div>
    \\{{#if empty}}<p class="empty-state">No scrape jobs yet. Start a scrape from the dashboard.</p>{{/if}}
);

/// Recent jobs mini-table for dashboard.
pub const recent_jobs_fragment = Template.compile(
    \\{{#if has_jobs}}<table class="data-table compact">
    \\  <thead><tr><th>ID</th><th>Status</th><th>Sites</th><th>Errors</th></tr></thead>
    \\  <tbody>
    \\    {{#each jobs}}<tr>
    \\      <td>{{job_id}}</td>
    \\      <td><span class="badge badge-{{status}}">{{status}}</span></td>
    \\      <td>{{completed_sites}}/{{total_sites}}</td>
    \\      <td>{{errors_count}}</td>
    \\    </tr>{{/each}}
    \\  </tbody>
    \\</table>{{else}}<p class="empty-state">No jobs yet.</p>{{/if}}
);

// ============================================================================
// Job Detail Fragment
// ============================================================================

/// Job detail panel — shown when clicking "Details" on a job row.
pub const job_detail_fragment = Template.compile(
    \\<div class="job-detail-panel">
    \\  <h3>Job #{{job_id}} Details</h3>
    \\  <div class="detail-grid">
    \\    <div class="detail-item"><strong>Status:</strong> <span class="badge badge-{{status}}">{{status}}</span></div>
    \\    <div class="detail-item"><strong>Sites:</strong> {{total_sites}}</div>
    \\    <div class="detail-item"><strong>Completed:</strong> {{completed_sites}}</div>
    \\    <div class="detail-item"><strong>Errors:</strong> {{errors_count}}</div>
    \\  </div>
    \\  {{#if has_errors}}<h4>Errors</h4>
    \\  <table class="data-table compact">
    \\    <thead><tr><th>Site</th><th>URL</th><th>Error</th></tr></thead>
    \\    <tbody>
    \\      {{#each errors}}<tr>
    \\        <td>{{site_name}}</td>
    \\        <td>{{url}}</td>
    \\        <td>{{error_message}}</td>
    \\      </tr>{{/each}}
    \\    </tbody>
    \\  </table>{{/if}}
    \\  {{#if has_errors}}{{else}}<p class="empty-state">No errors for this job.</p>{{/if}}
    \\</div>
);

// ============================================================================
// Raw JSON Viewer
// ============================================================================

/// Raw JSON data viewer.
pub const raw_json_viewer = Template.compile(
    \\<div class="raw-json-viewer">
    \\  <h3>Raw Scrape Data (Job #{{job_id}})</h3>
    \\  {{#each entries}}<div class="raw-entry">
    \\    <div class="raw-header">
    \\      <span class="site-badge">{{site_id}}</span>
    \\      <span class="status-badge badge-{{status}}">{{status}}</span>
    \\    </div>
    \\    <pre class="json-block">{{extracted_json}}</pre>
    \\  </div>{{/each}}
    \\  {{#if empty}}<p class="empty-state">No raw data for this job.</p>{{/if}}
    \\</div>
);
