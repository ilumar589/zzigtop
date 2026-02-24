# Build & Run Script

## Prerequisites

- [Zig](https://ziglang.org/download/) installed and available on your `PATH`
- PowerShell 5.1+ (included with Windows)

## Usage

```powershell
.\run.ps1 [-Optimize <mode>] [-BuildOnly] [-Clean] [-Server] [-- <exe-args>]
```

### Parameters

| Parameter     | Description                                              | Default   |
|---------------|----------------------------------------------------------|-----------||
| `-Optimize`   | Optimization mode: `Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall` | `Debug`   |
| `-BuildOnly`  | Build without running the executable                     | off       |
| `-Clean`      | Remove build artifacts before building                   | off       |
| `-Server`     | Build and run the HTTP server instead of zzigtop       | off       |
| `<exe-args>`  | Arguments passed through to the executable               | none      |

### Examples

```powershell
# Build and run (debug, default)
.\run.ps1

# Build and run with max performance
.\run.ps1 -Optimize ReleaseFast

# Build optimized for small binary size
.\run.ps1 -Optimize ReleaseSmall

# Only build, don't run
.\run.ps1 -Optimize ReleaseFast -BuildOnly

# Clean build artifacts, then build and run
.\run.ps1 -Clean

# Clean build, optimized, without running
.\run.ps1 -Clean -Optimize ReleaseFast -BuildOnly

# Pass arguments to the executable
.\run.ps1 -Optimize ReleaseFast -- arg1 arg2

# ---- HTTP Server ----

# Build and run the HTTP server (debug, port 8080)
.\run.ps1 -Server

# Run the server with max performance
.\run.ps1 -Server -Optimize ReleaseFast

# Run the server on a custom port
.\run.ps1 -Server -Optimize ReleaseFast -- --port 3000

# Run the server without database (skip PostgreSQL)
.\run.ps1 -Server -- --no-db

# Run the server with a specific thread pool size
.\run.ps1 -Server -Optimize ReleaseFast -- --port 3000 --threads 8

# Only build the server, don't run it
.\run.ps1 -Server -BuildOnly

# Clean build, then run server
.\run.ps1 -Server -Clean -Optimize ReleaseFast
```

### Optimization Modes

| Mode            | Description                                                  |
|-----------------|--------------------------------------------------------------|
| `Debug`         | No optimizations, includes debug info (default)              |
| `ReleaseSafe`   | Optimized with runtime safety checks (bounds checking, etc.) |
| `ReleaseFast`   | Maximum performance, safety checks disabled                  |
| `ReleaseSmall`  | Optimized for smallest binary size                           |

### Output

The compiled executables are placed at:

```
zig-out\bin\zzigtop.exe         # Default zzigtop app
zig-out\bin\http_server.exe    # HTTP server
```

### Zig Build Commands (without run.ps1)

You can also use `zig build` directly:

```powershell
# Build everything
zig build

# Build and run the HTTP server
zig build run-server

# Build and run the HTTP server with max performance
zig build run-server -Doptimize=ReleaseFast
```

---

## PostgreSQL Setup (Docker)

The server's REST API (`/api/users`) requires a PostgreSQL database. A Docker Compose file is provided for easy setup.

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running

### Start PostgreSQL

```powershell
cd docker
docker compose up -d
```

This starts PostgreSQL 16 on port **5432** with:
- Database: `ziglearn`
- Username: `ziglearn`
- Password: `ziglearn`
- Seed data: 3 users (Alice, Bob, Charlie)

### Verify

```powershell
docker compose ps          # Should show "healthy"
docker compose logs        # View PostgreSQL logs
```

### Stop / Reset

```powershell
docker compose down        # Stop container (data persists in volume)
docker compose down -v     # Stop and delete volume (reset to seed data)
```

### Running Without a Database

The HTTP server works without PostgreSQL — database endpoints return `503 Service Unavailable`:

```powershell
zig build run-server -- --no-db
```

# Pass arguments (e.g. custom port and thread count)
zig build run-server -- --port 3000 --threads 8
```

---

## Running Tests

### Test Script

Use `test.ps1` for a visual test runner with color-coded output:

```powershell
# Run unit tests only (default)
powershell -ExecutionPolicy Bypass -File test.ps1

# Run unit tests with each test name listed
powershell -ExecutionPolicy Bypass -File test.ps1 -Verbose

# Run integration tests (starts server, sends real HTTP requests)
powershell -ExecutionPolicy Bypass -File test.ps1 -Integration

# Run database integration tests (requires PostgreSQL — see Docker Setup)
powershell -ExecutionPolicy Bypass -File test.ps1 -DbIntegration

# Run benchmarks (ReleaseFast, measures throughput & latency)
powershell -ExecutionPolicy Bypass -File test.ps1 -Benchmark

# Run stress benchmark (CPU & RAM profiling, generates visual HTML report)
powershell -ExecutionPolicy Bypass -File test.ps1 -Stress

# Run everything: unit + integration + db-integration + benchmark + stress
powershell -ExecutionPolicy Bypass -File test.ps1 -All

# Combine flags as needed
powershell -ExecutionPolicy Bypass -File test.ps1 -Integration -Verbose
powershell -ExecutionPolicy Bypass -File test.ps1 -Integration -DbIntegration
```

### Test Script Parameters

| Parameter       | Description                                                    |
|-----------------|----------------------------------------------------------------|
| `-Verbose`        | List every individual test with `[PASS]` / `[FAIL]` markers     |
| `-Integration`    | Run integration tests (end-to-end HTTP over TCP)                 |
| `-DbIntegration`  | Run database integration tests (requires PostgreSQL via Docker)  |
| `-Benchmark`      | Run performance benchmarks (built with `-Doptimize=ReleaseFast`) |
| `-Stress`         | Run stress benchmark with CPU & RAM profiling (generates visual HTML report) |
| `-All`            | Run all phases: unit, integration, db-integration, benchmark, and stress |

With no flags, only unit tests are run. Use `-DbIntegration` only when PostgreSQL is running.

### What Each Phase Tests

| Phase         | Count | What it covers |
|---------------|-------|----------------|
| **Unit**      | 64    | Parser, router, request, response — pure logic, no I/O |
| **Integration** | 16  | Full HTTP request/response cycle over real TCP sockets |
| **DB Integration** | 10 | CRUD, constraints, SQL injection safety (requires PostgreSQL) |
| **Benchmark** | 6     | Throughput & latency: conn-per-req + keep-alive (ReleaseFast) |
| **Stress**    | —     | CPU & RAM profiling under heavy load, visual HTML report |

### Zig Build Commands (without test.ps1)

```powershell
# Run unit tests
zig build test

# Run unit tests with summary
zig build test --summary all

# Run integration tests (starts server, sends HTTP requests, validates responses)
zig build integration-test

# Run database integration tests (requires PostgreSQL — see Docker Setup above)
zig build db-integration-test

# Run benchmarks (use ReleaseFast for meaningful numbers)
zig build benchmark -Doptimize=ReleaseFast
```

---

## Stress Benchmark (CPU & RAM Profiling)

The stress benchmark launches the HTTP server under increasing concurrency,
samples OS-level CPU and memory metrics every 250 ms, and generates an
interactive HTML report with Chart.js graphs.

### Quick Start

```powershell
# Run via the test runner
powershell -ExecutionPolicy Bypass -File test.ps1 -Stress

# Or run the standalone script directly
powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1
```

### Parameters

| Parameter          | Description                                      | Default               |
|--------------------|--------------------------------------------------|-----------------------|
| `-Port`            | Port for the benchmark server                    | `18095`               |
| `-Duration`        | Total load duration in seconds                   | `30`                  |
| `-MaxConcurrency`  | Peak number of concurrent connections            | `200`                 |
| `-SkipBuild`       | Skip the `zig build` step (use existing binary)  | off                   |
| `-ReportPath`      | Output file name for the HTML report             | `benchmark-report.html` |

### Examples

```powershell
# Default: 30 s, up to 200 concurrent connections
powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1

# Longer run with higher concurrency
powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1 -Duration 60 -MaxConcurrency 500

# Quick smoke test
powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1 -Duration 10 -MaxConcurrency 50

# Custom port, skip rebuild
powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1 -Port 9090 -SkipBuild
```

### Output

The report is saved to `benchmark-report.html` and opened automatically in your
default browser. It includes:

- **Summary cards** — total requests, errors, peak/avg RAM, peak/avg CPU, peak RPS
- **Memory chart** — working set and private bytes over time
- **CPU chart** — processor usage percentage over time
- **Throughput chart** — requests/sec with concurrency overlay
- **Threads & handles chart** — OS thread and handle count over time
- **Combined overview** — normalized CPU, RAM, and RPS on a single chart
