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
const fs_compat = @import("../fs/compat.zig");

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

    if (!std.mem.eql(u8, &expected, &actual)) return error.ChecksumMismatch;
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
};

pub const CosignBlob = struct {
    /// Either `"cosign"` to resolve via PATH, or an absolute path (tests).
    cosign_bin: []const u8 = "cosign",
    /// The blob whose signature is being checked (usually checksums.txt).
    blob_path: []const u8,
    /// Sigstore `.sigstore.json` bundle (cert + signature + rekor entry).
    bundle_path: []const u8,
    /// Regex the Sigstore cert's identity must match - pins the workflow.
    cert_identity_regex: []const u8,
    /// OIDC issuer that signed the cert, e.g. GitHub Actions token issuer.
    oidc_issuer: []const u8,
};

/// Shell out to `cosign verify-blob` with the same flags `install.sh` uses.
/// Exit 0 = verified. Any other outcome maps to a CosignError.
pub fn verifyCosignBlob(allocator: std.mem.Allocator, args: CosignBlob) CosignError!void {
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

    var child = fs_compat.Child.init(&argv, allocator);
    child.stdout_behavior = .ignore;
    child.stderr_behavior = .ignore;
    child.spawn() catch return error.CosignNotFound;
    const term = child.wait() catch return error.CosignVerifyFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.CosignVerifyFailed,
        else => return error.CosignVerifyFailed,
    }
}
