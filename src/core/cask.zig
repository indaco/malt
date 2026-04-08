//! malt — cask module
//! Cask JSON parsing and installation (DMG, PKG, ZIP).

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const client_mod = @import("../net/client.zig");

pub const CaskError = error{
    ParseFailed,
    DownloadFailed,
    InstallFailed,
    UninstallFailed,
    Sha256Mismatch,
    OutOfMemory,
};

pub const Cask = struct {
    token: []const u8,
    name: []const u8,
    version: []const u8,
    desc: []const u8,
    homepage: []const u8,
    url: []const u8,
    sha256: ?[]const u8,
    auto_updates: bool,

    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Cask) void {
        self.parsed.deinit();
    }
};

/// Parse cask JSON from Homebrew API.
pub fn parseCask(allocator: std.mem.Allocator, json_bytes: []const u8) !Cask {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch
        return CaskError.ParseFailed;
    errdefer parsed.deinit();

    const obj = parsed.value.object;

    return .{
        .token = getStr(obj, "token") orelse return CaskError.ParseFailed,
        .name = getFirstName(obj) orelse getStr(obj, "token") orelse return CaskError.ParseFailed,
        .version = getStr(obj, "version") orelse "unknown",
        .desc = getStr(obj, "desc") orelse "",
        .homepage = getStr(obj, "homepage") orelse "",
        .url = getStr(obj, "url") orelse return CaskError.ParseFailed,
        .sha256 = getStr(obj, "sha256"),
        .auto_updates = getBool(obj, "auto_updates") orelse false,
        .parsed = parsed,
    };
}

/// Record cask installation in database.
pub fn recordInstall(db: *sqlite.Database, cask: *const Cask, app_path: ?[]const u8) !void {
    var stmt = db.prepare(
        "INSERT OR REPLACE INTO casks (token, name, version, url, sha256, app_path, auto_updates) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
    ) catch return;
    defer stmt.finalize();

    stmt.bindText(1, cask.token) catch return;
    stmt.bindText(2, cask.name) catch return;
    stmt.bindText(3, cask.version) catch return;
    stmt.bindText(4, cask.url) catch return;
    if (cask.sha256) |s| stmt.bindText(5, s) catch return else stmt.bindNull(5) catch return;
    if (app_path) |p| stmt.bindText(6, p) catch return else stmt.bindNull(6) catch return;
    stmt.bindInt(7, if (cask.auto_updates) 1 else 0) catch return;
    _ = stmt.step() catch {};
}

/// Remove cask record from database.
pub fn removeRecord(db: *sqlite.Database, token: []const u8) !void {
    var stmt = db.prepare("DELETE FROM casks WHERE token = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return;
    _ = stmt.step() catch {};
}

// --- JSON helpers ---

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

fn getFirstName(obj: std.json.ObjectMap) ?[]const u8 {
    const val = obj.get("name") orelse return null;
    switch (val) {
        .array => |arr| {
            if (arr.items.len > 0) {
                return switch (arr.items[0]) {
                    .string => |s| s,
                    else => null,
                };
            }
            return null;
        },
        .string => |s| return s,
        else => return null,
    }
}
