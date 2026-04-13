//! malt — DSL builtin: process operations
//! system() builtin using std.process.Child

const std = @import("std");
const values = @import("../values.zig");
const pathname = @import("pathname.zig");

const Value = values.Value;
const BuiltinError = pathname.BuiltinError;
const ExecCtx = pathname.ExecCtx;

/// system — execute a command
pub fn system(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };

    // Build argv from args
    var argv: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        const s = arg.asString(ctx.allocator) catch continue;
        argv.append(ctx.allocator, s) catch continue;
    }
    const argv_slice = argv.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;

    if (argv_slice.len == 0) return Value{ .nil = {} };

    var child = std.process.Child.init(argv_slice, ctx.allocator);
    child.spawn() catch return BuiltinError.SystemCommandFailed;
    const term = child.wait() catch return BuiltinError.SystemCommandFailed;

    return switch (term) {
        .Exited => |code| if (code == 0) Value{ .bool = true } else Value{ .bool = false },
        else => Value{ .bool = false },
    };
}

/// quiet_system — execute a command, suppress output
pub fn quietSystem(ctx: ExecCtx, recv: ?Value, args: []const Value) BuiltinError!Value {
    // Same as system but we ignore the exit code (quiet)
    _ = system(ctx, recv, args) catch {};
    return Value{ .nil = {} };
}

/// File.exist? — check if a file exists (bare form)
pub fn fileExist(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .bool = false };
    const path = args[0].asString(ctx.allocator) catch return Value{ .bool = false };
    std.fs.cwd().access(path, .{}) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = true };
}

/// DevelopmentTools.locate — find a command in PATH
pub fn devToolsLocate(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const cmd_name = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };

    // Reusable scratch buffer — every probe writes through this one stack
    // slot instead of allocating a fresh slice per iteration. The PATH
    // split itself uses tokenizeScalar (zero-alloc) so no caching needed.
    var probe: [std.fs.max_path_bytes]u8 = undefined;

    // Search PATH for the command.
    const path_env = std.posix.getenv("PATH") orelse "/usr/bin:/bin:/usr/sbin:/sbin";
    var path_iter = std.mem.tokenizeScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        const full = std.fmt.bufPrint(&probe, "{s}/{s}", .{ dir, cmd_name }) catch continue;
        std.fs.cwd().access(full, .{}) catch continue;
        const owned = ctx.allocator.dupe(u8, full) catch return BuiltinError.OutOfMemory;
        return Value{ .pathname = owned };
    }

    // Fallback: try common locations.
    const fallbacks = [_][]const u8{ "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/" };
    for (fallbacks) |prefix| {
        const full = std.fmt.bufPrint(&probe, "{s}{s}", .{ prefix, cmd_name }) catch continue;
        std.fs.cwd().access(full, .{}) catch continue;
        const owned = ctx.allocator.dupe(u8, full) catch return BuiltinError.OutOfMemory;
        return Value{ .pathname = owned };
    }

    return Value{ .pathname = cmd_name };
}

/// Formula["name"] lookup — return a Pathname to the formula's opt_prefix.
/// Chained accessors like .opt_bin, .opt_lib are resolved as path joins
/// by the receiver builtin dispatch.
pub fn formulaLookup(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const name = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };

    // Formula["name"] resolves to MALT_PREFIX/opt/name
    const opt_path = std.fs.path.join(ctx.allocator, &.{ ctx.malt_prefix, "opt", name }) catch
        return BuiltinError.OutOfMemory;
    return Value{ .pathname = opt_path };
}

/// OS.mac? — always true on macOS
pub fn osMac(_: ExecCtx, _: ?Value, _: []const Value) BuiltinError!Value {
    return Value{ .bool = true };
}

/// OS.linux? — always false on macOS
pub fn osLinux(_: ExecCtx, _: ?Value, _: []const Value) BuiltinError!Value {
    return Value{ .bool = false };
}

/// MacOS.version — return version as string (used for comparisons)
pub fn macosVersion(ctx: ExecCtx, _: ?Value, _: []const Value) BuiltinError!Value {
    // Get macOS version from sw_vers
    const argv = [_][]const u8{ "sw_vers", "-productVersion" };
    var child = std.process.Child.init(&argv, ctx.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return Value{ .string = "15.0" };
    const stdout = child.stdout orelse return Value{ .string = "15.0" };
    const ver = stdout.readToEndAlloc(ctx.allocator, 256) catch return Value{ .string = "15.0" };
    _ = child.wait() catch {};
    const trimmed = std.mem.trimRight(u8, ver, "\n\r ");
    return Value{ .string = trimmed };
}

/// Hardware::CPU.arch — return "arm64" or "x86_64"
pub fn cpuArch(_: ExecCtx, _: ?Value, _: []const Value) BuiltinError!Value {
    const is_arm = @import("builtin").cpu.arch == .aarch64;
    return Value{ .string = if (is_arm) "arm64" else "x86_64" };
}

/// Pathname.new("path") — create a Pathname value from string
pub fn pathnameNew(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .pathname = "" };
    const path = args[0].asString(ctx.allocator) catch return Value{ .pathname = "" };
    return Value{ .pathname = path };
}

/// ENV["key"] read — get environment variable
pub fn envGet(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };
    const key = args[0].asString(ctx.allocator) catch return Value{ .nil = {} };
    // Need null-terminated key for getenv
    const key_z = ctx.allocator.dupeZ(u8, key) catch return BuiltinError.OutOfMemory;
    if (std.posix.getenv(key_z)) |val| {
        return Value{ .string = val };
    }
    return Value{ .nil = {} };
}

/// ENV["key"] = value write — set environment variable (no-op in sandbox, just store)
pub fn envSet(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 2) return Value{ .nil = {} };
    // In sandbox mode we don't actually setenv — just return the value
    // The assignment is tracked so later reads of the same var work via local scope
    const val = args[1].asString(ctx.allocator) catch return Value{ .nil = {} };
    return Value{ .string = val };
}

/// safe_popen_read — capture stdout of a command
pub fn safePopenRead(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .string = "" };

    var argv: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        const s = arg.asString(ctx.allocator) catch continue;
        argv.append(ctx.allocator, s) catch continue;
    }
    const argv_slice = argv.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;

    if (argv_slice.len == 0) return Value{ .string = "" };

    var child = std.process.Child.init(argv_slice, ctx.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return Value{ .string = "" };

    const stdout = child.stdout orelse return Value{ .string = "" };
    const content = stdout.readToEndAlloc(ctx.allocator, 1024 * 1024) catch return Value{ .string = "" };
    _ = child.wait() catch {};

    // Chomp trailing newline
    const trimmed = std.mem.trimRight(u8, content, "\n\r");
    return Value{ .string = trimmed };
}
