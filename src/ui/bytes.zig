//! malt — shared byte humanizer for the CLI and TUI presentation surfaces.
//! Lives in the ui/ sink so both cli/* and tui/* import it downward; no
//! feature-layer deps, so it never re-introduces the weight (sqlite, arg
//! parsers) that spawned the per-command mirrors.

const std = @import("std");

/// Format `bytes` as `"{d:.1} {unit}"` over B/KB/MB/GB/TB, 1024 step.
/// `512` → `"512.0 B"`, `1024` → `"1.0 KB"`; caps at TB. On `buf` overflow
/// returns `"?"`, matching the incumbent copies' catch-fallback.
pub fn humanize(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

/// Nullable convenience for size columns that render `"-"` when the size is
/// unknown. Delegates the number shape to `humanize` — no `u == 0` special
/// case, so sub-KB sizes keep the canonical decimal shape.
pub fn humanizeOpt(bytes: ?u64, buf: []u8) []const u8 {
    return humanize(bytes orelse return "-", buf);
}

const testing = std.testing;

test "humanize scales across units with a single decimal" {
    var buf: [32]u8 = undefined;
    // Sub-KB values keep the decimal ("512.0 B"), pinning the shape the
    // installed tab converges onto (its old "512 B" was the outlier).
    try testing.expectEqualStrings("0.0 B", humanize(0, &buf));
    try testing.expectEqualStrings("512.0 B", humanize(512, &buf));
    try testing.expectEqualStrings("1023.0 B", humanize(1023, &buf));
    try testing.expectEqualStrings("1.0 KB", humanize(1024, &buf));
    try testing.expectEqualStrings("1.5 KB", humanize(1536, &buf));
    try testing.expectEqualStrings("1.0 MB", humanize(1024 * 1024, &buf));
    try testing.expectEqualStrings("1.0 GB", humanize(1024 * 1024 * 1024, &buf));
    try testing.expectEqualStrings("1.0 TB", humanize(1024 * 1024 * 1024 * 1024, &buf));
}

test "humanize caps the largest unit at TB" {
    var buf: [32]u8 = undefined;
    const beyond_tb: u64 = 2048 * 1024 * 1024 * 1024 * 1024;
    try testing.expectEqualStrings("2048.0 TB", humanize(beyond_tb, &buf));
}

test "humanize returns \"?\" on buffer overflow" {
    var buf: [3]u8 = undefined;
    try testing.expectEqualStrings("?", humanize(1024, &buf));
}

test "humanizeOpt delegates non-null and renders \"-\" for null" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("-", humanizeOpt(null, &buf));
    // No `u == 0` special case: zero keeps the canonical decimal, unlike the
    // installed tab's dropped `"{d} B"` integer branch.
    try testing.expectEqualStrings("0.0 B", humanizeOpt(0, &buf));
    try testing.expectEqualStrings("1.5 KB", humanizeOpt(1536, &buf));
}
