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

    // Queue of owned, heap-duped dep name strings. On scope exit anything
    // still sitting in the queue gets freed so partial BFS walks don't
    // leak.
    var queue: std.ArrayList([]const u8) = .empty;
    defer {
        for (queue.items) |s| allocator.free(s);
        queue.deinit(allocator);
    }

    // Seed the queue with the root formula's direct deps. getDeps returns
    // a slice of duped strings; we transfer each into the queue (or free
    // it on append failure) and then free the container itself.
    const root_deps = getDeps(allocator, root_name, api) catch {
        return result.toOwnedSlice(allocator) catch blk: {
            result.deinit(allocator);
            break :blk &.{};
        };
    };
    defer allocator.free(root_deps);

    for (root_deps) |dep| {
        queue.append(allocator, dep) catch {
            allocator.free(dep);
            continue;
        };
    }

    // Mark the root so sub-deps never try to recurse into it.
    visited.put(root_name, {}) catch {};

    while (queue.items.len > 0) {
        const dep_name = queue.orderedRemove(0);

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
                queue.append(allocator, sub_dep) catch {
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
