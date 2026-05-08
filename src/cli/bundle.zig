//! malt — bundle command

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const manifest_mod = @import("../core/bundle/manifest.zig");
const brewfile_mod = @import("../core/bundle/brewfile.zig");
const brewfile_emit = @import("../core/bundle/brewfile_emit.zig");
const runner_mod = @import("../core/bundle/runner.zig");
const cleanup_mod = @import("../core/bundle/cleanup.zig");
const install_cmd = @import("install.zig");
const uninstall_cmd = @import("uninstall.zig");
const tap_cmd = @import("tap.zig");
const services_cmd = @import("services.zig");

// Default in-process dispatcher: the CLI layer supplies this so the
// runner can stay ignorant of cli/* while still calling into the real
// install/tap/services primitives. The opaque `ctx` slot carries the
// process-wide AppCtx so the dispatch helpers can thread io / environ
// through to install/tap/services without re-deriving them.
fn cliInstallFormula(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    const app_ctx = appCtxFromOpaque(ctx);
    return install_cmd.installAll(app_ctx, allocator, &.{name}, .{});
}

fn cliInstallCask(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    const app_ctx = appCtxFromOpaque(ctx);
    return install_cmd.installAll(app_ctx, allocator, &.{name}, .{ .cask = true });
}

fn cliTapAdd(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    const app_ctx = appCtxFromOpaque(ctx);
    return tap_cmd.tapAdd(app_ctx, allocator, name);
}

fn cliServiceStart(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    const app_ctx = appCtxFromOpaque(ctx);
    return services_cmd.servicesStart(app_ctx, allocator, name);
}

fn cliUninstallFormula(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    const app_ctx = appCtxFromOpaque(ctx);
    return uninstall_cmd.execute(app_ctx, allocator, &.{name});
}

fn cliUninstallCask(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    const app_ctx = appCtxFromOpaque(ctx);
    return uninstall_cmd.execute(app_ctx, allocator, &.{ "--cask", name });
}

/// Cast the dispatcher's opaque `ctx` slot back to a borrowed AppCtx pointer.
/// The slot is `?*anyopaque` for ABI symmetry with the runner's Dispatcher;
/// every cli call path sets it via `runDispatcher` / `cleanupDispatcher`,
/// so a null here is a wiring bug — name it instead of UB-panicking.
fn appCtxFromOpaque(ctx: ?*anyopaque) *const AppCtx {
    const non_null = ctx orelse @panic("bundle: dispatcher invoked without AppCtx — wire via runDispatcher/cleanupDispatcher");
    return @ptrCast(@alignCast(non_null));
}

fn runDispatcher(ctx: *const AppCtx) runner_mod.Dispatcher {
    return .{
        .ctx = @ptrCast(@constCast(ctx)),
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

pub const BundleError = error{
    InvalidArgs,
    BundlefileNotFound,
    BundlefileParse,
    DatabaseError,
    RunnerFailed,
    WriteFailed,
};

pub fn describeError(err: BundleError) []const u8 {
    return switch (err) {
        BundleError.InvalidArgs => "invalid argument to `bundle`",
        BundleError.BundlefileNotFound => "no Brewfile/Maltfile.json found in search path",
        BundleError.BundlefileParse => "could not parse bundle file",
        BundleError.DatabaseError => "database error",
        BundleError.RunnerFailed => "one or more bundle members failed to install",
        BundleError.WriteFailed => "could not write bundle output",
    };
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or
        std.mem.eql(u8, args[0], "-h") or
        std.mem.eql(u8, args[0], "--help"))
    {
        try printHelp(ctx);
        return;
    }

    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "install")) return cmdInstall(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "cleanup")) return cmdCleanup(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "create")) return cmdCreate(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "list")) return cmdList(ctx);
    if (std.mem.eql(u8, sub, "remove")) return cmdRemove(ctx, rest);
    if (std.mem.eql(u8, sub, "export")) return cmdExport(ctx, allocator, rest);
    if (std.mem.eql(u8, sub, "import")) return cmdImport(ctx, allocator, rest);

    output.err("Unknown bundle subcommand: {s}", .{sub});
    return BundleError.InvalidArgs;
}

fn cmdInstall(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    // main.zig strips the global `--dry-run` from argv; reading the
    // module-global here keeps bundle install aligned with every other
    // subcommand (install, upgrade, purge, …) and with its envelope.
    const dry_run = output.isDryRun();
    var explicit_path: ?[]const u8 = null;
    for (rest) |a| {
        if (std.mem.startsWith(u8, a, "-")) {
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

    const dispatcher = runDispatcher(ctx);
    var report = runner_mod.run(ctx.io, allocator, &db, manifest, .{
        .dry_run = dry_run,
        .dispatcher = &dispatcher,
    }) catch |e| {
        output.err("bundle install failed: {s}", .{@errorName(e)});
        return BundleError.RunnerFailed;
    };
    defer report.deinit();

    for (report.previews) |p| switch (p.kind) {
        .tap => output.info("would run: malt tap {s}", .{p.name}),
        .formula => output.info("would run: malt install {s}", .{p.name}),
        .cask => output.info("would run: malt install --cask {s}", .{p.name}),
        .service_start => output.info("would run: malt services start {s}", .{p.name}),
    };
    var any_hard = false;
    for (report.failures) |f| switch (f.kind) {
        .tap => {
            output.err("tap failed: {s}", .{f.name});
            any_hard = true;
        },
        .formula => {
            output.err("install failed: {s}", .{f.name});
            any_hard = true;
        },
        .cask => {
            output.err("cask install failed: {s}", .{f.name});
            any_hard = true;
        },
        // Service auto-start is best-effort; warn but don't fail the bundle.
        .service_start => output.warn("could not auto-start service: {s}", .{f.name}),
    };
    if (report.db_record_error) |name| {
        output.err("could not record bundle in database: {s}", .{name});
        any_hard = true;
    }

    if (any_hard) return BundleError.RunnerFailed;
    output.success("bundle install complete", .{});
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
            return BundleError.DatabaseError;
        defer installed.deinit();
        var p = cleanup_mod.diff(
            allocator,
            manifest,
            installed.formulas,
            installed.casks,
        ) catch return BundleError.RunnerFailed;
        errdefer p.deinit();
        cleanup_mod.orderForRemoval(allocator, &db, &p) catch
            return BundleError.DatabaseError;
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
        return BundleError.RunnerFailed;
    };
    defer report.deinit();

    // The uninstall pipeline already prints rich per-member diagnostics;
    // surface only the count here so users see a single summary line.
    if (report.hasFailure()) {
        output.err("bundle cleanup completed with {d} failure(s)", .{report.failures.len});
        return BundleError.RunnerFailed;
    }
    output.success("bundle cleanup complete", .{});
}

fn cmdList(ctx: *const AppCtx) !void {
    var db = try openDb(ctx);
    defer db.close();

    var stmt = db.prepare("SELECT name, created_at FROM bundles ORDER BY name;") catch
        return BundleError.DatabaseError;
    defer stmt.finalize();

    var any = false;
    while (stmt.step() catch return BundleError.DatabaseError) {
        const n = stmt.columnText(0) orelse continue;
        const ts = stmt.columnInt(1);
        output.plain("{s}\t{d}", .{ std.mem.sliceTo(n, 0), ts });
        any = true;
    }
    if (!any) output.info("no bundles registered", .{});
}

fn cmdRemove(ctx: *const AppCtx, rest: []const []const u8) !void {
    if (rest.len != 1) {
        output.err("bundle remove: expected <name>", .{});
        return BundleError.InvalidArgs;
    }
    const name = rest[0];
    var db = try openDb(ctx);
    defer db.close();

    var stmt = db.prepare("DELETE FROM bundles WHERE name = ?;") catch
        return BundleError.DatabaseError;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return BundleError.DatabaseError;
    _ = stmt.step() catch return BundleError.DatabaseError;
    output.success("bundle removed: {s}", .{name});
}

fn cmdCreate(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    var format: Format = .brewfile;
    var out_path: []const u8 = "Brewfile";
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--format") and i + 1 < rest.len) {
            i += 1;
            format = parseFormat(rest[i]) orelse return BundleError.InvalidArgs;
            if (format == .json) out_path = "Maltfile.json";
        } else if (!std.mem.startsWith(u8, a, "-")) {
            out_path = a;
        }
    }

    var db = try openDb(ctx);
    defer db.close();

    var manifest = manifest_mod.Manifest.init(allocator);
    defer manifest.deinit();
    try populateFromInstalled(&manifest, &db);
    try writeManifest(ctx, manifest, out_path, format);
    output.success("wrote {s}", .{out_path});
}

fn cmdExport(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    var format: Format = .brewfile;
    var bundle_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--format") and i + 1 < rest.len) {
            i += 1;
            format = parseFormat(rest[i]) orelse return BundleError.InvalidArgs;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            bundle_name = a;
        }
    }

    var db = try openDb(ctx);
    defer db.close();

    var manifest = manifest_mod.Manifest.init(allocator);
    defer manifest.deinit();
    if (bundle_name) |n| {
        try populateFromBundle(&manifest, &db, n);
    } else {
        try populateFromInstalled(&manifest, &db);
    }

    var write_buf: [4096]u8 = undefined;
    var stdout_writer = ctx.stdout.writer(ctx.io, &write_buf);
    const w = &stdout_writer.interface;
    switch (format) {
        .brewfile => try brewfile_emit.emit(manifest, w),
        .json => try manifest_mod.emitJson(manifest, w),
    }
    try w.flush();
}

fn cmdImport(ctx: *const AppCtx, allocator: std.mem.Allocator, rest: []const []const u8) !void {
    if (rest.len != 1) {
        output.err("bundle import: expected <file>", .{});
        return BundleError.InvalidArgs;
    }
    const path = rest[0];
    var diag = brewfile_mod.Diagnostics.init(allocator);
    defer diag.deinit();
    var manifest = try readManifest(ctx, allocator, path, &diag);
    defer manifest.deinit();
    for (diag.warnings.items) |w| output.warn("{s}", .{w});

    var db = try openDb(ctx);
    defer db.close();

    // Record metadata only; no install.
    var stmt = db.prepare(
        \\INSERT OR REPLACE INTO bundles(name, manifest_path, created_at, version)
        \\VALUES (?, ?, ?, ?);
    ) catch return BundleError.DatabaseError;
    defer stmt.finalize();
    const name = if (manifest.name.len > 0) manifest.name else path;
    stmt.bindText(1, name) catch return BundleError.DatabaseError;
    stmt.bindText(2, path) catch return BundleError.DatabaseError;
    stmt.bindInt(3, std.Io.Clock.real.now(ctx.io).toSeconds()) catch return BundleError.DatabaseError;
    stmt.bindInt(4, @intCast(manifest.version)) catch return BundleError.DatabaseError;
    _ = stmt.step() catch return BundleError.DatabaseError;
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
    if (explicit) |p| return allocator.dupe(u8, p) catch return BundleError.BundlefileNotFound;

    const candidates = [_][]const u8{
        "Brewfile",
        "Maltfile.json",
    };
    for (candidates) |c| {
        std.Io.Dir.cwd().access(ctx.io, c, .{}) catch continue;
        return allocator.dupe(u8, c) catch return BundleError.BundlefileNotFound;
    }

    // ~/.config/malt
    if (std.process.Environ.getPosix(ctx.environ, "HOME")) |home| {
        for ([_][]const u8{ "Brewfile", "Maltfile.json" }) |name| {
            const p = std.fmt.allocPrint(allocator, "{s}/.config/malt/{s}", .{ home, name }) catch
                return BundleError.BundlefileNotFound;
            std.Io.Dir.accessAbsolute(ctx.io, p, .{}) catch {
                allocator.free(p);
                continue;
            };
            return p;
        }
    }
    return BundleError.BundlefileNotFound;
}

fn readManifest(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    path: []const u8,
    diag: ?*brewfile_mod.Diagnostics,
) !manifest_mod.Manifest {
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(ctx.io, path, .{}) catch return BundleError.BundlefileNotFound
    else
        std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return BundleError.BundlefileNotFound;
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch return BundleError.BundlefileNotFound;
    if (stat.size > 8 * 1024 * 1024) return BundleError.BundlefileParse;
    const body = allocator.alloc(u8, @intCast(stat.size)) catch return BundleError.BundlefileParse;
    defer allocator.free(body);
    _ = file.readPositionalAll(ctx.io, body, 0) catch return BundleError.BundlefileParse;

    if (std.mem.endsWith(u8, path, ".json")) {
        return manifest_mod.parseJson(allocator, body) catch return BundleError.BundlefileParse;
    }
    return brewfile_mod.parse(allocator, body, diag) catch return BundleError.BundlefileParse;
}

fn writeManifest(
    ctx: *const AppCtx,
    manifest: manifest_mod.Manifest,
    path: []const u8,
    format: Format,
) !void {
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.createFileAbsolute(ctx.io, path, .{ .truncate = true }) catch return BundleError.WriteFailed
    else
        std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = true }) catch return BundleError.WriteFailed;
    defer file.close(ctx.io);
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(ctx.io, &write_buf);
    const w = &fw.interface;
    switch (format) {
        .brewfile => brewfile_emit.emit(manifest, w) catch return BundleError.WriteFailed,
        .json => manifest_mod.emitJson(manifest, w) catch return BundleError.WriteFailed,
    }
    w.flush() catch return BundleError.WriteFailed;
}

fn populateFromInstalled(manifest: *manifest_mod.Manifest, db: *sqlite.Database) !void {
    const a = manifest.allocator();
    var formulas: std.ArrayList(manifest_mod.FormulaEntry) = .empty;
    var casks: std.ArrayList(manifest_mod.CaskEntry) = .empty;

    var f = db.prepare("SELECT name FROM kegs WHERE install_reason='direct' ORDER BY name;") catch
        return BundleError.DatabaseError;
    defer f.finalize();
    while (f.step() catch false) {
        const n = f.columnText(0) orelse continue;
        const name = a.dupe(u8, std.mem.sliceTo(n, 0)) catch return BundleError.DatabaseError;
        formulas.append(a, .{ .name = name }) catch return BundleError.DatabaseError;
    }

    var c = db.prepare("SELECT token FROM casks ORDER BY token;") catch
        return BundleError.DatabaseError;
    defer c.finalize();
    while (c.step() catch false) {
        const n = c.columnText(0) orelse continue;
        const name = a.dupe(u8, std.mem.sliceTo(n, 0)) catch return BundleError.DatabaseError;
        casks.append(a, .{ .name = name }) catch return BundleError.DatabaseError;
    }

    manifest.formulas = formulas.toOwnedSlice(a) catch return BundleError.DatabaseError;
    manifest.casks = casks.toOwnedSlice(a) catch return BundleError.DatabaseError;
    manifest.version = manifest_mod.schema_version;
}

fn populateFromBundle(manifest: *manifest_mod.Manifest, db: *sqlite.Database, name: []const u8) !void {
    const a = manifest.allocator();
    manifest.name = a.dupe(u8, name) catch return BundleError.DatabaseError;
    manifest.version = manifest_mod.schema_version;

    var taps: std.ArrayList([]const u8) = .empty;
    var formulas: std.ArrayList(manifest_mod.FormulaEntry) = .empty;
    var casks: std.ArrayList(manifest_mod.CaskEntry) = .empty;
    var services: std.ArrayList(manifest_mod.ServiceEntry) = .empty;

    var stmt = db.prepare("SELECT kind, ref FROM bundle_members WHERE bundle_name = ? ORDER BY kind, ref;") catch
        return BundleError.DatabaseError;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return BundleError.DatabaseError;
    while (stmt.step() catch false) {
        const kind_p = stmt.columnText(0) orelse continue;
        const ref_p = stmt.columnText(1) orelse continue;
        const kind = std.mem.sliceTo(kind_p, 0);
        const ref = a.dupe(u8, std.mem.sliceTo(ref_p, 0)) catch return BundleError.DatabaseError;
        if (std.mem.eql(u8, kind, "tap")) {
            taps.append(a, ref) catch return BundleError.DatabaseError;
        } else if (std.mem.eql(u8, kind, "formula")) {
            formulas.append(a, .{ .name = ref }) catch return BundleError.DatabaseError;
        } else if (std.mem.eql(u8, kind, "cask")) {
            casks.append(a, .{ .name = ref }) catch return BundleError.DatabaseError;
        } else if (std.mem.eql(u8, kind, "service")) {
            services.append(a, .{ .name = ref }) catch return BundleError.DatabaseError;
        }
    }
    manifest.taps = taps.toOwnedSlice(a) catch return BundleError.DatabaseError;
    manifest.formulas = formulas.toOwnedSlice(a) catch return BundleError.DatabaseError;
    manifest.casks = casks.toOwnedSlice(a) catch return BundleError.DatabaseError;
    manifest.services = services.toOwnedSlice(a) catch return BundleError.DatabaseError;
}

fn openDb(ctx: *const AppCtx) !sqlite.Database {
    const prefix = atomic.maltPrefixOrAbort();
    var db_dir_buf: [512]u8 = undefined;
    const db_dir = std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix}) catch
        return BundleError.DatabaseError;
    // makePath is the idempotent "ensure" variant; a real permission/ENOSPC
    // failure surfaces at sqlite.Database.open below with a narrower error.
    std.Io.Dir.cwd().createDirPath(ctx.io, db_dir) catch {};
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/malt.db", .{db_dir}, 0) catch
        return BundleError.DatabaseError;
    var db = try sqlite.Database.open(path);
    // Schema init is idempotent; a real failure surfaces at the next
    // prepare/step call in the caller with a narrower error.
    schema.initSchema(&db) catch {};
    return db;
}

fn printHelp(ctx: *const AppCtx) !void {
    const msg =
        \\Usage: malt bundle <subcommand> [args]
        \\
        \\Subcommands:
        \\  install [file]              Install formulae/casks/taps/services from a Brewfile or Maltfile.json.
        \\  cleanup [--yes] [--dry-run] [file]
        \\                              Uninstall packages present on disk but absent from the Brewfile.
        \\  create  [--format brewfile|json] [path]
        \\                              Write currently-installed set to a bundle file.
        \\  list                        List bundles registered in the database.
        \\  remove <name>               Unregister a bundle (does NOT uninstall members).
        \\  export  [--format brewfile|json] [name]
        \\                              Print bundle (or current install) to stdout.
        \\  import  <file>              Register a bundle definition without installing.
        \\
        \\Lookup order for install/export without an explicit path:
        \\  ./Brewfile, ./Maltfile.json, ~/.config/malt/Brewfile, ~/.config/malt/Maltfile.json
        \\
    ;
    ctx.stderr.writeStreamingAll(ctx.io, msg) catch {};
}
