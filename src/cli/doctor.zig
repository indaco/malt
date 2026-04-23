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
const printCheck = render.printCheck;

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "doctor")) return;

    const prefix = atomic.maltPrefix();

    // Check for --post-install-status flag
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--post-install-status")) {
            post_install.checkPostInstallStatus(allocator, prefix);
            return;
        }
    }

    var warnings: u32 = 0;
    var errors: u32 = 0;

    output.info("Running health checks...", .{});

    // 0. MALT_PREFIX visibility. atomic.maltPrefix() already aborts on a
    //    malformed env, so by this point the value is validated — doctor
    //    just surfaces it for operator context.
    {
        const is_default = std.mem.eql(u8, prefix, "/opt/malt");
        var pbuf: [600]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &pbuf,
            "{s} {s}",
            .{ prefix, if (is_default) "(default)" else "(from MALT_PREFIX)" },
        ) catch prefix;
        printCheck("MALT_PREFIX", .ok, detail);
    }

    // 1. SQLite integrity
    blk: {
        var db_path_buf: [512]u8 = undefined;
        const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch break :blk;
        var db = sqlite.Database.open(db_path) catch {
            printCheck("SQLite integrity", .err_status, "Cannot open database");
            errors += 1;
            break :blk;
        };
        defer db.close();

        schema.initSchema(&db) catch {};

        var stmt = db.prepare("PRAGMA integrity_check;") catch {
            printCheck("SQLite integrity", .err_status, "Cannot run integrity check");
            errors += 1;
            break :blk;
        };
        defer stmt.finalize();

        if (stmt.step() catch false) {
            const result = stmt.columnText(0);
            if (result) |r| {
                const txt = std.mem.sliceTo(r, 0);
                if (std.mem.eql(u8, txt, "ok")) {
                    printCheck("SQLite integrity", .ok, null);
                } else {
                    printCheck("SQLite integrity", .err_status, "Database may be corrupt");
                    errors += 1;
                }
            }
        }
    }

    // 2. Check required directories exist
    const dirs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "tmp", "cache", "db" };
    for (dirs) |dir| {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ prefix, dir }) catch continue;
        fs_compat.accessAbsolute(p, .{}) catch {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Missing directory: {s}", .{p}) catch continue;
            printCheck("Directory structure", .warn_status, msg);
            warnings += 1;
            continue;
        };
    }
    printCheck("Directory structure", .ok, null);

    // 3. Stale lock
    blk2: {
        var lock_buf: [512]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch break :blk2;
        const pid = lock_mod.LockFile.holderPid(lock_path);
        if (pid) |p| {
            // Check if PID is still running via kill(pid, 0)
            const is_alive = blk_alive: {
                if (std.c.kill(p, @enumFromInt(0)) != 0) break :blk_alive false;
                break :blk_alive true;
            };
            if (is_alive) {
                var pid_buf: [128]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "Lock held by active PID {d}", .{p}) catch "Lock held";
                printCheck("Stale lock", .warn_status, pid_str);
                warnings += 1;
            } else {
                var pid_buf: [128]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "Stale lock from dead PID {d}. Run: rm {s}", .{ p, lock_path }) catch "Stale lock detected";
                printCheck("Stale lock", .warn_status, pid_str);
                warnings += 1;
            }
        } else {
            printCheck("Stale lock", .ok, null);
        }
    }

    // 3b. External relocation tool — required by the Mach-O overflow
    //     fallback. Bottles whose load-command slots don't fit the new
    //     prefix get grown via this binary; without it, installs of
    //     those bottles fail. Realistic prefixes fit in-place for most
    //     bottles, so this is a warning (not an error) when absent.
    {
        const tool = patch.external_tool_name;
        if (externalToolAvailable(tool)) {
            printCheck(tool, .ok, null);
        } else {
            var et_buf: [256]u8 = undefined;
            const et_msg = std.fmt.bufPrint(
                &et_buf,
                "`{s}` not found on PATH. Install Xcode Command Line Tools: xcode-select --install",
                .{tool},
            ) catch "External relocation tool missing. Install Xcode Command Line Tools.";
            printCheck(tool, .warn_status, et_msg);
            warnings += 1;
        }
    }

    // 4. APFS volume
    if (clonefile.isApfs(prefix)) {
        printCheck("APFS volume", .ok, null);
    } else {
        printCheck("APFS volume", .warn_status, "Not on APFS — clonefile unavailable");
        warnings += 1;
    }

    // 4b. Prefix permissions — surfaces world/group-writable paths or
    //     unexpected ownership. Only meaningful on shared systems, but
    //     cheap to check and a clear signal when someone's chmod'd the
    //     tree.
    blk_perms: {
        const findings = perms_mod.walkPrefix(
            allocator,
            prefix,
            perms_mod.currentUid(),
            32, // cap so pathological trees don't balloon doctor's memory
        ) catch {
            printCheck("Prefix permissions", .warn_status, "Walk failed");
            warnings += 1;
            break :blk_perms;
        };
        defer perms_mod.freeFindings(allocator, findings);

        if (findings.len == 0) {
            printCheck("Prefix permissions", .ok, null);
        } else {
            var pm_buf: [256]u8 = undefined;
            const pm_msg = std.fmt.bufPrint(
                &pm_buf,
                "{d} path(s) with weak permissions under {s} — run `ls -l` or `chmod`",
                .{ findings.len, prefix },
            ) catch "Weak-permission paths under prefix";
            printCheck("Prefix permissions", .warn_status, pm_msg);
            warnings += 1;
            // First couple as a hint so the user knows where to look.
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
        }
    }

    // 5. API reachable
    blk3: {
        var http = client_mod.HttpClient.init(allocator);
        defer http.deinit();
        const status = http.head("https://formulae.brew.sh") catch {
            printCheck("API reachable", .warn_status, "Cannot reach formulae.brew.sh");
            warnings += 1;
            break :blk3;
        };
        if (status >= 200 and status < 400) {
            printCheck("API reachable", .ok, null);
        } else {
            printCheck("API reachable", .warn_status, "API returned error status");
            warnings += 1;
        }
    }

    // 6. Orphaned store entries — directories in store/ with no DB reference
    blk6: {
        var db_path_buf2: [512]u8 = undefined;
        const db_path2 = std.fmt.bufPrint(&db_path_buf2, "{s}/db/malt.db", .{prefix}) catch break :blk6;
        var db2 = sqlite.Database.open(db_path2) catch break :blk6;
        defer db2.close();

        var store_path_buf: [512]u8 = undefined;
        const store_path = std.fmt.bufPrint(&store_path_buf, "{s}/store", .{prefix}) catch break :blk6;
        var store_dir = fs_compat.openDirAbsolute(store_path, .{ .iterate = true }) catch {
            // store/ doesn't exist or can't be read — not an error, just skip
            printCheck("Orphaned store entries", .ok, null);
            break :blk6;
        };
        defer store_dir.close();

        var orphan_count: u32 = 0;
        var iter = store_dir.iterate();
        while (iter.next() catch null) |entry| {
            // Each entry in store/ is a sha256 directory; check if it exists in store_refs
            var stmt = db2.prepare(
                "SELECT refcount FROM store_refs WHERE store_sha256 = ?1;",
            ) catch continue;
            defer stmt.finalize();
            stmt.bindText(1, entry.name) catch continue;
            const has_row = stmt.step() catch false;
            if (has_row) {
                const refcount = stmt.columnInt(0);
                if (refcount <= 0) orphan_count += 1;
            } else {
                // Not in DB at all — orphaned
                orphan_count += 1;
            }
        }

        if (orphan_count > 0) {
            var msg_buf2: [256]u8 = undefined;
            const msg2 = std.fmt.bufPrint(&msg_buf2, "{d} orphaned store entry(s). Run: mt purge --store-orphans", .{orphan_count}) catch "Orphaned store entries found. Run: mt purge --store-orphans";
            printCheck("Orphaned store entries", .warn_status, msg2);
            warnings += 1;
        } else {
            printCheck("Orphaned store entries", .ok, null);
        }
    }

    // 7. Missing kegs — DB keg entries whose Cellar path doesn't exist on disk
    blk7: {
        var db_path_buf3: [512]u8 = undefined;
        const db_path3 = std.fmt.bufPrint(&db_path_buf3, "{s}/db/malt.db", .{prefix}) catch break :blk7;
        var db3 = sqlite.Database.open(db_path3) catch break :blk7;
        defer db3.close();

        var stmt = db3.prepare("SELECT name, version, cellar_path FROM kegs;") catch break :blk7;
        defer stmt.finalize();

        var missing_count: u32 = 0;
        while (stmt.step() catch false) {
            const cellar_raw = stmt.columnText(2) orelse continue;
            const cellar_path = std.mem.sliceTo(cellar_raw, 0);
            fs_compat.accessAbsolute(cellar_path, .{}) catch {
                missing_count += 1;
            };
        }

        if (missing_count > 0) {
            var msg_buf3: [256]u8 = undefined;
            const msg3 = std.fmt.bufPrint(&msg_buf3, "{d} keg(s) in DB but missing on disk. Reinstall affected packages", .{missing_count}) catch "Missing keg directories detected. Reinstall affected packages";
            printCheck("Missing kegs", .err_status, msg3);
            errors += 1;
        } else {
            printCheck("Missing kegs", .ok, null);
        }
    }

    // 8. Broken symlinks — walk bin/, lib/, include/, share/, sbin/ under prefix
    {
        const link_dirs = [_][]const u8{ "bin", "lib", "include", "share", "sbin" };
        var broken_count: u32 = 0;

        for (link_dirs) |subdir| {
            var dir_buf: [512]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ prefix, subdir }) catch continue;
            var dir = fs_compat.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();

            var dir_iter = dir.iterate();
            while (dir_iter.next() catch null) |entry| {
                if (entry.kind == .sym_link) {
                    // Try to stat the symlink target
                    _ = dir.statFile(entry.name) catch {
                        broken_count += 1;
                        continue;
                    };
                }
            }
        }

        if (broken_count > 0) {
            var msg_buf4: [256]u8 = undefined;
            const msg4 = std.fmt.bufPrint(&msg_buf4, "{d} broken symlink(s). Run: mt purge --housekeeping", .{broken_count}) catch "Broken symlinks found. Run: mt purge --housekeeping";
            printCheck("Broken symlinks", .warn_status, msg4);
            warnings += 1;
        } else {
            printCheck("Broken symlinks", .ok, null);
        }
    }

    // 8b. Unpatched Mach-O placeholders — scan Cellar/**/* for binaries whose
    //     LC_LOAD_DYLIB / LC_RPATH load commands still contain literal
    //     @@HOMEBREW_PREFIX@@ or @@HOMEBREW_CELLAR@@ tokens. These fail at
    //     runtime with `dyld: Symbol not found`.
    blk_mach: {
        var cellar_root_buf: [512]u8 = undefined;
        const cellar_root = std.fmt.bufPrint(&cellar_root_buf, "{s}/Cellar", .{prefix}) catch break :blk_mach;

        var cellar_dir = fs_compat.openDirAbsolute(cellar_root, .{ .iterate = true }) catch {
            // No Cellar yet — nothing to scan.
            printCheck("Mach-O placeholders", .ok, null);
            break :blk_mach;
        };
        defer cellar_dir.close();

        var walker = cellar_dir.walk(allocator) catch {
            printCheck("Mach-O placeholders", .warn_status, "Could not walk Cellar tree");
            warnings += 1;
            break :blk_mach;
        };
        defer walker.deinit();

        var bad_count: u32 = 0;
        var first_bad_buf: [256]u8 = undefined;
        var first_bad_len: usize = 0;

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (hasUnpatchedPlaceholder(allocator, &cellar_dir, entry.path) catch false) {
                bad_count += 1;
                if (first_bad_len == 0) {
                    const s = std.fmt.bufPrint(&first_bad_buf, "{s}", .{entry.path}) catch continue;
                    first_bad_len = s.len;
                }
            }
        }

        if (bad_count > 0) {
            var msg_buf_m: [512]u8 = undefined;
            const msg_m = std.fmt.bufPrint(
                &msg_buf_m,
                "{d} Mach-O file(s) with unpatched @@HOMEBREW_* placeholders (first: {s}). Reinstall the affected packages.",
                .{ bad_count, first_bad_buf[0..first_bad_len] },
            ) catch "Mach-O files with unpatched @@HOMEBREW_* placeholders found.";
            printCheck("Mach-O placeholders", .err_status, msg_m);
            errors += 1;
        } else {
            printCheck("Mach-O placeholders", .ok, null);
        }
    }

    // 9. Disk space — warn if < 1 GB free on the malt prefix volume
    blk9: {
        const posix_path = std.posix.toPosixPath(prefix) catch break :blk9;
        var stat_buf: mount_c.struct_statfs = undefined;
        const rc = mount_c.statfs(&posix_path, &stat_buf);
        if (rc != 0) {
            printCheck("Disk space", .warn_status, "Cannot determine free disk space");
            warnings += 1;
            break :blk9;
        }

        const free_bytes: u64 = @as(u64, @intCast(stat_buf.f_bavail)) * @as(u64, @intCast(stat_buf.f_bsize));
        const one_gb: u64 = 1024 * 1024 * 1024;
        if (free_bytes < one_gb) {
            const free_mb = free_bytes / (1024 * 1024);
            var msg_buf5: [256]u8 = undefined;
            const msg5 = std.fmt.bufPrint(&msg_buf5, "Only {d} MB free (< 1 GB). Free up disk space", .{free_mb}) catch "Low disk space (< 1 GB free)";
            printCheck("Disk space", .warn_status, msg5);
            warnings += 1;
        } else {
            printCheck("Disk space", .ok, null);
        }
    }

    // 10. Local-install source tracking — every keg with `tap='local'`
    //     remembers the absolute realpath of the `.rb` it was installed
    //     from. If that file has since been moved or deleted, the keg
    //     still works but `mt info <name>` will keep quoting a stale
    //     path. Advisory only.
    blk_local: {
        var db_path_buf: [512]u8 = undefined;
        const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch break :blk_local;
        var db = sqlite.Database.open(db_path) catch break :blk_local;
        defer db.close();

        const missing = countMissingLocalSources(allocator, &db);
        if (missing.total == 0) {
            printCheck("Local formula sources", .ok, null);
        } else if (missing.stale == 0) {
            printCheck("Local formula sources", .ok, null);
        } else {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &msg_buf,
                "{d}/{d} local keg(s) reference a .rb that no longer exists on disk. Run `mt info <name>` to see which.",
                .{ missing.stale, missing.total },
            ) catch "Some local kegs reference a .rb that no longer exists.";
            printCheck("Local formula sources", .warn_status, msg);
            warnings += 1;
        }
    }

    // Summary + exit code. Blank line first so the summary separates
    // visually from the check rows above it.
    output.plain("", .{});
    if (errors > 0) {
        output.err("{d} error(s), {d} warning(s)", .{ errors, warnings });
        std.process.exit(2);
    } else if (warnings > 0) {
        output.warn("{d} warning(s)", .{warnings});
        std.process.exit(1);
    } else {
        output.success("Your malt installation is healthy", .{});
    }
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
