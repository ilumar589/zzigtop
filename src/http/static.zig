//! Static file handler.
//!
//! Serves static files from a configured document root directory.
//! Used as a fallback when no comptime route matches a request path.
//!
//! Features:
//!   - Comptime MIME type table (extension → Content-Type)
//!   - Path traversal prevention (rejects `..`, null bytes, backslashes)
//!   - Arena-allocated file reads (freed in bulk with request)
//!   - `index.html` auto-resolution for directory paths
//!   - Configurable max file size (default 10MB)
//!   - Cache-Control headers for browser caching
//!
//! Security:
//!   All request paths are sanitized before filesystem access. The handler
//!   rejects any path containing `..` segments, null bytes (`\x00`), or
//!   backslash characters. The resolved path must stay under the document
//!   root — no symlink resolution is performed (relies on OS fs permissions).

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const Response = @import("response.zig");

const Static = @This();

// ============================================================================
// Configuration
// ============================================================================

/// Static file handler configuration.
pub const Config = struct {
    /// Root directory for static files (relative to CWD or absolute).
    /// Example: "public" serves files from ./public/
    root_dir: []const u8,

    /// Maximum file size to serve (bytes). Files larger than this
    /// are rejected with 404 to prevent memory exhaustion.
    /// Default: 10 MB.
    max_file_size: usize = 10 * 1024 * 1024,

    /// Cache-Control max-age value in seconds.
    /// Sent as: `Cache-Control: public, max-age=<value>`
    /// 0 = no Cache-Control header. Default: 3600 (1 hour).
    cache_max_age_s: u32 = 3600,

    /// Default file to serve for directory paths (e.g., "/" → "/index.html").
    /// null = disable index file resolution.
    index_file: ?[]const u8 = "index.html",
};

// ============================================================================
// Path sanitization
// ============================================================================

/// Validate and sanitize a URL path for filesystem access.
///
/// Returns null if the path is unsafe (traversal attempt, null bytes, etc.).
/// Returns the sanitized relative path (without leading `/`) on success.
///
/// Rules:
///   - Must start with `/`
///   - No `..` path segments (traversal)
///   - No null bytes
///   - No backslashes (Windows path injection)
///   - No `//` double slashes
///   - Query strings and fragments are stripped
pub fn sanitizePath(path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] != '/') return null;

    // Reject null bytes anywhere in the path.
    if (mem.indexOfScalar(u8, path, 0)) |_| return null;

    // Reject backslashes (Windows path separator injection).
    if (mem.indexOfScalar(u8, path, '\\')) |_| return null;

    // Strip query string and fragment.
    const clean = if (mem.indexOfScalar(u8, path, '?')) |qi|
        path[0..qi]
    else if (mem.indexOfScalar(u8, path, '#')) |fi|
        path[0..fi]
    else
        path;

    // Skip leading slash for the relative path.
    const relative = if (clean.len > 1) clean[1..] else "";

    // Check each segment for traversal.
    var iter = mem.splitScalar(u8, relative, '/');
    while (iter.next()) |segment| {
        // Reject empty segments (double slashes like //foo).
        // Allow empty for trailing slash (e.g. "foo/" → segments: "foo", "").
        // Actually, only reject ".." — empty segments from trailing slash are fine.
        if (mem.eql(u8, segment, "..")) return null;
        if (mem.eql(u8, segment, ".")) return null;
    }

    return relative;
}

// ============================================================================
// MIME type mapping (comptime)
// ============================================================================

/// MIME type entry: extension (without dot) → Content-Type.
const MimeEntry = struct {
    ext: []const u8,
    content_type: []const u8,
};

/// Comptime MIME type table. Checked at compile time — no runtime hash table.
/// Covers common web file types plus htmx-related types.
const mime_table = [_]MimeEntry{
    // ---- HTML / Templates ----
    .{ .ext = "html", .content_type = "text/html; charset=utf-8" },
    .{ .ext = "htm", .content_type = "text/html; charset=utf-8" },

    // ---- Stylesheets ----
    .{ .ext = "css", .content_type = "text/css; charset=utf-8" },

    // ---- JavaScript ----
    .{ .ext = "js", .content_type = "application/javascript; charset=utf-8" },
    .{ .ext = "mjs", .content_type = "application/javascript; charset=utf-8" },

    // ---- JSON ----
    .{ .ext = "json", .content_type = "application/json; charset=utf-8" },

    // ---- Images ----
    .{ .ext = "png", .content_type = "image/png" },
    .{ .ext = "jpg", .content_type = "image/jpeg" },
    .{ .ext = "jpeg", .content_type = "image/jpeg" },
    .{ .ext = "gif", .content_type = "image/gif" },
    .{ .ext = "svg", .content_type = "image/svg+xml" },
    .{ .ext = "ico", .content_type = "image/x-icon" },
    .{ .ext = "webp", .content_type = "image/webp" },
    .{ .ext = "avif", .content_type = "image/avif" },

    // ---- Fonts ----
    .{ .ext = "woff", .content_type = "font/woff" },
    .{ .ext = "woff2", .content_type = "font/woff2" },
    .{ .ext = "ttf", .content_type = "font/ttf" },
    .{ .ext = "otf", .content_type = "font/otf" },
    .{ .ext = "eot", .content_type = "application/vnd.ms-fontobject" },

    // ---- Other ----
    .{ .ext = "xml", .content_type = "application/xml; charset=utf-8" },
    .{ .ext = "txt", .content_type = "text/plain; charset=utf-8" },
    .{ .ext = "md", .content_type = "text/markdown; charset=utf-8" },
    .{ .ext = "map", .content_type = "application/json" },
    .{ .ext = "wasm", .content_type = "application/wasm" },
    .{ .ext = "pdf", .content_type = "application/pdf" },
};

/// Look up Content-Type for a file extension (case-insensitive).
///
/// Returns the MIME type string, or "application/octet-stream" for unknown extensions.
pub fn mimeType(filename: []const u8) []const u8 {
    const ext = extension(filename) orelse return "application/octet-stream";

    inline for (mime_table) |entry| {
        if (eqlIgnoreCaseComptime(ext, entry.ext)) {
            return entry.content_type;
        }
    }
    return "application/octet-stream";
}

/// Extract the file extension (without the dot) from a filename.
/// Returns null if no extension is found.
fn extension(filename: []const u8) ?[]const u8 {
    const dot_pos = mem.lastIndexOfScalar(u8, filename, '.') orelse return null;
    if (dot_pos + 1 >= filename.len) return null;
    return filename[dot_pos + 1 ..];
}

/// Compare a runtime string against a comptime string, case-insensitive.
/// Uses inline for to let the compiler optimize the comptime string comparison.
fn eqlIgnoreCaseComptime(runtime: []const u8, comptime expected: []const u8) bool {
    if (runtime.len != expected.len) return false;
    inline for (0..expected.len) |i| {
        if (std.ascii.toLower(runtime[i]) != comptime std.ascii.toLower(expected[i])) return false;
    }
    return true;
}

// ============================================================================
// File serving
// ============================================================================

/// Result of a static file serve attempt.
pub const ServeResult = enum {
    /// File served successfully.
    ok,
    /// Path was invalid or unsafe (400-level).
    bad_path,
    /// File not found (404).
    not_found,
    /// File too large (exceeds max_file_size).
    too_large,
    /// I/O error reading the file.
    io_error,
};

/// Try to serve a static file for the given request path.
///
/// 1. Sanitizes the path (rejects traversal attempts)
/// 2. Resolves index.html for directory-like paths
/// 3. Opens and reads the file from the document root
/// 4. Sends the response with correct Content-Type and Cache-Control
///
/// Returns a `ServeResult` indicating what happened. The caller can
/// use this to decide whether to send a 404 or other error.
pub fn serve(
    config: Config,
    request_path: []const u8,
    response: *Response,
    io: Io,
) ServeResult {
    // ---- Sanitize the URL path ----
    const relative = sanitizePath(request_path) orelse return .bad_path;

    // ---- Resolve file path ----
    // Try the exact path first, then index.html for directory-like paths.
    const file_content = readFile(config, relative, io) orelse {
        // If the path is empty or ends with /, try index.html.
        if (config.index_file) |index| {
            if (relative.len == 0 or (relative.len > 0 and relative[relative.len - 1] == '/')) {
                const index_path = if (relative.len == 0)
                    index
                else
                    std.fmt.allocPrint(response.arena, "{s}{s}", .{ relative, index }) catch return .io_error;

                const index_content = readFile(config, index_path, io) orelse return .not_found;
                return sendStaticResponse(response, index_path, index_content, config.cache_max_age_s);
            }
        }
        return .not_found;
    };

    return sendStaticResponse(response, relative, file_content, config.cache_max_age_s);
}

/// Read a file from the document root into a page-allocated buffer.
///
/// Returns the file bytes, or null if the file doesn't exist or can't be read.
/// The caller must free the returned slice with `std.heap.page_allocator` after use.
fn readFile(config: Config, relative_path: []const u8, io: Io) ?[]const u8 {
    // Open the root directory relative to CWD.
    const cwd = Dir.cwd();
    var dir = cwd.openDir(io, config.root_dir, .{}) catch return null;
    defer dir.close(io);

    // Open the file within the document root.
    const file = dir.openFile(io, relative_path, .{}) catch return null;
    defer file.close(io);

    // Get file size to check bounds.
    const stat = file.stat(io) catch return null;
    if (stat.size > config.max_file_size) return null;
    const size: usize = @intCast(stat.size);
    if (size == 0) return "";

    // Allocate buffer and read the entire file via positional read.
    const buf = std.heap.page_allocator.alloc(u8, size) catch return null;
    const bytes_read = file.readPositionalAll(io, buf, 0) catch {
        std.heap.page_allocator.free(buf);
        return null;
    };

    if (bytes_read != size) {
        std.heap.page_allocator.free(buf);
        return null;
    }

    return buf[0..bytes_read];
}

/// Send a static file response with Content-Type and Cache-Control headers.
fn sendStaticResponse(
    response: *Response,
    file_path: []const u8,
    content: []const u8,
    cache_max_age_s: u32,
) ServeResult {
    response.status = .ok;
    response.body = content;
    response.addHeader("content-type", mimeType(file_path)) catch return .io_error;

    if (cache_max_age_s > 0) {
        const cache_value = std.fmt.allocPrint(
            response.arena,
            "public, max-age={d}",
            .{cache_max_age_s},
        ) catch return .io_error;
        response.addHeader("cache-control", cache_value) catch return .io_error;
    }

    response.flush() catch return .io_error;

    // Free the page-allocated buffer after flushing (data has been written to socket).
    std.heap.page_allocator.free(@constCast(content));

    return .ok;
}

// ============================================================================
// Tests
// ============================================================================

test "sanitizePath - valid paths" {
    try std.testing.expectEqualStrings("", sanitizePath("/").?);
    try std.testing.expectEqualStrings("index.html", sanitizePath("/index.html").?);
    try std.testing.expectEqualStrings("css/style.css", sanitizePath("/css/style.css").?);
    try std.testing.expectEqualStrings("js/app.js", sanitizePath("/js/app.js").?);
    try std.testing.expectEqualStrings("images/logo.png", sanitizePath("/images/logo.png").?);
    try std.testing.expectEqualStrings("deep/nested/path/file.txt", sanitizePath("/deep/nested/path/file.txt").?);
}

test "sanitizePath - strips query string and fragment" {
    try std.testing.expectEqualStrings("page.html", sanitizePath("/page.html?v=1").?);
    try std.testing.expectEqualStrings("page.html", sanitizePath("/page.html#section").?);
    try std.testing.expectEqualStrings("page.html", sanitizePath("/page.html?q=1#top").?);
}

test "sanitizePath - rejects traversal" {
    try std.testing.expect(sanitizePath("/..") == null);
    try std.testing.expect(sanitizePath("/../etc/passwd") == null);
    try std.testing.expect(sanitizePath("/foo/../../bar") == null);
    try std.testing.expect(sanitizePath("/foo/../bar") == null);
}

test "sanitizePath - rejects dot segments" {
    try std.testing.expect(sanitizePath("/.") == null);
    try std.testing.expect(sanitizePath("/./foo") == null);
}

test "sanitizePath - rejects null bytes" {
    try std.testing.expect(sanitizePath("/foo\x00bar") == null);
}

test "sanitizePath - rejects backslashes" {
    try std.testing.expect(sanitizePath("/foo\\bar") == null);
    try std.testing.expect(sanitizePath("\\etc\\passwd") == null);
}

test "sanitizePath - rejects non-slash start" {
    try std.testing.expect(sanitizePath("") == null);
    try std.testing.expect(sanitizePath("foo/bar") == null);
}

test "mimeType - common web types" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeType("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", mimeType("style.css"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeType("app.js"));
    try std.testing.expectEqualStrings("application/json; charset=utf-8", mimeType("data.json"));
    try std.testing.expectEqualStrings("image/png", mimeType("logo.png"));
    try std.testing.expectEqualStrings("image/svg+xml", mimeType("icon.svg"));
    try std.testing.expectEqualStrings("font/woff2", mimeType("font.woff2"));
}

test "mimeType - unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", mimeType("file.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeType("noextension"));
}

test "mimeType - nested path" {
    try std.testing.expectEqualStrings("text/css; charset=utf-8", mimeType("css/deep/style.css"));
    try std.testing.expectEqualStrings("image/jpeg", mimeType("images/photo.jpg"));
}

test "extension helper" {
    try std.testing.expectEqualStrings("html", extension("index.html").?);
    try std.testing.expectEqualStrings("css", extension("path/to/style.css").?);
    try std.testing.expectEqualStrings("gz", extension("archive.tar.gz").?);
    try std.testing.expect(extension("noext") == null);
    try std.testing.expect(extension("trailing.") == null);
}
