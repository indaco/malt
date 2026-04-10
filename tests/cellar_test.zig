//! malt — cellar module tests
//! Tests for keg materialization, placeholder substitution, and directory flattening.

const std = @import("std");
const testing = std.testing;
const cellar_mod = @import("malt").cellar;
const patcher = @import("malt").patcher;
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
    const old = std.posix.getenv("MALT_PREFIX") orelse "";
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
    const path = try std.fmt.allocPrint(allocator, "/tmp/malt_cellar_test_{x}", .{std.crypto.random.int(u64)});
    defer allocator.free(path);
    const z = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(z, path);
    try std.fs.makeDirAbsolute(z);
    return z;
}

fn createBottleFixture(allocator: std.mem.Allocator, prefix: []const u8, sha: []const u8, name: []const u8, ver_dir: []const u8) !void {
    const keg = try std.fmt.allocPrint(allocator, "{s}/store/{s}/{s}/{s}", .{ prefix, sha, name, ver_dir });
    defer allocator.free(keg);
    try std.fs.cwd().makePath(keg);

    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin", .{keg});
    defer allocator.free(bin_dir);
    try std.fs.makeDirAbsolute(bin_dir);

    const script_path = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{keg});
    defer allocator.free(script_path);
    {
        const f = try std.fs.createFileAbsolute(script_path, .{});
        try f.writeAll("#!/bin/sh\nprefix=@@HOMEBREW_PREFIX@@\ncellar=@@HOMEBREW_CELLAR@@\necho $prefix\n");
        f.close();
    }

    const lib_dir = try std.fmt.allocPrint(allocator, "{s}/lib", .{keg});
    defer allocator.free(lib_dir);
    try std.fs.makeDirAbsolute(lib_dir);

    const pc_path = try std.fmt.allocPrint(allocator, "{s}/lib/test.pc", .{keg});
    defer allocator.free(pc_path);
    {
        const f = try std.fs.createFileAbsolute(pc_path, .{});
        try f.writeAll("prefix=@@HOMEBREW_PREFIX@@\nlibdir=${prefix}/lib\ncellar=@@HOMEBREW_CELLAR@@\n");
        f.close();
    }
}

fn setupMaltDirs(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const dirs = [_][]const u8{ "store", "Cellar", "opt", "bin", "lib" };
    for (dirs) |d| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, d });
        defer allocator.free(p);
        std.fs.cwd().makePath(p) catch {};
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
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
        std.fs.deleteTreeAbsolute(prefix) catch {};
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
    try std.fs.accessAbsolute(bin_path, .{});

    // Verify no extra nesting: Cellar/pcre2/10.47/pcre2/ should NOT exist
    var nested_buf: [512]u8 = undefined;
    const nested_path = try std.fmt.bufPrint(&nested_buf, "{s}/pcre2", .{keg.path});
    const nested_exists = blk: {
        std.fs.accessAbsolute(nested_path, .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(!nested_exists);
}

test "materialize handles exact version match (no revision)" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        std.fs.deleteTreeAbsolute(prefix) catch {};
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
    try std.fs.accessAbsolute(bin_path, .{});
}

// ---------------------------------------------------------------------------
// Placeholder substitution for relocatable bottles
// ---------------------------------------------------------------------------

test "placeholder substitution runs for relocatable bottles" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        std.fs.deleteTreeAbsolute(prefix) catch {};
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
        std.fs.deleteTreeAbsolute(prefix) catch {};
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
        std.fs.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/clean123/noop/1.0", .{prefix});
    defer testing.allocator.free(keg_dir);
    try std.fs.cwd().makePath(keg_dir);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg_dir});
    defer testing.allocator.free(bin_dir);
    try std.fs.makeDirAbsolute(bin_dir);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/bin/clean", .{keg_dir});
    defer testing.allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
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
        std.fs.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    const keg_dir = try std.fmt.allocPrint(testing.allocator, "{s}/store/bin123/binpkg/1.0", .{prefix});
    defer testing.allocator.free(keg_dir);
    try std.fs.cwd().makePath(keg_dir);

    const bin_dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{keg_dir});
    defer testing.allocator.free(bin_dir);
    try std.fs.makeDirAbsolute(bin_dir);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/bin/fakemach", .{keg_dir});
    defer testing.allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
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
// P4 — Pre-flight MALT_PREFIX length check
// ---------------------------------------------------------------------------

test "checkPrefixLength accepts prefixes within the Mach-O patch budget" {
    try install_mod.checkPrefixLength("/opt/malt");
    try install_mod.checkPrefixLength("/opt/homebrew"); // exactly 13 bytes — boundary
    try install_mod.checkPrefixLength("/tmp/mt");
}

test "checkPrefixLength rejects prefixes that overflow the budget" {
    try testing.expectError(
        error.PrefixTooLong,
        install_mod.checkPrefixLength("/var/folders/abc/def/ghi/jkl/mno/prefix"),
    );
    try testing.expectError(
        error.PrefixTooLong,
        install_mod.checkPrefixLength("/opt/homebrew/"), // 14 bytes — just over
    );
}

test "max_prefix_len matches the /opt/homebrew budget" {
    try testing.expectEqual(@as(usize, "/opt/homebrew".len), install_mod.max_prefix_len);
}

// ---------------------------------------------------------------------------
// P5 — CellarError.describeError covers every tag
// ---------------------------------------------------------------------------

test "describeError returns a non-empty, distinct message for every CellarError" {
    const cases = [_]cellar_mod.CellarError{
        cellar_mod.CellarError.CloneFailed,
        cellar_mod.CellarError.PatchFailed,
        cellar_mod.CellarError.PathTooLong,
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
        std.fs.deleteTreeAbsolute(prefix) catch {};
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
        std.fs.accessAbsolute(parent, .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(!parent_exists);
}

test "failed materialize leaves sibling versions untouched" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        std.fs.deleteTreeAbsolute(prefix) catch {};
        testing.allocator.free(prefix);
    }

    try setupMaltDirs(testing.allocator, prefix);

    // Pre-populate Cellar/keeper/1.0/ — this simulates an existing installed
    // version that a later failed materialize of keeper 2.0 must NOT delete.
    const keeper_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/keeper/1.0", .{prefix});
    defer testing.allocator.free(keeper_dir);
    try std.fs.cwd().makePath(keeper_dir);

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
    try std.fs.accessAbsolute(alive, .{});
}

test "patchTextFiles replaces all placeholder occurrences" {
    const dir = try createTestDir(testing.allocator);
    defer {
        std.fs.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/multi.txt", .{dir});
    defer testing.allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("a=@@HOMEBREW_PREFIX@@\nb=@@HOMEBREW_PREFIX@@\nc=@@HOMEBREW_CELLAR@@\n");
        f.close();
    }

    const count = try patcher.patchTextFiles(testing.allocator, dir, "/unused", "/opt/malt");
    try testing.expect(count > 0);

    const content = try readFile(testing.allocator, file_path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_PREFIX@@") == null);
    try testing.expect(std.mem.indexOf(u8, content, "@@HOMEBREW_CELLAR@@") == null);
    try testing.expect(std.mem.indexOf(u8, content, "/opt/malt") != null);
    try testing.expect(std.mem.indexOf(u8, content, "/opt/malt/Cellar") != null);
}
