//! malt — bundle cleanup
//!
//! `mt bundle cleanup` removes packages on disk that the Brewfile no longer
//! lists. This module owns the pure diff helper; the CLI layer wires the
//! database query and the uninstall pipeline around it.

const std = @import("std");
const manifest_mod = @import("manifest.zig");
const sqlite = @import("../../db/sqlite.zig");

pub const CleanupError = error{
    OutOfMemory,
    NoDispatcher,
    DatabaseError,
};

pub const MemberKind = enum { formula, cask };

pub const MemberPreview = struct {
    kind: MemberKind,
    name: []const u8,
};

pub const MemberError = struct {
    kind: MemberKind,
    name: []const u8,
    err: anyerror,
};

/// Layering seam: the CLI wires `cli/uninstall` behind this. Keeping the
/// dispatcher injected keeps `core/bundle/cleanup.zig` free of `cli/*`
/// imports, mirroring the existing bundle runner.
pub const Dispatcher = struct {
    ctx: ?*anyopaque = null,
    uninstallFormula: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void,
    uninstallCask: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void,
};

pub const Options = struct {
    dry_run: bool = false,
    dispatcher: ?*const Dispatcher = null,
};

/// Outcome of `run`. `previews` is populated on dry-run, `failures` on
/// real runs that hit per-member errors. Names are borrowed from the
/// caller's `Plan`, which must outlive the report.
pub const Report = struct {
    allocator: std.mem.Allocator,
    failures: []MemberError,
    previews: []MemberPreview,

    pub fn hasFailure(self: Report) bool {
        return self.failures.len > 0;
    }

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.failures);
        self.allocator.free(self.previews);
        self.* = undefined;
    }
};

/// Names that are installed today but absent from the Brewfile and so are
/// candidates for removal. Strings are owned by the plan; `deinit` frees
/// both slices and every name in them.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    formulas: [][]const u8,
    casks: [][]const u8,

    pub fn isEmpty(self: Plan) bool {
        return self.formulas.len == 0 and self.casks.len == 0;
    }

    pub fn deinit(self: *Plan) void {
        for (self.formulas) |n| self.allocator.free(n);
        for (self.casks) |n| self.allocator.free(n);
        self.allocator.free(self.formulas);
        self.allocator.free(self.casks);
        self.* = undefined;
    }
};

/// Direct formulas plus every cask currently installed, queried from the
/// malt database. Strings are owned; `deinit` frees them.
pub const InstalledLists = struct {
    allocator: std.mem.Allocator,
    formulas: [][]const u8,
    casks: [][]const u8,

    pub fn deinit(self: *InstalledLists) void {
        for (self.formulas) |n| self.allocator.free(n);
        for (self.casks) |n| self.allocator.free(n);
        self.allocator.free(self.formulas);
        self.allocator.free(self.casks);
        self.* = undefined;
    }
};

/// Pull the cleanup-relevant rows from the database. Only direct installs
/// are candidates — indirect deps stay managed by `purge --unused-deps`.
pub fn collectInstalled(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
) CleanupError!InstalledLists {
    var formulas: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedNames(allocator, &formulas);
    var casks: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedNames(allocator, &casks);

    {
        var stmt = db.prepare(
            "SELECT name FROM kegs WHERE install_reason='direct' ORDER BY name;",
        ) catch return CleanupError.DatabaseError;
        defer stmt.finalize();
        while (stmt.step() catch return CleanupError.DatabaseError) {
            const n = stmt.columnText(0) orelse continue;
            const owned = allocator.dupe(u8, std.mem.sliceTo(n, 0)) catch
                return CleanupError.OutOfMemory;
            formulas.append(allocator, owned) catch {
                allocator.free(owned);
                return CleanupError.OutOfMemory;
            };
        }
    }

    {
        var stmt = db.prepare("SELECT token FROM casks ORDER BY token;") catch
            return CleanupError.DatabaseError;
        defer stmt.finalize();
        while (stmt.step() catch return CleanupError.DatabaseError) {
            const n = stmt.columnText(0) orelse continue;
            const owned = allocator.dupe(u8, std.mem.sliceTo(n, 0)) catch
                return CleanupError.OutOfMemory;
            casks.append(allocator, owned) catch {
                allocator.free(owned);
                return CleanupError.OutOfMemory;
            };
        }
    }

    const owned_formulas = formulas.toOwnedSlice(allocator) catch return CleanupError.OutOfMemory;
    errdefer allocator.free(owned_formulas);
    const owned_casks = casks.toOwnedSlice(allocator) catch return CleanupError.OutOfMemory;

    return .{
        .allocator = allocator,
        .formulas = owned_formulas,
        .casks = owned_casks,
    };
}

/// Compute the cleanup plan: every installed name not present in the
/// manifest, returned sorted by name. Only direct installs are candidates —
/// indirect deps are managed by `purge --unused-deps`.
pub fn diff(
    allocator: std.mem.Allocator,
    manifest: manifest_mod.Manifest,
    installed_formulas: []const []const u8,
    installed_casks: []const []const u8,
) CleanupError!Plan {
    var formulas: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedNames(allocator, &formulas);
    var casks: std.ArrayList([]const u8) = .empty;
    errdefer freeOwnedNames(allocator, &casks);

    for (installed_formulas) |name| {
        if (manifestHasFormula(manifest, name)) continue;
        const owned = allocator.dupe(u8, name) catch return CleanupError.OutOfMemory;
        formulas.append(allocator, owned) catch {
            allocator.free(owned);
            return CleanupError.OutOfMemory;
        };
    }
    for (installed_casks) |name| {
        if (manifestHasCask(manifest, name)) continue;
        const owned = allocator.dupe(u8, name) catch return CleanupError.OutOfMemory;
        casks.append(allocator, owned) catch {
            allocator.free(owned);
            return CleanupError.OutOfMemory;
        };
    }

    sortNames(formulas.items);
    sortNames(casks.items);

    const owned_formulas = formulas.toOwnedSlice(allocator) catch return CleanupError.OutOfMemory;
    errdefer allocator.free(owned_formulas);
    const owned_casks = casks.toOwnedSlice(allocator) catch return CleanupError.OutOfMemory;

    return .{
        .allocator = allocator,
        .formulas = owned_formulas,
        .casks = owned_casks,
    };
}

/// Reorder `plan.formulas` so that, for any in-plan A that depends on an
/// in-plan B, A appears before B. Casks have no dep graph and stay alphabetical.
/// Walks the `dependencies` table once; falls back to alphabetical for any
/// nodes left in a cycle.
pub fn orderForRemoval(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    plan: *Plan,
) CleanupError!void {
    if (plan.formulas.len < 2) return;

    const n = plan.formulas.len;
    const deps = allocator.alloc(std.ArrayList(u32), n) catch return CleanupError.OutOfMemory;
    defer {
        for (deps) |*l| l.deinit(allocator);
        allocator.free(deps);
    }
    for (deps) |*l| l.* = .empty;

    const dependents_count = allocator.alloc(u32, n) catch return CleanupError.OutOfMemory;
    defer allocator.free(dependents_count);
    @memset(dependents_count, 0);

    var stmt = db.prepare(
        \\SELECT k.name, d.dep_name FROM kegs k
        \\JOIN dependencies d ON d.keg_id = k.id;
    ) catch return CleanupError.DatabaseError;
    defer stmt.finalize();
    while (stmt.step() catch return CleanupError.DatabaseError) {
        const k_ptr = stmt.columnText(0) orelse continue;
        const d_ptr = stmt.columnText(1) orelse continue;
        const k_idx = indexOf(plan.formulas, std.mem.sliceTo(k_ptr, 0)) orelse continue;
        const d_idx = indexOf(plan.formulas, std.mem.sliceTo(d_ptr, 0)) orelse continue;
        deps[k_idx].append(allocator, d_idx) catch return CleanupError.OutOfMemory;
        dependents_count[d_idx] += 1;
    }

    var ordered = allocator.alloc([]const u8, n) catch return CleanupError.OutOfMemory;
    errdefer allocator.free(ordered);
    var write_idx: usize = 0;

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    for (dependents_count, 0..) |c, i| {
        if (c == 0) queue.append(allocator, @intCast(i)) catch return CleanupError.OutOfMemory;
    }

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const idx = queue.items[head];
        ordered[write_idx] = plan.formulas[idx];
        write_idx += 1;
        for (deps[idx].items) |dep_idx| {
            dependents_count[dep_idx] -= 1;
            if (dependents_count[dep_idx] == 0) {
                queue.append(allocator, dep_idx) catch return CleanupError.OutOfMemory;
            }
        }
    }

    // Cycle fallback: copy any unreached candidates in alphabetical order
    // (plan.formulas is already sorted) so the output stays deterministic.
    if (write_idx < n) {
        var placed = allocator.alloc(bool, n) catch return CleanupError.OutOfMemory;
        defer allocator.free(placed);
        @memset(placed, false);
        for (queue.items) |idx| placed[idx] = true;
        for (plan.formulas, 0..) |name, i| {
            if (placed[i]) continue;
            ordered[write_idx] = name;
            write_idx += 1;
        }
    }

    allocator.free(plan.formulas);
    plan.formulas = ordered;
}

fn indexOf(haystack: []const []const u8, needle: []const u8) ?u32 {
    for (haystack, 0..) |s, i| if (std.mem.eql(u8, s, needle)) return @intCast(i);
    return null;
}

/// Execute the cleanup plan. Dry-runs collect previews and never touch
/// the dispatcher; live runs route each candidate through it and collect
/// per-member failures so the CLI can render a single summary.
pub fn run(
    allocator: std.mem.Allocator,
    plan: Plan,
    opts: Options,
) CleanupError!Report {
    var failures: std.ArrayList(MemberError) = .empty;
    errdefer failures.deinit(allocator);
    var previews: std.ArrayList(MemberPreview) = .empty;
    errdefer previews.deinit(allocator);

    if (opts.dry_run) {
        for (plan.formulas) |n| previews.append(allocator, .{ .kind = .formula, .name = n }) catch
            return CleanupError.OutOfMemory;
        for (plan.casks) |n| previews.append(allocator, .{ .kind = .cask, .name = n }) catch
            return CleanupError.OutOfMemory;
    } else {
        const d = opts.dispatcher orelse return CleanupError.NoDispatcher;
        for (plan.formulas) |n| {
            d.uninstallFormula(d.ctx, allocator, n) catch |e| {
                failures.append(allocator, .{ .kind = .formula, .name = n, .err = e }) catch
                    return CleanupError.OutOfMemory;
            };
        }
        for (plan.casks) |n| {
            d.uninstallCask(d.ctx, allocator, n) catch |e| {
                failures.append(allocator, .{ .kind = .cask, .name = n, .err = e }) catch
                    return CleanupError.OutOfMemory;
            };
        }
    }

    const owned_failures = failures.toOwnedSlice(allocator) catch return CleanupError.OutOfMemory;
    errdefer allocator.free(owned_failures);
    const owned_previews = previews.toOwnedSlice(allocator) catch return CleanupError.OutOfMemory;

    return .{
        .allocator = allocator,
        .failures = owned_failures,
        .previews = owned_previews,
    };
}

fn manifestHasFormula(manifest: manifest_mod.Manifest, name: []const u8) bool {
    for (manifest.formulas) |f| if (std.mem.eql(u8, f.name, name)) return true;
    return false;
}

fn manifestHasCask(manifest: manifest_mod.Manifest, name: []const u8) bool {
    for (manifest.casks) |c| if (std.mem.eql(u8, c.name, name)) return true;
    return false;
}

fn sortNames(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

fn freeOwnedNames(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |n| allocator.free(n);
    list.deinit(allocator);
}

// -------- inline tests --------

const testing = std.testing;
const schema = @import("../../db/schema.zig");

fn testManifest(
    parent: std.mem.Allocator,
    formulas: []const []const u8,
    casks: []const []const u8,
) !manifest_mod.Manifest {
    var m = manifest_mod.Manifest.init(parent);
    errdefer m.deinit();
    const a = m.allocator();

    if (formulas.len > 0) {
        const dst = try a.alloc(manifest_mod.FormulaEntry, formulas.len);
        for (formulas, 0..) |name, i| dst[i] = .{ .name = try a.dupe(u8, name) };
        m.formulas = dst;
    }
    if (casks.len > 0) {
        const dst = try a.alloc(manifest_mod.CaskEntry, casks.len);
        for (casks, 0..) |name, i| dst[i] = .{ .name = try a.dupe(u8, name) };
        m.casks = dst;
    }
    return m;
}

test "diff returns formulas installed but missing from manifest" {
    var m = try testManifest(testing.allocator, &.{ "wget", "jq" }, &.{});
    defer m.deinit();

    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "wget", "ripgrep", "jq", "fzf" },
        &[_][]const u8{},
    );
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 2), plan.formulas.len);
    try testing.expectEqualStrings("fzf", plan.formulas[0]);
    try testing.expectEqualStrings("ripgrep", plan.formulas[1]);
    try testing.expectEqual(@as(usize, 0), plan.casks.len);
}

test "diff returns casks installed but missing from manifest" {
    var m = try testManifest(testing.allocator, &.{}, &.{"ghostty"});
    defer m.deinit();

    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{},
        &[_][]const u8{ "ghostty", "visual-studio-code", "iterm2" },
    );
    defer plan.deinit();

    try testing.expectEqual(@as(usize, 0), plan.formulas.len);
    try testing.expectEqual(@as(usize, 2), plan.casks.len);
    try testing.expectEqualStrings("iterm2", plan.casks[0]);
    try testing.expectEqualStrings("visual-studio-code", plan.casks[1]);
}

test "diff is empty when manifest covers every installed entry" {
    var m = try testManifest(testing.allocator, &.{ "wget", "jq" }, &.{"ghostty"});
    defer m.deinit();

    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "wget", "jq" },
        &[_][]const u8{"ghostty"},
    );
    defer plan.deinit();

    try testing.expect(plan.isEmpty());
}

test "diff entries are sorted alphabetically" {
    var m = try testManifest(testing.allocator, &.{}, &.{});
    defer m.deinit();

    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "zsh", "abc", "midline" },
        &[_][]const u8{},
    );
    defer plan.deinit();

    try testing.expectEqualStrings("abc", plan.formulas[0]);
    try testing.expectEqualStrings("midline", plan.formulas[1]);
    try testing.expectEqualStrings("zsh", plan.formulas[2]);
}

const TestDispatcher = struct {
    allocator: std.mem.Allocator,
    formulas: std.ArrayList([]const u8),
    casks: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) TestDispatcher {
        return .{ .allocator = allocator, .formulas = .empty, .casks = .empty };
    }

    fn deinit(self: *TestDispatcher) void {
        self.formulas.deinit(self.allocator);
        self.casks.deinit(self.allocator);
    }

    fn unwrap(ctx: ?*anyopaque) *TestDispatcher {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn uninstallFormulaFn(ctx: ?*anyopaque, _: std.mem.Allocator, name: []const u8) anyerror!void {
        const self = unwrap(ctx);
        try self.formulas.append(self.allocator, name);
    }

    fn uninstallCaskFn(ctx: ?*anyopaque, _: std.mem.Allocator, name: []const u8) anyerror!void {
        const self = unwrap(ctx);
        try self.casks.append(self.allocator, name);
    }
};

test "run with dry_run does not invoke the dispatcher" {
    var fake = TestDispatcher.init(testing.allocator);
    defer fake.deinit();

    var m = try testManifest(testing.allocator, &.{}, &.{});
    defer m.deinit();
    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "wget", "jq" },
        &[_][]const u8{"ghostty"},
    );
    defer plan.deinit();

    const dispatcher = Dispatcher{
        .ctx = &fake,
        .uninstallFormula = TestDispatcher.uninstallFormulaFn,
        .uninstallCask = TestDispatcher.uninstallCaskFn,
    };

    var report = try run(testing.allocator, plan, .{ .dry_run = true, .dispatcher = &dispatcher });
    defer report.deinit();

    try testing.expectEqual(@as(usize, 0), fake.formulas.items.len);
    try testing.expectEqual(@as(usize, 0), fake.casks.items.len);
    try testing.expectEqual(@as(usize, 3), report.previews.len);
    try testing.expectEqual(@as(usize, 0), report.failures.len);
}

test "run executes uninstall via dispatcher in formula-then-cask order" {
    var fake = TestDispatcher.init(testing.allocator);
    defer fake.deinit();

    var m = try testManifest(testing.allocator, &.{}, &.{});
    defer m.deinit();
    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "jq", "wget" },
        &[_][]const u8{"ghostty"},
    );
    defer plan.deinit();

    const dispatcher = Dispatcher{
        .ctx = &fake,
        .uninstallFormula = TestDispatcher.uninstallFormulaFn,
        .uninstallCask = TestDispatcher.uninstallCaskFn,
    };

    var report = try run(testing.allocator, plan, .{ .dry_run = false, .dispatcher = &dispatcher });
    defer report.deinit();

    try testing.expectEqual(@as(usize, 2), fake.formulas.items.len);
    try testing.expectEqualStrings("jq", fake.formulas.items[0]);
    try testing.expectEqualStrings("wget", fake.formulas.items[1]);
    try testing.expectEqual(@as(usize, 1), fake.casks.items.len);
    try testing.expectEqualStrings("ghostty", fake.casks.items[0]);
    try testing.expectEqual(@as(usize, 0), report.failures.len);
}

test "run records per-member failures and keeps going" {
    var m = try testManifest(testing.allocator, &.{}, &.{});
    defer m.deinit();
    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "jq", "wget" },
        &[_][]const u8{"ghostty"},
    );
    defer plan.deinit();

    const Failer = struct {
        fn alwaysFails(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!void {
            return error.MemberFailed;
        }
    };
    const dispatcher = Dispatcher{
        .uninstallFormula = Failer.alwaysFails,
        .uninstallCask = Failer.alwaysFails,
    };

    var report = try run(testing.allocator, plan, .{ .dry_run = false, .dispatcher = &dispatcher });
    defer report.deinit();

    try testing.expectEqual(@as(usize, 3), report.failures.len);
    try testing.expectEqual(MemberKind.formula, report.failures[0].kind);
    try testing.expectEqualStrings("jq", report.failures[0].name);
    try testing.expectEqual(MemberKind.cask, report.failures[2].kind);
    try testing.expectEqualStrings("ghostty", report.failures[2].name);
}

test "orderForRemoval reorders formulas so dependents land before their deps" {
    const fs_compat = @import("../../fs/compat.zig");
    const dir = "/tmp/malt_bundle_cleanup_topo_inline";
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    var db_path_buf: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // Z depends on A; both are direct installs and both will land in the
    // cleanup plan when the manifest drops them. Alphabetical order would
    // try A first and fail (Z still depends on it). Topological order
    // must surface Z first.
    {
        var ins = try db.prepare(
            \\INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path, install_reason)
            \\VALUES (?, ?, '1.0', '', '', 'direct');
        );
        defer ins.finalize();
        for ([_][]const u8{ "A", "Z" }) |n| {
            try ins.reset();
            try ins.bindText(1, n);
            try ins.bindText(2, n);
            _ = try ins.step();
        }
    }
    {
        var dep = try db.prepare(
            \\INSERT INTO dependencies(keg_id, dep_name, dep_type)
            \\SELECT id, 'A', 'runtime' FROM kegs WHERE name = 'Z';
        );
        defer dep.finalize();
        _ = try dep.step();
    }

    var m = try testManifest(testing.allocator, &.{}, &.{});
    defer m.deinit();
    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "A", "Z" },
        &[_][]const u8{},
    );
    defer plan.deinit();

    // Pre-condition: diff produced alphabetical order.
    try testing.expectEqualStrings("A", plan.formulas[0]);
    try testing.expectEqualStrings("Z", plan.formulas[1]);

    try orderForRemoval(testing.allocator, &db, &plan);

    try testing.expectEqualStrings("Z", plan.formulas[0]);
    try testing.expectEqualStrings("A", plan.formulas[1]);
}

test "orderForRemoval falls back to alphabetical when the dep graph cycles" {
    const fs_compat = @import("../../fs/compat.zig");
    const dir = "/tmp/malt_bundle_cleanup_topo_cycle";
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    var db_path_buf: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // Pathological data: A <-> B. Real Homebrew rejects cycles, but the
    // helper must terminate and produce deterministic output anyway.
    {
        var ins = try db.prepare(
            \\INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path, install_reason)
            \\VALUES (?, ?, '1.0', '', '', 'direct');
        );
        defer ins.finalize();
        for ([_][]const u8{ "A", "B" }) |n| {
            try ins.reset();
            try ins.bindText(1, n);
            try ins.bindText(2, n);
            _ = try ins.step();
        }
    }
    {
        var dep = try db.prepare(
            \\INSERT INTO dependencies(keg_id, dep_name, dep_type)
            \\SELECT id, ?, 'runtime' FROM kegs WHERE name = ?;
        );
        defer dep.finalize();
        const edges = [_]struct { from: []const u8, to: []const u8 }{
            .{ .from = "A", .to = "B" },
            .{ .from = "B", .to = "A" },
        };
        for (edges) |e| {
            try dep.reset();
            try dep.bindText(1, e.to);
            try dep.bindText(2, e.from);
            _ = try dep.step();
        }
    }

    var m = try testManifest(testing.allocator, &.{}, &.{});
    defer m.deinit();
    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "A", "B" },
        &[_][]const u8{},
    );
    defer plan.deinit();

    try orderForRemoval(testing.allocator, &db, &plan);

    // Cycle fallback preserves the alphabetical input order.
    try testing.expectEqual(@as(usize, 2), plan.formulas.len);
    try testing.expectEqualStrings("A", plan.formulas[0]);
    try testing.expectEqualStrings("B", plan.formulas[1]);
}

test "orderForRemoval is a no-op when no in-plan deps exist" {
    const fs_compat = @import("../../fs/compat.zig");
    const dir = "/tmp/malt_bundle_cleanup_topo_noop";
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    var db_path_buf: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    var m = try testManifest(testing.allocator, &.{}, &.{});
    defer m.deinit();
    var plan = try diff(
        testing.allocator,
        m,
        &[_][]const u8{ "abc", "midline", "zsh" },
        &[_][]const u8{},
    );
    defer plan.deinit();

    try orderForRemoval(testing.allocator, &db, &plan);

    // Independent kegs stay in alphabetical order — Kahn's frontier
    // pops in plan-index order, which is alphabetical from `diff`.
    try testing.expectEqualStrings("abc", plan.formulas[0]);
    try testing.expectEqualStrings("midline", plan.formulas[1]);
    try testing.expectEqualStrings("zsh", plan.formulas[2]);
}

test "collectInstalled returns direct formulas and every cask, sorted" {
    const fs_compat = @import("../../fs/compat.zig");
    const dir = "/tmp/malt_bundle_cleanup_collect_inline";
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    defer fs_compat.deleteTreeAbsolute(dir) catch {};

    var db_path_buf: [256]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    {
        // Indirect kegs are out of scope: cleanup must never list them, since
        // they belong to `purge --unused-deps`.
        var stmt = try db.prepare(
            \\INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path, install_reason)
            \\VALUES (?, ?, '1.0', '', '', ?);
        );
        defer stmt.finalize();
        const rows = [_]struct { name: []const u8, reason: []const u8 }{
            .{ .name = "ripgrep", .reason = "direct" },
            .{ .name = "openssl@3", .reason = "dependency" },
            .{ .name = "wget", .reason = "direct" },
        };
        for (rows) |r| {
            try stmt.reset();
            try stmt.bindText(1, r.name);
            try stmt.bindText(2, r.name);
            try stmt.bindText(3, r.reason);
            _ = try stmt.step();
        }
    }
    {
        var stmt = try db.prepare(
            \\INSERT INTO casks(token, name, version, url) VALUES (?, ?, '1.0', '');
        );
        defer stmt.finalize();
        for ([_][]const u8{ "ghostty", "iterm2" }) |n| {
            try stmt.reset();
            try stmt.bindText(1, n);
            try stmt.bindText(2, n);
            _ = try stmt.step();
        }
    }

    var lists = try collectInstalled(testing.allocator, &db);
    defer lists.deinit();

    try testing.expectEqual(@as(usize, 2), lists.formulas.len);
    try testing.expectEqualStrings("ripgrep", lists.formulas[0]);
    try testing.expectEqualStrings("wget", lists.formulas[1]);
    try testing.expectEqual(@as(usize, 2), lists.casks.len);
    try testing.expectEqualStrings("ghostty", lists.casks[0]);
    try testing.expectEqualStrings("iterm2", lists.casks[1]);
}
