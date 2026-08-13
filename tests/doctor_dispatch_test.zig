//! malt — `mt doctor` dispatch + walker integration tests.
//!
//! Drives `doctor.runChecks` with the production check table against a
//! scratch MALT_PREFIX so each individual `checkX` body lands on the
//! coverage map. `doctor.execute`'s exit-on-warn/err branches call
//! `std.process.exit` and cannot be exercised here, so the coverage
//! goal is the body of every check, not the dispatch tally.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const macho = std.macho;
const doctor = malt.doctor;
const sqlite = malt.sqlite;
const schema = malt.schema;
const store_mod = malt.store;
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const base = try test_io.uniqueTempPath(allocator, "doctor_disp", tag);
        defer allocator.free(base);
        const path = try allocator.dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const subs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "tmp", "cache", "db" };
        for (subs) |sd| {
            const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, sd });
            defer allocator.free(dir);
            try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        }
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

fn quiet() void {
    output.setQuiet(true);
}
fn unquiet() void {
    output.setQuiet(false);
}

// --- runChecks against the production table ----------------------------

test "runChecks walks the production check table on a clean prefix" {
    // The walker visits every check fn — the goal is coverage on each
    // body. Tally values aren't asserted: API-reachable depends on the
    // host network state and isn't deterministic in a test bench.
    var s = try Scratch.init(testing.allocator, "clean");
    defer s.deinit(testing.allocator);

    // Pre-init the DB so checkSqliteIntegrity hits the happy path.
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    quiet();
    defer unquiet();

    const tally = doctor.runChecks(.{
        .allocator = testing.allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    // The walker must always produce a tally — the values themselves are
    // host-dependent (network, APFS, install_name_tool on PATH).
    _ = tally;
}

test "runChecks surfaces a warning when a directory is missing" {
    // Carve away one of the structure dirs so checkDirectoryStructure
    // takes the warn branch.
    var s = try Scratch.init(testing.allocator, "missing_dir");
    defer s.deinit(testing.allocator);

    const opt_path = try std.fmt.allocPrint(testing.allocator, "{s}/opt", .{s.path});
    defer testing.allocator.free(opt_path);
    test_io.deleteTreeAbsolute(std.Options.debug_io, opt_path) catch {};

    quiet();
    defer unquiet();

    const tally = doctor.runChecks(.{
        .allocator = testing.allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    // Walker bumped at least one warning (the missing-dir).
    try testing.expect(tally.warnings >= 1);
}

test "runChecks surfaces an error when a keg row points at a missing Cellar dir" {
    var s = try Scratch.init(testing.allocator, "missing_keg");
    defer s.deinit(testing.allocator);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);

        // Cellar path that intentionally does not exist on disk.
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
            \\VALUES ('phantom', 'phantom', '9.9', 0, '', '/tmp/malt_phantom_does_not_exist');
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    quiet();
    defer unquiet();

    const tally = doctor.runChecks(.{
        .allocator = testing.allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    try testing.expect(tally.errors >= 1);
}

// --- in-flight downgrade (lock-aware checks) ---------------------------

fn severityOf(items: anytype, id: []const u8) ?doctor.CheckStatus {
    for (items) |f| if (std.mem.eql(u8, f.id, id)) return f.severity;
    return null;
}

test "operationInFlight: true only for a live lock holder" {
    var s = try Scratch.init(testing.allocator, "opinflight");
    defer s.deinit(testing.allocator);

    var lock_buf: [512]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{s.path});

    // No lock file → nothing in flight.
    try testing.expect(!doctor.operationInFlight(std.Options.debug_io, s.path));

    // A dead PID is a stale lock — must not read as in-flight.
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, lock_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "999999");
    }
    try testing.expect(!doctor.operationInFlight(std.Options.debug_io, s.path));

    // Our own (live) PID → an operation is in flight.
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, lock_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        var b: [16]u8 = undefined;
        try f.writeStreamingAll(std.Options.debug_io, try std.fmt.bufPrint(&b, "{d}", .{std.c.getpid()}));
    }
    try testing.expect(doctor.operationInFlight(std.Options.debug_io, s.path));
}

test "in-flight downgrade: all three fs-vs-DB checks become info only while an op is live" {
    var s = try Scratch.init(testing.allocator, "downgrade_all");
    defer s.deinit(testing.allocator);

    // missing keg: a kegs row whose cellar dir does not exist (err).
    // orphaned store: a store/<sha> dir with a refcount-0 ref row (warn).
    const orphan_sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
            \\VALUES ('phantom', 'phantom', '9.9', 0, '', '/tmp/malt_phantom_missing_inflight');
        );
        defer stmt.finalize();
        _ = try stmt.step();

        var store_dir_buf: [512]u8 = undefined;
        const store_dir = try std.fmt.bufPrint(&store_dir_buf, "{s}/store/{s}", .{ s.path, orphan_sha });
        try test_io.cwd().createDirPath(std.Options.debug_io, store_dir);
        var store = store_mod.Store.init(std.Options.debug_io, testing.allocator, &db, s.path);
        try store.incrementRef(orphan_sha);
        try store.decrementRef(orphan_sha);
    }
    // broken symlink: a dangling link under bin/ (warn).
    {
        var bin_buf: [512]u8 = undefined;
        const bin_dir = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{s.path});
        var bin = try test_io.openDirAbsolute(std.Options.debug_io, bin_dir, .{ .iterate = true });
        defer bin.close(std.Options.debug_io);
        try bin.symLink(std.Options.debug_io, "/tmp/malt_inflight_vanished_target", "ghost", .{});
    }

    quiet();
    defer unquiet();

    // Not in flight: each finding shows its real severity.
    {
        var walk = doctor.collectFindings(testing.allocator, .{
            .allocator = testing.allocator,
            .prefix = s.path,
            .io = std.Options.debug_io,
            .environ = .empty,
        }, &doctor.checks, true);
        defer walk.deinit();
        try testing.expectEqual(doctor.CheckStatus.err_status, severityOf(walk.findings(), "missing_kegs").?);
        try testing.expectEqual(doctor.CheckStatus.warn_status, severityOf(walk.findings(), "orphaned_store_entries").?);
        try testing.expectEqual(doctor.CheckStatus.warn_status, severityOf(walk.findings(), "broken_symlinks").?);
        try testing.expect(walk.tally.errors >= 1);
    }

    // In flight: all three are expected transients → info, no fault.
    {
        var walk = doctor.collectFindings(testing.allocator, .{
            .allocator = testing.allocator,
            .prefix = s.path,
            .io = std.Options.debug_io,
            .environ = .empty,
            .op_in_flight = true,
        }, &doctor.checks, true);
        defer walk.deinit();
        try testing.expectEqual(doctor.CheckStatus.info_status, severityOf(walk.findings(), "missing_kegs").?);
        try testing.expectEqual(doctor.CheckStatus.info_status, severityOf(walk.findings(), "orphaned_store_entries").?);
        try testing.expectEqual(doctor.CheckStatus.info_status, severityOf(walk.findings(), "broken_symlinks").?);
        try testing.expectEqual(@as(u32, 0), walk.tally.errors);
    }
}

// --- execute pre-loop branches -----------------------------------------

test "execute --help short-circuits before opening anything" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try doctor.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute --post-install-status returns without invoking the walker" {
    // No kegs → the loop body is skipped, but every line of the helper
    // up to the loop is exercised (db open, query prep, http init).
    var s = try Scratch.init(testing.allocator, "pi_status");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    quiet();
    defer unquiet();

    try doctor.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--post-install-status"});
}

// --- pure helpers ------------------------------------------------------

test "externalToolAvailable rejects a missing absolute tool path" {
    quiet();
    defer unquiet();
    try testing.expect(!doctor.externalToolAvailable(
        std.Options.debug_io,
        "/usr/bin/tool-name-that-cannot-possibly-exist-on-any-machine-xyz123",
    ));
}

test "countMissingLocalSources tallies missing source paths against tap='local' rows" {
    var s = try Scratch.init(testing.allocator, "local_sources");
    defer s.deinit(testing.allocator);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // Two `local` kegs: one with a present source path, one with a
    // ghost path. Only the ghost should bump `stale`.
    const present = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/here.rb", .{s.path});
    defer testing.allocator.free(present);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, present, .{ .truncate = true });
    f.close(std.Options.debug_io);

    {
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap)
            \\VALUES ('here', ?1, '1.0', 0, '', '/here', 'local');
        );
        defer stmt.finalize();
        try stmt.bindText(1, present);
        _ = try stmt.step();
    }
    {
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap)
            \\VALUES ('gone', '/tmp/malt_doctor_disp_ghost.rb', '1.0', 0, '', '/gone', 'local');
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    const census = doctor.countMissingLocalSources(std.Options.debug_io, &db);
    try testing.expectEqual(@as(u32, 2), census.total);
    try testing.expectEqual(@as(u32, 1), census.stale);
}

// --- --verbose enumeration for count-only checks -----------------------

fn writeMachOWithPath(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    embedded_path: []const u8,
) !void {
    // Mach-O 64 with a single LC_LOAD_DYLIB whose dylib name is
    // `embedded_path`. `doctor.checkMachOPlaceholders` parses load
    // command paths and flags any that still contain
    // `@@HOMEBREW_PREFIX@@` / `@@HOMEBREW_CELLAR@@`, so this fixture is
    // the minimum that exercises the check end-to-end.
    const lc_size = @sizeOf(macho.dylib_command);
    const name_offset: u32 = @intCast(lc_size);
    const path_len = embedded_path.len + 1; // NUL terminator
    const cmdsize: u32 = @intCast(lc_size + path_len);
    const cmdsize_aligned: u32 = (cmdsize + 7) & ~@as(u32, 7);

    const header_size = @sizeOf(macho.mach_header_64);
    const total_len = header_size + cmdsize_aligned;

    const buf = try allocator.alloc(u8, total_len);
    defer allocator.free(buf);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    header.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 1,
        .sizeofcmds = cmdsize_aligned,
    };

    const dy = std.mem.bytesAsValue(macho.dylib_command, buf[header_size..][0..lc_size]);
    dy.* = .{
        .cmd = .LOAD_DYLIB,
        .cmdsize = cmdsize_aligned,
        .dylib = .{
            .name = name_offset,
            .timestamp = 0,
            .current_version = 0,
            .compatibility_version = 0,
        },
    };
    @memcpy(buf[header_size + lc_size ..][0..embedded_path.len], embedded_path);
    // Trailing NUL is already zero from @memset; the +1 ensures
    // parser sees a terminated string.

    const f = try test_io.createFileAbsolute(std.Options.debug_io, file_path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, buf);
}

fn captureStderrAround(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    op: anytype,
) void {
    output.beginStderrCapture(allocator, buf);
    defer output.endStderrCapture();
    op();
}

test "checkMachOPlaceholders under --verbose lists each affected (package version)" {
    // The verbose list is keyed by the keg the user would reinstall —
    // package + version — not per file, because a single keg can
    // ship hundreds of bundled Mach-O files (Python site-packages
    // inside a meta-package, for example) and a flat enumeration
    // buries the actionable name in noise. The per-package file
    // count is also dropped: the user reinstalls the keg either way,
    // and a "(N file(s))" suffix turns out to be implementation
    // noise that distracts from the action.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "macho_verbose");
    defer s.deinit(allocator);

    // alpha 1.0: two bad files — should appear ONCE in the list.
    const dir1 = try std.fmt.allocPrint(allocator, "{s}/Cellar/alpha/1.0/lib", .{s.path});
    defer allocator.free(dir1);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir1);
    const bin1a = try std.fmt.allocPrint(allocator, "{s}/libalpha.dylib", .{dir1});
    defer allocator.free(bin1a);
    try writeMachOWithPath(allocator, bin1a, "@@HOMEBREW_PREFIX@@/lib/libalpha.dylib");
    const bin1b = try std.fmt.allocPrint(allocator, "{s}/libalpha-extra.dylib", .{dir1});
    defer allocator.free(bin1b);
    try writeMachOWithPath(allocator, bin1b, "@@HOMEBREW_PREFIX@@/lib/libalpha-extra.dylib");

    // beta 2.0: one bad file.
    const dir2 = try std.fmt.allocPrint(allocator, "{s}/Cellar/beta/2.0/bin", .{s.path});
    defer allocator.free(dir2);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir2);
    const bin2 = try std.fmt.allocPrint(allocator, "{s}/beta", .{dir2});
    defer allocator.free(bin2);
    try writeMachOWithPath(allocator, bin2, "@@HOMEBREW_CELLAR@@/beta/2.0/bin/beta");

    output.setVerbose(true);
    defer output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "    - alpha 1.0\n") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "    - beta 2.0\n") != null);
    // Each package appears exactly once — no per-file rows leaking
    // back in via the grouping.
    const alpha_idx = std.mem.indexOf(u8, stderr_buf.items, "    - alpha 1.0\n").?;
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items[alpha_idx + 1 ..], "    - alpha 1.0\n") == null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        alpha/1.0/lib/libalpha.dylib") == null);
    // Verbose redundantly shows every package below the headline,
    // so the (first: …) hint must drop out — the row above is
    // shorter without it.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "(first:") == null);
}

test "checkBrokenSymlinks without --verbose keeps the count summary only" {
    // Default-mode pinning so the verbose branch cannot leak detail
    // rows when the user did not ask for them.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "symlinks_default");
    defer s.deinit(allocator);

    const link_path = try std.fmt.allocPrint(allocator, "{s}/bin/ghost-default", .{s.path});
    defer allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, "/tmp/malt_doctor_disp_default_symlink_target_dne", link_path, .{});

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "1 broken symlink(s)") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "    - bin/ghost-default") == null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Run: mt cleanup") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "purge --housekeeping") == null);
}

test "checkMachOPlaceholders without --verbose keeps the count + first-hint summary only" {
    // Pin the default-mode output so the verbose branch does not
    // accidentally leak detail lines into non-verbose runs.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "macho_default");
    defer s.deinit(allocator);

    const dir1 = try std.fmt.allocPrint(allocator, "{s}/Cellar/alpha/1.0/lib", .{s.path});
    defer allocator.free(dir1);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir1);
    const bin1 = try std.fmt.allocPrint(allocator, "{s}/libalpha.dylib", .{dir1});
    defer allocator.free(bin1);
    try writeMachOWithPath(allocator, bin1, "@@HOMEBREW_PREFIX@@/lib/libalpha.dylib");

    const dir2 = try std.fmt.allocPrint(allocator, "{s}/Cellar/beta/2.0/bin", .{s.path});
    defer allocator.free(dir2);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir2);
    const bin2 = try std.fmt.allocPrint(allocator, "{s}/beta", .{dir2});
    defer allocator.free(bin2);
    try writeMachOWithPath(allocator, bin2, "@@HOMEBREW_CELLAR@@/beta/2.0/bin/beta");

    // Explicit reset so a leaky test earlier in the run does not
    // poison this one.
    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    // Headline counts PACKAGES, not files: the user reinstalls the
    // keg either way, so the package count is the actionable number.
    // First-package hint stays (helps users who don't want to re-run
    // with --verbose). No detail rows in default mode.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "2 package(s)") != null);
    // FS walk order isn't guaranteed to be alphabetical on every
    // host, so accept either of the two seeded kegs as the first
    // example — the contract is "name a real package", not "name
    // this specific package".
    const has_alpha_first = std.mem.indexOf(u8, stderr_buf.items, "(first: alpha 1.0)") != null;
    const has_beta_first = std.mem.indexOf(u8, stderr_buf.items, "(first: beta 2.0)") != null;
    try testing.expect(has_alpha_first or has_beta_first);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "    - alpha 1.0\n") == null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "    - beta 2.0\n") == null);
}

test "checkBrokenSymlinks under --verbose lists every broken symlink path" {
    // Two link-dir entries (bin/ and lib/) each pointing at targets
    // that do not exist. The check counts both today; verbose must
    // surface the symlink paths so the user can `ls -l` them
    // directly.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "symlinks_verbose");
    defer s.deinit(allocator);

    const link_a_path = try std.fmt.allocPrint(allocator, "{s}/bin/ghost-a", .{s.path});
    defer allocator.free(link_a_path);
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, "/tmp/malt_doctor_disp_ghost_target_does_not_exist_a", link_a_path, .{});

    const link_b_path = try std.fmt.allocPrint(allocator, "{s}/lib/ghost-b", .{s.path});
    defer allocator.free(link_b_path);
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, "/tmp/malt_doctor_disp_ghost_target_does_not_exist_b", link_b_path, .{});

    output.setVerbose(true);
    defer output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "bin/ghost-a") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "lib/ghost-b") != null);
}

test "after the check loop, a dim --verbose hint fires when offenders exist and --verbose is off" {
    // Mach-O placeholder seeded so the check has at least one
    // offender to enumerate; with --verbose OFF the user only sees
    // the count + first hint. The new tail-of-output nudge points
    // them at --verbose so they can find the rest without having
    // to know about the flag.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "verbose_hint");
    defer s.deinit(allocator);

    const dir1 = try std.fmt.allocPrint(allocator, "{s}/Cellar/alpha/1.0/lib", .{s.path});
    defer allocator.free(dir1);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir1);
    const bin1 = try std.fmt.allocPrint(allocator, "{s}/libalpha.dylib", .{dir1});
    defer allocator.free(bin1);
    try writeMachOWithPath(allocator, bin1, "@@HOMEBREW_PREFIX@@/lib/libalpha.dylib");

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.resetVerboseHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitVerboseHintIfNeeded();

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "--verbose") != null);
}

test "emitVerboseHintIfNeeded stays silent when --verbose is already active" {
    // Re-running with --verbose surfaces the list directly, so the
    // nudge would be redundant. Pin it as silent in that case.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "verbose_hint_on");
    defer s.deinit(allocator);

    const dir1 = try std.fmt.allocPrint(allocator, "{s}/Cellar/alpha/1.0/lib", .{s.path});
    defer allocator.free(dir1);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir1);
    const bin1 = try std.fmt.allocPrint(allocator, "{s}/libalpha.dylib", .{dir1});
    defer allocator.free(bin1);
    try writeMachOWithPath(allocator, bin1, "@@HOMEBREW_PREFIX@@/lib/libalpha.dylib");

    output.setVerbose(true);
    defer output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.resetVerboseHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitVerboseHintIfNeeded();

    // The "Run …" prefix on the existing fix hint (e.g.
    // `Run: mt cleanup`) is unrelated; assert the nudge-specific
    // phrase is absent.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "for the full list") == null);
}

test "emitVerboseHintIfNeeded stays silent on a clean prefix" {
    // No enumerable offenders → no nudge. Otherwise we'd train
    // users to ignore it as noise on healthy systems.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "verbose_hint_clean");
    defer s.deinit(allocator);

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.resetVerboseHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitVerboseHintIfNeeded();

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "for the full list") == null);
}

test "checkPrefixPermissions hint lines flow through stderr capture so they share the verbose-list look" {
    // Pre-this PR, the first-3 hint rows used `std.debug.print` and
    // bypassed the output capture, so tests couldn't pin them and
    // they were styled differently from every other detail line.
    // Both should now route through `output.writeStderrAll` (the
    // same path used by Mach-O / symlinks / kegs verbose lists),
    // putting the bytes into the capture buffer.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "perms_hints");
    defer s.deinit(allocator);

    // Plant a path with a group-writable bit so the perms walker
    // reports it. Bit 0o020 == group-write. UID match keeps the
    // walker focused on the perms axis.
    const weak = try std.fmt.allocPrint(allocator, "{s}/Cellar/weak", .{s.path});
    defer allocator.free(weak);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, weak, .{ .truncate = true });
    f.close(std.Options.debug_io);
    _ = std.c.chmod(@ptrCast(weak.ptr), 0o664);

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    // Either the path landed in the capture (new behaviour) or the
    // perms walker on this host didn't trip (CI without group bits);
    // accept both, but if the row appears it must have flowed
    // through the capture, not the bypass.
    if (std.mem.indexOf(u8, stderr_buf.items, "Prefix permissions") != null and
        std.mem.indexOf(u8, stderr_buf.items, "weak permissions") != null)
    {
        try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Cellar/weak") != null);
    }
}

test "checkMissingKegs under --verbose lists each missing (name version) pair" {
    // Two keg rows pointing at Cellar paths that don't exist. The
    // user needs the names to decide which packages to reinstall —
    // count alone forces them to inspect the DB by hand.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "missing_keg_verbose");
    defer s.deinit(allocator);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
            \\VALUES
            \\  ('phantom-a', 'phantom-a', '9.9', 0, '', '/tmp/malt_doctor_disp_phantom_a_dne'),
            \\  ('phantom-b', 'phantom-b', '1.0', 0, '', '/tmp/malt_doctor_disp_phantom_b_dne');
        );
    }

    output.setVerbose(true);
    defer output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "phantom-a 9.9") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "phantom-b 1.0") != null);
}

// --- --fix hint emission ----------------------------------------------

test "fix hint fires when a broken symlink is present and --fix is off" {
    // Broken symlink is a safe-class condition `--fix` can remove,
    // so the dim nudge after the summary helps a user who doesn't
    // know the flag exists.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "fix_hint_symlink");
    defer s.deinit(allocator);

    const link_path = try std.fmt.allocPrint(allocator, "{s}/bin/ghost-fix-hint", .{s.path});
    defer allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(
        std.Options.debug_io,
        "/tmp/malt_doctor_disp_fix_hint_ghost_target_dne",
        link_path,
        .{},
    );

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.resetFixHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitFixHintIfNeeded(false);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "--fix") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "safe-class fixes") != null);
}

test "fix hint fires when an orphaned store entry is present" {
    // Plant a store/<sha> directory whose store_refs refcount has dropped
    // to 0 — a true orphan; checkOrphanedStore counts it and arms the hint.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "fix_hint_orphan");
    defer s.deinit(allocator);

    const sha = "0000000000000000000000000000000000000000000000000000000000000000";
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        var store = store_mod.Store.init(std.Options.debug_io, allocator, &db, s.path);
        try store.incrementRef(sha);
        try store.decrementRef(sha);
    }

    const orphan = try std.fmt.allocPrint(allocator, "{s}/store/{s}", .{ s.path, sha });
    defer allocator.free(orphan);
    try test_io.cwd().createDirPath(std.Options.debug_io, orphan);

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.resetFixHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitFixHintIfNeeded(false);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "--fix") != null);
}

test "fix hint stays silent when --fix was already passed" {
    // The user already knows about the flag; re-suggesting it after
    // the summary is noise.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "fix_hint_already_on");
    defer s.deinit(allocator);

    const link_path = try std.fmt.allocPrint(allocator, "{s}/bin/ghost-fix-already", .{s.path});
    defer allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(
        std.Options.debug_io,
        "/tmp/malt_doctor_disp_fix_already_ghost_target_dne",
        link_path,
        .{},
    );

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.resetFixHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitFixHintIfNeeded(true);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "safe-class fixes") == null);
}

test "fix hint stays silent on a clean prefix" {
    // No fixable conditions → no nudge. Otherwise we'd train users
    // to ignore it as noise on healthy systems.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "fix_hint_clean");
    defer s.deinit(allocator);

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.resetFixHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitFixHintIfNeeded(false);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "safe-class fixes") == null);
}

test "fix hint stays silent when only manual-class issues are present" {
    // A missing keg is manual-class (reinstall); the inline check
    // row already says so. Suggesting --fix would just route the
    // user to a near-duplicate hint.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "fix_hint_manual_only");
    defer s.deinit(allocator);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
            \\VALUES ('phantom-fix-hint', 'phantom-fix-hint', '9.9', 0, '', '/tmp/malt_doctor_disp_phantom_fix_hint_dne');
        );
    }

    output.setVerbose(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.resetFixHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitFixHintIfNeeded(false);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "safe-class fixes") == null);
}

test "resetFixHint clears state between runs so a clean walker stays silent" {
    // Without the reset, an armed flag from a prior run on the same
    // process would leak into the next call. Pin the contract here.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "fix_hint_reset");
    defer s.deinit(allocator);

    const link_path = try std.fmt.allocPrint(allocator, "{s}/bin/ghost-fix-reset", .{s.path});
    defer allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(
        std.Options.debug_io,
        "/tmp/malt_doctor_disp_fix_reset_ghost_target_dne",
        link_path,
        .{},
    );

    output.setVerbose(false);

    // First walk arms the flag.
    doctor.resetFixHint();
    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);

    // Now remove the offender and reset; the next walk has nothing
    // to find, and the hint must not fire.
    try test_io.cwd().deleteFile(std.Options.debug_io, link_path);
    doctor.resetFixHint();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    _ = doctor.runChecks(.{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks);
    doctor.emitFixHintIfNeeded(false);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "safe-class fixes") == null);
}
