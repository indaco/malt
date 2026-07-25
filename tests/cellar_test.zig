//! malt — cellar module tests
//! Tests for keg materialization, placeholder substitution, and directory flattening.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const cellar_mod = @import("malt").cellar;
const patcher = @import("malt").patcher;
const parser = @import("malt").parser;
const install_args = @import("malt").install_args;

// libc setenv/unsetenv — available because tests link with libc
const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn setMaltPrefix(prefix: [:0]const u8) [:0]const u8 {
    const old = test_io.getenv("MALT_PREFIX") orelse "";
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    return old;
}

fn restoreMaltPrefix(old: [:0]const u8) void {
    if (old.len == 0) {
        _ = c.unsetenv("MALT_PREFIX");
    } else {
        _ = c.setenv("MALT_PREFIX", old.ptr, 1);
    }
}

fn createTestDir(allocator: std.mem.Allocator) ![:0]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/malt_cellar_test_{x}", .{test_io.randomInt(std.Options.debug_io, u64)});
    defer allocator.free(path);
    const z = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(z, path);
    try test_io.makeDirAbsolute(std.Options.debug_io, z);
    return z;
}

fn createBottleFixture(allocator: std.mem.Allocator, prefix: []const u8, sha: []const u8, name: []const u8, ver_dir: []const u8) !void {
    const keg = try std.fmt.allocPrint(allocator, "{s}/store/{s}/{s}/{s}", .{ prefix, sha, name, ver_dir });
    defer allocator.free(keg);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg);

    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{keg});
    defer allocator.free(bin_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, bin_dir);

    const script_path = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{keg});
    defer allocator.free(script_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, script_path, .{});
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\nprefix=@@HOMEBREW_PREFIX@@\ncellar=@@HOMEBREW_CELLAR@@\necho $prefix\n");
        f.close(std.Options.debug_io);
    }

    const lib_dir = try std.fmt.allocPrint(allocator, "{s}/lib", .{keg});
    defer allocator.free(lib_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, lib_dir);

    const pc_path = try std.fmt.allocPrint(allocator, "{s}/lib/test.pc", .{keg});
    defer allocator.free(pc_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, pc_path, .{});
        try f.writeStreamingAll(std.Options.debug_io, "prefix=@@HOMEBREW_PREFIX@@\nlibdir=${prefix}/lib\ncellar=@@HOMEBREW_CELLAR@@\n");
        f.close(std.Options.debug_io);
    }
}

fn setupMaltDirs(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const dirs = [_][]const u8{ "store", "Cellar", "opt", "bin", "lib" };
    for (dirs) |d| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, d });
        defer allocator.free(p);
        test_io.cwd().createDirPath(std.Options.debug_io, p) catch {};
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try test_io.openFileAbsolute(std.Options.debug_io, path, .{});
    defer file.close(std.Options.debug_io);
    const stat = try file.stat(std.Options.debug_io);
    const buf = try allocator.alloc(u8, stat.size);
    const n = try file.readPositionalAll(std.Options.debug_io, buf, 0);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Keg directory flattening (revision suffix handling)
// ---------------------------------------------------------------------------

test "materialize handles version with revision suffix" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "abc123", "pcre2", "10.47_1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "abc123",
        "pcre2",
        "10.47",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    // Verify flat structure: Cellar/pcre2/10.47/bin/hello should exist
    var bin_buf: [512]u8 = undefined;
    const bin_path = try std.fmt.bufPrint(&bin_buf, "{s}/bin/hello", .{keg.path});
    try test_io.accessAbsolute(std.Options.debug_io, bin_path, .{});

    // Verify no extra nesting: Cellar/pcre2/10.47/pcre2/ should NOT exist
    var nested_buf: [512]u8 = undefined;
    const nested_path = try std.fmt.bufPrint(&nested_buf, "{s}/pcre2", .{keg.path});
    const nested_exists = blk: {
        test_io.accessAbsolute(std.Options.debug_io, nested_path, .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(!nested_exists);
}

test "materialize replaces a pre-existing Cellar/{name}/{version} directory (gh#85)" {
    // Regression: clonefile(2) refuses to write into an existing directory
    // (EEXIST), so a leftover keg from a SIGKILLed prior run, a partial
    // warm-path failure, or a drop-in Homebrew prefix would surface as
    // "CloneFailed (APFS clonefile or copy failed)" on every retry. The
    // cold path now wipes cellar_path before the clone, mirroring the
    // warm path's existing pre-wipe.
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "stale123", "lld@21", "21.1.8_1");

    // Plant a stale keg at the exact destination malt is about to write.
    const stale_keg = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/Cellar/lld@21/21.1.8_1",
        .{prefix},
    );
    defer testing.allocator.free(stale_keg);
    try test_io.cwd().createDirPath(std.Options.debug_io, stale_keg);
    const stale_file = try std.fmt.allocPrint(testing.allocator, "{s}/STALE_FILE", .{stale_keg});
    defer testing.allocator.free(stale_file);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, stale_file, .{});
        try f.writeStreamingAll(std.Options.debug_io, "stale\n");
        f.close(std.Options.debug_io);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "stale123",
        "lld@21",
        "21.1.8_1",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    // STALE_FILE must be gone: the cold path wiped the dir before clonefile.
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, stale_file, .{}));

    // Fresh content from the bottle is in place.
    var bin_buf: [512]u8 = undefined;
    const bin_path = try std.fmt.bufPrint(&bin_buf, "{s}/bin/hello", .{keg.path});
    try test_io.accessAbsolute(std.Options.debug_io, bin_path, .{});
}

test "materialize handles exact version match (no revision)" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "def456", "jq", "1.7.1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "def456",
        "jq",
        "1.7.1",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    var buf: [512]u8 = undefined;
    const bin_path = try std.fmt.bufPrint(&buf, "{s}/bin/hello", .{keg.path});
    try test_io.accessAbsolute(std.Options.debug_io, bin_path, .{});
}

// ---------------------------------------------------------------------------
// Placeholder substitution for relocatable bottles
// ---------------------------------------------------------------------------

test "placeholder substitution runs for relocatable bottles" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "rel123", "stow", "2.4.1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "rel123",
        "stow",
        "2.4.1",
        ":any", // relocatable — the bug scenario
    );
    defer testing.allocator.free(keg.path);

    var script_buf: [512]u8 = undefined;
    const script_path = try std.fmt.bufPrint(&script_buf, "{s}/bin/hello", .{keg.path});
    const content = try readFile(testing.allocator, script_path);
    defer testing.allocator.free(content);

    // Must NOT contain any unreplaced @@...@@ tokens
    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_PREFIX@@") == null);
    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_CELLAR@@") == null);

    // Must contain the actual malt prefix
    try testing.expect(std.mem.indexOf(u8, content, prefix) != null);
}

test "placeholder substitution replaces multiple tokens in single file" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "multi123", "pkg", "1.0");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "multi123",
        "pkg",
        "1.0",
        "",
    );
    defer testing.allocator.free(keg.path);

    var pc_buf: [512]u8 = undefined;
    const pc_path = try std.fmt.bufPrint(&pc_buf, "{s}/lib/test.pc", .{keg.path});
    const content = try readFile(testing.allocator, pc_path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_PREFIX@@") == null);
    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_CELLAR@@") == null);

    var cellar_str_buf: [256]u8 = undefined;
    const expected_cellar = try std.fmt.bufPrint(&cellar_str_buf, "{s}/Cellar", .{prefix});
    try testing.expect(std.mem.indexOf(u8, content, expected_cellar) != null);
}

test "files with no placeholders are left unchanged" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/clean123/noop/1.0", .{prefix});
    defer testing.allocator.free(keg_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg_dir});
    defer testing.allocator.free(bin_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, bin_dir);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/bin/clean", .{keg_dir});
    defer testing.allocator.free(file_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, file_path, .{});
        try f.writeStreamingAll(std.Options.debug_io, "#!/bin/sh\necho hello world\n");
        f.close(std.Options.debug_io);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "clean123",
        "noop",
        "1.0",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    var buf: [512]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&buf, "{s}/bin/clean", .{keg.path});
    const content = try readFile(testing.allocator, out_path);
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("#!/bin/sh\necho hello world\n", content);
}

test "binary files are skipped by text patching without error" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/bin123/binpkg/1.0", .{prefix});
    defer testing.allocator.free(keg_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_dir);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg_dir});
    defer testing.allocator.free(bin_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, bin_dir);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/bin/fakemach", .{keg_dir});
    defer testing.allocator.free(file_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, file_path, .{});
        try f.writeStreamingAll(std.Options.debug_io, "\xcf\xfa\xed\xfe\x00\x00\x00@@HOMEBREW_PREFIX@@\x00more\x00binary");
        f.close(std.Options.debug_io);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "bin123",
        "binpkg",
        "1.0",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    var buf: [512]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&buf, "{s}/bin/fakemach", .{keg.path});
    const content = try readFile(testing.allocator, out_path);
    defer testing.allocator.free(content);

    // Text patcher skips binary files (null bytes detected), so placeholder remains
    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_PREFIX@@") != null);
}

// ---------------------------------------------------------------------------
// patchTextFiles direct test
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Prefix sanity cap (upper guardrail, no longer a Mach-O in-place budget)
// ---------------------------------------------------------------------------

test "checkPrefixSane accepts realistic MALT_PREFIX values" {
    try install_args.checkPrefixSane("/opt/malt");
    try install_args.checkPrefixSane("/opt/homebrew");
    try install_args.checkPrefixSane("/tmp/mt");
    try install_args.checkPrefixSane("/tmp/mt_tahoe"); // 13 bytes — formerly rejected
    try install_args.checkPrefixSane("/var/folders/abc/def/ghi/jkl/mno/prefix");
}

test "checkPrefixSane rejects absurd prefixes at the 256-byte cap" {
    const huge = "/" ++ "x" ** 512;
    try testing.expectError(error.PrefixAbsurd, install_args.checkPrefixSane(huge));
}

// ---------------------------------------------------------------------------
// CellarError.describeError covers every tag
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Relocated-store cache integration
// ---------------------------------------------------------------------------

const relocated_mod = @import("malt").relocated_store;

const valid_test_sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "materializeWithCellar short-circuits when the relocated cache has the sha" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    try setupMaltDirs(testing.allocator, prefix);

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    // Pre-stage the relocated cache: write a fixture keg directly under
    // store-relocated/<sha>/ via a temp Cellar entry + relocated.save.
    try createBottleFixture(testing.allocator, prefix, "stub-store", "cached", "1.0");
    const keg_pre = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "stub-store",
        "cached",
        "1.0",
        ":any",
    );
    testing.allocator.free(keg_pre.path);
    try relocated_mod.save(std.Options.debug_io, testing.allocator, prefix, valid_test_sha, "cached", "1.0");
    // Wipe the just-built Cellar entry — the cache must rebuild it.
    const cellar_keg_path = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/cached/1.0", .{prefix});
    defer testing.allocator.free(cellar_keg_path);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, cellar_keg_path);

    // No `store/<sha>/` exists for `valid_test_sha` — the only way this
    // call can succeed is via the cache short-circuit.
    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "cached",
        "1.0",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    var buf: [512]u8 = undefined;
    const bin_path = try std.fmt.bufPrint(&buf, "{s}/bin/hello", .{keg.path});
    const content = try readFile(testing.allocator, bin_path);
    defer testing.allocator.free(content);
    // Cache-hit short-circuit skips placeholder substitution, so the
    // cached file content is preserved verbatim. The cache was populated
    // from a successful pipeline run, so placeholders are already gone.
    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_PREFIX@@") == null);
}

test "materializeWithCellar populates the relocated cache after a cold install" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, valid_test_sha, "snap", "0.1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    try testing.expect(!relocated_mod.has(std.Options.debug_io, prefix, valid_test_sha));
    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "snap",
        "0.1",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    // Snapshot must run on the success path so warm reinstalls hit it.
    try testing.expect(relocated_mod.has(std.Options.debug_io, prefix, valid_test_sha));
}

// ---------------------------------------------------------------------------
// Post-relocation keg verification
// ---------------------------------------------------------------------------

/// Minimal Mach-O 64 with two LC_RPATH slots. Enough for the keg walk to
/// parse; the fixtures below vary the two paths to break one invariant each.
fn buildRpathMachO(
    allocator: std.mem.Allocator,
    path1: []const u8,
    cmdsize1: u32,
    path2: []const u8,
    cmdsize2: u32,
) ![]u8 {
    const macho = std.macho;
    const header_size = @sizeOf(macho.mach_header_64);
    const path_off: u32 = @sizeOf(macho.rpath_command);
    const buf = try allocator.alloc(u8, header_size + cmdsize1 + cmdsize2);
    @memset(buf, 0);

    const hdr = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    hdr.* = .{ .magic = macho.MH_MAGIC_64, .ncmds = 2, .sizeofcmds = cmdsize1 + cmdsize2 };

    const off1 = header_size;
    const rp1 = std.mem.bytesAsValue(macho.rpath_command, buf[off1..][0..path_off]);
    rp1.* = .{ .cmd = .RPATH, .cmdsize = cmdsize1, .path = path_off };
    @memcpy(buf[off1 + path_off ..][0..path1.len], path1);

    const off2 = header_size + cmdsize1;
    const rp2 = std.mem.bytesAsValue(macho.rpath_command, buf[off2..][0..path_off]);
    rp2.* = .{ .cmd = .RPATH, .cmdsize = cmdsize2, .path = path_off };
    @memcpy(buf[off2 + path_off ..][0..path2.len], path2);

    return buf;
}

fn writeBinary(path: []const u8, bytes: []const u8) !void {
    const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, bytes);
}

fn fileExists(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !bool {
    const p = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(p);
    test_io.accessAbsolute(std.Options.debug_io, p, .{}) catch return false;
    return true;
}

test "materializeWithCellar rebuilds a cached keg whose binary would abort dyld" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, valid_test_sha, "poisoned", "1.0");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    // Cold install populates the relocated cache.
    const first = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "poisoned",
        "1.0",
        ":any",
    );
    testing.allocator.free(first.path);
    try testing.expect(relocated_mod.has(std.Options.debug_io, prefix, valid_test_sha));

    // Poison the snapshot the way a pre-fix relocation did: a binary carrying
    // the same LC_RPATH twice. The cache key is untouched, so without
    // verification this keg is served verbatim forever.
    const bad = try buildRpathMachO(testing.allocator, "/opt/malt/lib", 32, "/opt/malt/lib", 32);
    defer testing.allocator.free(bad);
    const cached_bin = try std.fmt.allocPrint(testing.allocator, "{s}/store-relocated/v{d}/{s}/bin/bad", .{ prefix, relocated_mod.RELOC_LOGIC_VERSION, valid_test_sha });
    defer testing.allocator.free(cached_bin);
    try writeBinary(cached_bin, bad);

    // Drop the mark so the entry looks like one a pre-verification malt wrote
    // — the only shape that can carry an unchecked keg.
    const mark = try std.fmt.allocPrint(testing.allocator, "{s}/store-relocated/v{d}/{s}.verified", .{ prefix, relocated_mod.RELOC_LOGIC_VERSION, valid_test_sha });
    defer testing.allocator.free(mark);
    try test_io.deleteFileAbsolute(std.Options.debug_io, mark);

    // Force the warm path: no Cellar keg, cache entry present.
    const cellar_keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/poisoned/1.0", .{prefix});
    defer testing.allocator.free(cellar_keg);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, cellar_keg);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "poisoned",
        "1.0",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    // Self-healed: the install succeeded from the store, not the cache, so the
    // duplicate-rpath binary is absent from the keg the user actually gets.
    try testing.expect(!try fileExists(testing.allocator, "{s}/bin/bad", .{keg.path}));
    // ...and the poisoned entry was evicted, so the re-saved snapshot is clean.
    try testing.expect(!try fileExists(testing.allocator, "{s}/store-relocated/v{d}/{s}/bin/bad", .{ prefix, relocated_mod.RELOC_LOGIC_VERSION, valid_test_sha }));
}

test "materializeWithCellar trusts a snapshot it already verified" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, valid_test_sha, "trusted", "1.0");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const first = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "trusted",
        "1.0",
        ":any",
    );
    testing.allocator.free(first.path);
    try testing.expect(relocated_mod.isVerified(std.Options.debug_io, prefix, valid_test_sha));

    // Deliberate boundary: a marked snapshot is restored without re-walking it,
    // which is what keeps warm reinstalls free. Tampering after the fact is out
    // of scope — this pins the skip so it cannot be dropped by accident.
    const bad = try buildRpathMachO(testing.allocator, "/opt/malt/lib", 32, "/opt/malt/lib", 32);
    defer testing.allocator.free(bad);
    const cached_bin = try std.fmt.allocPrint(testing.allocator, "{s}/store-relocated/v{d}/{s}/bin/bad", .{ prefix, relocated_mod.RELOC_LOGIC_VERSION, valid_test_sha });
    defer testing.allocator.free(cached_bin);
    try writeBinary(cached_bin, bad);

    const cellar_keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/trusted/1.0", .{prefix});
    defer testing.allocator.free(cellar_keg);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, cellar_keg);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "trusted",
        "1.0",
        ":any",
    );
    defer testing.allocator.free(keg.path);

    try testing.expect(try fileExists(testing.allocator, "{s}/bin/bad", .{keg.path}));
    try testing.expect(relocated_mod.has(std.Options.debug_io, prefix, valid_test_sha));
}

test "materializeWithCellar refuses a keg whose binary kept an unsubstituted placeholder" {
    // Root bypasses POSIX mode bits, so the read-only file below would be
    // patched normally and the skip this test relies on could not fire.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, valid_test_sha, "unpatched", "2.0");

    // A read-only binary makes the patch walk fail its write and skip the file,
    // which is exactly how a placeholder survives relocation today. The slot is
    // wide enough that substitution would otherwise fit in place.
    const bytes = try buildRpathMachO(testing.allocator, "@@HOMEBREW_PREFIX@@/lib", 96, "/opt/malt/opt/x/lib", 40);
    defer testing.allocator.free(bytes);
    const store_bin = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}/unpatched/2.0/bin/stuck", .{ prefix, valid_test_sha });
    defer testing.allocator.free(store_bin);
    try writeBinary(store_bin, bytes);
    {
        const f = try test_io.openFileAbsolute(std.Options.debug_io, store_bin, .{});
        defer f.close(std.Options.debug_io);
        try f.setPermissions(std.Options.debug_io, std.Io.File.Permissions.fromMode(0o444));
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    try testing.expectError(cellar_mod.CellarError.VerifyFailed, cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "unpatched",
        "2.0",
        ":any",
    ));

    // A keg that cannot load is not left installed, and never gets cached.
    try testing.expect(!try fileExists(testing.allocator, "{s}/Cellar/unpatched/2.0", .{prefix}));
    try testing.expect(!relocated_mod.has(std.Options.debug_io, prefix, valid_test_sha));
}

test "describeError returns a non-empty, distinct message for every CellarError" {
    const cases = [_]cellar_mod.CellarError{
        cellar_mod.CellarError.CloneFailed,
        cellar_mod.CellarError.PatchFailed,
        cellar_mod.CellarError.PathTooLong,
        cellar_mod.CellarError.InsufficientHeaderPad,
        cellar_mod.CellarError.InstallNameToolMissing,
        cellar_mod.CellarError.CodesignFailed,
        cellar_mod.CellarError.VerifyFailed,
        cellar_mod.CellarError.RemoveFailed,
        cellar_mod.CellarError.OutOfMemory,
    };
    var seen: [cases.len][]const u8 = undefined;
    for (cases, 0..) |e, i| {
        const msg = cellar_mod.describeError(e);
        try testing.expect(msg.len > 0);
        // Every tag must map to a distinct description.
        for (seen[0..i]) |prev| {
            try testing.expect(!std.mem.eql(u8, msg, prev));
        }
        seen[i] = msg;
    }
}

// ---------------------------------------------------------------------------
// P8 — Empty Cellar/{name}/ parent dir is cleaned up on failed materialize
// ---------------------------------------------------------------------------

test "failed materialize cleans up empty Cellar/{name}/ parent dir" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    // No bottle fixture — the materialize call must fail (nothing to clone),
    // which is what exercises the errdefer.
    _ = setMaltPrefix(prefix);
    defer restoreMaltPrefix("");

    const result = cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "no-such-sha",
        "ghost",
        "0.0.1",
        ":any",
    );
    try testing.expectError(cellar_mod.CellarError.CloneFailed, result);

    // Cellar/ghost/ must not exist on disk after the failure.
    var parent_buf: [512]u8 = undefined;
    const parent = try std.fmt.bufPrint(&parent_buf, "{s}/Cellar/ghost", .{prefix});
    const parent_exists = blk: {
        test_io.accessAbsolute(std.Options.debug_io, parent, .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(!parent_exists);
}

test "failed materialize leaves sibling versions untouched" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    // Pre-populate Cellar/keeper/1.0/ — this simulates an existing installed
    // version that a later failed materialize of keeper 2.0 must NOT delete.
    const keeper_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/keeper/1.0", .{prefix});
    defer testing.allocator.free(keeper_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keeper_dir);

    _ = setMaltPrefix(prefix);
    defer restoreMaltPrefix("");

    const result = cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        "missing-sha",
        "keeper",
        "2.0",
        ":any",
    );
    try testing.expectError(cellar_mod.CellarError.CloneFailed, result);

    // Cellar/keeper/1.0 must still be there — the errdefer may delete the
    // empty parent, but it must NOT recurse into a non-empty one.
    var alive_buf: [512]u8 = undefined;
    const alive = try std.fmt.bufPrint(&alive_buf, "{s}/Cellar/keeper/1.0", .{prefix});
    try test_io.accessAbsolute(std.Options.debug_io, alive, .{});
}

test "patchTextFiles replaces all placeholder occurrences" {
    const dir = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
        testing.allocator.free(dir);
    }

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/multi.txt", .{dir});
    defer testing.allocator.free(file_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, file_path, .{});
        try f.writeStreamingAll(std.Options.debug_io, "a=@@HOMEBREW_PREFIX@@\nb=@@HOMEBREW_PREFIX@@\nc=@@HOMEBREW_CELLAR@@\n");
        f.close(std.Options.debug_io);
    }

    const replacements = [_]patcher.Replacement{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = "/opt/malt" },
        .{ .old = "@@HOMEBREW_CELLAR@@", .new = "/opt/malt/Cellar" },
        .{ .old = "/unused", .new = "/opt/malt" },
    };
    const count = try patcher.patchTextFiles(std.Options.debug_io, testing.allocator, dir, &replacements);
    try testing.expect(count > 0);

    const content = try readFile(testing.allocator, file_path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_PREFIX@@") == null);
    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_CELLAR@@") == null);
    try testing.expect(std.mem.indexOf(u8, content, "/opt/malt") != null);
    try testing.expect(std.mem.indexOf(u8, content, "/opt/malt/Cellar") != null);
}

// ---------------------------------------------------------------------------
// P1 — REGRESSION GUARD: @@HOMEBREW_PREFIX@@ must be rewritten in Mach-O
// load commands even when cellar_type is ":any" (relocatable bottle).
//
// Before the fix, the materializer skipped Mach-O patching entirely for
// ":any" bottles, leaving @@HOMEBREW_* placeholder tokens in LC_LOAD_DYLIB
// and LC_RPATH unresolved. Zig, rust, curl and all llvm@* bottles then
// failed at runtime with `dyld: Symbol not found`.
//
// This test builds a minimal but *parser-valid* Mach-O fixture containing
// one LC_RPATH whose path is `@@HOMEBREW_PREFIX@@/lib/test`, materializes it
// as a ":any" bottle, re-parses the patched output, and asserts both the
// negative (no placeholder remains) and the positive (the new prefix is
// present) invariants.
// ---------------------------------------------------------------------------

/// Build a minimal valid Mach-O 64 binary with one LC_RPATH load command.
/// The `cmdsize` is padded to 256 bytes so the load-command slot is large
/// enough to accept any reasonable replacement prefix.
fn buildMinimalMachOWithRpath(
    allocator: std.mem.Allocator,
    rpath: []const u8,
) ![]u8 {
    const macho = std.macho;
    const header_size = @sizeOf(macho.mach_header_64);
    const cmdsize: u32 = 256;
    const total = header_size + cmdsize;

    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    // Only set the fields we actually care about. std.macho struct fields
    // use primitive integer types, not typed enums — we write the raw
    // constants (MH_EXECUTE = 2, LC_RPATH = 0x1c) directly.
    const hdr = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    hdr.* = .{
        .magic = macho.MH_MAGIC_64,
        .ncmds = 1,
        .sizeofcmds = cmdsize,
    };

    // LC_RPATH header: cmd(4), cmdsize(4), path(4) + padded path string.
    // We write the bytes directly rather than through rpath_command because
    // the field layout varies across Zig releases and we only need three u32s.
    // LC_RPATH = 0x1c OR'd with LC_REQ_DYLD (0x80000000). The parser matches
    // on the full LC enum value including the LC_REQ_DYLD flag bit.
    const lc_rpath: u32 = 0x1c | 0x80000000;
    const rpath_cmd_size: usize = 12;
    std.mem.writeInt(u32, buf[header_size..][0..4], lc_rpath, .little);
    std.mem.writeInt(u32, buf[header_size + 4 ..][0..4], cmdsize, .little);
    std.mem.writeInt(u32, buf[header_size + 8 ..][0..4], @intCast(rpath_cmd_size), .little); // path offset

    // Copy the rpath string into the slot; trailing bytes stay as NULs.
    std.debug.assert(rpath.len + 1 <= cmdsize - rpath_cmd_size);
    @memcpy(buf[header_size + rpath_cmd_size ..][0..rpath.len], rpath);

    return buf;
}

test "materialize rewrites @@HOMEBREW_PREFIX@@ in Mach-O rpath for :any bottle" {
    // Use a SHORT test prefix so the rewritten path definitely fits in the
    // original load-command slot. `/tmp/mp-{hex}` is ~14 bytes.
    const prefix_str = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/mp-{x}",
        .{test_io.randomInt(std.Options.debug_io, u32)},
    );
    defer testing.allocator.free(prefix_str);

    const prefix: [:0]const u8 = try testing.allocator.allocSentinel(u8, prefix_str.len, 0);
    defer testing.allocator.free(prefix);
    @memcpy(@constCast(prefix), prefix_str);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.makeDirAbsolute(std.Options.debug_io, prefix);
    try setupMaltDirs(testing.allocator, prefix);

    // Place a synthetic Mach-O inside the store tree.
    const sha = "p1test";
    const name = "relfake";
    const version = "1.0";
    const keg_bin_dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/store/{s}/{s}/{s}/bin",
        .{ prefix, sha, name, version },
    );
    defer testing.allocator.free(keg_bin_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_bin_dir);

    const bin_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/fakebin",
        .{keg_bin_dir},
    );
    defer testing.allocator.free(bin_path);

    const fixture = try buildMinimalMachOWithRpath(
        testing.allocator,
        "@@HOMEBREW_PREFIX@@/lib/test",
    );
    defer testing.allocator.free(fixture);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, fixture);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    // The exact bug scenario: `:any` bottle that would have skipped Mach-O
    // patching before P1.
    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        sha,
        name,
        version,
        ":any",
    );
    defer testing.allocator.free(keg.path);

    // Re-parse the patched binary and validate the load-command path.
    const out_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/bin/fakebin",
        .{keg.path},
    );
    defer testing.allocator.free(out_path);

    const data = try readFile(testing.allocator, out_path);
    defer testing.allocator.free(data);

    var parsed = try parser.parse(testing.allocator, data);
    defer parsed.deinit();

    // Must have at least one LC_RPATH.
    try testing.expect(parsed.paths.len >= 1);

    // Negative invariant: no placeholder tokens anywhere.
    for (parsed.paths) |lcp| {
        try testing.expect(std.mem.indexOf(u8, lcp.path, "@@HOMEBREW_PREFIX@@") == null);
        try testing.expect(std.mem.indexOf(u8, lcp.path, "@@HOMEBREW_CELLAR@@") == null);
    }

    // Positive invariant: at least one load command now holds the new prefix.
    var found_new_prefix = false;
    for (parsed.paths) |lcp| {
        if (std.mem.indexOf(u8, lcp.path, prefix) != null) {
            found_new_prefix = true;
            break;
        }
    }
    try testing.expect(found_new_prefix);

    // Spot-check the specific expected result.
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/lib/test", .{prefix});
    var found_exact = false;
    for (parsed.paths) |lcp| {
        if (std.mem.eql(u8, lcp.path, expected)) {
            found_exact = true;
            break;
        }
    }
    try testing.expect(found_exact);
}

/// Build a minimal universal (fat) Mach-O binary with two arch slices
/// (arm64 + x86_64), each of which contains a single LC_RPATH load command
/// carrying the supplied rpath.
///
/// Layout:
///
///     fat_header       @  0: magic(4)=0xCAFEBABE (big), nfat_arch(4)=2 (big)
///     fat_arch[0]      @  8: cputype=arm64,  offset=48,  size=288
///     fat_arch[1]      @ 28: cputype=x86_64, offset=336, size=288
///     arm64 slice      @ 48: mach_header_64 (32) + LC_RPATH slot (256)
///     x86_64 slice     @336: mach_header_64 (32) + LC_RPATH slot (256)
///     total = 624 bytes
fn buildFatMachOWithRpath(
    allocator: std.mem.Allocator,
    rpath: []const u8,
) ![]u8 {
    const macho = std.macho;
    const header_size = @sizeOf(macho.mach_header_64);
    const cmdsize: u32 = 256;
    const slice_bytes: u32 = header_size + cmdsize; // 288

    const fat_header_size: usize = 8;
    const fat_arch_size: usize = 20;
    const slice0_offset: u32 = @intCast(fat_header_size + 2 * fat_arch_size); // 48
    const slice1_offset: u32 = slice0_offset + slice_bytes; // 336
    const total: usize = slice1_offset + slice_bytes; // 624

    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    // --- fat_header (big-endian) ---
    std.mem.writeInt(u32, buf[0..4], 0xCAFEBABE, .big); // FAT_MAGIC
    std.mem.writeInt(u32, buf[4..8], 2, .big); // nfat_arch

    // --- fat_arch[0]: arm64 ---
    std.mem.writeInt(u32, buf[8..12], 0x0100000C, .big); // cputype = arm64
    std.mem.writeInt(u32, buf[12..16], 0, .big); // cpusubtype
    std.mem.writeInt(u32, buf[16..20], slice0_offset, .big); // offset
    std.mem.writeInt(u32, buf[20..24], slice_bytes, .big); // size
    std.mem.writeInt(u32, buf[24..28], 14, .big); // align (2^14 is conventional)

    // --- fat_arch[1]: x86_64 ---
    std.mem.writeInt(u32, buf[28..32], 0x01000007, .big); // cputype = x86_64
    std.mem.writeInt(u32, buf[32..36], 0, .big); // cpusubtype
    std.mem.writeInt(u32, buf[36..40], slice1_offset, .big); // offset
    std.mem.writeInt(u32, buf[40..44], slice_bytes, .big); // size
    std.mem.writeInt(u32, buf[44..48], 14, .big); // align

    // --- Two identical Mach-O 64 slices ---
    const lc_rpath: u32 = 0x1c | 0x80000000;
    const rpath_cmd_size: usize = 12;
    std.debug.assert(rpath.len + 1 <= cmdsize - rpath_cmd_size);

    for ([_]u32{ slice0_offset, slice1_offset }) |sl| {
        // mach_header_64 — only the fields the parser actually reads.
        const hdr = std.mem.bytesAsValue(
            macho.mach_header_64,
            buf[sl..][0..header_size],
        );
        hdr.* = .{
            .magic = macho.MH_MAGIC_64,
            .ncmds = 1,
            .sizeofcmds = cmdsize,
        };

        // LC_RPATH command (cmd, cmdsize, path offset) + padded path string.
        const lc_off = sl + header_size;
        std.mem.writeInt(u32, buf[lc_off..][0..4], lc_rpath, .little);
        std.mem.writeInt(u32, buf[lc_off + 4 ..][0..4], cmdsize, .little);
        std.mem.writeInt(u32, buf[lc_off + 8 ..][0..4], @intCast(rpath_cmd_size), .little);
        @memcpy(buf[lc_off + rpath_cmd_size ..][0..rpath.len], rpath);
    }

    return buf;
}

test "P9: materialize patches @@HOMEBREW_PREFIX@@ in EVERY fat-binary arch slice" {
    // Short prefix (well within the 13-byte budget).
    const prefix_str = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/mp-{x}",
        .{test_io.randomInt(std.Options.debug_io, u32)},
    );
    defer testing.allocator.free(prefix_str);

    const prefix: [:0]const u8 = try testing.allocator.allocSentinel(u8, prefix_str.len, 0);
    defer testing.allocator.free(prefix);
    @memcpy(@constCast(prefix), prefix_str);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.makeDirAbsolute(std.Options.debug_io, prefix);
    try setupMaltDirs(testing.allocator, prefix);

    // Drop a fat Mach-O fixture into the store.
    const sha = "p9fat";
    const name = "fatfake";
    const version = "1.0";
    const keg_bin_dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/store/{s}/{s}/{s}/bin",
        .{ prefix, sha, name, version },
    );
    defer testing.allocator.free(keg_bin_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_bin_dir);

    const bin_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/fatbin",
        .{keg_bin_dir},
    );
    defer testing.allocator.free(bin_path);

    const fixture = try buildFatMachOWithRpath(
        testing.allocator,
        "@@HOMEBREW_PREFIX@@/lib/fat",
    );
    defer testing.allocator.free(fixture);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, fixture);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        sha,
        name,
        version,
        ":any",
    );
    defer testing.allocator.free(keg.path);

    // Re-parse the patched fat binary and assert BOTH slices are clean.
    const out_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/bin/fatbin",
        .{keg.path},
    );
    defer testing.allocator.free(out_path);

    const data = try readFile(testing.allocator, out_path);
    defer testing.allocator.free(data);

    var parsed = try parser.parse(testing.allocator, data);
    defer parsed.deinit();

    // Must see TWO rpath entries — one per arch slice.
    try testing.expectEqual(@as(usize, 2), parsed.paths.len);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}/lib/fat", .{prefix});

    for (parsed.paths) |lcp| {
        try testing.expect(std.mem.indexOf(u8, lcp.path, "@@HOMEBREW_PREFIX@@") == null);
        try testing.expectEqualStrings(expected, lcp.path);
    }

    // Additional belt-and-suspenders check: the raw file bytes contain no
    // `@@HOMEBREW_` at all, ruling out the possibility that one slice was
    // patched and the other left alone.
    try testing.expect(std.mem.indexOf(u8, data, "@@HOMEBREW_") == null);
}

test "materialize rewrites @@HOMEBREW_CELLAR@@ in Mach-O rpath for :any bottle" {
    // Same fixture strategy, different token.
    const prefix_str = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/mp-{x}",
        .{test_io.randomInt(std.Options.debug_io, u32)},
    );
    defer testing.allocator.free(prefix_str);

    const prefix: [:0]const u8 = try testing.allocator.allocSentinel(u8, prefix_str.len, 0);
    defer testing.allocator.free(prefix);
    @memcpy(@constCast(prefix), prefix_str);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    try test_io.makeDirAbsolute(std.Options.debug_io, prefix);
    try setupMaltDirs(testing.allocator, prefix);

    const sha = "p1cellar";
    const name = "cellarfake";
    const version = "2.0";
    const keg_bin_dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/store/{s}/{s}/{s}/bin",
        .{ prefix, sha, name, version },
    );
    defer testing.allocator.free(keg_bin_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg_bin_dir);

    const bin_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/fakelib",
        .{keg_bin_dir},
    );
    defer testing.allocator.free(bin_path);

    const fixture = try buildMinimalMachOWithRpath(
        testing.allocator,
        "@@HOMEBREW_CELLAR@@/openssl@3/3.0/lib",
    );
    defer testing.allocator.free(fixture);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, bin_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, fixture);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        sha,
        name,
        version,
        ":any_skip_relocation",
    );
    defer testing.allocator.free(keg.path);

    const out_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/bin/fakelib",
        .{keg.path},
    );
    defer testing.allocator.free(out_path);

    const data = try readFile(testing.allocator, out_path);
    defer testing.allocator.free(data);

    var parsed = try parser.parse(testing.allocator, data);
    defer parsed.deinit();

    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "{s}/Cellar/openssl@3/3.0/lib",
        .{prefix},
    );

    var found = false;
    for (parsed.paths) |lcp| {
        try testing.expect(std.mem.indexOf(u8, lcp.path, "@@HOMEBREW_CELLAR@@") == null);
        if (std.mem.eql(u8, lcp.path, expected)) found = true;
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------------
// Bottle etc/var overlay pour
// ---------------------------------------------------------------------------

fn writeAbs(path: []const u8, content: []const u8) !void {
    const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{});
    try f.writeStreamingAll(std.Options.debug_io, content);
    f.close(std.Options.debug_io);
}

fn overlayFixture(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const keg = try std.fmt.allocPrint(allocator, "{s}/Cellar/fc/1.0", .{prefix});
    errdefer allocator.free(keg);
    const etc_dir = try std.fmt.allocPrint(allocator, "{s}/.bottle/etc/fonts", .{keg});
    defer allocator.free(etc_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, etc_dir);
    const conf = try std.fmt.allocPrint(allocator, "{s}/fonts.conf", .{etc_dir});
    defer allocator.free(conf);
    try writeAbs(conf, "<fontconfig>poured</fontconfig>\n");
    return keg;
}

test "installBottleEtcVar pours a missing overlay file into the prefix" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    const keg = try overlayFixture(testing.allocator, prefix);
    defer testing.allocator.free(keg);
    // A var payload rides the same overlay mechanism as etc.
    const var_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.bottle/var/db", .{keg});
    defer testing.allocator.free(var_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, var_dir);
    const seed = try std.fmt.allocPrint(testing.allocator, "{s}/seed", .{var_dir});
    defer testing.allocator.free(seed);
    try writeAbs(seed, "seed\n");

    cellar_mod.installBottleEtcVar(std.Options.debug_io, testing.allocator, keg, prefix);

    const conf_path = try std.fmt.allocPrint(testing.allocator, "{s}/etc/fonts/fonts.conf", .{prefix});
    defer testing.allocator.free(conf_path);
    const poured = try readFile(testing.allocator, conf_path);
    defer testing.allocator.free(poured);
    try testing.expectEqualStrings("<fontconfig>poured</fontconfig>\n", poured);

    const seed_path = try std.fmt.allocPrint(testing.allocator, "{s}/var/db/seed", .{prefix});
    defer testing.allocator.free(seed_path);
    const seeded = try readFile(testing.allocator, seed_path);
    defer testing.allocator.free(seeded);
    try testing.expectEqualStrings("seed\n", seeded);
}

test "installBottleEtcVar keeps a user-modified config and writes the new default beside it" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    const keg = try overlayFixture(testing.allocator, prefix);
    defer testing.allocator.free(keg);

    const live_dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc/fonts", .{prefix});
    defer testing.allocator.free(live_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, live_dir);
    const live = try std.fmt.allocPrint(testing.allocator, "{s}/fonts.conf", .{live_dir});
    defer testing.allocator.free(live);
    try writeAbs(live, "<fontconfig>user-edited</fontconfig>\n");

    cellar_mod.installBottleEtcVar(std.Options.debug_io, testing.allocator, keg, prefix);

    const kept = try readFile(testing.allocator, live);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("<fontconfig>user-edited</fontconfig>\n", kept);

    const default_path = try std.fmt.allocPrint(testing.allocator, "{s}.default", .{live});
    defer testing.allocator.free(default_path);
    const dflt = try readFile(testing.allocator, default_path);
    defer testing.allocator.free(dflt);
    try testing.expectEqualStrings("<fontconfig>poured</fontconfig>\n", dflt);
}

test "installBottleEtcVar leaves an identical config alone" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    const keg = try overlayFixture(testing.allocator, prefix);
    defer testing.allocator.free(keg);

    const live_dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc/fonts", .{prefix});
    defer testing.allocator.free(live_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, live_dir);
    const live = try std.fmt.allocPrint(testing.allocator, "{s}/fonts.conf", .{live_dir});
    defer testing.allocator.free(live);
    try writeAbs(live, "<fontconfig>poured</fontconfig>\n");

    cellar_mod.installBottleEtcVar(std.Options.debug_io, testing.allocator, keg, prefix);

    const default_path = try std.fmt.allocPrint(testing.allocator, "{s}.default", .{live});
    defer testing.allocator.free(default_path);
    try testing.expectError(
        error.FileNotFound,
        test_io.openFileAbsolute(std.Options.debug_io, default_path, .{}),
    );
}

test "installBottleEtcVar no-ops for kegs without a bottle overlay" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/plain/1.0", .{prefix});
    defer testing.allocator.free(keg);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg);

    cellar_mod.installBottleEtcVar(std.Options.debug_io, testing.allocator, keg, prefix);

    const etc_path = try std.fmt.allocPrint(testing.allocator, "{s}/etc", .{prefix});
    defer testing.allocator.free(etc_path);
    try testing.expectError(
        error.FileNotFound,
        test_io.openFileAbsolute(std.Options.debug_io, etc_path, .{}),
    );
}

test "warm cache-hit reinstall re-pours a wiped overlay config" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    try setupMaltDirs(testing.allocator, prefix);

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    // Cold install: bottle fixture carrying an etc overlay populates the
    // relocated cache and pours the config.
    try createBottleFixture(testing.allocator, prefix, valid_test_sha, "fc", "1.0");
    const overlay_dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/store/{s}/fc/1.0/.bottle/etc/fonts",
        .{ prefix, valid_test_sha },
    );
    defer testing.allocator.free(overlay_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, overlay_dir);
    const overlay_conf = try std.fmt.allocPrint(testing.allocator, "{s}/fonts.conf", .{overlay_dir});
    defer testing.allocator.free(overlay_conf);
    try writeAbs(overlay_conf, "<fontconfig>poured</fontconfig>\n");

    const keg_cold = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "fc",
        "1.0",
        ":any",
    );
    testing.allocator.free(keg_cold.path);
    try testing.expect(relocated_mod.has(std.Options.debug_io, prefix, valid_test_sha));

    // Wipe the poured config and the Cellar entry; the reinstall must take
    // the cache short-circuit AND restore the config.
    const live_conf = try std.fmt.allocPrint(testing.allocator, "{s}/etc/fonts/fonts.conf", .{prefix});
    defer testing.allocator.free(live_conf);
    const poured_cold = try readFile(testing.allocator, live_conf);
    defer testing.allocator.free(poured_cold);
    try testing.expectEqualStrings("<fontconfig>poured</fontconfig>\n", poured_cold);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, live_conf);
    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/fc/1.0", .{prefix});
    defer testing.allocator.free(keg_dir);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, keg_dir);
    const store_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/{s}", .{ prefix, valid_test_sha });
    defer testing.allocator.free(store_dir);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, store_dir);

    const keg_warm = try cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        testing.allocator,
        prefix,
        valid_test_sha,
        "fc",
        "1.0",
        ":any",
    );
    testing.allocator.free(keg_warm.path);

    const poured_warm = try readFile(testing.allocator, live_conf);
    defer testing.allocator.free(poured_warm);
    try testing.expectEqualStrings("<fontconfig>poured</fontconfig>\n", poured_warm);
}

test "installBottleEtcVar creates empty overlay directories hooks rely on" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    // dbus ships `.bottle/var/lib/dbus/` with no files; post_install's
    // dbus-uuidgen expects the directory to exist.
    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/dbus/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const empty_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.bottle/var/lib/dbus", .{keg});
    defer testing.allocator.free(empty_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, empty_dir);

    cellar_mod.installBottleEtcVar(std.Options.debug_io, testing.allocator, keg, prefix);

    const poured_dir = try std.fmt.allocPrint(testing.allocator, "{s}/var/lib/dbus", .{prefix});
    defer testing.allocator.free(poured_dir);
    var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, poured_dir, .{});
    dir.close(std.Options.debug_io);
}
