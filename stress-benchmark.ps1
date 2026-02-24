#!/usr/bin/env pwsh
# ------------------------------------------------------------------
#  Stress Benchmark - CPU and RAM under heavy load
#
#  Builds the HTTP server (ReleaseFast), hammers it with increasing
#  concurrency, samples process CPU% and Working-Set every 250 ms,
#  and emits an interactive HTML report (Chart.js) to:
#      benchmark-report.html
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1
#    powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1 -Port 9090
#    powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1 -Duration 30
#    powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1 -MaxConcurrency 500
#    powershell -ExecutionPolicy Bypass -File stress-benchmark.ps1 -SkipBuild
# ------------------------------------------------------------------

param(
    [int]$Port = 18095,
    [int]$Duration = 30,
    [int]$MaxConcurrency = 200,
    [switch]$SkipBuild,
    [string]$ReportPath = "benchmark-report.html"
)

$ErrorActionPreference = "Continue"
$ProjectRoot = $PSScriptRoot

# -- Styling helpers -------------------------------------------------
$bar   = "=" * 60

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "  $bar" -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "  $bar" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Phase {
    param([string]$Text)
    Write-Host "  >> $Text" -ForegroundColor Yellow
}

function Write-Stat {
    param([string]$Label, [string]$Value)
    Write-Host "     $Label : " -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

# -- 1. Build -------------------------------------------------------
Write-Banner "Stress Benchmark - CPU and RAM Profiler"

$serverExe = Join-Path $ProjectRoot "zig-out\bin\http_server.exe"

if (-not $SkipBuild) {
    Write-Phase "Building HTTP server (ReleaseFast)..."
    Push-Location $ProjectRoot
    & zig build -Doptimize=ReleaseFast 2>&1 | Out-Null
    Pop-Location
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAIL] Build failed (exit $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] Build succeeded" -ForegroundColor Green
}

if (-not (Test-Path $serverExe)) {
    Write-Host "  [FAIL] Server binary not found: $serverExe" -ForegroundColor Red
    exit 1
}

# -- 2. Launch server -----------------------------------------------
Write-Phase "Starting server on port $Port..."

$serverProc = Start-Process -FilePath $serverExe `
    -ArgumentList "--port", $Port, "--no-db", "--no-static", "--idle-timeout", "0", "--request-timeout", "0", "--backlog", "1024" `
    -PassThru -WindowStyle Hidden

Start-Sleep -Seconds 1

if ($serverProc.HasExited) {
    Write-Host "  [FAIL] Server exited immediately" -ForegroundColor Red
    exit 1
}

Write-Host "  [OK] Server running (PID $($serverProc.Id))" -ForegroundColor Green

# -- 3. Metrics collector (background job) --------------------------
Write-Phase "Starting metrics collector (250 ms interval)..."

$metricsJob = Start-Job -ArgumentList $serverProc.Id -ScriptBlock {
    param($procId)
    $samples = [System.Collections.ArrayList]::new()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prevCpu = $null
    $prevTime = $null

    while ($true) {
        try {
            $proc = Get-Process -Id $procId -ErrorAction Stop
            $now = $sw.Elapsed.TotalSeconds

            # CPU% approximation (delta processor time / delta wall time)
            $cpuTime = $proc.TotalProcessorTime.TotalMilliseconds
            $cpuPercent = 0.0
            if ($null -ne $prevCpu -and $null -ne $prevTime) {
                $dt = ($now - $prevTime)
                if ($dt -gt 0) {
                    $cpuPercent = (($cpuTime - $prevCpu) / ($dt * 1000.0)) * 100.0
                    # Clamp to [0, numProcs * 100]
                    $numProcs = [Environment]::ProcessorCount
                    if ($cpuPercent -lt 0) { $cpuPercent = 0 }
                    if ($cpuPercent -gt ($numProcs * 100)) { $cpuPercent = $numProcs * 100 }
                }
            }
            $prevCpu  = $cpuTime
            $prevTime = $now

            [void]$samples.Add(@{
                t           = [math]::Round($now, 3)
                cpuPercent  = [math]::Round($cpuPercent, 2)
                ramMB       = [math]::Round($proc.WorkingSet64 / 1MB, 2)
                privateMB   = [math]::Round($proc.PrivateMemorySize64 / 1MB, 2)
                threads     = $proc.Threads.Count
                handles     = $proc.HandleCount
            })
        } catch {
            # Process gone - stop collecting
            break
        }
        Start-Sleep -Milliseconds 250
    }

    return $samples
}

# Let the collector take a few idle samples
Start-Sleep -Seconds 1

# -- 4. Load generation ---------------------------------------------

# Concurrency ramp schedule: [concurrency, durationSeconds]
$phases = @()
$rampSteps = @(10, 25, 50, 100)
if ($MaxConcurrency -ge 200)  { $rampSteps += 200 }
if ($MaxConcurrency -ge 500)  { $rampSteps += 500 }
if ($MaxConcurrency -ge 1000) { $rampSteps += 1000 }

# Calculate phase durations (distribute evenly, sustained at peak gets extra)
$rampPhaseDuration = [math]::Max(3, [int]($Duration / ($rampSteps.Count + 2)))
$sustainDuration   = $Duration - ($rampPhaseDuration * $rampSteps.Count)
if ($sustainDuration -lt 3) { $sustainDuration = 3 }

foreach ($c in $rampSteps) {
    if ($c -le $MaxConcurrency) {
        $phases += @{ Concurrency = $c; Seconds = $rampPhaseDuration }
    }
}
# Sustained peak
$phases += @{ Concurrency = $MaxConcurrency; Seconds = $sustainDuration }

$baseUrl = "http://127.0.0.1:$Port"
# Only hit endpoints that actually exist and are fast (no file I/O).
# /json was removed — it never existed and returned 404 (counted as error).
# / was removed — it serves index.html via file I/O (not a fair CPU benchmark).
$endpoints = @("/health", "/hello/bench", "/metrics", "/search?q=stress&page=1")

# Throughput tracking
$throughputSamples = [System.Collections.ArrayList]::new()
$totalRequests = 0
$totalErrors   = 0
$errorTimeouts = 0
$errorConnRefused = 0
$errorHttpStatus = 0

Write-Phase "Starting load generation ($Duration s, max concurrency $MaxConcurrency)..."
Write-Host ""

Add-Type -AssemblyName System.Net.Http

# --- Create a SINGLE HttpClient for the entire benchmark ---
$globalHandler = [System.Net.Http.HttpClientHandler]::new()
$globalHandler.MaxConnectionsPerServer = [math]::Max($MaxConcurrency, 512)
$globalHandler.UseProxy = $false
$globalClient = [System.Net.Http.HttpClient]::new($globalHandler)
$globalClient.Timeout = [TimeSpan]::FromSeconds(3)
# Connection: close — prevents thread starvation on the Windows threaded backend.
# With keep-alive, idle connections hold server threads in receiveHead() waiting for
# the next request. At 200 concurrency with only ~16 OS threads, nearly all connections
# get stuck. Connection: close frees the server thread immediately after each response,
# allowing the thread pool to service the next request.
$globalClient.DefaultRequestHeaders.ConnectionClose = $true

# --- Warmup: prime the connection pool before measurement ---
Write-Phase "Warmup (20 sequential requests)..."
for ($w = 0; $w -lt 20; $w++) {
    $ep = $endpoints[$w % $endpoints.Count]
    try {
        $resp = $globalClient.GetAsync("$baseUrl$ep").Result
        if ($null -ne $resp) {
            try { [void]$resp.Content.ReadAsByteArrayAsync().Result } catch {}
            $resp.Dispose()
        }
    } catch {}
}
Write-Host "  [OK] Warmup complete" -ForegroundColor Green
Write-Host ""

# Start the global clock AFTER warmup
$globalSw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($phase in $phases) {
    $conc = $phase.Concurrency
    $secs = $phase.Seconds

    Write-Host "  [$([math]::Round($globalSw.Elapsed.TotalSeconds, 1))s] " -NoNewline -ForegroundColor DarkGray
    Write-Host "Concurrency: $conc " -NoNewline -ForegroundColor Cyan
    Write-Host "for ${secs}s" -ForegroundColor DarkGray

    $phaseEnd = [System.Diagnostics.Stopwatch]::StartNew()
    $phaseRequests = 0
    $phaseErrors   = 0

    # Sampling interval for throughput (1 second buckets)
    $lastSampleTime = $globalSw.Elapsed.TotalSeconds
    $sampleRequests = 0

    # --- Sliding window: maintain exactly $conc requests in flight ---
    # Instead of batch-and-wait (fire N, WaitAll, repeat), we use WaitAny:
    # as soon as ONE request completes, we immediately fire a replacement.
    # This keeps the pipeline fully saturated with zero dead time.
    $reqIdx = 0
    $activeTasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task[System.Net.Http.HttpResponseMessage]]'

    # Seed the initial batch
    for ($i = 0; $i -lt $conc; $i++) {
        $ep = $endpoints[$reqIdx % $endpoints.Count]
        $reqIdx++
        $activeTasks.Add($globalClient.GetAsync("$baseUrl$ep"))
    }

    while ($phaseEnd.Elapsed.TotalSeconds -lt $secs) {
        # Wait for ANY task to complete (not all — this is the key difference)
        $completedIdx = -1
        try {
            $completedIdx = [System.Threading.Tasks.Task]::WaitAny($activeTasks.ToArray(), 5000)
        } catch {}

        if ($completedIdx -eq -1) {
            # All tasks timed out at WaitAny level — cancel and restart
            for ($di = 0; $di -lt $activeTasks.Count; $di++) {
                $phaseErrors++
                $errorTimeouts++
                try { $activeTasks[$di].Dispose() } catch {}
            }
            $activeTasks.Clear()
            for ($i = 0; $i -lt $conc; $i++) {
                $ep = $endpoints[$reqIdx % $endpoints.Count]
                $reqIdx++
                $activeTasks.Add($globalClient.GetAsync("$baseUrl$ep"))
            }
            continue
        }

        # Process the completed task
        $task = $activeTasks[$completedIdx]
        if ($task.Status -eq "RanToCompletion" -and $null -ne $task.Result) {
            try { [void]$task.Result.Content.ReadAsByteArrayAsync().Result } catch {}
            if ($task.Result.IsSuccessStatusCode) {
                $phaseRequests++
                $sampleRequests++
            } else {
                $phaseErrors++
                $errorHttpStatus++
            }
            $task.Result.Dispose()
        } else {
            $phaseErrors++
            # Categorize the error
            if ($task.Status -eq "Faulted" -and $null -ne $task.Exception) {
                $innerMsg = $task.Exception.InnerException.Message
                if ($innerMsg -match "timed? ?out|TaskCanceled") {
                    $errorTimeouts++
                } else {
                    $errorConnRefused++
                }
            } else {
                $errorTimeouts++
            }
        }
        $task.Dispose()

        # Immediately replace with a new request (keeps pipeline full)
        $ep = $endpoints[$reqIdx % $endpoints.Count]
        $reqIdx++
        $activeTasks[$completedIdx] = $globalClient.GetAsync("$baseUrl$ep")

        # Record throughput sample every ~1 second
        $now = $globalSw.Elapsed.TotalSeconds
        if (($now - $lastSampleTime) -ge 1.0) {
            $rps = $sampleRequests / ($now - $lastSampleTime)
            [void]$throughputSamples.Add(@{
                t           = [math]::Round($now, 2)
                rps         = [math]::Round($rps, 1)
                concurrency = $conc
            })
            $sampleRequests = 0
            $lastSampleTime = $now
        }
    }

    # Drain remaining active tasks
    try { [void][System.Threading.Tasks.Task]::WaitAll($activeTasks.ToArray(), 3000) } catch {}
    foreach ($task in $activeTasks) {
        if ($task.IsCompleted -and $task.Status -eq "RanToCompletion" -and $null -ne $task.Result) {
            try { [void]$task.Result.Content.ReadAsByteArrayAsync().Result } catch {}
            if ($task.Result.IsSuccessStatusCode) {
                $phaseRequests++
                $sampleRequests++
            } else {
                $phaseErrors++
                $errorHttpStatus++
            }
            $task.Result.Dispose()
        }
        if ($task.IsCompleted) { $task.Dispose() }
    }

    # Flush the final throughput bucket for this phase
    if ($sampleRequests -gt 0) {
        $now = $globalSw.Elapsed.TotalSeconds
        $dt = $now - $lastSampleTime
        if ($dt -gt 0.1) {
            $rps = $sampleRequests / $dt
            [void]$throughputSamples.Add(@{
                t           = [math]::Round($now, 2)
                rps         = [math]::Round($rps, 1)
                concurrency = $conc
            })
        }
    }

    $totalRequests += $phaseRequests
    $totalErrors   += $phaseErrors
}

# Clean up the shared HttpClient
$globalClient.Dispose()
$globalHandler.Dispose()

$globalSw.Stop()
$totalWallSecs = $globalSw.Elapsed.TotalSeconds

Write-Host ""
Write-Phase "Load generation complete."

# -- 5. Cooldown - let the collector capture post-load metrics ---
Write-Phase "Cooldown (2 s)..."
Start-Sleep -Seconds 2

# -- 6. Stop server and collect metrics ---------------------------
Write-Phase "Stopping server..."
try { $serverProc | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 1

# Receive metrics from background job
$metricsSamples = Receive-Job -Job $metricsJob -Wait -AutoRemoveJob

if ($null -eq $metricsSamples) { $metricsSamples = @() }

Write-Host "  [OK] Collected $($metricsSamples.Count) metric samples" -ForegroundColor Green
Write-Host "  [OK] Collected $($throughputSamples.Count) throughput samples" -ForegroundColor Green

# -- 7. Compute summary stats ---------------------------------------
$peakRamMB     = ($metricsSamples | ForEach-Object { $_.ramMB })     | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
$avgRamMB      = ($metricsSamples | ForEach-Object { $_.ramMB })     | Measure-Object -Average | Select-Object -ExpandProperty Average
$peakCpu       = ($metricsSamples | ForEach-Object { $_.cpuPercent })  | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
$avgCpu        = ($metricsSamples | ForEach-Object { $_.cpuPercent })  | Measure-Object -Average | Select-Object -ExpandProperty Average
$peakPrivateMB = ($metricsSamples | ForEach-Object { $_.privateMB })   | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
$peakThreads   = ($metricsSamples | ForEach-Object { $_.threads })     | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
$avgRps        = if ($totalWallSecs -gt 0) { [math]::Round($totalRequests / $totalWallSecs, 1) } else { 0 }
$peakRps       = ($throughputSamples | ForEach-Object { $_.rps })      | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum

Write-Host ""
Write-Banner "Summary"
Write-Stat "Total requests" "$totalRequests ($totalErrors errors)"
if ($totalErrors -gt 0) {
    Write-Stat "  Timeouts"    "$errorTimeouts"
    Write-Stat "  Conn errors" "$errorConnRefused"
    Write-Stat "  HTTP errors" "$errorHttpStatus"
}
Write-Stat "Wall time"      "$([math]::Round($totalWallSecs, 2)) s"
Write-Stat "Avg throughput" "$avgRps req/s"
Write-Stat "Peak throughput" "$([math]::Round($peakRps, 1)) req/s"
Write-Stat "Peak RAM"       "$([math]::Round($peakRamMB, 2)) MB (working set)"
Write-Stat "Avg RAM"        "$([math]::Round($avgRamMB, 2)) MB"
Write-Stat "Peak Private"   "$([math]::Round($peakPrivateMB, 2)) MB"
Write-Stat "Peak CPU"       "$([math]::Round($peakCpu, 1)) %"
Write-Stat "Avg CPU"        "$([math]::Round($avgCpu, 1)) %"
Write-Stat "Peak threads"   "$peakThreads"

# -- 8. Generate JSON data ------------------------------------------

# Convert samples to JSON-safe arrays
$metricsJson = $metricsSamples | ForEach-Object {
    "{""t"":$($_.t),""cpu"":$($_.cpuPercent),""ram"":$($_.ramMB),""priv"":$($_.privateMB),""threads"":$($_.threads),""handles"":$($_.handles)}"
}
$metricsJsonStr = "[" + ($metricsJson -join ",") + "]"

$throughputJson = $throughputSamples | ForEach-Object {
    "{""t"":$($_.t),""rps"":$($_.rps),""conc"":$($_.concurrency)}"
}
$throughputJsonStr = "[" + ($throughputJson -join ",") + "]"

$summaryJson = @"
{
    "totalRequests": $totalRequests,
    "totalErrors": $totalErrors,
    "errorTimeouts": $errorTimeouts,
    "errorConnRefused": $errorConnRefused,
    "errorHttpStatus": $errorHttpStatus,
    "wallTimeSec": $([math]::Round($totalWallSecs, 2)),
    "avgRps": $avgRps,
    "peakRps": $([math]::Round($peakRps, 1)),
    "peakRamMB": $([math]::Round($peakRamMB, 2)),
    "avgRamMB": $([math]::Round($avgRamMB, 2)),
    "peakPrivateMB": $([math]::Round($peakPrivateMB, 2)),
    "peakCpu": $([math]::Round($peakCpu, 1)),
    "avgCpu": $([math]::Round($avgCpu, 1)),
    "peakThreads": $peakThreads,
    "maxConcurrency": $MaxConcurrency,
    "date": "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
    "processorCount": $([Environment]::ProcessorCount)
}
"@

# -- 9. Generate HTML report ----------------------------------------
Write-Phase "Generating visual report: $ReportPath"

$htmlReport = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>zzigtop Stress Benchmark Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js"></script>
<style>
:root {
    --bg: #0a0a0f;
    --card-bg: #14141f;
    --border: #2a2a3a;
    --text: #e0e0e8;
    --text-muted: #888898;
    --accent: #f7a41d;
    --accent-dim: #c07a10;
    --green: #4ade80;
    --blue: #60a5fa;
    --red: #f87171;
    --purple: #c084fc;
    --radius: 10px;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.6;
    padding: 2rem;
    max-width: 1200px;
    margin: 0 auto;
}
header {
    text-align: center;
    margin-bottom: 2rem;
    padding-bottom: 1.5rem;
    border-bottom: 1px solid var(--border);
}
header h1 {
    font-size: 2rem;
    color: var(--accent);
    margin-bottom: 0.3rem;
}
.subtitle {
    color: var(--text-muted);
    font-size: 0.95rem;
}
.grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
    gap: 1rem;
    margin-bottom: 2rem;
}
.stat-card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 1.2rem;
    text-align: center;
}
.stat-card .value {
    font-size: 1.8rem;
    font-weight: 700;
    color: var(--accent);
    display: block;
}
.stat-card .label {
    font-size: 0.8rem;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.05em;
}
.stat-card.green .value  { color: var(--green); }
.stat-card.blue .value   { color: var(--blue); }
.stat-card.red .value    { color: var(--red); }
.stat-card.purple .value { color: var(--purple); }
.chart-container {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 1.5rem;
    margin-bottom: 1.5rem;
}
.chart-container h2 {
    font-size: 1.1rem;
    color: var(--accent);
    margin-bottom: 1rem;
}
.chart-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1.5rem;
    margin-bottom: 1.5rem;
}
@media (max-width: 800px) {
    .chart-row { grid-template-columns: 1fr; }
}
canvas { width: 100% !important; }
footer {
    text-align: center;
    color: var(--text-muted);
    font-size: 0.85rem;
    margin-top: 2rem;
    padding-top: 1rem;
    border-top: 1px solid var(--border);
}
</style>
</head>
<body>
<header>
    <h1>&#9889; zzigtop Stress Benchmark</h1>
    <p class="subtitle" id="reportDate"></p>
</header>

<!-- Summary Cards -->
<div class="grid" id="summaryCards"></div>

<!-- Charts -->
<div class="chart-row">
    <div class="chart-container">
        <h2>&#128200; Memory Usage (MB)</h2>
        <canvas id="memChart"></canvas>
    </div>
    <div class="chart-container">
        <h2>&#9889; CPU Usage (%)</h2>
        <canvas id="cpuChart"></canvas>
    </div>
</div>
<div class="chart-row">
    <div class="chart-container">
        <h2>&#128640; Throughput (req/s)</h2>
        <canvas id="rpsChart"></canvas>
    </div>
    <div class="chart-container">
        <h2>&#128296; Concurrency &amp; Threads</h2>
        <canvas id="threadChart"></canvas>
    </div>
</div>
<div class="chart-container">
    <h2>&#128202; Combined Overview</h2>
    <canvas id="overviewChart"></canvas>
</div>

<footer>
    Generated by <strong>stress-benchmark.ps1</strong> &mdash; zzigtop HTTP server
</footer>

<script>
// ── Embedded data ───────────────────────────────────────────
const metrics    = $metricsJsonStr;
const throughput = $throughputJsonStr;
const summary    = $summaryJson;

// ── Helpers ─────────────────────────────────────────────────
const chartDefaults = {
    responsive: true,
    animation: { duration: 0 },
    interaction: { mode: 'index', intersect: false },
    plugins: {
        legend: { labels: { color: '#e0e0e8', font: { size: 12 } } },
        tooltip: {
            backgroundColor: '#14141f',
            borderColor: '#2a2a3a',
            borderWidth: 1,
            titleColor: '#f7a41d',
            bodyColor: '#e0e0e8',
        }
    },
    scales: {
        x: {
            title: { display: true, text: 'Time (s)', color: '#888898' },
            ticks: { color: '#888898' },
            grid:  { color: '#1a1a2a' }
        },
        y: {
            ticks: { color: '#888898' },
            grid:  { color: '#1a1a2a' }
        }
    }
};

function makeScale(label) {
    return {
        ...chartDefaults.scales.y,
        title: { display: true, text: label, color: '#888898' }
    };
}

// ── Summary cards ───────────────────────────────────────────
document.getElementById('reportDate').textContent =
    summary.date + '  \u2022  ' + summary.processorCount + ' CPU cores  \u2022  Max concurrency ' + summary.maxConcurrency;

const cards = [
    { label: 'Total Requests',  value: summary.totalRequests.toLocaleString(), cls: '' },
    { label: 'Errors',          value: summary.totalErrors.toLocaleString(),   cls: summary.totalErrors > 0 ? 'red' : 'green' },
    { label: 'Avg RPS',         value: summary.avgRps.toLocaleString(),        cls: 'green' },
    { label: 'Peak RPS',        value: summary.peakRps.toLocaleString(),       cls: 'green' },
    { label: 'Peak RAM',        value: summary.peakRamMB + ' MB',             cls: 'blue' },
    { label: 'Avg RAM',         value: summary.avgRamMB + ' MB',              cls: 'blue' },
    { label: 'Peak CPU',        value: summary.peakCpu + ' %',                cls: 'purple' },
    { label: 'Avg CPU',         value: summary.avgCpu + ' %',                 cls: 'purple' },
    { label: 'Peak Threads',    value: summary.peakThreads,                   cls: '' },
    { label: 'Wall Time',       value: summary.wallTimeSec + ' s',            cls: '' },
];

const cardsContainer = document.getElementById('summaryCards');
cards.forEach(c => {
    const div = document.createElement('div');
    div.className = 'stat-card ' + c.cls;
    div.innerHTML = '<span class="value">' + c.value + '</span><span class="label">' + c.label + '</span>';
    cardsContainer.appendChild(div);
});

// ── Memory chart ────────────────────────────────────────────
const memLabels  = metrics.map(m => m.t);
const memWorking = metrics.map(m => m.ram);
const memPrivate = metrics.map(m => m.priv);

new Chart(document.getElementById('memChart'), {
    type: 'line',
    data: {
        labels: memLabels,
        datasets: [
            {
                label: 'Working Set (MB)',
                data: memWorking,
                borderColor: '#60a5fa',
                backgroundColor: 'rgba(96,165,250,0.1)',
                fill: true,
                tension: 0.3,
                pointRadius: 0,
                borderWidth: 2
            },
            {
                label: 'Private Bytes (MB)',
                data: memPrivate,
                borderColor: '#c084fc',
                backgroundColor: 'rgba(192,132,252,0.05)',
                fill: true,
                tension: 0.3,
                pointRadius: 0,
                borderWidth: 2
            }
        ]
    },
    options: {
        ...chartDefaults,
        scales: {
            x: chartDefaults.scales.x,
            y: makeScale('Memory (MB)')
        }
    }
});

// ── CPU chart ───────────────────────────────────────────────
new Chart(document.getElementById('cpuChart'), {
    type: 'line',
    data: {
        labels: memLabels,
        datasets: [{
            label: 'CPU %',
            data: metrics.map(m => m.cpu),
            borderColor: '#f7a41d',
            backgroundColor: 'rgba(247,164,29,0.1)',
            fill: true,
            tension: 0.3,
            pointRadius: 0,
            borderWidth: 2
        }]
    },
    options: {
        ...chartDefaults,
        scales: {
            x: chartDefaults.scales.x,
            y: { ...makeScale('CPU (%)'), min: 0 }
        }
    }
});

// ── Throughput chart ────────────────────────────────────────
const rpsLabels = throughput.map(t => t.t);
const rpsData   = throughput.map(t => t.rps);
const concData  = throughput.map(t => t.conc);

new Chart(document.getElementById('rpsChart'), {
    type: 'bar',
    data: {
        labels: rpsLabels,
        datasets: [
            {
                label: 'Requests/sec',
                data: rpsData,
                backgroundColor: 'rgba(74,222,128,0.6)',
                borderColor: '#4ade80',
                borderWidth: 1,
                borderRadius: 3,
                yAxisID: 'y'
            },
            {
                label: 'Concurrency',
                data: concData,
                type: 'line',
                borderColor: '#f87171',
                backgroundColor: 'rgba(248,113,113,0.1)',
                fill: false,
                tension: 0.4,
                pointRadius: 0,
                borderWidth: 2,
                borderDash: [5, 3],
                yAxisID: 'y2'
            }
        ]
    },
    options: {
        ...chartDefaults,
        scales: {
            x: chartDefaults.scales.x,
            y:  { ...makeScale('Req/s'), position: 'left' },
            y2: { ...makeScale('Concurrency'), position: 'right', grid: { drawOnChartArea: false } }
        }
    }
});

// ── Threads chart ───────────────────────────────────────────
new Chart(document.getElementById('threadChart'), {
    type: 'line',
    data: {
        labels: memLabels,
        datasets: [
            {
                label: 'OS Threads',
                data: metrics.map(m => m.threads),
                borderColor: '#4ade80',
                tension: 0.3,
                pointRadius: 0,
                borderWidth: 2
            },
            {
                label: 'Handles',
                data: metrics.map(m => m.handles),
                borderColor: '#f87171',
                tension: 0.3,
                pointRadius: 0,
                borderWidth: 2,
                yAxisID: 'y2'
            }
        ]
    },
    options: {
        ...chartDefaults,
        scales: {
            x: chartDefaults.scales.x,
            y:  { ...makeScale('Threads'), position: 'left' },
            y2: { ...makeScale('Handles'), position: 'right', grid: { drawOnChartArea: false } }
        }
    }
});

// ── Overview (normalized) ───────────────────────────────────
// Normalize each series to 0-100% of its own max for a combined view
function normalize(arr) {
    const max = Math.max(...arr, 1);
    return arr.map(v => (v / max) * 100);
}

// Align throughput to metric timestamps via nearest-match
const alignedRps = memLabels.map(t => {
    let closest = throughput[0] || { rps: 0 };
    let minDist = Infinity;
    throughput.forEach(s => {
        const d = Math.abs(s.t - t);
        if (d < minDist) { minDist = d; closest = s; }
    });
    return closest.rps;
});

new Chart(document.getElementById('overviewChart'), {
    type: 'line',
    data: {
        labels: memLabels,
        datasets: [
            {
                label: 'CPU (% of peak)',
                data: normalize(metrics.map(m => m.cpu)),
                borderColor: '#f7a41d',
                tension: 0.3, pointRadius: 0, borderWidth: 2
            },
            {
                label: 'RAM (% of peak)',
                data: normalize(memWorking),
                borderColor: '#60a5fa',
                tension: 0.3, pointRadius: 0, borderWidth: 2
            },
            {
                label: 'RPS (% of peak)',
                data: normalize(alignedRps),
                borderColor: '#4ade80',
                tension: 0.3, pointRadius: 0, borderWidth: 2
            }
        ]
    },
    options: {
        ...chartDefaults,
        scales: {
            x: chartDefaults.scales.x,
            y: { ...makeScale('% of Peak'), min: 0, max: 105 }
        }
    }
});
</script>
</body>
</html>
"@

$reportFile = Join-Path $ProjectRoot $ReportPath
$htmlReport | Out-File -Encoding utf8 $reportFile

Write-Host "  [OK] Report saved: $reportFile" -ForegroundColor Green

# -- 10. Open in browser --------------------------------------------
Write-Phase "Opening report in default browser..."
Start-Process $reportFile

Write-Host ""
Write-Banner "Done!"
Write-Host ""
