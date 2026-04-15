//! malt — DSL builtin: Pathname operations
//! Maps Ruby Pathname methods to std.fs calls.

const std = @import("std");
const values = @import("../values.zig");
const sandbox = @import("../sandbox.zig");
const ast = @import("../ast.zig");

const Value = values.Value;

pub const BuiltinError = error{
    PathSandboxViolation,
    PostInstallFailed,
    SystemCommandFailed,
    OutOfMemory,
    UnknownMethod,
    UnsupportedNode,
    ParseError,
};

pub const ExecCtx = struct {
    allocator: std.mem.Allocator,
    cellar_path: []const u8,
    malt_prefix: []const u8,
};

/// mkpath — recursive directory creation
pub fn mkpath(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };
    std.fs.cwd().makePath(path) catch {};
    return Value{ .nil = {} };
}

/// exist? — check if path exists
pub fn existQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    std.fs.cwd().access(path, .{}) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = true };
}

/// directory? — check if path is a directory
pub fn directoryQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    var dir = std.fs.openDirAbsolute(path, .{}) catch {
        return Value{ .bool = false };
    };
    dir.close();
    return Value{ .bool = true };
}

/// symlink? — check if path is a symlink
pub fn symlinkQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.fs.cwd().readLink(path, &buf) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = true };
}

/// write — write content to file (sandbox-validated)
pub fn write(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };
    sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    const content = if (args.len > 0) try args[0].asString(ctx.allocator) else "";

    const file = std.fs.createFileAbsolute(path, .{}) catch {
        return Value{ .nil = {} };
    };
    defer file.close();
    file.writeAll(content) catch {};
    return Value{ .nil = {} };
}

/// read — read file content
pub fn read(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .string = "" };
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        return Value{ .string = "" };
    };
    defer file.close();
    const content = file.readToEndAlloc(ctx.allocator, 1024 * 1024) catch {
        return Value{ .string = "" };
    };
    return Value{ .string = content };
}

/// children — list directory entries
pub fn children(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .array = &.{} };
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch {
        return Value{ .array = &.{} };
    };
    defer dir.close();

    var entries: std.ArrayList(Value) = .empty;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const child_path = std.fs.path.join(ctx.allocator, &.{ path, entry.name }) catch continue;
        entries.append(ctx.allocator, Value{ .pathname = child_path }) catch continue;
    }
    const slice = entries.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;
    return Value{ .array = slice };
}

/// basename — filename component
pub fn basename(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = std.fs.path.basename(path) };
}

/// dirname — parent directory
pub fn dirname(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .pathname = std.fs.path.dirname(path) orelse "/" };
}

/// extname — file extension
pub fn extname(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = std.fs.path.extension(path) };
}

/// to_s — convert pathname to string
pub fn toS(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = path };
}

/// realpath — resolve symlinks
pub fn realpath(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.fs.cwd().realpath(path, &buf) catch {
        return Value{ .pathname = path };
    };
    const duped = ctx.allocator.dupe(u8, resolved) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = duped };
}

/// file? — check if path is a regular file
pub fn fileQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    const stat = std.fs.cwd().statFile(path) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = stat.kind == .file };
}

/// atomic_write — write content atomically (sandbox-validated)
pub fn atomicWrite(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    return write(ctx, receiver, args);
}

/// opt_bin — receiver/"bin" (Formula accessor)
pub fn optBin(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "bin" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// opt_lib — receiver/"lib" (Formula accessor)
pub fn optLib(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "lib" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// opt_include — receiver/"include" (Formula accessor)
pub fn optInclude(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "include" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// pkgetc — receiver/"etc" (Formula accessor for pkgetc)
pub fn pkgetc(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "etc" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// unlink — delete a file (alias for File.delete)
pub fn unlink(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };
    sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    std.fs.cwd().deleteFile(path) catch {};
    return Value{ .nil = {} };
}

/// install_symlink — create a symlink (sandbox-validated)
pub fn installSymlink(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const source = try receiverPath(ctx.allocator, receiver);
    const target = if (args.len > 0) try args[0].asString(ctx.allocator) else return Value{ .nil = {} };

    // Guard against empty/invalid paths
    if (source.len == 0 or target.len == 0) return Value{ .nil = {} };

    sandbox.validatePath(target, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    // Ensure parent exists
    if (std.fs.path.dirname(target)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    std.fs.cwd().deleteFile(target) catch {};
    std.fs.symLinkAbsolute(source, target, .{}) catch {};
    return Value{ .nil = {} };
}

/// glob(pattern) — match files in a directory against a glob pattern
/// Receiver is the directory path; first arg is the pattern string.
/// If called bare (no receiver), the first arg is the full glob pattern.
pub fn glob(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    var base_dir: []const u8 = "";
    var pattern: []const u8 = "*";

    if (receiver) |recv| {
        // Receiver form: dir.glob("*.dylib")
        base_dir = switch (recv) {
            .pathname => |p| p,
            .string => |s| s,
            else => recv.asString(ctx.allocator) catch return BuiltinError.OutOfMemory,
        };
        if (args.len == 0) return Value{ .array = &.{} };
        pattern = args[0].asString(ctx.allocator) catch return Value{ .array = &.{} };
    } else {
        // Bare form: Dir.glob("lib/*.dylib") — first arg is full pattern
        if (args.len == 0) return Value{ .array = &.{} };
        const full = args[0].asString(ctx.allocator) catch return Value{ .array = &.{} };
        if (full.len == 0) return Value{ .array = &.{} };
        base_dir = std.fs.path.dirname(full) orelse ".";
        pattern = std.fs.path.basename(full);
    }

    // Guard against empty/relative base_dir
    if (base_dir.len == 0) return Value{ .array = &.{} };

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch {
        return Value{ .array = &.{} };
    };
    defer dir.close();

    var results: std.ArrayList(Value) = .empty;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (globMatch(pattern, entry.name)) {
            const child_path = std.fs.path.join(ctx.allocator, &.{ base_dir, entry.name }) catch continue;
            results.append(ctx.allocator, Value{ .pathname = child_path }) catch continue;
        }
    }

    const slice = results.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;
    return Value{ .array = slice };
}

/// Glob pattern matching with `*`, `?`, and `{a,b,c}` brace expansion.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Check if pattern contains braces — if so, expand and try each alternative
    if (std.mem.findScalar(u8, pattern, '{')) |brace_start| {
        if (findMatchingBrace(pattern, brace_start)) |brace_end| {
            const prefix = pattern[0..brace_start];
            const suffix = pattern[brace_end + 1 ..];
            const alternatives = pattern[brace_start + 1 .. brace_end];

            // Split alternatives by comma and try each
            var iter = std.mem.splitScalar(u8, alternatives, ',');
            while (iter.next()) |alt| {
                // Build expanded pattern: prefix + alt + suffix
                var buf: [1024]u8 = undefined;
                const expanded_len = prefix.len + alt.len + suffix.len;
                if (expanded_len > buf.len) continue;
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len .. prefix.len + alt.len], alt);
                @memcpy(buf[prefix.len + alt.len .. expanded_len], suffix);
                if (globMatch(buf[0..expanded_len], name)) return true;
            }
            return false;
        }
    }

    // Standard glob matching without braces
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == name[ni] or pattern[pi] == '?')) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }

    // Consume trailing *'s in pattern
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}

/// Find matching closing brace, accounting for nesting.
fn findMatchingBrace(pattern: []const u8, start: usize) ?usize {
    var depth: u32 = 0;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '{') {
            depth += 1;
        } else if (pattern[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn receiverPath(allocator: std.mem.Allocator, receiver: ?Value) BuiltinError![]const u8 {
    const recv = receiver orelse return BuiltinError.UnknownMethod;
    return switch (recv) {
        .pathname => |p| p,
        .string => |s| s,
        else => recv.asString(allocator) catch return BuiltinError.OutOfMemory,
    };
}
