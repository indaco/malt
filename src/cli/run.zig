//! malt — run command
//! Run a package binary without installing — download to temp, execute, clean up.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const formula_mod = @import("../core/formula.zig");
const bottle_mod = @import("../core/bottle.zig");
const cellar = @import("../core/cellar.zig");
const client_mod = @import("../net/client.zig");
const ghcr_mod = @import("../net/ghcr.zig");
const api_mod = @import("../net/api.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "run")) return;

    if (args.len == 0) {
        output.err("Usage: mt run <package> [-- <args...>]", .{});
        output.info("Example: mt run jq -- --version", .{});
        return;
    }

    const pkg_name = args[0];

    // Split args at "--" into package args and command args
    var cmd_args_start: usize = args.len;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            cmd_args_start = i + 1;
            break;
        }
    }
    const cmd_args = if (cmd_args_start < args.len) args[cmd_args_start..] else &[_][]const u8{};

    const prefix = atomic.maltPrefix();

    // Check if already installed — if so, just run it
    {
        var bin_buf: [512]u8 = undefined;
        const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/bin/{s}", .{ prefix, pkg_name }) catch return;
        std.fs.accessAbsolute(bin_path, .{}) catch {
            // Not installed — proceed with ephemeral run
            return ephemeralRun(allocator, pkg_name, cmd_args, prefix);
        };

        // Already installed — just exec it
        output.info("Running installed {s}...", .{pkg_name});
        return execBinary(bin_path, cmd_args);
    }
}

fn ephemeralRun(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    cmd_args: []const []const u8,
    prefix: []const u8,
) !void {
    output.info("Fetching {s} for ephemeral run...", .{pkg_name});

    // Set up HTTP + API
    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    var cache_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    // Fetch formula
    const formula_json = api.fetchFormula(pkg_name) catch {
        output.err("Formula '{s}' not found", .{pkg_name});
        return;
    };
    defer allocator.free(formula_json);

    var formula = formula_mod.parseFormula(allocator, formula_json) catch {
        output.err("Failed to parse formula for '{s}'", .{pkg_name});
        return;
    };
    defer formula.deinit();

    // Select bottle
    const bottle = formula_mod.resolveBottle(allocator, &formula) catch {
        output.err("No bottle available for {s} on this platform", .{pkg_name});
        return;
    };

    // Set up GHCR
    var ghcr = ghcr_mod.GhcrClient.init(allocator, &http);
    defer ghcr.deinit();

    // Create temp dir
    const tmp_dir = atomic.createTempDir(allocator, "run") catch {
        output.err("Failed to create temp directory", .{});
        return;
    };
    defer {
        atomic.cleanupTempDir(tmp_dir);
        allocator.free(tmp_dir);
    }

    // Extract repo + digest from bottle URL
    const ghcr_prefix = "https://ghcr.io/v2/";
    var repo_buf: [256]u8 = undefined;
    var digest_buf: [128]u8 = undefined;
    var repo: []const u8 = undefined;
    var digest: []const u8 = undefined;

    if (std.mem.startsWith(u8, bottle.url, ghcr_prefix)) {
        const path = bottle.url[ghcr_prefix.len..];
        if (std.mem.indexOf(u8, path, "/blobs/")) |blobs_pos| {
            repo = std.fmt.bufPrint(&repo_buf, "{s}", .{path[0..blobs_pos]}) catch return;
            digest = std.fmt.bufPrint(&digest_buf, "{s}", .{path[blobs_pos + "/blobs/".len ..]}) catch return;
        } else return;
    } else return;

    // Download
    output.info("Downloading {s} {s}...", .{ pkg_name, formula.version });
    _ = bottle_mod.download(allocator, &ghcr, repo, digest, bottle.sha256, tmp_dir, null) catch {
        output.err("Failed to download {s}", .{pkg_name});
        return;
    };

    // Find the binary in the extracted contents
    var bin_path_buf: [512]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_path_buf, "{s}/{s}/{s}/bin/{s}", .{
        tmp_dir,
        pkg_name,
        formula.version,
        pkg_name,
    }) catch return;

    std.fs.accessAbsolute(bin_path, .{}) catch {
        output.err("Binary '{s}' not found in bottle", .{pkg_name});
        return;
    };

    // Make executable
    {
        const f = std.fs.openFileAbsolute(bin_path, .{ .mode = .read_write }) catch return;
        defer f.close();
        f.chmod(0o755) catch {};
    }

    output.info("Running {s} {s} (ephemeral)...", .{ pkg_name, formula.version });
    const stderr = std.fs.File.stderr();
    stderr.writeAll("---\n") catch {};

    execBinary(bin_path, cmd_args);
}

fn execBinary(path: []const u8, cmd_args: []const []const u8) void {
    // Build argv: [path] ++ cmd_args
    var argv_buf: [64][]const u8 = undefined;
    argv_buf[0] = path;
    const argc = @min(cmd_args.len, argv_buf.len - 1);
    for (cmd_args[0..argc], 1..) |arg, i| {
        argv_buf[i] = arg;
    }

    var child = std.process.Child.init(argv_buf[0 .. argc + 1], std.heap.c_allocator);
    child.spawn() catch {
        output.err("Failed to execute binary", .{});
        return;
    };
    _ = child.wait() catch {};
}
