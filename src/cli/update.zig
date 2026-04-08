//! malt — update command
//! Refresh metadata cache.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        }
    }

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return;
    };
    defer allocator.free(cache_dir);

    // Delete all files in {cache_dir}/api/
    var api_path_buf: [512]u8 = undefined;
    const api_path = std.fmt.bufPrint(&api_path_buf, "{s}/api", .{cache_dir}) catch return;

    std.fs.deleteTreeAbsolute(api_path) catch {
        // Directory may not exist yet — that's fine
    };

    output.info("Cache cleared. Metadata will be re-fetched on next operation.", .{});
}
