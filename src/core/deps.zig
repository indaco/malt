//! malt — BFS dep resolution with cycle detection and orphan finding.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const api_mod = @import("../net/api.zig");
const fs_compat = @import("../fs/compat.zig");
const formula_mod = @import("formula.zig");

pub const DepError = error{
    CycleDetected,
    ResolutionFailed,
    OutOfMemory,
};

pub const ResolvedDep = struct {
    name: []const u8,
    already_installed: bool,
};

/// Per-invocation parsed-formula cache: collapses the 2-3× re-parse the
/// install pipeline used to pay per dep. All allocations land on a
/// private arena so `deinit` is a single bulk reclaim.
///
/// Thread-safe via a `std.atomic.Mutex` spin-lock — short critical
/// sections (one map op + one parse), no Io dependency, futures-proof
/// for parallel workers folding into the cache.
pub const FormulaCache = struct {
    /// Owns every key dupe, the boxed `Formula`s, and parseFormula's
    /// internal allocations. `init` is allocation-free until first use.
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(*formula_mod.Formula),
    /// Bumps on `getOrParse` miss; tests pin parse-once via this counter.
    parse_count: usize,
    mutex: std.atomic.Mutex,

    pub fn init(parent: std.mem.Allocator) FormulaCache {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent),
            .map = .empty,
            .parse_count = 0,
            .mutex = .unlocked,
        };
    }

    /// Single free site — drops the arena and every parsed tree with it.
    pub fn deinit(self: *FormulaCache) void {
        self.arena.deinit();
    }

    /// Caller borrows the pointer until cache deinit; never frees it.
    pub fn get(self: *FormulaCache, name: []const u8) ?*const formula_mod.Formula {
        self.lock();
        defer self.mutex.unlock();
        return self.map.get(name);
    }

    /// Live entry count — used by tests pinning the per-invocation bound.
    pub fn entryCount(self: *FormulaCache) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.map.count();
    }

    /// Single seam every install-side parser routes through.
    pub fn getOrParse(
        self: *FormulaCache,
        name: []const u8,
        json: []const u8,
    ) !*const formula_mod.Formula {
        self.lock();
        defer self.mutex.unlock();

        if (self.map.get(name)) |existing| return existing;

        const a = self.arena.allocator();
        const owned_key = try a.dupe(u8, name);
        const slot = try a.create(formula_mod.Formula);
        slot.* = try formula_mod.parseFormula(a, json);
        try self.map.put(a, owned_key, slot);
        self.parse_count += 1;
        return slot;
    }

    inline fn lock(self: *FormulaCache) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

/// BFS resolve returning deps in topological order; skips already-installed.
/// Caller frees each `ResolvedDep.name` and the outer slice. Every string
/// from `getDeps` is either moved into `result`/`queue` or freed on the spot.
/// `cache` is shared with the download pipeline so each formula parses once.
pub fn resolve(
    allocator: std.mem.Allocator,
    root_name: []const u8,
    api: *api_mod.BrewApi,
    db: *sqlite.Database,
    cache: *FormulaCache,
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

    const root_deps = getDeps(allocator, root_name, api, cache) catch {
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

    // OOM on visited.put is non-fatal: duplicates are caught by the dedup check below.
    visited.put(root_name, {}) catch {};

    while (queue.popFront()) |dep_name| {
        // Dedup: already processed → free the duplicate.
        if (visited.get(dep_name) != null) {
            allocator.free(dep_name);
            continue;
        }

        // Append to `result` before marking `visited` — `visited` borrows from
        // `result`'s stable storage, and reversing risks leak or dangle on OOM.
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
            const sub_deps = getDeps(allocator, dep_name, api, cache) catch continue;
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

/// Find orphaned dependencies (install_reason='dependency' and not in the
/// transitive closure of any direct install's dependency graph).
///
/// The recursive CTE seeds with kegs directly listed by any `install_reason
/// = 'direct'` keg, then walks `dependencies` rows transitively so a dep
/// reached only through another dep (e.g. `node` → `openssl@3` →
/// `ca-certificates`) is still classed as retained. A flat one-level
/// query would mis-purge those grandchild deps.
pub fn findOrphans(allocator: std.mem.Allocator, db: *sqlite.Database) ![]const []const u8 {
    var orphans: std.ArrayList([]const u8) = .empty;

    var stmt = db.prepare(
        \\WITH RECURSIVE retained(name) AS (
        \\    SELECT DISTINCT d.dep_name
        \\    FROM dependencies d
        \\    JOIN kegs k ON k.id = d.keg_id
        \\    WHERE k.install_reason = 'direct'
        \\    UNION
        \\    SELECT d.dep_name
        \\    FROM dependencies d
        \\    JOIN kegs k2 ON k2.id = d.keg_id
        \\    JOIN retained r ON r.name = k2.name
        \\)
        \\SELECT k.name FROM kegs k
        \\WHERE k.install_reason = 'dependency'
        \\AND k.name NOT IN (SELECT name FROM retained);
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
    // Stale opt/<name> may not exist on first link; symLink would EEXIST otherwise.
    parent_dir.deleteFile(name) catch {};
    // Best-effort opt refresh: a failure here leaves the DB correct; `mt link` recovers.
    parent_dir.symLink(cellar_path, name, .{}) catch {};
}

/// Resolve a formula's direct deps through the shared cache. JSON without
/// a `name` field falls through to a Value-walk so synthetic fixtures and
/// upstream API quirks keep walking the graph (cache stays empty for that
/// entry — a malformed Formula is no use to downstream consumers).
fn getDeps(
    allocator: std.mem.Allocator,
    name: []const u8,
    api: *api_mod.BrewApi,
    cache: *FormulaCache,
) ![][]const u8 {
    if (cache.get(name)) |formula| return dupeDepNames(allocator, formula.dependencies);

    const json_bytes = api.fetchFormula(name) catch return &.{};
    defer allocator.free(json_bytes);

    if (cache.getOrParse(name, json_bytes)) |formula| {
        return dupeDepNames(allocator, formula.dependencies);
    } else |_| {
        return getDepsFromValue(allocator, json_bytes);
    }
}

/// Permissive dep-list extraction for JSON `parseFormula` rejects.
/// Reads `dependencies[]` directly off the dynamic Value tree.
fn getDepsFromValue(allocator: std.mem.Allocator, json_bytes: []const u8) ![][]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return &.{};
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return &.{},
    };
    const arr = switch (obj.get("dependencies") orelse return &.{}) {
        .array => |a| a,
        else => return &.{},
    };

    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => continue,
        };
        const owned = allocator.dupe(u8, s) catch continue;
        out.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }
    return out.toOwnedSlice(allocator) catch blk: {
        for (out.items) |d| allocator.free(d);
        out.deinit(allocator);
        break :blk &.{};
    };
}

/// Dupe every dep name onto the BFS allocator — `resolve` owns the strings.
fn dupeDepNames(allocator: std.mem.Allocator, deps: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (deps) |d| {
        const owned = allocator.dupe(u8, d) catch continue;
        out.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }
    return out.toOwnedSlice(allocator) catch blk: {
        for (out.items) |d| allocator.free(d);
        out.deinit(allocator);
        break :blk &.{};
    };
}

// --- FormulaCache unit tests (no DB / no network) -------------------------

const testing = std.testing;

/// Minimal formula fixture for the cache wrapper tests.
fn testFormulaJson(comptime name: []const u8) []const u8 {
    return "{\"name\":\"" ++ name ++ "\"," ++
        "\"versions\":{\"stable\":\"1.0\"}," ++
        "\"dependencies\":[],\"oldnames\":[]}";
}

test "FormulaCache.getOrParse increments parse_count only on miss" {
    var cache = FormulaCache.init(testing.allocator);
    defer cache.deinit();

    _ = try cache.getOrParse("hello", testFormulaJson("hello"));
    try testing.expectEqual(@as(usize, 1), cache.parse_count);

    // Repeat name must hit the cache.
    _ = try cache.getOrParse("hello", testFormulaJson("hello"));
    try testing.expectEqual(@as(usize, 1), cache.parse_count);

    // Distinct name re-bumps; cache is keyed per formula.
    _ = try cache.getOrParse("world", testFormulaJson("world"));
    try testing.expectEqual(@as(usize, 2), cache.parse_count);
}

test "FormulaCache.get returns null on miss and the cached pointer on hit" {
    var cache = FormulaCache.init(testing.allocator);
    defer cache.deinit();

    try testing.expect(cache.get("nope") == null);

    _ = try cache.getOrParse("alpha", testFormulaJson("alpha"));

    const hit = cache.get("alpha") orelse return error.TestExpectedHit;
    try testing.expectEqualStrings("alpha", hit.name);
}

test "FormulaCache.deinit releases the arena and every parsed tree" {
    // testing.allocator surfaces any unfreed byte; arena.deinit must
    // sweep every parseFormula side allocation in one shot.
    var cache = FormulaCache.init(testing.allocator);
    _ = try cache.getOrParse("a", testFormulaJson("a"));
    _ = try cache.getOrParse("b", testFormulaJson("b"));
    cache.deinit();
}

test "FormulaCache.entryCount tracks the live entry count" {
    var cache = FormulaCache.init(testing.allocator);
    defer cache.deinit();

    try testing.expectEqual(@as(usize, 0), cache.entryCount());
    _ = try cache.getOrParse("a", testFormulaJson("a"));
    try testing.expectEqual(@as(usize, 1), cache.entryCount());
    _ = try cache.getOrParse("a", testFormulaJson("a"));
    try testing.expectEqual(@as(usize, 1), cache.entryCount());
    _ = try cache.getOrParse("b", testFormulaJson("b"));
    try testing.expectEqual(@as(usize, 2), cache.entryCount());
}
