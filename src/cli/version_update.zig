//! malt - self-update command.
//!
//! Thin orchestrator over `src/update/` modules: argument parsing,
//! user I/O, download, verification, swap. The trust posture mirrors
//! `scripts/install.sh` exactly - SHA256 over the tarball and cosign
//! verification of the `checksums.txt` Sigstore bundle, bypassed only
//! when the user opts in via both `--no-verify` and
//! `MALT_ALLOW_UNVERIFIED=1`.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const io_mod = @import("../ui/io.zig");
const builtin = @import("builtin");
const client_mod = @import("../net/client.zig");
const archive = @import("../fs/archive.zig");
const output = @import("../ui/output.zig");
const cleanup = @import("../update/cleanup.zig");
const origin = @import("../update/origin.zig");
const release = @import("../update/release.zig");
const verify = @import("../update/verify.zig");
const swap = @import("../update/swap.zig");

const current_version = @import("../version.zig").value;
const releases_api = "https://api.github.com/repos/indaco/malt/releases/latest";
const checksums_name = "checksums.txt";
const sigstore_name = "checksums.txt.sigstore.json";
// Pins the signature to the exact workflow that produced the release.
// A token able to upload a replacement checksums.txt cannot forge this.
const cert_identity_regex = "^https://github.com/indaco/malt/\\.github/workflows/release\\.yml@";
const oidc_issuer = "https://token.actions.githubusercontent.com";

pub const Opts = struct {
    check: bool = false,
    yes: bool = false,
    no_verify: bool = false,
    cleanup: bool = false,
};

pub fn parseArgs(args: []const []const u8) Opts {
    var opts = Opts{};
    for (args) |a| {
        if (std.mem.eql(u8, a, "--check")) opts.check = true;
        if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) opts.yes = true;
        if (std.mem.eql(u8, a, "--no-verify")) opts.no_verify = true;
        if (std.mem.eql(u8, a, "--cleanup")) opts.cleanup = true;
    }
    return opts;
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const opts = parseArgs(args);

    if (opts.cleanup) return runCleanup();

    // Brew-managed installs must be upgraded via `brew`, otherwise the
    // Cellar/Caskroom metadata drifts from the file on disk. Route these
    // users at the tool that owns their install.
    if (detectOrigin() == .homebrew) {
        output.info("This malt was installed via Homebrew.", .{});
        output.info("Update with: brew upgrade --cask malt", .{});
        return;
    }

    output.info("Current version: {s}", .{current_version});
    output.info("Checking for updates...", .{});

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    var resp = http.get(releases_api) catch {
        output.err("Cannot reach GitHub API", .{});
        return error.Aborted;
    };
    defer resp.deinit();
    if (resp.status != 200) {
        output.err("GitHub API returned status {d}", .{resp.status});
        return error.Aborted;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch {
        output.err("Failed to parse release info", .{});
        return error.Aborted;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            output.err("Release payload was not a JSON object", .{});
            return error.Aborted;
        },
    };

    const tag = release.strField(obj, "tag_name") orelse {
        output.err("No tag_name in release", .{});
        return error.Aborted;
    };
    const latest = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;

    if (std.mem.eql(u8, latest, current_version)) {
        output.info("Already up to date ({s})", .{current_version});
        return;
    }
    output.info("New version available: {s} (current: {s})", .{ latest, current_version });

    if (opts.check) {
        output.info("Run 'mt version update' to install", .{});
        return;
    }

    const assets_val = obj.get("assets") orelse {
        output.err("No assets in release", .{});
        return error.Aborted;
    };
    const assets = switch (assets_val) {
        .array => |a| a,
        else => {
            output.err("Invalid assets", .{});
            return error.Aborted;
        },
    };

    // --- resolve all three URLs up front so we fail fast if the
    //     release is malformed (missing checksums is a workflow bug,
    //     not a soft condition to route around). ---
    const arch_str = if (builtin.cpu.arch == .aarch64) "arm64" else "x86_64";
    const tarball_url = release.pickAssetUrl(assets, arch_str) orelse {
        output.err("No matching binary found for darwin {s}", .{arch_str});
        return error.Aborted;
    };
    const checksums_url = release.pickAssetUrlByName(assets, checksums_name) orelse {
        output.err("Release is missing {s}", .{checksums_name});
        return error.Aborted;
    };
    const archive_name = std.fs.path.basename(tarball_url);

    // --- scratch dir under $TMPDIR, pid-tagged so concurrent invocations
    //     don't collide and `rm -rf` of a stale dir never hits /tmp root. ---
    var scratch_buf: [std.fs.max_path_bytes]u8 = undefined;
    const scratch = try buildScratchDir(&scratch_buf);
    // Pre-clean any leftover scratch from an aborted prior run; makeDirAbsolute below surfaces real errors.
    fs_compat.deleteTreeAbsolute(scratch) catch {};
    fs_compat.makeDirAbsolute(scratch) catch {
        output.err("Cannot create scratch dir at {s}", .{scratch});
        return error.Aborted;
    };
    // Teardown: scratch is pid-tagged, so a leftover tree is only our own dead run's.
    defer fs_compat.deleteTreeAbsolute(scratch) catch {};

    // --- download tarball + checksums (always needed for SHA verify) ---
    output.info("Downloading {s}...", .{archive_name});
    const tarball_path = try writeDownload(allocator, &http, tarball_url, scratch, archive_name);
    defer allocator.free(tarball_path);
    const checksums_path = try writeDownload(allocator, &http, checksums_url, scratch, checksums_name);
    defer allocator.free(checksums_path);

    // --- verification phase ---
    try runVerification(.{
        .allocator = allocator,
        .http = &http,
        .assets = assets,
        .scratch = scratch,
        .tarball_path = tarball_path,
        .checksums_path = checksums_path,
        .archive_name = archive_name,
        .opts = opts,
    });

    // --- extract + find binary ---
    const extract_dir_buf = try std.fmt.allocPrint(allocator, "{s}/extract", .{scratch});
    defer allocator.free(extract_dir_buf);
    fs_compat.makeDirAbsolute(extract_dir_buf) catch {
        output.err("Cannot create extract dir", .{});
        return error.Aborted;
    };
    archive.extractTarGz(tarball_path, extract_dir_buf) catch {
        output.err("Failed to extract update", .{});
        return error.Aborted;
    };

    var new_binary_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_binary = release.findReleaseBinary(allocator, extract_dir_buf, &new_binary_buf) orelse {
        output.err("Binary 'malt' not found in release archive", .{});
        return error.Aborted;
    };

    // Separate stack buffer so `executablePath` doesn't overwrite `new_binary`.
    var self_exe_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io_mod.ctx(), &self_exe_buf) catch {
        output.err("Cannot determine current binary path", .{});
        return error.Aborted;
    };
    const self_exe = self_exe_buf[0..n];

    // install.sh ships two independent binaries (`malt` and `mt`) side by
    // side; swapping only the invoked one leaves the other on the old
    // version. Detect the twin so we can update both in lockstep.
    var twin_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const twin_path: ?[]const u8 = resolveTwinRegularFile(self_exe, &twin_buf);

    // --- confirm with the user unless --yes. TTY-only by design: CI
    //     or scripted runs must pass --yes explicitly. ---
    if (!opts.yes) {
        var prompt_buf: [320]u8 = undefined;
        const prompt = if (twin_path) |tp|
            std.fmt.bufPrint(&prompt_buf, "Replace {s} and {s} with {s}? Type 'yes' to confirm: ", .{ self_exe, tp, latest }) catch "Type 'yes' to confirm: "
        else
            std.fmt.bufPrint(&prompt_buf, "Replace {s} with {s}? Type 'yes' to confirm: ", .{ self_exe, latest }) catch "Type 'yes' to confirm: ";
        if (!output.confirmTyped("yes", prompt)) {
            output.info("Aborted", .{});
            return;
        }
    }

    output.info("Replacing {s}...", .{self_exe});
    swap.atomicReplace(self_exe, new_binary) catch |e| switch (e) {
        error.StagingFailed, error.SwapFailed => {
            output.err("Failed to replace {s}. You may need sudo.", .{self_exe});
            output.info("Manual update: sudo cp {s} {s}", .{ new_binary, self_exe });
            return;
        },
        error.RollbackFailed => {
            // Two renames went one-and-a-half: target is gone, .old is still
            // the previous binary. The next invocation the user makes
            // cannot find `malt` on PATH, so surface the recovery path loudly.
            output.err("Update aborted mid-swap; rollback also failed.", .{});
            output.info("Restore the previous binary with:", .{});
            output.info("  sudo mv {s}.old {s}", .{ self_exe, self_exe });
            return error.Aborted;
        },
    };

    if (twin_path) |tp| {
        output.info("Replacing {s}...", .{tp});
        swap.atomicReplace(tp, new_binary) catch |e| {
            // Don't roll back self: one updated binary beats a forced
            // downgrade on the one the user just invoked. Surface the
            // manual fix so they can close the gap.
            output.err("Failed to replace {s}: {s}", .{ tp, @errorName(e) });
            output.warn("{s} is now {s} but {s} is still the previous version.", .{ self_exe, latest, tp });
            output.info("Finish manually: sudo cp {s} {s}", .{ new_binary, tp });
            output.info("Updated to {s} (previous {s} kept at {s}.old)", .{ latest, std.fs.path.basename(self_exe), self_exe });
            return;
        };
        output.info("Updated {s} and {s} to {s} (previous kept at *.old)", .{ self_exe, tp, latest });
        return;
    }

    output.info("Updated to {s} (previous kept at {s}.old)", .{ latest, self_exe });
}

/// Return the sibling binary path (`malt` ↔ `mt`) next to `self_exe`, but
/// only when it is a plain regular file that needs its own swap. Symlinks
/// track their target automatically after a swap, so we skip those.
/// Returned slice points into `buf`.
pub fn resolveTwinRegularFile(self_exe: []const u8, buf: []u8) ?[]const u8 {
    const base = std.fs.path.basename(self_exe);
    const twin_base: []const u8 =
        if (std.mem.eql(u8, base, "malt")) "mt" else if (std.mem.eql(u8, base, "mt")) "malt" else return null;
    const dir = std.fs.path.dirname(self_exe) orelse return null;

    const twin_path = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, twin_base }) catch return null;

    // `readLinkAbsolute` is the cheapest lstat here: success = symlink
    // (skip), `error.NotLink` = regular file to update, anything else
    // (missing, permission) = nothing we can usefully replace.
    var link_buf: [fs_compat.max_path_bytes]u8 = undefined;
    if (fs_compat.readLinkAbsolute(twin_path, &link_buf)) |_| {
        return null;
    } else |err| switch (err) {
        error.NotLink => return twin_path,
        else => return null,
    }
}

/// Build `$TMPDIR/malt-update-<pid>/`. Falls back to `/tmp` when
/// `$TMPDIR` is unset (sandboxes, minimal environments).
fn buildScratchDir(buf: []u8) ![]const u8 {
    const base = fs_compat.getenv("TMPDIR") orelse "/tmp";
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const pid = std.c.getpid();
    return std.fmt.bufPrint(buf, "{s}/malt-update-{d}", .{ trimmed, pid });
}

/// Download `url` into `dir/name`, return the absolute path.
/// Caller owns the returned slice.
fn writeDownload(
    allocator: std.mem.Allocator,
    http: *client_mod.HttpClient,
    url: []const u8,
    dir: []const u8,
    name: []const u8,
) ![]const u8 {
    var resp = http.get(url) catch {
        output.err("Download failed: {s}", .{url});
        return error.Aborted;
    };
    defer resp.deinit();
    if (resp.status != 200) {
        output.err("Download returned status {d} for {s}", .{ resp.status, url });
        return error.Aborted;
    }
    return writeResponseBody(allocator, dir, name, resp.body);
}

/// Write `body` to `dir/name`, return the caller-owned absolute path.
/// Split from `writeDownload` so the file-write half is reachable under
/// `testing.allocator` without a live HTTP client (BUG-012 regression guard).
pub fn writeResponseBody(
    allocator: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    body: []const u8,
) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    errdefer allocator.free(path);
    const f = fs_compat.createFileAbsolute(path, .{}) catch {
        output.err("Cannot create {s}", .{path});
        return error.Aborted;
    };
    defer f.close();
    f.writeAll(body) catch {
        output.err("Failed to write {s}", .{path});
        return error.Aborted;
    };
    return path;
}

const RunVerification = struct {
    allocator: std.mem.Allocator,
    http: *client_mod.HttpClient,
    assets: std.json.Array,
    scratch: []const u8,
    tarball_path: []const u8,
    checksums_path: []const u8,
    archive_name: []const u8,
    opts: Opts,
};

/// Run cosign + SHA256 verification, or print a loud bypass warning
/// when the user has opted out of both with `--no-verify` and
/// `MALT_ALLOW_UNVERIFIED=1`. Fails the update on any verify error.
fn runVerification(rv: RunVerification) !void {
    if (rv.opts.no_verify and unverifiedAllowed()) {
        output.warn("MALT_ALLOW_UNVERIFIED=1 and --no-verify - skipping signature and checksum verification", .{});
        output.warn("This update will not be cryptographically verified. Install cosign to enable verification.", .{});
        return;
    }

    const sigstore_url = release.pickAssetUrlByName(rv.assets, sigstore_name) orelse {
        output.err("Release is missing {s}", .{sigstore_name});
        return error.Aborted;
    };
    const sigstore_path = try writeDownload(rv.allocator, rv.http, sigstore_url, rv.scratch, sigstore_name);
    defer rv.allocator.free(sigstore_path);

    output.info("Verifying cosign signature + SHA256 checksum...", .{});
    verify.verifyAll(rv.allocator, .{
        .tarball_path = rv.tarball_path,
        .checksums_path = rv.checksums_path,
        .sigstore_path = sigstore_path,
        .archive_name = rv.archive_name,
        .cert_identity_regex = cert_identity_regex,
        .oidc_issuer = oidc_issuer,
    }) catch |e| switch (e) {
        error.CosignNotFound => {
            output.err("cosign is required to verify the release signature.", .{});
            output.info("Install: https://docs.sigstore.dev/cosign/system_config/installation/ (e.g. `brew install cosign`)", .{});
            output.info("To bypass (not recommended): MALT_ALLOW_UNVERIFIED=1 mt version update --no-verify", .{});
            return error.Aborted;
        },
        error.CosignVerifyFailed => {
            output.err("cosign signature verification failed for {s}", .{checksums_name});
            return error.Aborted;
        },
        error.ChecksumMissing => {
            output.err("Checksum for {s} not listed in {s}", .{ rv.archive_name, checksums_name });
            return error.Aborted;
        },
        error.ChecksumMismatch => {
            output.err("SHA256 mismatch for {s}", .{rv.archive_name});
            return error.Aborted;
        },
        error.InvalidHex => {
            output.err("Malformed checksum for {s}", .{rv.archive_name});
            return error.Aborted;
        },
        error.ReadFailed => {
            output.err("Cannot read verification files in {s}", .{rv.scratch});
            return error.Aborted;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Remove `<self_exe>.old` and any orphaned `.malt-update-*` staging
/// files next to the running binary. Idempotent - a clean tree exits 0.
fn runCleanup() !void {
    var exe_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io_mod.ctx(), &exe_buf) catch {
        output.err("Cannot determine current binary path", .{});
        return error.Aborted;
    };
    const cleaned = cleanup.cleanUpdateArtefacts(exe_buf[0..n]) catch {
        output.err("Cleanup failed", .{});
        return error.Aborted;
    };
    if (cleaned.total() == 0) {
        output.info("Nothing to clean up.", .{});
    } else {
        output.info("Removed {d} .old binary, {d} staging file(s).", .{ cleaned.old, cleaned.staging });
    }
}

/// Resolve the running binary via `executablePath` + `realpath` and
/// classify the install. Failure to resolve degrades to `.direct`, so
/// a transient FS error never locks the updater out.
fn detectOrigin() origin.Origin {
    var exe_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io_mod.ctx(), &exe_buf) catch return .direct;
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    return origin.classifyResolved(&resolved_buf, exe_buf[0..n]);
}

fn unverifiedAllowed() bool {
    const v = fs_compat.getenv("MALT_ALLOW_UNVERIFIED") orelse return false;
    return std.mem.eql(u8, v, "1");
}
