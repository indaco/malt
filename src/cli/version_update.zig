//! malt — version update command
//! Self-update the mt binary from GitHub releases.

const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("../net/client.zig");
const output = @import("../ui/output.zig");

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
        return;
    };
    defer resp.deinit();

    if (resp.status != 200) {
        output.err("GitHub API returned status {d}", .{resp.status});
        return;
    }

    // Parse JSON to find tag_name and assets
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch {
        output.err("Failed to parse release info", .{});
        return;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const tag_val = obj.get("tag_name") orelse {
        output.err("No tag_name in release", .{});
        return;
    };
    const tag = switch (tag_val) {
        .string => |s| s,
        else => {
            output.err("Invalid tag_name", .{});
            return;
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

    // Find the right asset for this platform
    const arch_str = if (builtin.cpu.arch == .aarch64) "arm64" else "x86_64";
    const os_str = "Darwin";

    const assets_val = obj.get("assets") orelse {
        output.err("No assets in release", .{});
        return;
    };
    const assets = switch (assets_val) {
        .array => |a| a,
        else => {
            output.err("Invalid assets", .{});
            return;
        },
    };

    var download_url: ?[]const u8 = null;
    for (assets.items) |asset| {
        switch (asset) {
            .object => |asset_obj| {
                const name_val = asset_obj.get("name") orelse continue;
                const asset_name = switch (name_val) {
                    .string => |s| s,
                    else => continue,
                };

                // Look for a matching binary (e.g., malt_0.2.0_Darwin_arm64.tar.gz)
                if (std.mem.indexOf(u8, asset_name, os_str) != null and
                    std.mem.indexOf(u8, asset_name, arch_str) != null and
                    std.mem.endsWith(u8, asset_name, ".tar.gz"))
                {
                    const url_val = asset_obj.get("browser_download_url") orelse continue;
                    download_url = switch (url_val) {
                        .string => |s| s,
                        else => continue,
                    };
                    break;
                }
            },
            else => continue,
        }
    }

    const url = download_url orelse {
        output.err("No matching binary found for {s} {s}", .{ os_str, arch_str });
        return;
    };

    output.info("Downloading {s}...", .{url});

    var dl_resp = http.get(url) catch {
        output.err("Download failed", .{});
        return;
    };
    defer dl_resp.deinit();

    if (dl_resp.status != 200) {
        output.err("Download returned status {d}", .{dl_resp.status});
        return;
    }

    // Write to temp file
    const tmp_path = "/tmp/mt-update.tar.gz";
    {
        const f = std.fs.createFileAbsolute(tmp_path, .{}) catch {
            output.err("Cannot create temp file", .{});
            return;
        };
        defer f.close();
        f.writeAll(dl_resp.body) catch {
            output.err("Failed to write temp file", .{});
            return;
        };
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Extract
    const tmp_dir = "/tmp/mt-update";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    std.fs.makeDirAbsolute(tmp_dir) catch {
        output.err("Cannot create temp directory", .{});
        return;
    };
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const archive = @import("../fs/archive.zig");
    archive.extractTarXzFile(tmp_path, tmp_dir) catch {
        // Try tar.gz extraction via system tar as fallback
        const argv = [_][]const u8{ "tar", "xf", tmp_path, "-C", tmp_dir };
        var child = std.process.Child.init(&argv, std.heap.page_allocator);
        child.spawn() catch {
            output.err("Failed to extract update", .{});
            return;
        };
        _ = child.wait() catch {};
    };

    // Find the mt binary in the extracted contents
    var mt_buf: [256]u8 = undefined;
    const new_binary = std.fmt.bufPrint(&mt_buf, "{s}/mt", .{tmp_dir}) catch return;

    std.fs.accessAbsolute(new_binary, .{}) catch {
        output.err("Binary 'mt' not found in release archive", .{});
        return;
    };

    // Find where the current binary lives
    const self_exe = std.fs.selfExePath(&mt_buf) catch {
        output.err("Cannot determine current binary path", .{});
        return;
    };

    output.info("Replacing {s}...", .{self_exe});

    // Replace: copy new over old
    std.fs.copyFileAbsolute(new_binary, self_exe, .{}) catch {
        output.err("Failed to replace binary. You may need sudo.", .{});
        output.info("Manual update: sudo cp {s} {s}", .{ new_binary, self_exe });
        return;
    };

    // Make executable
    {
        const f = std.fs.openFileAbsolute(self_exe, .{ .mode = .read_write }) catch return;
        defer f.close();
        f.chmod(0o755) catch {};
    }

    output.info("Updated to {s}", .{latest});
}
