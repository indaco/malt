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
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_doctor_disp_{s}_{d}",
            .{ tag, ts },
            0,
        );
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

test "externalToolAvailable returns false when PATH does not contain the tool" {
    quiet();
    defer unquiet();
    try testing.expect(!doctor.externalToolAvailable(
        std.Options.debug_io,
        .empty,
        "tool-name-that-cannot-possibly-exist-on-any-machine-xyz123",
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

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        alpha 1.0\n") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        beta 2.0\n") != null);
    // Each package appears exactly once — no per-file rows leaking
    // back in via the grouping.
    const alpha_idx = std.mem.indexOf(u8, stderr_buf.items, "        alpha 1.0\n").?;
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items[alpha_idx + 1 ..], "        alpha 1.0\n") == null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        alpha/1.0/lib/libalpha.dylib") == null);
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
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        bin/ghost-default") == null);
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
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        alpha 1.0\n") == null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        beta 2.0\n") == null);
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
