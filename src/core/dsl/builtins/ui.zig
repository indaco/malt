//! malt — DSL builtin: UI operations
//! Maps ohai/opoo/odie to src/ui/output.zig — the sole UI channel the
//! DSL is allowed. Direct stderr writes were removed per the "core
//! returns outcomes" layering (R3).

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
    output.info("{s}", .{msg});
    return Value{ .nil = {} };
}

/// opoo — warning message
pub fn opoo(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const msg = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };
    output.warn("{s}", .{msg});
    return Value{ .nil = {} };
}

/// odie — error message + fail
pub fn odie(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return BuiltinError.PostInstallFailed;
    const msg = args[0].asString(ctx.allocator) catch return BuiltinError.PostInstallFailed;
    output.err("{s}", .{msg});
    return BuiltinError.PostInstallFailed;
}
