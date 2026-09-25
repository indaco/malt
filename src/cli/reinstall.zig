//! malt — reinstall command.
//! Thin shim over the install pipeline. Refuses when the named package
//! isn't installed; otherwise prepends `--force` and forwards argv into
//! `install.execute`. Mirrors the `cleanup → purge` shape so global
//! flags (`--json`, `--quiet`, `--dry-run`) reach the downstream parser
//! untouched. Package-scoped — transitive deps are not reinstalled.
//! A tap package is reinstalled from its owning tap, on its own.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const schema_report = @import("schema_report.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");
const install = @import("install.zig");
const install_args = @import("install/args.zig");
const tap_mod = @import("../core/tap.zig");

/// First positional that doesn't look like a flag is the package name
/// that drives the "is this installed?" lookup.
fn firstPositional(args: []const []const u8) ?[]const u8 {
    for (args) |a| {
        if (isPositional(a)) return a;
    }
    return null;
}

fn isPositional(a: []const u8) bool {
    return a.len > 0 and a[0] != '-';
}

const Presence = enum { keg, cask, local, missing };

/// Which subtree a tap keg's `.rb` came from. `.any` lets install probe
/// both, as upgrade does for rows recorded before malt tracked it.
const Side = enum { any, formula, cask };

/// Table the user's `--formula` / `--cask` restricts the lookup to.
pub const Only = enum { any, keg, cask };

/// What `classify` resolved the user's name to.
pub const Target = struct {
    presence: Presence,
    /// The name install resolves: `<tap>/<name>` for a third-party row, the
    /// bare name for a core one, the recorded `.rb` path for a local keg.
    name: ?[]u8 = null,
    side: Side = .any,
    /// Third-party or local row: its install is pinned to where it came from.
    pinned: bool = false,

    pub fn deinit(self: Target, allocator: std.mem.Allocator) void {
        if (self.name) |s| allocator.free(s);
    }

    /// Whether forwarding changes what the user typed beyond `--force`.
    fn rewrites(self: Target, typed: []const u8) bool {
        const name = self.name orelse return false;
        return self.pinned or !std.mem.eql(u8, name, typed);
    }
};

/// Single source of truth for "is this package installed?" — keeps the
/// reinstall dispatch arm aligned with the install pipeline's keg /
/// cask split. A `<user>/<repo>/<name>` form matches by leaf and canonical
/// tap, the way install recognises a recorded tap package. Empty `name`
/// short-circuits to `.missing` so SQLite never sees an empty bind.
pub fn classify(allocator: std.mem.Allocator, db: *sqlite.Database, typed: []const u8, only: Only) error{OutOfMemory}!Target {
    const missing: Target = .{ .presence = .missing };
    if (typed.len == 0) return missing;

    var slug_buf: [tap_mod.max_slug_len]u8 = undefined;
    var leaf = typed;
    var want_tap: ?[]const u8 = null;
    if (install_args.parseTapName(typed)) |p| {
        if (p.user.len == 0 or p.repo.len == 0) return missing;
        leaf = p.formula;
        want_tap = tap_mod.canonicalTapSlug(&slug_buf, typed[0 .. p.user.len + 1 + p.repo.len]) orelse return missing;
    }

    if (only != .cask) {
        var stmt = db.prepare("SELECT name, ifnull(tap, ''), full_name, tap_rb_subtree FROM kegs WHERE name = ?1;") catch return missing;
        defer stmt.finalize();
        stmt.bindText(1, leaf) catch return missing;
        while (stmt.step() catch false) {
            const tap = columnSlice(&stmt, 1);
            if (!tapMatches(want_tap, "homebrew/core", tap)) continue;
            const name = columnSlice(&stmt, 0);
            if (install_args.isLocalTap(tap)) return .{
                .presence = .local,
                .name = try allocator.dupe(u8, columnSlice(&stmt, 2)),
                .pinned = true,
            };
            if (install_args.isCoreTap(tap)) return .{ .presence = .keg, .name = try allocator.dupe(u8, name) };
            return .{
                .presence = .keg,
                .name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tap, name }),
                .side = sideOf(stmt.columnText(3)),
                .pinned = true,
            };
        }
    }
    if (only != .keg) {
        var stmt = db.prepare("SELECT token, ifnull(tap, '') FROM casks WHERE token = ?1;") catch return missing;
        defer stmt.finalize();
        stmt.bindText(1, leaf) catch return missing;
        while (stmt.step() catch false) {
            const tap = columnSlice(&stmt, 1);
            if (!tapMatches(want_tap, "homebrew/cask", tap)) continue;
            const token = columnSlice(&stmt, 0);
            if (install_args.isCoreTap(tap)) return .{ .presence = .cask, .name = try allocator.dupe(u8, token) };
            return .{
                .presence = .cask,
                .name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tap, token }),
                .pinned = true,
            };
        }
    }
    return missing;
}

/// A bare name takes any row; `<core_label>/<x>` takes any core row of
/// this table, since core rows may carry no tap at all.
fn tapMatches(want: ?[]const u8, core_label: []const u8, tap: []const u8) bool {
    const w = want orelse return true;
    if (install_args.isCoreTap(w)) return std.mem.eql(u8, w, core_label) and install_args.isCoreTap(tap);
    return std.mem.eql(u8, w, tap);
}

fn sideOf(subtree: ?[*:0]const u8) Side {
    const s = std.mem.sliceTo(subtree orelse return .any, 0);
    if (std.mem.eql(u8, s, "cask")) return .cask;
    if (std.mem.eql(u8, s, "formula")) return .formula;
    return .any;
}

fn columnSlice(stmt: *sqlite.Statement, col: u32) []const u8 {
    return std.mem.sliceTo(stmt.columnText(col) orelse return "", 0);
}

/// One install run pins a single tap and side, so a package that needs
/// rewriting can't share it with other names without mis-routing them.
fn mixesRewrittenNames(allocator: std.mem.Allocator, db: *sqlite.Database, args: []const []const u8, only: Only) error{OutOfMemory}!bool {
    var positionals: usize = 0;
    for (args) |a| {
        if (isPositional(a)) positionals += 1;
    }
    if (positionals < 2) return false;
    for (args) |a| {
        if (!isPositional(a)) continue;
        const t = try classify(allocator, db, a, only);
        defer t.deinit(allocator);
        if (t.rewrites(a)) return true;
    }
    return false;
}

/// Single-quotes `s` so a path with spaces stays one argument when the
/// suggested command is pasted.
fn shellQuote(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn onlyFromArgs(args: []const []const u8) Only {
    for (args) |a| if (std.mem.eql(u8, a, "--cask")) return .cask;
    for (args) |a| if (std.mem.eql(u8, a, "--formula")) return .keg;
    return .any;
}

/// `--force`, the side to install from, then `args` with the first
/// positional swapped for the resolved name. Pinning the side stops a tap
/// install trying the other subtree. Caller frees the slice, not its items.
pub fn forwardArgv(allocator: std.mem.Allocator, target: Target, args: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.ensureTotalCapacity(allocator, args.len + 2);
    argv.appendAssumeCapacity("--force");
    switch (target.presence) {
        .missing, .local => {},
        .cask => argv.appendAssumeCapacity("--cask"),
        .keg => switch (target.side) {
            .any => {},
            .formula => argv.appendAssumeCapacity("--formula"),
            .cask => argv.appendAssumeCapacity("--cask"),
        },
    }
    var name = target.name;
    for (args) |a| {
        if (name != null and isPositional(a)) {
            argv.appendAssumeCapacity(name.?);
            name = null;
        } else argv.appendAssumeCapacity(a);
    }
    return argv.toOwnedSlice(allocator);
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

    const only = onlyFromArgs(args);
    const target, const mixed = blk: {
        var db = sqlite.Database.open(db_path) catch {
            output.err("Failed to open database", .{});
            return error.Aborted;
        };
        defer db.close();
        schema.initSchema(&db) catch |e| return schema_report.abortInitFailure(&db, e, prefix);
        const t = try classify(allocator, &db, name, only);
        errdefer t.deinit(allocator);
        break :blk .{ t, try mixesRewrittenNames(allocator, &db, args, only) };
    };
    defer target.deinit(allocator);

    switch (target.presence) {
        .missing => {
            output.err("{s} is not installed", .{name});
            return error.Aborted;
        },
        // Forwarding would silently re-run a `.rb` the user didn't name here.
        .local => {
            const path = try shellQuote(allocator, target.name.?);
            defer allocator.free(path);
            output.err("{s} was installed from a local formula; reinstall it with `mt install --local --force {s}`", .{ name, path });
            return error.Aborted;
        },
        .keg, .cask => {},
    }
    if (mixed) {
        output.err("Reinstall tap packages one at a time so each resolves from its own tap", .{});
        return error.Aborted;
    }
    const argv = try forwardArgv(allocator, target, args);
    defer allocator.free(argv);
    return install.execute(ctx, allocator, argv);
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

fn seedDb() !sqlite.Database {
    var db = try sqlite.Database.open(":memory:");
    errdefer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, tap, tap_rb_subtree) VALUES
        \\  ('wget', 'wget', '1.24', 'a', '/c/wget', NULL, NULL),
        \\  ('jq', 'homebrew/core/jq', '1.7', 'b', '/c/jq', 'homebrew/core', NULL),
        \\  ('foo', 'acme/homebrew-tools/foo', '1.0', 'c', '/c/foo', 'acme/tools', 'formula'),
        \\  ('bar', 'acme/tools/bar', '1.0', 'd', '/c/bar', 'acme/tools', 'cask'),
        \\  ('old', 'acme/tools/old', '1.0', 'e', '/c/old', 'acme/tools', NULL),
        \\  ('lx', '/src/lx.rb', '1.0', 'f', '/c/lx', 'local', NULL),
        \\  ('dual', 'acme/tools/dual', '1.0', 'g', '/c/dual', 'acme/tools', 'formula');
        \\INSERT INTO casks (token, name, version, url, tap) VALUES
        \\  ('firefox', 'firefox', '120.0', 'https://x.invalid/f.dmg', NULL),
        \\  ('baz', 'Baz', '1.0', 'https://x.invalid/b.dmg', 'acme/tools'),
        \\  ('dual', 'Dual', '1.0', 'https://x.invalid/d.dmg', NULL);
    );
    return db;
}

fn expectTarget(db: *sqlite.Database, typed: []const u8, only: Only, presence: Presence, name: []const u8, side: Side) !void {
    const t = try classify(testing.allocator, db, typed, only);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(presence, t.presence);
    try testing.expectEqualStrings(name, t.name.?);
    try testing.expectEqual(side, t.side);
}

fn expectMissing(db: *sqlite.Database, typed: []const u8) !void {
    const t = try classify(testing.allocator, db, typed, .any);
    try testing.expectEqual(Presence.missing, t.presence);
}

test "classify returns .missing for an empty DB" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try expectMissing(&db, "wget");
}

test "classify returns .missing for an empty name without binding to SQLite" {
    var db = try seedDb();
    defer db.close();
    try expectMissing(&db, "");
}

test "classify resolves core packages to their bare name, typed bare or core-qualified" {
    // A migrated core keg's full_name is `homebrew/core/<x>`; forwarding that
    // form would send a core package down the tap path.
    var db = try seedDb();
    defer db.close();
    try expectTarget(&db, "wget", .any, .keg, "wget", .any);
    try expectTarget(&db, "homebrew/core/wget", .any, .keg, "wget", .any);
    try expectTarget(&db, "homebrew/core/jq", .any, .keg, "jq", .any);
    try expectTarget(&db, "firefox", .any, .cask, "firefox", .any);
    try expectTarget(&db, "homebrew/cask/firefox", .any, .cask, "firefox", .any);
}

test "classify resolves a tap keg by bare name and by any spelling of its slug" {
    // Without the slug, install looks the bare name up in homebrew/core and
    // reinstalls a different package, or none at all.
    var db = try seedDb();
    defer db.close();
    for ([_][]const u8{ "foo", "acme/tools/foo", "acme/homebrew-tools/foo", "Acme/Tools/foo" }) |typed| {
        try expectTarget(&db, typed, .any, .keg, "acme/tools/foo", .formula);
    }
}

test "classify pins a Casks/-sourced tap keg to the cask side" {
    var db = try seedDb();
    defer db.close();
    try expectTarget(&db, "bar", .any, .keg, "acme/tools/bar", .cask);
}

test "classify leaves a legacy tap keg's side open so install probes both" {
    // Rows from before malt tracked the subtree may have come from Casks/.
    var db = try seedDb();
    defer db.close();
    try expectTarget(&db, "old", .any, .keg, "acme/tools/old", .any);
}

test "classify resolves a tap cask by bare token and by full slug" {
    var db = try seedDb();
    defer db.close();
    try expectTarget(&db, "baz", .any, .cask, "acme/tools/baz", .any);
    try expectTarget(&db, "acme/tools/baz", .any, .cask, "acme/tools/baz", .any);
}

test "classify misses a slug naming a different tap" {
    var db = try seedDb();
    defer db.close();
    try expectMissing(&db, "other/tap/foo");
    try expectMissing(&db, "homebrew/core/foo");
}

test "classify keeps each core qualifier to its own table" {
    // `homebrew/cask/<x>` names a cask and `homebrew/core/<x>` a formula;
    // crossing them would reinstall a package the user didn't name.
    var db = try seedDb();
    defer db.close();
    try expectMissing(&db, "homebrew/cask/wget");
    try expectMissing(&db, "homebrew/core/firefox");
}

test "shellQuote keeps a path with spaces and quotes one argument" {
    const q = try shellQuote(testing.allocator, "/src/my dir/l'x.rb");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'/src/my dir/l'\\''x.rb'", q);
}

test "classify reports a local keg with its recorded path, never as a tap slug" {
    // `local` is a label, not a tap: `local/lx` resolves nowhere.
    var db = try seedDb();
    defer db.close();
    try expectTarget(&db, "lx", .any, .local, "/src/lx.rb", .any);
    try expectMissing(&db, "/src/lx.rb");
}

test "classify prefers the keg row, unless the user asked for the cask" {
    var db = try seedDb();
    defer db.close();
    try expectTarget(&db, "dual", .any, .keg, "acme/tools/dual", .formula);
    try expectTarget(&db, "dual", .cask, .cask, "dual", .any);
    try expectTarget(&db, "dual", .keg, .keg, "acme/tools/dual", .formula);
    try expectMissing(&db, "nope");
}

test "onlyFromArgs maps the user's kind flag onto the table it restricts" {
    try testing.expectEqual(Only.cask, onlyFromArgs(&.{ "--cask", "x" }));
    try testing.expectEqual(Only.keg, onlyFromArgs(&.{ "x", "--formula" }));
    try testing.expectEqual(Only.any, onlyFromArgs(&.{"x"}));
}

test "mixesRewrittenNames refuses a tap package alongside other names" {
    // One install run pins one tap and one side: `foo firefox` would send
    // firefox to the formula side, `old wget` would send old to core.
    var db = try seedDb();
    defer db.close();
    try testing.expect(try mixesRewrittenNames(testing.allocator, &db, &.{ "foo", "firefox" }, .any));
    try testing.expect(try mixesRewrittenNames(testing.allocator, &db, &.{ "bar", "wget" }, .any));
    try testing.expect(try mixesRewrittenNames(testing.allocator, &db, &.{ "wget", "old" }, .any));
    try testing.expect(try mixesRewrittenNames(testing.allocator, &db, &.{ "wget", "homebrew/core/jq" }, .any));
}

test "mixesRewrittenNames keeps core-only and single-name runs as before" {
    var db = try seedDb();
    defer db.close();
    try testing.expect(!try mixesRewrittenNames(testing.allocator, &db, &.{ "wget", "jq" }, .any));
    try testing.expect(!try mixesRewrittenNames(testing.allocator, &db, &.{ "--quiet", "foo" }, .any));
    try testing.expect(!try mixesRewrittenNames(testing.allocator, &db, &.{ "wget", "not-installed" }, .any));
}

fn expectArgv(expected: []const []const u8, target: Target, args: []const []const u8) !void {
    const argv = try forwardArgv(testing.allocator, target, args);
    defer testing.allocator.free(argv);
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |e, a| try testing.expectEqualStrings(e, a);
}

test "forwardArgv keeps a core keg's argv exactly" {
    var name = "wget".*;
    try expectArgv(&.{ "--force", "--quiet", "wget" }, .{ .presence = .keg, .name = &name }, &.{ "--quiet", "wget" });
}

test "forwardArgv forwards a core-qualified name as the bare one" {
    var name = "wget".*;
    try expectArgv(&.{ "--force", "wget" }, .{ .presence = .keg, .name = &name }, &.{"homebrew/core/wget"});
}

test "forwardArgv routes a core cask through --cask" {
    var name = "firefox".*;
    try expectArgv(&.{ "--force", "--cask", "firefox" }, .{ .presence = .cask, .name = &name }, &.{"firefox"});
}

test "forwardArgv pins a Formula/-sourced tap keg to its slug and the formula side" {
    // `--formula` stops install trying the tap's Casks/ subtree first.
    var name = "acme/tools/foo".*;
    try expectArgv(
        &.{ "--force", "--formula", "--quiet", "acme/tools/foo" },
        .{ .presence = .keg, .name = &name, .side = .formula, .pinned = true },
        &.{ "--quiet", "foo" },
    );
}

test "forwardArgv routes a Casks/-sourced tap keg through --cask" {
    var name = "acme/tools/bar".*;
    try expectArgv(
        &.{ "--force", "--cask", "acme/tools/bar" },
        .{ .presence = .keg, .name = &name, .side = .cask, .pinned = true },
        &.{"bar"},
    );
}

test "forwardArgv pins no side for a legacy tap keg" {
    var name = "acme/tools/old".*;
    try expectArgv(
        &.{ "--force", "acme/tools/old" },
        .{ .presence = .keg, .name = &name, .pinned = true },
        &.{"old"},
    );
}

test "forwardArgv routes a tap cask to its slug through --cask" {
    var name = "acme/tools/baz".*;
    try expectArgv(
        &.{ "--force", "--cask", "acme/tools/baz" },
        .{ .presence = .cask, .name = &name, .pinned = true },
        &.{"baz"},
    );
}
