//! malt — bundle runner
//!
//! Installs every member of a `Manifest` by invoking the already-installed
//! `malt` binary as a subprocess for each formula/cask. Tap adds are
//! synthesised as `malt tap <name>`. Delegating to the CLI gives us full
//! idempotency for free (`malt install` skips installed kegs) at the cost of
//! one extra fork per member — acceptable for the typical bundle size.

const std = @import("std");
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
};

pub fn describeError(err: RunnerError) []const u8 {
    return switch (err) {
        RunnerError.MemberFailed => "at least one bundle member failed to install",
        RunnerError.DatabaseError => "database error during bundle install",
        RunnerError.LockFailed => "could not acquire bundle lock",
        RunnerError.IoFailed => "filesystem error during bundle install",
        RunnerError.OutOfMemory => "out of memory during bundle install",
    };
}

pub const Options = struct {
    /// When true, report what would be installed without forking subprocesses.
    dry_run: bool = false,
    /// Override the binary used for member installs. When null, `malt` from
    /// $PATH is used.
    malt_bin: ?[]const u8 = null,
};

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    manifest: manifest_mod.Manifest,
    opts: Options,
) RunnerError!void {
    const bundle_name = if (manifest.name.len > 0) manifest.name else "unnamed";

    // Bundles directory + advisory lock for idempotency.
    const bundles_dir = std.fmt.allocPrint(allocator, "{s}/var/malt/bundles", .{atomic.maltPrefix()}) catch
        return RunnerError.OutOfMemory;
    defer allocator.free(bundles_dir);
    std.fs.cwd().makePath(bundles_dir) catch {};

    const lock_path = std.fmt.allocPrint(allocator, "{s}/{s}.lock", .{ bundles_dir, bundle_name }) catch
        return RunnerError.OutOfMemory;
    defer allocator.free(lock_path);

    var lock = if (!opts.dry_run)
        (lock_mod.LockFile.acquire(lock_path, 5_000) catch return RunnerError.LockFailed)
    else
        null;
    defer if (lock) |*l| l.release();

    const malt_bin = opts.malt_bin orelse "malt";

    var any_failed = false;

    // 1. taps
    for (manifest.taps) |t| {
        runMember(allocator, malt_bin, &.{ "tap", t }, opts.dry_run) catch {
            output.err("tap failed: {s}", .{t});
            any_failed = true;
        };
    }

    // 2. formulas
    for (manifest.formulas) |f| {
        runMember(allocator, malt_bin, &.{ "install", f.name }, opts.dry_run) catch {
            output.err("install failed: {s}", .{f.name});
            any_failed = true;
        };
    }

    // 3. casks
    for (manifest.casks) |c| {
        runMember(allocator, malt_bin, &.{ "install", "--cask", c.name }, opts.dry_run) catch {
            output.err("cask install failed: {s}", .{c.name});
            any_failed = true;
        };
    }

    // 4. services start (auto_start only). Best-effort.
    for (manifest.services) |s| {
        if (!s.auto_start) continue;
        runMember(allocator, malt_bin, &.{ "services", "start", s.name }, opts.dry_run) catch {
            output.warn("could not auto-start service: {s}", .{s.name});
        };
    }

    // 5. Record bundle and members in DB (even in dry-run skip).
    if (!opts.dry_run) recordBundle(allocator, db, manifest) catch |e| {
        output.err("could not record bundle in database: {s}", .{@errorName(e)});
    };

    if (any_failed) return RunnerError.MemberFailed;
}

fn runMember(
    allocator: std.mem.Allocator,
    malt_bin: []const u8,
    args: []const []const u8,
    dry_run: bool,
) !void {
    if (dry_run) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, malt_bin);
        for (args) |a| {
            try line.append(allocator, ' ');
            try line.appendSlice(allocator, a);
        }
        output.info("would run: {s}", .{line.items});
        return;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, malt_bin);
    for (args) |a| try argv.append(allocator, a);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.MemberFailed,
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
    try ins.bindInt(2, std.time.timestamp());
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
