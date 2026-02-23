//! htmx helpers for server-side integration.
//!
//! Provides request detection and response header utilities for
//! building htmx-powered applications with the Zig HTTP server.
//!
//! ## htmx Request Detection
//!
//! htmx sends several headers with every AJAX request. Use these
//! to decide whether to return a full page or an HTML fragment:
//!
//! ```zig
//! const Htmx = @import("html").Htmx;
//!
//! fn handleUsers(req: *Request, res: *Response, _: Io) !void {
//!     const users = try getUsers();
//!     if (Htmx.isHtmxRequest(req)) {
//!         // htmx request — return just the table body fragment
//!         const html = try user_rows.render(req.arena, .{ .users = users });
//!         try res.sendHtml(.ok, html);
//!     } else {
//!         // Full page request — return complete HTML document
//!         const html = try user_page.render(req.arena, .{ .users = users });
//!         try res.sendHtml(.ok, html);
//!     }
//! }
//! ```
//!
//! ## htmx Response Headers
//!
//! Control htmx behavior from the server by setting response headers:
//!
//! ```zig
//! try Htmx.trigger(res, "userCreated");    // Fire client-side event
//! try Htmx.redirect(res, "/login");         // Client-side redirect
//! try Htmx.pushUrl(res, "/users/42");       // Update browser URL
//! try Htmx.reswap(res, .outerHTML);         // Override swap strategy
//! try Htmx.retarget(res, "#main");          // Override target element
//! try Htmx.refresh(res);                    // Full page refresh
//! ```

const std = @import("std");
const Request = @import("../http/request.zig");
const Response = @import("../http/response.zig");

// ============================================================================
// Request Detection
// ============================================================================

/// Returns true if this request was made by htmx (has `HX-Request: true` header).
///
/// Use this to choose between returning a full HTML page or a fragment:
///   - htmx request → return HTML fragment (partial)
///   - Normal request → return full HTML document
pub fn isHtmxRequest(request: *const Request) bool {
    if (request.getHeader("hx-request")) |val| {
        return std.ascii.eqlIgnoreCase(val, "true");
    }
    return false;
}

/// Returns true if this htmx request was triggered by `hx-boost`.
///
/// Boosted requests replace the entire `<body>` content. You may want to
/// return a full page layout (minus `<html>`/`<head>`) for boosted requests
/// and a small fragment for regular htmx requests.
pub fn isBoosted(request: *const Request) bool {
    if (request.getHeader("hx-boosted")) |val| {
        return std.ascii.eqlIgnoreCase(val, "true");
    }
    return false;
}

/// Returns true if this request is a history-restore request.
///
/// htmx sends this header when restoring history via the back button.
/// You should return a full page for these requests.
pub fn isHistoryRestore(request: *const Request) bool {
    if (request.getHeader("hx-history-restore-request")) |val| {
        return std.ascii.eqlIgnoreCase(val, "true");
    }
    return false;
}

/// Get the current URL of the browser when the htmx request was made.
pub fn currentUrl(request: *const Request) ?[]const u8 {
    return request.getHeader("hx-current-url");
}

/// Get the `id` of the element that triggered the htmx request.
pub fn triggerId(request: *const Request) ?[]const u8 {
    return request.getHeader("hx-trigger");
}

/// Get the `name` of the element that triggered the htmx request.
pub fn triggerName(request: *const Request) ?[]const u8 {
    return request.getHeader("hx-trigger-name");
}

/// Get the `id` of the target element for the htmx request.
pub fn target(request: *const Request) ?[]const u8 {
    return request.getHeader("hx-target");
}

/// Get the URL that htmx wants to make a request to.
pub fn prompt(request: *const Request) ?[]const u8 {
    return request.getHeader("hx-prompt");
}

// ============================================================================
// Response Headers
// ============================================================================

/// htmx swap strategies for `HX-Reswap` response header.
pub const SwapStrategy = enum {
    /// Replace the inner html of the target element.
    innerHTML,
    /// Replace the entire target element with the response.
    outerHTML,
    /// Insert the response before the target element.
    beforebegin,
    /// Insert the response before the first child of the target element.
    afterbegin,
    /// Insert the response after the last child of the target element.
    beforeend,
    /// Insert the response after the target element.
    afterend,
    /// Delete the target element regardless of the response.
    delete,
    /// Does not append content from response.
    none,
};

/// Trigger a client-side event after the response is processed.
///
/// The event can be caught with `htmx.on("eventName", ...)` or
/// standard `addEventListener()` in JavaScript.
///
/// Example:
///   try Htmx.trigger(response, "userCreated");
///   // Client: htmx.on("userCreated", function() { ... })
pub fn trigger(response: *Response, event: []const u8) !void {
    try response.addHeader("HX-Trigger", event);
}

/// Trigger a client-side event after the settle step.
pub fn triggerAfterSettle(response: *Response, event: []const u8) !void {
    try response.addHeader("HX-Trigger-After-Settle", event);
}

/// Trigger a client-side event after the swap step.
pub fn triggerAfterSwap(response: *Response, event: []const u8) !void {
    try response.addHeader("HX-Trigger-After-Swap", event);
}

/// Perform a client-side redirect to the given URL.
///
/// This does a full page navigation (not an htmx swap).
pub fn redirect(response: *Response, url: []const u8) !void {
    try response.addHeader("HX-Redirect", url);
}

/// Push a URL into the browser history stack.
///
/// Updates the address bar without a page reload.
pub fn pushUrl(response: *Response, url: []const u8) !void {
    try response.addHeader("HX-Push-Url", url);
}

/// Replace the current URL in the browser location bar.
///
/// Unlike pushUrl, this does NOT create a new history entry.
pub fn replaceUrl(response: *Response, url: []const u8) !void {
    try response.addHeader("HX-Replace-Url", url);
}

/// Override the swap strategy that htmx will use for this response.
///
/// Normally htmx uses the `hx-swap` attribute on the triggering element.
/// This header lets the server override that choice per-response.
pub fn reswap(response: *Response, strategy: SwapStrategy) !void {
    try response.addHeader("HX-Reswap", @tagName(strategy));
}

/// Override the target element for the swap.
///
/// Takes a CSS selector. Normally htmx uses the `hx-target` attribute
/// on the triggering element. This header overrides that per-response.
pub fn retarget(response: *Response, css_selector: []const u8) !void {
    try response.addHeader("HX-Retarget", css_selector);
}

/// Trigger a full page refresh from the server.
///
/// Useful after operations that change global state (e.g., login/logout).
pub fn refresh(response: *Response) !void {
    try response.addHeader("HX-Refresh", "true");
}

/// Send a 286 status code to stop htmx polling.
///
/// When an element has `hx-trigger="every 2s"`, returning 286
/// tells htmx to stop issuing further polling requests.
pub fn stopPolling(response: *Response) void {
    // HTTP 286 is not a standard status code, but htmx interprets it
    // as "stop polling". We set the status directly.
    response.status = @enumFromInt(286);
}

// ============================================================================
// Tests
// ============================================================================

test "isHtmxRequest — true" {
    var request = testRequest("GET / HTTP/1.1\r\nHX-Request: true\r\nHost: localhost\r\n\r\n");
    try std.testing.expect(isHtmxRequest(&request));
}

test "isHtmxRequest — false (no header)" {
    var request = testRequest("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try std.testing.expect(!isHtmxRequest(&request));
}

test "isBoosted — true" {
    var request = testRequest("GET / HTTP/1.1\r\nHX-Boosted: true\r\nHX-Request: true\r\n\r\n");
    try std.testing.expect(isBoosted(&request));
}

test "isBoosted — false" {
    var request = testRequest("GET / HTTP/1.1\r\nHX-Request: true\r\n\r\n");
    try std.testing.expect(!isBoosted(&request));
}

test "isHistoryRestore — true" {
    var request = testRequest("GET / HTTP/1.1\r\nHX-History-Restore-Request: true\r\n\r\n");
    try std.testing.expect(isHistoryRestore(&request));
}

test "target header" {
    var request = testRequest("GET / HTTP/1.1\r\nHX-Target: #main-content\r\nHX-Request: true\r\n\r\n");
    const t = target(&request);
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("#main-content", t.?);
}

test "currentUrl header" {
    var request = testRequest("GET / HTTP/1.1\r\nHX-Current-URL: http://localhost:8080/page\r\n\r\n");
    const url = currentUrl(&request);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("http://localhost:8080/page", url.?);
}

/// Create a test Request with the given raw header buffer.
fn testRequest(comptime head_buf: []const u8) Request {
    return .{
        .method = .GET,
        .path = "/",
        .version = .@"HTTP/1.1",
        .keep_alive = true,
        .content_type = null,
        .content_length = null,
        .arena = std.testing.allocator,
        .head_buffer = head_buf,
    };
}
