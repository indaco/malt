//! malt — pin / unpin commands
//! Toggle the `pinned` column on an installed keg or cask. `mt upgrade`
//! reads the column to skip protected versions; the schema and
//! `list --pinned` already surface it.

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const schema_report = @import("schema_report.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub fn execute(ctx: *const AppCtx, _: std.mem.Allocator, args: []const []const u8) !void {
    return run(ctx, args, .pin);
}

pub fn executeUnpin(ctx: *const AppCtx, _: std.mem.Allocator, args: []const []const u8) !void {
    return run(ctx, args, .unpin);
}

const Action = enum {
    pin,
    unpin,

    fn flag(self: Action) bool {
        return self == .pin;
    }

    fn cmdName(self: Action) []const u8 {
        return @tagName(self);
    }

    fn doneVerb(self: Action) []const u8 {
        return switch (self) {
            .pin => "pinned",
            .unpin => "unpinned",
        };
    }
};

fn run(ctx: *const AppCtx, args: []const []const u8, action: Action) !void {
    if (help.showIfRequested(ctx, args, action.cmdName())) return;

    var force_cask = false;
    var force_formula = false;
    var name: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            force_cask = true;
        } else if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            force_formula = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (arg.len > 0 and arg[0] == '-') {
            output.err("Unknown flag: {s}", .{arg});
            return error.Aborted;
        } else if (name == null and arg.len > 0) {
            name = arg;
        }
    }

    // Brew's check and wording, ahead of the usage check like its parser.
    if (force_cask and force_formula) {
        output.err("Options --formula and --cask are mutually exclusive", .{});
        return error.Aborted;
    }
    const pkg = name orelse {
        output.err("Usage: mt {s} <name> [--cask | --formula]", .{action.cmdName()});
        return error.Aborted;
    };

    const prefix = atomic.maltPrefixOrAbort();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    schema.initSchema(&db) catch |e| if (e == error.SchemaTooNew) return schema_report.abortInitFailure(&db, e, prefix);

    // A bare name means the formula when both exist, as brew resolves it.
    const updated = blk: {
        if (!force_cask) {
            if (try setOrAbort(&db, .formula, pkg, action)) {
                if (!force_formula and lookupPinned(&db, .cask, pkg) != null) help.warnTreatedAsFormula(pkg);
                break :blk true;
            }
            if (force_formula) break :blk false;
        }
        break :blk try setOrAbort(&db, .cask, pkg, action);
    };
    if (!updated) {
        output.err("{s} is not installed", .{pkg});
        return error.Aborted;
    }

    output.success("{s} {s}", .{ pkg, action.doneVerb() });
}

fn setOrAbort(db: *sqlite.Database, kind: Kind, name: []const u8, action: Action) error{Aborted}!bool {
    return setPinned(db, kind, name, action.flag()) catch {
        output.err("Database update failed for {s}", .{name});
        return error.Aborted;
    };
}

/// Which table a pin lives in. Local so this leaf needs no API import.
pub const Kind = enum { formula, cask };

/// Set the `pinned` column on `name` in `kind`'s table only. Returns true
/// when a row was matched (idempotent re-pins still report true). False
/// means no installed package of that kind has this name.
pub fn setPinned(db: *sqlite.Database, kind: Kind, name: []const u8, value: bool) sqlite.SqliteError!bool {
    var stmt = try db.prepare(switch (kind) {
        .formula => "UPDATE kegs SET pinned = ?1 WHERE name = ?2;",
        .cask => "UPDATE casks SET pinned = ?1 WHERE token = ?2;",
    });
    defer stmt.finalize();
    try stmt.bindInt(1, @intFromBool(value));
    try stmt.bindText(2, name);
    _ = try stmt.step();
    return changes(db) > 0;
}

/// Returns true iff `kind`'s row for `name` has `pinned=1`. Never consults
/// the other kind: a formula and a cask sharing a name hold separate pins.
/// A missing row reads as not pinned — nothing to skip.
pub fn isPinned(db: *sqlite.Database, kind: Kind, name: []const u8) bool {
    return lookupPinned(db, kind, name) orelse false;
}

/// Null when `kind` has no row for `name`, which doubles as an existence check.
fn lookupPinned(db: *sqlite.Database, kind: Kind, name: []const u8) ?bool {
    var stmt = db.prepare(switch (kind) {
        .formula => "SELECT pinned FROM kegs WHERE name = ?1 LIMIT 1;",
        .cask => "SELECT pinned FROM casks WHERE token = ?1 LIMIT 1;",
    }) catch return null;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return null;
    const has = stmt.step() catch return null;
    if (!has) return null;
    return stmt.columnBool(0);
}

fn changes(db: *sqlite.Database) i64 {
    var stmt = db.prepare("SELECT changes();") catch return 0;
    defer stmt.finalize();
    const has = stmt.step() catch return 0;
    if (!has) return 0;
    return stmt.columnInt(0);
}

const testing = std.testing;

fn openSharedNameDb() !sqlite.Database {
    var db = try sqlite.Database.open(":memory:");
    errdefer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('box', 'box', '1.0', 'sha', '/cellar/box/1.0');
        \\INSERT INTO casks (token, name, version, url) VALUES ('box', 'Box', '2.0', 'https://example.invalid/box.zip');
    );
    return db;
}

test "a cask pin is read and written on the cask row even when a formula shares the name" {
    var db = try openSharedNameDb();
    defer db.close();

    try testing.expect(try setPinned(&db, .cask, "box", true));
    try testing.expect(isPinned(&db, .cask, "box"));
    try testing.expect(!isPinned(&db, .formula, "box"));
}

test "a formula pin is read and written on the keg row even when a cask shares the name" {
    var db = try openSharedNameDb();
    defer db.close();

    try testing.expect(try setPinned(&db, .formula, "box", true));
    try testing.expect(isPinned(&db, .formula, "box"));
    try testing.expect(!isPinned(&db, .cask, "box"));
}

test "a kind with no row of that name is not pinned and cannot be set" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec("INSERT INTO casks (token, name, version, url, pinned) VALUES ('solo', 'Solo', '1.0', 'https://example.invalid/s.zip', 1);");

    // A pinned cask must not leak into the formula's answer.
    try testing.expect(!isPinned(&db, .formula, "solo"));
    try testing.expect(!try setPinned(&db, .formula, "solo", true));
    try testing.expect(isPinned(&db, .cask, "solo"));
}
