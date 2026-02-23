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
