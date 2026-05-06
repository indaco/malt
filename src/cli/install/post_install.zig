//! Post-install routing for formulas that declare a Ruby hook.
//! Prefers the native DSL interpreter and, when a per-formula scope
//! opts in, falls back to a sandboxed `ruby` subprocess. Single source
//! of truth for both `install` and `migrate` so users see byte-identical
//! human + JSON envelopes regardless of which command did the work.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;
const formula_mod = @import("../../core/formula.zig");
const dsl = @import("../../core/dsl/root.zig");
const ruby_sub = @import("../../core/ruby_subprocess.zig");
const output = @import("../../ui/output.zig");

const download = @import("download.zig");

/// Extract the post_install body from a tap's `<name>.rb`. Tap kegs
/// aren't reachable from the bottle DSL pipeline (the locator only
/// knows homebrew-core), so the migrate fallback resolves the body
/// here and feeds it to `driveTap`. Returns null when no `def
/// post_install` block is present, the file is missing, or the parser
/// can't extract a clean body — caller's contract is "run iff
/// non-null."
pub fn extractRbPostInstallBody(io: std.Io, allocator: std.mem.Allocator, rb_path: []const u8) ?[]const u8 {
    return ruby_sub.extractPostInstallBody(io, allocator, rb_path);
}

pub const DownloadJob = download.DownloadJob;

/// Whether --use-system-ruby opts the named formula into the Ruby
/// post_install path. Caller carries the parsed scope from the flag.
pub fn useSystemRubyForFormula(scope: []const []const u8, formula_name: []const u8) bool {
    for (scope) |n| if (std.mem.eql(u8, n, formula_name)) return true;
    return false;
}

/// `ruby` and its versioned aliases (`ruby@3`, `ruby@3.4`, ...) carry their
/// own `post_install` hook. Without auto-inclusion the user has to write
/// `--use-system-ruby=ruby` to install ruby — recursive nonsense, since
/// the trust boundary is whatever `mt migrate ruby` already implies.
pub fn isSelfHostingRubyKeg(name: []const u8) bool {
    if (std.mem.eql(u8, name, "ruby")) return true;
    if (!std.mem.startsWith(u8, name, "ruby@")) return false;
    const tail = name["ruby@".len..];
    if (tail.len == 0) return false;
    for (tail) |c| switch (c) {
        '0'...'9', '.' => {},
        else => return false,
    };
    return true;
}

/// Post_install outcome status — surfaced to users as human text and
/// to scripted consumers as JSON when `--json` is set.
pub const PostInstallStatus = enum {
    completed,
    partially_skipped,
    ran_via_ruby,
    ruby_fallback_failed,
    fatal,
};

/// Route the post_install outcome using the fallback log as the single
/// source of truth. "completed" means zero logged entries; any
/// unknown_method / unsupported_node downgrades to the same
/// `--use-system-ruby` suggestion we show on execute-time failures so
/// users never see "completed" when statements were silently skipped.
///
/// Under `--verbose`, the skipped entries are dumped so users can tell
/// WHICH helpers fell through. Under `--json`, a single status line is
/// emitted to stdout for scripted pipelines.
///
/// Pub so the install-pure tests can drive it with a synthetic flog and
/// pin the exact output for every branch.
pub fn routePostInstallOutcome(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    prefix: []const u8,
    flog: *const dsl.FallbackLog,
    use_system_ruby_list: []const []const u8,
) void {
    routePostInstallOutcomeWithBody(
        ctx,
        allocator,
        name,
        version_str,
        prefix,
        flog,
        use_system_ruby_list,
        null,
    );
}

/// Variant that takes a pre-resolved post_install body so the system-
/// Ruby fallback works for tap kegs (whose `.rb` source isn't reachable
/// through homebrew-core's locator). When `pre_resolved_body` is null
/// the routing matches the bottle path byte-for-byte.
pub fn routePostInstallOutcomeWithBody(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    prefix: []const u8,
    flog: *const dsl.FallbackLog,
    use_system_ruby_list: []const []const u8,
    pre_resolved_body: ?[]const u8,
) void {
    const status: PostInstallStatus = blk: {
        if (flog.hasFatal()) {
            output.warn("post_install DSL failed for {s} (fatal)", .{name});
            flog.printFatal(name);
            // `--debug` also surfaces the non-fatal context so a bug
            // report includes every reason the DSL logged, not just the
            // one that aborted execution.
            if (output.isDebug()) flog.printUnknown(name);
            break :blk .fatal;
        }
        if (!flog.hasErrors()) {
            output.info("post_install completed for {s}", .{name});
            break :blk .completed;
        }
        if (useSystemRubyForFormula(use_system_ruby_list, name) or isSelfHostingRubyKeg(name)) {
            output.warn("post_install DSL incomplete for {s}, falling back to system Ruby...", .{name});
            if (output.isVerbose()) flog.printUnknown(name);
            if (output.isDebug()) flog.printFatal(name);
            const ruby_result: anyerror!void = if (pre_resolved_body) |body|
                ruby_sub.runPostInstallWithBody(ctx.io, ctx.environ, allocator, name, version_str, prefix, body)
            else
                ruby_sub.runPostInstall(ctx.io, ctx.environ, allocator, name, version_str, prefix);
            ruby_result catch |e| {
                const err: ruby_sub.RubyError = @errorCast(e);
                output.warn("post_install subprocess failed for {s}: {s}", .{ name, ruby_sub.describeError(err) });
                break :blk .ruby_fallback_failed;
            };
            // Symmetric with the native "completed" info so scripted users
            // see a positive signal when the Ruby escape hatch succeeded.
            output.info("post_install completed for {s} (via system Ruby)", .{name});
            break :blk .ran_via_ruby;
        }
        output.warn("{s}: post_install partially skipped (use --use-system-ruby={s} to attempt via Ruby)", .{ name, name });
        if (output.isVerbose()) flog.printUnknown(name);
        if (output.isDebug()) flog.printFatal(name);
        break :blk .partially_skipped;
    };

    // ndjson always streams; --json picks per-command between streaming
    // and buffering for embed in a final summary doc.
    if (output.isNdjson()) {
        emitPostInstallStreamLine(allocator, name, status, flog);
        return;
    }
    if (output.isJson()) {
        switch (output.postInstallEmit()) {
            .stream => emitPostInstallStreamLine(allocator, name, status, flog),
            .embed => bufferPostInstallEvent(allocator, name, status, flog),
        }
    }
}

/// Write one JSON line per post_install routing decision to stdout. One
/// line per package keeps the stream pipe-friendly (`jq -c`, line-split).
fn emitPostInstallStreamLine(
    allocator: std.mem.Allocator,
    name: []const u8,
    status: PostInstallStatus,
    flog: *const dsl.FallbackLog,
) void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    // Event prefix sourced from NdjsonEvent so renames propagate.
    w.writeAll("{\"event\":\"") catch return;
    w.writeAll(@tagName(output.NdjsonEvent.post_install)) catch return;
    w.writeAll("\",") catch return;
    writePostInstallBody(w, allocator, name, status, flog) catch return;
    w.writeAll("}\n") catch return;
    output.writeStdoutAll(aw.written());
}

/// Append `{name,status,entries}` to the accumulator for later embed.
fn bufferPostInstallEvent(
    allocator: std.mem.Allocator,
    name: []const u8,
    status: PostInstallStatus,
    flog: *const dsl.FallbackLog,
) void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{") catch return;
    writePostInstallBody(w, allocator, name, status, flog) catch return;
    w.writeAll("}") catch return;
    // Surface push errors loudly so a half-populated summary is obvious.
    output.pushPostInstallEvent(aw.written()) catch |e|
        output.warn("post_install event buffering failed for {s}: {s}", .{ name, @errorName(e) });
}

/// Shared payload writer so the streaming line and buffered embed
/// stay byte-equivalent at the field level.
fn writePostInstallBody(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    name: []const u8,
    status: PostInstallStatus,
    flog: *const dsl.FallbackLog,
) !void {
    try w.writeAll("\"name\":");
    try output.jsonStr(w, name);
    try w.writeAll(",\"status\":\"");
    try w.writeAll(@tagName(status));
    try w.writeAll("\",\"entries\":");
    const entries_json = try flog.toJson(allocator);
    defer allocator.free(entries_json);
    try w.writeAll(entries_json);
}

/// Outcome of a single DSL post_install attempt. `.parse_failed` lets
/// the caller fall through to the system-Ruby fallback instead of
/// silently dropping the hook.
pub const DslPostInstallOutcome = enum {
    handled,
    parse_failed,
};

/// Run one DSL post_install attempt for a formula. Owns the parsed
/// formula + FallbackLog lifetimes so callers don't have to replicate
/// the cleanup chain across every candidate source (local .rb, GitHub).
///
/// Narrow inputs (name + version + json bytes) keep migrate decoupled
/// from install's `DownloadJob` shape.
pub fn executeDslPostInstall(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    formula_json: []const u8,
    post_install_src: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
) DslPostInstallOutcome {
    var formula = formula_mod.parseFormula(allocator, formula_json) catch {
        output.warn("post_install: failed to parse formula for {s}", .{name});
        return .parse_failed;
    };
    defer formula.deinit();
    executeDslPostInstallFields(
        ctx,
        allocator,
        name,
        version_str,
        formula.version,
        formula.pkg_version,
        post_install_src,
        prefix,
        use_system_ruby_list,
    );
    return .handled;
}

/// Fields-based variant: bypass formula JSON entirely. Used by the
/// migrate tap-fallback path where we already have name/version from
/// the receipt and the post_install body extracted from the tap's .rb.
/// Forwards the body through to the router so a `--use-system-ruby`
/// fallback for a tap keg targets the same body the DSL was run with —
/// homebrew-core's locator can't reach non-core taps.
pub fn executeDslPostInstallFields(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    dsl_version: []const u8,
    pkg_version: []const u8,
    post_install_src: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
) void {
    var flog = dsl.FallbackLog.init(allocator);
    defer flog.deinit();

    // DSL errors reflect in `flog`; the router reads the log as the source
    // of truth so silent skips downgrade the same as hard failures.
    dsl.executePostInstall(ctx.io, ctx.environ, allocator, .{
        .name = name,
        .version = dsl_version,
        .pkg_version = pkg_version,
    }, post_install_src, prefix, &flog) catch {};
    routePostInstallOutcomeWithBody(
        ctx,
        allocator,
        name,
        version_str,
        prefix,
        &flog,
        use_system_ruby_list,
        post_install_src,
    );
}

/// Locate a DSL post_install body for `name`: prefer a locally cloned
/// homebrew-core tap, fall back to the pinned GitHub fetch. Returned
/// slice (when non-null) is owned by the caller.
fn locateDslSource(ctx: *const AppCtx, allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const tap_path = ruby_sub.findHomebrewCoreTap(ctx.io);
    var rb_buf: [1024]u8 = undefined;
    const rb_path = if (tap_path) |tp|
        ruby_sub.resolveFormulaRbPath(ctx.io, &rb_buf, tp, name)
    else
        null;
    if (rb_path) |sp| {
        if (ruby_sub.extractPostInstallBody(ctx.io, allocator, sp)) |s| return s;
    }
    return ruby_sub.fetchPostInstallFromGitHub(ctx.io, ctx.environ, allocator, name);
}

/// End-to-end post_install dispatch shared by `install` and `migrate`:
/// locate a DSL source, run it through the interpreter and route the
/// outcome, or fall back to a system-Ruby subprocess (when the formula
/// is in `--use-system-ruby` scope) or the unified skip hint. Both
/// commands route through here so human + JSON envelopes match exactly.
pub fn drive(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    formula_json: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
) void {
    if (locateDslSource(ctx, allocator, name)) |src| {
        defer allocator.free(src);
        switch (executeDslPostInstall(
            ctx,
            allocator,
            name,
            version_str,
            formula_json,
            src,
            prefix,
            use_system_ruby_list,
        )) {
            .handled => return,
            // parse_failed leaves the DSL path unusable — fall through so
            // the system-Ruby fallback still has a chance to run.
            .parse_failed => {},
        }
    }

    if (useSystemRubyForFormula(use_system_ruby_list, name) or isSelfHostingRubyKeg(name)) {
        output.warn("Running post_install for {s} via system Ruby...", .{name});
        ruby_sub.runPostInstall(ctx.io, ctx.environ, allocator, name, version_str, prefix) catch |e| {
            output.warn("post_install failed for {s}: {s}", .{ name, ruby_sub.describeError(e) });
        };
    } else {
        output.warn("{s}: post_install skipped (use --use-system-ruby={s} or brew install {s})", .{ name, name, name });
    }
}

/// Tap-fallback analog of `drive`: the post_install body has already
/// been resolved off the tap's `<name>.rb`, so we skip the homebrew-core
/// locator and feed it straight to the DSL. The router still emits the
/// same `completed` / `partially skipped` / `--use-system-ruby` lines —
/// this is the install path's user-facing contract, just sourced from
/// a tap receipt instead of a parsed formula.
///
/// Tap kegs migrated through the fallback carry no revision suffix
/// (the receipt's `source.versions.stable` is the whole version), so a
/// single `version` string covers both the user-facing message and the
/// DSL's `formula.version` / `formula.pkg_version` slots.
pub fn driveTap(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    post_install_src: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
) void {
    executeDslPostInstallFields(
        ctx,
        allocator,
        name,
        version,
        version,
        version,
        post_install_src,
        prefix,
        use_system_ruby_list,
    );
}

test "extractRbPostInstallBody: returns the body when the .rb defines post_install" {
    const dir = "/tmp/malt_pi_decl_yes";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, dir) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, dir) catch {};

    const rb = dir ++ "/glow.rb";
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, rb, .{ .truncate = true });
    try f.writeStreamingAll(std.Options.debug_io,
        \\class Glow < Formula
        \\  def post_install
        \\    bin.install "glow"
        \\  end
        \\end
        \\
    );
    f.close(std.Options.debug_io);

    const body = extractRbPostInstallBody(std.Options.debug_io, std.testing.allocator, rb);
    try std.testing.expect(body != null);
    defer std.testing.allocator.free(body.?);
    try std.testing.expect(std.mem.indexOf(u8, body.?, "bin.install") != null);
}

test "extractRbPostInstallBody: null when the .rb has no post_install block" {
    const dir = "/tmp/malt_pi_decl_no";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, dir) catch {};
    try std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, dir) catch {};

    const rb = dir ++ "/quiet.rb";
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, rb, .{ .truncate = true });
    try f.writeStreamingAll(std.Options.debug_io,
        \\class Quiet < Formula
        \\  url "x"
        \\end
        \\
    );
    f.close(std.Options.debug_io);

    try std.testing.expect(extractRbPostInstallBody(std.Options.debug_io, std.testing.allocator, rb) == null);
}

test "extractRbPostInstallBody: null when the .rb is missing entirely" {
    try std.testing.expect(extractRbPostInstallBody(
        std.Options.debug_io,
        std.testing.allocator,
        "/tmp/malt_pi_decl_missing/never.rb",
    ) == null);
}

test "isSelfHostingRubyKeg: bare ruby and versioned aliases match" {
    try std.testing.expect(isSelfHostingRubyKeg("ruby"));
    try std.testing.expect(isSelfHostingRubyKeg("ruby@3"));
    try std.testing.expect(isSelfHostingRubyKeg("ruby@3.4"));
    try std.testing.expect(isSelfHostingRubyKeg("ruby@4.0.3"));
}

test "isSelfHostingRubyKeg: non-ruby kegs and lookalikes are rejected" {
    try std.testing.expect(!isSelfHostingRubyKeg(""));
    try std.testing.expect(!isSelfHostingRubyKeg("rubygems"));
    try std.testing.expect(!isSelfHostingRubyKeg("iruby"));
    try std.testing.expect(!isSelfHostingRubyKeg("jruby"));
    try std.testing.expect(!isSelfHostingRubyKeg("ruby-build"));
    // Empty/garbage version tail must not auto-include — keeps the
    // pattern tight to canonical Homebrew interpreter kegs.
    try std.testing.expect(!isSelfHostingRubyKeg("ruby@"));
    try std.testing.expect(!isSelfHostingRubyKeg("ruby@stable"));
    try std.testing.expect(!isSelfHostingRubyKeg("ruby@3-rc1"));
}
