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

/// Resolve `bin` to the path the spawn must use, refusing one that lands
/// inside `prefix`. Returning the path is what lets the caller pin the spawn:
/// vetting alone left the kernel free to resolve a different binary.
fn resolveTrustedCosign(
    io: std.Io,
    bin: []const u8,
    prefix: []const u8,
    environ: std.process.Environ,
    out: []u8,
) CosignError![]const u8 {
    // No prefix means no guard (tests only) - spawn the name as given.
    if (prefix.len == 0) return bin;

    // Resolve the prefix too, or the comparison is spelling-sensitive: on
    // macOS `/tmp` is a symlink to `/private/tmp`, so a resolved binary path
    // would never match a prefix given in the other form. Falls back to the
    // literal when the prefix does not exist yet - nothing can resolve inside
    // a prefix that is not there.
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix_real = if (std.Io.Dir.cwd().realPathFile(io, prefix, &prefix_buf)) |pn|
        prefix_buf[0..pn]
    else |_|
        prefix;

    // An explicit path is checked as given; a bare name is searched on PATH.
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        const n = std.Io.Dir.cwd().realPathFile(io, bin, out) catch return error.CosignNotFound;
        if (resolvedInsidePrefix(out[0..n], prefix_real)) return error.CosignUntrusted;
        return out[0..n];
    }

    const path_env = std.process.Environ.getPosix(environ, "PATH") orelse return error.CosignNotFound;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    var probe: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next()) |dir| {
        const cand = std.fmt.bufPrint(&probe, "{s}/{s}", .{ dir, bin }) catch continue;
        // Mere existence is the wrong test: execvp walks past an entry it
        // cannot exec, so a non-executable file (or a directory) named
        // `cosign` earlier on PATH would end the search here while the real
        // resolution carried on into the prefix.
        const st = std.Io.Dir.cwd().statFile(io, cand, .{}) catch continue;
        if (st.kind != .file) continue;
        std.Io.Dir.cwd().access(io, cand, .{ .execute = true }) catch continue;
        // Unresolvable means unvettable, so skip it the way execvp skips one
        // it cannot exec. Safe because the spawn runs whatever this walk
        // returns - a skipped candidate can never be the one that executes.
        const n = std.Io.Dir.cwd().realPathFile(io, cand, out) catch continue;
        if (resolvedInsidePrefix(out[0..n], prefix_real)) return error.CosignUntrusted;
        return out[0..n];
    }
    return error.CosignNotFound;
}

/// Shell out to `cosign verify-blob` with the same flags `install.sh` uses.
/// Exit 0 = verified. Any other outcome maps to a CosignError.
pub fn verifyCosignBlob(io: std.Io, args: CosignBlob) CosignError!void {
    // A path with a slash makes the spawn skip its own PATH search, so the
    // vetted binary is the one that runs. The residual TOCTOU is accepted:
    // closing it needs fexecve, which std.process.spawn does not expose.
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cosign_bin = try resolveTrustedCosign(io, args.cosign_bin, args.prefix, args.environ, &resolved_buf);

    const argv = [_][]const u8{
        cosign_bin,
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

test "an unexecutable PATH entry does not end the search short of the prefix" {
    const io = std.Options.debug_io;
    const a = std.testing.allocator;

    // Two directories on PATH, the decoy first: a plain file and a directory,
    // both named `cosign`, neither of which execvp would run. If the guard
    // stops at either, the shim in the prefix is spawned unchecked.
    const root = try std.fmt.allocPrint(a, "/tmp/malt_cosign_decoy_{d}", .{std.c.getpid()});
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const decoy_dir = try std.fmt.allocPrint(a, "{s}/decoy", .{root});
    defer a.free(decoy_dir);
    const prefix = try std.fmt.allocPrint(a, "{s}/prefix", .{root});
    defer a.free(prefix);
    const prefix_bin = try std.fmt.allocPrint(a, "{s}/bin", .{prefix});
    defer a.free(prefix_bin);
    try std.Io.Dir.cwd().createDirPath(io, decoy_dir);
    try std.Io.Dir.cwd().createDirPath(io, prefix_bin);

    const shim = try std.fmt.allocPrint(a, "{s}/cosign", .{prefix_bin});
    defer a.free(shim);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, shim, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "placeholder\n");
        try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    }

    const path_val = try std.fmt.allocPrintSentinel(a, "PATH={s}:{s}", .{ decoy_dir, prefix_bin }, 0);
    defer a.free(path_val);
    const entries = [_:null]?[*:0]const u8{path_val.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    const args: CosignBlob = .{
        .cosign_bin = "cosign",
        .environ = environ,
        .prefix = prefix,
        .blob_path = "/dev/null",
        .bundle_path = "/dev/null",
        .cert_identity_regex = "^x$",
        .oidc_issuer = "https://example.invalid",
    };

    // Decoy 1: a readable, non-executable regular file.
    const decoy = try std.fmt.allocPrint(a, "{s}/cosign", .{decoy_dir});
    defer a.free(decoy);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, decoy, .{ .truncate = true });
        defer f.close(io);
        try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o644));
    }
    try std.testing.expectError(error.CosignUntrusted, verifyCosignBlob(io, args));

    // Decoy 2: a searchable directory, which `access(X_OK)` alone accepts.
    try std.Io.Dir.cwd().deleteFile(io, decoy);
    try std.Io.Dir.cwd().createDirPath(io, decoy);
    try std.testing.expectError(error.CosignUntrusted, verifyCosignBlob(io, args));
}

test "the resolver pins the spawn to the candidate it vetted" {
    const io = std.Options.debug_io;
    const a = std.testing.allocator;

    // The decoy passes `access(X_OK)` but `execve` rejects it with ENOENT, so
    // the kernel's own PATH walk would carry on into the prefix. The resolver
    // must hand back the decoy, which is what pins the spawn away from there.
    const root = try std.fmt.allocPrint(a, "/tmp/malt_cosign_pin_{d}", .{std.c.getpid()});
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const decoy_dir = try std.fmt.allocPrint(a, "{s}/decoy", .{root});
    defer a.free(decoy_dir);
    const prefix = try std.fmt.allocPrint(a, "{s}/prefix", .{root});
    defer a.free(prefix);
    const prefix_bin = try std.fmt.allocPrint(a, "{s}/bin", .{prefix});
    defer a.free(prefix_bin);
    try std.Io.Dir.cwd().createDirPath(io, decoy_dir);
    try std.Io.Dir.cwd().createDirPath(io, prefix_bin);

    for ([_][]const u8{ decoy_dir, prefix_bin }) |dir| {
        const p = try std.fmt.allocPrint(a, "{s}/cosign", .{dir});
        defer a.free(p);
        const f = try std.Io.Dir.createFileAbsolute(io, p, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/nonexistent/interp\n");
        try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    }

    const path_val = try std.fmt.allocPrintSentinel(a, "PATH={s}:{s}", .{ decoy_dir, prefix_bin }, 0);
    defer a.free(path_val);
    const entries = [_:null]?[*:0]const u8{path_val.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = try resolveTrustedCosign(io, "cosign", prefix, environ, &buf);
    try std.testing.expect(std.mem.endsWith(u8, got, "/decoy/cosign"));
    try std.testing.expect(!resolvedInsidePrefix(got, prefix));
}

test "the resolver reports not-found rather than trusting an unresolvable name" {
    const io = std.Options.debug_io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // An explicit path that does not exist: the spawn would have failed the
    // same way, so the error stays CosignNotFound.
    try std.testing.expectError(error.CosignNotFound, resolveTrustedCosign(
        io,
        "/tmp/malt_cosign_absent_xyz",
        "/opt/malt",
        .empty,
        &buf,
    ));
    // No PATH to search, and a PATH with no hit: both are a missing cosign.
    try std.testing.expectError(error.CosignNotFound, resolveTrustedCosign(io, "cosign", "/opt/malt", .empty, &buf));
    const path_val: [:0]const u8 = "PATH=/tmp/malt_cosign_absent_dir_xyz";
    const entries = [_:null]?[*:0]const u8{path_val.ptr};
    try std.testing.expectError(error.CosignNotFound, resolveTrustedCosign(
        io,
        "cosign",
        "/opt/malt",
        .{ .block = .{ .slice = &entries } },
        &buf,
    ));
}

test "an empty prefix disables the guard and passes the name through" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = try resolveTrustedCosign(std.Options.debug_io, "cosign", "", .empty, &buf);
    try std.testing.expectEqualStrings("cosign", got);
}

test "a PATH entry symlinked into the prefix is refused" {
    const io = std.Options.debug_io;
    const a = std.testing.allocator;

    // The link sits outside the prefix but its target does not. Vetting the
    // resolved path is what catches this; comparing the candidate would not.
    const root = try std.fmt.allocPrint(a, "/tmp/malt_cosign_link_{d}", .{std.c.getpid()});
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{root});
    defer a.free(outside);
    const prefix = try std.fmt.allocPrint(a, "{s}/prefix", .{root});
    defer a.free(prefix);
    const prefix_bin = try std.fmt.allocPrint(a, "{s}/bin", .{prefix});
    defer a.free(prefix_bin);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    try std.Io.Dir.cwd().createDirPath(io, prefix_bin);

    const target = try std.fmt.allocPrint(a, "{s}/cosign", .{prefix_bin});
    defer a.free(target);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, target, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/nonexistent/interp\n");
        try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    }
    const link = try std.fmt.allocPrint(a, "{s}/cosign", .{outside});
    defer a.free(link);
    try std.Io.Dir.symLinkAbsolute(io, target, link, .{});

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_val = try std.fmt.allocPrintSentinel(a, "PATH={s}", .{outside}, 0);
    defer a.free(path_val);
    const entries = [_:null]?[*:0]const u8{path_val.ptr};
    try std.testing.expectError(error.CosignUntrusted, resolveTrustedCosign(
        io,
        "cosign",
        prefix,
        .{ .block = .{ .slice = &entries } },
        &buf,
    ));

    // Explicit-path form takes the same route through the symlink.
    try std.testing.expectError(error.CosignUntrusted, resolveTrustedCosign(io, link, prefix, .empty, &buf));
}

test "a candidate that cannot be resolved is skipped, never trusted" {
    const io = std.Options.debug_io;
    const a = std.testing.allocator;

    // An executable, prefix-external cosign the walk reaches and accepts on
    // every check but the last: an undersized output buffer makes realpath
    // fail there. The candidate must be skipped, not handed to the spawn.
    const root = try std.fmt.allocPrint(a, "/tmp/malt_cosign_unres_{d}", .{std.c.getpid()});
    defer a.free(root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const dir = try std.fmt.allocPrint(a, "{s}/bin", .{root});
    defer a.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const cosign = try std.fmt.allocPrint(a, "{s}/cosign", .{dir});
    defer a.free(cosign);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, cosign, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "#!/nonexistent/interp\n");
        try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    }

    const path_val = try std.fmt.allocPrintSentinel(a, "PATH={s}", .{dir}, 0);
    defer a.free(path_val);
    const entries = [_:null]?[*:0]const u8{path_val.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };

    // Returning any path here would hand the spawn something unvetted.
    var small: [64]u8 = undefined;
    try std.testing.expectError(error.CosignNotFound, resolveTrustedCosign(
        io,
        "cosign",
        "/opt/malt",
        environ,
        &small,
    ));
}
