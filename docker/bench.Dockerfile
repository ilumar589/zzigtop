# =============================================================================
# Benchmark runner image
#
# Includes wrk (HTTP benchmarking tool) and a shell script that runs a
# multi-phase benchmark against the server container.
#
# wrk is the same tool used by TechEmpower Framework Benchmarks — the gold
# standard for HTTP throughput measurement. It uses epoll + multi-threaded
# event loops and supports HTTP pipelining (16 requests per write syscall).
#
# Usage:
#   docker compose --profile bench up bench
# =============================================================================
FROM alpine:3.21 AS wrk-builder

RUN apk add --no-cache build-base git openssl-dev linux-headers perl
RUN git clone --depth 1 https://github.com/wg/wrk.git /wrk \
    && cd /wrk \
    && make -j$(nproc) WITH_OPENSSL=/usr \
    && strip wrk

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM alpine:3.21

RUN apk add --no-cache curl jq bc libgcc openssl

COPY --from=wrk-builder /wrk/wrk /usr/local/bin/wrk

COPY docker/bench.sh /bench.sh
RUN chmod +x /bench.sh

ENTRYPOINT ["/bench.sh"]
