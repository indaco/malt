//! Post-install routing for formulas that declare a Ruby hook.
//! Prefers the native DSL interpreter and, when a per-formula scope
//! opts in, falls back to a sandboxed `ruby` subprocess. Single source
//! of truth for both `install` and `migrate` so users see byte-identical
//! human + JSON envelopes regardless of which command did the work.

const std = @import("std");

const AppCtx = @import("../../app_ctx.zig").AppCtx;
const deps_mod = @import("../../core/deps.zig");
const dsl = @import("../../core/dsl/root.zig");
const formula_mod = @import("../../core/formula.zig");
const ruby_sub = @import("../../core/ruby_subprocess.zig");
const steps_mod = @import("../../core/post_install_steps.zig");
const sandbox = @import("../../core/sandbox/macos.zig");
const output = @import("../../ui/output.zig");
const download = @import("download.zig");
pub const DownloadJob = download.DownloadJob;
const sink_mod = @import("sink.zig");
const OutputSink = sink_mod.OutputSink;

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

/// Steps-migrated tap formulas carry a declarative `post_install_steps`
/// block instead of `def post_install`; detect it so migrate can warn
/// instead of silently dropping the hook.
pub fn rbHasPostInstallSteps(io: std.Io, allocator: std.mem.Allocator, rb_path: []const u8) bool {
    return ruby_sub.rbHasPostInstallSteps(io, allocator, rb_path);
}

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
/// Auto-included Ruby-interpreter kegs (`ruby`, `ruby@N`) only fall
/// through to the system-Ruby re-run when the DSL handled none of the
/// body. Their effects often already landed at brew-install time, so a
/// blanket re-run would double-stamp non-idempotent steps (counters,
/// timestamps, version caches). Explicit `--use-system-ruby=NAME` is
/// a user opt-in and falls through unconditionally.
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
    sink: OutputSink,
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
        sink,
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
    sink: OutputSink,
) void {
    // Diagnostics the DSL recorded during execution render first, matching
    // the pre-refactor order where they printed inline before routing.
    renderNotes(flog);
    const status: PostInstallStatus = blk: {
        if (flog.hasFatal()) {
            sink.warn("post_install DSL failed for {s} (fatal)", .{name});
            renderFatal(flog, name);
            // `--debug` also surfaces the non-fatal context so a bug
            // report includes every reason the DSL logged, not just the
            // one that aborted execution.
            if (output.isDebug()) renderUnknown(flog, name);
            break :blk .fatal;
        }
        if (!flog.hasErrors()) {
            sink.info("post_install completed for {s}", .{name});
            break :blk .completed;
        }
        // Auto-included Ruby-interpreter kegs (`ruby`, `ruby@N`) skip the
        // re-run when the DSL handled any top-level statement: their
        // post_install effects often already landed (e.g. `mt migrate ruby`
        // after brew installed it), so a Ruby-side re-run would double-stamp
        // non-idempotent steps. Explicit `--use-system-ruby=NAME` honors the
        // user's opt-in unconditionally.
        const explicit_opt_in = useSystemRubyForFormula(use_system_ruby_list, name);
        const auto_self_hosting = isSelfHostingRubyKeg(name);
        if (explicit_opt_in or (auto_self_hosting and !flog.dslDidWork())) {
            sink.warn("post_install DSL incomplete for {s}, falling back to system Ruby...", .{name});
            if (output.isVerbose()) renderUnknown(flog, name);
            if (output.isDebug()) renderFatal(flog, name);
            const ruby_stdio: sandbox.Stdio = .{ .out = ctx.stdout.handle, .err = ctx.stderr.handle };
            const ruby_result: ruby_sub.RubyError!void = if (pre_resolved_body) |body|
                ruby_sub.runPostInstallWithBody(ctx.io, ctx.environ, allocator, name, version_str, prefix, body, ruby_stdio)
            else
                ruby_sub.runPostInstall(ctx.io, ctx.environ, allocator, name, version_str, prefix, ruby_stdio);
            ruby_result catch |err| {
                sink.warn("post_install subprocess failed for {s}: {s}", .{ name, ruby_sub.describeError(err) });
                break :blk .ruby_fallback_failed;
            };
            // Symmetric with the native "completed" info so scripted users
            // see a positive signal when the Ruby escape hatch succeeded.
            sink.info("post_install completed for {s} (via system Ruby)", .{name});
            break :blk .ran_via_ruby;
        }
        sink.warn("{s}: post_install partially skipped (use --use-system-ruby={s} to attempt via Ruby)", .{ name, name });
        if (output.isVerbose()) renderUnknown(flog, name);
        if (output.isDebug()) renderFatal(flog, name);
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
            .embed => bufferPostInstallEvent(allocator, name, status, flog, sink),
        }
    }
}

/// Render the log entries whose reason is in `reasons` as
/// `tag:line:col: [reason] detail` lines. Rendering lives here, not in
/// core/dsl: the fallback log is pure recording, the CLI owns the UI.
fn renderEntries(flog: *const dsl.FallbackLog, tag: []const u8, comptime reasons: []const dsl.FallbackReason) void {
    for (flog.entries()) |entry| {
        if (std.mem.indexOfScalar(dsl.FallbackReason, reasons, entry.reason) == null) continue;
        var buf: [1024]u8 = undefined;
        const formatted = if (entry.loc) |loc|
            std.fmt.bufPrint(&buf, "  {s}:{d}:{d}: [{s}] {s}\n", .{
                tag, loc.line, loc.col, @tagName(entry.reason), entry.detail,
            }) catch continue
        else
            std.fmt.bufPrint(&buf, "  {s}: [{s}] {s}\n", .{
                tag, @tagName(entry.reason), entry.detail,
            }) catch continue;
        output.writeStderrAll(formatted);
    }
}

/// Fatal-or-diagnostic entries (`parse_error` included so users get the
/// file:line:col before a `--use-system-ruby` salvage).
fn renderFatal(flog: *const dsl.FallbackLog, tag: []const u8) void {
    renderEntries(flog, tag, &.{ .sandbox_violation, .system_command_failed, .parse_error });
}

/// The log-only reasons `renderFatal` skips; shown under `--verbose`.
fn renderUnknown(flog: *const dsl.FallbackLog, tag: []const u8) void {
    renderEntries(flog, tag, &.{ .unknown_method, .unsupported_node });
}

/// Emit the pure log's free-form diagnostics (raise messages, inreplace
/// fallback warnings) plus any OOM-drop notice. The DSL records these
/// during execution; rendering is the CLI's job so core/dsl stays UI-free.
fn renderNotes(flog: *const dsl.FallbackLog) void {
    for (flog.notes()) |line| output.writeStderrAll(line);
    if (flog.dropped_oom)
        output.writeStderrAll("malt: fallback log dropped an entry due to OOM\n");
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
    sink: OutputSink,
) void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{") catch return;
    writePostInstallBody(w, allocator, name, status, flog) catch return;
    w.writeAll("}") catch return;
    // Surface push errors loudly so a half-populated summary is obvious.
    output.pushPostInstallEvent(aw.written()) catch |e|
        sink.warn("post_install event buffering failed for {s}: {s}", .{ name, @errorName(e) });
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
///
/// `cache`, when non-null, is the install pipeline's per-run
/// `FormulaCache`: routes through it so the parse-once invariant the
/// dep resolver and `linkAndRecord` rely on extends to post_install.
/// Null callers (migrate, tests) keep a private parse arena.
pub fn executeDslPostInstall(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    formula_json: []const u8,
    post_install_src: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
    cache: ?*deps_mod.FormulaCache,
    sink: OutputSink,
) DslPostInstallOutcome {
    var owned: ?formula_mod.Formula = null;
    defer if (owned) |*f| f.deinit();

    const dsl_version: []const u8, const pkg_version: []const u8 = blk: {
        if (cache) |c| {
            const f = c.getOrParse(name, formula_json) catch {
                sink.warn("post_install: failed to parse formula for {s}", .{name});
                return .parse_failed;
            };
            break :blk .{ f.version, f.pkg_version };
        }
        owned = formula_mod.parseFormula(allocator, formula_json) catch {
            sink.warn("post_install: failed to parse formula for {s}", .{name});
            return .parse_failed;
        };
        break :blk .{ owned.?.version, owned.?.pkg_version };
    };

    executeDslPostInstallFields(
        ctx,
        allocator,
        name,
        version_str,
        dsl_version,
        pkg_version,
        post_install_src,
        prefix,
        use_system_ruby_list,
        sink,
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
    sink: OutputSink,
) void {
    var flog = dsl.FallbackLog.init(allocator);
    defer flog.deinit();

    // DSL errors reflect in `flog`; the router reads the log as the source
    // of truth so silent skips downgrade the same as hard failures. The
    // stdio mode is read here (CLI owns --json/--ndjson) and threaded in so
    // a spawned child's stdout can't corrupt the document.
    dsl.executePostInstallWithOpts(ctx.io, ctx.environ, allocator, .{
        .name = name,
        .version = dsl_version,
        .pkg_version = pkg_version,
    }, post_install_src, prefix, &flog, .{
        .suppress_child_stdout = output.isJson() or output.isNdjson(),
    }) catch {};
    routePostInstallOutcomeWithBody(
        ctx,
        allocator,
        name,
        version_str,
        prefix,
        &flog,
        use_system_ruby_list,
        post_install_src,
        sink,
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
///
/// `cache` is forwarded to `executeDslPostInstall`; pass non-null from
/// the install path to share the parse-once cache, null from migrate
/// (its own per-keg parse already owns the lifetime).
pub fn drive(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    formula_json: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
    cache: ?*deps_mod.FormulaCache,
    sink: OutputSink,
) void {
    // Steps-migrated formulas have no Ruby body to extract — the JSON steps
    // are authoritative and already in hand, so this path goes first.
    if (driveSteps(ctx, allocator, name, version_str, formula_json, prefix, use_system_ruby_list, cache, sink))
        return;

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
            cache,
            sink,
        )) {
            .handled => return,
            // parse_failed leaves the DSL path unusable — fall through so
            // the system-Ruby fallback still has a chance to run.
            .parse_failed => {},
        }
    }

    if (useSystemRubyForFormula(use_system_ruby_list, name) or isSelfHostingRubyKeg(name)) {
        sink.warn("Running post_install for {s} via system Ruby...", .{name});
        const ruby_stdio: sandbox.Stdio = .{ .out = ctx.stdout.handle, .err = ctx.stderr.handle };
        ruby_sub.runPostInstall(ctx.io, ctx.environ, allocator, name, version_str, prefix, ruby_stdio) catch |e| {
            sink.warn("post_install failed for {s}: {s}", .{ name, ruby_sub.describeError(e) });
        };
    } else {
        sink.warn("{s}: post_install skipped (use --use-system-ruby={s} or brew install {s})", .{ name, name, name });
    }
}

/// Native dispatch for formulas migrated to the declarative
/// `post_install_steps` array. Returns true when the steps path owned the
/// formula — executed (or loudly downgraded) and routed through the same
/// outcome envelope as the DSL path. False means "no steps": the caller's
/// Ruby-body pipeline still owns the formula.
pub fn driveSteps(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    formula_json: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
    cache: ?*deps_mod.FormulaCache,
    sink: OutputSink,
) bool {
    var owned: ?formula_mod.Formula = null;
    defer if (owned) |*f| f.deinit();

    const has_steps: bool, const dsl_version: []const u8, const pkg_version: []const u8 = blk: {
        if (cache) |c| {
            const f = c.getOrParse(name, formula_json) catch return false;
            break :blk .{ f.has_post_install_steps, f.version, f.pkg_version };
        }
        owned = formula_mod.parseFormula(allocator, formula_json) catch return false;
        break :blk .{ owned.?.has_post_install_steps, owned.?.version, owned.?.pkg_version };
    };
    if (!has_steps) return false;

    // Arena owns every resolved path and log detail until routing is done;
    // the flog itself lives on the caller allocator like the DSL path.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var flog = dsl.FallbackLog.init(allocator);
    defer flog.deinit();

    const keg_path = std.fmt.allocPrint(arena.allocator(), "{s}/Cellar/{s}/{s}", .{ prefix, name, pkg_version }) catch return false;
    _ = steps_mod.execute(.{
        .io = ctx.io,
        .allocator = arena.allocator(),
        .name = name,
        .version = dsl_version,
        .prefix = prefix,
        .keg_path = keg_path,
        .flog = &flog,
        .suppress_child_stdout = output.isJson() or output.isNdjson(),
        .environ = ctx.environ,
    }, formula_json);

    routePostInstallOutcome(ctx, allocator, name, version_str, prefix, &flog, use_system_ruby_list, sink);
    return true;
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
    sink: OutputSink,
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
        sink,
    );
}

/// ca-certificates' macOS post_install regenerates the trust store from
/// the system keychain — Ruby surface the native DSL can't run, so it
/// lands no `cert.pem`. Mirror the formula's own documented fallback
/// natively: when a keg ships `share/<name>/cacert.pem` but post_install
/// left `etc/<name>/cert.pem` absent, symlink the shipped Mozilla bundle
/// into place. opt-anchored so the link survives version bumps; no-op for
/// any keg that ships no CA bundle, and idempotent once it is present.
pub fn provisionShippedCaBundle(io: std.Io, prefix: []const u8, name: []const u8) void {
    var shipped_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shipped = std.fmt.bufPrint(&shipped_buf, "{s}/opt/{s}/share/{s}/cacert.pem", .{ prefix, name, name }) catch return;
    // Keg ships no CA bundle → nothing to provision.
    std.Io.Dir.cwd().access(io, shipped, .{}) catch return;

    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/etc/{s}/cert.pem", .{ prefix, name }) catch return;
    // post_install (or a prior provision) already landed a bundle → leave it.
    if (std.Io.Dir.cwd().access(io, dest, .{})) |_| return else |_| {}

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/etc/{s}", .{ prefix, name }) catch return;
    // Same non-raising fs contract as the DSL fs builtins: a failed link
    // surfaces downstream (doctor/shellenv report the missing bundle).
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    std.Io.Dir.cwd().deleteFile(io, dest) catch {}; // replace a stale dangling link
    std.Io.Dir.symLinkAbsolute(io, shipped, dest, .{}) catch {};
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

/// Lay down `<prefix>/opt/<name>/share/<name>/cacert.pem` with `content`,
/// mimicking a freshly linked CA-bundle keg.
fn writeShippedBundle(prefix: []const u8, name: []const u8, content: []const u8) !void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const share_dir = try std.fmt.bufPrint(&dir_buf, "{s}/opt/{s}/share/{s}", .{ prefix, name, name });
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, share_dir);
    var f_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shipped = try std.fmt.bufPrint(&f_buf, "{s}/cacert.pem", .{share_dir});
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, shipped, .{ .truncate = true });
    try f.writeStreamingAll(std.Options.debug_io, content);
    f.close(std.Options.debug_io);
}

test "provisionShippedCaBundle: links cert.pem to the shipped cacert.pem when absent" {
    const prefix = "/tmp/malt_ca_provision_link";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    try writeShippedBundle(prefix, "ca-certificates", "MOZILLA-BUNDLE");

    provisionShippedCaBundle(std.Options.debug_io, prefix, "ca-certificates");

    // cert.pem now resolves (opt-anchored) to the shipped bundle.
    const dest = prefix ++ "/etc/ca-certificates/cert.pem";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(std.Options.debug_io, dest, &buf);
    try std.testing.expectEqualStrings(prefix ++ "/opt/ca-certificates/share/ca-certificates/cacert.pem", buf[0..n]);
}

test "provisionShippedCaBundle: leaves an existing cert.pem untouched" {
    const prefix = "/tmp/malt_ca_provision_keep";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    try writeShippedBundle(prefix, "ca-certificates", "MOZILLA-BUNDLE");

    // A post_install (or system-Ruby regeneration) already wrote a real bundle.
    const etc_dir = prefix ++ "/etc/ca-certificates";
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, etc_dir);
    const dest = etc_dir ++ "/cert.pem";
    {
        const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, dest, .{ .truncate = true });
        try f.writeStreamingAll(std.Options.debug_io, "REAL-KEYCHAIN-BUNDLE");
        f.close(std.Options.debug_io);
    }

    provisionShippedCaBundle(std.Options.debug_io, prefix, "ca-certificates");

    // Untouched: still the regular file we wrote, not replaced by a symlink.
    const st = try std.Io.Dir.cwd().statFile(std.Options.debug_io, dest, .{});
    try std.testing.expect(st.kind == .file);
}

test "provisionShippedCaBundle: no-op when the keg ships no cacert.pem" {
    const prefix = "/tmp/malt_ca_provision_noop";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};

    provisionShippedCaBundle(std.Options.debug_io, prefix, "tree");

    const dest = prefix ++ "/etc/tree/cert.pem";
    if (std.Io.Dir.cwd().access(std.Options.debug_io, dest, .{})) |_| {
        return error.TestUnexpectedResult; // a non-CA keg must not get a cert.pem
    } else |_| {}
}

test "provisionShippedCaBundle: self-heals a stale dangling cert.pem symlink" {
    const prefix = "/tmp/malt_ca_provision_dangle";
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    try writeShippedBundle(prefix, "ca-certificates", "MOZILLA-BUNDLE");

    // A prior install left cert.pem pointing at a now-removed target.
    const etc_dir = prefix ++ "/etc/ca-certificates";
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, etc_dir);
    const dest = etc_dir ++ "/cert.pem";
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, prefix ++ "/gone/cacert.pem", dest, .{});

    provisionShippedCaBundle(std.Options.debug_io, prefix, "ca-certificates");

    // Repointed at the shipped bundle rather than left dangling.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(std.Options.debug_io, dest, &buf);
    try std.testing.expectEqualStrings(prefix ++ "/opt/ca-certificates/share/ca-certificates/cacert.pem", buf[0..n]);
}
