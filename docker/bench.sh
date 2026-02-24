#!/bin/sh
# =============================================================================
#  wrk-based benchmark runner for zzigtop
#
#  Runs inside the bench container. Hits the server container at $SERVER_URL
#  with increasing concurrency using wrk (same tool as TechEmpower).
#  Generates an interactive HTML report with Chart.js graphs.
#
#  Environment variables:
#    SERVER_URL      - Base URL of the server (default: http://server:8080)
#    DURATION        - Duration per phase in seconds (default: 10)
#    THREADS         - wrk threads (default: auto = nproc)
#    PIPELINE        - HTTP pipeline depth (default: 16, like TechEmpower)
#    TEST_DB         - Also benchmark /api/users (default: false)
#    REPORT_DIR      - Directory for HTML report (default: /results)
# =============================================================================
set -e

SERVER_URL="${SERVER_URL:-http://server:8080}"
DURATION="${DURATION:-10}"
THREADS="${THREADS:-$(nproc)}"
PIPELINE="${PIPELINE:-16}"
TEST_DB="${TEST_DB:-false}"
REPORT_DIR="${REPORT_DIR:-/results}"

BAR="============================================================"

info()  { printf "\n  \033[36m%s\033[0m\n  \033[36m%s\033[0m\n  \033[36m%s\033[0m\n\n" "$BAR" "  $1" "$BAR"; }
phase() { printf "  \033[33m>> %s\033[0m\n" "$1"; }
stat()  { printf "     \033[90m%-22s :\033[0m %s\n" "$1" "$2"; }
ok()    { printf "  \033[32m[OK]\033[0m %s\n" "$1"; }
fail()  { printf "  \033[31m[FAIL]\033[0m %s\n" "$1"; }

# ---------------------------------------------------------------------------
#  Data collection
# ---------------------------------------------------------------------------
RESULTS_CSV="/tmp/results.csv"
LATENCY_CSV="/tmp/latency.csv"
echo "phase,name,connections,pipeline,rps,avg_lat_us,transfer_mbs,total_reqs,errors" > "$RESULTS_CSV"
echo "connections,p50_us,p75_us,p90_us,p99_us" > "$LATENCY_CSV"

# Convert latency string (e.g. "82.00us", "1.23ms", "2.10s") to microseconds
lat_to_us() {
    val="$1"
    case "$val" in
        *us) echo "$val" | sed 's/us//' | awk '{printf "%.0f", $1}' ;;
        *ms) echo "$val" | sed 's/ms//' | awk '{printf "%.0f", $1 * 1000}' ;;
        *s)  echo "$val" | sed 's/s//'  | awk '{printf "%.0f", $1 * 1000000}' ;;
        *)   echo "0" ;;
    esac
}

# Convert transfer string (e.g. "20.00MB", "1.23GB", "500.00KB") to MB/s
transfer_to_mb() {
    val="$1"
    case "$val" in
        *GB) echo "$val" | sed 's/GB//' | awk '{printf "%.2f", $1 * 1024}' ;;
        *MB) echo "$val" | sed 's/MB//' | awk '{printf "%.2f", $1}' ;;
        *KB) echo "$val" | sed 's/KB//' | awk '{printf "%.2f", $1 / 1024}' ;;
        *)   echo "0" ;;
    esac
}

# Parse total requests from wrk output (handles "1234567 requests in 10.00s")
parse_total() {
    echo "$1" | grep "requests in" | awk '{print $1}'
}

# Parse socket/HTTP errors
parse_errors() {
    sockerr=$(echo "$1" | grep "Socket errors:" | awk '{
        sum=0; for(i=1;i<=NF;i++) if($i~/^[0-9]+$/) sum+=$i; print sum
    }')
    httperr=$(echo "$1" | grep "Non-2xx" | awk '{print $NF}')
    total=0
    [ -n "$sockerr" ] && total=$((total + sockerr))
    [ -n "$httperr" ] && total=$((total + httperr))
    echo "$total"
}

# ---------------------------------------------------------------------------
#  wrk Lua script for HTTP pipelining (same as TechEmpower)
# ---------------------------------------------------------------------------
cat > /tmp/pipeline.lua << 'LUASCRIPT'
init = function(args)
   local r = {}
   local depth = tonumber(args[1]) or 16
   for i = 1, depth do
      r[i] = wrk.format()
   end
   req = table.concat(r)
end

request = function()
   return req
end
LUASCRIPT

# ---------------------------------------------------------------------------
#  Wait for server to be ready
# ---------------------------------------------------------------------------
info "zzigtop Benchmark Suite (wrk)"

phase "Waiting for server at $SERVER_URL ..."
RETRIES=0
MAX_RETRIES=30
while ! curl -sf "$SERVER_URL/health" > /dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
        fail "Server not reachable after ${MAX_RETRIES}s"
        exit 1
    fi
    sleep 1
done
ok "Server is up"
echo ""

# ---------------------------------------------------------------------------
#  System info
# ---------------------------------------------------------------------------
phase "System info"
stat "CPU cores" "$(nproc)"
stat "wrk threads" "$THREADS"
stat "Pipeline depth" "$PIPELINE"
stat "Duration/phase" "${DURATION}s"
stat "Server" "$SERVER_URL"
echo ""

# ---------------------------------------------------------------------------
#  Run a single benchmark — captures + parses wrk output
#  Usage: run_bench <phase> <name> <url> <connections> [pipeline=yes]
# ---------------------------------------------------------------------------
run_bench() {
    bench_phase="$1"
    name="$2"
    url="$3"
    conns="$4"
    use_pipeline="${5:-yes}"

    printf "\n  \033[33m--- %-40s (c=%s) ---\033[0m\n" "$name" "$conns"

    if [ "$use_pipeline" = "yes" ]; then
        OUTPUT=$(wrk -t"$THREADS" -c"$conns" -d"${DURATION}s" \
            -s /tmp/pipeline.lua \
            "$url" -- "$PIPELINE" 2>&1)
    else
        OUTPUT=$(wrk -t"$THREADS" -c"$conns" -d"${DURATION}s" \
            "$url" 2>&1)
    fi

    # Print to console
    echo "$OUTPUT" | while IFS= read -r line; do
        printf "     %s\n" "$line"
    done
    echo ""

    # Parse metrics
    rps=$(echo "$OUTPUT" | grep "Requests/sec:" | awk '{printf "%.0f", $2}')
    avg_lat_raw=$(echo "$OUTPUT" | grep "Latency" | head -1 | awk '{print $2}')
    avg_lat_us=$(lat_to_us "$avg_lat_raw")
    transfer_raw=$(echo "$OUTPUT" | grep "Transfer/sec:" | awk '{print $2}')
    transfer_mb=$(transfer_to_mb "$transfer_raw")
    total=$(parse_total "$OUTPUT")
    errors=$(parse_errors "$OUTPUT")

    pipe_flag="yes"
    [ "$use_pipeline" != "yes" ] && pipe_flag="no"

    # Append to CSV
    echo "${bench_phase},${name},${conns},${pipe_flag},${rps:-0},${avg_lat_us:-0},${transfer_mb:-0},${total:-0},${errors:-0}" >> "$RESULTS_CSV"
}

# ---------------------------------------------------------------------------
#  Run a latency benchmark — captures percentile data
#  Usage: run_latency <connections>
# ---------------------------------------------------------------------------
run_latency() {
    conns="$1"
    threads=$((conns < THREADS ? conns : THREADS))
    [ "$threads" -lt 1 ] && threads=1

    printf "\n  \033[33m--- Latency profile (c=%s) ---\033[0m\n" "$conns"

    OUTPUT=$(wrk -t"$threads" -c"$conns" -d"${DURATION}s" --latency \
        "$SERVER_URL/health" 2>&1)

    echo "$OUTPUT" | while IFS= read -r line; do
        printf "     %s\n" "$line"
    done
    echo ""

    # Parse percentiles
    p50_raw=$(echo "$OUTPUT" | grep "50%" | awk '{print $2}')
    p75_raw=$(echo "$OUTPUT" | grep "75%" | awk '{print $2}')
    p90_raw=$(echo "$OUTPUT" | grep "90%" | awk '{print $2}')
    p99_raw=$(echo "$OUTPUT" | grep "99%" | awk '{print $2}')

    p50=$(lat_to_us "$p50_raw")
    p75=$(lat_to_us "$p75_raw")
    p90=$(lat_to_us "$p90_raw")
    p99=$(lat_to_us "$p99_raw")

    echo "${conns},${p50:-0},${p75:-0},${p90:-0},${p99:-0}" >> "$LATENCY_CSV"

    # Also add to main results
    rps=$(echo "$OUTPUT" | grep "Requests/sec:" | awk '{printf "%.0f", $2}')
    avg_lat_raw=$(echo "$OUTPUT" | grep "Latency" | head -1 | awk '{print $2}')
    avg_lat_us=$(lat_to_us "$avg_lat_raw")
    total=$(parse_total "$OUTPUT")
    errors=$(parse_errors "$OUTPUT")
    echo "Latency,Latency c=${conns},${conns},no,${rps:-0},${avg_lat_us:-0},0,${total:-0},${errors:-0}" >> "$RESULTS_CSV"
}

# ===================================================================
#  BENCHMARK PHASES
# ===================================================================

# ---------------------------------------------------------------------------
#  Phase 1: Plaintext pipelined
# ---------------------------------------------------------------------------
info "Phase 1: Plaintext — /health (pipelined)"

phase "Warmup (2s, 8 connections, no pipeline)..."
wrk -t2 -c8 -d2s "$SERVER_URL/health" > /dev/null 2>&1
ok "Warmup complete"

for CONNS in 16 32 64 128 256; do
    run_bench "Plaintext-Pipeline" "Plaintext /health (pipeline)" "$SERVER_URL/health" "$CONNS" yes
done

# ---------------------------------------------------------------------------
#  Phase 2: Plaintext non-pipelined
# ---------------------------------------------------------------------------
info "Phase 2: Plaintext — /health (no pipeline)"

for CONNS in 16 32 64 128 256; do
    run_bench "Plaintext" "Plaintext /health" "$SERVER_URL/health" "$CONNS" no
done

# ---------------------------------------------------------------------------
#  Phase 3: JSON
# ---------------------------------------------------------------------------
info "Phase 3: JSON — /metrics"

for CONNS in 16 64 128; do
    run_bench "JSON" "JSON /metrics" "$SERVER_URL/metrics" "$CONNS" yes
done

# ---------------------------------------------------------------------------
#  Phase 4: Dynamic path
# ---------------------------------------------------------------------------
info "Phase 4: Dynamic — /hello/bench"

for CONNS in 16 64 128; do
    run_bench "Dynamic" "Dynamic /hello/bench" "$SERVER_URL/hello/bench" "$CONNS" yes
done

# ---------------------------------------------------------------------------
#  Phase 5: Query params
# ---------------------------------------------------------------------------
info "Phase 5: Query Params — /search?q=hello&page=1"

for CONNS in 16 64 128; do
    run_bench "Query" "Query /search" "$SERVER_URL/search?q=hello&page=1&limit=10" "$CONNS" yes
done

# ---------------------------------------------------------------------------
#  Phase 6: Database (if enabled)
# ---------------------------------------------------------------------------
if [ "$TEST_DB" = "true" ]; then
    info "Phase 6: Database — /api/users"

    phase "Checking database connectivity..."
    if curl -sf "$SERVER_URL/api/users" > /dev/null 2>&1; then
        ok "Database connected"
        for CONNS in 16 32 64; do
            run_bench "Database" "DB /api/users" "$SERVER_URL/api/users" "$CONNS" yes
        done
    else
        fail "Database not available — skipping"
    fi
fi

# ---------------------------------------------------------------------------
#  Phase 7: Latency profile
# ---------------------------------------------------------------------------
info "Phase 7: Latency Profile (no pipelining)"

run_latency 1
run_latency 10
run_latency 64

# ---------------------------------------------------------------------------
#  Summary
# ---------------------------------------------------------------------------
info "Benchmark Complete"

phase "Quick reference (TechEmpower Round 22 plaintext, Linux):"
stat "Kestrel (aspcore raw)" "7,006,142 req/s"
stat "Go gnet (#1)"         "7,013,961 req/s"
stat "Rust faf (#2)"        "7,010,014 req/s"
stat "Go net/http"          "  681,653 req/s"
stat "Node.js"              "  454,082 req/s"

echo ""
phase "Note: TechEmpower uses 28-core dedicated hardware + 10GbE."
phase "Your Docker results will be lower but proportionally comparable."
echo ""

# ===================================================================
#  GENERATE HTML REPORT
# ===================================================================
info "Generating HTML report..."

REPORT="$REPORT_DIR/docker-bench-report.html"
mkdir -p "$REPORT_DIR"

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
CPUS=$(nproc)

# Read CSV data into JavaScript arrays
RESULTS_JSON="["
first=1
while IFS=',' read -r rphase rname rconns rpipeline rrps rlat rtransfer rtotal rerrors; do
    [ "$rphase" = "phase" ] && continue
    [ $first -eq 0 ] && RESULTS_JSON="${RESULTS_JSON},"
    first=0
    RESULTS_JSON="${RESULTS_JSON}{\"phase\":\"${rphase}\",\"name\":\"${rname}\",\"conns\":${rconns},\"pipeline\":\"${rpipeline}\",\"rps\":${rrps},\"lat_us\":${rlat},\"transfer_mb\":${rtransfer},\"total\":${rtotal},\"errors\":${rerrors}}"
done < "$RESULTS_CSV"
RESULTS_JSON="${RESULTS_JSON}]"

LATENCY_JSON="["
first=1
while IFS=',' read -r lconns lp50 lp75 lp90 lp99; do
    [ "$lconns" = "connections" ] && continue
    [ $first -eq 0 ] && LATENCY_JSON="${LATENCY_JSON},"
    first=0
    LATENCY_JSON="${LATENCY_JSON}{\"conns\":${lconns},\"p50\":${lp50},\"p75\":${lp75},\"p90\":${lp90},\"p99\":${lp99}}"
done < "$LATENCY_CSV"
LATENCY_JSON="${LATENCY_JSON}]"

cat > "$REPORT" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>zzigtop Benchmark Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js"></script>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: #0a0a12;
    color: #e0e0e0;
    padding: 24px;
    line-height: 1.6;
  }
  h1 {
    font-size: 28px;
    font-weight: 700;
    color: #60a5fa;
    margin-bottom: 4px;
  }
  .subtitle { color: #888; font-size: 14px; margin-bottom: 24px; }
  .cards {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 16px;
    margin-bottom: 32px;
  }
  .card {
    background: #14141f;
    border: 1px solid #1e1e3a;
    border-radius: 12px;
    padding: 20px;
    text-align: center;
  }
  .card .value {
    font-size: 28px;
    font-weight: 700;
    color: #60a5fa;
  }
  .card .value.green { color: #4ade80; }
  .card .value.amber { color: #fbbf24; }
  .card .value.red   { color: #f87171; }
  .card .label {
    font-size: 12px;
    color: #888;
    text-transform: uppercase;
    letter-spacing: 1px;
    margin-top: 4px;
  }
  .chart-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 24px;
    margin-bottom: 32px;
  }
  .chart-box {
    background: #14141f;
    border: 1px solid #1e1e3a;
    border-radius: 12px;
    padding: 20px;
  }
  .chart-box.full { grid-column: 1 / -1; }
  .chart-box h2 {
    font-size: 16px;
    font-weight: 600;
    color: #c0c0c0;
    margin-bottom: 12px;
  }
  canvas { width: 100% !important; }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 14px;
  }
  th, td {
    padding: 8px 12px;
    text-align: left;
    border-bottom: 1px solid #1e1e3a;
  }
  th { color: #888; font-weight: 600; text-transform: uppercase; font-size: 11px; letter-spacing: 1px; }
  td { color: #e0e0e0; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  .badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 11px;
    font-weight: 600;
  }
  .badge.pipe { background: #1e3a5f; color: #60a5fa; }
  .badge.nopipe { background: #3a2a1e; color: #fbbf24; }
  .badge.lat { background: #1e3a2a; color: #4ade80; }
  .footer { text-align: center; color: #555; font-size: 12px; margin-top: 32px; }
  @media (max-width: 768px) {
    .chart-grid { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>

<h1>zzigtop Benchmark Report</h1>
<p class="subtitle">${TIMESTAMP} &mdash; ${CPUS} CPU cores, wrk ${THREADS} threads, ${PIPELINE}x pipeline, ${DURATION}s/phase</p>

<div id="cards" class="cards"></div>

<div class="chart-grid">
  <div class="chart-box full">
    <h2>Throughput by Test (req/s)</h2>
    <canvas id="rpsChart"></canvas>
  </div>
  <div class="chart-box">
    <h2>Plaintext Scaling (req/s vs connections)</h2>
    <canvas id="scalingChart"></canvas>
  </div>
  <div class="chart-box">
    <h2>Average Latency by Test</h2>
    <canvas id="latChart"></canvas>
  </div>
  <div class="chart-box">
    <h2>Latency Percentiles</h2>
    <canvas id="pctChart"></canvas>
  </div>
  <div class="chart-box">
    <h2>Data Transfer (MB/s)</h2>
    <canvas id="transferChart"></canvas>
  </div>
  <div class="chart-box full">
    <h2>All Results</h2>
    <div style="overflow-x:auto"><table id="resultsTable"></table></div>
  </div>
</div>

<div class="footer">
  Generated by zzigtop bench.sh &mdash; wrk (same tool as TechEmpower Framework Benchmarks)<br>
  TechEmpower R22 reference: Kestrel 7.0M &bull; Go gnet 7.0M &bull; Go net/http 682K &bull; Node.js 454K req/s (28-core dedicated HW)
</div>

<script>
const results = ${RESULTS_JSON};
const latency = ${LATENCY_JSON};

Chart.defaults.color = '#888';
Chart.defaults.borderColor = '#1e1e3a';
Chart.defaults.font.family = "'Segoe UI', system-ui, sans-serif";
Chart.defaults.plugins.legend.labels.usePointStyle = true;

const C = {
  blue:   'rgba(96,165,250,0.8)',  blueBg:   'rgba(96,165,250,0.15)',
  purple: 'rgba(192,132,252,0.8)', purpleBg: 'rgba(192,132,252,0.15)',
  green:  'rgba(74,222,128,0.8)',  greenBg:  'rgba(74,222,128,0.15)',
  amber:  'rgba(251,191,36,0.8)',  amberBg:  'rgba(251,191,36,0.15)',
  red:    'rgba(248,113,113,0.8)', cyan:     'rgba(34,211,238,0.8)',
};

function fmt(n) {
  if (n >= 1e6) return (n/1e6).toFixed(2) + 'M';
  if (n >= 1e3) return (n/1e3).toFixed(1) + 'K';
  return n.toString();
}
function fmtLat(us) {
  if (us >= 1e6) return (us/1e6).toFixed(2) + 's';
  if (us >= 1000) return (us/1000).toFixed(1) + 'ms';
  return us + '\u03BCs';
}

// ---- Summary cards ----
const peakRps = Math.max(...results.map(r => r.rps));
const bestLat = Math.min(...results.filter(r=>r.lat_us>0).map(r => r.lat_us));
const totalReqs = results.reduce((s,r) => s + r.total, 0);
const totalErrors = results.reduce((s,r) => s + r.errors, 0);
const nonLat = results.filter(r => r.phase !== 'Latency');
const avgRps = nonLat.length ? Math.round(nonLat.reduce((s,r) => s+r.rps, 0) / nonLat.length) : 0;

document.getElementById('cards').innerHTML = [
  { value: fmt(peakRps), label: 'Peak req/s', cls: '' },
  { value: fmtLat(bestLat), label: 'Best Avg Latency', cls: 'green' },
  { value: fmt(totalReqs), label: 'Total Requests', cls: '' },
  { value: totalErrors.toString(), label: 'Total Errors', cls: totalErrors > 0 ? 'red' : 'green' },
  { value: fmt(avgRps), label: 'Avg req/s', cls: 'amber' },
  { value: '${CPUS} cores', label: 'CPU Cores', cls: '' },
].map(c => '<div class="card"><div class="value '+c.cls+'">'+c.value+'</div><div class="label">'+c.label+'</div></div>').join('');

// ---- Throughput bar chart (best per phase) ----
const phases = [...new Set(results.map(r => r.phase))];
const best = phases.map(p => {
  const rows = results.filter(r => r.phase === p);
  return rows.reduce((b, r) => r.rps > b.rps ? r : b, rows[0]);
});
const phaseClr = best.map(r =>
  r.pipeline==='yes' ? C.blue : r.phase==='Latency' ? C.green : C.amber
);

new Chart(document.getElementById('rpsChart'), {
  type: 'bar',
  data: {
    labels: best.map(r => r.phase + ' (c=' + r.conns + ')'),
    datasets: [{ label: 'req/s', data: best.map(r=>r.rps), backgroundColor: phaseClr, borderRadius: 6, maxBarThickness: 80 }]
  },
  options: {
    indexAxis: 'y', responsive: true,
    plugins: { legend:{display:false}, tooltip:{callbacks:{label:ctx=>fmt(ctx.raw)+' req/s'}} },
    scales: { x:{ticks:{callback:v=>fmt(v)},grid:{color:'#1e1e3a'}}, y:{grid:{display:false}} }
  }
});

// ---- Scaling chart ----
const pipD = results.filter(r=>r.phase==='Plaintext-Pipeline').sort((a,b)=>a.conns-b.conns);
const nopD = results.filter(r=>r.phase==='Plaintext').sort((a,b)=>a.conns-b.conns);

new Chart(document.getElementById('scalingChart'), {
  type: 'line',
  data: {
    labels: pipD.map(r=>r.conns),
    datasets: [
      { label:'Pipelined (${PIPELINE}x)', data:pipD.map(r=>r.rps), borderColor:C.blue, backgroundColor:C.blueBg, fill:true, tension:.3, pointRadius:5 },
      { label:'No Pipeline', data:nopD.map(r=>r.rps), borderColor:C.amber, backgroundColor:C.amberBg, fill:true, tension:.3, pointRadius:5 }
    ]
  },
  options: {
    responsive:true,
    plugins:{tooltip:{callbacks:{label:ctx=>ctx.dataset.label+': '+fmt(ctx.raw)+' req/s'}}},
    scales:{
      x:{title:{display:true,text:'Connections'},grid:{color:'#1e1e3a'}},
      y:{title:{display:true,text:'req/s'},ticks:{callback:v=>fmt(v)},grid:{color:'#1e1e3a'}}
    }
  }
});

// ---- Latency bar chart ----
const latR = best.filter(r=>r.lat_us>0);
const latClr = latR.map(r=>r.lat_us<200?C.green:r.lat_us<5000?C.amber:C.red);

new Chart(document.getElementById('latChart'), {
  type:'bar',
  data: {
    labels: latR.map(r=>r.phase),
    datasets: [{ label:'Avg Latency', data:latR.map(r=>r.lat_us), backgroundColor:latClr, borderRadius:6, maxBarThickness:60 }]
  },
  options: {
    responsive:true,
    plugins:{ legend:{display:false}, tooltip:{callbacks:{label:ctx=>fmtLat(ctx.raw)}} },
    scales:{ y:{ticks:{callback:v=>fmtLat(v)},grid:{color:'#1e1e3a'}}, x:{grid:{display:false}} }
  }
});

// ---- Latency percentile chart ----
if (latency.length > 0) {
  new Chart(document.getElementById('pctChart'), {
    type:'bar',
    data: {
      labels: latency.map(l=>'c='+l.conns),
      datasets: [
        { label:'p50', data:latency.map(l=>l.p50), backgroundColor:C.green, borderRadius:4 },
        { label:'p75', data:latency.map(l=>l.p75), backgroundColor:C.blue, borderRadius:4 },
        { label:'p90', data:latency.map(l=>l.p90), backgroundColor:C.amber, borderRadius:4 },
        { label:'p99', data:latency.map(l=>l.p99), backgroundColor:C.red, borderRadius:4 },
      ]
    },
    options: {
      responsive:true,
      plugins:{tooltip:{callbacks:{label:ctx=>ctx.dataset.label+': '+fmtLat(ctx.raw)}}},
      scales:{ y:{ticks:{callback:v=>fmtLat(v)},grid:{color:'#1e1e3a'}}, x:{grid:{display:false}} }
    }
  });
}

// ---- Transfer chart ----
const trD = best.filter(r=>r.transfer_mb>0);
new Chart(document.getElementById('transferChart'), {
  type:'bar',
  data: {
    labels: trD.map(r=>r.phase),
    datasets: [{ label:'MB/s', data:trD.map(r=>r.transfer_mb), backgroundColor:C.purple, borderRadius:6, maxBarThickness:60 }]
  },
  options: {
    responsive:true,
    plugins:{ legend:{display:false}, tooltip:{callbacks:{label:ctx=>ctx.raw.toFixed(1)+' MB/s'}} },
    scales:{ y:{ticks:{callback:v=>v+' MB/s'},grid:{color:'#1e1e3a'}}, x:{grid:{display:false}} }
  }
});

// ---- Results table ----
let t = '<thead><tr><th>Phase</th><th>Name</th><th>Conns</th><th>Mode</th><th style="text-align:right">Req/s</th><th style="text-align:right">Avg Latency</th><th style="text-align:right">Transfer</th><th style="text-align:right">Total</th><th style="text-align:right">Errors</th></tr></thead><tbody>';
results.forEach(r => {
  const badge = r.pipeline==='yes'
    ? '<span class="badge pipe">pipeline</span>'
    : r.phase==='Latency' ? '<span class="badge lat">latency</span>' : '<span class="badge nopipe">single</span>';
  const es = r.errors>0 ? ' style="color:#f87171"' : '';
  t += '<tr><td>'+r.phase+'</td><td>'+r.name+'</td><td class="num">'+r.conns+'</td><td>'+badge+'</td>'
    + '<td class="num" style="font-weight:600;color:#60a5fa">'+fmt(r.rps)+'</td>'
    + '<td class="num">'+(r.lat_us>0?fmtLat(r.lat_us):'\u2014')+'</td>'
    + '<td class="num">'+(r.transfer_mb>0?r.transfer_mb.toFixed(1)+' MB/s':'\u2014')+'</td>'
    + '<td class="num">'+fmt(r.total)+'</td>'
    + '<td class="num"'+es+'>'+r.errors+'</td></tr>';
});
t += '</tbody>';
document.getElementById('resultsTable').innerHTML = t;
</script>
</body>
</html>
HTMLEOF

ok "Report saved to $REPORT"
echo ""
