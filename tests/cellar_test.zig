//! malt — cellar module tests
//! Tests for keg materialization, placeholder substitution, and directory flattening.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const cellar_mod = @import("malt").cellar;
const patcher = @import("malt").patcher;
const parser = @import("malt").parser;
const install_mod = @import("malt").install;

// libc setenv/unsetenv — available because tests link with libc
const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn setMaltPrefix(prefix: [:0]const u8) [:0]const u8 {
    const old = malt.fs_compat.getenv("MALT_PREFIX") orelse "";
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
    const path = try std.fmt.allocPrint(allocator, "/tmp/malt_cellar_test_{x}", .{malt.fs_compat.randomInt(u64)});
    defer allocator.free(path);
    const z = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(z, path);
    try malt.fs_compat.makeDirAbsolute(z);
    return z;
}

fn createBottleFixture(allocator: std.mem.Allocator, prefix: []const u8, sha: []const u8, name: []const u8, ver_dir: []const u8) !void {
    const keg = try std.fmt.allocPrint(allocator, "{s}/store/{s}/{s}/{s}", .{ prefix, sha, name, ver_dir });
    defer allocator.free(keg);
    try malt.fs_compat.cwd().makePath(keg);

    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{keg});
    defer allocator.free(bin_dir);
    try malt.fs_compat.makeDirAbsolute(bin_dir);

    const script_path = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{keg});
    defer allocator.free(script_path);
    {
        const f = try malt.fs_compat.createFileAbsolute(script_path, .{});
        try f.writeAll("#!/bin/sh\nprefix=@@HOMEBREW_PREFIX@@\ncellar=@@HOMEBREW_CELLAR@@\necho $prefix\n");
        f.close();
    }

    const lib_dir = try std.fmt.allocPrint(allocator, "{s}/lib", .{keg});
    defer allocator.free(lib_dir);
    try malt.fs_compat.makeDirAbsolute(lib_dir);

    const pc_path = try std.fmt.allocPrint(allocator, "{s}/lib/test.pc", .{keg});
    defer allocator.free(pc_path);
    {
        const f = try malt.fs_compat.createFileAbsolute(pc_path, .{});
        try f.writeAll("prefix=@@HOMEBREW_PREFIX@@\nlibdir=${prefix}/lib\ncellar=@@HOMEBREW_CELLAR@@\n");
        f.close();
    }
}

fn setupMaltDirs(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const dirs = [_][]const u8{ "store", "Cellar", "opt", "bin", "lib" };
    for (dirs) |d| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, d });
        defer allocator.free(p);
        malt.fs_compat.cwd().makePath(p) catch {};
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try malt.fs_compat.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    const n = try file.readAll(buf);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Keg directory flattening (revision suffix handling)
// ---------------------------------------------------------------------------

test "materialize handles version with revision suffix" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "abc123", "pcre2", "10.47_1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
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
    try malt.fs_compat.accessAbsolute(bin_path, .{});

    // Verify no extra nesting: Cellar/pcre2/10.47/pcre2/ should NOT exist
    var nested_buf: [512]u8 = undefined;
    const nested_path = try std.fmt.bufPrint(&nested_buf, "{s}/pcre2", .{keg.path});
    const nested_exists = blk: {
        malt.fs_compat.accessAbsolute(nested_path, .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(!nested_exists);
}

test "materialize handles exact version match (no revision)" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "def456", "jq", "1.7.1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
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
    try malt.fs_compat.accessAbsolute(bin_path, .{});
}

// ---------------------------------------------------------------------------
// Placeholder substitution for relocatable bottles
// ---------------------------------------------------------------------------

test "placeholder substitution runs for relocatable bottles" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "rel123", "stow", "2.4.1");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
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
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);
    try createBottleFixture(testing.allocator, prefix, "multi123", "pkg", "1.0");

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
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
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/clean123/noop/1.0", .{prefix});
    defer testing.allocator.free(keg_dir);
    try malt.fs_compat.cwd().makePath(keg_dir);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg_dir});
    defer testing.allocator.free(bin_dir);
    try malt.fs_compat.makeDirAbsolute(bin_dir);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/bin/clean", .{keg_dir});
    defer testing.allocator.free(file_path);
    {
        const f = try malt.fs_compat.createFileAbsolute(file_path, .{});
        try f.writeAll("#!/bin/sh\necho hello world\n");
        f.close();
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
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
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/bin123/binpkg/1.0", .{prefix});
    defer testing.allocator.free(keg_dir);
    try malt.fs_compat.cwd().makePath(keg_dir);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg_dir});
    defer testing.allocator.free(bin_dir);
    try malt.fs_compat.makeDirAbsolute(bin_dir);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/bin/fakemach", .{keg_dir});
    defer testing.allocator.free(file_path);
    {
        const f = try malt.fs_compat.createFileAbsolute(file_path, .{});
        try f.writeAll("\xcf\xfa\xed\xfe\x00\x00\x00@@HOMEBREW_PREFIX@@\x00more\x00binary");
        f.close();
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
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
    try install_mod.checkPrefixSane("/opt/malt");
    try install_mod.checkPrefixSane("/opt/homebrew");
    try install_mod.checkPrefixSane("/tmp/mt");
    try install_mod.checkPrefixSane("/tmp/mt_tahoe"); // 13 bytes — formerly rejected
    try install_mod.checkPrefixSane("/var/folders/abc/def/ghi/jkl/mno/prefix");
}

test "checkPrefixSane rejects absurd prefixes at the 256-byte cap" {
    const huge = "/" ++ "x" ** 512;
    try testing.expectError(error.PrefixAbsurd, install_mod.checkPrefixSane(huge));
}

// ---------------------------------------------------------------------------
// CellarError.describeError covers every tag
// ---------------------------------------------------------------------------

test "describeError returns a non-empty, distinct message for every CellarError" {
    const cases = [_]cellar_mod.CellarError{
        cellar_mod.CellarError.CloneFailed,
        cellar_mod.CellarError.PatchFailed,
        cellar_mod.CellarError.PathTooLong,
        cellar_mod.CellarError.InsufficientHeaderPad,
        cellar_mod.CellarError.InstallNameToolMissing,
        cellar_mod.CellarError.CodesignFailed,
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
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    // No bottle fixture — the materialize call must fail (nothing to clone),
    // which is what exercises the errdefer.
    _ = setMaltPrefix(prefix);
    defer restoreMaltPrefix("");

    const result = cellar_mod.materializeWithCellar(
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
        malt.fs_compat.accessAbsolute(parent, .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(!parent_exists);
}

test "failed materialize leaves sibling versions untouched" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        malt.fs_compat.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    // Pre-populate Cellar/keeper/1.0/ — this simulates an existing installed
    // version that a later failed materialize of keeper 2.0 must NOT delete.
    const keeper_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/keeper/1.0", .{prefix});
    defer testing.allocator.free(keeper_dir);
    try malt.fs_compat.cwd().makePath(keeper_dir);

    _ = setMaltPrefix(prefix);
    defer restoreMaltPrefix("");

    const result = cellar_mod.materializeWithCellar(
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
    try malt.fs_compat.accessAbsolute(alive, .{});
}

test "patchTextFiles replaces all placeholder occurrences" {
    const dir = try createTestDir(testing.allocator);
    defer {
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/multi.txt", .{dir});
    defer testing.allocator.free(file_path);
    {
        const f = try malt.fs_compat.createFileAbsolute(file_path, .{});
        try f.writeAll("a=@@HOMEBREW_PREFIX@@\nb=@@HOMEBREW_PREFIX@@\nc=@@HOMEBREW_CELLAR@@\n");
        f.close();
    }

    const replacements = [_]patcher.Replacement{
        .{ .old = "@@HOMEBREW_PREFIX@@", .new = "/opt/malt" },
        .{ .old = "@@HOMEBREW_CELLAR@@", .new = "/opt/malt/Cellar" },
        .{ .old = "/unused", .new = "/opt/malt" },
    };
    const count = try patcher.patchTextFiles(testing.allocator, dir, &replacements);
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
        .{malt.fs_compat.randomInt(u32)},
    );
    defer testing.allocator.free(prefix_str);

    const prefix: [:0]const u8 = try testing.allocator.allocSentinel(u8, prefix_str.len, 0);
    defer testing.allocator.free(prefix);
    @memcpy(@constCast(prefix), prefix_str);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};

    try malt.fs_compat.makeDirAbsolute(prefix);
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
    try malt.fs_compat.cwd().makePath(keg_bin_dir);

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
        const f = try malt.fs_compat.createFileAbsolute(bin_path, .{});
        defer f.close();
        try f.writeAll(fixture);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    // The exact bug scenario: `:any` bottle that would have skipped Mach-O
    // patching before P1.
    const keg = try cellar_mod.materializeWithCellar(
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
        .{malt.fs_compat.randomInt(u32)},
    );
    defer testing.allocator.free(prefix_str);

    const prefix: [:0]const u8 = try testing.allocator.allocSentinel(u8, prefix_str.len, 0);
    defer testing.allocator.free(prefix);
    @memcpy(@constCast(prefix), prefix_str);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};

    try malt.fs_compat.makeDirAbsolute(prefix);
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
    try malt.fs_compat.cwd().makePath(keg_bin_dir);

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
        const f = try malt.fs_compat.createFileAbsolute(bin_path, .{});
        defer f.close();
        try f.writeAll(fixture);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
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
        .{malt.fs_compat.randomInt(u32)},
    );
    defer testing.allocator.free(prefix_str);

    const prefix: [:0]const u8 = try testing.allocator.allocSentinel(u8, prefix_str.len, 0);
    defer testing.allocator.free(prefix);
    @memcpy(@constCast(prefix), prefix_str);
    defer malt.fs_compat.deleteTreeAbsolute(prefix) catch {};

    try malt.fs_compat.makeDirAbsolute(prefix);
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
    try malt.fs_compat.cwd().makePath(keg_bin_dir);

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
        const f = try malt.fs_compat.createFileAbsolute(bin_path, .{});
        defer f.close();
        try f.writeAll(fixture);
    }

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try cellar_mod.materializeWithCellar(
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
