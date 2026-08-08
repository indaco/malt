//! malt — DSL builtin: process operations
//! system() builtin using std.process.spawn

const std = @import("std");
const values = @import("../values.zig");
const pathname = @import("pathname.zig");
const sandbox = @import("../sandbox.zig");
const fallback_log = @import("../fallback_log.zig");
const macos_sandbox = @import("../../sandbox/macos.zig");

const Value = values.Value;
const BuiltinError = pathname.BuiltinError;
const ExecCtx = pathname.ExecCtx;

/// Post_install output is attacker-influenced: a formula's `system` call can
/// emit whatever the child writes, and a terminal will act on it. The
/// `--use-system-ruby` path already pumps the child through
/// `ui/term_sanitize.zig`, which drops OSC (including OSC 52 clipboard
/// writes), DCS, absolute cursor positioning, and scrollback erase. The
/// native interpreter — the default path, and the one the README leads with —
/// inherited the terminal directly, so none of that applied to it.
///
/// Piping means the child no longer sees a TTY, so colour-on-TTY heuristics
/// turn themselves off. That is the same trade the ruby path already makes,
/// and `MALT_ALLOW_RAW_POST_INSTALL=1` opts out of both.
fn childStdioMode(suppress: bool, raw: bool) std.process.SpawnOptions.StdIo {
    if (suppress) return .ignore;
    return if (raw) .inherit else .pipe;
}

/// Pump `child`'s piped stdout/stderr through the sanitizer, then reap it.
/// Threads (rather than draining inline) so a chatty child cannot deadlock by
/// filling one pipe while we block on the other. `wait` owns the pipe fds, so
/// the pumps use the non-closing `filterInto`.
fn waitSanitized(ctx: ExecCtx, child: *std.process.Child) !std.process.Child.Term {
    var out_thread: ?std.Thread = null;
    var err_thread: ?std.Thread = null;
    if (child.stdout) |f| {
        out_thread = std.Thread.spawn(.{}, macos_sandbox.filterInto, .{ f.handle, std.c.STDOUT_FILENO }) catch null;
    }
    if (child.stderr) |f| {
        err_thread = std.Thread.spawn(.{}, macos_sandbox.filterInto, .{ f.handle, std.c.STDERR_FILENO }) catch null;
    }
    // The pumps see EOF when the child's write ends close, i.e. when it exits,
    // so joining before `wait` cannot hang on a live child.
    if (out_thread) |t| t.join();
    if (err_thread) |t| t.join();
    return child.wait(ctx.io);
}

/// Coerce every argument to a string and collect them into an owned argv.
/// A coercion/allocation failure aborts the whole call rather than silently
/// dropping an element and shifting the command line — the DSL runs untrusted
/// formula code, so a mutated argv is a worse failure than a loud abort.
fn buildArgv(ctx: ExecCtx, args: []const Value) BuiltinError![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(ctx.allocator);
    for (args) |arg| {
        const s = try arg.asString(ctx.allocator);
        try argv.append(ctx.allocator, s);
    }
    return argv.toOwnedSlice(ctx.allocator);
}

/// system — execute a command
pub fn system(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len == 0) return Value{ .nil = {} };

    const argv_slice = try buildArgv(ctx, args);
    if (argv_slice.len == 0) return Value{ .nil = {} };

    // Same sandbox seam as pathname/inreplace/fileutils — gate the spawn
    // so a fake sandbox can isolate all four DSL builtins, not three.
    sandbox.validateArgv(argv_slice, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    // The lint above waves bare/system-dir argv0 through; the real write
    // containment is the sandbox-exec fence wrapping the spawn (parity with
    // the --use-system-ruby path).
    const spawn_argv = sandbox.fenceArgv(ctx.allocator, argv_slice, ctx.cellar_path, ctx.malt_prefix, .{}) catch |e| switch (e) {
        error.OutOfMemory => return BuiltinError.OutOfMemory,
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
    };

    const raw = macos_sandbox.rawPassthroughEnabled(ctx.environ);
    var child = std.process.spawn(ctx.io, .{
        .argv = spawn_argv,
        .stdout = childStdioMode(ctx.suppress_child_stdout, raw),
        .stderr = childStdioMode(false, raw),
    }) catch return BuiltinError.SystemCommandFailed;
    const term = waitSanitized(ctx, &child) catch return BuiltinError.SystemCommandFailed;

    switch (term) {
        .exited => |code| if (code == 0) return Value{ .bool = true } else recordFailure(ctx, argv_slice[0], code),
        else => recordFailure(ctx, argv_slice[0], null),
    }
    return Value{ .bool = false };
}

/// Homebrew's formula-context `system` raises on failure, so a child that
/// runs and exits non-zero is a fatal failure — record it or the router
/// reports the hook as completed over a failed post_install.
fn recordFailure(ctx: ExecCtx, argv0: []const u8, exit_code: ?u32) void {
    const flog = ctx.fallback_log orelse return;
    const detail = if (exit_code) |code|
        std.fmt.allocPrint(ctx.allocator, "{s} exited with code {d}", .{ argv0, code }) catch argv0
    else
        std.fmt.allocPrint(ctx.allocator, "{s} terminated abnormally", .{argv0}) catch argv0;
    flog.log(.{
        .formula = ctx.formula_name,
        .reason = .system_command_failed,
        .detail = detail,
        .loc = null,
    });
}

/// quiet_system — execute a command, suppress output
pub fn quietSystem(ctx: ExecCtx, recv: ?Value, args: []const Value) BuiltinError!Value {
    // Ruby's `quiet_system` returns true/false and never raises — formulas
    // use it for may-fail probes, so strip the failure entry `system`
    // would record. We drop the bool too because the DSL sites that use
    // it ignore the result.
    var quiet_ctx = ctx;
    quiet_ctx.fallback_log = null;
    _ = system(quiet_ctx, recv, args) catch {};
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

    const argv_slice = try buildArgv(ctx, args);
    if (argv_slice.len == 0) return Value{ .string = "" };

    // Same two gates as `system`: this is the identical DSL surface, so
    // capturing stdout must not be a way to spawn unconfined.
    sandbox.validateArgv(argv_slice, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    const spawn_argv = sandbox.fenceArgv(ctx.allocator, argv_slice, ctx.cellar_path, ctx.malt_prefix, .{}) catch |e| switch (e) {
        error.OutOfMemory => return BuiltinError.OutOfMemory,
        error.PathSandboxViolation => return BuiltinError.PathSandboxViolation,
    };

    var child = std.process.spawn(ctx.io, .{
        .argv = spawn_argv,
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

test "childStdioMode: suppression wins, then raw passthrough, else sanitized pipe" {
    // Under --json/--ndjson the caller suppresses the child's stdout so it
    // can't corrupt the document — that still takes precedence.
    try std.testing.expect(std.meta.activeTag(childStdioMode(true, false)) == .ignore);
    try std.testing.expect(std.meta.activeTag(childStdioMode(true, true)) == .ignore);
    // MALT_ALLOW_RAW_POST_INSTALL=1 hands the terminal straight to the child.
    try std.testing.expect(std.meta.activeTag(childStdioMode(false, true)) == .inherit);
    // Default: pipe, so the bytes can be run through the sanitizer first.
    try std.testing.expect(std.meta.activeTag(childStdioMode(false, false)) == .pipe);
}

// Homebrew's formula-context `system` raises on failure, so a child
// that runs and exits non-zero must surface as a recorded failure —
// otherwise the router reports a failed hook as completed.
test "system records a fatal flog entry when the child exits non-zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lio: std.Io.Threaded = .init(arena.allocator(), .{});
    defer lio.deinit();
    var flog = fallback_log.FallbackLog.init(arena.allocator());
    defer flog.deinit();
    const ctx = ExecCtx{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
        .fallback_log = &flog,
        .formula_name = "foo",
    };

    const result = try system(ctx, null, &.{.{ .string = "/usr/bin/false" }});

    try std.testing.expect(result == .bool and !result.bool);
    try std.testing.expect(flog.hasFatal());
    const entry = flog.entries()[0];
    try std.testing.expectEqualStrings("foo", entry.formula);
    try std.testing.expect(std.mem.indexOf(u8, entry.detail, "/usr/bin/false") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.detail, "1") != null);
}

// The failure entry must be failure-only: a clean exit that logged
// anything would route every successful hook as fatal.
test "system records nothing when the child exits zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lio: std.Io.Threaded = .init(arena.allocator(), .{});
    defer lio.deinit();
    var flog = fallback_log.FallbackLog.init(arena.allocator());
    defer flog.deinit();
    const ctx = ExecCtx{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
        .fallback_log = &flog,
        .formula_name = "foo",
    };

    const result = try system(ctx, null, &.{.{ .string = "/usr/bin/true" }});

    try std.testing.expect(result == .bool and result.bool);
    try std.testing.expect(!flog.hasErrors());
}

// Test contexts omit the log (it is optional on ExecCtx); a failing
// child must still degrade to `false` instead of dereferencing null.
test "system tolerates a missing fallback log on failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lio: std.Io.Threaded = .init(arena.allocator(), .{});
    defer lio.deinit();
    const ctx = ExecCtx{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
    };

    const result = try system(ctx, null, &.{.{ .string = "/usr/bin/false" }});

    try std.testing.expect(result == .bool and !result.bool);
}

// A child that dies to a signal never reaches an exit code; that is
// still a failed hook and must surface as a recorded fatal failure.
test "system records an abnormal termination when the child dies to a signal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lio: std.Io.Threaded = .init(arena.allocator(), .{});
    defer lio.deinit();
    var flog = fallback_log.FallbackLog.init(arena.allocator());
    defer flog.deinit();
    const ctx = ExecCtx{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
        .fallback_log = &flog,
        .formula_name = "foo",
    };

    const result = try system(ctx, null, &.{
        .{ .string = "/usr/bin/perl" },
        .{ .string = "-e" },
        .{ .string = "kill 'KILL', $$" },
    });

    try std.testing.expect(result == .bool and !result.bool);
    try std.testing.expect(flog.hasFatal());
    const entry = flog.entries()[0];
    try std.testing.expect(std.mem.indexOf(u8, entry.detail, "terminated abnormally") != null);
}

// Ruby's `quiet_system` never raises — formulas use it for may-fail
// probes, so the failure entry `system` records must not leak through.
test "quiet_system suppresses the failure entry for may-fail probes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lio: std.Io.Threaded = .init(arena.allocator(), .{});
    defer lio.deinit();
    var flog = fallback_log.FallbackLog.init(arena.allocator());
    defer flog.deinit();
    const ctx = ExecCtx{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
        .fallback_log = &flog,
        .formula_name = "foo",
    };

    _ = try quietSystem(ctx, null, &.{.{ .string = "/usr/bin/false" }});

    try std.testing.expect(!flog.hasErrors());
}

// Untrusted formula input: an argv element that fails to build must abort
// the whole call, not silently vanish and shift the command line left. The
// .int tag is the only one that allocates, so a failing allocator on that
// coercion reproduces the drop the pre-fix `catch continue` loop hid.
test "system fails loud when building an argv element runs out of memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const ctx = ExecCtx{
        .allocator = failing.allocator(),
        .io = undefined,
        .environ = undefined,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
    };

    try std.testing.expectError(
        BuiltinError.OutOfMemory,
        system(ctx, null, &.{.{ .int = 42 }}),
    );
}

// Same shared builder, so the loud-abort contract must hold for the other
// caller too: an argv element that can't be built propagates OOM instead of
// the pre-fix silent "" that hid the drop.
test "safe_popen_read fails loud when building an argv element runs out of memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const ctx = ExecCtx{
        .allocator = failing.allocator(),
        .io = undefined,
        .environ = undefined,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
    };

    try std.testing.expectError(
        BuiltinError.OutOfMemory,
        safePopenRead(ctx, null, &.{.{ .int = 42 }}),
    );
}

// The extraction must preserve the full, in-order argv on the success
// path: `/bin/test hello = hello` exits 0 only if all three arguments
// reach the child unshifted — a dropped or reordered element flips it
// non-zero and this assertion fails.
test "system spawns with the full in-order argv for a multi-argument command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lio: std.Io.Threaded = .init(arena.allocator(), .{});
    defer lio.deinit();
    const ctx = ExecCtx{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
    };

    const result = try system(ctx, null, &.{
        .{ .string = "/bin/test" },
        .{ .string = "hello" },
        .{ .string = "=" },
        .{ .string = "hello" },
    });

    try std.testing.expect(result == .bool and result.bool);
}

// The empty-args early returns stay at each call site after the build
// extraction: `system` yields nil, `safe_popen_read` yields "".
test "system and safe_popen_read keep their distinct empty-args returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lio: std.Io.Threaded = .init(arena.allocator(), .{});
    defer lio.deinit();
    const ctx = ExecCtx{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
    };

    try std.testing.expect((try system(ctx, null, &.{})) == .nil);
    const popen = try safePopenRead(ctx, null, &.{});
    try std.testing.expect(popen == .string and popen.string.len == 0);
}

// `safe_popen_read` is the same DSL surface as `system` — reachable from any
// formula's post_install — so it must clear the same argv0 gate. Without it the
// builtin is an unfenced-exec hole straight through the sandbox.
test "safe_popen_read rejects an argv0 outside the sandbox roots before spawning" {
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
        safePopenRead(ctx, null, &.{.{ .string = "/Users/me/evil" }}),
    );
}

// The argv0 lint waves bare/system-dir commands through, so the sandbox-exec
// fence is what actually contains a write the *arguments* aim outside the keg.
// `system` is fenced; `safe_popen_read` must be too, or a formula can reach any
// path the user can write by picking the capturing builtin instead.
test "safe_popen_read runs under the sandbox-exec write fence" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lio: std.Io.Threaded = .init(alloc, .{});
    defer lio.deinit();

    const base = try std.fmt.allocPrint(alloc, "/tmp/malt_popen_fence_{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(lio.io(), base) catch {};
    defer std.Io.Dir.cwd().deleteTree(lio.io(), base) catch {};
    const keg = try std.fmt.allocPrint(alloc, "{s}/Cellar/foo/1.0", .{base});
    try std.Io.Dir.cwd().createDirPath(lio.io(), keg);

    const ctx = ExecCtx{
        .allocator = alloc,
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = keg,
        .malt_prefix = keg,
    };

    // `/usr/bin/touch` clears the argv0 lint (system dir), so only the fence
    // can stop the write landing outside the keg.
    const outside = try std.fmt.allocPrint(alloc, "{s}/ESCAPED", .{base});
    _ = try safePopenRead(ctx, null, &.{
        .{ .string = "/usr/bin/touch" },
        .{ .string = outside },
    });
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(lio.io(), outside, .{}),
    );
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

// The sanitizer only matters if it is actually in the path, so capture this
// process's real stdout and check what a hostile post_install would land on
// the user's terminal.
test "system strips terminal escapes a formula emits, keeping the text" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var lio: std.Io.Threaded = .init(alloc, .{});
    defer lio.deinit();

    const cap_path = try std.fmt.allocPrintSentinel(
        alloc,
        "/tmp/malt_sanitize_capture_{d}",
        .{std.c.getpid()},
        0,
    );
    defer std.Io.Dir.cwd().deleteFile(lio.io(), cap_path) catch {};

    // Swap fd 1 for a file, run the builtin, then put the real one back.
    const saved = std.c.dup(std.c.STDOUT_FILENO);
    try std.testing.expect(saved >= 0);
    const cap_fd = std.c.open(cap_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(cap_fd >= 0);
    _ = std.c.dup2(cap_fd, std.c.STDOUT_FILENO);
    _ = std.c.close(cap_fd);

    const ctx = ExecCtx{
        .allocator = alloc,
        .io = lio.io(),
        .environ = .empty,
        .cellar_path = "/opt/malt/Cellar/foo/1.0",
        .malt_prefix = "/opt/malt",
    };
    // OSC 52 is the clipboard write; the trailing text must survive.
    const payload = "\x1b]52;c;ZXZpbA==\x07VISIBLE";
    _ = system(ctx, null, &.{
        .{ .string = "/bin/echo" },
        .{ .string = payload },
    }) catch {};

    _ = std.c.dup2(saved, std.c.STDOUT_FILENO);
    _ = std.c.close(saved);

    const f = try std.Io.Dir.openFileAbsolute(lio.io(), cap_path, .{});
    defer f.close(lio.io());
    var buf: [512]u8 = undefined;
    const n = try f.readPositionalAll(lio.io(), &buf, 0);
    const got = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, got, "VISIBLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b]52") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, got, 0x1b) == null);
}
