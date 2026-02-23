//! HTML template engine module root.
//!
//! Re-exports all public types for the comptime template engine
//! and htmx integration helpers.
//!
//! ## Overview
//!
//! - **Template** — Comptime HTML template engine. Templates are parsed at
//!   compile time; rendering is a zero-overhead sequence of buffer writes.
//! - **Htmx** — Server-side htmx helpers. Request detection (is this an
//!   htmx AJAX request?) and response header utilities (trigger events,
//!   redirect, push URL, etc.).
//!
//! ## Quick Example
//!
//! ```zig
//! const html = @import("zzigtop").html;
//!
//! // Compile template at comptime
//! const UserRow = html.Template.compile(
//!     \\<tr hx-get="/users/{{id}}" hx-target="#detail">
//!     \\  <td>{{name}}</td><td>{{email}}</td>
//!     \\</tr>
//! );
//!
//! fn handleUsers(req: *http.Request, res: *http.Response, _: Io) !void {
//!     const users = try getUsers();
//!     if (html.Htmx.isHtmxRequest(req)) {
//!         // htmx request — return fragment
//!         const body = try UserRow.render(req.arena, .{ ... });
//!         try res.sendHtml(.ok, body);
//!     } else {
//!         // Full page request
//!         const body = try FullPage.render(req.arena, .{ ... });
//!         try res.sendHtml(.ok, body);
//!     }
//! }
//! ```

/// Comptime HTML template engine.
///
/// Templates are parsed at compile time into an optimized render function.
/// Supports variable interpolation, loops (`#each`), conditionals (`#if`/`#else`),
/// and HTML auto-escaping.
pub const Template = @import("template.zig");

/// htmx server-side integration helpers.
///
/// Request detection (HX-Request, HX-Boosted, HX-Target) and response
/// header utilities (HX-Trigger, HX-Redirect, HX-Push-Url, HX-Reswap, etc.).
pub const Htmx = @import("htmx.zig");

test {
    // Run all tests in submodules
    _ = Template;
    _ = Htmx;
}
