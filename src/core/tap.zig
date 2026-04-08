const std = @import("std");
const sqlite = @import("../db/sqlite.zig");

pub const TapInfo = struct {
    name: []const u8,
    url: []const u8,
};

pub fn add(db: *sqlite.Database, name: []const u8, url: []const u8) !void {
    var stmt = db.prepare("INSERT OR IGNORE INTO taps (name, url) VALUES (?1, ?2);") catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;
    stmt.bindText(2, url) catch return;
    _ = stmt.step() catch {};
}

pub fn remove(db: *sqlite.Database, name: []const u8) !void {
    var stmt = db.prepare("DELETE FROM taps WHERE name = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;
    _ = stmt.step() catch {};
}

pub fn list(allocator: std.mem.Allocator, db: *sqlite.Database) ![]TapInfo {
    var taps: std.ArrayList(TapInfo) = .empty;
    var stmt = db.prepare("SELECT name, url FROM taps;") catch return taps.toOwnedSlice(allocator) catch &.{};
    defer stmt.finalize();

    while (stmt.step() catch null) |has_row| {
        if (!has_row) break;
        const n = stmt.columnText(0) orelse continue;
        const u = stmt.columnText(1) orelse continue;
        const name_owned = allocator.dupe(u8, std.mem.sliceTo(n, 0)) catch continue;
        const url_owned = allocator.dupe(u8, std.mem.sliceTo(u, 0)) catch continue;
        taps.append(allocator, .{ .name = name_owned, .url = url_owned }) catch continue;
    }

    return taps.toOwnedSlice(allocator) catch &.{};
}

/// Resolve a tap formula — builds the full tap formula name.
pub fn resolveFormula(allocator: std.mem.Allocator, user: []const u8, repo: []const u8, formula: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ user, repo, formula });
}
