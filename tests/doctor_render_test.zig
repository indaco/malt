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
const color = @import("malt").color;
const io_mod = @import("malt").io_mod;
const output = @import("malt").output;

// Pin the palette so escape-string assertions stay deterministic
// across terminals. Tests below run against dark+basic.
comptime {
    // no-op, just documents the shared assumption.
}

fn render(
    status: doctor.CheckStatus,
    name: []const u8,
    detail: ?[]const u8,
    opts: doctor.CheckStyle,
) ![]const u8 {
    color.setBackgroundForTest(color.Background.dark);
    color.setTruecolorForTest(false);
    defer color.setBackgroundForTest(null);
    defer color.setTruecolorForTest(null);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try doctor.renderCheckRow(&aw.writer, status, name, detail, opts);
    return aw.toOwnedSlice();
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

// ── countMissingLocalSources ────────────────────────────────────────
//
// The local-source check walks `kegs WHERE tap='local'` and reports
// how many rows point at a path that no longer exists. Exercised with
// an in-memory SQLite so the test is hermetic.

const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const patch = malt.patch;

// ── external-tool availability check ─────────────────────────────────
//
// Guards the doctor row that surfaces `install_name_tool` (today) or
// `patchelf` (after the Linux backend lands). The tool name is read
// from the facade so the check is platform-agnostic at the call site.

test "doctor.externalToolAvailable returns true when the tool is on PATH" {
    // `install_name_tool` is part of Xcode Command Line Tools and is
    // always installed in the repo's dev environment — any bot that
    // can build malt can find it.
    try testing.expect(malt.doctor.externalToolAvailable(patch.external_tool_name));
}

test "doctor.externalToolAvailable returns false for a clearly-missing binary" {
    try testing.expect(!malt.doctor.externalToolAvailable("mt_no_such_binary_ever_xyz"));
}

fn seedKeg(db: *sqlite.Database, name: []const u8, tap: []const u8, full_name: []const u8) !void {
    var stmt = try db.prepare(
        "INSERT INTO kegs (name, full_name, version, tap, store_sha256, cellar_path, install_reason)" ++
            " VALUES (?1, ?2, '1.0', ?3, '0' , '/opt/malt/Cellar/x/1.0', 'direct');",
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, full_name);
    try stmt.bindText(3, tap);
    _ = try stmt.step();
}

test "countMissingLocalSources ignores non-local kegs" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try seedKeg(&db, "foo", "homebrew/core", "foo");
    try seedKeg(&db, "bar", "user/tap", "bar");

    const got = doctor.countMissingLocalSources(testing.allocator, &db);
    try testing.expectEqual(@as(u32, 0), got.total);
    try testing.expectEqual(@as(u32, 0), got.stale);
}

test "countMissingLocalSources flags kegs whose .rb no longer exists" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try seedKeg(&db, "ghost", "local", "/tmp/mt_doctor_vanished_formula_xyz.rb");

    const got = doctor.countMissingLocalSources(testing.allocator, &db);
    try testing.expectEqual(@as(u32, 1), got.total);
    try testing.expectEqual(@as(u32, 1), got.stale);
}

test "countMissingLocalSources does not flag kegs whose .rb still exists" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // Use the running test binary as the "file exists" witness — it
    // is guaranteed to be readable from the test process.
    const self_path = "/tmp/mt_doctor_present_formula.rb";
    const f = try malt.fs_compat.createFileAbsolute(self_path, .{});
    defer malt.fs_compat.cwd().deleteFile(self_path) catch {};
    try f.writeAll("class X end\n");
    f.close();

    try seedKeg(&db, "present", "local", self_path);

    const got = doctor.countMissingLocalSources(testing.allocator, &db);
    try testing.expectEqual(@as(u32, 1), got.total);
    try testing.expectEqual(@as(u32, 0), got.stale);
}

test "countMissingLocalSources mixes stale and present rows correctly" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const present_path = "/tmp/mt_doctor_mixed_present.rb";
    const f = try malt.fs_compat.createFileAbsolute(present_path, .{});
    defer malt.fs_compat.cwd().deleteFile(present_path) catch {};
    try f.writeAll("x");
    f.close();

    try seedKeg(&db, "p1", "local", present_path);
    try seedKeg(&db, "g1", "local", "/tmp/mt_doctor_mixed_missing_1.rb");
    try seedKeg(&db, "g2", "local", "/tmp/mt_doctor_mixed_missing_2.rb");

    const got = doctor.countMissingLocalSources(testing.allocator, &db);
    try testing.expectEqual(@as(u32, 3), got.total);
    try testing.expectEqual(@as(u32, 2), got.stale);
}

// ── printCheck streaming behaviour ───────────────────────────────────
// Bugs here only surface when stderr is a regular file — we drive
// `printCheck` through the same capture path those sinks hit.

const PrintCheckCapture = struct {
    buf: *std.ArrayList(u8),
    prior_quiet: bool,

    fn init(buf: *std.ArrayList(u8), color_on: bool, emoji_on: bool, quiet: bool) PrintCheckCapture {
        const prior_quiet = output.isQuiet();
        color.setForTest(color_on, emoji_on);
        color.setBackgroundForTest(color.Background.dark);
        color.setTruecolorForTest(false);
        output.setQuiet(quiet);
        io_mod.beginStderrCapture(testing.allocator, buf);
        return .{ .buf = buf, .prior_quiet = prior_quiet };
    }

    fn deinit(self: PrintCheckCapture) void {
        io_mod.endStderrCapture();
        color.setForTest(null, null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
        output.setQuiet(self.prior_quiet);
    }
};

test "printCheck appends consecutive rows instead of overwriting" {
    // Regression: positional `File.writer.flush` clobbered prior rows
    // when stderr was a regular file.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = PrintCheckCapture.init(&buf, false, false, false);
    defer cap.deinit();

    doctor.printCheck("Row A", .ok, null);
    doctor.printCheck("Row B", .warn_status, "detail b");
    doctor.printCheck("Row C", .err_status, null);

    const s = buf.items;
    try testing.expect(std.mem.indexOf(u8, s, "Row A") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Row B") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Row C") != null);
    try testing.expect(std.mem.indexOf(u8, s, "detail b") != null);
}

test "printCheck emits plain-mode bytes identical to renderCheckRow" {
    var cap_buf: std.ArrayList(u8) = .empty;
    defer cap_buf.deinit(testing.allocator);
    const cap = PrintCheckCapture.init(&cap_buf, false, false, false);
    defer cap.deinit();

    doctor.printCheck("APFS volume", .warn_status, "Not on APFS");

    try testing.expectEqualStrings(
        "  ! APFS volume — Not on APFS\n",
        cap_buf.items,
    );
}

test "printCheck honours quiet mode and emits nothing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = PrintCheckCapture.init(&buf, false, false, true);
    defer cap.deinit();

    doctor.printCheck("Should not appear", .err_status, "hidden");
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "printCheck handles null detail without em-dash separator" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = PrintCheckCapture.init(&buf, false, false, false);
    defer cap.deinit();

    doctor.printCheck("Stale lock", .ok, null);
    try testing.expectEqualStrings("  * Stale lock\n", buf.items);
    try testing.expect(std.mem.indexOf(u8, buf.items, "—") == null);
}

test "printCheck colour+emoji mode wraps glyph in ANSI" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = PrintCheckCapture.init(&buf, true, true, false);
    defer cap.deinit();

    doctor.printCheck("X", .err_status, null);
    // Red glyph + reset; no em-dash since detail is null.
    try testing.expectEqualStrings("  \x1b[31m✗\x1b[0m X\n", buf.items);
}
