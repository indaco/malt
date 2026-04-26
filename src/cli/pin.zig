//! malt — pin / unpin commands
//! Toggle the `pinned` column on an installed keg. `mt upgrade` reads
//! the column to skip protected versions; the schema and `list --pinned`
//! already surface it.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub fn execute(_: std.mem.Allocator, args: []const []const u8) !void {
    return run(args, .pin);
}

pub fn executeUnpin(_: std.mem.Allocator, args: []const []const u8) !void {
    return run(args, .unpin);
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

fn run(args: []const []const u8, action: Action) !void {
    if (help.showIfRequested(args, action.cmdName())) return;

    if (args.len == 0) {
        output.err("Usage: mt {s} <name>", .{action.cmdName()});
        return error.Aborted;
    }
    const name = args[0];

    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    schema.initSchema(&db) catch {};

    const updated = setPinned(&db, name, action.flag()) catch {
        output.err("Database update failed for {s}", .{name});
        return error.Aborted;
    };
    if (!updated) {
        output.err("{s} is not installed", .{name});
        return error.Aborted;
    }

    output.success("{s} {s}", .{ name, action.doneVerb() });
}

/// Set the `pinned` column on `name`. Returns true when a row was matched
/// (idempotent re-pins still report true). False means no installed keg
/// or cask of that name exists, which the caller surfaces as a usage error.
pub fn setPinned(db: *sqlite.Database, name: []const u8, value: bool) sqlite.SqliteError!bool {
    if (try setPinnedOn(db, "UPDATE kegs SET pinned = ?1 WHERE name = ?2;", name, value)) return true;
    // Fall through to casks so `mt pin firefox` works on an installed cask.
    return setPinnedOn(db, "UPDATE casks SET pinned = ?1 WHERE token = ?2;", name, value);
}

fn setPinnedOn(
    db: *sqlite.Database,
    sql: [:0]const u8,
    name: []const u8,
    value: bool,
) sqlite.SqliteError!bool {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    try stmt.bindInt(1, @intFromBool(value));
    try stmt.bindText(2, name);
    _ = try stmt.step();
    return changes(db) > 0;
}

/// Returns true iff an installed keg or cask named `name` has `pinned=1`.
/// Missing rows are reported as not pinned — callers treat the absence
/// of a row as "nothing to skip".
pub fn isPinned(db: *sqlite.Database, name: []const u8) bool {
    if (lookupPinned(db, "SELECT pinned FROM kegs WHERE name = ?1 LIMIT 1;", name)) |p| return p;
    return lookupPinned(db, "SELECT pinned FROM casks WHERE token = ?1 LIMIT 1;", name) orelse false;
}

fn lookupPinned(db: *sqlite.Database, sql: [:0]const u8, name: []const u8) ?bool {
    var stmt = db.prepare(sql) catch return null;
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
