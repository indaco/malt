const std = @import("std");
const sqlite = @import("../db/sqlite.zig");

pub const LinkError = error{ ConflictFound, LinkFailed, UnlinkFailed, OutOfMemory };

pub const Conflict = struct {
    link_path: []const u8,
    existing_keg: []const u8,
};

pub const Linker = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    prefix: []const u8,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Database, prefix: []const u8) Linker {
        return .{ .allocator = allocator, .db = db, .prefix = prefix };
    }

    /// Check for symlink conflicts before linking.
    pub fn checkConflicts(self: *Linker, keg_path: []const u8) ![]Conflict {
        // Walk keg_path/bin/, keg_path/lib/, etc.
        // For each file, check if {prefix}/bin/{name} already exists
        // If it does and points to a different keg, that's a conflict
        _ = .{ self, keg_path };
        // Return empty for now — will implement full walk later
        return &.{};
    }

    /// Create symlinks for all files in a keg, recording in DB.
    pub fn link(self: *Linker, keg_path: []const u8, name: []const u8, keg_id: i64) !void {
        const dirs_to_link = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc" };

        for (dirs_to_link) |subdir| {
            self.linkSubdir(keg_path, subdir, name, keg_id) catch continue;
        }
    }

    fn linkSubdir(self: *Linker, keg_path: []const u8, subdir: []const u8, name: []const u8, keg_id: i64) !void {
        _ = name;
        var keg_dir_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ keg_path, subdir }) catch return;

        var dir = std.fs.openDirAbsolute(keg_subdir, .{ .iterate = true }) catch return;
        defer dir.close();

        // Ensure parent dir exists
        var parent_buf: [512]u8 = undefined;
        const parent = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ self.prefix, subdir }) catch return;
        std.fs.makeDirAbsolute(parent) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var parent_dir = std.fs.openDirAbsolute(parent, .{}) catch return;
        defer parent_dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) continue;

            var target_buf: [512]u8 = undefined;
            const target = std.fmt.bufPrint(&target_buf, "{s}/{s}/{s}", .{ keg_path, subdir, entry.name }) catch continue;

            // Remove existing symlink if present
            parent_dir.deleteFile(entry.name) catch {};

            // Create symlink
            parent_dir.symLink(target, entry.name, .{}) catch continue;

            // Build the full link path for DB recording
            var link_buf: [512]u8 = undefined;
            const link_path = std.fmt.bufPrint(&link_buf, "{s}/{s}/{s}", .{ self.prefix, subdir, entry.name }) catch continue;

            // Record in DB
            var stmt = self.db.prepare(
                "INSERT OR REPLACE INTO links (keg_id, link_path, target) VALUES (?1, ?2, ?3);",
            ) catch continue;
            defer stmt.finalize();
            stmt.bindInt(1, keg_id) catch continue;
            stmt.bindText(2, link_path) catch continue;
            stmt.bindText(3, target) catch continue;
            _ = stmt.step() catch {};
        }
    }

    /// Create opt/{name} -> Cellar/{name}/{version} symlink.
    pub fn linkOpt(self: *Linker, name: []const u8, version: []const u8) !void {
        var opt_parent_buf: [512]u8 = undefined;
        const opt_parent = std.fmt.bufPrint(&opt_parent_buf, "{s}/opt", .{self.prefix}) catch return;
        std.fs.makeDirAbsolute(opt_parent) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var opt_dir = std.fs.openDirAbsolute(opt_parent, .{}) catch return;
        defer opt_dir.close();

        var cellar_buf: [512]u8 = undefined;
        const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ self.prefix, name, version }) catch return;

        // Remove existing symlink if present
        opt_dir.deleteFile(name) catch {};

        // Create symlink
        opt_dir.symLink(cellar_path, name, .{}) catch {};
    }

    /// Remove all symlinks for a keg (from DB).
    pub fn unlink(self: *Linker, keg_id: i64) !void {
        // Query all links for this keg
        var stmt = self.db.prepare("SELECT link_path FROM links WHERE keg_id = ?1;") catch return;
        defer stmt.finalize();
        stmt.bindInt(1, keg_id) catch return;

        while (stmt.step() catch null) |has_row| {
            if (!has_row) break;
            const link_path = stmt.columnText(0) orelse continue;
            const path_slice = std.mem.sliceTo(link_path, 0);
            std.fs.cwd().deleteFile(path_slice) catch {};
        }

        // Delete from DB
        var del_stmt = self.db.prepare("DELETE FROM links WHERE keg_id = ?1;") catch return;
        defer del_stmt.finalize();
        del_stmt.bindInt(1, keg_id) catch return;
        _ = del_stmt.step() catch {};
    }
};
