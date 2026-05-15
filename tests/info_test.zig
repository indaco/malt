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
const rollback = @import("malt").cli_rollback;

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
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, info.no_history, false);

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
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, info.no_history, false);

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
    try info.encodeInstalledCaskJson(&aw.writer, &row, info.no_history);

    try testing.expectEqualStrings(
        "{\"name\":\"firefox\",\"type\":\"cask\",\"installed\":true,\"version\":\"120.0\",\"full_name\":\"Firefox\",\"url\":\"https://example.com/firefox.dmg\",\"app_path\":\"/Applications/Firefox.app\",\"auto_updates\":false,\"installed_at\":\"2026-05-13 10:40:56\",\"tap\":\"\",\"available_rollback_versions\":[]}\n",
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
    try info.encodeInstalledCaskJson(&aw.writer, &row, info.no_history);

    try testing.expectEqualStrings(
        "{\"name\":\"ghost\",\"type\":\"cask\",\"installed\":true,\"version\":\"\",\"full_name\":\"ghost\",\"url\":\"\",\"app_path\":\"\",\"auto_updates\":true,\"installed_at\":\"\",\"tap\":\"\",\"available_rollback_versions\":[]}\n",
        aw.written(),
    );
}

test "encodeInstalledCaskHuman surfaces the owning tap when set" {
    const row: info.InstalledCaskRow = .{
        .token = "deckclip",
        .name = "deckclip",
        .version = "1.4.5",
        .installed_at = "2026-05-13 10:40:56",
        .tap = "yuzeguitarist/deck",
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, info.no_history, false);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Tap:          yuzeguitarist/deck") != null);
    // Tap is appended after Installed so the top of the dump stays
    // stable for scripts that grep the first N lines of `mt info`.
    const installed_idx = std.mem.indexOf(u8, out, "Installed:") orelse return error.NoInstalledLine;
    const tap_idx = std.mem.indexOf(u8, out, "Tap:") orelse return error.NoTapLine;
    try testing.expect(installed_idx < tap_idx);
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
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, info.no_history, false);

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
    try info.encodeInstalledCaskJson(&aw.writer, &tapped, info.no_history);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"tap\":\"yuzeguitarist/deck\"") != null);
}

// --- rollback history surfaces ------------------------------------------
//
// `mt info` reuses `mt rollback <pkg> --list`'s listing so users see one
// shape across both verbs. These tests pin: (a) empty history is invisible
// in human output but stable as `[]` in JSON, (b) non-empty history emits
// the `mt rollback --list` section under both formula and cask paths.

const ns_per_s: i128 = std.time.ns_per_s;

const two_entries = [_]rollback.Entry{
    .{ .sha256 = "aaa111", .pkg_version = "1.24", .mtime_ns = 1_700_000_000 * ns_per_s },
    .{ .sha256 = "bbb222", .pkg_version = "1.23", .mtime_ns = 1_699_000_000 * ns_per_s },
};

test "encodeInstalledFormulaHuman omits the rollback section when history is empty" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledFormulaHuman(
        &aw.writer,
        &scratch,
        "wget",
        "1.24.5",
        "homebrew/core",
        "/opt/malt/Cellar/wget/1.24.5",
        false,
        "2026-05-13 10:40:56",
        info.no_history,
        false,
    );
    // Byte-identical to the pre-T-040 shape — adding history must not
    // alter the dump for a fresh single-version install.
    try testing.expectEqualStrings(
        "wget: stable 1.24.5\n" ++
            "From:      homebrew/core\n" ++
            "Path:      /opt/malt/Cellar/wget/1.24.5\n" ++
            "Installed: 2026-05-13 10:40:56\n",
        aw.written(),
    );
}

test "encodeInstalledFormulaHuman appends the rollback listing when history is non-empty" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledFormulaHuman(
        &aw.writer,
        &scratch,
        "wget",
        "1.24.5",
        "homebrew/core",
        "/opt/malt/Cellar/wget/1.24.5",
        false,
        "2026-05-13 10:40:56",
        &two_entries,
        false,
    );
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Available rollback versions for wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.24") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.23") != null);
    try testing.expect(std.mem.indexOf(u8, out, "aaa111") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bbb222") != null);
    // Section sits below the field block so the top of the dump stays
    // stable for greppers reading the first N lines.
    const installed_idx = std.mem.indexOf(u8, out, "Installed:").?;
    const section_idx = std.mem.indexOf(u8, out, "Available rollback versions").?;
    try testing.expect(installed_idx < section_idx);
}

test "encodeInstalledFormulaJson emits available_rollback_versions:[] for an empty history" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeInstalledFormulaJson(
        &aw.writer,
        "wget",
        "1.24.5",
        "homebrew/core",
        false,
        "2026-05-13 10:40:56",
        info.no_history,
    );
    try testing.expectEqualStrings(
        "{\"name\":\"wget\",\"type\":\"formula\",\"installed\":true,\"version\":\"1.24.5\"," ++
            "\"tap\":\"homebrew/core\",\"pinned\":false,\"installed_at\":\"2026-05-13 10:40:56\"," ++
            "\"available_rollback_versions\":[]}\n",
        aw.written(),
    );
}

test "encodeInstalledFormulaJson splices the same entries[] shape mt rollback --list emits" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeInstalledFormulaJson(
        &aw.writer,
        "wget",
        "1.24.5",
        "homebrew/core",
        true,
        "2026-05-13 10:40:56",
        &two_entries,
    );
    // Pinning the entries-array bytes here is the splice contract:
    // downstream consumers already parse `mt rollback --list --json`'s
    // `entries[]`, and the info payload must hand them the same shape.
    try testing.expectEqualStrings(
        "{\"name\":\"wget\",\"type\":\"formula\",\"installed\":true,\"version\":\"1.24.5\"," ++
            "\"tap\":\"homebrew/core\",\"pinned\":true,\"installed_at\":\"2026-05-13 10:40:56\"," ++
            "\"available_rollback_versions\":[" ++
            "{\"sha256\":\"aaa111\",\"version\":\"1.24\",\"mtime\":1700000000}," ++
            "{\"sha256\":\"bbb222\",\"version\":\"1.23\",\"mtime\":1699000000}" ++
            "]}\n",
        aw.written(),
    );
}

test "encodeInstalledFormulaJson output parses as JSON with available_rollback_versions reachable" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeInstalledFormulaJson(
        &aw.writer,
        "wget",
        "1.24.5",
        "homebrew/core",
        false,
        "2026-05-13 10:40:56",
        &two_entries,
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();

    const arr = parsed.value.object.get("available_rollback_versions") orelse return error.MissingKey;
    try testing.expectEqual(@as(usize, 2), arr.array.items.len);
    try testing.expectEqualStrings("1.24", arr.array.items[0].object.get("version").?.string);
    try testing.expectEqualStrings("aaa111", arr.array.items[0].object.get("sha256").?.string);
    try testing.expectEqual(@as(i64, 1_700_000_000), arr.array.items[0].object.get("mtime").?.integer);
}

test "encodeInstalledCaskHuman omits the rollback section when history is empty" {
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
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, info.no_history, false);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "Available rollback versions") == null);
}

test "encodeInstalledCaskHuman appends the rollback listing when history is non-empty" {
    const row: info.InstalledCaskRow = .{
        .token = "flux-markdown",
        .name = "flux-markdown",
        .version = "1.32.0",
    };
    const cask_history = [_]rollback.Entry{
        .{ .sha256 = "aa", .pkg_version = "1.31.0", .mtime_ns = 1_700_000_000 * ns_per_s },
        .{ .sha256 = "bb", .pkg_version = "1.30.0", .mtime_ns = 1_699_000_000 * ns_per_s },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var scratch: [4096]u8 = undefined;
    try info.encodeInstalledCaskHuman(&aw.writer, &scratch, &row, &cask_history, false);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "Available rollback versions for flux-markdown") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.31.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.30.0") != null);
}

test "encodeInstalledCaskJson splices history entries into the installed-cask object" {
    const row: info.InstalledCaskRow = .{
        .token = "flux-markdown",
        .name = "flux-markdown",
        .version = "1.32.0",
        .auto_updates = false,
        .installed_at = "2026-05-13 10:40:56",
    };
    const cask_history = [_]rollback.Entry{
        .{ .sha256 = "aa", .pkg_version = "1.31.0", .mtime_ns = 1_700_000_000 * ns_per_s },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeInstalledCaskJson(&aw.writer, &row, &cask_history);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();

    const arr = parsed.value.object.get("available_rollback_versions") orelse return error.MissingKey;
    try testing.expectEqual(@as(usize, 1), arr.array.items.len);
    try testing.expectEqualStrings("1.31.0", arr.array.items[0].object.get("version").?.string);
    try testing.expectEqual(@as(i64, 1_700_000_000), arr.array.items[0].object.get("mtime").?.integer);
}

test "encodeInstalledCaskJson output parses as JSON with .tap reachable" {
    // Loose shape guard: catches future reorderings or sibling-field
    // additions that the exact-bytes test would also catch, but keeps
    // working even if a later refactor reorders the object keys. WHY
    // this matters: downstream consumers branch on `.tap`, not on byte
    // position — a parses-as test pins the contract they actually rely on.
    const row: info.InstalledCaskRow = .{
        .token = "deckclip",
        .name = "deckclip",
        .version = "1.4.5",
        .tap = "yuzeguitarist/deck",
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try info.encodeInstalledCaskJson(&aw.writer, &row, info.no_history);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();

    const tap_val = parsed.value.object.get("tap") orelse return error.MissingTapKey;
    try testing.expectEqualStrings("yuzeguitarist/deck", tap_val.string);
    const type_val = parsed.value.object.get("type") orelse return error.MissingTypeKey;
    try testing.expectEqualStrings("cask", type_val.string);
}
