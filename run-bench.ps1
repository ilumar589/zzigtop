<#
.SYNOPSIS
    Run Docker-based Linux benchmarks for zzigtop server.

.DESCRIPTION
    Builds the Zig server on Alpine Linux with ReleaseFast optimizations,
    starts it alongside PostgreSQL, and runs wrk benchmarks with HTTP pipelining.

    Profiles:
      bench    — server + wrk (no database tests)
      bench-db — server + postgres + wrk (includes database tests)

.PARAMETER Profile
    Which benchmark profile to run: "bench" (default) or "bench-db".
    "bench" skips database tests; "bench-db" includes them.

.PARAMETER Duration
    Duration of each wrk test phase in seconds (default: 10).

.PARAMETER Pipeline
    HTTP pipelining depth (default: 16, same as TechEmpower).

.PARAMETER Build
    Force a fresh Docker image rebuild (default: $false).

.PARAMETER Down
    Tear down all containers and volumes, then exit.

.EXAMPLE
    .\run-bench.ps1
    .\run-bench.ps1 -Profile bench-db -Duration 15
    .\run-bench.ps1 -Down
#>

param(
    [ValidateSet("bench", "bench-db")]
    [string]$Profile = "bench",

    [int]$Duration = 10,
    [int]$Pipeline = 16,
    [switch]$Build,
    [switch]$Down
)

$ErrorActionPreference = "Stop"
$ComposeFile = Join-Path (Join-Path $PSScriptRoot "docker") "compose.yml"

function Write-Header($msg) {
    $line = "=" * 70
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "$line`n" -ForegroundColor Cyan
}

# ----- Tear down --------------------------------------------------------
if ($Down) {
    Write-Header "Tearing down all containers and volumes"
    docker compose -f $ComposeFile --profile bench --profile bench-db --profile server down -v --remove-orphans
    Write-Host "Done." -ForegroundColor Green
    exit 0
}

# ----- Pre-flight checks ------------------------------------------------
Write-Header "zzigtop Docker Benchmark"

Write-Host "Profile   : $Profile"
Write-Host "Duration  : ${Duration}s per phase"
Write-Host "Pipeline  : ${Pipeline}x depth"
Write-Host ""

# Check Docker is running
try {
    docker info 2>$null | Out-Null
} catch {
    Write-Host "ERROR: Docker is not running. Start Docker Desktop first." -ForegroundColor Red
    exit 1
}

# ----- Set environment overrides ----------------------------------------
$env:DURATION  = $Duration
$env:PIPELINE  = $Pipeline

# ----- Build & Run -------------------------------------------------------
$buildFlag = if ($Build) { "--build" } else { "" }

Write-Header "Building and starting services (profile: $Profile)"

# Start services — bench container will run and exit
$startTime = Get-Date

# Docker writes build progress to stderr which PowerShell treats as errors.
# Temporarily relax error handling for the docker compose command.
$buildArg = if ($Build) { "--build" } else { $null }
$dockerArgs = @("compose", "-f", $ComposeFile, "--profile", $Profile, "up", "--abort-on-container-exit")
if ($Build) { $dockerArgs += "--build" }

$prevPref = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& docker @dockerArgs 2>&1 | ForEach-Object {
    $line = "$_"
    if ($line -match "bench.*\|") {
        Write-Host $line -ForegroundColor Yellow
    } elseif ($line -match "error|fail|panic") {
        Write-Host $line -ForegroundColor Red
    } else {
        Write-Host $line -ForegroundColor DarkGray
    }
}
$dockerExit = $LASTEXITCODE
$ErrorActionPreference = $prevPref

$elapsed = (Get-Date) - $startTime

# ----- Summary -----------------------------------------------------------
Write-Header "Benchmark Complete"
Write-Host "Total wall time: $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor Green
if ($dockerExit -ne 0) {
    Write-Host "Docker exited with code $dockerExit (bench container finished)" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "To view server logs:  docker compose -f docker/compose.yml --profile server logs server"
Write-Host "To tear down:         .\run-bench.ps1 -Down"
Write-Host ""
