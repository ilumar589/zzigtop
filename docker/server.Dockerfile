# =============================================================================
# Multi-stage build: Zig HTTP server on Alpine Linux
#
# Stage 1: Build the server binary with ReleaseFast using Zig's native
#           cross-compilation (no C toolchain needed).
# Stage 2: Copy the binary into a minimal Alpine image (~8 MB total).
#
# Usage:
#   docker build -f docker/server.Dockerfile -t zzigtop-server .
#   docker run -p 8080:8080 zzigtop-server
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS builder

# Install the exact Zig dev version matching build.zig.zon.
# Dev builds are ephemeral on ziglang.org so we use the Mach community mirror
# which archives all dev builds: https://machengine.org/docs/zig/
ARG ZIG_VERSION=0.16.0-dev.2535+b5bd49460
RUN apk add --no-cache curl xz binutils \
    && ZIG_TARBALL="zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && curl -fsSL "https://pkg.machengine.org/zig/${ZIG_TARBALL}" \
       | tar -xJ -C /opt \
    && ZIG_DIR=$(ls -d /opt/zig-*) \
    && ln -s "$ZIG_DIR/zig" /usr/local/bin/zig \
    && zig version

WORKDIR /src

# Copy build manifests and source code
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY public/ public/

# Build with maximum optimizations targeting native Linux x86_64
# - ReleaseFast: full LLVM optimizations, no runtime safety checks
# - Single-threaded: false (we want multi-threaded I/O runtime)
#
# Docker overlay2fs doesn't support linkat(AT_EMPTY_PATH) which Zig's
# build system uses for atomic file creation. We work around this by
# copying sources to a tmpfs, building there, and copying the binary back.
RUN --mount=type=tmpfs,target=/build \
    cp -r /src/* /build/ \
    && cd /build \
    && zig build -Doptimize=ReleaseFast \
    && strip /build/zig-out/bin/http_server \
    && cp /build/zig-out/bin/http_server /src/http_server

# ---------------------------------------------------------------------------
# Stage 2: Minimal runtime image
# ---------------------------------------------------------------------------
FROM alpine:3.21

# Labels
LABEL maintainer="zzigtop" \
      description="Zig HTTP/1 server — ReleaseFast build on Alpine Linux"

# No runtime dependencies needed — Zig produces a static binary.
# Add only curl for healthchecks.
RUN apk add --no-cache curl

# Non-root user for security
RUN adduser -D -h /app appuser
USER appuser
WORKDIR /app

# Copy the server binary and static assets
COPY --from=builder /src/http_server ./http_server
COPY --from=builder /src/public/ ./public/

# Default server configuration
ENV PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=5s --timeout=3s --start-period=2s --retries=3 \
    CMD curl -sf http://localhost:8080/health || exit 1

# Run the server — compose.yml overrides CMD with full flags including
# --idle-timeout 0 --request-timeout 0 (fast path avoiding io.select bug).
ENTRYPOINT ["./http_server"]
CMD ["--port", "8080", "--backlog", "4096", "--static-dir", "public"]
