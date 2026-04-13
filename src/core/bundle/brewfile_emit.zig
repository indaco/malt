//! malt — Brewfile emitter (Manifest → Brewfile text)

const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub fn emit(manifest: manifest_mod.Manifest, writer: anytype) !void {
    for (manifest.taps) |t| {
        try writer.print("tap \"{s}\"\n", .{t});
    }
    for (manifest.formulas) |f| {
        try writer.print("brew \"{s}\"", .{f.name});
        if (f.version) |v| try writer.print(", version: \"{s}\"", .{v});
        if (f.restart_service) try writer.writeAll(", restart_service: true");
        try writer.writeAll("\n");
    }
    for (manifest.casks) |c| {
        try writer.print("cask \"{s}\"\n", .{c.name});
    }
}
