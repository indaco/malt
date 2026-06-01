//! malt — Ruby subprocess post_install executor
//! Delegates post_install script execution to the system Ruby interpreter.
//! This is an experimental stopgap until malt can natively evaluate the
//! Homebrew DSL.
//!
//! Spawn, result glue, and sandbox wiring live here; detection and source
//! extraction are split into `ruby/detect.zig` and `ruby/source.zig` so
//! DSL-only and net-only tests stop cross-linking through this driver.

const std = @import("std");
const sandbox = @import("sandbox/macos.zig");
const fs_atomic = @import("../fs/atomic.zig");
const detect = @import("ruby/detect.zig");
const source = @import("ruby/source.zig");

// Public surface preserved through the top-level file: the only consumers
// (`cli/install/post_install.zig`, `cli/doctor/post_install.zig`) and the
// existing test suite reach detection/extraction via `ruby_subprocess.X`.
pub const detectRuby = detect.detectRuby;
pub const findHomebrewCoreTap = detect.findHomebrewCoreTap;
pub const resolveFormulaRbPath = detect.resolveFormulaRbPath;
pub const extractPostInstallBody = source.extractPostInstallBody;
pub const extractPostInstallFromSource = source.extractPostInstallFromSource;
pub const fetchPostInstallFromGitHub = source.fetchPostInstallFromGitHub;

pub const RubyError = error{
    RubyNotFound,
    TapNotFound,
    FormulaSourceNotFound,
    PostInstallBodyNotFound,
    FetchFailed,
    ScriptWriteFailed,
    PostInstallFailed,
    OutOfMemory,
    InvalidInput,
};

/// Human-readable hint for each RubyError variant. CLI renders these so
/// core/* itself emits no UI.
pub fn describeError(err: RubyError) []const u8 {
    return switch (err) {
        RubyError.RubyNotFound => "no Ruby interpreter found (tried /opt/homebrew, /usr/local, rbenv, asdf, PATH)",
        RubyError.TapNotFound => "no local homebrew-core tap clone, and the hash-pinned GitHub fallback was not viable for this formula",
        RubyError.FormulaSourceNotFound => "formula .rb source not found in the homebrew-core tap, and the hash-pinned GitHub fallback could not recover it",
        RubyError.PostInstallBodyNotFound => "could not extract a post_install body from the formula source",
        RubyError.FetchFailed => "hash-pinned GitHub fallback fetch failed (network error, HTTP status, hash mismatch, or formula absent from the pinned manifest)",
        RubyError.ScriptWriteFailed => "could not write the temporary Ruby wrapper script",
        RubyError.PostInstallFailed => "post_install script failed to run or exited non-zero",
        RubyError.OutOfMemory => "out of memory running post_install",
        RubyError.InvalidInput => "invalid formula name, version, or prefix",
    };
}

/// Which arm of the local-tap path was the last one to fail. Carried
/// from `resolvePostInstallBody` into the failure classifier so the
/// returned RubyError reflects the deepest-known reason rather than a
/// blanket TapNotFound.
const LocalArmFailure = enum {
    /// `findHomebrewCoreTap` returned null — no clone on disk.
    no_tap,
    /// Tap clone exists but no `.rb` for this formula in either layout.
    no_rb,
    /// Tap + `.rb` exist but the body extractor returned null.
    body_not_extracted,
};

/// Pure decision: pick the most actionable RubyError given the local
/// arm's failure mode and the fetch arm's outcome. Operators triage by
/// the variant, so we surface the deepest-known reason — e.g. a hash
/// mismatch becomes `FetchFailed`, not `TapNotFound`.
fn classifyResolveFailure(local: LocalArmFailure, fetch_failure: source.FetchOutcome) RubyError {
    return switch (fetch_failure) {
        .body => unreachable, // success isn't a failure to classify
        .body_not_found => RubyError.PostInstallBodyNotFound,
        .fetch_failed => switch (local) {
            .no_tap => RubyError.TapNotFound,
            .no_rb => RubyError.FetchFailed,
            .body_not_extracted => RubyError.PostInstallBodyNotFound,
        },
    };
}

/// Resolve a formula's post_install body. Tries the on-disk
/// homebrew-core tap first; on miss, falls back to the hash-pinned
/// GitHub fetch so API-only Homebrew installs (no tap clone) still
/// reach a usable body. Caller owns the returned slice on success.
///
/// Failure surfaces a distinguishing RubyError — TapNotFound,
/// FetchFailed, or PostInstallBodyNotFound — so operators triaging an
/// install crash see the actual cause rather than a single catch-all.
pub fn resolvePostInstallBody(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    name: []const u8,
) RubyError![]const u8 {
    var local: LocalArmFailure = .no_tap;
    if (findHomebrewCoreTap(io)) |tap_path| {
        var rb_buf: [1024]u8 = undefined;
        if (resolveFormulaRbPath(io, &rb_buf, tap_path, name)) |rb_path| {
            if (extractPostInstallBody(io, allocator, rb_path)) |body| return body;
            local = .body_not_extracted;
        } else {
            local = .no_rb;
        }
    }

    const fetch = source.fetchPostInstallFromGitHubTagged(io, environ, allocator, name);
    return switch (fetch) {
        .body => |b| b,
        else => classifyResolveFailure(local, fetch),
    };
}

/// Generate the Ruby wrapper script that provides a FormulaStub sandbox
/// and evaluates the post_install body.
///
/// `prefix`, `name`, `version` are interpolated into single-quoted Ruby
/// literals. They MUST contain only bytes from the centralised charset in
/// `fs/atomic.zig` — anything else (`'`, `\`, `\n`, control bytes, …)
/// would break the literal or open an injection. We validate at the
/// boundary rather than escape so the contract is one-line reviewable:
/// pass → safe to interpolate, fail → InvalidInput.
pub fn generateWrapper(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    prefix: []const u8,
    post_install_body: []const u8,
) ![]const u8 {
    if (prefix.len == 0 or name.len == 0 or version.len == 0) return error.InvalidInput;
    for (prefix) |b| if (!fs_atomic.isAllowedPrefixByte(b)) return error.InvalidInput;
    for (name) |b| if (!fs_atomic.isAllowedNameByte(b)) return error.InvalidInput;
    for (version) |b| if (!fs_atomic.isAllowedNameByte(b)) return error.InvalidInput;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const writer = &aw.writer;

    try writer.writeAll(
        \\require 'pathname'
        \\require 'fileutils'
        \\
        \\class FormulaStub
        \\  def initialize(name, version, malt_prefix)
        \\    @name = name
        \\    @version = version
        \\    @malt_prefix = Pathname.new(malt_prefix)
        \\    @prefix_path = @malt_prefix/'Cellar'/name/version
        \\  end
        \\
        \\  def name; @name; end
        \\  def version; @version; end
        \\  def prefix; @prefix_path; end
        \\  def bin; prefix/'bin'; end
        \\  def sbin; prefix/'sbin'; end
        \\  def lib; prefix/'lib'; end
        \\  def libexec; prefix/'libexec'; end
        \\  def include; prefix/'include'; end
        \\  def share; prefix/'share'; end
        \\  def pkgshare; share/@name; end
        \\  def frameworks; prefix/'Frameworks'; end
        \\  def kext_prefix; prefix/'Library/Extensions'; end
        \\  def etc; @malt_prefix/'etc'; end
        \\  def var; @malt_prefix/'var'; end
        \\  def opt_prefix; @malt_prefix/'opt'/@name; end
        \\  def opt_bin; opt_prefix/'bin'; end
        \\  def opt_lib; opt_prefix/'lib'; end
        \\  def opt_include; opt_prefix/'include'; end
        \\  def buildpath; prefix; end
        \\  def cellar; @malt_prefix/'Cellar'; end
        \\
        \\  HOMEBREW_PREFIX = Pathname.new('
    );
    try writer.writeAll(prefix);
    try writer.writeAll(
        \\')
        \\  HOMEBREW_CELLAR = HOMEBREW_PREFIX/'Cellar'
        \\
        \\  def inreplace(path, before = nil, after = nil, &block)
        \\    content = File.read(path.to_s)
        \\    if block
        \\      block.call(content)
        \\    else
        \\      content.gsub!(before.to_s, after.to_s)
        \\    end
        \\    File.write(path.to_s, content)
        \\  end
        \\
        \\  def system(*args)
        \\    result = Kernel.system(*args.map(&:to_s))
        \\    raise "system command failed: #{args.join(' ')}" unless result
        \\  end
        \\
        \\  def ohai(msg); puts "==> #{msg}"; end
        \\  def opoo(msg); $stderr.puts "Warning: #{msg}"; end
        \\  def odie(msg); $stderr.puts "Error: #{msg}"; exit 1; end
        \\
        \\  def which(cmd)
        \\    ENV['PATH'].split(':').each do |dir|
        \\      path = File.join(dir, cmd.to_s)
        \\      return Pathname.new(path) if File.executable?(path)
        \\    end
        \\    nil
        \\  end
        \\end
        \\
        \\
    );

    // Instantiate and run. The body is wrapped in a soft-fail rescue:
    // bodies that reach for Homebrew helpers we don't ship in
    // `FormulaStub` (`MachO`, `Pathname#dylib_id`, `rubygems_bindir`,
    // `OS.mac?`, `Hardware::CPU.arm?`, ...) bail cleanly with the
    // missing helper on stderr instead of failing the whole migration.
    // Net effect for kegs whose post_install is mostly Homebrew-tooling
    // glue (e.g. ruby's dylib-id rewrite, which malt's own Mach-O path
    // patcher already handles): the script exits 0, malt reports
    // `ran_via_ruby`, and the partial line tells the user *why* the
    // body bailed so they can verify nothing critical was skipped.
    try writer.print("stub = FormulaStub.new('{s}', '{s}', '{s}')\n", .{ name, version, prefix });
    try writer.writeAll(
        \\begin
        \\  stub.instance_eval do
        \\
    );
    try writer.writeAll(post_install_body);
    try writer.writeAll(
        \\
        \\  end
        \\rescue NoMethodError, NameError, NotImplementedError => e
        \\  $stderr.puts "post_install: partial - #{e.class.name.split('::').last}: #{e.message}"
        \\  exit 0
        \\end
        \\
    );

    return aw.toOwnedSlice();
}

/// Run the post_install hook for a formula via the system Ruby interpreter.
///
/// Requires:
/// - A Ruby interpreter available on the system
/// - Either the homebrew-core tap cloned locally OR network reachability
///   to GitHub's raw content host (the hash-pinned fallback fetches the
///   `.rb` source from a manifest-authorised commit when the tap is
///   absent).
pub fn runPostInstall(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    prefix: []const u8,
    stdio: sandbox.Stdio,
) RubyError!void {
    // 0. Boundary validation — must run before body resolution so a
    //    hostile name can't reach `fetchPostInstallFromGitHub` (which
    //    performs its own check but only after a network round-trip).
    try validateRunPostInstallInputs(name, version, prefix);

    // 2-4. Resolve the post_install body. Local homebrew-core tap is
    //      preferred; hash-pinned GitHub fetch is the fallback so
    //      API-only Homebrew installs (no tap clone) still resolve.
    //      The resolver returns a distinguishing tag so a hash mismatch
    //      doesn't get filed under "no local tap".
    const body = try resolvePostInstallBody(io, environ, allocator, name);
    defer allocator.free(body);
    return runPostInstallWithBody(io, environ, allocator, name, version, prefix, body, stdio);
}

fn validateRunPostInstallInputs(name: []const u8, version: []const u8, prefix: []const u8) RubyError!void {
    if (prefix.len == 0 or name.len == 0 or version.len == 0) return RubyError.InvalidInput;
    for (prefix) |b| if (!fs_atomic.isAllowedPrefixByte(b)) return RubyError.InvalidInput;
    for (name) |b| if (!fs_atomic.isAllowedNameByte(b)) return RubyError.InvalidInput;
    for (version) |b| if (!fs_atomic.isAllowedNameByte(b)) return RubyError.InvalidInput;
}

/// Tap-aware variant: caller has already extracted the post_install
/// body from the tap's `<name>.rb` (homebrew-core's locator can't reach
/// non-core taps). Skips body resolution; everything else mirrors
/// `runPostInstall` exactly so the sandbox + script-write contract
/// stays a single source of truth.
pub fn runPostInstallWithBody(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    prefix: []const u8,
    body: []const u8,
    stdio: sandbox.Stdio,
) RubyError!void {
    // 0. Validate inputs at the boundary. A hostile Cellar dir name (the
    //    on-disk source of `name` on the runPostInstall path) must die
    //    here, not deeper in script generation or the sandbox spawn.
    try validateRunPostInstallInputs(name, version, prefix);

    // Core returns outcomes; UI renders at the boundary — the CLI caller
    // maps each RubyError variant to user-facing text.

    // 1. Find Ruby (caller-owned heap slice — see detectRuby contract).
    const ruby_path = detectRuby(io, environ, allocator) orelse return RubyError.RubyNotFound;
    defer allocator.free(ruby_path);

    // 5. Generate wrapper script
    const script = generateWrapper(allocator, name, version, prefix, body) catch
        return RubyError.OutOfMemory;
    defer allocator.free(script);

    // 6. Write temp file with an exclusive-create to defeat tmp-file races.
    // The path includes the PID and a 128-bit random suffix so concurrent
    // post_install runs for the same (or a different) formula cannot collide,
    // and an attacker cannot pre-create the target to redirect execution.
    var tmp_path_buf: [256]u8 = undefined;
    var rand_bytes: [16]u8 = undefined;
    io.random(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const pid = std.c.getpid();
    const tmp_path = std.fmt.bufPrint(
        &tmp_path_buf,
        "/tmp/malt_post_install_{s}_{d}_{s}.rb",
        .{ name, pid, hex[0..] },
    ) catch return RubyError.ScriptWriteFailed;

    const tmp_file = std.Io.Dir.createFileAbsolute(io, tmp_path, .{
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch return RubyError.ScriptWriteFailed;
    tmp_file.writeStreamingAll(io, script) catch {
        tmp_file.close(io);
        // Cleanup of the partial tmp script; ScriptWriteFailed is the real error.
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        return RubyError.ScriptWriteFailed;
    };
    tmp_file.close(io);

    // Ensure cleanup — tmp path is PID+random, so a late-running delete
    // only ever targets this process's own script.
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    // 7. Spawn Ruby under sandbox-exec with a per-formula profile,
    //    scrubbed env, and resource limits. stdout/stderr inherit the
    //    parent's so post_install output still reaches the user.
    //    The parent's env is intentionally NOT forwarded — only HOME,
    //    a minimal PATH, MALT_PREFIX, and a formula-scoped TMPDIR pass.

    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(
        &cellar_buf,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, name, version },
    ) catch return RubyError.PostInstallFailed;

    const home = std.process.Environ.getPosix(environ, "HOME") orelse "/tmp";
    const env: sandbox.ScrubbedEnv = .{
        .home = home,
        .path = sandbox.sandbox_path,
        .malt_prefix = prefix,
        .tmpdir = "/tmp",
    };

    const exit_code = sandbox.runRubySandboxed(
        allocator,
        environ,
        ruby_path,
        tmp_path,
        cellar_path,
        prefix,
        env,
        .{},
        stdio,
    ) catch return RubyError.PostInstallFailed;
    if (exit_code != 0) return RubyError.PostInstallFailed;
}

test "classifyResolveFailure: fetch returned source but no body folds onto PostInstallBodyNotFound" {
    // body_not_found is fetch-arm-only — local arm doesn't matter.
    const cases = [_]LocalArmFailure{ .no_tap, .no_rb, .body_not_extracted };
    for (cases) |local| {
        try std.testing.expectEqual(
            RubyError.PostInstallBodyNotFound,
            classifyResolveFailure(local, .body_not_found),
        );
    }
}

test "classifyResolveFailure: fetch_failed maps to the deepest local-arm reason" {
    // The whole point of the split: hash mismatch under a populated tap
    // surfaces FetchFailed, not TapNotFound.
    try std.testing.expectEqual(
        RubyError.TapNotFound,
        classifyResolveFailure(.no_tap, .fetch_failed),
    );
    try std.testing.expectEqual(
        RubyError.FetchFailed,
        classifyResolveFailure(.no_rb, .fetch_failed),
    );
    try std.testing.expectEqual(
        RubyError.PostInstallBodyNotFound,
        classifyResolveFailure(.body_not_extracted, .fetch_failed),
    );
}
