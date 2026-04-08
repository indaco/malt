//! malt — dependency resolution
//! BFS dependency resolution with cycle detection and orphan finding.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const api_mod = @import("../net/api.zig");

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
pub fn resolve(
    allocator: std.mem.Allocator,
    root_name: []const u8,
    api: *api_mod.BrewApi,
    db: *sqlite.Database,
) ![]ResolvedDep {
    var result: std.ArrayList(ResolvedDep) = .empty;
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    // Queue for BFS
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);

    // Get root formula's dependencies
    const root_deps = getDeps(allocator, root_name, api) catch return result.toOwnedSlice(allocator) catch &.{};
    defer allocator.free(root_deps);

    for (root_deps) |dep| {
        queue.append(allocator, dep) catch continue;
    }

    visited.put(root_name, {}) catch {};

    while (queue.items.len > 0) {
        const dep_name = queue.orderedRemove(0);

        // Skip if already visited
        if (visited.get(dep_name) != null) continue;
        visited.put(dep_name, {}) catch continue;

        // Check if already installed
        const installed = isInstalled(db, dep_name);

        result.append(allocator, .{
            .name = dep_name,
            .already_installed = installed,
        }) catch continue;

        // If not installed, resolve its dependencies too
        if (!installed) {
            const sub_deps = getDeps(allocator, dep_name, api) catch continue;
            defer allocator.free(sub_deps);
            for (sub_deps) |sub_dep| {
                if (visited.get(sub_dep) == null) {
                    queue.append(allocator, sub_dep) catch continue;
                }
            }
        }
    }

    return result.toOwnedSlice(allocator) catch &.{};
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

    while (stmt.step() catch break) {
        const name = stmt.columnText(0) orelse continue;
        const owned = allocator.dupe(u8, std.mem.sliceTo(name, 0)) catch continue;
        orphans.append(allocator, owned) catch continue;
    }

    return orphans.toOwnedSlice(allocator) catch &.{};
}

// --- helpers ---

fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
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
                deps.append(allocator, owned) catch continue;
            },
            else => {},
        }
    }

    return deps.toOwnedSlice(allocator) catch &.{};
}
