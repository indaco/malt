//! malt — DSL builtin: process operations
//! system() builtin using std.process.spawn

const std = @import("std");
const values = @import("../values.zig");
const pathname = @import("pathname.zig");
const sandbox = @import("../sandbox.zig");

const Value = values.Value;
const BuiltinError = pathname.BuiltinError;
const ExecCtx = pathname.ExecCtx;

/// Subprocess stdout shares the FD with malt's `--json` / `--ndjson`
/// document, so verbose tools like fc-cache would corrupt it. The caller
/// decides via `ExecCtx.suppress_child_stdout`; stderr stays inherited so
/// warnings still surface for the user.
fn childStdoutMode(suppress: bool) std.process.SpawnOptions.StdIo {
    return if (suppress) .ignore else .inherit;
}

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

    // Same sandbox seam as pathname/inreplace/fileutils — gate the spawn
    // so a fake sandbox can isolate all four DSL builtins, not three.
    sandbox.validateArgv(argv_slice, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    const child_stdout = childStdoutMode(ctx.suppress_child_stdout);
    var child = std.process.spawn(ctx.io, .{
        .argv = argv_slice,
        .stdout = child_stdout,
    }) catch return BuiltinError.SystemCommandFailed;
    const term = child.wait(ctx.io) catch return BuiltinError.SystemCommandFailed;

    return switch (term) {
        .exited => |code| if (code == 0) Value{ .bool = true } else Value{ .bool = false },
        else => Value{ .bool = false },
    };
}

/// quiet_system — execute a command, suppress output
pub fn quietSystem(ctx: ExecCtx, recv: ?Value, args: []const Value) BuiltinError!Value {
    // Ruby's `quiet_system` returns true/false and never raises; we drop the
    // bool too because the DSL sites that use it ignore the result.
    _ = system(ctx, recv, args) catch {};
    return Value{ .nil = {} };
}

/// File.exist? — check if a file exists (bare form)
pub fn fileExist(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .bool = false };
    const path = args[0].asString(ctx.allocator) catch return Value{ .bool = false };
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch {
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
    const path_env = std.process.Environ.getPosix(ctx.environ, "PATH") orelse "/usr/bin:/bin:/usr/sbin:/sbin";
    var path_iter = std.mem.tokenizeScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        const full = std.fmt.bufPrint(&probe, "{s}/{s}", .{ dir, cmd_name }) catch continue;
        std.Io.Dir.cwd().access(ctx.io, full, .{}) catch continue;
        const owned = ctx.allocator.dupe(u8, full) catch return BuiltinError.OutOfMemory;
        return Value{ .pathname = owned };
    }

    // Fallback: try common locations.
    const fallbacks = [_][]const u8{ "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/" };
    for (fallbacks) |prefix| {
        const full = std.fmt.bufPrint(&probe, "{s}{s}", .{ prefix, cmd_name }) catch continue;
        std.Io.Dir.cwd().access(ctx.io, full, .{}) catch continue;
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
    var child = std.process.spawn(ctx.io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return Value{ .string = "15.0" };
    const stdout = child.stdout orelse return Value{ .string = "15.0" };
    const ver = readPipeAll(stdout, ctx.allocator, 256) catch return Value{ .string = "15.0" };
    // Already captured stdout; wait is just for reaping the zombie.
    _ = child.wait(ctx.io) catch {};
    const trimmed = std.mem.trimEnd(u8, ver, "\n\r ");
    return Value{ .string = trimmed };
}

/// MacOS::CLT.PKG_PATH — Homebrew's canonical Command Line Tools prefix.
/// Hard-coded because Apple's installer places CLT here on every macOS
/// version our DSL could plausibly run on; resolving it lets formulas
/// like `"#{MacOS::CLT::PKG_PATH}/SDKs/MacOSX.sdk"` interpolate into
/// real paths instead of silent empty strings.
pub fn cltPkgPath(_: ExecCtx, _: ?Value, _: []const Value) BuiltinError!Value {
    return Value{ .string = "/Library/Developer/CommandLineTools" };
}

/// `Set.new(arr)` — stubbed as a thin array pass-through. Real Ruby Set
/// is ordered-unique; for the formulas we care about (llvm@21's
/// `arches = Set.new([:arm64, :x86_64, :aarch64]); arches << arch`)
/// the only operations are `<<` append and `.each` iteration, both of
/// which already work on arrays. Calling with no args returns an
/// empty array so the subsequent shovel keeps going.
pub fn setNew(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .array = &.{} };
    if (args[0] == .array) return args[0];
    const singleton = ctx.allocator.alloc(Value, 1) catch return BuiltinError.OutOfMemory;
    singleton[0] = args[0];
    return Value{ .array = singleton };
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
    if (std.process.Environ.getPosix(ctx.environ, key)) |val| {
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

    var child = std.process.spawn(ctx.io, .{
        .argv = argv_slice,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return Value{ .string = "" };

    const stdout = child.stdout orelse return Value{ .string = "" };
    const content = readPipeAll(stdout, ctx.allocator, 1024 * 1024) catch return Value{ .string = "" };
    // Already captured stdout; wait is just for reaping the zombie.
    _ = child.wait(ctx.io) catch {};

    // Chomp trailing newline
    const trimmed = std.mem.trimEnd(u8, content, "\n\r");
    return Value{ .string = trimmed };
}

/// Stream a child stdout pipe into a caller-owned slice. Always builds
/// a private `Threaded` for blocking pipe reads — the caller's runtime
/// `io` may be `debug_io` (failing allocator) which cannot wait on a
/// blocking child pipe.
fn readPipeAll(file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var buf: [4096]u8 = undefined;
    var r = file.readerStreaming(threaded.io(), &buf);
    return r.interface.allocRemaining(allocator, std.Io.Limit.limited(max_bytes));
}

test "childStdoutMode ignores subprocess stdout only when suppression is requested" {
    // Under --json/--ndjson the caller suppresses the child's stdout so it
    // can't corrupt the document; otherwise it inherits malt's fd.
    try std.testing.expect(std.meta.activeTag(childStdoutMode(true)) == .ignore);
    try std.testing.expect(std.meta.activeTag(childStdoutMode(false)) == .inherit);
}

test "system rejects an argv0 outside the sandbox roots before spawning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lio: std.Io.Threaded = .init(arena.allocator(), .{});
    defer lio.deinit();
    const ctx = ExecCtx{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = undefined,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
    };
    try std.testing.expectError(
        BuiltinError.PathSandboxViolation,
        system(ctx, null, &.{.{ .string = "/Users/me/evil" }}),
    );
}
