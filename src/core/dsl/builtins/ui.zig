//! malt — DSL builtin: UI operations
//! Maps ohai/opoo/odie to src/ui/output.zig

const std = @import("std");
const output = @import("../../../ui/output.zig");
const values = @import("../values.zig");
const pathname = @import("pathname.zig");

const Value = values.Value;
const BuiltinError = pathname.BuiltinError;
const ExecCtx = pathname.ExecCtx;

/// ohai — info message
pub fn ohai(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const msg = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };
    var buf: [4096]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{s}", .{msg}) catch return Value{ .nil = {} };
    const f = std.fs.File.stderr();
    f.writeAll("  > ") catch {};
    f.writeAll(formatted) catch {};
    f.writeAll("\n") catch {};
    return Value{ .nil = {} };
}

/// opoo — warning message
pub fn opoo(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const msg = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };
    var buf: [4096]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{s}", .{msg}) catch return Value{ .nil = {} };
    const f = std.fs.File.stderr();
    f.writeAll("  ! ") catch {};
    f.writeAll(formatted) catch {};
    f.writeAll("\n") catch {};
    return Value{ .nil = {} };
}

/// odie — error message + fail
pub fn odie(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return BuiltinError.PostInstallFailed;
    const msg = args[0].asString(ctx.allocator) catch return BuiltinError.PostInstallFailed;
    var buf: [4096]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{s}", .{msg}) catch return BuiltinError.PostInstallFailed;
    const f = std.fs.File.stderr();
    f.writeAll("  x ") catch {};
    f.writeAll(formatted) catch {};
    f.writeAll("\n") catch {};
    return BuiltinError.PostInstallFailed;
}
