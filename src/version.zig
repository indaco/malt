//! malt — version constant
//! Injected by build.zig from the .version file.

const std = @import("std");
const options = @import("version_string");

pub const value: []const u8 = std.mem.trimRight(u8, options.version, "\r\n \t");
