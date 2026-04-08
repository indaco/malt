//! malt — migrate command
//! Import existing Homebrew installation.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const codesign = @import("../macho/codesign.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    var dry_run = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) dry_run = true;
    }

    // Detect Homebrew installation
    const brew_prefix = if (codesign.isArm64()) "/opt/homebrew" else "/usr/local";
    var cellar_buf: [256]u8 = undefined;
    const brew_cellar = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{brew_prefix}) catch return;

    std.fs.accessAbsolute(brew_cellar, .{}) catch {
        output.err("No Homebrew installation found at {s}", .{brew_prefix});
        return;
    };

    output.info("Found Homebrew installation at {s}", .{brew_prefix});

    // List installed kegs
    var dir = std.fs.openDirAbsolute(brew_cellar, .{ .iterate = true }) catch {
        output.err("Cannot read Homebrew Cellar", .{});
        return;
    };
    defer dir.close();

    var count: u32 = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        count += 1;
        if (dry_run) {
            const f = std.fs.File.stderr();
            f.writeAll("  Would migrate: ") catch {};
            f.writeAll(entry.name) catch {};
            f.writeAll("\n") catch {};
        }
    }

    if (dry_run) {
        output.info("Would migrate {d} packages from Homebrew", .{count});
        output.warn("Run without --dry-run to perform migration", .{});
    } else {
        // TODO: implement actual migration (download bottles, install via malt)
        output.warn("Migration not yet fully implemented. Found {d} packages.", .{count});
        output.info("Each package will be downloaded fresh from GHCR and installed via malt", .{});

        _ = atomic.maltPrefix();
    }
}
