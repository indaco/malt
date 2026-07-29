//! malt - trust layer for self-update.
//!
//! Two independent primitives the updater composes:
//!   1. `verifySha256` / `lookupSha256` — integrity against a
//!      GoReleaser-style `checksums.txt`.
//!   2. `verifyCosignBlob` — Sigstore signature of that checksums file,
//!      mirroring `scripts/install.sh` exactly.
//!
//! Pure string/bytes in, errors out. No network, no filesystem (except
//! the cosign subprocess, which is injected via `cosign_bin`).

const std = @import("std");
const hash = @import("../core/hash.zig");
const read = @import("../fs/read.zig");

pub const ChecksumError = error{
    /// `bytes` did not hash to the value named in `expected_hex`.
    ChecksumMismatch,
    /// `expected_hex` was not 64 hex digits.
    InvalidHex,
};

/// Verify that SHA256(bytes) equals `expected_hex`. Case-insensitive.
pub fn verifySha256(bytes: []const u8, expected_hex: []const u8) ChecksumError!void {
    if (expected_hex.len != 64) return error.InvalidHex;
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch return error.InvalidHex;

    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});

    // The expected digest is public: constant-time here is for uniformity
    // across malt's SHA paths, not to close a live oracle.
    if (!std.crypto.timing_safe.eql([32]u8, expected, actual)) return error.ChecksumMismatch;
}

/// Find the SHA256 hex for `archive_name` in a GoReleaser-style
/// `checksums.txt`. Line format: `<64-hex>  <filename>\n`.
/// Returns null if the archive is not listed.
pub fn lookupSha256(checksums_txt: []const u8, archive_name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, checksums_txt, '\n');
    while (it.next()) |raw| {
        // Tolerate CRLF endings from Windows-edited fixtures.
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 66) continue; // 64 hex + 2 spaces + >=1 name char
        // GoReleaser writes `<hex>  <name>` with two spaces.
        const sep = std.mem.indexOf(u8, line, "  ") orelse continue;
        if (sep != 64) continue;
        const name = line[sep + 2 ..];
        if (!std.mem.eql(u8, name, archive_name)) continue;
        return line[0..64];
    }
    return null;
}

pub const CosignError = error{
    /// `cosign_bin` could not be spawned (not installed, not executable).
    CosignNotFound,
    /// `cosign verify-blob` exited non-zero - signature did not verify.
    CosignVerifyFailed,
    /// The `cosign` that would run resolves inside malt's own prefix, which
    /// packages can write to. Refuse rather than trust its exit status.
    CosignUntrusted,
};

pub const CosignBlob = struct {
    /// Either `"cosign"` to resolve via PATH, or an absolute path (tests).
    cosign_bin: []const u8 = "cosign",
    /// Process environment, for the PATH lookup that mirrors execvp.
    environ: std.process.Environ = .empty,
    /// malt's install prefix. A `cosign` resolving inside it is refused.
    prefix: []const u8 = "",
    /// The blob whose signature is being checked (usually checksums.txt).
    blob_path: []const u8,
    /// Sigstore `.sigstore.json` bundle (cert + signature + rekor entry).
    bundle_path: []const u8,
    /// Regex the Sigstore cert's identity must match - pins the workflow.
    cert_identity_regex: []const u8,
    /// OIDC issuer that signed the cert, e.g. GitHub Actions token issuer.
    oidc_issuer: []const u8,
};

pub const VerifyError = error{
    CosignNotFound,
    CosignVerifyFailed,
    CosignUntrusted,
    /// `archive_name` has no matching line in `checksums.txt`.
    ChecksumMissing,
    ChecksumMismatch,
    InvalidHex,
    /// A required input file could not be read (OS error, permissions).
    ReadFailed,
    OutOfMemory,
};

pub const VerifyInputs = struct {
    /// `"cosign"` for PATH lookup, or an absolute path (tests).
    cosign_bin: []const u8 = "cosign",
    /// Process environment, for the PATH lookup that mirrors execvp.
    environ: std.process.Environ = .empty,
    /// malt's install prefix. A `cosign` resolving inside it is refused.
    prefix: []const u8 = "",
    tarball_path: []const u8,
    checksums_path: []const u8,
    sigstore_path: []const u8,
    /// Filename as it appears in `checksums.txt`, e.g. `malt_0.7.0_darwin_all.tar.gz`.
    archive_name: []const u8,
    cert_identity_regex: []const u8,
    oidc_issuer: []const u8,
};

/// Verify a downloaded release end-to-end: cosign-verify the checksums
/// file, then SHA256-verify the tarball against the now-trusted list.
/// Pure file I/O + subprocess — the caller is responsible for placing
/// the three input files on disk. Testable without HTTP.
pub fn verifyAll(io: std.Io, allocator: std.mem.Allocator, in: VerifyInputs) VerifyError!void {
    verifyCosignBlob(io, .{
        .cosign_bin = in.cosign_bin,
        .environ = in.environ,
        .prefix = in.prefix,
        .blob_path = in.checksums_path,
        .bundle_path = in.sigstore_path,
        .cert_identity_regex = in.cert_identity_regex,
        .oidc_issuer = in.oidc_issuer,
    }) catch |e| return e;

    const checksums = read.readFileAllAbsolute(io, allocator, in.checksums_path, 1 << 20) catch
        return error.ReadFailed;
    defer allocator.free(checksums);

    const expected_hex = lookupSha256(checksums, in.archive_name) orelse return error.ChecksumMissing;
    if (expected_hex.len != 64) return error.InvalidHex;
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch return error.InvalidHex;

    // Stream to bound RSS during self-update — the tarball can be 256 MiB.
    const actual = hash.hashFileSha256Raw(io, in.tarball_path) catch return error.ReadFailed;
    // The expected digest comes from the cosign-verified checksums file, so
    // it is public: constant-time here is for uniformity, not a live oracle.
    if (!std.crypto.timing_safe.eql([32]u8, expected, actual)) return error.ChecksumMismatch;
}

/// True when `path` sits inside malt's own install prefix.
///
/// `cosign` is normally resolved off `PATH`, which includes `<prefix>/bin` —
/// a directory malt itself installs packages into, and which any of the
/// package-controlled write paths can reach. A `cosign` shim landing there
/// would turn every later `mt version update` into a rubber stamp, since the
/// only signal this module reads is the child's exit status. Refuse to treat
/// a verifier that malt (or a package) could have written as trusted.
pub fn resolvedInsidePrefix(resolved: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (!std.mem.startsWith(u8, resolved, prefix)) return false;
    if (resolved.len == prefix.len) return true;
    if (prefix[prefix.len - 1] == '/') return true;
    return resolved[prefix.len] == '/';
}

/// Locate `bin` on `PATH` and reject it when it resolves inside `prefix`.
/// A bare name with no match is left to the spawn to fail as CosignNotFound.
fn rejectPrefixResidentTool(
    io: std.Io,
    bin: []const u8,
    prefix: []const u8,
    environ: std.process.Environ,
) CosignError!void {
    if (prefix.len == 0) return;
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Resolve the prefix too, or the comparison is spelling-sensitive: on
    // macOS `/tmp` is a symlink to `/private/tmp`, so a resolved binary path
    // would never match a prefix given in the other form. Falls back to the
    // literal when the prefix does not exist yet.
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_real = if (std.Io.Dir.cwd().realPathFile(io, prefix, &prefix_buf)) |pn|
        prefix_buf[0..pn]
    else |_|
        prefix;

    // An explicit path is checked as given; a bare name is searched on PATH.
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        const n = std.Io.Dir.cwd().realPathFile(io, bin, &resolved_buf) catch return;
        if (resolvedInsidePrefix(resolved_buf[0..n], prefix_real)) return error.CosignUntrusted;
        return;
    }

    const path_env = std.process.Environ.getPosix(environ, "PATH") orelse return;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    var probe: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next()) |dir| {
        const cand = std.fmt.bufPrint(&probe, "{s}/{s}", .{ dir, bin }) catch continue;
        std.Io.Dir.cwd().access(io, cand, .{}) catch continue;
        // First hit wins, exactly as execvp would resolve it.
        const n = std.Io.Dir.cwd().realPathFile(io, cand, &resolved_buf) catch return;
        if (resolvedInsidePrefix(resolved_buf[0..n], prefix_real)) return error.CosignUntrusted;
        return;
    }
}

/// Shell out to `cosign verify-blob` with the same flags `install.sh` uses.
/// Exit 0 = verified. Any other outcome maps to a CosignError.
pub fn verifyCosignBlob(io: std.Io, args: CosignBlob) CosignError!void {
    try rejectPrefixResidentTool(io, args.cosign_bin, args.prefix, args.environ);

    const argv = [_][]const u8{
        args.cosign_bin,
        "verify-blob",
        "--bundle",
        args.bundle_path,
        "--certificate-identity-regexp",
        args.cert_identity_regex,
        "--certificate-oidc-issuer",
        args.oidc_issuer,
        args.blob_path,
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.CosignNotFound;
    const term = child.wait(io) catch return error.CosignVerifyFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.CosignVerifyFailed,
        else => return error.CosignVerifyFailed,
    }
}

test "resolvedInsidePrefix: only a component-boundary match counts" {
    try std.testing.expect(resolvedInsidePrefix("/opt/malt/bin/cosign", "/opt/malt"));
    try std.testing.expect(resolvedInsidePrefix("/opt/malt", "/opt/malt"));
    try std.testing.expect(resolvedInsidePrefix("/opt/malt/", "/opt/malt/"));
    // A sibling that merely shares a textual prefix is not inside it.
    try std.testing.expect(!resolvedInsidePrefix("/opt/malthack/bin/cosign", "/opt/malt"));
    try std.testing.expect(!resolvedInsidePrefix("/usr/local/bin/cosign", "/opt/malt"));
    try std.testing.expect(!resolvedInsidePrefix("/opt/homebrew/bin/cosign", "/opt/malt"));
    // An empty prefix disables the check rather than matching everything.
    try std.testing.expect(!resolvedInsidePrefix("/anything", ""));
}

test "verifyCosignBlob refuses a cosign that lives inside the prefix" {
    const io = std.Options.debug_io;
    const a = std.testing.allocator;

    // Stand up a fake prefix with an executable `cosign` in its bin/, exactly
    // where a package (or one of the path-traversal bugs) could drop one.
    const prefix = try std.fmt.allocPrint(a, "/tmp/malt_cosign_trust_{d}", .{std.c.getpid()});
    defer a.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{prefix});
    defer a.free(bin);
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const shim = try std.fmt.allocPrint(a, "{s}/cosign", .{bin});
    defer a.free(shim);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, shim, .{ .truncate = true });
        defer f.close(io);
        // Contents are deliberately inert: the guard refuses on *location*
        // before anything is spawned, so a shim that could actually run would
        // add nothing to the test but a shell-invocation pattern under src/
        // (which `tests/spawn_invariant_test.zig` rightly rejects).
        try f.writeStreamingAll(io, "placeholder\n");
        try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    }

    // Explicit-path form: refused because it resolves inside the prefix.
    try std.testing.expectError(error.CosignUntrusted, verifyCosignBlob(io, .{
        .cosign_bin = shim,
        .prefix = prefix,
        .blob_path = "/dev/null",
        .bundle_path = "/dev/null",
        .cert_identity_regex = "^x$",
        .oidc_issuer = "https://example.invalid",
    }));

    // PATH form: same shim, found by search, same refusal.
    const path_val = try std.fmt.allocPrintSentinel(a, "PATH={s}", .{bin}, 0);
    defer a.free(path_val);
    const entries = [_:null]?[*:0]const u8{path_val.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    try std.testing.expectError(error.CosignUntrusted, verifyCosignBlob(io, .{
        .cosign_bin = "cosign",
        .environ = environ,
        .prefix = prefix,
        .blob_path = "/dev/null",
        .bundle_path = "/dev/null",
        .cert_identity_regex = "^x$",
        .oidc_issuer = "https://example.invalid",
    }));
}
