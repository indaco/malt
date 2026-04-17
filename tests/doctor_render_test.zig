//! malt — doctor row renderer tests
//!
//! Covers `doctor.renderCheckRow` in all combinations of status,
//! color, and emoji. The renderer is what keeps `mt doctor` visually
//! consistent with the rest of malt's UI (✓/⚠/✗ glyphs, dim detail
//! suffix); a regression here is a visible UX drift, so the render
//! shape is worth locking in.

const std = @import("std");
const testing = std.testing;
const doctor = @import("malt").doctor;

const Buf = struct {
    list: std.ArrayList(u8) = .empty,

    pub fn writeAll(self: *Buf, bytes: []const u8) !void {
        try self.list.appendSlice(testing.allocator, bytes);
    }

    fn deinit(self: *Buf) void {
        self.list.deinit(testing.allocator);
    }
};

fn render(
    status: doctor.CheckStatus,
    name: []const u8,
    detail: ?[]const u8,
    opts: doctor.CheckStyle,
) ![]const u8 {
    var buf: Buf = .{};
    try doctor.renderCheckRow(&buf, status, name, detail, opts);
    return buf.list.toOwnedSlice(testing.allocator);
}

// ── plain (no color, no emoji) ───────────────────────────────────────

test "plain: ok without detail" {
    const s = try render(.ok, "SQLite integrity", null, .{ .color = false, .emoji = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  * SQLite integrity\n", s);
}

test "plain: warn with detail uses em-dash separator" {
    const s = try render(.warn_status, "Disk space", "Only 500 MB free", .{ .color = false, .emoji = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  ! Disk space — Only 500 MB free\n", s);
}

test "plain: err with detail" {
    const s = try render(.err_status, "Missing kegs", "3 keg(s) missing", .{ .color = false, .emoji = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  x Missing kegs — 3 keg(s) missing\n", s);
}

// ── emoji-only (no color) ────────────────────────────────────────────

test "emoji no color: ok uses ✓ glyph" {
    const s = try render(.ok, "APFS volume", null, .{ .color = false, .emoji = true });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  ✓ APFS volume\n", s);
}

test "emoji no color: warn uses ⚠ glyph" {
    const s = try render(.warn_status, "Stale lock", "PID 1234 abandoned", .{ .color = false, .emoji = true });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  ⚠ Stale lock — PID 1234 abandoned\n", s);
}

test "emoji no color: err uses ✗ glyph" {
    const s = try render(.err_status, "SQLite integrity", "Database may be corrupt", .{ .color = false, .emoji = true });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  ✗ SQLite integrity — Database may be corrupt\n", s);
}

// ── full color ───────────────────────────────────────────────────────

test "color: ok wraps glyph in green and detail in dim" {
    const s = try render(.ok, "Name", "Detail", .{ .color = true, .emoji = true });
    defer testing.allocator.free(s);
    // Green glyph + reset, plain name, then dim em-dash + detail + reset
    try testing.expectEqualStrings(
        "  \x1b[32m✓\x1b[0m Name \x1b[2m— Detail\x1b[0m\n",
        s,
    );
}

test "color: warn glyph is yellow" {
    const s = try render(.warn_status, "X", null, .{ .color = true, .emoji = true });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  \x1b[33m⚠\x1b[0m X\n", s);
}

test "color: err glyph is red" {
    const s = try render(.err_status, "X", null, .{ .color = true, .emoji = true });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  \x1b[31m✗\x1b[0m X\n", s);
}

test "color off + emoji on: no ANSI codes leak through" {
    const s = try render(.ok, "Z", "d", .{ .color = false, .emoji = true });
    defer testing.allocator.free(s);
    // No \x1b anywhere — the emoji glyph is fine (multibyte but not ANSI).
    try testing.expect(std.mem.indexOf(u8, s, "\x1b") == null);
    try testing.expectEqualStrings("  ✓ Z — d\n", s);
}

// ── invariants ───────────────────────────────────────────────────────

test "row always ends with newline" {
    const cases = [_]struct { st: doctor.CheckStatus, name: []const u8, det: ?[]const u8 }{
        .{ .st = .ok, .name = "a", .det = null },
        .{ .st = .warn_status, .name = "b", .det = "x" },
        .{ .st = .err_status, .name = "c", .det = "y" },
    };
    for (cases) |cs| {
        const s = try render(cs.st, cs.name, cs.det, .{ .color = true, .emoji = true });
        defer testing.allocator.free(s);
        try testing.expect(std.mem.endsWith(u8, s, "\n"));
    }
}

test "row always starts with two-space indent" {
    const cases = [_]doctor.CheckStatus{ .ok, .warn_status, .err_status };
    for (cases) |st| {
        const s = try render(st, "n", null, .{ .color = false, .emoji = false });
        defer testing.allocator.free(s);
        try testing.expect(std.mem.startsWith(u8, s, "  "));
    }
}

test "empty detail string still renders (edge case)" {
    // A non-null but empty detail shows the em-dash with nothing after.
    // Intentionally preserved so callers don't get a silent skip.
    const s = try render(.ok, "N", "", .{ .color = false, .emoji = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("  * N — \n", s);
}

test "null detail omits the em-dash entirely" {
    const s = try render(.ok, "N", null, .{ .color = false, .emoji = false });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "—") == null);
    try testing.expect(std.mem.indexOf(u8, s, "-") == null);
}
