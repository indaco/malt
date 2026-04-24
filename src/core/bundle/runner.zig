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
//! core returns outcomes; UI renders at the boundary — `run()` produces a
//! `Report` that the caller (`cli/bundle.zig`) renders via `ui/output.*`.
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
const manifest_mod = @import("manifest.zig");

pub const RunnerError = error{
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
        RunnerError.DatabaseError => "database error during bundle install",
        RunnerError.LockFailed => "could not acquire bundle lock",
        RunnerError.IoFailed => "filesystem error during bundle install",
        RunnerError.OutOfMemory => "out of memory during bundle install",
        RunnerError.NoDispatcher => "bundle runner called without a dispatcher and without malt_bin",
    };
}

pub const MemberKind = enum { tap, formula, cask, service_start };

/// One member whose install call returned a non-null error. `name` is
/// borrowed from the caller's `Manifest`; the caller must keep the
/// manifest alive until `Report.deinit`.
pub const MemberError = struct {
    kind: MemberKind,
    name: []const u8,
    err: anyerror,
};

/// Entry in the dry-run preview list — what the CLI would render as
/// "would run: malt …" without actually forking.
pub const MemberPreview = struct {
    kind: MemberKind,
    name: []const u8,
};

/// Structured outcome of a `run()` call. The runner emits no UI; the
/// CLI renders this report via `ui/output.*`.
pub const Report = struct {
    allocator: std.mem.Allocator,
    failures: []MemberError,
    previews: []MemberPreview,
    /// When `recordBundle` failed (non-dry-run only), the `@errorName`
    /// of the cause. Borrowed from `@errorName`, so no free needed.
    db_record_error: ?[]const u8 = null,

    pub fn hasFailure(self: Report) bool {
        return self.failures.len > 0 or self.db_record_error != null;
    }

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.failures);
        self.allocator.free(self.previews);
        self.* = undefined;
    }
};

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
    /// runner records `NoDispatcher` as each member's failure.
    dispatcher: ?*const Dispatcher = null,
};

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    manifest: manifest_mod.Manifest,
    opts: Options,
) RunnerError!Report {
    const bundle_name = if (manifest.name.len > 0) manifest.name else "unnamed";

    // Bundles directory + advisory lock for idempotency.
    const prefix: []const u8 = opts.prefix orelse atomic.maltPrefix();
    const bundles_dir = std.fmt.allocPrint(allocator, "{s}/var/malt/bundles", .{prefix}) catch
        return RunnerError.OutOfMemory;
    defer allocator.free(bundles_dir);
    // bundles/ may already exist; the lock file create below surfaces real errors.
    fs_compat.cwd().makePath(bundles_dir) catch {};

    const lock_path = std.fmt.allocPrint(allocator, "{s}/{s}.lock", .{ bundles_dir, bundle_name }) catch
        return RunnerError.OutOfMemory;
    defer allocator.free(lock_path);

    var lock = if (!opts.dry_run)
        (lock_mod.LockFile.acquire(lock_path, 5_000) catch return RunnerError.LockFailed)
    else
        null;
    defer if (lock) |*l| l.release();

    var failures: std.ArrayList(MemberError) = .empty;
    errdefer failures.deinit(allocator);
    var previews: std.ArrayList(MemberPreview) = .empty;
    errdefer previews.deinit(allocator);

    // 1. taps
    for (manifest.taps) |t| {
        try recordMember(allocator, .{ .tap = t }, opts, &failures, &previews);
    }

    // 2. formulas
    for (manifest.formulas) |f| {
        try recordMember(allocator, .{ .formula = f.name }, opts, &failures, &previews);
    }

    // 3. casks
    for (manifest.casks) |c| {
        try recordMember(allocator, .{ .cask = c.name }, opts, &failures, &previews);
    }

    // 4. services start (auto_start only). Best-effort.
    for (manifest.services) |s| {
        if (!s.auto_start) continue;
        try recordMember(allocator, .{ .service_start = s.name }, opts, &failures, &previews);
    }

    var db_record_error: ?[]const u8 = null;
    // 5. Record bundle and members in DB (even on partial failure). Skipped
    //    in dry-run so the preview path stays read-only.
    if (!opts.dry_run) recordBundle(allocator, db, manifest) catch |e| {
        db_record_error = @errorName(e);
    };

    // Own each slice before composing the return so an OOM on the second
    // toOwnedSlice cannot orphan the first.
    const owned_failures = failures.toOwnedSlice(allocator) catch return RunnerError.OutOfMemory;
    errdefer allocator.free(owned_failures);
    const owned_previews = previews.toOwnedSlice(allocator) catch return RunnerError.OutOfMemory;

    return .{
        .allocator = allocator,
        .failures = owned_failures,
        .previews = owned_previews,
        .db_record_error = db_record_error,
    };
}

const MemberCall = union(enum) {
    tap: []const u8,
    formula: []const u8,
    cask: []const u8,
    service_start: []const u8,

    fn kind(self: MemberCall) MemberKind {
        return switch (self) {
            .tap => .tap,
            .formula => .formula,
            .cask => .cask,
            .service_start => .service_start,
        };
    }

    fn name(self: MemberCall) []const u8 {
        return switch (self) {
            .tap => |n| n,
            .formula => |n| n,
            .cask => |n| n,
            .service_start => |n| n,
        };
    }
};

fn recordMember(
    allocator: std.mem.Allocator,
    call: MemberCall,
    opts: Options,
    failures: *std.ArrayList(MemberError),
    previews: *std.ArrayList(MemberPreview),
) RunnerError!void {
    if (opts.dry_run) {
        previews.append(allocator, .{ .kind = call.kind(), .name = call.name() }) catch
            return RunnerError.OutOfMemory;
        return;
    }

    callMember(allocator, call, opts) catch |e| {
        failures.append(allocator, .{
            .kind = call.kind(),
            .name = call.name(),
            .err = e,
        }) catch return RunnerError.OutOfMemory;
    };
}

fn callMember(allocator: std.mem.Allocator, call: MemberCall, opts: Options) !void {
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
