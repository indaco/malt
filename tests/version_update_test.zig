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
