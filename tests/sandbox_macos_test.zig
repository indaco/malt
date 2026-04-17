//! malt — sandbox/macos module tests
//!
//! Covers the profile renderer and path-safety guard. The fork/exec
//! path itself is integration-tested via a small Ruby fixture under
//! tests/fixtures/ (see sandbox_macos_exec_test.zig — TODO once the
//! Ruby interpreter is available in CI) — this file stays pure so it
//! runs without a Ruby toolchain.

const std = @import("std");
const testing = std.testing;
const sandbox = @import("malt").sandbox_macos;

test "validatePathForProfile accepts clean absolute paths" {
    try sandbox.validatePathForProfile("/opt/malt");
    try sandbox.validatePathForProfile("/opt/malt/Cellar/foo/1.2.3");
    try sandbox.validatePathForProfile("/tmp/x-y_z.0+1");
}

test "validatePathForProfile rejects SCL metacharacters" {
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/\"hack"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/ha(ck"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/ha)ck"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/ha\\ck"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/ha\nck"));
}

test "validatePathForProfile rejects relative / empty" {
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile(""));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("relative"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("./also"));
}

test "renderRubyProfile deny-by-default, network denied, cellar + prefix subpaths allowed" {
    const profile = try sandbox.renderRubyProfile(
        testing.allocator,
        "/opt/malt/Cellar/foo/1.0",
        "/opt/malt",
    );
    defer testing.allocator.free(profile);
    try testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(allow file-read*)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/Cellar/foo/1.0\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/etc\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/var\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/share\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/opt\")") != null);
}

test "renderRubyProfile refuses unsafe cellar path" {
    try testing.expectError(
        error.UnsafePath,
        sandbox.renderRubyProfile(testing.allocator, "/opt/malt\"/evil", "/opt/malt"),
    );
}

test "renderRubyProfile refuses unsafe prefix path" {
    try testing.expectError(
        error.UnsafePath,
        sandbox.renderRubyProfile(testing.allocator, "/opt/malt/Cellar/foo/1.0", "/opt/m)alt"),
    );
}

test "ScrubbedEnv type smoke — only allowlisted keys" {
    // Compile-time check: the struct has exactly the four allowed env
    // slots and nothing else. If someone ever adds a field here without
    // also thinking through the trust implications, this test fails.
    const info = @typeInfo(sandbox.ScrubbedEnv).@"struct";
    try testing.expectEqual(@as(usize, 4), info.fields.len);
    try testing.expectEqualStrings("home", info.fields[0].name);
    try testing.expectEqualStrings("path", info.fields[1].name);
    try testing.expectEqualStrings("malt_prefix", info.fields[2].name);
    try testing.expectEqualStrings("tmpdir", info.fields[3].name);
}

test "SANDBOX_PATH restricts to system directories only" {
    // Nothing in the minimal PATH should be user-writable.
    try testing.expectEqualStrings("/usr/bin:/bin:/usr/sbin:/sbin", sandbox.SANDBOX_PATH);
}
