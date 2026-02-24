-- ============================================================================
-- Schema for zzigtop HTTP server (Step 13: PostgreSQL integration)
-- ============================================================================
-- This file runs automatically on first `docker compose up`.
-- To re-run: `docker compose down -v` then `docker compose up -d`.

-- Users table for CRUD demo
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    age INT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Seed data
INSERT INTO users (name, email, age) VALUES
    ('Alice', 'alice@example.com', 30),
    ('Bob', 'bob@example.com', 25),
    ('Charlie', 'charlie@example.com', 35);

-- ============================================================================
-- Football Scraping Feature (Step 18)
-- ============================================================================

-- Scrape jobs — tracks each batch scrape run
CREATE TABLE IF NOT EXISTS scrape_jobs (
    id SERIAL PRIMARY KEY,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    total_sites INT NOT NULL DEFAULT 0,
    completed_sites INT NOT NULL DEFAULT 0,
    errors_count INT NOT NULL DEFAULT 0,
    results_summary JSONB
);

-- Raw scrape data — stores fetched HTML/JSON for each URL
CREATE TABLE IF NOT EXISTS raw_scrape_data (
    id SERIAL PRIMARY KEY,
    job_id INT REFERENCES scrape_jobs(id) ON DELETE CASCADE,
    site_id VARCHAR(50) NOT NULL,
    url TEXT NOT NULL,
    extracted_json JSONB,
    scraped_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    status VARCHAR(20) NOT NULL DEFAULT 'success',
    error_message TEXT
);

CREATE INDEX IF NOT EXISTS idx_raw_scrape_job ON raw_scrape_data(job_id);
CREATE INDEX IF NOT EXISTS idx_raw_scrape_site ON raw_scrape_data(site_id);

-- Competitions (leagues, cups, tournaments)
CREATE TABLE IF NOT EXISTS competitions (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    country VARCHAR(100),
    season VARCHAR(20),
    site_source VARCHAR(50),
    UNIQUE(name, season)
);

-- Teams
CREATE TABLE IF NOT EXISTS teams (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    short_name VARCHAR(50),
    country VARCHAR(100),
    competition_id INT REFERENCES competitions(id) ON DELETE SET NULL,
    logo_url TEXT
);

-- Players
CREATE TABLE IF NOT EXISTS players (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    team_id INT REFERENCES teams(id) ON DELETE SET NULL,
    position VARCHAR(50),
    number INT,
    nationality VARCHAR(100),
    UNIQUE(name, team_id)
);

-- Matches
CREATE TABLE IF NOT EXISTS matches (
    id SERIAL PRIMARY KEY,
    competition_id INT REFERENCES competitions(id) ON DELETE SET NULL,
    home_team_id INT REFERENCES teams(id) ON DELETE SET NULL,
    away_team_id INT REFERENCES teams(id) ON DELETE SET NULL,
    match_date TIMESTAMP WITH TIME ZONE,
    status VARCHAR(20) NOT NULL DEFAULT 'scheduled',
    home_score INT,
    away_score INT,
    venue VARCHAR(255),
    matchday INT
);

CREATE INDEX IF NOT EXISTS idx_matches_competition ON matches(competition_id);
CREATE INDEX IF NOT EXISTS idx_matches_date ON matches(match_date);

-- Match events (goals, cards, substitutions)
CREATE TABLE IF NOT EXISTS match_events (
    id SERIAL PRIMARY KEY,
    match_id INT REFERENCES matches(id) ON DELETE CASCADE,
    event_type VARCHAR(30) NOT NULL,
    minute INT,
    player_id INT REFERENCES players(id) ON DELETE SET NULL,
    team_id INT REFERENCES teams(id) ON DELETE SET NULL,
    details TEXT
);

-- Injuries
CREATE TABLE IF NOT EXISTS injuries (
    id SERIAL PRIMARY KEY,
    player_id INT REFERENCES players(id) ON DELETE SET NULL,
    team_id INT REFERENCES teams(id) ON DELETE SET NULL,
    injury_type VARCHAR(100),
    expected_return VARCHAR(100),
    reported_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    site_source VARCHAR(50)
);

-- Standings
CREATE TABLE IF NOT EXISTS standings (
    id SERIAL PRIMARY KEY,
    competition_id INT REFERENCES competitions(id) ON DELETE CASCADE,
    team_id INT REFERENCES teams(id) ON DELETE CASCADE,
    position INT,
    played INT NOT NULL DEFAULT 0,
    won INT NOT NULL DEFAULT 0,
    drawn INT NOT NULL DEFAULT 0,
    lost INT NOT NULL DEFAULT 0,
    goals_for INT NOT NULL DEFAULT 0,
    goals_against INT NOT NULL DEFAULT 0,
    points INT NOT NULL DEFAULT 0,
    UNIQUE(competition_id, team_id)
);

CREATE INDEX IF NOT EXISTS idx_standings_competition ON standings(competition_id);
