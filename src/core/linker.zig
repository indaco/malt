const std = @import("std");
const testing = std.testing;

const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");

pub const LinkError = error{ ConflictFound, LinkFailed, UnlinkFailed, OutOfMemory };

pub const Conflict = struct {
    link_path: []const u8,
    existing_keg: []const u8,
};

pub const Linker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.Database,
    prefix: []const u8,

    /// Keg subdirectories whose top-level files get symlinked into the
    /// prefix. `bin`/`sbin` lead so the bin-isolated variant is a tail
    /// slice (`[2..]`). The install path also reads this to decide whether
    /// an extracted archive produced anything linkable at all — keep that
    /// check and `link` reading the same list so they cannot drift.
    pub const linkable_dirs = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc" };

    pub fn init(io: std.Io, allocator: std.mem.Allocator, db: *sqlite.Database, prefix: []const u8) Linker {
        return .{ .allocator = allocator, .io = io, .db = db, .prefix = prefix };
    }

    /// Check for symlink conflicts before linking. When `bin_isolated`
    /// is true, the probe skips `bin`/`sbin` to mirror the link-side
    /// policy — otherwise a dep installed under isolation would falsely
    /// trigger a conflict against a keg whose bins were never linked.
    pub fn checkConflicts(self: *Linker, keg_path: []const u8, bin_isolated: bool) ![]Conflict {
        const dirs_full = [_][]const u8{ "bin", "sbin", "lib", "include", "share", "etc" };
        const dirs_isolated = [_][]const u8{ "lib", "include", "share", "etc" };
        const dirs_to_check: []const []const u8 = if (bin_isolated) &dirs_isolated else &dirs_full;
        var conflicts: std.ArrayList(Conflict) = .empty;

        for (dirs_to_check) |subdir| {
            var keg_dir_buf: [512]u8 = undefined;
            const keg_subdir = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ keg_path, subdir }) catch continue;

            var dir = std.Io.Dir.openDirAbsolute(self.io, keg_subdir, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);

            var prefix_dir_buf: [512]u8 = undefined;
            const prefix_subdir = std.fmt.bufPrint(&prefix_dir_buf, "{s}/{s}", .{ self.prefix, subdir }) catch continue;

            var prefix_dir = std.Io.Dir.openDirAbsolute(self.io, prefix_subdir, .{}) catch continue;
            defer prefix_dir.close(self.io);

            var iter = dir.iterate();
            while (iter.next(self.io) catch null) |entry| {
                if (entry.kind == .directory) continue;

                // Check if a symlink already exists at the target location.
                // 1 KiB fits every path malt produces under its prefix — the
                // previous `max_path_bytes` (~4 KiB) was stack-wasteful when
                // scanning kegs with many files.
                var link_target_buf: [1024]u8 = undefined;
                const link_target_len = prefix_dir.readLink(self.io, entry.name, &link_target_buf) catch continue;
                const link_target = link_target_buf[0..link_target_len];

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
    /// When `bin_isolated` is true, the keg's `bin`/`sbin` contents are
    /// deliberately left unlinked — `opt/<name>` and dependents'
    /// `LC_LOAD_DYLIB` paths continue to resolve via `lib`, so compiled
    /// formulae are unaffected; only the global PATH entries disappear.
    pub fn link(self: *Linker, keg_path: []const u8, name: []const u8, keg_id: i64, bin_isolated: bool) !void {
        // bin-isolated drops the leading `bin`/`sbin`; full keeps them.
        const dirs_to_link: []const []const u8 = if (bin_isolated) linkable_dirs[2..] else &linkable_dirs;

        for (dirs_to_link) |subdir| {
            self.linkSubdir(keg_path, subdir, name, keg_id) catch continue;
        }
    }

    fn linkSubdir(self: *Linker, keg_path: []const u8, subdir: []const u8, name: []const u8, keg_id: i64) !void {
        _ = name;
        var keg_dir_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ keg_path, subdir }) catch return;

        var dir = std.Io.Dir.openDirAbsolute(self.io, keg_subdir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        // Ensure parent dir exists
        var parent_buf: [512]u8 = undefined;
        const parent = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ self.prefix, subdir }) catch return;
        std.Io.Dir.createDirAbsolute(self.io, parent, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var parent_dir = std.Io.Dir.openDirAbsolute(self.io, parent, .{}) catch return;
        defer parent_dir.close(self.io);

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind == .directory) continue;

            var target_buf: [512]u8 = undefined;
            const target = std.fmt.bufPrint(&target_buf, "{s}/{s}/{s}", .{ keg_path, subdir, entry.name }) catch continue;

            // Atomic symlink: create at a temp name, then rename into place.
            // This avoids a window where the link is absent after deleteFile.
            var tmp_name_buf: [280]u8 = undefined;
            const tmp_name = std.fmt.bufPrint(&tmp_name_buf, ".malt_tmp_{s}", .{entry.name}) catch continue;
            // Stale tmp from a prior aborted link; symLink would otherwise EEXIST.
            parent_dir.deleteFile(self.io, tmp_name) catch {};
            parent_dir.symLink(self.io, target, tmp_name, .{}) catch continue;
            parent_dir.rename(tmp_name, parent_dir, entry.name, self.io) catch {
                // Rename failed — fall back to direct replacement (non-atomic).
                parent_dir.deleteFile(self.io, tmp_name) catch {};
                parent_dir.deleteFile(self.io, entry.name) catch {};
                parent_dir.symLink(self.io, target, entry.name, .{}) catch continue;
            };

            // Build the full link path for DB recording
            var link_buf: [512]u8 = undefined;
            const link_path = std.fmt.bufPrint(&link_buf, "{s}/{s}/{s}", .{ self.prefix, subdir, entry.name }) catch continue;

            // Record in DB
            var stmt = try self.db.prepare(
                "INSERT OR REPLACE INTO links (keg_id, link_path, target) VALUES (?1, ?2, ?3);",
            );
            defer stmt.finalize();
            try stmt.bindInt(1, keg_id);
            try stmt.bindText(2, link_path);
            try stmt.bindText(3, target);
            _ = try stmt.step();
        }
    }

    /// Create `opt/{name} -> Cellar/{name}/{version}` symlink.
    ///
    /// Dependents' relocated `LC_LOAD_DYLIB` entries point into
    /// `<prefix>/opt/<dep>/lib/...`; a missing link there surfaces as a
    /// dyld load failure at *runtime*, far from this call. Errors
    /// propagate so the caller can surface them at install time.
    pub fn linkOpt(self: *Linker, name: []const u8, version: []const u8) !void {
        var opt_parent_buf: [512]u8 = undefined;
        const opt_parent = try std.fmt.bufPrint(&opt_parent_buf, "{s}/opt", .{self.prefix});
        std.Io.Dir.createDirAbsolute(self.io, opt_parent, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        var opt_dir = try std.Io.Dir.openDirAbsolute(self.io, opt_parent, .{});
        defer opt_dir.close(self.io);

        var cellar_buf: [512]u8 = undefined;
        const cellar_path = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ self.prefix, name, version });

        // Stale opt link from a prior version; symLink would otherwise EEXIST.
        // Best-effort: a directory at opt/<name> isn't removable here, and
        // the symLink below surfaces the real obstruction as PathAlreadyExists.
        opt_dir.deleteFile(self.io, name) catch {};

        try opt_dir.symLink(self.io, cellar_path, name, .{});
    }

    /// Remove all symlinks for a keg (from DB).
    pub fn unlink(self: *Linker, keg_id: i64) sqlite.SqliteError!void {
        var stmt = try self.db.prepare("SELECT link_path FROM links WHERE keg_id = ?1;");
        defer stmt.finalize();
        try stmt.bindInt(1, keg_id);

        while (try stmt.step()) {
            const link_path = stmt.columnText(0) orelse continue;
            const path_slice = std.mem.sliceTo(link_path, 0);
            // Symlink may already be gone from the filesystem; DB row is the source of truth we're flushing.
            std.Io.Dir.cwd().deleteFile(self.io, path_slice) catch {};
        }

        var del_stmt = try self.db.prepare("DELETE FROM links WHERE keg_id = ?1;");
        defer del_stmt.finalize();
        try del_stmt.bindInt(1, keg_id);
        _ = try del_stmt.step();
    }
};

/// Read-only link status for a keg: true iff any symlink is recorded for
/// it in `links`. Counterpart to `link`/`unlink`; `mt list --json
/// --linked` uses it to report whether a keg is active in the prefix.
/// Any DB error reads as "not linked" rather than failing the row.
pub fn isKegLinked(db: *sqlite.Database, keg_id: i64) bool {
    var stmt = db.prepare("SELECT EXISTS(SELECT 1 FROM links WHERE keg_id = ?1);") catch return false;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return false;
    if (stmt.step() catch false) return stmt.columnInt(0) != 0;
    return false;
}

test "isKegLinked reflects whether the keg has link rows" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs (id, name, full_name, version, store_sha256, cellar_path)
        \\VALUES (1, 'linked-keg', 'linked-keg', '1.0', 'aa', '/c/linked-keg/1.0'),
        \\       (2, 'bare-keg',   'bare-keg',   '2.0', 'bb', '/c/bare-keg/2.0');
    );
    // Only keg 1 has a recorded symlink.
    try db.exec(
        \\INSERT INTO links (keg_id, link_path, target)
        \\VALUES (1, '/opt/malt/bin/linked-keg', '/c/linked-keg/1.0/bin/linked-keg');
    );

    try testing.expect(isKegLinked(&db, 1));
    try testing.expect(!isKegLinked(&db, 2));
    // A keg id that doesn't exist is simply "not linked".
    try testing.expect(!isKegLinked(&db, 999));
}
