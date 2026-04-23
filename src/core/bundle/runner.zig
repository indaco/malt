//! malt — bundle runner
//!
//! Installs every member of a `Manifest` by routing each item through a
//! caller-supplied `Dispatcher` (in-process) or a fallback `malt` subprocess
//! (when `Options.malt_bin` is set — tests use that to assert exit-code
//! propagation via `/usr/bin/false`). In-process is the production default:
//! it keeps SQLite warm and avoids per-fork output noise. The runner itself
//! depends on no `cli/*` module, so bundle tests link without dragging in
//! the whole CLI surface.
//!
//! Each underlying primitive (install, tap, services start) is already
//! idempotent, so running a bundle twice is a no-op for already-installed
//! members.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");
const builtin = @import("builtin");
const sqlite = @import("../../db/sqlite.zig");
const schema = @import("../../db/schema.zig");
const lock_mod = @import("../../db/lock.zig");
const atomic = @import("../../fs/atomic.zig");
const output = @import("../../ui/output.zig");
const manifest_mod = @import("manifest.zig");

pub const RunnerError = error{
    MemberFailed,
    DatabaseError,
    LockFailed,
    IoFailed,
    OutOfMemory,
    /// Production builds need a `Dispatcher` wired from the CLI layer;
    /// absence means the caller forgot to provide one and we refuse to
    /// silently do nothing.
    NoDispatcher,
};

pub fn describeError(err: RunnerError) []const u8 {
    return switch (err) {
        RunnerError.MemberFailed => "at least one bundle member failed to install",
        RunnerError.DatabaseError => "database error during bundle install",
        RunnerError.LockFailed => "could not acquire bundle lock",
        RunnerError.IoFailed => "filesystem error during bundle install",
        RunnerError.OutOfMemory => "out of memory during bundle install",
        RunnerError.NoDispatcher => "bundle runner called without a dispatcher and without malt_bin",
    };
}

/// Layering seam: the CLI wires up a concrete implementation that forwards
/// to `cli/install`, `cli/tap`, `cli/services`. Keeping this as an injected
/// interface is what lets `core/bundle/runner.zig` avoid a `cli/*` import.
pub const Dispatcher = struct {
    ctx: ?*anyopaque = null,
    installFormula: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void,
    installCask: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void,
    tapAdd: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void,
    serviceStart: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void,
};

pub const Options = struct {
    /// When true, report what would be installed without forking subprocesses.
    dry_run: bool = false,
    /// Override the binary used for member installs. When set, each member
    /// is run via subprocess — test suites use this to substitute
    /// `/usr/bin/false` and assert exit-code propagation. Production
    /// callers leave it null and provide a `dispatcher` instead.
    malt_bin: ?[]const u8 = null,
    /// Override the install prefix used for the bundle lockfile. Tests use
    /// this to keep the lock under their per-test temp directory; production
    /// callers leave it null (which falls back to `MALT_PREFIX`).
    prefix: ?[]const u8 = null,
    /// In-process dispatcher injected from the CLI layer. Null is legal
    /// for `dry_run` and subprocess (`malt_bin`) paths; otherwise the
    /// runner returns `RunnerError.NoDispatcher`.
    dispatcher: ?*const Dispatcher = null,
};

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    manifest: manifest_mod.Manifest,
    opts: Options,
) RunnerError!void {
    const bundle_name = if (manifest.name.len > 0) manifest.name else "unnamed";

    // Bundles directory + advisory lock for idempotency.
    const prefix: []const u8 = opts.prefix orelse atomic.maltPrefix();
    const bundles_dir = std.fmt.allocPrint(allocator, "{s}/var/malt/bundles", .{prefix}) catch
        return RunnerError.OutOfMemory;
    defer allocator.free(bundles_dir);
    fs_compat.cwd().makePath(bundles_dir) catch {};

    const lock_path = std.fmt.allocPrint(allocator, "{s}/{s}.lock", .{ bundles_dir, bundle_name }) catch
        return RunnerError.OutOfMemory;
    defer allocator.free(lock_path);

    var lock = if (!opts.dry_run)
        (lock_mod.LockFile.acquire(lock_path, 5_000) catch return RunnerError.LockFailed)
    else
        null;
    defer if (lock) |*l| l.release();

    var any_failed = false;

    // 1. taps
    for (manifest.taps) |t| {
        callMember(allocator, .{ .tap = t }, opts) catch {
            output.err("tap failed: {s}", .{t});
            any_failed = true;
        };
    }

    // 2. formulas
    for (manifest.formulas) |f| {
        callMember(allocator, .{ .formula = f.name }, opts) catch {
            output.err("install failed: {s}", .{f.name});
            any_failed = true;
        };
    }

    // 3. casks
    for (manifest.casks) |c| {
        callMember(allocator, .{ .cask = c.name }, opts) catch {
            output.err("cask install failed: {s}", .{c.name});
            any_failed = true;
        };
    }

    // 4. services start (auto_start only). Best-effort.
    for (manifest.services) |s| {
        if (!s.auto_start) continue;
        callMember(allocator, .{ .service_start = s.name }, opts) catch {
            output.warn("could not auto-start service: {s}", .{s.name});
        };
    }

    // 5. Record bundle and members in DB (even in dry-run skip).
    if (!opts.dry_run) recordBundle(allocator, db, manifest) catch |e| {
        output.err("could not record bundle in database: {s}", .{@errorName(e)});
    };

    if (any_failed) return RunnerError.MemberFailed;
}

const MemberCall = union(enum) {
    tap: []const u8,
    formula: []const u8,
    cask: []const u8,
    service_start: []const u8,
};

fn callMember(allocator: std.mem.Allocator, call: MemberCall, opts: Options) !void {
    if (opts.dry_run) {
        switch (call) {
            .tap => |n| output.info("would run: malt tap {s}", .{n}),
            .formula => |n| output.info("would run: malt install {s}", .{n}),
            .cask => |n| output.info("would run: malt install --cask {s}", .{n}),
            .service_start => |n| output.info("would run: malt services start {s}", .{n}),
        }
        return;
    }

    // Test escape hatch: when malt_bin is set, fall back to subprocess so
    // tests can substitute /usr/bin/false to assert exit-code propagation.
    if (opts.malt_bin) |bin| return runSubprocess(allocator, bin, call);

    const d = opts.dispatcher orelse return RunnerError.NoDispatcher;
    switch (call) {
        .tap => |n| try d.tapAdd(d.ctx, allocator, n),
        .formula => |n| try d.installFormula(d.ctx, allocator, n),
        .cask => |n| try d.installCask(d.ctx, allocator, n),
        .service_start => |n| try d.serviceStart(d.ctx, allocator, n),
    }
}

fn runSubprocess(allocator: std.mem.Allocator, bin: []const u8, call: MemberCall) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin);
    switch (call) {
        .tap => |n| {
            try argv.append(allocator, "tap");
            try argv.append(allocator, n);
        },
        .formula => |n| {
            try argv.append(allocator, "install");
            try argv.append(allocator, n);
        },
        .cask => |n| {
            try argv.append(allocator, "install");
            try argv.append(allocator, "--cask");
            try argv.append(allocator, n);
        },
        .service_start => |n| {
            try argv.append(allocator, "services");
            try argv.append(allocator, "start");
            try argv.append(allocator, n);
        },
    }

    var child = fs_compat.Child.init(argv.items, allocator);
    child.stdout_behavior = .inherit;
    child.stderr_behavior = .inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .exited => |code| if (code != 0) return error.MemberFailed,
        else => return error.MemberFailed,
    }
}

fn recordBundle(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    manifest: manifest_mod.Manifest,
) !void {
    _ = allocator;
    try schema.migrate(db);

    try db.beginTransaction();
    errdefer db.rollback();

    const name = if (manifest.name.len > 0) manifest.name else "unnamed";
    var ins = try db.prepare(
        \\INSERT OR REPLACE INTO bundles(name, manifest_path, created_at, version)
        \\VALUES (?, NULL, ?, ?);
    );
    defer ins.finalize();
    try ins.bindText(1, name);
    try ins.bindInt(2, fs_compat.timestamp());
    try ins.bindInt(3, @intCast(manifest.version));
    _ = try ins.step();

    // Clean previous members of this bundle to keep it idempotent.
    var del = try db.prepare("DELETE FROM bundle_members WHERE bundle_name = ?;");
    defer del.finalize();
    try del.bindText(1, name);
    _ = try del.step();

    var memb = try db.prepare(
        \\INSERT INTO bundle_members(bundle_name, kind, ref, spec)
        \\VALUES (?, ?, ?, NULL);
    );
    defer memb.finalize();

    for (manifest.taps) |t| {
        try memb.reset();
        try memb.bindText(1, name);
        try memb.bindText(2, "tap");
        try memb.bindText(3, t);
        _ = try memb.step();
    }
    for (manifest.formulas) |f| {
        try memb.reset();
        try memb.bindText(1, name);
        try memb.bindText(2, "formula");
        try memb.bindText(3, f.name);
        _ = try memb.step();
    }
    for (manifest.casks) |c| {
        try memb.reset();
        try memb.bindText(1, name);
        try memb.bindText(2, "cask");
        try memb.bindText(3, c.name);
        _ = try memb.step();
    }
    for (manifest.services) |s| {
        try memb.reset();
        try memb.bindText(1, name);
        try memb.bindText(2, "service");
        try memb.bindText(3, s.name);
        _ = try memb.step();
    }

    try db.commit();
}
