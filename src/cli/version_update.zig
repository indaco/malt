//! malt — version update command
//! Self-update the mt binary from GitHub releases.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const io_mod = @import("../ui/io.zig");
const builtin = @import("builtin");
const client_mod = @import("../net/client.zig");
const archive = @import("../fs/archive.zig");
const output = @import("../ui/output.zig");
const release = @import("../update/release.zig");

const CURRENT_VERSION = @import("../version.zig").value;
const RELEASES_API = "https://api.github.com/repos/indaco/malt/releases/latest";

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var check_only = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check_only = true;
    }

    output.info("Current version: {s}", .{CURRENT_VERSION});
    output.info("Checking for updates...", .{});

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    // Fetch latest release info from GitHub API
    var resp = http.get(RELEASES_API) catch {
        output.err("Cannot reach GitHub API", .{});
        return error.Aborted;
    };
    defer resp.deinit();

    if (resp.status != 200) {
        output.err("GitHub API returned status {d}", .{resp.status});
        return error.Aborted;
    }

    // Parse JSON to find tag_name and assets
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
    const tag_val = obj.get("tag_name") orelse {
        output.err("No tag_name in release", .{});
        return error.Aborted;
    };
    const tag = switch (tag_val) {
        .string => |s| s,
        else => {
            output.err("tag_name was not a string", .{});
            return error.Aborted;
        },
    };

    // Strip leading "v" from tag
    const latest = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;

    if (std.mem.eql(u8, latest, CURRENT_VERSION)) {
        output.info("Already up to date ({s})", .{CURRENT_VERSION});
        return;
    }

    output.info("New version available: {s} (current: {s})", .{ latest, CURRENT_VERSION });

    if (check_only) {
        output.info("Run 'mt version update' to install", .{});
        return;
    }

    // Find the right asset for this platform.
    const arch_str = if (builtin.cpu.arch == .aarch64) "arm64" else "x86_64";

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

    const url = release.pickAssetUrl(assets, arch_str) orelse {
        output.err("No matching binary found for darwin {s}", .{arch_str});
        return error.Aborted;
    };

    output.info("Downloading {s}...", .{url});

    var dl_resp = http.get(url) catch {
        output.err("Download failed", .{});
        return error.Aborted;
    };
    defer dl_resp.deinit();

    if (dl_resp.status != 200) {
        output.err("Download returned status {d}", .{dl_resp.status});
        return error.Aborted;
    }

    // Write to temp file
    const tmp_path = "/tmp/mt-update.tar.gz";
    {
        const f = fs_compat.createFileAbsolute(tmp_path, .{}) catch {
            output.err("Cannot create temp file", .{});
            return error.Aborted;
        };
        defer f.close();
        f.writeAll(dl_resp.body) catch {
            output.err("Failed to write temp file", .{});
            return error.Aborted;
        };
    }
    defer fs_compat.deleteFileAbsolute(tmp_path) catch {};

    // Extract
    const tmp_dir = "/tmp/mt-update";
    fs_compat.deleteTreeAbsolute(tmp_dir) catch {};
    fs_compat.makeDirAbsolute(tmp_dir) catch {
        output.err("Cannot create temp directory", .{});
        return error.Aborted;
    };
    defer fs_compat.deleteTreeAbsolute(tmp_dir) catch {};

    archive.extractTarGz(tmp_path, tmp_dir) catch {
        output.err("Failed to extract update", .{});
        return error.Aborted;
    };

    // Locate the replacement binary inside the extracted tree.
    //
    // GoReleaser wraps the binary in a versioned directory (e.g.
    // `malt_0.3.1_darwin_all/malt`) and emits it under the long name
    // `malt`, regardless of whether the user invoked `malt` or `mt`.
    // Walk the extracted tree and take the first file whose basename
    // matches either alias so both install layouts keep working.
    //
    // Separate stack buffers for `new_binary` and `self_exe` — the
    // previous code shared one, and `selfExePath` overwrites the
    // buffer, making the eventual copy a no-op `copy(self_exe,
    // self_exe)` that silently failed to replace the binary.
    var new_binary_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_binary = release.findReleaseBinary(allocator, tmp_dir, &new_binary_buf) orelse {
        output.err("Binary 'malt' not found in release archive", .{});
        return error.Aborted;
    };

    // Find where the current binary lives
    var self_exe_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io_mod.ctx(), &self_exe_buf) catch {
        output.err("Cannot determine current binary path", .{});
        return error.Aborted;
    };
    const self_exe = self_exe_buf[0..n];

    output.info("Replacing {s}...", .{self_exe});

    // Replace: copy new over old
    fs_compat.copyFileAbsolute(new_binary, self_exe, .{}) catch {
        output.err("Failed to replace binary. You may need sudo.", .{});
        output.info("Manual update: sudo cp {s} {s}", .{ new_binary, self_exe });
        return;
    };

    // Make executable
    {
        const f = fs_compat.openFileAbsolute(self_exe, .{ .mode = .read_write }) catch return;
        defer f.close();
        f.chmod(0o755) catch {};
    }

    output.info("Updated to {s}", .{latest});
}
