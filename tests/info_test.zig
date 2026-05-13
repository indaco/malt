//! malt — info command tests
//!
//! `mt info` is read-only metadata — it must tolerate a prefix without
//! a pre-existing database (e.g. a fresh install on a new machine)
//! instead of failing with "Failed to open database". These tests
//! pin that behavior via the `openDb` helper.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const info = malt.cli_info;

test "openDb returns null when the prefix has no db/ directory" {
    // Fresh prefix with no db/ subdir at all — SQLite's OPEN_CREATE
    // cannot create intermediate dirs, so the open must fail and
    // the helper must turn that into a null instead of an error.
    const prefix = "/tmp/malt_info_test_missing_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try testing.expect(info.openDb(prefix) == null);
}

test "openDb succeeds and returns a usable handle when db/ exists" {
    const prefix = "/tmp/malt_info_test_ok_db";
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try test_io.makeDirAbsolute(std.Options.debug_io, prefix);
    var db_buf: [512]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try test_io.makeDirAbsolute(std.Options.debug_io, db_dir);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var db = info.openDb(prefix) orelse return error.ExpectedDatabase;
    defer db.close();
}

test "openDb returns null when the prefix itself does not exist" {
    // A completely absent prefix path — typical when MALT_PREFIX is
    // pointed at a freshly-minted directory that hasn't been
    // populated by any malt command yet.
    const prefix = "/tmp/malt_info_test_no_prefix_at_all";
    test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try testing.expect(info.openDb(prefix) == null);
}

// --- install hint --------------------------------------------------------

test "encodeInstallHint surfaces both malt and mt invocations" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [512]u8 = undefined;
    try info.encodeInstallHint(&aw.writer, &scratch, "wget", false, false, 14);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Status:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Not installed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Install:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "malt install wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mt install wget") != null);
}

test "encodeInstallHint collapses to a bare line in quiet mode" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [512]u8 = undefined;
    try info.encodeInstallHint(&aw.writer, &scratch, "wget", true, false, 14);
    try testing.expectEqualStrings("Not installed\n", aw.written());
}

// --- API-metadata encoders -----------------------------------------------

const malt_formula = @import("malt").formula;
const malt_cask = @import("malt").cask;

const FORMULA_FIXTURE =
    \\{
    \\  "name":"wget",
    \\  "full_name":"wget",
    \\  "tap":"homebrew/core",
    \\  "desc":"Internet file retriever",
    \\  "homepage":"https://www.gnu.org/software/wget/",
    \\  "license":"GPL-3.0-or-later",
    \\  "revision":0,
    \\  "versions":{"stable":"1.24.5"},
    \\  "dependencies":["libidn2","openssl@3"],
    \\  "keg_only":false,
    \\  "post_install_defined":false
    \\}
;

const CASK_FIXTURE =
    \\{
    \\  "token":"firefox",
    \\  "name":["Mozilla Firefox"],
    \\  "version":"149.0.2",
    \\  "desc":"Web browser",
    \\  "homepage":"https://www.mozilla.org/firefox/",
    \\  "url":"https://example.com/firefox.dmg",
    \\  "sha256":"deadbeef",
    \\  "auto_updates":false
    \\}
;

test "encodeApiFormulaHuman includes metadata and install hint" {
    // parseFormula allocates a few auxiliary slices (dependencies,
    // oldnames) outside of its `Parsed` tree, and the public
    // `Formula.deinit` only frees the tree — so driving this with a
    // single-call test allocator would leak. An arena scoped to the
    // test body cleans up everything in one shot.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try malt_formula.parseFormula(arena.allocator(), FORMULA_FIXTURE);
    defer f.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeApiFormulaHuman(&aw.writer, &scratch, &f, false, false);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "wget: stable 1.24.5\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Description:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Internet file retriever") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Homepage:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://www.gnu.org/software/wget/") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Status:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Install:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "malt install wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "From:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "homebrew/core") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Dependencies:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "libidn2, openssl@3\n") != null);
}

test "encodeApiFormulaJson produces the documented shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try malt_formula.parseFormula(arena.allocator(), FORMULA_FIXTURE);
    defer f.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeApiFormulaJson(&aw.writer, &f);

    try testing.expectEqualStrings(
        "{\"name\":\"wget\",\"type\":\"formula\",\"installed\":false,\"version\":\"1.24.5\",\"desc\":\"Internet file retriever\",\"homepage\":\"https://www.gnu.org/software/wget/\",\"tap\":\"homebrew/core\",\"dependencies\":[\"libidn2\",\"openssl@3\"]}\n",
        aw.written(),
    );
}

test "encodeApiCaskHuman includes metadata and install hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try malt_cask.parseCask(arena.allocator(), CASK_FIXTURE);
    defer c.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeApiCaskHuman(&aw.writer, &scratch, &c, false, false);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "firefox: 149.0.2 (cask)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Name:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Mozilla Firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Description:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Web browser") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Status:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Install:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "malt install firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "URL:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.com/firefox.dmg") != null);
}

test "encodeApiCaskJson produces the documented shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try malt_cask.parseCask(arena.allocator(), CASK_FIXTURE);
    defer c.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeApiCaskJson(&aw.writer, &c);

    try testing.expectEqualStrings(
        "{\"name\":\"firefox\",\"type\":\"cask\",\"installed\":false,\"version\":\"149.0.2\",\"full_name\":\"Mozilla Firefox\",\"desc\":\"Web browser\",\"homepage\":\"https://www.mozilla.org/firefox/\",\"url\":\"https://example.com/firefox.dmg\"}\n",
        aw.written(),
    );
}

// --- installed-cask encoders -------------------------------------------

test "encodeInstalledCaskHuman renders every populated field" {
    const row: info.InstalledCaskRow = .{
        .token = "firefox",
        .name = "Firefox",
        .version = "120.0",
        .url = "https://example.com/firefox.dmg",
        .app_path = "/Applications/Firefox.app",
        .auto_updates = true,
        .installed_at = "2026-05-13 10:40:56",
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, false);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "firefox: 120.0 (cask)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Name:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "URL:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.com/firefox.dmg") != null);
    try testing.expect(std.mem.indexOf(u8, out, "App:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/Applications/Firefox.app") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Auto-updates:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Installed:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2026-05-13 10:40:56") != null);
}

test "encodeInstalledCaskHuman omits Auto-updates when false and uses fallbacks for nulls" {
    const row: info.InstalledCaskRow = .{
        .token = "ghost",
        .name = "ghost",
        // version/url/app_path/installed_at null → human fallbacks ("unknown"/"N/A")
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, false);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "ghost: unknown (cask)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Auto-updates:") == null);
    try testing.expect(std.mem.indexOf(u8, out, "URL:          N/A") != null);
    try testing.expect(std.mem.indexOf(u8, out, "App:          N/A") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Installed:    N/A") != null);
}

test "encodeInstalledCaskJson produces the documented shape" {
    const row: info.InstalledCaskRow = .{
        .token = "firefox",
        .name = "Firefox",
        .version = "120.0",
        .url = "https://example.com/firefox.dmg",
        .app_path = "/Applications/Firefox.app",
        .auto_updates = false,
        .installed_at = "2026-05-13 10:40:56",
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeInstalledCaskJson(&aw.writer, &row);

    try testing.expectEqualStrings(
        "{\"name\":\"firefox\",\"type\":\"cask\",\"installed\":true,\"version\":\"120.0\",\"full_name\":\"Firefox\",\"url\":\"https://example.com/firefox.dmg\",\"app_path\":\"/Applications/Firefox.app\",\"auto_updates\":false,\"installed_at\":\"2026-05-13 10:40:56\",\"tap\":\"\"}\n",
        aw.written(),
    );
}

test "encodeInstalledCaskJson emits empty strings for null fields" {
    const row: info.InstalledCaskRow = .{
        .token = "ghost",
        .name = "ghost",
        .auto_updates = true,
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeInstalledCaskJson(&aw.writer, &row);

    try testing.expectEqualStrings(
        "{\"name\":\"ghost\",\"type\":\"cask\",\"installed\":true,\"version\":\"\",\"full_name\":\"ghost\",\"url\":\"\",\"app_path\":\"\",\"auto_updates\":true,\"installed_at\":\"\",\"tap\":\"\"}\n",
        aw.written(),
    );
}

test "encodeInstalledCaskHuman surfaces the owning tap when set" {
    const row: info.InstalledCaskRow = .{
        .token = "deckclip",
        .name = "deckclip",
        .version = "1.4.5",
        .tap = "yuzeguitarist/deck",
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, false);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Tap:          yuzeguitarist/deck") != null);
    // Tap line sits between Name and URL — same position as `From:` for formulas.
    const name_idx = std.mem.indexOf(u8, out, "Name:") orelse return error.NoNameLine;
    const tap_idx = std.mem.indexOf(u8, out, "Tap:") orelse return error.NoTapLine;
    const url_idx = std.mem.indexOf(u8, out, "URL:") orelse return error.NoUrlLine;
    try testing.expect(name_idx < tap_idx);
    try testing.expect(tap_idx < url_idx);
}

test "encodeInstalledCaskHuman omits the Tap line when null (core-API cask)" {
    const row: info.InstalledCaskRow = .{
        .token = "firefox",
        .name = "Firefox",
        .version = "120.0",
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, false);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "Tap:") == null);
}

test "encodeInstalledCaskJson includes tap as an empty string for null and the label for tap casks" {
    const tapped: info.InstalledCaskRow = .{
        .token = "deckclip",
        .name = "deckclip",
        .version = "1.4.5",
        .tap = "yuzeguitarist/deck",
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeInstalledCaskJson(&aw.writer, &tapped);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"tap\":\"yuzeguitarist/deck\"") != null);
}
