//! malt — doctor command
//! System health check.

const std = @import("std");

const mount_c = @import("c_mount");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const patch = @import("../core/patch.zig");
const perms_mod = @import("../core/perms.zig");
const lock_mod = @import("../db/lock.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const clonefile = @import("../fs/clonefile.zig");
const parser = @import("../macho/parser.zig");
const client_mod = @import("../net/client.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
pub const cask_history = @import("doctor/cask_history.zig");
const fix_mod = @import("doctor/fix.zig");
pub const FixKind = fix_mod.FixKind;
pub const ManualKind = fix_mod.ManualKind;
pub const FixConditions = fix_mod.Conditions;
pub const FixPlan = fix_mod.Plan;
pub const planFixes = fix_mod.planFixes;
const post_install = @import("doctor/post_install.zig");
const render = @import("doctor/render.zig");
pub const CheckStatus = render.CheckStatus;
pub const CheckStyle = render.CheckStyle;
pub const renderCheckRow = render.renderCheckRow;
pub const printCheck = render.printCheck;
/// Per-check outcome; same tags the row renderer uses so the walker
/// can tally without re-translating.
pub const CheckResult = render.CheckStatus;
const help = @import("help.zig");

/// Shared context passed to every check.
pub const CheckCtx = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    io: std.Io,
    environ: std.process.Environ,
};

/// One entry in the health walk. `run` prints its row(s) and returns
/// the walker's tally tag.
pub const Check = struct {
    name: []const u8,
    run: *const fn (ctx: CheckCtx, name: []const u8) CheckResult,
};

pub const Tally = struct {
    warnings: u32 = 0,
    errors: u32 = 0,
};

// Single source of truth for the health walk — append one entry to add
// a check. Exposed `pub` so tests can run the production walker against
// a scratch prefix without re-listing the table.
pub const checks = [_]Check{
    .{ .name = "MALT_PREFIX", .run = checkMaltPrefix },
    .{ .name = "SQLite integrity", .run = checkSqliteIntegrity },
    .{ .name = "Directory structure", .run = checkDirectoryStructure },
    .{ .name = "Stale lock", .run = checkStaleLock },
    .{ .name = patch.external_tool_name, .run = checkExternalTool },
    .{ .name = "APFS volume", .run = checkApfs },
    .{ .name = "Prefix permissions", .run = checkPrefixPermissions },
    .{ .name = "API reachable", .run = checkApiReachable },
    .{ .name = "Orphaned store entries", .run = checkOrphanedStore },
    .{ .name = "Missing kegs", .run = checkMissingKegs },
    .{ .name = "Broken symlinks", .run = checkBrokenSymlinks },
    .{ .name = "Mach-O placeholders", .run = checkMachOPlaceholders },
    .{ .name = "Disk space", .run = checkDiskSpace },
    .{ .name = "Local formula sources", .run = checkLocalSources },
};

/// Walks the table and tallies warn/err contributions. Exposed so
/// tests can drive a fake table hermetically.
pub fn runChecks(ctx: CheckCtx, table: []const Check) Tally {
    var tally: Tally = .{};
    for (table) |c| {
        switch (c.run(ctx, c.name)) {
            .ok => {},
            .warn_status => tally.warnings += 1,
            .err_status => tally.errors += 1,
        }
    }
    return tally;
}

/// Walk retained cask versions and emit the report doctor surfaces
/// after the check rows. Pure read-only: routes to stdout (JSON) or
/// stderr (human + optional verbose entry list) by reading
/// `output.isJson()` and `output.isVerbose()`. Held public so the
/// integration test can drive the same path `execute` uses.
pub fn emitCaskHistoryReport(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) void {
    var census = cask_history.collectCensus(allocator, io, prefix);
    defer census.deinit(allocator);

    if (output.isJson()) {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        cask_history.writeJson(&aw.writer, census) catch return;
        output.writeStdoutAll(aw.written());
        return;
    }

    if (census.entries.len == 0) return;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    cask_history.writeHumanSummary(&aw.writer, census) catch return;
    if (output.isVerbose()) {
        // Best-effort: a writer error here loses the entry rows but
        // the summary line is already in `aw` and worth flushing.
        cask_history.writeHumanEntries(&aw.writer, census) catch {};
    }
    output.writeStderrAll(aw.written());
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "doctor")) return;

    const prefix = atomic.maltPrefixOrAbort();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--post-install-status")) {
            post_install.checkPostInstallStatus(ctx, allocator, prefix);
            return;
        }
    }

    const fix_requested = fix_mod.wantsFix(args);

    resetVerboseHint();
    output.info("Running health checks...", .{});
    const tally = runChecks(.{
        .allocator = allocator,
        .prefix = prefix,
        .io = ctx.io,
        .environ = ctx.environ,
    }, &checks);

    emitCaskHistoryReport(allocator, ctx.io, prefix);

    if (fix_requested) {
        output.plain("", .{});
        const dry_run = output.isDryRun();
        if (dry_run) {
            output.info("Doctor fix plan (dry-run):", .{});
        } else {
            output.info("Applying safe-class fixes:", .{});
        }

        const outcome = fix_mod.executeFix(.{ .prefix = prefix, .io = ctx.io }, dry_run);

        if (outcome.plan.safe.count() == 0) {
            output.dim("no safe-class fixes to apply", .{});
        } else if (dry_run) {
            var it = outcome.plan.safe.iterator();
            while (it.next()) |kind| {
                output.dim("would {s}", .{fix_mod.safeLabel(kind)});
            }
        } else {
            if (outcome.stale_lock_removed) output.success("removed stale lock file", .{});
            if (outcome.broken_symlinks_removed > 0) {
                output.success("unlinked {d} broken symlink(s)", .{outcome.broken_symlinks_removed});
            }
            if (outcome.orphans_removed > 0) {
                output.success("swept {d} orphaned store entry(s)", .{outcome.orphans_removed});
            }
        }

        var mit = outcome.plan.manual.iterator();
        while (mit.next()) |kind| {
            output.warn("manual: {s}", .{fix_mod.manualHint(kind)});
        }
    }

    output.plain("", .{});
    emitVerboseHintIfNeeded();
    if (tally.errors > 0) {
        output.err("{d} error(s), {d} warning(s)", .{ tally.errors, tally.warnings });
        std.process.exit(2);
    } else if (tally.warnings > 0) {
        output.warn("{d} warning(s)", .{tally.warnings});
        std.process.exit(1);
    } else {
        output.success("Your malt installation is healthy", .{});
    }
}

/// Armed by any check that surfaces offenders the user could see
/// listed under `--verbose` (Mach-O placeholders, broken symlinks,
/// missing kegs, prefix-permissions). `execute` reads it after the
/// check loop to emit a dim "run with --verbose for the full list"
/// nudge. Reset by `resetVerboseHint` so re-entering the dispatcher
/// from tests starts clean.
var verbose_hint_armed: bool = false;

/// Test hook + production reset: clear the verbose-hint flag at the
/// top of every `execute` so a previous run on the same process
/// doesn't leak its state.
pub fn resetVerboseHint() void {
    verbose_hint_armed = false;
}

/// Internal arm — called by enumerable checks whenever they have
/// offenders, regardless of the verbose flag. `emitVerboseHintIfNeeded`
/// decides whether to surface the nudge.
fn armVerboseHint() void {
    verbose_hint_armed = true;
}

/// Emit a "run with --verbose for the full list" nudge after the
/// check loop when an enumerable check surfaced offenders AND
/// `--verbose` is off.
pub fn emitVerboseHintIfNeeded() void {
    if (output.isVerbose()) return;
    if (!verbose_hint_armed) return;
    output.dim("run with --verbose for the full list", .{});
}

/// Emit one dim/faint detail line indented under a check row, with a
/// `-` bullet so multiple rows read as a list. Routes through
/// `output.writeStderrAll` so doctor's stderr-capture tests see the
/// bytes; `std.debug.print` would bypass the capture buffer.
fn writeStyledDetail(text: []const u8) void {
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "    - {s}\n", .{text}) catch return;
    if (color.isColorEnabled()) {
        output.writeStderrAll(color.SemanticStyle.detail.code());
        output.writeStderrAll(line);
        output.writeStderrAll(color.Style.reset.code());
    } else {
        output.writeStderrAll(line);
    }
}

/// Stream the verbose-only entry list. Gated on `--verbose`; the
/// always-on first-3 hint lines (`checkPrefixPermissions`) call
/// `writeStyledDetail` directly so they share the styling without
/// the verbose gate.
fn writeVerboseList(entries: []const []const u8) void {
    if (!output.isVerbose()) return;
    for (entries) |e| writeStyledDetail(e);
}

fn freeOwnedStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
}

/// Extract the keg identifier (`<package> <version>`) from a
/// Cellar-relative file path of the form `<package>/<version>/<rest>`.
/// Returns null when the path has fewer than two slash-delimited
/// segments — those are walker artefacts we ignore here.
fn caskCellarKegKey(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const first_slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const rest = path[first_slash + 1 ..];
    const second_slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ path[0..first_slash], rest[0..second_slash] }) catch null;
}

// ── individual checks ────────────────────────────────────────────────
// `atomic.maltPrefixOrAbort()` validates the prefix upstream, so checks treat
// it as trusted.

fn checkMaltPrefix(ctx: CheckCtx, name: []const u8) CheckResult {
    const is_default = std.mem.eql(u8, ctx.prefix, "/opt/malt");
    var pbuf: [600]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &pbuf,
        "{s} {s}",
        .{ ctx.prefix, if (is_default) "(default)" else "(from MALT_PREFIX)" },
    ) catch ctx.prefix;
    printCheck(name, .ok, detail);
    return .ok;
}

fn checkSqliteIntegrity(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .err_status, "Prefix path too long");
        return .err_status;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .err_status, "Cannot open database");
        return .err_status;
    };
    defer db.close();

    // Schema is idempotent; the `PRAGMA integrity_check` below is the real probe.
    schema.initSchema(&db) catch {};

    var stmt = db.prepare("PRAGMA integrity_check;") catch {
        printCheck(name, .err_status, "Cannot run integrity check");
        return .err_status;
    };
    defer stmt.finalize();

    if (stmt.step() catch false) {
        if (stmt.columnText(0)) |r| {
            const txt = std.mem.sliceTo(r, 0);
            if (std.mem.eql(u8, txt, "ok")) {
                printCheck(name, .ok, null);
                return .ok;
            }
            printCheck(name, .err_status, "Database may be corrupt");
            return .err_status;
        }
    }
    // PRAGMA yielded no row — unreachable in practice; stay silent.
    return .ok;
}

fn checkDirectoryStructure(ctx: CheckCtx, name: []const u8) CheckResult {
    const dirs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "tmp", "cache", "db" };
    var first_missing_buf: [512]u8 = undefined;
    var first_missing_len: usize = 0;
    var missing: u32 = 0;
    for (dirs) |dir| {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ctx.prefix, dir }) catch continue;
        std.Io.Dir.accessAbsolute(ctx.io, p, .{}) catch {
            if (first_missing_len == 0) {
                const s = std.fmt.bufPrint(&first_missing_buf, "{s}", .{p}) catch &[_]u8{};
                first_missing_len = s.len;
            }
            missing += 1;
        };
    }
    if (missing == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [640]u8 = undefined;
    const msg = if (missing == 1)
        std.fmt.bufPrint(&msg_buf, "Missing directory: {s}", .{first_missing_buf[0..first_missing_len]}) catch "Missing directory"
    else
        std.fmt.bufPrint(&msg_buf, "{d} missing directories (first: {s})", .{ missing, first_missing_buf[0..first_missing_len] }) catch "Missing directories";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

fn checkStaleLock(ctx: CheckCtx, name: []const u8) CheckResult {
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    const pid = lock_mod.LockFile.holderPid(ctx.io, lock_path);
    if (pid) |p| {
        const is_alive = std.c.kill(p, @enumFromInt(0)) == 0;
        var pid_buf: [256]u8 = undefined;
        if (is_alive) {
            const s = std.fmt.bufPrint(&pid_buf, "Lock held by active PID {d}", .{p}) catch "Lock held";
            printCheck(name, .warn_status, s);
        } else {
            const s = std.fmt.bufPrint(&pid_buf, "Stale lock from dead PID {d}. Run: rm {s}", .{ p, lock_path }) catch "Stale lock detected";
            printCheck(name, .warn_status, s);
        }
        return .warn_status;
    }
    printCheck(name, .ok, null);
    return .ok;
}

fn checkExternalTool(ctx: CheckCtx, name: []const u8) CheckResult {
    // Row title is also the PATH binary to probe.
    if (externalToolAvailable(ctx.io, ctx.environ, name)) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var et_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &et_buf,
        "`{s}` not found on PATH. Install Xcode Command Line Tools: xcode-select --install",
        .{name},
    ) catch "External relocation tool missing. Install Xcode Command Line Tools.";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

fn checkApfs(ctx: CheckCtx, name: []const u8) CheckResult {
    if (clonefile.isApfs(ctx.prefix)) {
        printCheck(name, .ok, null);
        return .ok;
    }
    printCheck(name, .warn_status, "Not on APFS — clonefile unavailable");
    return .warn_status;
}

fn checkPrefixPermissions(ctx: CheckCtx, name: []const u8) CheckResult {
    // Cap the walk so pathological trees don't balloon doctor's memory.
    const findings = perms_mod.walkPrefix(
        ctx.io,
        ctx.allocator,
        ctx.prefix,
        perms_mod.currentUid(),
        32,
    ) catch {
        printCheck(name, .warn_status, "Walk failed");
        return .warn_status;
    };
    defer perms_mod.freeFindings(ctx.allocator, findings);

    if (findings.len == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var pm_buf: [256]u8 = undefined;
    const pm_msg = std.fmt.bufPrint(
        &pm_buf,
        "{d} path(s) with weak permissions under {s} — run `ls -l` or `chmod`",
        .{ findings.len, ctx.prefix },
    ) catch "Weak-permission paths under prefix";
    printCheck(name, .warn_status, pm_msg);
    armVerboseHint();
    // First few as a hint so the user knows where to look. Routes
    // through the shared styled-detail writer for parity with the
    // verbose lists below — capture-aware (so tests see the bytes)
    // and dim/faint on a tty.
    for (findings[0..@min(findings.len, 3)]) |f| {
        var line_buf: [1024]u8 = undefined;
        const reason = if (f.report.other_writable)
            "other-writable"
        else if (f.report.group_writable)
            "group-writable"
        else
            "wrong owner";
        const line = std.fmt.bufPrint(&line_buf, "{s} ({s})", .{ f.path, reason }) catch continue;
        writeStyledDetail(line);
    }
    return .warn_status;
}

fn checkApiReachable(ctx: CheckCtx, name: []const u8) CheckResult {
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, ctx.allocator);
    defer http.deinit();
    const status = http.head("https://formulae.brew.sh") catch {
        printCheck(name, .warn_status, "Cannot reach formulae.brew.sh");
        return .warn_status;
    };
    if (status >= 200 and status < 400) {
        printCheck(name, .ok, null);
        return .ok;
    }
    printCheck(name, .warn_status, "API returned error status");
    return .warn_status;
}

fn checkOrphanedStore(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer db.close();

    var store_path_buf: [512]u8 = undefined;
    const store_path = std.fmt.bufPrint(&store_path_buf, "{s}/store", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var store_dir = std.Io.Dir.openDirAbsolute(ctx.io, store_path, .{ .iterate = true }) catch {
        // store/ missing or unreadable — not an error, just skip.
        printCheck(name, .ok, null);
        return .ok;
    };
    defer store_dir.close(ctx.io);

    var orphan_count: u32 = 0;
    var iter = store_dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        // Each entry is a sha256 dir; classify via store_refs.
        var stmt = db.prepare(
            "SELECT refcount FROM store_refs WHERE store_sha256 = ?1;",
        ) catch continue;
        defer stmt.finalize();
        stmt.bindText(1, entry.name) catch continue;
        const has_row = stmt.step() catch false;
        if (has_row) {
            if (stmt.columnInt(0) <= 0) orphan_count += 1;
        } else {
            orphan_count += 1;
        }
    }

    if (orphan_count == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} orphaned store entry(s). Run: mt purge --store-orphans",
        .{orphan_count},
    ) catch "Orphaned store entries found. Run: mt purge --store-orphans";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

fn checkMissingKegs(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer db.close();

    var stmt = db.prepare("SELECT name, version, cellar_path FROM kegs;") catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer stmt.finalize();

    // Collect missing kegs so `--verbose` can name each one; under
    // default mode the list is just sized for the count.
    var offenders: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(ctx.allocator, &offenders);

    while (stmt.step() catch false) {
        const cellar_raw = stmt.columnText(2) orelse continue;
        const cellar_path = std.mem.sliceTo(cellar_raw, 0);
        std.Io.Dir.accessAbsolute(ctx.io, cellar_path, .{}) catch {
            const k_name = std.mem.sliceTo(stmt.columnText(0) orelse continue, 0);
            const k_ver = std.mem.sliceTo(stmt.columnText(1) orelse continue, 0);
            const row = std.fmt.allocPrint(ctx.allocator, "{s} {s}", .{ k_name, k_ver }) catch continue;
            offenders.append(ctx.allocator, row) catch {
                ctx.allocator.free(row);
                continue;
            };
        };
    }

    if (offenders.items.len == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} keg(s) in DB but missing on disk. Reinstall affected packages",
        .{offenders.items.len},
    ) catch "Missing keg directories detected. Reinstall affected packages";
    printCheck(name, .err_status, msg);
    armVerboseHint();
    writeVerboseList(offenders.items);
    return .err_status;
}

fn checkBrokenSymlinks(ctx: CheckCtx, name: []const u8) CheckResult {
    const link_dirs = [_][]const u8{ "bin", "lib", "include", "share", "sbin" };
    var offenders: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(ctx.allocator, &offenders);

    for (link_dirs) |subdir| {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ ctx.prefix, subdir }) catch continue;
        var dir = std.Io.Dir.openDirAbsolute(ctx.io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(ctx.io);

        var dir_iter = dir.iterate();
        while (dir_iter.next(ctx.io) catch null) |entry| {
            if (entry.kind == .sym_link) {
                _ = dir.statFile(ctx.io, entry.name, .{}) catch {
                    const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ subdir, entry.name }) catch continue;
                    offenders.append(ctx.allocator, path) catch {
                        ctx.allocator.free(path);
                        continue;
                    };
                    continue;
                };
            }
        }
    }

    if (offenders.items.len == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} broken symlink(s). Run: mt purge --housekeeping",
        .{offenders.items.len},
    ) catch "Broken symlinks found. Run: mt purge --housekeeping";
    printCheck(name, .warn_status, msg);
    armVerboseHint();
    writeVerboseList(offenders.items);
    return .warn_status;
}

fn checkMachOPlaceholders(ctx: CheckCtx, name: []const u8) CheckResult {
    var cellar_root_buf: [512]u8 = undefined;
    const cellar_root = std.fmt.bufPrint(&cellar_root_buf, "{s}/Cellar", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };

    var cellar_dir = std.Io.Dir.openDirAbsolute(ctx.io, cellar_root, .{ .iterate = true }) catch {
        // No Cellar yet — nothing to scan.
        printCheck(name, .ok, null);
        return .ok;
    };
    defer cellar_dir.close(ctx.io);

    var walker = cellar_dir.walk(ctx.allocator) catch {
        printCheck(name, .warn_status, "Could not walk Cellar tree");
        return .warn_status;
    };
    defer walker.deinit();

    // Group by `<package> <version>` so the headline reports the
    // reinstall target — the user reinstalls the keg, not the file.
    // A single keg can bundle hundreds of placeholder-bearing files
    // (Python site-packages inside a meta-package, LLVM tools);
    // counting files there inflates the number without adding
    // actionable information.
    var groups: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        var it = groups.iterator();
        while (it.next()) |kv| ctx.allocator.free(kv.key_ptr.*);
        groups.deinit(ctx.allocator);
    }

    while (walker.next(ctx.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (hasUnpatchedPlaceholder(ctx.io, ctx.allocator, &cellar_dir, entry.path) catch false) {
            // Grouping is best-effort: an allocator failure here
            // drops the group entry, never silently triggers an
            // .ok outcome — the headline is still right because
            // it's derived from `groups.count()` which only grows
            // when the entry actually lands.
            const key = caskCellarKegKey(ctx.allocator, entry.path) orelse continue;
            const gop = groups.getOrPut(ctx.allocator, key) catch {
                ctx.allocator.free(key);
                continue;
            };
            if (gop.found_existing) ctx.allocator.free(key);
        }
    }

    if (groups.count() == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [512]u8 = undefined;
    const msg = blk: {
        if (output.isVerbose()) {
            // Verbose lists every package below; the (first: …) hint
            // would just duplicate the first row of that list.
            break :blk std.fmt.bufPrint(
                &msg_buf,
                "{d} package(s) ship Mach-O file(s) with unpatched @@HOMEBREW_* placeholders. Reinstall the affected packages.",
                .{groups.count()},
            ) catch "Mach-O files with unpatched @@HOMEBREW_* placeholders found.";
        }
        const first_key = first_key: {
            var it = groups.iterator();
            break :first_key if (it.next()) |kv| kv.key_ptr.* else "";
        };
        break :blk std.fmt.bufPrint(
            &msg_buf,
            "{d} package(s) ship Mach-O file(s) with unpatched @@HOMEBREW_* placeholders (first: {s}). Reinstall the affected packages.",
            .{ groups.count(), first_key },
        ) catch "Mach-O files with unpatched @@HOMEBREW_* placeholders found.";
    };
    printCheck(name, .err_status, msg);
    armVerboseHint();

    if (output.isVerbose()) {
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(ctx.allocator);
        var it = groups.iterator();
        while (it.next()) |kv| lines.append(ctx.allocator, kv.key_ptr.*) catch continue;
        writeVerboseList(lines.items);
    }
    return .err_status;
}

fn checkDiskSpace(ctx: CheckCtx, name: []const u8) CheckResult {
    const posix_path = std.posix.toPosixPath(ctx.prefix) catch {
        printCheck(name, .warn_status, "Cannot determine free disk space");
        return .warn_status;
    };
    var stat_buf: mount_c.struct_statfs = undefined;
    const rc = mount_c.statfs(&posix_path, &stat_buf);
    if (rc != 0) {
        printCheck(name, .warn_status, "Cannot determine free disk space");
        return .warn_status;
    }

    const free_bytes: u64 = @as(u64, @intCast(stat_buf.f_bavail)) * @as(u64, @intCast(stat_buf.f_bsize));
    const one_gb: u64 = 1024 * 1024 * 1024;
    if (free_bytes >= one_gb) {
        printCheck(name, .ok, null);
        return .ok;
    }
    const free_mb = free_bytes / (1024 * 1024);
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "Only {d} MB free (< 1 GB). Free up disk space",
        .{free_mb},
    ) catch "Low disk space (< 1 GB free)";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

fn checkLocalSources(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer db.close();

    const missing = countMissingLocalSources(ctx.io, &db);
    if (missing.total == 0 or missing.stale == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d}/{d} local keg(s) reference a .rb that no longer exists on disk. Run `mt info <name>` to see which.",
        .{ missing.stale, missing.total },
    ) catch "Some local kegs reference a .rb that no longer exists.";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

/// True if `rel_path` inside `base_dir` is a Mach-O binary with at least one
/// load command that still contains `@@HOMEBREW_PREFIX@@` or
/// `@@HOMEBREW_CELLAR@@`. Any I/O or parser error is treated as "not bad" —
/// doctor's placeholder check is best-effort.
fn hasUnpatchedPlaceholder(
    io: std.Io,
    allocator: std.mem.Allocator,
    base_dir: *std.Io.Dir,
    rel_path: []const u8,
) !bool {
    var file = base_dir.openFile(io, rel_path, .{}) catch return false;
    defer file.close(io);

    var magic: [4]u8 = undefined;
    const n = file.readPositionalAll(io, &magic, 0) catch return false;
    if (n < 4) return false;
    if (!parser.isMachO(&magic)) return false;

    // Re-read the full file — parser needs the whole buffer.
    const stat = file.stat(io) catch return false;
    if (stat.size > 512 * 1024 * 1024) return false; // skip pathologically large files
    const data = allocator.alloc(u8, stat.size) catch return false;
    defer allocator.free(data);

    const read = file.readPositionalAll(io, data, 0) catch return false;
    if (read < data.len) return false;

    var macho = parser.parse(allocator, data) catch return false;
    defer macho.deinit();

    for (macho.paths) |lcp| {
        if (std.mem.indexOf(u8, lcp.path, "@@HOMEBREW_PREFIX@@") != null) return true;
        if (std.mem.indexOf(u8, lcp.path, "@@HOMEBREW_CELLAR@@") != null) return true;
    }
    return false;
}

/// Fast existence check for a platform relocation tool on PATH.
/// Tries `/usr/bin/<tool>` first (where Xcode Command Line Tools land
/// install_name_tool) and then walks `PATH` entry-by-entry. `pub` so
/// the doctor render test can exercise both branches.
pub fn externalToolAvailable(io: std.Io, environ: std.process.Environ, tool: []const u8) bool {
    // Fast path for the common macOS case — avoids allocating a PATH
    // walk on every `mt doctor` invocation.
    var fast_buf: [64]u8 = undefined;
    const fast_path = std.fmt.bufPrint(&fast_buf, "/usr/bin/{s}", .{tool}) catch null;
    if (fast_path) |p| {
        if (std.Io.Dir.accessAbsolute(io, p, .{})) |_| return true else |_| {}
    }

    const path_env = std.process.Environ.getPosix(environ, "PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, tool }) catch continue;
        if (std.Io.Dir.accessAbsolute(io, full, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Summary of how many locally-installed kegs still point at their
/// original `.rb` source. `total` counts rows with `tap='local'`;
/// `stale` counts the subset whose `full_name` no longer exists on
/// disk. Keeping this pure (pass in the DB, no `output.*` calls) means
/// the check is exercisable from a hermetic unit test.
pub const LocalSourceCensus = struct {
    total: u32,
    stale: u32,
};

/// Walk `kegs WHERE tap='local'` and classify each row's recorded
/// source path as present or missing. Uses `accessAbsolute` (not a
/// full `openFile`) because we just need to know if the path resolves
/// — we are not reading the file. Silent on DB errors: a broken DB is
/// reported by the separate SQLite-integrity check above.
pub fn countMissingLocalSources(
    io: std.Io,
    db: *sqlite.Database,
) LocalSourceCensus {
    var census: LocalSourceCensus = .{ .total = 0, .stale = 0 };
    var stmt = db.prepare("SELECT full_name FROM kegs WHERE tap = 'local';") catch return census;
    defer stmt.finalize();
    while (stmt.step() catch false) {
        const path_ptr = stmt.columnText(0) orelse continue;
        const path = std.mem.sliceTo(path_ptr, 0);
        census.total += 1;
        std.Io.Dir.accessAbsolute(io, path, .{}) catch {
            census.stale += 1;
        };
    }
    return census;
}
