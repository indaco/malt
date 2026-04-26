//! malt — version update tests.
//!
//! Matcher / walker coverage moved to tests/release_test.zig alongside
//! the `src/update/release.zig` module. This file now only pins the
//! version-string sanity guard.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const version_mod = malt.version;
const updater = malt.cli_version_update;
const output_mod = malt.output;
const fs_compat = malt.fs_compat;
const io_mod = malt.io_mod;

test "version value is non-empty and trimmed" {
    try testing.expect(version_mod.value.len > 0);
    try testing.expect(version_mod.value[version_mod.value.len - 1] != '\n');
    try testing.expect(version_mod.value[version_mod.value.len - 1] != ' ');
}

// --- parseArgs ------------------------------------------------------------
//
// Flag parsing is the tiniest possible target for drift: a typo or
// refactor that silently disables `--yes` in CI could leave the updater
// prompting forever. Pin each flag's recognised forms.

test "parseArgs: no flags yields all-false" {
    const opts = updater.parseArgs(&.{});
    try testing.expect(!opts.check);
    try testing.expect(!opts.yes);
    try testing.expect(!opts.no_verify);
    try testing.expect(!opts.cleanup);
}

test "parseArgs: --check sets check" {
    try testing.expect(updater.parseArgs(&.{"--check"}).check);
}

test "parseArgs: both long and short forms of --yes" {
    try testing.expect(updater.parseArgs(&.{"--yes"}).yes);
    try testing.expect(updater.parseArgs(&.{"-y"}).yes);
}

test "parseArgs: --no-verify and --cleanup are independent" {
    const opts = updater.parseArgs(&.{ "--no-verify", "--cleanup" });
    try testing.expect(opts.no_verify);
    try testing.expect(opts.cleanup);
    try testing.expect(!opts.yes);
}

test "parseArgs: unrecognised flags are ignored (do not crash)" {
    // Forward-compat: a user passing a flag from a newer version of
    // malt to an older binary should not crash the updater.
    const opts = updater.parseArgs(&.{ "--check", "--nonsense", "--yes" });
    try testing.expect(opts.check);
    try testing.expect(opts.yes);
}

// --- writeResponseBody ---------------------------------------------------
//
// BUG-012 regression guard: the old `writeDownload` allocated `path` and
// returned early on `createFileAbsolute` / `writeAll` errors without freeing
// it. Exercising the helper under `testing.allocator` proves the ownership
// contract — happy path returns an owned slice, failure path leaves zero
// allocations behind.

fn tmpDirAbsolute(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try std.Io.Dir.realPath(tmp.dir, io_mod.ctx(), buf);
    return buf[0..n];
}

test "writeResponseBody: writes body and returns caller-owned path" {
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [fs_compat.max_path_bytes]u8 = undefined;
    const dir_abs = try tmpDirAbsolute(&tmp, &buf);

    const path = try updater.writeResponseBody(testing.allocator, dir_abs, "payload.bin", "hello-T011");
    defer testing.allocator.free(path);

    const expected_suffix = "/payload.bin";
    try testing.expect(std.mem.endsWith(u8, path, expected_suffix));

    const contents = try fs_compat.readFileAbsoluteAlloc(testing.allocator, path, 1024);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("hello-T011", contents);
}

test "writeResponseBody: createFileAbsolute failure leaves zero leaked allocations" {
    // testing.allocator leak-detects; without `errdefer` on the allocPrint
    // the freshly-allocated `path` would escape unfreed here.
    output_mod.setQuiet(true);
    defer output_mod.setQuiet(false);

    const result = updater.writeResponseBody(
        testing.allocator,
        "/nonexistent/malt-T011-guardrail",
        "payload.bin",
        "x",
    );
    try testing.expectError(error.Aborted, result);
}

// --- resolveTwinRegularFile ---------------------------------------------
//
// install.sh ships two independent binaries (`malt` and `mt`). The updater
// has to swap both in lockstep, otherwise `malt --version` and `mt --version`
// drift apart. These tests pin the twin-detection contract.

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try fs_compat.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(content);
}

fn makeScratch(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(allocator, "/tmp/malt_twin_test_{s}", .{tag});
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    return dir;
}

test "resolveTwinRegularFile: returns sibling mt when invoked as malt" {
    const dir = try makeScratch(testing.allocator, "malt_to_mt");
    defer {
        fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }

    const malt_path = try std.fmt.allocPrint(testing.allocator, "{s}/malt", .{dir});
    defer testing.allocator.free(malt_path);
    const mt_path = try std.fmt.allocPrint(testing.allocator, "{s}/mt", .{dir});
    defer testing.allocator.free(mt_path);
    try writeFile(malt_path, "m");
    try writeFile(mt_path, "m");

    var buf: [fs_compat.max_path_bytes]u8 = undefined;
    const twin = updater.resolveTwinRegularFile(malt_path, &buf) orelse return error.ExpectedTwin;
    try testing.expectEqualStrings(mt_path, twin);
}

test "resolveTwinRegularFile: returns sibling malt when invoked as mt" {
    const dir = try makeScratch(testing.allocator, "mt_to_malt");
    defer {
        fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }

    const malt_path = try std.fmt.allocPrint(testing.allocator, "{s}/malt", .{dir});
    defer testing.allocator.free(malt_path);
    const mt_path = try std.fmt.allocPrint(testing.allocator, "{s}/mt", .{dir});
    defer testing.allocator.free(mt_path);
    try writeFile(malt_path, "m");
    try writeFile(mt_path, "m");

    var buf: [fs_compat.max_path_bytes]u8 = undefined;
    const twin = updater.resolveTwinRegularFile(mt_path, &buf) orelse return error.ExpectedTwin;
    try testing.expectEqualStrings(malt_path, twin);
}

test "resolveTwinRegularFile: returns null when sibling is a symlink" {
    // A symlink already tracks its target: swapping the real file is enough,
    // no second swap required.
    const dir = try makeScratch(testing.allocator, "symlink_twin");
    defer {
        fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }

    const malt_path = try std.fmt.allocPrint(testing.allocator, "{s}/malt", .{dir});
    defer testing.allocator.free(malt_path);
    const mt_path = try std.fmt.allocPrint(testing.allocator, "{s}/mt", .{dir});
    defer testing.allocator.free(mt_path);
    try writeFile(malt_path, "m");
    try fs_compat.symLinkAbsolute(malt_path, mt_path, .{});

    var buf: [fs_compat.max_path_bytes]u8 = undefined;
    try testing.expect(updater.resolveTwinRegularFile(malt_path, &buf) == null);
}

test "resolveTwinRegularFile: returns null when no sibling exists" {
    const dir = try makeScratch(testing.allocator, "no_twin");
    defer {
        fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }

    const malt_path = try std.fmt.allocPrint(testing.allocator, "{s}/malt", .{dir});
    defer testing.allocator.free(malt_path);
    try writeFile(malt_path, "m");

    var buf: [fs_compat.max_path_bytes]u8 = undefined;
    try testing.expect(updater.resolveTwinRegularFile(malt_path, &buf) == null);
}

test "resolveTwinRegularFile: returns null for unrelated basenames" {
    const dir = try makeScratch(testing.allocator, "other_name");
    defer {
        fs_compat.deleteTreeAbsolute(dir) catch {};
        testing.allocator.free(dir);
    }

    const other_path = try std.fmt.allocPrint(testing.allocator, "{s}/something-else", .{dir});
    defer testing.allocator.free(other_path);
    try writeFile(other_path, "x");

    var buf: [fs_compat.max_path_bytes]u8 = undefined;
    try testing.expect(updater.resolveTwinRegularFile(other_path, &buf) == null);
}

// --- buildSudoInstallArgv ------------------------------------------------
//
// `install -m 0755 -b -B .old` is the sudo fallback when the user lacks
// write access to the install directory (e.g. /usr/local/bin without
// admin group). One BSD-install invocation gives us atomic copy +
// `.old` backup + executable bit in a single sudo prompt — the same
// rollback contract `atomicReplace` provides for the unprivileged path.
test "buildSudoInstallArgv: shape matches BSD install with .old backup suffix" {
    const argv = updater.buildSudoInstallArgv("/tmp/new-malt", "/usr/local/bin/malt");
    try testing.expectEqual(@as(usize, 9), argv.len);
    try testing.expectEqualStrings("sudo", argv[0]);
    try testing.expectEqualStrings("install", argv[1]);
    try testing.expectEqualStrings("-m", argv[2]);
    try testing.expectEqualStrings("0755", argv[3]);
    try testing.expectEqualStrings("-b", argv[4]);
    try testing.expectEqualStrings("-B", argv[5]);
    try testing.expectEqualStrings(".old", argv[6]);
    try testing.expectEqualStrings("/tmp/new-malt", argv[7]);
    try testing.expectEqualStrings("/usr/local/bin/malt", argv[8]);
}
