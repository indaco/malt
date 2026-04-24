//! malt — dependency resolution
//! BFS dependency resolution with cycle detection and orphan finding.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const api_mod = @import("../net/api.zig");
const fs_compat = @import("../fs/compat.zig");

pub const DepError = error{
    CycleDetected,
    ResolutionFailed,
    OutOfMemory,
};

pub const ResolvedDep = struct {
    name: []const u8,
    already_installed: bool,
};

/// Resolve all dependencies for a formula using BFS.
/// Returns dependencies in topological order (deps before dependents).
/// Skips already-installed packages.
///
/// Ownership: each returned `ResolvedDep.name` is heap-allocated with
/// `allocator` and the caller must free both every `name` and the outer
/// slice. `getDeps` already hands us duped strings, so every string we
/// receive from it is either (a) moved into `result`, (b) moved into
/// `queue` for later processing, or (c) freed on the spot. Nothing is
/// allowed to escape silently — earlier versions leaked duped dep
/// strings any time BFS skipped a name via the `visited` set.
pub fn resolve(
    allocator: std.mem.Allocator,
    root_name: []const u8,
    api: *api_mod.BrewApi,
    db: *sqlite.Database,
) ![]ResolvedDep {
    var result: std.ArrayList(ResolvedDep) = .empty;

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    // std.Deque owns the head-tail ring; on scope exit we free any
    // strings still queued (early-return or OOM paths).
    var queue: std.Deque([]const u8) = .empty;
    defer {
        var it = queue.iterator();
        while (it.next()) |s| allocator.free(s);
        queue.deinit(allocator);
    }

    const root_deps = getDeps(allocator, root_name, api) catch {
        return result.toOwnedSlice(allocator) catch blk: {
            result.deinit(allocator);
            break :blk &.{};
        };
    };
    defer allocator.free(root_deps);

    for (root_deps) |dep| {
        queue.pushBack(allocator, dep) catch {
            allocator.free(dep);
            continue;
        };
    }

    visited.put(root_name, {}) catch {};

    while (queue.popFront()) |dep_name| {
        // Dedup: already processed → free the duplicate.
        if (visited.get(dep_name) != null) {
            allocator.free(dep_name);
            continue;
        }

        // Transfer ownership of `dep_name` into `result` BEFORE marking it
        // in `visited`. That way `visited`'s key borrows from `result`'s
        // stable storage — if we did it the other way round and the
        // append failed, we'd either leak the string or leave `visited`
        // with a dangling key.
        const installed = isInstalled(db, dep_name);
        result.append(allocator, .{
            .name = dep_name,
            .already_installed = installed,
        }) catch {
            allocator.free(dep_name);
            continue;
        };

        // visited.put failure is non-fatal: worst case we re-process the
        // name later, which the dedup check above will handle.
        visited.put(dep_name, {}) catch {};

        // Fan out into this dep's own dependencies.
        if (!installed) {
            const sub_deps = getDeps(allocator, dep_name, api) catch continue;
            defer allocator.free(sub_deps);

            for (sub_deps) |sub_dep| {
                // Free duplicates immediately instead of dropping them on
                // the floor — the previous code's silent leak was here.
                if (visited.get(sub_dep) != null) {
                    allocator.free(sub_dep);
                    continue;
                }
                queue.pushBack(allocator, sub_dep) catch {
                    allocator.free(sub_dep);
                    continue;
                };
            }
        }
    }

    return result.toOwnedSlice(allocator) catch blk: {
        // toOwnedSlice can only fail if the shrink-realloc fails; in that
        // case `result` still owns everything, so free every name before
        // giving up.
        for (result.items) |r| allocator.free(r.name);
        result.deinit(allocator);
        break :blk &.{};
    };
}

/// Find orphaned dependencies (install_reason='dependency' but not needed by any direct install).
pub fn findOrphans(allocator: std.mem.Allocator, db: *sqlite.Database) ![]const []const u8 {
    var orphans: std.ArrayList([]const u8) = .empty;

    // Get all dependency-installed kegs
    var stmt = db.prepare(
        \\SELECT k.name FROM kegs k
        \\WHERE k.install_reason = 'dependency'
        \\AND k.name NOT IN (
        \\    SELECT DISTINCT d.dep_name FROM dependencies d
        \\    JOIN kegs k2 ON k2.id = d.keg_id
        \\    WHERE k2.install_reason = 'direct'
        \\);
    ) catch return orphans.toOwnedSlice(allocator) catch &.{};
    defer stmt.finalize();

    while (true) {
        const has_row = stmt.step() catch break;
        if (!has_row) break;
        const name = stmt.columnText(0) orelse continue;
        const owned = allocator.dupe(u8, std.mem.sliceTo(name, 0)) catch continue;
        orphans.append(allocator, owned) catch continue;
    }

    return orphans.toOwnedSlice(allocator) catch &.{};
}

// --- helpers ---

fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT cellar_path FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    if (!(stmt.step() catch false)) return false;

    // Trust the DB only when the cellar_path is still on disk.
    const cp_raw = stmt.columnText(0) orelse return false;
    const cellar_path = std.mem.sliceTo(cp_raw, 0);
    fs_compat.accessAbsolute(cellar_path, .{}) catch return false;
    return true;
}

/// Keep `opt/{name}` pointing at the keg's DB-recorded cellar_path.
/// No-op when already correct; silent on failure.
pub fn ensureOptLink(db: *sqlite.Database, prefix: []const u8, name: []const u8) void {
    var stmt = db.prepare("SELECT cellar_path FROM kegs WHERE name = ?1 LIMIT 1;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;
    if (!(stmt.step() catch false)) return;
    const cp_raw = stmt.columnText(0) orelse return;
    const cellar_path = std.mem.sliceTo(cp_raw, 0);

    var opt_buf: [512]u8 = undefined;
    const opt_path = std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ prefix, name }) catch return;

    // Fast path: symlink already resolves to the DB's cellar_path.
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (fs_compat.readLinkAbsolute(opt_path, &target_buf)) |target| {
        if (std.mem.eql(u8, target, cellar_path)) return;
    } else |_| {}

    var opt_parent_buf: [512]u8 = undefined;
    const opt_parent = std.fmt.bufPrint(&opt_parent_buf, "{s}/opt", .{prefix}) catch return;
    fs_compat.makeDirAbsolute(opt_parent) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return,
    };
    var parent_dir = fs_compat.openDirAbsolute(opt_parent, .{}) catch return;
    defer parent_dir.close();
    parent_dir.deleteFile(name) catch {};
    parent_dir.symLink(cellar_path, name, .{}) catch {};
}

fn getDeps(allocator: std.mem.Allocator, name: []const u8, api: *api_mod.BrewApi) ![][]const u8 {
    const json_bytes = api.fetchFormula(name) catch return &.{};
    defer allocator.free(json_bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return &.{};
    defer parsed.deinit();

    const obj = parsed.value.object;
    const deps_val = obj.get("dependencies") orelse return &.{};
    const arr = switch (deps_val) {
        .array => |a| a,
        else => return &.{},
    };

    var deps: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        switch (item) {
            .string => |s| {
                const owned = allocator.dupe(u8, s) catch continue;
                // Free the duped bytes if appending to the list fails —
                // otherwise they leak silently.
                deps.append(allocator, owned) catch {
                    allocator.free(owned);
                    continue;
                };
            },
            else => {},
        }
    }

    return deps.toOwnedSlice(allocator) catch blk: {
        // toOwnedSlice can fail on shrink-realloc; in that case every
        // duped string is still owned by `deps`. Free them before
        // returning an empty slice so callers see a clean state.
        for (deps.items) |d| allocator.free(d);
        deps.deinit(allocator);
        break :blk &.{};
    };
}
