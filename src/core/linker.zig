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
    /// Returns a slice of conflicts (files already linked to a different keg).
    pub fn checkConflicts(self: *Linker, keg_path: []const u8) ![]Conflict {
        const dirs_to_check = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc" };
        var conflicts: std.ArrayList(Conflict) = .empty;

        for (dirs_to_check) |subdir| {
            var keg_dir_buf: [512]u8 = undefined;
            const keg_subdir = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ keg_path, subdir }) catch continue;

            var dir = std.fs.openDirAbsolute(keg_subdir, .{ .iterate = true }) catch continue;
            defer dir.close();

            var prefix_dir_buf: [512]u8 = undefined;
            const prefix_subdir = std.fmt.bufPrint(&prefix_dir_buf, "{s}/{s}", .{ self.prefix, subdir }) catch continue;

            var prefix_dir = std.fs.openDirAbsolute(prefix_subdir, .{}) catch continue;
            defer prefix_dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .directory) continue;

                // Check if a symlink already exists at the target location.
                // 1 KiB fits every path malt produces under its prefix — the
                // previous `max_path_bytes` (~4 KiB) was stack-wasteful when
                // scanning kegs with many files.
                var link_target_buf: [1024]u8 = undefined;
                const link_target = prefix_dir.readLink(entry.name, &link_target_buf) catch continue;

                // If the existing symlink points into a different keg, it's a conflict
                if (!std.mem.startsWith(u8, link_target, keg_path)) {
                    var link_path_buf: [512]u8 = undefined;
                    const link_path = std.fmt.bufPrint(&link_path_buf, "{s}/{s}/{s}", .{ self.prefix, subdir, entry.name }) catch continue;

                    // Extract the existing keg path from the symlink target
                    // Targets look like: /opt/malt/Cellar/<name>/<ver>/bin/<file>
                    const existing_keg = extractKegFromPath(link_target) orelse link_target;

                    conflicts.append(self.allocator, .{
                        .link_path = self.allocator.dupe(u8, link_path) catch continue,
                        .existing_keg = self.allocator.dupe(u8, existing_keg) catch continue,
                    }) catch continue;
                }
            }
        }

        return conflicts.toOwnedSlice(self.allocator) catch return &.{};
    }

    /// Extract "Cellar/<name>/<ver>" from a full path like "/opt/malt/Cellar/foo/1.0/bin/foo"
    fn extractKegFromPath(path: []const u8) ?[]const u8 {
        const cellar_marker = "Cellar/";
        const idx = std.mem.indexOf(u8, path, cellar_marker) orelse return null;
        const after = path[idx + cellar_marker.len ..];
        // Find the slash between <name> and <ver>, then the slash after <ver>.
        const first_slash = std.mem.findScalar(u8, after, '/') orelse return after;
        const rest = after[first_slash + 1 ..];
        const second_slash = std.mem.findScalar(u8, rest, '/') orelse return after;
        return path[idx .. idx + cellar_marker.len + first_slash + 1 + second_slash];
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

            // Atomic symlink: create at a temp name, then rename into place.
            // This avoids a window where the link is absent after deleteFile.
            var tmp_name_buf: [280]u8 = undefined;
            const tmp_name = std.fmt.bufPrint(&tmp_name_buf, ".malt_tmp_{s}", .{entry.name}) catch continue;
            parent_dir.deleteFile(tmp_name) catch {};
            parent_dir.symLink(target, tmp_name, .{}) catch continue;
            parent_dir.rename(tmp_name, entry.name) catch {
                // Rename failed — fall back to direct replacement
                parent_dir.deleteFile(tmp_name) catch {};
                parent_dir.deleteFile(entry.name) catch {};
                parent_dir.symLink(target, entry.name, .{}) catch continue;
            };

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
