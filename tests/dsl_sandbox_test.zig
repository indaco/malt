//! malt -- DSL sandbox tests
//! Tests for path sandboxing validation.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const dsl = malt.dsl;
const sandbox = dsl.sandbox;
const SandboxError = sandbox.SandboxError;

const cellar = "/opt/malt/Cellar/foo/1.0";
const prefix = "/opt/malt";

// ---------------------------------------------------------------------------
// Valid paths
// ---------------------------------------------------------------------------

test "sandbox: valid cellar path" {
    try sandbox.validatePath(
        "/opt/malt/Cellar/foo/1.0/bin/foo",
        cellar,
        prefix,
    );
}

test "sandbox: valid cellar path exact" {
    try sandbox.validatePath(cellar, cellar, prefix);
}

test "sandbox: valid malt prefix path" {
    try sandbox.validatePath(
        "/opt/malt/etc/foo.conf",
        cellar,
        prefix,
    );
}

test "sandbox: valid var dir under prefix" {
    try sandbox.validatePath(
        "/opt/malt/var/log/foo.log",
        cellar,
        prefix,
    );
}

test "sandbox: valid share dir under prefix" {
    try sandbox.validatePath(
        "/opt/malt/share/myapp/data",
        cellar,
        prefix,
    );
}

// ---------------------------------------------------------------------------
// Rejected paths
// ---------------------------------------------------------------------------

test "sandbox: dotdot escape from cellar" {
    const result = sandbox.validatePath(
        "/opt/malt/Cellar/foo/1.0/../../bar",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: dotdot escape from prefix" {
    const result = sandbox.validatePath(
        "/opt/malt/../etc/passwd",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: outside prefix entirely" {
    const result = sandbox.validatePath(
        "/usr/local/bin/foo",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: relative path rejected" {
    const result = sandbox.validatePath(
        "bin/foo",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: empty path rejected" {
    const result = sandbox.validatePath(
        "",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: tmp path rejected" {
    const result = sandbox.validatePath(
        "/tmp/evil",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: home directory rejected" {
    const result = sandbox.validatePath(
        "/Users/attacker/.bashrc",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: dotdot in middle" {
    const result = sandbox.validatePath(
        "/opt/malt/Cellar/foo/1.0/bin/../../../evil",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

// ---------------------------------------------------------------------------
// validateResolved
// ---------------------------------------------------------------------------

test "sandbox: validateResolved accepts valid literal path" {
    // Path does not exist on disk, so only literal validation runs
    try sandbox.validateResolved(
        "/opt/malt/Cellar/foo/1.0/bin/mybin",
        cellar,
        prefix,
    );
}

test "sandbox: validateResolved rejects dotdot" {
    const result = sandbox.validateResolved(
        "/opt/malt/Cellar/foo/1.0/../../evil",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: validateResolved rejects outside prefix" {
    const result = sandbox.validateResolved(
        "/etc/passwd",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

// ---------------------------------------------------------------------------
// Extended sandbox tests
// ---------------------------------------------------------------------------

test "sandbox: symlink escape detected by validateResolved" {
    // Create a temp directory and a symlink pointing outside the sandbox
    const tmp = std.testing.tmpDir(.{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = blk: {
        const n = try std.Io.Dir.realPath(tmp.dir, malt.io_mod.ctx(), &buf);
        break :blk buf[0..n];
    };

    // Create a "cellar" subdir
    try std.Io.Dir.createDirPath(tmp.dir, malt.io_mod.ctx(), "cellar/pkg/1.0/bin");

    // Create a symlink from cellar/pkg/1.0/bin/escape -> /tmp
    const symlink_dir = try std.fs.path.join(
        testing.allocator,
        &.{ tmp_path, "cellar", "pkg", "1.0", "bin", "escape" },
    );
    defer testing.allocator.free(symlink_dir);

    const cellar_dir = try std.fs.path.join(
        testing.allocator,
        &.{ tmp_path, "cellar", "pkg", "1.0" },
    );
    defer testing.allocator.free(cellar_dir);

    malt.fs_compat.cwd().symLink("/tmp", symlink_dir, .{}) catch {
        // If we can't create symlinks (permissions), skip the test
        return;
    };

    // validateResolved should catch the escape because resolved path is /tmp
    const result = sandbox.validateResolved(
        symlink_dir,
        cellar_dir,
        tmp_path,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: deep nesting valid path" {
    try sandbox.validatePath(
        "/opt/malt/Cellar/foo/1.0/share/doc/foo/index.html",
        cellar,
        prefix,
    );
}

test "sandbox: prefix exact match valid" {
    try sandbox.validatePath(
        "/opt/malt",
        cellar,
        prefix,
    );
}

// Regression: `std.mem.startsWith` without a path-component boundary would
// accept look-alike siblings of the malt prefix such as `/opt/malthack`.
// The fix requires either an exact match or a '/' separator after the prefix.
test "sandbox: lookalike malt prefix rejected" {
    const result = sandbox.validatePath(
        "/opt/malthack/etc/passwd",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

// And: the same attack against a standalone cellar (no matching malt_prefix
// overlap) must be rejected too. Uses a disjoint malt_prefix so the cellar
// rule is the only thing that could accept the path.
test "sandbox: lookalike cellar prefix rejected when prefixes disjoint" {
    const disjoint_prefix = "/var/empty";
    const result = sandbox.validatePath(
        "/opt/malt/Cellar/foo/1.0evil/x",
        cellar,
        disjoint_prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}
