//! SIMD-accelerated HTTP/1 parsing utilities.
//!
//! All parsing is zero-copy: returned slices point directly into the input buffer.
//! Uses @Vector for parallel byte scanning when processing large header blocks.

const std = @import("std");
const http = std.http;
const mem = std.mem;

/// A parsed HTTP header as zero-copy slices into the original buffer.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Result of parsing the HTTP request line.
pub const RequestLine = struct {
    method: http.Method,
    path: []const u8,
    version: http.Version,
};

pub const ParseError = error{
    InvalidMethod,
    InvalidPath,
    InvalidVersion,
    InvalidHeader,
    HeadersTooLarge,
    IncompleteLine,
};

// ---------------------------------------------------------------------------
// SIMD helpers — process 16 bytes at a time
// ---------------------------------------------------------------------------

const simd_width = 16;
const SimdVec = @Vector(simd_width, u8);

/// Check if a SIMD vector contains a specific byte value.
/// Compiles down to a single SIMD compare + horizontal OR.
inline fn containsByte(comptime needle: u8, chunk: SimdVec) bool {
    const needles: SimdVec = @splat(needle);
    const matches = chunk == needles;
    return @reduce(.Or, matches);
}

/// Find the first occurrence of `needle` in a SIMD vector.
/// Returns the index within the 16-byte vector, or null.
inline fn findByteInVec(comptime needle: u8, chunk: SimdVec) ?u4 {
    const needles: SimdVec = @splat(needle);
    const matches = chunk == needles;
    // Convert bool vector to bitmask and find first set bit
    const mask: u16 = @bitCast(matches);
    if (mask == 0) return null;
    return @truncate(@ctz(mask));
}

/// SIMD-accelerated scan for a byte in a buffer.
/// Falls back to scalar for the tail bytes.
pub fn findByte(comptime needle: u8, data: []const u8) ?usize {
    var i: usize = 0;

    // SIMD path: process 16 bytes at a time
    while (i + simd_width <= data.len) {
        const chunk: SimdVec = data[i..][0..simd_width].*;
        if (findByteInVec(needle, chunk)) |offset| {
            return i + offset;
        }
        i += simd_width;
    }

    // Scalar tail
    while (i < data.len) : (i += 1) {
        if (data[i] == needle) return i;
    }

    return null;
}

/// SIMD-accelerated scan for CRLF ("\r\n") in a buffer.
/// Returns the index of the '\r' in the CRLF pair.
pub fn findCRLF(data: []const u8) ?usize {
    if (data.len < 2) return null;

    var i: usize = 0;

    // SIMD: scan for '\r' in 16-byte chunks, then verify '\n' follows
    while (i + simd_width <= data.len) {
        const chunk: SimdVec = data[i..][0..simd_width].*;
        if (containsByte('\r', chunk)) {
            // Found a '\r' somewhere in this chunk — scan precisely
            var j: usize = i;
            const end = @min(i + simd_width, data.len - 1);
            while (j < end) : (j += 1) {
                if (data[j] == '\r' and data[j + 1] == '\n') {
                    return j;
                }
            }
        }
        i += simd_width;
    }

    // Scalar tail
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n') {
            return i;
        }
    }

    return null;
}

/// SIMD-accelerated double-CRLF scan (end of headers: "\r\n\r\n").
/// Returns the index of the first '\r' in the "\r\n\r\n" sequence.
pub fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;

    var i: usize = 0;

    // SIMD: scan for '\r' then verify full sequence
    while (i + simd_width <= data.len) {
        const chunk: SimdVec = data[i..][0..simd_width].*;
        if (containsByte('\r', chunk)) {
            var j: usize = i;
            const end = @min(i + simd_width, data.len - 3);
            while (j < end) : (j += 1) {
                if (data[j] == '\r' and data[j + 1] == '\n' and
                    data[j + 2] == '\r' and data[j + 3] == '\n')
                {
                    return j;
                }
            }
        }
        i += simd_width;
    }

    // Scalar tail
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and
            data[i + 2] == '\r' and data[i + 3] == '\n')
        {
            return i;
        }
    }

    return null;
}

/// Parse the HTTP request line (first line).
/// Returns slices into the input buffer.
pub fn parseRequestLine(line: []const u8) ParseError!RequestLine {
    // Find method end (first space)
    const method_end = findByte(' ', line) orelse
        return error.InvalidMethod;

    const method_str = line[0..method_end];
    const method = std.meta.stringToEnum(http.Method, method_str) orelse
        return error.InvalidMethod;

    // Find path end (last space before version)
    const rest = line[method_end + 1 ..];
    const path_end = mem.findScalarLast(u8, rest, ' ') orelse
        return error.InvalidPath;

    const path = rest[0..path_end];
    if (path.len == 0) return error.InvalidPath;

    // Parse version — compare 8-byte integers for speed
    const version_str = rest[path_end + 1 ..];
    if (version_str.len != 8) return error.InvalidVersion;

    const v: *const [8]u8 = version_str[0..8];
    const int: u64 = @bitCast(v.*);
    const http10: u64 = @bitCast(@as(*const [8]u8, "HTTP/1.0").*);
    const http11: u64 = @bitCast(@as(*const [8]u8, "HTTP/1.1").*);

    const version: http.Version = if (int == http11)
        .@"HTTP/1.1"
    else if (int == http10)
        .@"HTTP/1.0"
    else
        return error.InvalidVersion;

    return .{
        .method = method,
        .path = path,
        .version = version,
    };
}

/// Trim leading and trailing whitespace (space and tab only, per HTTP spec).
inline fn trimHttpWhitespace(s: []const u8) []const u8 {
    return mem.trim(u8, s, " \t");
}

/// Parse a single "Name: Value" header line.
/// Returns slices into the input buffer (zero-copy).
pub fn parseHeaderLine(line: []const u8) ParseError!Header {
    const colon = findByte(':', line) orelse
        return error.InvalidHeader;

    const name = line[0..colon];
    if (name.len == 0) return error.InvalidHeader;

    const value = trimHttpWhitespace(line[colon + 1 ..]);

    return .{
        .name = name,
        .value = value,
    };
}

// ---- Tests ----

// ---------------------------------------------------------------------------
// findByte tests
// ---------------------------------------------------------------------------

test "findByte - basic" {
    const data = "Hello, World!";
    try std.testing.expectEqual(@as(?usize, 5), findByte(',', data));
    try std.testing.expectEqual(@as(?usize, null), findByte('z', data));
    try std.testing.expectEqual(@as(?usize, 0), findByte('H', data));
}

test "findByte - empty input" {
    try std.testing.expectEqual(@as(?usize, null), findByte('x', ""));
}

test "findByte - last character" {
    try std.testing.expectEqual(@as(?usize, 4), findByte('!', "test!"));
}

test "findByte - longer than 16 bytes (SIMD path)" {
    // A string > 16 bytes to exercise the SIMD path
    const data = "0123456789abcdef!trailing";
    try std.testing.expectEqual(@as(?usize, 16), findByte('!', data));
}

test "findByte - needle only in scalar tail" {
    // Exactly 17 bytes — SIMD processes first 16, scalar finds needle at 16
    const data = "0123456789abcdefX";
    try std.testing.expectEqual(@as(?usize, 16), findByte('X', data));
}

test "findByte - no match in long string" {
    const data = "a" ** 64;
    try std.testing.expectEqual(@as(?usize, null), findByte('z', data));
}

// ---------------------------------------------------------------------------
// findCRLF tests
// ---------------------------------------------------------------------------

test "findCRLF" {
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expectEqual(@as(?usize, 14), findCRLF(data));
}

test "findCRLF - empty input" {
    try std.testing.expectEqual(@as(?usize, null), findCRLF(""));
}

test "findCRLF - single byte" {
    try std.testing.expectEqual(@as(?usize, null), findCRLF("\r"));
}

test "findCRLF - lone CR without LF" {
    try std.testing.expectEqual(@as(?usize, null), findCRLF("hello\rworld"));
}

test "findCRLF - LF without CR" {
    try std.testing.expectEqual(@as(?usize, null), findCRLF("hello\nworld"));
}

test "findCRLF - at end" {
    try std.testing.expectEqual(@as(?usize, 5), findCRLF("hello\r\n"));
}

test "findCRLF - long input (SIMD path)" {
    // CRLF past the 16-byte SIMD boundary
    const data = "0123456789abcdef0123\r\nsuffix";
    try std.testing.expectEqual(@as(?usize, 20), findCRLF(data));
}

// ---------------------------------------------------------------------------
// findHeaderEnd tests
// ---------------------------------------------------------------------------

test "findHeaderEnd" {
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expectEqual(@as(?usize, 31), findHeaderEnd(data));
}

test "findHeaderEnd - empty" {
    try std.testing.expectEqual(@as(?usize, null), findHeaderEnd(""));
}

test "findHeaderEnd - no double CRLF" {
    try std.testing.expectEqual(@as(?usize, null), findHeaderEnd("GET / HTTP/1.1\r\nHost: localhost\r\n"));
}

test "findHeaderEnd - minimal" {
    try std.testing.expectEqual(@as(?usize, 0), findHeaderEnd("\r\n\r\n"));
}

test "findHeaderEnd - long headers (SIMD path)" {
    // Build a header block > 32 bytes to exercise SIMD path
    const data = "X-Long-Header-Name: some-value!!\r\n\r\n";
    try std.testing.expectEqual(@as(?usize, 32), findHeaderEnd(data));
}

// ---------------------------------------------------------------------------
// parseRequestLine tests
// ---------------------------------------------------------------------------

test "parseRequestLine - GET" {
    const result = try parseRequestLine("GET /hello/world HTTP/1.1");
    try std.testing.expectEqual(http.Method.GET, result.method);
    try std.testing.expectEqualStrings("/hello/world", result.path);
    try std.testing.expectEqual(http.Version.@"HTTP/1.1", result.version);
}

test "parseRequestLine - POST" {
    const result = try parseRequestLine("POST /api/data HTTP/1.1");
    try std.testing.expectEqual(http.Method.POST, result.method);
    try std.testing.expectEqualStrings("/api/data", result.path);
}

test "parseRequestLine - HTTP/1.0" {
    const result = try parseRequestLine("GET / HTTP/1.0");
    try std.testing.expectEqual(http.Version.@"HTTP/1.0", result.version);
}

test "parseRequestLine - DELETE method" {
    const result = try parseRequestLine("DELETE /items/5 HTTP/1.1");
    try std.testing.expectEqual(http.Method.DELETE, result.method);
    try std.testing.expectEqualStrings("/items/5", result.path);
}

test "parseRequestLine - invalid method" {
    const result = parseRequestLine("INVALID / HTTP/1.1");
    try std.testing.expectError(error.InvalidMethod, result);
}

test "parseRequestLine - no spaces" {
    const result = parseRequestLine("GETHTTP/1.1");
    try std.testing.expectError(error.InvalidMethod, result);
}

test "parseRequestLine - invalid version" {
    const result = parseRequestLine("GET / HTTP/2.0");
    try std.testing.expectError(error.InvalidVersion, result);
}

test "parseRequestLine - path with query string" {
    const result = try parseRequestLine("GET /search?q=zig HTTP/1.1");
    try std.testing.expectEqualStrings("/search?q=zig", result.path);
}

// ---------------------------------------------------------------------------
// parseHeaderLine tests
// ---------------------------------------------------------------------------

test "parseHeaderLine - simple" {
    const result = try parseHeaderLine("Content-Type: text/html");
    try std.testing.expectEqualStrings("Content-Type", result.name);
    try std.testing.expectEqualStrings("text/html", result.value);
}

test "parseHeaderLine - value with extra whitespace" {
    const result = try parseHeaderLine("Host:   example.com  ");
    try std.testing.expectEqualStrings("Host", result.name);
    try std.testing.expectEqualStrings("example.com", result.value);
}

test "parseHeaderLine - missing colon" {
    const result = parseHeaderLine("InvalidHeader");
    try std.testing.expectError(error.InvalidHeader, result);
}

test "parseHeaderLine - empty name" {
    const result = parseHeaderLine(": value");
    try std.testing.expectError(error.InvalidHeader, result);
}

test "parseHeaderLine - value with colon" {
    const result = try parseHeaderLine("Location: http://example.com:8080/path");
    try std.testing.expectEqualStrings("Location", result.name);
    try std.testing.expectEqualStrings("http://example.com:8080/path", result.value);
}

test "parseHeaderLine - numeric value" {
    const result = try parseHeaderLine("Content-Length: 42");
    try std.testing.expectEqualStrings("Content-Length", result.name);
    try std.testing.expectEqualStrings("42", result.value);
}
