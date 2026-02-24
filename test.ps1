#!/usr/bin/env pwsh
# ------------------------------------------------------------------
#  Zig Test Runner - Visual Feedback
#  Usage: powershell -ExecutionPolicy Bypass -File test.ps1
#         powershell -ExecutionPolicy Bypass -File test.ps1 -Verbose
#         powershell -ExecutionPolicy Bypass -File test.ps1 -Integration
#         powershell -ExecutionPolicy Bypass -File test.ps1 -DbIntegration
#         powershell -ExecutionPolicy Bypass -File test.ps1 -Benchmark
#         powershell -ExecutionPolicy Bypass -File test.ps1 -Stress
#         powershell -ExecutionPolicy Bypass -File test.ps1 -All
# ------------------------------------------------------------------

param(
    [switch]$Verbose,
    [switch]$Integration,
    [switch]$DbIntegration,
    [switch]$Benchmark,
    [switch]$Stress,
    [switch]$All
)

$ErrorActionPreference = "Continue"

# -- Colors & Symbols -----------------------------------------------
$check  = "[PASS]"
$cross  = "[FAIL]"
$bullet = "*"
$line   = "-" * 60

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host "  $bullet $Text" -ForegroundColor Cyan
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Pass {
    param([string]$Text)
    Write-Host "    $check $Text" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Text)
    Write-Host "    $cross $Text" -ForegroundColor Red
}

function Write-Info {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor DarkGray
}

# -- Timer ---------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# -- Determine what to run -----------------------------------------
$runUnit            = (-not $Integration -and -not $DbIntegration -and -not $Benchmark -and -not $Stress) -or $All
$runIntegration     = $Integration -or $All
$runDbIntegration   = $DbIntegration -or $All
$runBenchmark       = $Benchmark -or $All
$runStress          = $Stress -or $All

$globalExit = 0

# ===================================================================
#  PHASE 1: Unit Tests
# ===================================================================
if ($runUnit) {
    Write-Header "Unit Tests  (zig build test)"

    Write-Host "  Compiling..." -ForegroundColor Yellow -NoNewline

    $output = & zig build test --summary all 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    Write-Host "`r  Compiling... done.          " -ForegroundColor DarkGray

    # -- Parse Results ------------------------------------------------
    $passed  = 0
    $failed  = 0
    $skipped = 0
    $failedTests  = @()
    $allTests     = @()

    foreach ($rawLine in ($output -split "`n")) {
        $l = $rawLine.Trim()

        if ($l -match '^\d+/\d+\s+(.+)\.\.\.(OK|FAIL.*)$') {
            $testName   = $Matches[1]
            $testResult = $Matches[2]

            if ($testResult -eq "OK") {
                $passed++
                if ($Verbose) { Write-Pass $testName }
            } else {
                $failed++
                $failedTests += $testName
                Write-Fail $testName
            }
            $allTests += @{ Name = $testName; Result = $testResult }
        }
        elseif ($l -match '(\d+) passed.*?(\d+) skipped.*?(\d+) failed') {
            $passed  = [int]$Matches[1]
            $skipped = [int]$Matches[2]
            $failed  = [int]$Matches[3]
        }
        elseif ($l -match 'All (\d+) tests passed') {
            $passed = [int]$Matches[1]
            $failed = 0
        }
        # Match "Build Summary: ... 64/64 tests passed"
        elseif ($l -match '(\d+)/(\d+) tests passed') {
            $passed = [int]$Matches[1]
            $total  = [int]$Matches[2]
            $failed = $total - $passed
        }
    }

    $total = $passed + $failed + $skipped

    if ($failed -eq 0 -and $exitCode -eq 0) {
        Write-Host ""
        Write-Host "    $check ALL $total UNIT TESTS PASSED" -ForegroundColor Green
    } else {
        $globalExit = 1
        Write-Host ""
        Write-Host "    $cross $failed / $total UNIT TESTS FAILED" -ForegroundColor Red

        if ($failedTests.Count -gt 0) {
            Write-Host ""
            Write-Host "    Failed tests:" -ForegroundColor Red
            foreach ($ft in $failedTests) {
                Write-Host "      $cross $ft" -ForegroundColor Red
            }
        }

        $errorLines = ($output -split "`n") | Where-Object {
            $_ -match 'error:|FAIL|expected .+, found'
        } | Select-Object -First 10
        if ($errorLines.Count -gt 0) {
            Write-Host ""
            Write-Host "    Error details:" -ForegroundColor Yellow
            foreach ($el in $errorLines) {
                Write-Host "      $el" -ForegroundColor DarkYellow
            }
        }
    }

    $statsLine = "    $check $passed passed"
    if ($skipped -gt 0) { $statsLine += "   $bullet $skipped skipped" }
    if ($failed  -gt 0) { $statsLine += "   $cross $failed failed" }

    if ($failed -eq 0) {
        Write-Host $statsLine -ForegroundColor Green
    } else {
        Write-Host $statsLine -ForegroundColor Yellow
    }
}

# ===================================================================
#  PHASE 2: Integration Tests
# ===================================================================
if ($runIntegration) {
    Write-Header "Integration Tests  (zig build integration-test)"

    Write-Host "  Building & running..." -ForegroundColor Yellow -NoNewline

    $intOutput = & zig build integration-test 2>&1 | Out-String
    $intExit   = $LASTEXITCODE

    Write-Host "`r  Building & running... done.          " -ForegroundColor DarkGray

    # Parse lines like: PASS <name> / FAIL <name>
    $intPassed = 0
    $intFailed = 0
    $intFailedTests = @()

    foreach ($rawLine in ($intOutput -split "`n")) {
        $l = $rawLine.Trim()

        if ($l -match 'PASS\s+(.+)$') {
            $intPassed++
            if ($Verbose) { Write-Pass $Matches[1] }
        }
        elseif ($l -match 'FAIL\s+(.+)$') {
            $intFailed++
            $intFailedTests += $Matches[1]
            Write-Fail $Matches[1]
        }
        elseif ($l -match 'Results:\s*(\d+)/(\d+)\s+passed,\s*(\d+)\s+failed') {
            $intPassed = [int]$Matches[1]
            $intFailed = [int]$Matches[3]
        }
    }

    $intTotal = $intPassed + $intFailed

    if ($intFailed -eq 0 -and $intExit -eq 0 -and $intTotal -gt 0) {
        Write-Host ""
        Write-Host "    $check ALL $intTotal INTEGRATION TESTS PASSED" -ForegroundColor Green
        Write-Host "    $check $intPassed passed" -ForegroundColor Green
    } elseif ($intTotal -eq 0) {
        $globalExit = 1
        Write-Host ""
        Write-Host "    $cross BUILD / RUN FAILED (no test results)" -ForegroundColor Red
        # Show first few output lines for diagnostics
        $diagLines = ($intOutput -split "`n") | Select-Object -First 10
        foreach ($dl in $diagLines) {
            Write-Info $dl.Trim()
        }
    } else {
        $globalExit = 1
        Write-Host ""
        Write-Host "    $cross $intFailed / $intTotal INTEGRATION TESTS FAILED" -ForegroundColor Red
        if ($intFailedTests.Count -gt 0) {
            foreach ($ft in $intFailedTests) {
                Write-Host "      $cross $ft" -ForegroundColor Red
            }
        }
    }
}

# ===================================================================
#  PHASE 3: Database Integration Tests (requires PostgreSQL)
# ===================================================================
if ($runDbIntegration) {
    Write-Header "DB Integration Tests  (zig build db-integration-test)"

    Write-Host "  Building & running..." -ForegroundColor Yellow -NoNewline

    $dbOutput = & zig build db-integration-test 2>&1 | Out-String
    $dbExit   = $LASTEXITCODE

    Write-Host "`r  Building & running... done.          " -ForegroundColor DarkGray

    # Parse lines like: PASS <name> / FAIL <name>
    $dbPassed = 0
    $dbFailed = 0
    $dbFailedTests = @()

    foreach ($rawLine in ($dbOutput -split "`n")) {
        $l = $rawLine.Trim()

        if ($l -match 'PASS\s+(.+)$') {
            $dbPassed++
            if ($Verbose) { Write-Pass $Matches[1] }
        }
        elseif ($l -match 'FAIL\s+(.+)$') {
            $dbFailed++
            $dbFailedTests += $Matches[1]
            Write-Fail $Matches[1]
        }
        elseif ($l -match 'Results:\s*(\d+)/(\d+)\s+passed,\s*(\d+)\s+failed') {
            $dbPassed = [int]$Matches[1]
            $dbFailed = [int]$Matches[3]
        }
    }

    $dbTotal = $dbPassed + $dbFailed

    if ($dbFailed -eq 0 -and $dbExit -eq 0 -and $dbTotal -gt 0) {
        Write-Host ""
        Write-Host "    $check ALL $dbTotal DB INTEGRATION TESTS PASSED" -ForegroundColor Green
        Write-Host "    $check $dbPassed passed" -ForegroundColor Green
    } elseif ($dbTotal -eq 0) {
        $globalExit = 1
        Write-Host ""
        Write-Host "    $cross BUILD / RUN FAILED (no test results)" -ForegroundColor Red
        Write-Host "    Make sure PostgreSQL is running: cd docker && docker compose up -d" -ForegroundColor Yellow
        $diagLines = ($dbOutput -split "`n") | Select-Object -First 10
        foreach ($dl in $diagLines) {
            Write-Info $dl.Trim()
        }
    } else {
        $globalExit = 1
        Write-Host ""
        Write-Host "    $cross $dbFailed / $dbTotal DB INTEGRATION TESTS FAILED" -ForegroundColor Red
        if ($dbFailedTests.Count -gt 0) {
            foreach ($ft in $dbFailedTests) {
                Write-Host "      $cross $ft" -ForegroundColor Red
            }
        }
    }
}

# ===================================================================
#  PHASE 4: Benchmark (optional, not a pass/fail gate)
# ===================================================================
if ($runBenchmark) {
    Write-Header "Benchmark  (zig build benchmark -Doptimize=ReleaseFast)"

    Write-Host "  Building (ReleaseFast)..." -ForegroundColor Yellow -NoNewline

    $benchOutput = & zig build benchmark -Doptimize=ReleaseFast 2>&1 | Out-String
    $benchExit   = $LASTEXITCODE

    Write-Host "`r  Building (ReleaseFast)... done.          " -ForegroundColor DarkGray

    # Display benchmark results
    $inResults = $false
    foreach ($rawLine in ($benchOutput -split "`n")) {
        $l = $rawLine.TrimEnd()

        # Skip box-drawing / empty / non-result lines
        if ($l -match '^\s*$') { continue }
        if ($l.Length -gt 0 -and [int]$l[0] -gt 127) { continue }

        # Benchmark name headers
        if ($l -match '^\s{2}GET |^\s{2}POST ') {
            Write-Host ""
            Write-Host "    $bullet $($l.Trim())" -ForegroundColor Cyan
            $inResults = $false
            continue
        }

        if ($l -match 'Throughput:|Latency:|Requests:|Wall time:') {
            $inResults = $true
            $trimmed = $l.Trim()

            if ($trimmed -match '^Throughput:\s*(.+)$') {
                Write-Host "      Throughput: " -NoNewline -ForegroundColor DarkGray
                Write-Host $Matches[1] -ForegroundColor Green
            }
            elseif ($trimmed -match '^Latency:\s*(.+)$') {
                Write-Host "      Latency:    " -NoNewline -ForegroundColor DarkGray
                Write-Host $Matches[1] -ForegroundColor Yellow
            }
            elseif ($trimmed -match '^Requests:\s*(.+)$') {
                Write-Host "      Requests:   " -NoNewline -ForegroundColor DarkGray
                Write-Host $Matches[1] -ForegroundColor White
            }
            elseif ($trimmed -match '^Wall time:\s*(.+)$') {
                Write-Host "      Wall time:  " -NoNewline -ForegroundColor DarkGray
                Write-Host $Matches[1] -ForegroundColor White
            }
            continue
        }
    }

    if ($benchExit -ne 0 -and $benchOutput -notmatch 'Throughput:') {
        Write-Host ""
        Write-Host "    $cross BENCHMARK FAILED TO RUN" -ForegroundColor Red
        $diagLines = ($benchOutput -split "`n") | Select-Object -First 8
        foreach ($dl in $diagLines) {
            Write-Info $dl.Trim()
        }
    } else {
        Write-Host ""
        Write-Host "    $check Benchmark complete" -ForegroundColor Green
    }
}

# ===================================================================
#  PHASE 5: Stress Benchmark (CPU & RAM under load, visual report)
# ===================================================================
if ($runStress) {
    Write-Header "Stress Benchmark  (CPU & RAM profiling)"

    Write-Host "  Launching stress-benchmark.ps1..." -ForegroundColor Yellow

    $stressScript = Join-Path $PSScriptRoot "stress-benchmark.ps1"
    if (Test-Path $stressScript) {
        & powershell -ExecutionPolicy Bypass -File $stressScript
        $stressExit = $LASTEXITCODE

        if ($stressExit -ne 0) {
            $globalExit = 1
            Write-Host ""
            Write-Host "    $cross STRESS BENCHMARK FAILED" -ForegroundColor Red
        } else {
            Write-Host ""
            Write-Host "    $check Stress benchmark complete (report: benchmark-report.html)" -ForegroundColor Green
        }
    } else {
        Write-Host "    $cross stress-benchmark.ps1 not found" -ForegroundColor Red
    }
}

$sw.Stop()
$elapsed = $sw.Elapsed

# ===================================================================
#  GRAND SUMMARY
# ===================================================================
Write-Host ""
Write-Host "  $line" -ForegroundColor DarkCyan

$phases = @()
if ($runUnit)            { $phases += "unit" }
if ($runIntegration)     { $phases += "integration" }
if ($runDbIntegration)   { $phases += "db-integration" }
if ($runBenchmark)       { $phases += "benchmark" }
if ($runStress)          { $phases += "stress" }

$phasesStr = $phases -join " + "

if ($globalExit -eq 0) {
    Write-Host "  $check ALL PHASES PASSED ($phasesStr)" -ForegroundColor Green
} else {
    Write-Host "  $cross SOME PHASES FAILED ($phasesStr)" -ForegroundColor Red
}

Write-Host "  Total time: $($elapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor DarkGray
Write-Host "  $line" -ForegroundColor DarkCyan
Write-Host ""

exit $globalExit
