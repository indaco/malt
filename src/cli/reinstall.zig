//! malt — reinstall command.
//! Thin shim over the install pipeline. Refuses when the named package
//! isn't installed; otherwise prepends `--force` and forwards argv into
//! `install.execute`. Mirrors the `cleanup → purge` shape so global
//! flags (`--json`, `--quiet`, `--dry-run`) reach the downstream parser
//! untouched. Package-scoped — transitive deps are not reinstalled.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");
const install = @import("install.zig");

/// First positional that doesn't look like a flag is the package name.
/// Multiple positionals are tolerated to match `mt install`'s shape,
/// but the install dispatch arm only refuses on the install side if
/// anything is actually broken — we just need the first name to drive
/// the "is this installed?" lookup.
fn firstPositional(args: []const []const u8) ?[]const u8 {
    for (args) |a| {
        if (a.len > 0 and a[0] != '-') return a;
    }
    return null;
}

const Presence = enum { keg, cask, missing };

/// Single source of truth for "is this package installed?" — keeps the
/// reinstall dispatch arm aligned with the install pipeline's keg /
/// cask split. Empty `name` short-circuits to `.missing` so the SQL
/// layer never sees an empty bind parameter on a guarded code path.
pub fn classify(db: *sqlite.Database, name: []const u8) Presence {
    if (name.len == 0) return .missing;
    {
        var stmt = db.prepare("SELECT 1 FROM kegs WHERE name = ?1 LIMIT 1;") catch return .missing;
        defer stmt.finalize();
        stmt.bindText(1, name) catch return .missing;
        if (stmt.step() catch false) return .keg;
    }
    {
        var stmt = db.prepare("SELECT 1 FROM casks WHERE token = ?1 LIMIT 1;") catch return .missing;
        defer stmt.finalize();
        stmt.bindText(1, name) catch return .missing;
        if (stmt.step() catch false) return .cask;
    }
    return .missing;
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "reinstall")) return;

    const name = firstPositional(args) orelse {
        output.err("Usage: mt reinstall <package>", .{});
        return error.Aborted;
    };

    const prefix = atomic.maltPrefixOrAbort();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch
        return error.Aborted;

    // No DB file means nothing was ever installed under this prefix —
    // collapse to the same `not installed` line so the user sees a
    // single verb response, not a stack of plumbing errors.
    std.Io.Dir.accessAbsolute(ctx.io, db_path, .{}) catch {
        output.err("{s} is not installed", .{name});
        return error.Aborted;
    };

    const presence = blk: {
        var db = sqlite.Database.open(db_path) catch {
            output.err("Failed to open database", .{});
            return error.Aborted;
        };
        defer db.close();
        schema.initSchema(&db) catch return error.Aborted;
        break :blk classify(&db, name);
    };

    // Forward argv with `--force` prepended; add `--cask` only for the
    // cask branch so the install dispatch routes without the user
    // having to retype it. Exhaustive switch pins all three Presence
    // variants — a future addition fails the build here.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.ensureTotalCapacity(allocator, args.len + 2);
    switch (presence) {
        .missing => {
            output.err("{s} is not installed", .{name});
            return error.Aborted;
        },
        .keg => argv.appendAssumeCapacity("--force"),
        .cask => {
            argv.appendAssumeCapacity("--force");
            argv.appendAssumeCapacity("--cask");
        },
    }
    argv.appendSliceAssumeCapacity(args);
    return install.execute(ctx, allocator, argv.items);
}

const testing = std.testing;

test "firstPositional skips flags and returns the first non-flag arg" {
    try testing.expectEqualStrings("wget", firstPositional(&.{ "--force", "wget" }).?);
    try testing.expectEqualStrings("firefox", firstPositional(&.{ "--cask", "--quiet", "firefox" }).?);
}

test "firstPositional returns null when only flags are present" {
    try testing.expect(firstPositional(&.{ "--force", "--quiet" }) == null);
    try testing.expect(firstPositional(&.{}) == null);
}

test "classify returns .missing for an empty DB" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try testing.expectEqual(Presence.missing, classify(&db, "wget"));
}

test "classify returns .missing for an empty name without binding to SQLite" {
    // Defensive: an empty positional that slips past `firstPositional`
    // would otherwise bind to "" against `name = ?1`; collapse early
    // so the SQL layer never sees the malformed query.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try testing.expectEqual(Presence.missing, classify(&db, ""));
}

test "classify finds an installed keg" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES ('wget', 'wget', '1.24', 'sha-x', '/opt/malt/Cellar/wget/1.24');
    );
    try testing.expectEqual(Presence.keg, classify(&db, "wget"));
}

test "classify finds an installed cask" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO casks (token, name, version, url)
        \\VALUES ('firefox', 'firefox', '120.0', 'https://x.invalid/f.dmg');
    );
    try testing.expectEqual(Presence.cask, classify(&db, "firefox"));
}

test "classify prefers the keg row when both name + token match" {
    // Defensive pin: a future schema migration that lets a name appear
    // in both tables must not make the dispatch arm ambiguous. Keg
    // wins because the install pipeline treats `--cask` as opt-in.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES ('shared', 'shared', '1.0', 'sha-y', '/opt/malt/Cellar/shared/1.0');
    );
    try db.exec(
        \\INSERT INTO casks (token, name, version, url)
        \\VALUES ('shared', 'shared', '1.0', 'https://x.invalid/s.dmg');
    );
    try testing.expectEqual(Presence.keg, classify(&db, "shared"));
}
