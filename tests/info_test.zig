//! malt — info command tests
//!
//! `mt info` is read-only metadata — it must tolerate a prefix without
//! a pre-existing database (e.g. a fresh install on a new machine)
//! instead of failing with "Failed to open database". These tests
//! pin that behavior via the `openDb` helper.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const info = malt.cli_info;

test "openDb returns null when the prefix has no db/ directory" {
    // Fresh prefix with no db/ subdir at all — SQLite's OPEN_CREATE
    // cannot create intermediate dirs, so the open must fail and
    // the helper must turn that into a null instead of an error.
    const prefix = "/tmp/malt_info_test_missing_db";
    std.fs.deleteTreeAbsolute(prefix) catch {};
    try std.fs.makeDirAbsolute(prefix);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    try testing.expect(info.openDb(prefix) == null);
}

test "openDb succeeds and returns a usable handle when db/ exists" {
    const prefix = "/tmp/malt_info_test_ok_db";
    std.fs.deleteTreeAbsolute(prefix) catch {};
    try std.fs.makeDirAbsolute(prefix);
    var db_buf: [512]u8 = undefined;
    const db_dir = try std.fmt.bufPrint(&db_buf, "{s}/db", .{prefix});
    try std.fs.makeDirAbsolute(db_dir);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    var db = info.openDb(prefix) orelse return error.ExpectedDatabase;
    defer db.close();
}

test "openDb returns null when the prefix itself does not exist" {
    // A completely absent prefix path — typical when MALT_PREFIX is
    // pointed at a freshly-minted directory that hasn't been
    // populated by any malt command yet.
    const prefix = "/tmp/malt_info_test_no_prefix_at_all";
    std.fs.deleteTreeAbsolute(prefix) catch {};
    try testing.expect(info.openDb(prefix) == null);
}

// --- install hint --------------------------------------------------------

test "encodeInstallHint surfaces both malt and mt invocations" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var scratch: [512]u8 = undefined;
    try info.encodeInstallHint(buf.writer(testing.allocator), &scratch, "wget", false);
    try testing.expectEqualStrings(
        "Not installed. Run: malt install wget  (or: mt install wget)\n",
        buf.items,
    );
}

test "encodeInstallHint collapses to a bare line in quiet mode" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var scratch: [512]u8 = undefined;
    try info.encodeInstallHint(buf.writer(testing.allocator), &scratch, "wget", true);
    try testing.expectEqualStrings("Not installed\n", buf.items);
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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var scratch: [4096]u8 = undefined;
    try info.encodeApiFormulaHuman(buf.writer(testing.allocator), &scratch, &f, false);

    const out = buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "wget: stable 1.24.5\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Internet file retriever") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://www.gnu.org/software/wget/") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Not installed. Run: malt install wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "From: homebrew/core") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Dependencies: libidn2, openssl@3\n") != null);
}

test "encodeApiFormulaJson produces the documented shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f = try malt_formula.parseFormula(arena.allocator(), FORMULA_FIXTURE);
    defer f.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try info.encodeApiFormulaJson(buf.writer(testing.allocator), &f);

    try testing.expectEqualStrings(
        "{\"name\":\"wget\",\"type\":\"formula\",\"installed\":false,\"version\":\"1.24.5\",\"desc\":\"Internet file retriever\",\"homepage\":\"https://www.gnu.org/software/wget/\",\"tap\":\"homebrew/core\",\"dependencies\":[\"libidn2\",\"openssl@3\"]}\n",
        buf.items,
    );
}

test "encodeApiCaskHuman includes metadata and install hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try malt_cask.parseCask(arena.allocator(), CASK_FIXTURE);
    defer c.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var scratch: [4096]u8 = undefined;
    try info.encodeApiCaskHuman(buf.writer(testing.allocator), &scratch, &c, false);

    const out = buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "firefox: 149.0.2 (cask)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Name: Mozilla Firefox\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Web browser") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Not installed. Run: malt install firefox") != null);
    try testing.expect(std.mem.indexOf(u8, out, "URL: https://example.com/firefox.dmg") != null);
}

test "encodeApiCaskJson produces the documented shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try malt_cask.parseCask(arena.allocator(), CASK_FIXTURE);
    defer c.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try info.encodeApiCaskJson(buf.writer(testing.allocator), &c);

    try testing.expectEqualStrings(
        "{\"name\":\"firefox\",\"type\":\"cask\",\"installed\":false,\"version\":\"149.0.2\",\"full_name\":\"Mozilla Firefox\",\"desc\":\"Web browser\",\"homepage\":\"https://www.mozilla.org/firefox/\",\"url\":\"https://example.com/firefox.dmg\"}\n",
        buf.items,
    );
}
