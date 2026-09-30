//! malt — bundle command

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const brewfile_mod = @import("../core/bundle/brewfile.zig");
const brewfile_emit = @import("../core/bundle/brewfile_emit.zig");
const cleanup_mod = @import("../core/bundle/cleanup.zig");
const help_mod = @import("help.zig");
const manifest_mod = @import("../core/bundle/manifest.zig");
const runner_mod = @import("../core/bundle/runner.zig");
const schema = @import("../db/schema.zig");
const schema_report = @import("schema_report.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const path_write = @import("../fs/path_write.zig");
const output = @import("../ui/output.zig");
const signals = @import("../core/signals.zig");
const install_args = @import("install/args.zig");
const install_sink_mod = @import("install/sink.zig");
const install_cmd = @import("install.zig");
const services_cmd = @import("services.zig");
const tap_cmd = @import("tap.zig");
const uninstall_cmd = @import("uninstall.zig");

// Default in-process dispatcher: the CLI layer supplies this so the
// runner can stay ignorant of cli/* while still calling into the real
// install/tap/services primitives. The opaque `ctx` slot carries the
// process-wide AppCtx so the dispatch helpers can thread io / environ
// through to install/tap/services without re-deriving them.
//
// The error value carries no cause, so the wrapper narrows everything
// except OOM to DispatchFailed and keeps the dispatcher type closed. Install
// members carry the cause on `MemberError.reason`; tap, services and
// uninstall print their own through the global output.
fn narrowDispatch(e: anyerror) runner_mod.DispatchError {
    return switch (e) {
        error.OutOfMemory => runner_mod.DispatchError.OutOfMemory,
        else => runner_mod.DispatchError.DispatchFailed,
    };
}

/// Per-`bundle install` invocation context. Carries the user's
/// `--isolate-deps` intent so the runner's per-member install calls
/// honour the same flag without it having to thread through the
/// dispatcher's fn-pointer ABI.
const BundleInstallCtx = struct {
    app: *const AppCtx,
    isolate_deps: bool,
};

fn bundleInstallCtxFromOpaque(ctx: ?*anyopaque) *const BundleInstallCtx {
    const non_null = ctx orelse @panic("bundle: install dispatcher invoked without BundleInstallCtx");
    return @ptrCast(@alignCast(non_null));
}

fn captureErr(ctx: ?*anyopaque, msg: []const u8) void {
    const reason: *runner_mod.MemberReason = @ptrCast(@alignCast(ctx.?));
    reason.record(msg);
}

/// The bundle `Report` is the per-member channel, so the install pipeline's
/// per-keg lines would only be noise over it; its first error line (or the
/// detail under an error header) is kept as the member's failure reason.
pub fn captureSink(reason: *runner_mod.MemberReason) install_sink_mod.OutputSink {
    var s = install_sink_mod.silent;
    s.ctx = reason;
    s.writeErr = captureErr;
    return s;
}

fn cliInstallFormula(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, reason: *runner_mod.MemberReason) runner_mod.DispatchError!void {
    const bd = bundleInstallCtxFromOpaque(ctx);
    install_cmd.installAll(bd.app, allocator, &.{name}, .{ .isolate_deps = bd.isolate_deps, .sink = captureSink(reason) }) catch |e| return narrowDispatch(e);
}

fn cliInstallCask(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, reason: *runner_mod.MemberReason) runner_mod.DispatchError!void {
    const bd = bundleInstallCtxFromOpaque(ctx);
    install_cmd.installAll(bd.app, allocator, &.{name}, .{ .cask = true, .isolate_deps = bd.isolate_deps, .sink = captureSink(reason) }) catch |e| return narrowDispatch(e);
}

// Tap and services primitives print their cause through the global output.
fn cliTapAdd(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, _: *runner_mod.MemberReason) runner_mod.DispatchError!void {
    const bd = bundleInstallCtxFromOpaque(ctx);
    tap_cmd.tapAdd(bd.app, allocator, name) catch |e| return narrowDispatch(e);
}

fn cliServiceStart(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, _: *runner_mod.MemberReason) runner_mod.DispatchError!void {
    const bd = bundleInstallCtxFromOpaque(ctx);
    services_cmd.servicesStart(bd.app, allocator, name) catch |e| return narrowDispatch(e);
}

fn cliUninstallFormula(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) cleanup_mod.DispatchError!void {
    const app_ctx = appCtxFromOpaque(ctx);
    // Explicit so a cleanup never depends on which kind a bare name resolves to.
    uninstall_cmd.execute(app_ctx, allocator, &.{ "--formula", name }) catch |e| return narrowDispatch(e);
}

fn cliUninstallCask(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) cleanup_mod.DispatchError!void {
    const app_ctx = appCtxFromOpaque(ctx);
    uninstall_cmd.execute(app_ctx, allocator, &.{ "--cask", name }) catch |e| return narrowDispatch(e);
}

/// Cast the dispatcher's opaque `ctx` slot back to a borrowed AppCtx pointer.
/// The slot is `?*anyopaque` for ABI symmetry with the runner's Dispatcher;
/// every cli call path sets it via `runDispatcher` / `cleanupDispatcher`,
/// so a null here is a wiring bug — name it instead of UB-panicking.
fn appCtxFromOpaque(ctx: ?*anyopaque) *const AppCtx {
    const non_null = ctx orelse @panic("bundle: dispatcher invoked without AppCtx — wire via runDispatcher/cleanupDispatcher");
    return @ptrCast(@alignCast(non_null));
}

fn runDispatcher(bd: *const BundleInstallCtx) runner_mod.Dispatcher {
    return .{
        .ctx = @ptrCast(@constCast(bd)),
        .installFormula = cliInstallFormula,
        .installCask = cliInstallCask,
        .tapAdd = cliTapAdd,
        .serviceStart = cliServiceStart,
    };
}

fn cleanupDispatcher(ctx: *const AppCtx) cleanup_mod.Dispatcher {
    return .{
        .ctx = @ptrCast(@constCast(ctx)),
        .uninstallFormula = cliUninstallFormula,
        .uninstallCask = cliUninstallCask,
    };
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        printHelp(ctx);
        return;
    }
    if (help_mod.showIfRequested(ctx, args[0..1], "bundle")) return;

    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "install")) return cmdInstall(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "cleanup")) return cmdCleanup(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "create")) return cmdCreate(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "list")) return cmdList(ctx);
    if (std.mem.eql(u8, sub, "remove")) return cmdRemove(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "export")) return cmdExport(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "import")) return cmdImport(ctx, allocator, rest);

    output.err("Unknown bundle subcommand: {s}", .{sub});
    return error.Aborted;
}

fn cmdInstall(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    // main.zig strips the global `--dry-run` from argv; reading the
    // module-global here keeps bundle install aligned with every other
    // subcommand (install, upgrade, purge, …) and with its envelope.
    const dry_run = output.isDryRun();
    var explicit_path: ?[]const u8 = null;
    var isolate_deps = false;
    for (rest) |a| {
        if (std.mem.eql(u8, a, "--isolate-deps") or std.mem.eql(u8, a, "--isolate-dependencies")) {
            isolate_deps = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            output.warn("ignored flag: {s}", .{a});
        } else {
            explicit_path = a;
        }
    }

    const path = try resolveBundlefile(ctx, allocator, explicit_path);
    defer allocator.free(path);
    output.info("using bundle file: {s}", .{path});

    var diag = brewfile_mod.Diagnostics.init(allocator);
    defer diag.deinit();
    var manifest = try readManifest(ctx, allocator, path, &diag);
    defer manifest.deinit();
    for (diag.warnings.items) |w| output.warn("{s}", .{w});

    var db = try openDb(ctx);
    defer db.close();

    const bd = BundleInstallCtx{ .app = ctx, .isolate_deps = isolate_deps };
    const dispatcher = runDispatcher(&bd);
    var report = runner_mod.run(ctx.io, allocator, &db, manifest, .{
        .dry_run = dry_run,
        .dispatcher = &dispatcher,
    }) catch |e| {
        output.err("bundle install failed: {s}", .{runner_mod.describeError(e)});
        return error.Aborted;
    };
    defer report.deinit();

    for (report.previews) |p| switch (p.kind) {
        .tap => output.info("would run: malt tap {s}", .{p.name}),
        .formula => output.info("would run: malt install {s}", .{p.name}),
        .cask => output.info("would run: malt install --cask {s}", .{p.name}),
        .service_start => output.info("would run: malt services start {s}", .{p.name}),
    };
    var any_hard = renderFailures(report.failures);
    if (report.db_record_error) |name| {
        output.err("could not record bundle in database: {s}", .{name});
        any_hard = true;
    }

    // A short report after Ctrl-C is not a completed bundle.
    if (signals.isInterrupted()) {
        output.warn("Interrupted — remaining bundle members were not installed.", .{});
        return error.UserInterrupted;
    }
    if (any_hard) return error.Aborted;
    output.success("bundle install complete", .{});
}

/// Renders one line per failed member; true when any failure is hard.
fn renderFailures(failures: []const runner_mod.MemberError) bool {
    var any_hard = false;
    for (failures) |*f| {
        const label = switch (f.kind) {
            .tap => "tap failed",
            .formula => "install failed",
            .cask => "cask install failed",
            // Service auto-start is best-effort; warn but don't fail the bundle.
            .service_start => {
                output.warn("could not auto-start service: {s}", .{f.name});
                continue;
            },
        };
        const why = f.reason.slice();
        if (why.len > 0)
            output.err("{s}: {s}: {s}", .{ label, f.name, why })
        else
            output.err("{s}: {s}", .{ label, f.name });
        any_hard = true;
    }
    return any_hard;
}

fn cmdCleanup(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    // main.zig strips the global `--dry-run` from argv; reading the
    // module-global keeps cleanup aligned with `bundle install`.
    var dry_run = output.isDryRun();
    var yes = false;
    var explicit_path: ?[]const u8 = null;
    for (rest) |a| {
        if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) {
            yes = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            output.warn("ignored flag: {s}", .{a});
        } else {
            explicit_path = a;
        }
    }

    const path = try resolveBundlefile(ctx, allocator, explicit_path);
    defer allocator.free(path);
    output.info("using bundle file: {s}", .{path});

    var diag = brewfile_mod.Diagnostics.init(allocator);
    defer diag.deinit();
    var manifest = try readManifest(ctx, allocator, path, &diag);
    defer manifest.deinit();
    for (diag.warnings.items) |w| output.warn("{s}", .{w});

    // Tight DB scope: the connection's only job is the read-then-plan
    // phase, so the per-member uninstalls below run against a freshly
    // opened handle each.
    var plan: cleanup_mod.Plan = blk: {
        var db = try openDb(ctx);
        defer db.close();
        var installed = cleanup_mod.collectInstalled(allocator, &db) catch
            return unreadableDb(&db);
        defer installed.deinit();
        var p = cleanup_mod.diff(
            allocator,
            manifest,
            installed.formulas,
            installed.casks,
        ) catch |e| return planFailed(e);
        errdefer p.deinit();
        const spared = cleanup_mod.dropKeptDependencies(allocator, &db, &p) catch
            return unreadableDb(&db);
        defer cleanup_mod.freeNames(p.allocator, spared);
        for (spared) |n| output.info("keeping {s}: an installed package depends on it", .{n});
        cleanup_mod.orderForRemoval(allocator, &db, &p) catch
            return unreadableDb(&db);
        break :blk p;
    };
    defer plan.deinit();

    if (plan.isEmpty()) {
        output.success("nothing to clean up", .{});
        return;
    }

    output.info("cleanup plan:", .{});
    for (plan.formulas) |n| output.plain("  - {s}", .{n});
    for (plan.casks) |n| output.plain("  - {s} (cask)", .{n});

    if (dry_run) {
        output.info("dry-run: skipping uninstall", .{});
        return;
    }

    if (!yes and !output.confirmTyped("yes", "Type 'yes' to remove these packages: ")) {
        output.warn("aborted", .{});
        return;
    }

    const dispatcher = cleanupDispatcher(ctx);
    var report = cleanup_mod.run(allocator, plan, .{
        .dry_run = false,
        .dispatcher = &dispatcher,
    }) catch |e| {
        output.err("bundle cleanup failed: {s}", .{@errorName(e)});
        return error.Aborted;
    };
    defer report.deinit();

    // The uninstall pipeline already prints rich per-member diagnostics;
    // surface only the count here so users see a single summary line.
    if (signals.isInterrupted()) {
        output.warn("Interrupted — remaining bundle members were not removed.", .{});
        return error.UserInterrupted;
    }
    if (report.hasFailure()) {
        output.err("bundle cleanup completed with {d} failure(s)", .{report.failures.len});
        return error.Aborted;
    }
    output.success("bundle cleanup complete", .{});
}

fn cmdList(ctx: *const AppCtx) !void {
    var db = try openDb(ctx);
    defer db.close();

    var stmt = db.prepare("SELECT name, created_at FROM bundles ORDER BY name;") catch
        return unreadableDb(&db);
    defer stmt.finalize();

    var any = false;
    while (stmt.step() catch return unreadableDb(&db)) {
        const n = stmt.columnText(0) orelse continue;
        const ts = stmt.columnInt(1);
        output.plain("{s}\t{d}", .{ std.mem.sliceTo(n, 0), ts });
        any = true;
    }
    if (!any) output.info("no bundles registered", .{});
}

const RemoveArgs = struct { name: []const u8, purge: bool, yes: bool, dry_run: bool };

/// Parse `bundle remove` args. Null signals a missing or duplicated <name>,
/// which the caller reports as InvalidArgs. `--dry-run` seeds from the global
/// so `malt --dry-run bundle remove --purge` previews, matching cleanup.
fn resolveRemoveArgs(rest: []const []const u8, global_dry_run: bool) ?RemoveArgs {
    var name: ?[]const u8 = null;
    var purge = false;
    var yes = false;
    var dry_run = global_dry_run;
    for (rest) |a| {
        if (std.mem.eql(u8, a, "--purge")) {
            purge = true;
        } else if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) {
            yes = true;
        } else if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            output.warn("ignored flag: {s}", .{a});
        } else {
            if (name != null) return null;
            name = a;
        }
    }
    return .{
        .name = name orelse return null,
        .purge = purge,
        .yes = yes,
        .dry_run = dry_run,
    };
}

fn cmdRemove(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    const args = resolveRemoveArgs(rest, output.isDryRun()) orelse {
        output.err("bundle remove: expected <name>", .{});
        return error.Aborted;
    };

    if (args.purge) try purgeMembers(ctx, allocator, args);

    // Unregister last: on a failed purge we return above, leaving the row in
    // place so the command stays retryable rather than orphaning the members.
    if (args.dry_run) {
        output.info("dry-run: keeping bundle registration for {s}", .{args.name});
        return;
    }
    var db = try openDb(ctx);
    defer db.close();

    var stmt = db.prepare("DELETE FROM bundles WHERE name = ?;") catch
        return unwritableDb(&db);
    defer stmt.finalize();
    stmt.bindText(1, args.name) catch return unwritableDb(&db);
    _ = stmt.step() catch return unwritableDb(&db);
    output.success("bundle removed: {s}", .{args.name});
}

/// Uninstall the members of a registered bundle. The `bundles` row stores a
/// manifest path, not a member list, so the file has to be re-read; a missing
/// or unparsable manifest is a hard error rather than a silent unregister,
/// since the caller asked to remove packages and we cannot know which.
fn purgeMembers(ctx: *const AppCtx, allocator: std.mem.Allocator, args: RemoveArgs) !void {
    const path = try lookupManifestPath(ctx, allocator, args.name);
    defer allocator.free(path);
    output.info("using bundle file: {s}", .{path});

    var diag = brewfile_mod.Diagnostics.init(allocator);
    defer diag.deinit();
    var manifest = try readManifest(ctx, allocator, path, &diag);
    defer manifest.deinit();
    for (diag.warnings.items) |w| output.warn("{s}", .{w});

    var plan: cleanup_mod.Plan = blk: {
        var db = try openDb(ctx);
        defer db.close();
        var installed = cleanup_mod.collectInstalled(allocator, &db) catch
            return unreadableDb(&db);
        defer installed.deinit();
        var p = cleanup_mod.selectMembers(
            allocator,
            manifest,
            installed.formulas,
            installed.casks,
        ) catch |e| return planFailed(e);
        errdefer p.deinit();
        cleanup_mod.orderForRemoval(allocator, &db, &p) catch
            return unreadableDb(&db);
        break :blk p;
    };
    defer plan.deinit();

    if (plan.isEmpty()) {
        output.info("no installed members to purge", .{});
        return;
    }

    output.info("purge plan:", .{});
    for (plan.formulas) |n| output.plain("  - {s}", .{n});
    for (plan.casks) |n| output.plain("  - {s} (cask)", .{n});

    if (args.dry_run) {
        output.info("dry-run: skipping uninstall", .{});
        return;
    }

    if (!args.yes and !output.confirmTyped("yes", "Type 'yes' to remove these packages: ")) {
        output.warn("aborted", .{});
        return error.Aborted;
    }

    const dispatcher = cleanupDispatcher(ctx);
    var report = cleanup_mod.run(allocator, plan, .{
        .dry_run = false,
        .dispatcher = &dispatcher,
    }) catch |e| {
        output.err("bundle purge failed: {s}", .{@errorName(e)});
        return error.Aborted;
    };
    defer report.deinit();

    if (report.hasFailure()) {
        output.err("bundle purge completed with {d} failure(s)", .{report.failures.len});
        return error.Aborted;
    }
}

/// Resolve a registered bundle name to its manifest path. Caller owns the
/// returned slice.
fn lookupManifestPath(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
) ![]const u8 {
    var db = try openDb(ctx);
    defer db.close();

    var stmt = db.prepare("SELECT manifest_path FROM bundles WHERE name = ?;") catch
        return unreadableDb(&db);
    defer stmt.finalize();
    stmt.bindText(1, name) catch return unreadableDb(&db);

    if (!(stmt.step() catch return unreadableDb(&db))) {
        output.err("bundle not registered: {s}", .{name});
        return error.Aborted;
    }
    const raw = std.mem.sliceTo(stmt.columnText(0) orelse {
        output.err("bundle {s} has no recorded manifest path", .{name});
        return error.Aborted;
    }, 0);
    // Rows written before import canonicalised the path: resolving them
    // against this process's cwd could purge from an unrelated file.
    if (!std.fs.path.isAbsolute(raw)) {
        output.err("bundle {s} was registered with a relative manifest path ({s}); re-import it", .{ name, raw });
        return error.Aborted;
    }
    return allocator.dupe(u8, raw);
}

const CreateArgs = struct { format: Format, out_path: []const u8, include_services: bool };

/// Parse `bundle create` args. The default filename is resolved once after the
/// loop so an explicit positional path wins no matter where `--format` sits.
/// Null signals an invalid format value.
fn resolveCreateArgs(rest: []const []const u8) error{Aborted}!CreateArgs {
    var format: Format = .brewfile;
    var out_path: ?[]const u8 = null;
    var include_services = false;
    var opts_done = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts_done or !std.mem.startsWith(u8, a, "-")) {
            out_path = a;
        } else if (std.mem.eql(u8, a, "--")) {
            opts_done = true;
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            format = parseFormat(if (i < rest.len) rest[i] else "") orelse return badFormat();
        } else if (std.mem.eql(u8, a, "--services")) {
            include_services = true;
        } else return unknownFlag(a);
    }
    return .{
        .format = format,
        .out_path = out_path orelse switch (format) {
            .brewfile => "Brewfile",
            .json => "Maltfile.json",
        },
        .include_services = include_services,
    };
}

fn cmdCreate(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    const args = try resolveCreateArgs(rest);

    var db = try openDb(ctx);
    defer db.close();

    var manifest = manifest_mod.Manifest.init(allocator);
    defer manifest.deinit();
    try populateFromInstalled(&manifest, &db, .{ .include_services = args.include_services });
    try writeManifest(ctx, manifest, args.out_path, args.format);
    output.success("wrote {s}", .{args.out_path});
}

fn cmdExport(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    var format: Format = .brewfile;
    var bundle_name: ?[]const u8 = null;
    var include_services = false;
    var opts_done = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts_done or !std.mem.startsWith(u8, a, "-")) {
            if (bundle_name != null) {
                output.err("bundle export: expected at most one <name>", .{});
                return error.Aborted;
            }
            bundle_name = a;
        } else if (std.mem.eql(u8, a, "--")) {
            opts_done = true;
        } else if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            format = parseFormat(if (i < rest.len) rest[i] else "") orelse return badFormat();
        } else if (std.mem.eql(u8, a, "--services")) {
            include_services = true;
        } else return unknownFlag(a);
    }

    var db = try openDb(ctx);
    defer db.close();

    var manifest = manifest_mod.Manifest.init(allocator);
    defer manifest.deinit();
    if (bundle_name) |n| {
        try populateFromBundle(&manifest, &db, n);
    } else {
        try populateFromInstalled(&manifest, &db, .{ .include_services = include_services });
    }

    var write_buf: [4096]u8 = undefined;
    var stdout_writer = ctx.stdout.writer(ctx.io, &write_buf);
    const w = &stdout_writer.interface;
    (switch (format) {
        .brewfile => brewfile_emit.emit(manifest, w),
        .json => manifest_mod.emitJson(manifest, w),
    }) catch |e| return unwritable("stdout", e);
    w.flush() catch |e| return unwritable("stdout", e);
}

fn cmdImport(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    if (rest.len != 1) {
        output.err("bundle import: expected <file>", .{});
        return error.Aborted;
    }
    const path = rest[0];
    var diag = brewfile_mod.Diagnostics.init(allocator);
    defer diag.deinit();
    var manifest = try readManifest(ctx, allocator, path, &diag);
    defer manifest.deinit();
    for (diag.warnings.items) |w| output.warn("{s}", .{w});

    // The row outlives this process, so a cwd-relative path would be
    // re-resolved against whatever cwd `remove --purge` later runs from.
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, path, allocator) catch |e|
        return unreadable(path, e);
    defer allocator.free(canonical);

    var db = try openDb(ctx);
    defer db.close();

    // Record metadata only; no install.
    var stmt = db.prepare(
        \\INSERT OR REPLACE INTO bundles(name, manifest_path, created_at, version)
        \\VALUES (?, ?, ?, ?);
    ) catch return unwritableDb(&db);
    defer stmt.finalize();
    const name = if (manifest.name.len > 0) manifest.name else path;
    stmt.bindText(1, name) catch return unwritableDb(&db);
    stmt.bindText(2, canonical) catch return unwritableDb(&db);
    stmt.bindInt(3, std.Io.Clock.real.now(ctx.io).toSeconds()) catch return unwritableDb(&db);
    stmt.bindInt(4, @intCast(manifest.version)) catch return unwritableDb(&db);
    _ = stmt.step() catch return unwritableDb(&db);
    output.success("bundle registered: {s}", .{name});
}

// ---------- helpers ----------

const Format = enum { brewfile, json };

fn parseFormat(s: []const u8) ?Format {
    if (std.mem.eql(u8, s, "brewfile")) return .brewfile;
    if (std.mem.eql(u8, s, "json")) return .json;
    return null;
}

fn resolveBundlefile(ctx: *const AppCtx, allocator: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |p| return allocator.dupe(u8, p);

    const candidates = [_][]const u8{
        "Brewfile",
        "Maltfile.json",
    };
    for (candidates) |c| {
        std.Io.Dir.cwd().access(ctx.io, c, .{}) catch continue;
        return allocator.dupe(u8, c);
    }

    // ~/.config/malt
    if (std.process.Environ.getPosix(ctx.environ, "HOME")) |home| {
        for ([_][]const u8{ "Brewfile", "Maltfile.json" }) |name| {
            const p = try std.fmt.allocPrint(allocator, "{s}/.config/malt/{s}", .{ home, name });
            std.Io.Dir.accessAbsolute(ctx.io, p, .{}) catch {
                allocator.free(p);
                continue;
            };
            return p;
        }
    }
    output.err("No Brewfile or Maltfile.json in the current directory or ~/.config/malt", .{});
    return error.Aborted;
}

fn readManifest(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    path: []const u8,
    diag: ?*brewfile_mod.Diagnostics,
) !manifest_mod.Manifest {
    // openFileAbsolute is just openFile on cwd (an absolute path ignores the
    // cwd handle), so one call covers both path kinds.
    const file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |e| return unreadable(path, e);
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch |e| return unreadable(path, e);
    if (stat.size > 8 * 1024 * 1024) {
        output.err("Bundle file {s} is larger than 8 MiB", .{path});
        return error.Aborted;
    }
    const body = allocator.alloc(u8, @intCast(stat.size)) catch |e| return unreadable(path, e);
    defer allocator.free(body);
    _ = file.readPositionalAll(ctx.io, body, 0) catch |e| return unreadable(path, e);

    if (std.mem.endsWith(u8, path, ".json")) {
        return manifest_mod.parseJson(allocator, body) catch |e| {
            output.err("Maltfile parse error: {s}", .{manifest_mod.describeError(e)});
            return error.Aborted;
        };
    }
    return brewfile_mod.parse(allocator, body, diag) catch |e| {
        // Name the cause, and the line when the parser recorded one.
        const reason = brewfile_mod.describeError(e);
        const line = if (diag) |d| d.error_line else null;
        if (line) |ln| {
            output.err("Brewfile parse error at line {d}: {s}", .{ ln, reason });
        } else output.err("Brewfile parse error: {s}", .{reason});
        return error.Aborted;
    };
}

fn unreadable(path: []const u8, e: anyerror) error{Aborted} {
    output.err("Cannot read bundle file {s}: {s}", .{ path, @errorName(e) });
    return error.Aborted;
}

fn unwritable(path: []const u8, e: anyerror) error{Aborted} {
    output.err("Cannot write {s}: {s}", .{ path, @errorName(e) });
    return error.Aborted;
}

fn unreadableDb(db: *sqlite.Database) error{Aborted} {
    output.err("Could not read the package database: {s}", .{db.errMsg()});
    return error.Aborted;
}

fn unwritableDb(db: *sqlite.Database) error{Aborted} {
    output.err("Could not update the package database: {s}", .{db.errMsg()});
    return error.Aborted;
}

fn planFailed(e: anyerror) error{Aborted} {
    output.err("Could not plan which packages to remove: {s}", .{@errorName(e)});
    return error.Aborted;
}

// create writes a file, so a flag it cannot honour must stop it.
fn unknownFlag(flag: []const u8) error{Aborted} {
    output.err("Unknown flag: {s}", .{flag});
    return error.Aborted;
}

fn badFormat() error{Aborted} {
    output.err("--format expects brewfile or json", .{});
    return error.Aborted;
}

fn writeManifest(
    ctx: *const AppCtx,
    manifest: manifest_mod.Manifest,
    path: []const u8,
    format: Format,
) !void {
    // Create parents for a nested out_path; streams into the file below, so
    // only the parent step is shared with backup/purge's path_write.writeFile.
    path_write.ensureParentDir(ctx.io, path) catch |e| return unwritable(path, e);
    const file = std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = true }) catch |e| return unwritable(path, e);
    defer file.close(ctx.io);
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(ctx.io, &write_buf);
    const w = &fw.interface;
    (switch (format) {
        .brewfile => brewfile_emit.emit(manifest, w),
        .json => manifest_mod.emitJson(manifest, w),
    }) catch |e| return unwritable(path, e);
    w.flush() catch |e| return unwritable(path, e);
}

/// Options for `populateFromInstalled`. Taps round-trip unconditionally
/// (Brewfile carries them and a missing tap silently breaks restore);
/// services opt in via `--services` because they encode runtime state.
const PopulateOpts = struct {
    include_services: bool = false,
};

fn populateFromInstalled(
    manifest: *manifest_mod.Manifest,
    db: *sqlite.Database,
    opts: PopulateOpts,
) !void {
    const a = manifest.allocator();
    var taps: std.ArrayList([]const u8) = .empty;
    var formulas: std.ArrayList(manifest_mod.FormulaEntry) = .empty;
    var casks: std.ArrayList(manifest_mod.CaskEntry) = .empty;
    var services: std.ArrayList(manifest_mod.ServiceEntry) = .empty;

    var t = db.prepare("SELECT name FROM taps ORDER BY name;") catch
        return unreadableDb(db);
    defer t.finalize();
    // A failed step would drop the table from a manifest that looks whole.
    while (t.step() catch return unreadableDb(db)) {
        const n = t.columnText(0) orelse continue;
        const name = try a.dupe(u8, std.mem.sliceTo(n, 0));
        try taps.append(a, name);
    }

    // A keg built from a tap's Casks/ only rebuilds through `cask`.
    var f = db.prepare("SELECT name, tap, tap_rb_subtree = 'cask', full_name FROM kegs WHERE install_reason='direct' ORDER BY name;") catch
        return unreadableDb(db);
    defer f.finalize();
    while (f.step() catch return unreadableDb(db)) {
        const n = f.columnText(0) orelse continue;
        // A bare name would install core's package of that name elsewhere;
        // a `--local` recipe only rebuilds from its file on this machine.
        if (install_args.isLocalTap(if (f.columnText(1)) |p| std.mem.sliceTo(p, 0) else "")) {
            const path = if (f.columnText(3)) |p| std.mem.sliceTo(p, 0) else "";
            const name = std.mem.sliceTo(n, 0);
            if (install_args.localRecipePrintable(name, path))
                output.warnAlways("{s} is a local formula; bundle skips it - rebuild with `mt install --local {f}`", .{ name, output.shellQuoted(path) })
            else
                output.warnAlways(install_args.unprintable_local_fmt ++ "; bundle skips it", .{ std.zig.fmtString(name), std.zig.fmtString(path) });
            continue;
        }
        const name = try qualifiedName(a, f.columnText(1), n);
        if (f.columnBool(2))
            try casks.append(a, .{ .name = name })
        else
            try formulas.append(a, .{ .name = name });
    }

    var c = db.prepare("SELECT token, tap FROM casks ORDER BY token;") catch
        return unreadableDb(db);
    defer c.finalize();
    while (c.step() catch return unreadableDb(db)) {
        const n = c.columnText(0) orelse continue;
        const name = try qualifiedName(a, c.columnText(1), n);
        try casks.append(a, .{ .name = name });
    }

    if (opts.include_services) {
        // A local keg's service stays behind with its package.
        var s = db.prepare("SELECT name FROM services WHERE auto_start = 1 AND keg_name NOT IN " ++
            "(SELECT name FROM kegs WHERE tap = '" ++ install_args.local_tap_label ++ "') ORDER BY name;") catch
            return unreadableDb(db);
        defer s.finalize();
        while (s.step() catch return unreadableDb(db)) {
            const n = s.columnText(0) orelse continue;
            const name = try a.dupe(u8, std.mem.sliceTo(n, 0));
            try services.append(a, .{ .name = name, .auto_start = true });
        }
    }

    manifest.taps = try taps.toOwnedSlice(a);
    manifest.formulas = try formulas.toOwnedSlice(a);
    manifest.casks = try casks.toOwnedSlice(a);
    manifest.services = try services.toOwnedSlice(a);
    manifest.version = manifest_mod.schema_version;
}

/// `<tap>/<name>` for a third-party tap, so `bundle install` reaches the tap
/// the package came from instead of core.
fn qualifiedName(a: std.mem.Allocator, tap_col: ?[*:0]const u8, name_col: [*:0]const u8) ![]const u8 {
    const name = std.mem.sliceTo(name_col, 0);
    const tap = install_args.thirdPartyTap(if (tap_col) |p| std.mem.sliceTo(p, 0) else "");
    if (tap.len == 0) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ tap, name });
}

fn populateFromBundle(manifest: *manifest_mod.Manifest, db: *sqlite.Database, name: []const u8) !void {
    const a = manifest.allocator();
    manifest.name = try a.dupe(u8, name);
    manifest.version = manifest_mod.schema_version;

    var taps: std.ArrayList([]const u8) = .empty;
    var formulas: std.ArrayList(manifest_mod.FormulaEntry) = .empty;
    var casks: std.ArrayList(manifest_mod.CaskEntry) = .empty;
    var services: std.ArrayList(manifest_mod.ServiceEntry) = .empty;

    // A bundle with no members is valid; one never registered is a typo.
    var known = db.prepare("SELECT 1 FROM bundles WHERE name = ?;") catch return unreadableDb(db);
    defer known.finalize();
    known.bindText(1, name) catch return unreadableDb(db);
    if (!(known.step() catch return unreadableDb(db))) {
        output.err("bundle not registered: {s}", .{name});
        return error.Aborted;
    }

    var stmt = db.prepare("SELECT kind, ref FROM bundle_members WHERE bundle_name = ? ORDER BY kind, ref;") catch
        return unreadableDb(db);
    defer stmt.finalize();
    stmt.bindText(1, name) catch return unreadableDb(db);
    while (stmt.step() catch return unreadableDb(db)) {
        const kind_p = stmt.columnText(0) orelse continue;
        const ref_p = stmt.columnText(1) orelse continue;
        const kind = std.mem.sliceTo(kind_p, 0);
        const ref = try a.dupe(u8, std.mem.sliceTo(ref_p, 0));
        if (std.mem.eql(u8, kind, "tap")) {
            try taps.append(a, ref);
        } else if (std.mem.eql(u8, kind, "formula")) {
            try formulas.append(a, .{ .name = ref });
        } else if (std.mem.eql(u8, kind, "cask")) {
            try casks.append(a, .{ .name = ref });
        } else if (std.mem.eql(u8, kind, "service")) {
            try services.append(a, .{ .name = ref });
        }
    }
    manifest.taps = try taps.toOwnedSlice(a);
    manifest.formulas = try formulas.toOwnedSlice(a);
    manifest.casks = try casks.toOwnedSlice(a);
    manifest.services = try services.toOwnedSlice(a);
}

fn openDb(ctx: *const AppCtx) !sqlite.Database {
    const prefix = atomic.maltPrefixOrAbort();
    var db_dir_buf: [512]u8 = undefined;
    const db_dir = std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix}) catch
        return openFailed();
    // makePath is the idempotent "ensure" variant; a real permission/ENOSPC
    // failure surfaces at sqlite.Database.open below with a narrower error.
    std.Io.Dir.cwd().createDirPath(ctx.io, db_dir) catch {};
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/malt.db", .{db_dir}, 0) catch
        return openFailed();
    var db = sqlite.Database.open(path) catch return openFailed();
    errdefer db.close();
    // Schema init is idempotent; a newer-than-us DB is the one failure to
    // stop on, anything else surfaces at the caller's next prepare/step.
    schema.initSchema(&db) catch |e| if (e == error.SchemaTooNew) return schema_report.abortInitFailure(&db, e, prefix);
    return db;
}

fn openFailed() error{Aborted} {
    output.err("Failed to open database", .{});
    return error.Aborted;
}

/// Bare `malt bundle` is a usage error, so the text goes to stderr. An explicit
/// `--help` is a successful request and goes to stdout via `showIfRequested`,
/// matching every other command. Both read the same text from `help.zig`.
fn printHelp(ctx: *const AppCtx) void {
    ctx.stderr.writeStreamingAll(ctx.io, help_mod.helpFor("bundle")) catch {};
}

const fs_test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

test "remove: bare name defaults to unregister-only" {
    const a = resolveRemoveArgs(&.{"work"}, false).?;
    try std.testing.expectEqualStrings("work", a.name);
    // The default must stay non-destructive: `bundle remove` predates --purge
    // and callers rely on it leaving packages installed.
    try std.testing.expect(!a.purge);
    try std.testing.expect(!a.yes);
    try std.testing.expect(!a.dry_run);
}

test "remove: flags parse in any position relative to the name" {
    const before = resolveRemoveArgs(&.{ "--purge", "--yes", "work" }, false).?;
    try std.testing.expectEqualStrings("work", before.name);
    try std.testing.expect(before.purge);
    try std.testing.expect(before.yes);

    const after = resolveRemoveArgs(&.{ "work", "--purge", "-y" }, false).?;
    try std.testing.expectEqualStrings("work", after.name);
    try std.testing.expect(after.purge);
    try std.testing.expect(after.yes);
}

test "remove: --dry-run is set by the flag or inherited from the global" {
    try std.testing.expect(resolveRemoveArgs(&.{ "work", "--dry-run" }, false).?.dry_run);
    try std.testing.expect(resolveRemoveArgs(&.{ "work", "-n" }, false).?.dry_run);
    // `malt --dry-run bundle remove --purge` must preview, not uninstall:
    // main.zig strips the global, so the flag can only arrive this way.
    try std.testing.expect(resolveRemoveArgs(&.{"work"}, true).?.dry_run);
}

test "remove: a missing or duplicated name is rejected" {
    try std.testing.expect(resolveRemoveArgs(&.{}, false) == null);
    try std.testing.expect(resolveRemoveArgs(&.{"--purge"}, false) == null);
    // Two positionals are ambiguous; silently purging the second would be
    // destructive, so refuse rather than guess.
    try std.testing.expect(resolveRemoveArgs(&.{ "work", "home" }, false) == null);
}

test "create: explicit out_path wins regardless of --format position" {
    // Path before the flag was the broken order: a late --format json used to
    // clobber the explicit path with the JSON default.
    const a = try resolveCreateArgs(&.{ "myfile", "--format", "json" });
    try std.testing.expectEqualStrings("myfile", a.out_path);
    try std.testing.expectEqual(Format.json, a.format);

    const b = try resolveCreateArgs(&.{ "--format", "json", "myfile" });
    try std.testing.expectEqualStrings("myfile", b.out_path);

    // No explicit path falls back to the format default.
    try std.testing.expectEqualStrings("Maltfile.json", (try resolveCreateArgs(&.{ "--format", "json" })).out_path);
    try std.testing.expectEqualStrings("Brewfile", (try resolveCreateArgs(&.{})).out_path);

    // Repeated --format must not strand the JSON default on a brewfile result.
    try std.testing.expectEqualStrings("Brewfile", (try resolveCreateArgs(&.{ "--format", "json", "--format", "brewfile" })).out_path);

    // An invalid format is rejected; --services rides through to the result.
    try std.testing.expectError(error.Aborted, resolveCreateArgs(&.{ "--format", "yaml" }));
    try std.testing.expect((try resolveCreateArgs(&.{"--services"})).include_services);
}

test "create: a --format with no value is rejected, not silently dropped" {
    // Dropping it would write a Brewfile where the user asked for another format.
    try std.testing.expectError(error.Aborted, resolveCreateArgs(&.{"--format"}));
    try std.testing.expectError(error.Aborted, resolveCreateArgs(&.{ "myfile", "--format" }));
}

test "create: an unknown flag stops the command before it writes a file" {
    // `--file=elsewhere` carried on would overwrite ./Brewfile instead.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();
    try std.testing.expectError(error.Aborted, resolveCreateArgs(&.{"--file=elsewhere"}));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Unknown flag: --file=elsewhere") != null);
}

test "create: `--` ends the options, so a dash-led path is the output path" {
    const a = try resolveCreateArgs(&.{ "--", "-odd", "--format" });
    try std.testing.expectEqualStrings("--format", a.out_path);
    try std.testing.expectEqual(Format.brewfile, a.format);
}

test "writeManifest creates parent directories for a nested output path" {
    // A nested out_path whose parent is missing must be created, not fail with
    // no file — parity with `backup -o` / `purge --backup`.
    const io = std.Options.debug_io;
    var s = try Scratch.init("bundle_nested");
    defer s.deinit();

    const dest = s.p("/a/b/Brewfile");

    var manifest = manifest_mod.Manifest.init(std.testing.allocator);
    defer manifest.deinit();

    const ctx: AppCtx = .{ .io = io, .environ = .empty };
    try writeManifest(&ctx, manifest, dest, .brewfile);

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    f.close(io);
}

fn testFailure(kind: runner_mod.MemberKind, name: []const u8, why: []const u8) runner_mod.MemberError {
    var f: runner_mod.MemberError = .{ .kind = kind, .name = name, .err = runner_mod.DispatchError.DispatchFailed };
    f.reason.record(why);
    return f;
}

test "renderFailures appends the captured reason to install failure lines" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    const failures = [_]runner_mod.MemberError{
        testFailure(.formula, "foo", "offline mode: formula 'foo' not cached"),
        testFailure(.cask, "bar", "no download for this cask"),
    };
    try std.testing.expect(renderFailures(&failures));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "install failed: foo: offline mode: formula 'foo' not cached") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "cask install failed: bar: no download for this cask") != null);
}

test "renderFailures keeps the bare line when no reason was captured" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    const failures = [_]runner_mod.MemberError{
        testFailure(.formula, "foo", ""),
        testFailure(.tap, "user/tap", ""),
    };
    try std.testing.expect(renderFailures(&failures));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "install failed: foo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "install failed: foo:") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "tap failed: user/tap\n") != null);
}

test "renderFailures scrubs escape sequences out of the reason" {
    // The reason quotes API-supplied names, so it must not reach the terminal raw.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    const failures = [_]runner_mod.MemberError{testFailure(.formula, "foo", "formula '\x1b]0;pwned\x07' not cached")};
    _ = renderFailures(&failures);

    try std.testing.expect(std.mem.indexOfScalar(u8, buf.items, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "not cached") != null);
}

test "renderFailures: a failed service start alone is not a hard failure" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    const failures = [_]runner_mod.MemberError{testFailure(.service_start, "svc", "")};
    try std.testing.expect(!renderFailures(&failures));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "could not auto-start service: svc") != null);
}

test "captureSink keeps the actionable error line and prints nothing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer output.endStderrCapture();

    var reason: runner_mod.MemberReason = .{};
    const sink = captureSink(&reason);
    sink.info("installing {s}", .{"foo"});
    sink.warn("careful", .{});
    sink.err("foo: {d} symlink conflict(s) detected:", .{2});
    sink.err("  {s} already linked by {s}", .{ "bin/foo", "Cellar/bar/1.0" });
    sink.err("Uninstall the conflicting package first.", .{});
    sink.success("done", .{});

    try std.testing.expectEqualStrings("bin/foo already linked by Cellar/bar/1.0", reason.slice());
    try std.testing.expect(!sink.show_progress);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "resolveBundlefile says where it looked when no bundle file is found" {
    const ctx = @import("../app_ctx.zig").debug_ctx; // no HOME
    for ([_][]const u8{ "Brewfile", "Maltfile.json" }) |name| {
        std.Io.Dir.cwd().access(ctx.io, name, .{}) catch continue;
        return error.SkipZigTest; // the runner's cwd holds a real one
    }
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &captured);
    defer output.endStderrCapture();
    try std.testing.expectError(error.Aborted, resolveBundlefile(&ctx, std.testing.allocator, null));
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "No Brewfile or Maltfile.json") != null);
}
