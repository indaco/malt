//! malt — restore command
//! Reads a backup file produced by `malt backup` and installs every entry
//! it contains. Thin wrapper over `malt install` — the install command does
//! the heavy lifting (DB lock, download, dependency resolution).

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const backup_mod = @import("backup.zig");
const install_mod = @import("install.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub const Error = error{
    MissingFileArgument,
    FileNotFound,
    ReadFailed,
    Empty,
    InvalidArgs,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "restore")) return;

    // `--dry-run` is a global flag consumed by main.zig before we get here,
    // so we read it via `output.isDryRun()` rather than from `args`.
    const dry_run = output.isDryRun();
    var file_path: ?[]const u8 = null;
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            output.err("Unknown argument for restore: {s}", .{arg});
            return Error.InvalidArgs;
        } else if (file_path == null) {
            file_path = arg;
        } else {
            output.err("restore accepts a single file argument (got extra: {s})", .{arg});
            return Error.InvalidArgs;
        }
    }

    const path = file_path orelse {
        output.err("Usage: malt restore <file>", .{});
        return Error.MissingFileArgument;
    };

    // ── Read the file ────────────────────────────────────────────────────
    const text = readFile(allocator, path) catch |e| switch (e) {
        error.FileNotFound => {
            output.err("Backup file not found: {s}", .{path});
            return Error.FileNotFound;
        },
        else => {
            output.err("Failed to read {s}", .{path});
            return Error.ReadFailed;
        },
    };
    defer allocator.free(text);

    const entries = backup_mod.parseBackup(allocator, text) catch {
        output.err("Failed to parse backup file: {s}", .{path});
        return Error.ReadFailed;
    };
    defer allocator.free(entries);

    if (entries.len == 0) {
        output.warn("No entries found in {s}", .{path});
        return;
    }

    // ── Split into formula / cask arg lists ──────────────────────────────
    var formulae: std.ArrayList([]const u8) = .empty;
    defer formulae.deinit(allocator);
    var casks: std.ArrayList([]const u8) = .empty;
    defer casks.deinit(allocator);

    for (entries) |e| {
        // Reconstruct the install-style argument: `<name>` or `<name>@<version>`
        const arg = if (e.version.len > 0)
            try std.fmt.allocPrint(allocator, "{s}@{s}", .{ e.name, e.version })
        else
            try allocator.dupe(u8, e.name);

        switch (e.kind) {
            .formula => try formulae.append(allocator, arg),
            .cask => try casks.append(allocator, arg),
        }
    }

    output.info("Restoring {d} formula(e) and {d} cask(s) from {s}", .{
        formulae.items.len,
        casks.items.len,
        path,
    });

    if (dry_run) {
        for (formulae.items) |name| output.info("  formula {s}", .{name});
        for (casks.items) |name| output.info("  cask    {s}", .{name});
        output.info("Dry run — no packages installed.", .{});
        return;
    }

    // ── Delegate to `malt install` ───────────────────────────────────────
    // Two calls: one batched for formulae, one batched for casks. install.zig
    // already prints per-package success/failure, so we do not re-summarise.
    var any_failed = false;

    if (formulae.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, "--formula");
        if (force) try argv.append(allocator, "--force");
        for (formulae.items) |name| try argv.append(allocator, name);

        install_mod.execute(allocator, argv.items) catch |e| {
            output.err("Formula restore returned error: {s}", .{@errorName(e)});
            any_failed = true;
        };
    }

    if (casks.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, "--cask");
        if (force) try argv.append(allocator, "--force");
        for (casks.items) |name| try argv.append(allocator, name);

        install_mod.execute(allocator, argv.items) catch |e| {
            output.err("Cask restore returned error: {s}", .{@errorName(e)});
            any_failed = true;
        };
    }

    if (any_failed) {
        return error.RestoreFailed;
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try fs_compat.openFileAbsolute(path, .{})
    else
        try fs_compat.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const bytes = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(bytes);
    const n = try file.readAll(bytes);
    if (n != stat.size) return error.ReadFailed;
    return bytes;
}
