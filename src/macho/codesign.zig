const std = @import("std");
const builtin = @import("builtin");

pub fn adHocSign(path: []const u8) !void {
    _ = path;
    return error.NotImplemented;
}

pub fn isArm64() bool {
    return builtin.cpu.arch == .aarch64;
}
