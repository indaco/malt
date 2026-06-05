//! malt — doctor cask history walker.
//!
//! Counts every `cask_versions` row whose `version` no longer matches
//! the live `casks.version` row, plus the on-disk footprint (Caskroom
//! dir + per-version cache file). Read-only: doctor surfaces the number
//! so the user knows what `mt purge --old-versions` would reclaim;
//! mutation lives in purge, not here.

const std = @import("std");
const sqlite = @import("../../db/sqlite.zig");

pub const Entry = struct {
    token: []const u8,
    version: []const u8,
    bytes: u64,
};

pub const Census = struct {
    entries: []Entry,
    total_bytes: u64,

    pub fn deinit(self: *Census, allocator: std.mem.Allocator) void {
        for (self.entries) |e| {
            allocator.free(e.token);
            allocator.free(e.version);
        }
        allocator.free(self.entries);
        self.* = .{ .entries = &.{}, .total_bytes = 0 };
    }
};

/// Walk `cask_versions JOIN casks` and return every row whose version
/// isn't the currently-installed one, plus its disk footprint. Always
/// returns a valid census — a missing/unopenable DB or an absent
/// schema is "nothing retained", not a failure: doctor reports here,
/// it does not enforce.
pub fn collectCensus(
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []const u8,
) Census {
    const empty: Census = .{ .entries = &.{}, .total_bytes = 0 };

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return empty;
    var db = sqlite.Database.open(db_path) catch return empty;
    defer db.close();

    // INNER JOIN drops tokens that have history but no current install
    // (uninstall already cleared that case); `!=` selects every history
    // row whose version no longer matches the live one — same set
    // `mt purge --old-versions` would sweep.
    var stmt = db.prepare(
        \\SELECT cv.token, cv.version
        \\FROM cask_versions cv
        \\JOIN casks c ON c.token = cv.token
        \\WHERE cv.version != c.version
        \\ORDER BY cv.token, cv.version;
    ) catch return empty;
    defer stmt.finalize();

    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |e| {
            allocator.free(e.token);
            allocator.free(e.version);
        }
        list.deinit(allocator);
    }

    var total_bytes: u64 = 0;
    while (stmt.step() catch false) {
        const tok_ptr = stmt.columnText(0) orelse continue;
        const ver_ptr = stmt.columnText(1) orelse continue;
        const tok = std.mem.sliceTo(tok_ptr, 0);
        const ver = std.mem.sliceTo(ver_ptr, 0);

        const bytes = perVersionFootprint(io, allocator, prefix, tok, ver);
        const tok_dup = allocator.dupe(u8, tok) catch continue;
        const ver_dup = allocator.dupe(u8, ver) catch {
            allocator.free(tok_dup);
            continue;
        };
        list.append(allocator, .{ .token = tok_dup, .version = ver_dup, .bytes = bytes }) catch {
            allocator.free(tok_dup);
            allocator.free(ver_dup);
            continue;
        };
        total_bytes += bytes;
    }

    const slice = list.toOwnedSlice(allocator) catch return empty;
    return .{ .entries = slice, .total_bytes = total_bytes };
}

/// Caskroom dir total + every per-version cache file. Mirrors the
/// extension list and stat/walk shape of
/// `cli/purge/scopes.zig::caskVersionFootprint` so doctor's reported
/// bytes match the bytes `mt purge --old-versions` actually frees.
fn perVersionFootprint(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    token: []const u8,
    version: []const u8,
) u64 {
    var total: u64 = 0;
    var path_buf: [512]u8 = undefined;

    if (std.fmt.bufPrint(&path_buf, "{s}/Caskroom/{s}/{s}", .{ prefix, token, version })) |caskroom_path| {
        total += pathSize(io, allocator, caskroom_path);
    } else |_| {}

    for ([_][]const u8{ ".dmg", ".zip", ".pkg", ".tar.gz" }) |ext| {
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/cache/Cask/{s}-{s}{s}", .{ prefix, token, version, ext }) catch continue;
        if (std.Io.Dir.cwd().statFile(io, cache_path, .{})) |st| {
            total += st.size;
        } else |_| {}
    }
    return total;
}

/// Size of a regular file (single stat) or the recursive sum of every
/// regular file under a directory. Mirrors `cli/purge/util.zig::pathSize`
/// — doctor can't cross the sibling-CLI boundary into `cli/purge`, so
/// the shape is duplicated here. Best-effort throughout: any I/O
/// failure contributes zero, not an error.
fn pathSize(io: std.Io, allocator: std.mem.Allocator, path: []const u8) u64 {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
        if (st.kind != .directory) return st.size;
    } else |_| return 0;

    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();

    var total: u64 = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .file) {
            const s = std.Io.Dir.statFile(entry.dir, io, entry.basename, .{}) catch continue;
            total += s.size;
        }
    }
    return total;
}

/// Render the human one-liner doctor surfaces after the check rows.
/// Empty census writes nothing — the empty case must not add noise to
/// the default human output. Pure (writer-driven) so tests pin the
/// exact bytes.
pub fn writeHumanSummary(w: *std.Io.Writer, census: Census) !void {
    if (census.entries.len == 0) return;
    var buf: [32]u8 = undefined;
    const size = formatBytes(census.total_bytes, &buf);
    try w.print(
        "  > Retained cask versions: {d} ({s}). Run: mt purge --old-versions\n",
        .{ census.entries.len, size },
    );
}

/// Emit one indented `<token> <version> (<size>)` line per retained
/// entry — what `--verbose` prints under doctor's summary row. Empty
/// census writes nothing so the verbose path stays silent in the
/// clean case. Pure for byte-pinning tests.
pub fn writeHumanEntries(w: *std.Io.Writer, census: Census) !void {
    if (census.entries.len == 0) return;
    var size_buf: [32]u8 = undefined;
    for (census.entries) |e| {
        const size = formatBytes(e.bytes, &size_buf);
        try w.print("        {s} {s} ({s})\n", .{ e.token, e.version, size });
    }
}

/// Write the `"cask_history":{...}` field (no braces/newline) for the
/// doctor `--json` merger. The schema stays stable across the empty case
/// (zero values, not omission) so scripted consumers can always read
/// `cask_history.retained_versions` and `cask_history.bytes`.
pub fn writeField(w: *std.Io.Writer, census: Census) !void {
    try w.print(
        "\"cask_history\":{{\"retained_versions\":{d},\"bytes\":{d}}}",
        .{ census.entries.len, census.total_bytes },
    );
}

/// Standalone single-line `{"cask_history":{...}}` document. Pure for
/// byte-pinning tests; wraps `writeField`.
pub fn writeJson(w: *std.Io.Writer, census: Census) !void {
    try w.writeAll("{");
    try writeField(w, census);
    try w.writeAll("}\n");
}

/// Format a byte count as `{d:.1} {unit}` (B/KB/MB/GB/TB). Local mirror
/// of `cli/purge/util.zig::formatBytes` — same shape, but doctor can't
/// pull `cli/purge` across the sibling-CLI boundary.
fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

// ── inline unit tests ──────────────────────────────────────────────────────

const testing = std.testing;
const fs_test_io = std.Options.debug_io;
const schema = @import("../../db/schema.zig");

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

/// Build a unique scratch prefix with the dir skeleton doctor's walker
/// expects (`db/`, `cache/Cask/`, `Caskroom/`). Caller frees the slice.
fn seedScratch(allocator: std.mem.Allocator, tag: []const u8) ![:0]u8 {
    const ts: u32 = @intCast(std.Io.Clock.real.now(fs_test_io).toMilliseconds() & 0xffff_ffff);
    const prefix = try std.fmt.allocPrintSentinel(
        allocator,
        "/tmp/malt_doctor_cask_history_{s}_{x}",
        .{ tag, ts },
        0,
    );
    rmrf(prefix);
    inline for ([_][]const u8{ "/db", "/cache/Cask", "/Caskroom" }) |sub| {
        var sub_buf: [600]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&sub_buf, "{s}{s}", .{ prefix, sub });
        try std.Io.Dir.cwd().createDirPath(fs_test_io, sub_path);
    }
    return prefix;
}

fn writeFile(path: []const u8, body: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(fs_test_io, path, .{ .truncate = true });
    defer f.close(fs_test_io);
    try f.writeStreamingAll(fs_test_io, body);
}

test "collectCensus reports retained versions plus on-disk bytes" {
    // Two history rows differ from the live cask; one row matches and
    // must not appear. Disk artefacts are planted only for the retained
    // versions so the byte total can be lower-bounded against the
    // exact bytes we wrote.
    const allocator = testing.allocator;
    const prefix = try seedScratch(allocator, "two_retained");
    defer {
        rmrf(prefix);
        allocator.free(prefix);
    }

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO casks (token, name, version, url)
            \\VALUES ('alpha', 'Alpha', '2.0', 'https://x.invalid/a.dmg');
        );
        try db.exec(
            \\INSERT INTO cask_versions (token, version, url, artifact_type)
            \\VALUES ('alpha', '1.0', 'https://x.invalid/a-1.0.dmg', 'dmg'),
            \\       ('alpha', '1.5', 'https://x.invalid/a-1.5.dmg', 'dmg'),
            \\       ('alpha', '2.0', 'https://x.invalid/a-2.0.dmg', 'dmg');
        );
    }

    const cask_1_0 = try std.fmt.allocPrint(allocator, "{s}/Caskroom/alpha/1.0", .{prefix});
    defer allocator.free(cask_1_0);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, cask_1_0);
    const app_1_0 = try std.fmt.allocPrint(allocator, "{s}/Caskroom/alpha/1.0/Alpha.app", .{prefix});
    defer allocator.free(app_1_0);
    try writeFile(app_1_0, "x" ** 64);

    const cache_1_5 = try std.fmt.allocPrint(allocator, "{s}/cache/Cask/alpha-1.5.dmg", .{prefix});
    defer allocator.free(cache_1_5);
    try writeFile(cache_1_5, "y" ** 128);

    var census = collectCensus(allocator, fs_test_io, prefix);
    defer census.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), census.entries.len);
    try testing.expect(census.total_bytes >= 64 + 128);
}

test "writeHumanSummary emits a one-liner with count + scaled bytes when non-empty" {
    // Pin the exact bytes doctor's human path appends after the check
    // rows. The byte total is `formatBytes`-shaped (matches purge's
    // freed-bytes reporter) so users see one consistent size format
    // across `doctor` and `purge --old-versions`.
    var entries = [_]Entry{
        .{ .token = "alpha", .version = "1.0", .bytes = 64 },
        .{ .token = "alpha", .version = "1.5", .bytes = 128 },
    };
    const census: Census = .{ .entries = entries[0..], .total_bytes = 192 };

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHumanSummary(&w, census);
    try testing.expectEqualStrings(
        "  > Retained cask versions: 2 (192.0 B). Run: mt purge --old-versions\n",
        w.buffered(),
    );
}

test "writeHumanEntries emits one indented (token version size) line per entry" {
    // `--verbose` lets the user see exactly which retained version
    // accounts for each byte. The indent matches doctor's existing
    // detail-row pattern (see `checkPrefixPermissions`).
    var entries = [_]Entry{
        .{ .token = "alpha", .version = "1.0", .bytes = 64 },
        .{ .token = "alpha", .version = "1.5", .bytes = 128 },
    };
    const census: Census = .{ .entries = entries[0..], .total_bytes = 192 };

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHumanEntries(&w, census);
    try testing.expectEqualStrings(
        "        alpha 1.0 (64.0 B)\n        alpha 1.5 (128.0 B)\n",
        w.buffered(),
    );
}

test "writeHumanEntries writes nothing when the census is empty" {
    // Symmetric with the summary writer — empty case stays silent so
    // `--verbose` on a clean prefix adds no rows.
    const census: Census = .{ .entries = &.{}, .total_bytes = 0 };

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHumanEntries(&w, census);
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "writeHumanSummary writes nothing when the census is empty" {
    // The empty branch must not append a row — the task forbids extra
    // human noise when nothing is retained. JSON callers still see the
    // section with zero values; that's a separate writer.
    const census: Census = .{ .entries = &.{}, .total_bytes = 0 };

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeHumanSummary(&w, census);
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "writeJson emits the cask_history object with retained_versions + bytes" {
    // Stable JSON shape for `mt doctor --json`: a `cask_history` key
    // mapping to `{retained_versions, bytes}`. Compact form (no
    // indent) matches the rollback / list JSON writers so existing
    // CLI consumers do not have to special-case doctor.
    var entries = [_]Entry{
        .{ .token = "alpha", .version = "1.0", .bytes = 64 },
        .{ .token = "alpha", .version = "1.5", .bytes = 128 },
    };
    const census: Census = .{ .entries = entries[0..], .total_bytes = 192 };

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJson(&w, census);
    try testing.expectEqualStrings(
        "{\"cask_history\":{\"retained_versions\":2,\"bytes\":192}}\n",
        w.buffered(),
    );
}

test "writeJson keeps the cask_history section present when the census is empty" {
    // Stable shape: the section MUST exist with zero values so callers
    // can rely on the schema even when nothing is retained.
    const census: Census = .{ .entries = &.{}, .total_bytes = 0 };

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJson(&w, census);
    try testing.expectEqualStrings(
        "{\"cask_history\":{\"retained_versions\":0,\"bytes\":0}}\n",
        w.buffered(),
    );
}

test "collectCensus ignores orphan history rows that have no live casks entry" {
    // Mirrors purge's INNER JOIN contract: a token uninstalled from
    // `casks` but still carrying `cask_versions` history is purge's
    // stale-casks scope, not old-versions. Doctor must not double-
    // report it here.
    const allocator = testing.allocator;
    const prefix = try seedScratch(allocator, "orphan");
    defer {
        rmrf(prefix);
        allocator.free(prefix);
    }

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        // History present, NO row in `casks` for this token.
        try db.exec(
            \\INSERT INTO cask_versions (token, version, url, artifact_type)
            \\VALUES ('orphan', '0.9', 'https://x.invalid/o-0.9.dmg', 'dmg');
        );
    }

    var census = collectCensus(allocator, fs_test_io, prefix);
    defer census.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), census.entries.len);
    try testing.expectEqual(@as(u64, 0), census.total_bytes);
}

test "collectCensus omits the token whose history matches the live version exactly" {
    // History row with the same version as the live install is the
    // "current" pointer used for resume after a crash — it must not
    // count as retained, otherwise purge would re-delete what the
    // user is actively running.
    const allocator = testing.allocator;
    const prefix = try seedScratch(allocator, "match");
    defer {
        rmrf(prefix);
        allocator.free(prefix);
    }

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO casks (token, name, version, url)
            \\VALUES ('beta', 'Beta', '3.0', 'https://x.invalid/b.dmg');
        );
        try db.exec(
            \\INSERT INTO cask_versions (token, version, url, artifact_type)
            \\VALUES ('beta', '3.0', 'https://x.invalid/b-3.0.dmg', 'dmg');
        );
    }

    var census = collectCensus(allocator, fs_test_io, prefix);
    defer census.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), census.entries.len);
}

test "collectCensus on a fresh prefix returns an empty census" {
    // No DB on disk → walker reports zero entries / zero bytes. Empty
    // is the silent default; doctor's human path skips its summary
    // line when this branch is taken.
    const allocator = testing.allocator;
    const prefix = "/tmp/malt_doctor_cask_history_fresh";
    rmrf(prefix);
    defer rmrf(prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);

    var census = collectCensus(allocator, fs_test_io, prefix);
    defer census.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), census.entries.len);
    try testing.expectEqual(@as(u64, 0), census.total_bytes);
}
