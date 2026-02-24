#!/bin/sh
# =============================================================================
#  wrk-based benchmark runner for zzigtop
#
#  Runs inside the bench container. Hits the server container at $SERVER_URL
#  with increasing concurrency using wrk (same tool as TechEmpower).
#
#  Environment variables:
#    SERVER_URL      - Base URL of the server (default: http://server:8080)
#    DURATION        - Duration per phase in seconds (default: 10)
#    THREADS         - wrk threads (default: auto = nproc)
#    PIPELINE        - HTTP pipeline depth (default: 16, like TechEmpower)
#    TEST_DB         - Also benchmark /api/users (default: false)
# =============================================================================
set -e

SERVER_URL="${SERVER_URL:-http://server:8080}"
DURATION="${DURATION:-10}"
THREADS="${THREADS:-$(nproc)}"
PIPELINE="${PIPELINE:-16}"
TEST_DB="${TEST_DB:-false}"

BAR="============================================================"

info()  { printf "\n  \033[36m%s\033[0m\n  \033[36m%s\033[0m\n  \033[36m%s\033[0m\n\n" "$BAR" "  $1" "$BAR"; }
phase() { printf "  \033[33m>> %s\033[0m\n" "$1"; }
stat()  { printf "     \033[90m%-22s :\033[0m %s\n" "$1" "$2"; }
ok()    { printf "  \033[32m[OK]\033[0m %s\n" "$1"; }
fail()  { printf "  \033[31m[FAIL]\033[0m %s\n" "$1"; }

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
#  Run a single benchmark
#  Usage: run_bench <name> <url> <connections> [pipeline]
# ---------------------------------------------------------------------------
run_bench() {
    name="$1"
    url="$2"
    conns="$3"
    use_pipeline="${4:-yes}"

    printf "\n  \033[33m--- %-40s (c=%s) ---\033[0m\n" "$name" "$conns"

    if [ "$use_pipeline" = "yes" ]; then
        wrk -t"$THREADS" -c"$conns" -d"${DURATION}s" \
            -s /tmp/pipeline.lua \
            "$url" -- "$PIPELINE" 2>&1 | while IFS= read -r line; do
            printf "     %s\n" "$line"
        done
    else
        wrk -t"$THREADS" -c"$conns" -d"${DURATION}s" \
            "$url" 2>&1 | while IFS= read -r line; do
            printf "     %s\n" "$line"
        done
    fi
    echo ""
}

# ---------------------------------------------------------------------------
#  Benchmark: Plaintext / Health (like TechEmpower plaintext)
# ---------------------------------------------------------------------------
info "Phase 1: Plaintext — /health (pipelined)"

phase "Warmup (2s, 8 connections, no pipeline)..."
wrk -t2 -c8 -d2s "$SERVER_URL/health" > /dev/null 2>&1
ok "Warmup complete"

for CONNS in 16 32 64 128 256; do
    run_bench "Plaintext /health (pipeline)" "$SERVER_URL/health" "$CONNS" yes
done

# ---------------------------------------------------------------------------
#  Benchmark: Plaintext without pipelining
# ---------------------------------------------------------------------------
info "Phase 2: Plaintext — /health (no pipeline)"

for CONNS in 16 32 64 128 256; do
    run_bench "Plaintext /health" "$SERVER_URL/health" "$CONNS" no
done

# ---------------------------------------------------------------------------
#  Benchmark: JSON (small dynamic response)
# ---------------------------------------------------------------------------
info "Phase 3: JSON — /metrics"

for CONNS in 16 64 128; do
    run_bench "JSON /metrics" "$SERVER_URL/metrics" "$CONNS" yes
done

# ---------------------------------------------------------------------------
#  Benchmark: Dynamic path param + allocPrint
# ---------------------------------------------------------------------------
info "Phase 4: Dynamic — /hello/bench"

for CONNS in 16 64 128; do
    run_bench "Dynamic /hello/bench" "$SERVER_URL/hello/bench" "$CONNS" yes
done

# ---------------------------------------------------------------------------
#  Benchmark: Query param parsing
# ---------------------------------------------------------------------------
info "Phase 5: Query Params — /search?q=hello&page=1"

for CONNS in 16 64 128; do
    run_bench "Query /search" "$SERVER_URL/search?q=hello&page=1&limit=10" "$CONNS" yes
done

# ---------------------------------------------------------------------------
#  Benchmark: Database (if enabled)
# ---------------------------------------------------------------------------
if [ "$TEST_DB" = "true" ]; then
    info "Phase 6: Database — /api/users"

    phase "Checking database connectivity..."
    if curl -sf "$SERVER_URL/api/users" > /dev/null 2>&1; then
        ok "Database connected"
        for CONNS in 16 32 64; do
            run_bench "DB List /api/users" "$SERVER_URL/api/users" "$CONNS" yes
        done
    else
        fail "Database not available — skipping"
    fi
fi

# ---------------------------------------------------------------------------
#  Latency profile (low concurrency, no pipelining)
# ---------------------------------------------------------------------------
info "Phase 7: Latency Profile (no pipelining)"

phase "Single-connection latency..."
printf "\n"
wrk -t1 -c1 -d"${DURATION}s" --latency "$SERVER_URL/health" 2>&1 | while IFS= read -r line; do
    printf "     %s\n" "$line"
done
echo ""

phase "10-connection latency..."
printf "\n"
wrk -t2 -c10 -d"${DURATION}s" --latency "$SERVER_URL/health" 2>&1 | while IFS= read -r line; do
    printf "     %s\n" "$line"
done
echo ""

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
