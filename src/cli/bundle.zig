//! malt — bundle command

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const io_mod = @import("../ui/io.zig");
const manifest_mod = @import("../core/bundle/manifest.zig");
const brewfile_mod = @import("../core/bundle/brewfile.zig");
const brewfile_emit = @import("../core/bundle/brewfile_emit.zig");
const runner_mod = @import("../core/bundle/runner.zig");
const install_cmd = @import("install.zig");
const tap_cmd = @import("tap.zig");
const services_cmd = @import("services.zig");

// Default in-process dispatcher: the CLI layer supplies this so the
// runner can stay ignorant of cli/* while still calling into the real
// install/tap/services primitives.
fn cliInstallFormula(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    _ = ctx;
    return install_cmd.installAll(allocator, &.{name}, .{});
}

fn cliInstallCask(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    _ = ctx;
    return install_cmd.installAll(allocator, &.{name}, .{ .cask = true });
}

fn cliTapAdd(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    _ = ctx;
    return tap_cmd.tapAdd(allocator, name);
}

fn cliServiceStart(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
    _ = ctx;
    return services_cmd.servicesStart(allocator, name);
}

const default_dispatcher = runner_mod.Dispatcher{
    .installFormula = cliInstallFormula,
    .installCask = cliInstallCask,
    .tapAdd = cliTapAdd,
    .serviceStart = cliServiceStart,
};

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

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or
        std.mem.eql(u8, args[0], "-h") or
        std.mem.eql(u8, args[0], "--help"))
    {
        try printHelp();
        return;
    }

    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "install")) return cmdInstall(allocator, rest);
    if (std.mem.eql(u8, sub, "create")) return cmdCreate(allocator, rest);
    if (std.mem.eql(u8, sub, "list")) return cmdList(allocator);
    if (std.mem.eql(u8, sub, "remove")) return cmdRemove(allocator, rest);
    if (std.mem.eql(u8, sub, "export")) return cmdExport(allocator, rest);
    if (std.mem.eql(u8, sub, "import")) return cmdImport(allocator, rest);

    output.err("Unknown bundle subcommand: {s}", .{sub});
    return BundleError.InvalidArgs;
}

fn cmdInstall(allocator: std.mem.Allocator, rest: []const []const u8) !void {
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

    const path = try resolveBundlefile(allocator, explicit_path);
    defer allocator.free(path);
    output.info("using bundle file: {s}", .{path});

    var diag = brewfile_mod.Diagnostics.init(allocator);
    defer diag.deinit();
    var manifest = try readManifest(allocator, path, &diag);
    defer manifest.deinit();
    for (diag.warnings.items) |w| output.warn("{s}", .{w});

    var db = try openDb();
    defer db.close();
    schema.initSchema(&db) catch {};

    var report = runner_mod.run(allocator, &db, manifest, .{
        .dry_run = dry_run,
        .dispatcher = &default_dispatcher,
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

fn cmdList(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var db = try openDb();
    defer db.close();
    schema.initSchema(&db) catch {};

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

fn cmdRemove(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    _ = allocator;
    if (rest.len != 1) {
        output.err("bundle remove: expected <name>", .{});
        return BundleError.InvalidArgs;
    }
    const name = rest[0];
    var db = try openDb();
    defer db.close();
    schema.initSchema(&db) catch {};

    var stmt = db.prepare("DELETE FROM bundles WHERE name = ?;") catch
        return BundleError.DatabaseError;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return BundleError.DatabaseError;
    _ = stmt.step() catch return BundleError.DatabaseError;
    output.success("bundle removed: {s}", .{name});
}

fn cmdCreate(allocator: std.mem.Allocator, rest: []const []const u8) !void {
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

    var db = try openDb();
    defer db.close();
    schema.initSchema(&db) catch {};

    var manifest = manifest_mod.Manifest.init(allocator);
    defer manifest.deinit();
    try populateFromInstalled(&manifest, &db);
    try writeManifest(allocator, manifest, out_path, format);
    output.success("wrote {s}", .{out_path});
}

fn cmdExport(allocator: std.mem.Allocator, rest: []const []const u8) !void {
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

    var db = try openDb();
    defer db.close();
    schema.initSchema(&db) catch {};

    var manifest = manifest_mod.Manifest.init(allocator);
    defer manifest.deinit();
    if (bundle_name) |n| {
        try populateFromBundle(&manifest, &db, n);
    } else {
        try populateFromInstalled(&manifest, &db);
    }

    const stdout = io_mod.stdoutFile();
    var write_buf: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(io_mod.ctx(), &write_buf);
    const w = &stdout_writer.interface;
    switch (format) {
        .brewfile => try brewfile_emit.emit(manifest, w),
        .json => try manifest_mod.emitJson(manifest, w),
    }
    try w.flush();
}

fn cmdImport(allocator: std.mem.Allocator, rest: []const []const u8) !void {
    if (rest.len != 1) {
        output.err("bundle import: expected <file>", .{});
        return BundleError.InvalidArgs;
    }
    const path = rest[0];
    var diag = brewfile_mod.Diagnostics.init(allocator);
    defer diag.deinit();
    var manifest = try readManifest(allocator, path, &diag);
    defer manifest.deinit();
    for (diag.warnings.items) |w| output.warn("{s}", .{w});

    var db = try openDb();
    defer db.close();
    schema.initSchema(&db) catch {};

    // Record metadata only; no install.
    var stmt = db.prepare(
        \\INSERT OR REPLACE INTO bundles(name, manifest_path, created_at, version)
        \\VALUES (?, ?, ?, ?);
    ) catch return BundleError.DatabaseError;
    defer stmt.finalize();
    const name = if (manifest.name.len > 0) manifest.name else path;
    stmt.bindText(1, name) catch return BundleError.DatabaseError;
    stmt.bindText(2, path) catch return BundleError.DatabaseError;
    stmt.bindInt(3, fs_compat.timestamp()) catch return BundleError.DatabaseError;
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

fn resolveBundlefile(allocator: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |p| return allocator.dupe(u8, p) catch return BundleError.BundlefileNotFound;

    const candidates = [_][]const u8{
        "Brewfile",
        "Maltfile.json",
    };
    for (candidates) |c| {
        fs_compat.cwd().access(c, .{}) catch continue;
        return allocator.dupe(u8, c) catch return BundleError.BundlefileNotFound;
    }

    // ~/.config/malt
    if (fs_compat.getenv("HOME")) |home| {
        for ([_][]const u8{ "Brewfile", "Maltfile.json" }) |name| {
            const p = std.fmt.allocPrint(allocator, "{s}/.config/malt/{s}", .{ home, name }) catch
                return BundleError.BundlefileNotFound;
            fs_compat.accessAbsolute(p, .{}) catch {
                allocator.free(p);
                continue;
            };
            return p;
        }
    }
    return BundleError.BundlefileNotFound;
}

fn readManifest(
    allocator: std.mem.Allocator,
    path: []const u8,
    diag: ?*brewfile_mod.Diagnostics,
) !manifest_mod.Manifest {
    const file = if (std.fs.path.isAbsolute(path))
        fs_compat.openFileAbsolute(path, .{}) catch return BundleError.BundlefileNotFound
    else
        fs_compat.cwd().openFile(path, .{}) catch return BundleError.BundlefileNotFound;
    defer file.close();

    const stat = file.stat() catch return BundleError.BundlefileNotFound;
    if (stat.size > 8 * 1024 * 1024) return BundleError.BundlefileParse;
    const body = allocator.alloc(u8, @intCast(stat.size)) catch return BundleError.BundlefileParse;
    defer allocator.free(body);
    _ = file.readAll(body) catch return BundleError.BundlefileParse;

    if (std.mem.endsWith(u8, path, ".json")) {
        return manifest_mod.parseJson(allocator, body) catch return BundleError.BundlefileParse;
    }
    return brewfile_mod.parse(allocator, body, diag) catch return BundleError.BundlefileParse;
}

fn writeManifest(
    allocator: std.mem.Allocator,
    manifest: manifest_mod.Manifest,
    path: []const u8,
    format: Format,
) !void {
    _ = allocator;
    const file = if (std.fs.path.isAbsolute(path))
        fs_compat.createFileAbsolute(path, .{ .truncate = true }) catch return BundleError.WriteFailed
    else
        fs_compat.cwd().createFile(path, .{ .truncate = true }) catch return BundleError.WriteFailed;
    defer file.close();
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(&write_buf);
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

fn openDb() !sqlite.Database {
    const prefix = atomic.maltPrefix();
    var db_dir_buf: [512]u8 = undefined;
    const db_dir = std.fmt.bufPrint(&db_dir_buf, "{s}/db", .{prefix}) catch
        return BundleError.DatabaseError;
    fs_compat.cwd().makePath(db_dir) catch {};
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/malt.db", .{db_dir}) catch
        return BundleError.DatabaseError;
    return sqlite.Database.open(path);
}

fn printHelp() !void {
    const msg =
        \\Usage: malt bundle <subcommand> [args]
        \\
        \\Subcommands:
        \\  install [file]              Install formulae/casks/taps/services from a Brewfile or Maltfile.json.
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
    io_mod.stderrWriteAll(msg);
}
