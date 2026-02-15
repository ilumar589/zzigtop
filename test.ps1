#!/usr/bin/env pwsh
# ------------------------------------------------------------------
#  Zig Test Runner - Visual Feedback
#  Usage: powershell -ExecutionPolicy Bypass -File test.ps1
#         powershell -ExecutionPolicy Bypass -File test.ps1 -Verbose
# ------------------------------------------------------------------

param(
    [switch]$Verbose
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

Write-Header "Running Zig Tests"

# -- Run zig test on root module ------------------------------------
Write-Host "  Compiling..." -ForegroundColor Yellow -NoNewline

$output = & zig test src/root.zig 2>&1 | Out-String
$exitCode = $LASTEXITCODE

# Clear the "Compiling..." line
Write-Host "`r  Compiling... done.          " -ForegroundColor DarkGray

# -- Parse Results --------------------------------------------------────
$passed  = 0
$failed  = 0
$skipped = 0
$failedTests  = @()
$allTests     = @()

foreach ($rawLine in ($output -split "`n")) {
    $l = $rawLine.Trim()

    # Match lines like: 4/62 http.parser.test.findByte - basic...OK
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
    # Match summary line: 61 passed; 0 skipped; 1 failed.
    elseif ($l -match '(\d+) passed.*?(\d+) skipped.*?(\d+) failed') {
        # use these as authoritative counts
        $passed  = [int]$Matches[1]
        $skipped = [int]$Matches[2]
        $failed  = [int]$Matches[3]
    }
    # Match "All N tests passed."
    elseif ($l -match 'All (\d+) tests passed') {
        $passed = [int]$Matches[1]
        $failed = 0
    }
}

$total = $passed + $failed + $skipped
$sw.Stop()
$elapsed = $sw.Elapsed

# -- Summary -------------------------------------------------------────
Write-Host ""
Write-Host "  $line" -ForegroundColor DarkCyan

if ($failed -eq 0 -and $exitCode -eq 0) {
    Write-Host ""
    Write-Host "  $check ALL $total TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  $cross $failed / $total TESTS FAILED" -ForegroundColor Red

    if ($failedTests.Count -gt 0) {
        Write-Host ""
        Write-Host "  Failed tests:" -ForegroundColor Red
        foreach ($ft in $failedTests) {
            Write-Host "    $cross $ft" -ForegroundColor Red
        }
    }

    # Show compiler/error output for failures
    $errorLines = ($output -split "`n") | Where-Object {
        $_ -match 'error:|FAIL|expected .+, found' 
    } | Select-Object -First 10
    if ($errorLines.Count -gt 0) {
        Write-Host ""
        Write-Host "  Error details:" -ForegroundColor Yellow
        foreach ($el in $errorLines) {
            Write-Host "    $el" -ForegroundColor DarkYellow
        }
    }
}

# -- Stats Bar ------------------------------------------------------────
Write-Host ""
$statsLine = "  $check $passed passed"
if ($skipped -gt 0) { $statsLine += "   $bullet $skipped skipped" }
if ($failed  -gt 0) { $statsLine += "   $cross $failed failed" }
$statsLine += "   $bullet $($elapsed.TotalSeconds.ToString('F2'))s"

if ($failed -eq 0) {
    Write-Host $statsLine -ForegroundColor Green
} else {
    Write-Host $statsLine -ForegroundColor Yellow
}

Write-Host "  $line" -ForegroundColor DarkCyan
Write-Host ""

# -- Exit Code ------------------------------------------------------────
exit $exitCode
