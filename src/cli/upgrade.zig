//! malt — upgrade command
//! Upgrade installed packages.

const std = @import("std");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "upgrade")) return;

    _ = allocator;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        }
    }

    output.warn("upgrade not yet implemented", .{});
}
