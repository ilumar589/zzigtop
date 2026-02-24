//! HTML content extraction and data normalization.
//!
//! Provides lightweight HTML text pattern matching to extract football
//! data from scraped pages. This is not a full DOM parser — it uses
//! targeted string scanning to find data in common HTML patterns.
//!
//! Each site has specific extraction logic since HTML structures vary.
//! The parser outputs normalized `Types` structs ready for DB insertion.

const std = @import("std");
const Types = @import("types.zig");

// ============================================================================
// Generic HTML Extraction Utilities
// ============================================================================

/// Extract text content between HTML tags.
/// Given "<td>Hello World</td>", returns "Hello World".
pub fn extractTagContent(html: []const u8, tag: []const u8) ?[]const u8 {
    const open_tag_start = std.mem.indexOf(u8, html, "<") orelse return null;
    _ = tag;

    // Find the closing >
    const open_tag_end = std.mem.indexOfPos(u8, html, open_tag_start, ">") orelse return null;
    const content_start = open_tag_end + 1;

    // Find the closing tag
    const close_tag = std.mem.indexOfPos(u8, html, content_start, "</") orelse return null;

    if (content_start >= close_tag) return null;
    return html[content_start..close_tag];
}

/// Extract all text segments between matching open/close tag pairs.
/// Returns slices into the input HTML (zero-copy).
pub fn extractAllTagContents(
    allocator: std.mem.Allocator,
    html_content: []const u8,
    open_pattern: []const u8,
    close_pattern: []const u8,
) ![]const []const u8 {
    var results = std.ArrayList([]const u8){};
    var pos: usize = 0;

    while (pos < html_content.len) {
        const start = std.mem.indexOfPos(u8, html_content, pos, open_pattern) orelse break;
        const content_start = start + open_pattern.len;
        const end = std.mem.indexOfPos(u8, html_content, content_start, close_pattern) orelse break;

        if (content_start < end) {
            const content = std.mem.trim(u8, html_content[content_start..end], " \t\n\r");
            if (content.len > 0) {
                try results.append(allocator, content);
            }
        }
        pos = end + close_pattern.len;
    }

    return results.toOwnedSlice(allocator);
}

/// Extract an attribute value from an HTML tag.
/// Given `<a href="/link">`, extractAttribute(tag, "href") returns "/link".
pub fn extractAttribute(tag_html: []const u8, attr_name: []const u8) ?[]const u8 {
    // Look for attr_name="
    const attr_prefix = attr_name;
    const attr_start = std.mem.indexOf(u8, tag_html, attr_prefix) orelse return null;
    const eq_pos = std.mem.indexOfPos(u8, tag_html, attr_start + attr_prefix.len, "=") orelse return null;

    // Skip whitespace and find quote
    var pos = eq_pos + 1;
    while (pos < tag_html.len and (tag_html[pos] == ' ' or tag_html[pos] == '\t')) : (pos += 1) {}

    if (pos >= tag_html.len) return null;
    const quote = tag_html[pos];
    if (quote != '"' and quote != '\'') return null;

    const value_start = pos + 1;
    const value_end = std.mem.indexOfPos(u8, tag_html, value_start, &.{quote}) orelse return null;

    return tag_html[value_start..value_end];
}

/// Strip all HTML tags from a string, returning plain text.
pub fn stripHtmlTags(allocator: std.mem.Allocator, html_content: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    var in_tag = false;

    for (html_content) |c| {
        if (c == '<') {
            in_tag = true;
        } else if (c == '>') {
            in_tag = false;
        } else if (!in_tag) {
            try result.append(allocator, c);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Decode common HTML entities (&amp; &lt; &gt; &quot; &#39;).
pub fn decodeHtmlEntities(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try result.append(allocator, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try result.append(allocator, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try result.append(allocator, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try result.append(allocator, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, input[i..], "&#39;")) {
                try result.append(allocator, '\'');
                i += 5;
            } else if (std.mem.startsWith(u8, input[i..], "&nbsp;")) {
                try result.append(allocator, ' ');
                i += 6;
            } else {
                try result.append(allocator, input[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Score Extraction
// ============================================================================

/// Parsed score from a match.
pub const ParsedScore = struct {
    home_team: []const u8 = "",
    away_team: []const u8 = "",
    home_score: ?i32 = null,
    away_score: ?i32 = null,
    status: []const u8 = "completed",
    competition: []const u8 = "",
};

/// Try to parse a score line like "Team A 2 - 1 Team B" or "Team A 2-1 Team B".
pub fn parseScoreLine(line: []const u8) ?ParsedScore {
    // Look for patterns like "2 - 1" or "2-1"
    const trimmed = std.mem.trim(u8, line, " \t\n\r");
    if (trimmed.len == 0) return null;

    // Find the score separator (digit - digit pattern)
    var dash_pos: ?usize = null;
    var i: usize = 1;
    while (i < trimmed.len - 1) : (i += 1) {
        if (trimmed[i] == '-') {
            // Check if there's a digit before and after (with optional spaces)
            var before = i - 1;
            while (before > 0 and trimmed[before] == ' ') : (before -= 1) {}
            var after = i + 1;
            while (after < trimmed.len and trimmed[after] == ' ') : (after += 1) {}

            if (before < trimmed.len and after < trimmed.len and
                std.ascii.isDigit(trimmed[before]) and std.ascii.isDigit(trimmed[after]))
            {
                dash_pos = i;
                break;
            }
        }
    }

    const dash = dash_pos orelse return null;

    // Extract scores
    var score_start = dash - 1;
    while (score_start > 0 and (std.ascii.isDigit(trimmed[score_start - 1]) or trimmed[score_start - 1] == ' ')) : (score_start -= 1) {}
    if (trimmed[score_start] == ' ') score_start += 1;

    var score_end = dash + 1;
    while (score_end < trimmed.len and trimmed[score_end] == ' ') : (score_end += 1) {}
    while (score_end < trimmed.len and std.ascii.isDigit(trimmed[score_end])) : (score_end += 1) {}

    // Parse numeric scores
    const home_score_str = std.mem.trim(u8, trimmed[score_start..dash], " ");
    const away_score_str = std.mem.trim(u8, trimmed[dash + 1 .. score_end], " ");

    const home_score = std.fmt.parseInt(i32, home_score_str, 10) catch return null;
    const away_score = std.fmt.parseInt(i32, away_score_str, 10) catch return null;

    // Extract team names
    const home_team = std.mem.trim(u8, trimmed[0..score_start], " ");
    const away_team = std.mem.trim(u8, trimmed[score_end..], " ");

    if (home_team.len == 0 or away_team.len == 0) return null;

    return .{
        .home_team = home_team,
        .away_team = away_team,
        .home_score = home_score,
        .away_score = away_score,
        .status = "completed",
    };
}

// ============================================================================
// JSON Data Extraction
// ============================================================================

/// Extract JSON-LD structured data from HTML (common in sports sites).
/// Looks for <script type="application/ld+json">...</script> blocks.
pub fn extractJsonLd(allocator: std.mem.Allocator, html_content: []const u8) ![]const []const u8 {
    return extractAllTagContents(
        allocator,
        html_content,
        "<script type=\"application/ld+json\">",
        "</script>",
    );
}

/// Extract data from inline JavaScript variables.
/// Looks for patterns like `var data = {...};` or `const data = {...};`.
pub fn extractJsVariable(html_content: []const u8, var_name: []const u8) ?[]const u8 {
    // Look for "var_name = " or "var_name ="
    const patterns = [_][]const u8{ " = {", "={" };
    for (patterns) |eq_pattern| {
        const search = var_name;
        const var_start = std.mem.indexOf(u8, html_content, search) orelse continue;
        const eq_pos = std.mem.indexOfPos(u8, html_content, var_start + search.len, eq_pattern) orelse continue;

        // Find the JSON object boundaries
        const json_start = eq_pos + eq_pattern.len - 1; // Start at {
        var depth: i32 = 1;
        var pos = json_start + 1;
        while (pos < html_content.len and depth > 0) : (pos += 1) {
            if (html_content[pos] == '{') depth += 1;
            if (html_content[pos] == '}') depth -= 1;
        }
        if (depth == 0) {
            return html_content[json_start..pos];
        }
    }
    return null;
}

/// Build a JSON summary of extracted data for storage.
pub fn buildExtractedJson(
    allocator: std.mem.Allocator,
    site_id: []const u8,
    data_type: []const u8,
    items_count: usize,
    raw_items: []const []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8){};

    try buf.appendSlice(allocator, "{\"site\":\"");
    try buf.appendSlice(allocator, site_id);
    try buf.appendSlice(allocator, "\",\"type\":\"");
    try buf.appendSlice(allocator, data_type);
    try buf.appendSlice(allocator, "\",\"count\":");

    var count_buf: [12]u8 = undefined;
    const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{items_count});
    try buf.appendSlice(allocator, count_str);

    try buf.appendSlice(allocator, ",\"items\":[");
    for (raw_items, 0..) |item, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\"");
        // Escape quotes in item text
        for (item) |c| {
            if (c == '"') {
                try buf.appendSlice(allocator, "\\\"");
            } else if (c == '\\') {
                try buf.appendSlice(allocator, "\\\\");
            } else if (c == '\n') {
                try buf.appendSlice(allocator, "\\n");
            } else {
                try buf.append(allocator, c);
            }
        }
        try buf.appendSlice(allocator, "\"");
    }
    try buf.appendSlice(allocator, "]}");

    return buf.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "extractTagContent basic" {
    const html = "<td>Hello World</td>";
    const result = extractTagContent(html, "td");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Hello World", result.?);
}

test "extractAttribute href" {
    const html = "<a href=\"/link/to/page\" class=\"btn\">";
    const result = extractAttribute(html, "href");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/link/to/page", result.?);
}

test "stripHtmlTags" {
    const allocator = std.testing.allocator;
    const result = try stripHtmlTags(allocator, "<p>Hello <b>World</b></p>");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello World", result);
}

test "decodeHtmlEntities" {
    const allocator = std.testing.allocator;
    const result = try decodeHtmlEntities(allocator, "A &amp; B &lt; C");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A & B < C", result);
}

test "parseScoreLine valid" {
    const result = parseScoreLine("Arsenal 2 - 1 Chelsea");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Arsenal", result.?.home_team);
    try std.testing.expectEqualStrings("Chelsea", result.?.away_team);
    try std.testing.expectEqual(@as(i32, 2), result.?.home_score.?);
    try std.testing.expectEqual(@as(i32, 1), result.?.away_score.?);
}

test "parseScoreLine no dash" {
    const result = parseScoreLine("No score here");
    try std.testing.expect(result == null);
}

test "buildExtractedJson" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "item1", "item2" };
    const json = try buildExtractedJson(allocator, "espn", "scores", 2, &items);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"site\":\"espn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
}
