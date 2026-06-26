//! malt -- DSL sandbox tests
//! Tests for path sandboxing validation.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const test_io = @import("test_io");
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
// validateWriteDir
// ---------------------------------------------------------------------------

test "sandbox: validateWriteDir accepts a valid path whose dirs don't exist yet" {
    // None of these dirs exist on disk, so the resolve walks to root and the
    // literal validation is what stands — a missing parent can't escape.
    try sandbox.validateWriteDir(
        std.Options.debug_io,
        "/opt/malt/Cellar/foo/1.0/bin/mybin",
        cellar,
        prefix,
    );
}

test "sandbox: validateWriteDir rejects dotdot" {
    const result = sandbox.validateWriteDir(
        std.Options.debug_io,
        "/opt/malt/Cellar/foo/1.0/../../evil",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

test "sandbox: validateWriteDir rejects outside prefix" {
    const result = sandbox.validateWriteDir(
        std.Options.debug_io,
        "/etc/passwd",
        cellar,
        prefix,
    );
    try testing.expectError(SandboxError.PathSandboxViolation, result);
}

// ---------------------------------------------------------------------------
// Extended sandbox tests
// ---------------------------------------------------------------------------

test "sandbox: validateWriteDir catches an intermediate-directory symlink escape" {
    const io = std.Options.debug_io;
    const tmp = std.testing.tmpDir(.{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = buf[0..try std.Io.Dir.realPath(tmp.dir, io, &buf)];

    try std.Io.Dir.createDirPath(tmp.dir, io, "cellar/pkg/1.0/bin");

    // bin/escape is a directory symlink pointing out of the keg.
    const link_dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "cellar", "pkg", "1.0", "bin", "escape" });
    defer testing.allocator.free(link_dir);
    const cellar_dir = try std.fs.path.join(testing.allocator, &.{ tmp_path, "cellar", "pkg", "1.0" });
    defer testing.allocator.free(cellar_dir);
    // A would-be write target *under* the symlinked directory.
    const target = try std.fs.path.join(testing.allocator, &.{ link_dir, "x" });
    defer testing.allocator.free(target);

    test_io.cwd().symLink(io, "/tmp", link_dir, .{}) catch return; // skip if symlinks unavailable

    // The literal path is inside the keg, but its resolved parent is /tmp.
    try testing.expectError(
        SandboxError.PathSandboxViolation,
        sandbox.validateWriteDir(io, target, cellar_dir, tmp_path),
    );
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

// ────────────────────────────────────────────────────────────────────
// pathHasPrefix direct tests. This helper is now public and re-used by
// the plist validator (src/core/services/plist.zig) for the argv path
// allowlist, so its boundary behaviour is load-bearing for two
// independent security checks. Regression here = silent bypass in
// either place.
// ────────────────────────────────────────────────────────────────────

test "pathHasPrefix: identical paths accepted" {
    try testing.expect(sandbox.pathHasPrefix("/opt/malt", "/opt/malt"));
}

test "pathHasPrefix: component-boundary extension accepted" {
    try testing.expect(sandbox.pathHasPrefix("/opt/malt/bin/foo", "/opt/malt"));
}

test "pathHasPrefix: substring-without-boundary rejected" {
    // The whole point of this helper: `/opt/malthack` must NOT match
    // prefix `/opt/malt`. Plain `startsWith` would say yes.
    try testing.expect(!sandbox.pathHasPrefix("/opt/malthack", "/opt/malt"));
    try testing.expect(!sandbox.pathHasPrefix("/opt/malthack/x", "/opt/malt"));
}

test "pathHasPrefix: trailing-slash prefix still accepts bare path" {
    // e.g. prefix computed with a stray trailing '/'
    try testing.expect(sandbox.pathHasPrefix("/opt/malt/bin/foo", "/opt/malt/"));
}

test "pathHasPrefix: empty prefix rejected" {
    // An empty prefix would accept every absolute path — explicitly refuse.
    try testing.expect(!sandbox.pathHasPrefix("/opt/malt", ""));
}

test "pathHasPrefix: shorter path than prefix rejected" {
    try testing.expect(!sandbox.pathHasPrefix("/opt", "/opt/malt"));
}

test "pathHasPrefix: disjoint paths rejected" {
    try testing.expect(!sandbox.pathHasPrefix("/usr/local/bin", "/opt/malt"));
}
