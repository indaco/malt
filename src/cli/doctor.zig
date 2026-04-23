//! malt — doctor command
//! System health check.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const lock_mod = @import("../db/lock.zig");
const atomic = @import("../fs/atomic.zig");
const clonefile = @import("../fs/clonefile.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");
const parser = @import("../macho/parser.zig");
const patch = @import("../core/patch.zig");
const perms_mod = @import("../core/perms.zig");
const client_mod = @import("../net/client.zig");
const mount_c = @import("c_mount");

const render = @import("doctor/render.zig");
const post_install = @import("doctor/post_install.zig");

pub const CheckStatus = render.CheckStatus;
pub const CheckStyle = render.CheckStyle;
pub const renderCheckRow = render.renderCheckRow;
pub const printCheck = render.printCheck;

/// Shared context passed to every check.
pub const CheckCtx = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
};

/// Per-check outcome; same tags the row renderer uses so the walker
/// can tally without re-translating.
pub const CheckResult = render.CheckStatus;

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
// a check.
const checks = [_]Check{
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

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "doctor")) return;

    const prefix = atomic.maltPrefix();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--post-install-status")) {
            post_install.checkPostInstallStatus(allocator, prefix);
            return;
        }
    }

    output.info("Running health checks...", .{});
    const tally = runChecks(.{ .allocator = allocator, .prefix = prefix }, &checks);

    output.plain("", .{});
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

// ── individual checks ────────────────────────────────────────────────
// `atomic.maltPrefix()` validates the prefix upstream, so checks treat
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
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}) catch {
        printCheck(name, .err_status, "Prefix path too long");
        return .err_status;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .err_status, "Cannot open database");
        return .err_status;
    };
    defer db.close();

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
        fs_compat.accessAbsolute(p, .{}) catch {
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
    const pid = lock_mod.LockFile.holderPid(lock_path);
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

fn checkExternalTool(_: CheckCtx, name: []const u8) CheckResult {
    // Row title is also the PATH binary to probe.
    if (externalToolAvailable(name)) {
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
    // First few as a hint so the user knows where to look.
    for (findings[0..@min(findings.len, 3)]) |f| {
        var line_buf: [1024]u8 = undefined;
        const reason = if (f.report.other_writable)
            "other-writable"
        else if (f.report.group_writable)
            "group-writable"
        else
            "wrong owner";
        const line = std.fmt.bufPrint(&line_buf, "        {s} ({s})", .{ f.path, reason }) catch continue;
        std.debug.print("{s}\n", .{line});
    }
    return .warn_status;
}

fn checkApiReachable(ctx: CheckCtx, name: []const u8) CheckResult {
    var http = client_mod.HttpClient.init(ctx.allocator);
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
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}) catch {
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
    var store_dir = fs_compat.openDirAbsolute(store_path, .{ .iterate = true }) catch {
        // store/ missing or unreadable — not an error, just skip.
        printCheck(name, .ok, null);
        return .ok;
    };
    defer store_dir.close();

    var orphan_count: u32 = 0;
    var iter = store_dir.iterate();
    while (iter.next() catch null) |entry| {
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
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}) catch {
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

    var missing_count: u32 = 0;
    while (stmt.step() catch false) {
        const cellar_raw = stmt.columnText(2) orelse continue;
        const cellar_path = std.mem.sliceTo(cellar_raw, 0);
        fs_compat.accessAbsolute(cellar_path, .{}) catch {
            missing_count += 1;
        };
    }

    if (missing_count == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} keg(s) in DB but missing on disk. Reinstall affected packages",
        .{missing_count},
    ) catch "Missing keg directories detected. Reinstall affected packages";
    printCheck(name, .err_status, msg);
    return .err_status;
}

fn checkBrokenSymlinks(ctx: CheckCtx, name: []const u8) CheckResult {
    const link_dirs = [_][]const u8{ "bin", "lib", "include", "share", "sbin" };
    var broken_count: u32 = 0;

    for (link_dirs) |subdir| {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ ctx.prefix, subdir }) catch continue;
        var dir = fs_compat.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var dir_iter = dir.iterate();
        while (dir_iter.next() catch null) |entry| {
            if (entry.kind == .sym_link) {
                _ = dir.statFile(entry.name) catch {
                    broken_count += 1;
                    continue;
                };
            }
        }
    }

    if (broken_count == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} broken symlink(s). Run: mt purge --housekeeping",
        .{broken_count},
    ) catch "Broken symlinks found. Run: mt purge --housekeeping";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

fn checkMachOPlaceholders(ctx: CheckCtx, name: []const u8) CheckResult {
    var cellar_root_buf: [512]u8 = undefined;
    const cellar_root = std.fmt.bufPrint(&cellar_root_buf, "{s}/Cellar", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };

    var cellar_dir = fs_compat.openDirAbsolute(cellar_root, .{ .iterate = true }) catch {
        // No Cellar yet — nothing to scan.
        printCheck(name, .ok, null);
        return .ok;
    };
    defer cellar_dir.close();

    var walker = cellar_dir.walk(ctx.allocator) catch {
        printCheck(name, .warn_status, "Could not walk Cellar tree");
        return .warn_status;
    };
    defer walker.deinit();

    var bad_count: u32 = 0;
    var first_bad_buf: [256]u8 = undefined;
    var first_bad_len: usize = 0;

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (hasUnpatchedPlaceholder(ctx.allocator, &cellar_dir, entry.path) catch false) {
            bad_count += 1;
            if (first_bad_len == 0) {
                const s = std.fmt.bufPrint(&first_bad_buf, "{s}", .{entry.path}) catch continue;
                first_bad_len = s.len;
            }
        }
    }

    if (bad_count == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} Mach-O file(s) with unpatched @@HOMEBREW_* placeholders (first: {s}). Reinstall the affected packages.",
        .{ bad_count, first_bad_buf[0..first_bad_len] },
    ) catch "Mach-O files with unpatched @@HOMEBREW_* placeholders found.";
    printCheck(name, .err_status, msg);
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
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer db.close();

    const missing = countMissingLocalSources(ctx.allocator, &db);
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
    allocator: std.mem.Allocator,
    base_dir: *fs_compat.Dir,
    rel_path: []const u8,
) !bool {
    var file = base_dir.openFile(rel_path, .{}) catch return false;
    defer file.close();

    var magic: [4]u8 = undefined;
    const n = file.readAll(&magic) catch return false;
    if (n < 4) return false;
    if (!parser.isMachO(&magic)) return false;

    // Re-read the full file — parser needs the whole buffer.
    const stat = file.stat() catch return false;
    if (stat.size > 512 * 1024 * 1024) return false; // skip pathologically large files
    const data = allocator.alloc(u8, stat.size) catch return false;
    defer allocator.free(data);

    const read = file.readAll(data) catch return false;
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
pub fn externalToolAvailable(tool: []const u8) bool {
    // Fast path for the common macOS case — avoids allocating a PATH
    // walk on every `mt doctor` invocation.
    var fast_buf: [64]u8 = undefined;
    const fast_path = std.fmt.bufPrint(&fast_buf, "/usr/bin/{s}", .{tool}) catch null;
    if (fast_path) |p| {
        if (fs_compat.accessAbsolute(p, .{})) |_| return true else |_| {}
    }

    const path_env = fs_compat.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, tool }) catch continue;
        if (fs_compat.accessAbsolute(full, .{})) |_| return true else |_| {}
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
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
) LocalSourceCensus {
    _ = allocator;
    var census: LocalSourceCensus = .{ .total = 0, .stale = 0 };
    var stmt = db.prepare("SELECT full_name FROM kegs WHERE tap = 'local';") catch return census;
    defer stmt.finalize();
    while (stmt.step() catch false) {
        const path_ptr = stmt.columnText(0) orelse continue;
        const path = std.mem.sliceTo(path_ptr, 0);
        census.total += 1;
        fs_compat.accessAbsolute(path, .{}) catch {
            census.stale += 1;
        };
    }
    return census;
}
