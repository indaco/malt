//! Post-install routing for formulas that declare a Ruby hook.
//! Prefers the native DSL interpreter and, when a per-formula scope
//! opts in, falls back to a sandboxed `ruby` subprocess. Single source
//! of truth for both `install` and `migrate` so users see byte-identical
//! human + JSON envelopes regardless of which command did the work.

const std = @import("std");
const formula_mod = @import("../../core/formula.zig");
const dsl = @import("../../core/dsl/root.zig");
const ruby_sub = @import("../../core/ruby_subprocess.zig");
const output = @import("../../ui/output.zig");
const io_mod = @import("../../ui/io.zig");

const download = @import("download.zig");

pub const DownloadJob = download.DownloadJob;

/// Whether --use-system-ruby opts the named formula into the Ruby
/// post_install path. Caller carries the parsed scope from the flag.
pub fn useSystemRubyForFormula(scope: []const []const u8, formula_name: []const u8) bool {
    for (scope) |n| if (std.mem.eql(u8, n, formula_name)) return true;
    return false;
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
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    prefix: []const u8,
    flog: *const dsl.FallbackLog,
    use_system_ruby_list: []const []const u8,
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
        if (useSystemRubyForFormula(use_system_ruby_list, name)) {
            output.warn("post_install DSL incomplete for {s}, falling back to system Ruby...", .{name});
            if (output.isVerbose()) flog.printUnknown(name);
            if (output.isDebug()) flog.printFatal(name);
            ruby_sub.runPostInstall(allocator, name, version_str, prefix) catch |e| {
                output.warn("post_install subprocess failed for {s}: {s}", .{ name, ruby_sub.describeError(e) });
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

    if (output.isJson()) emitPostInstallJson(allocator, name, status, flog);
}

/// Write one JSON line per post_install routing decision to stdout. One
/// line per package keeps the stream pipe-friendly (`jq -c`, line-split).
fn emitPostInstallJson(
    allocator: std.mem.Allocator,
    name: []const u8,
    status: PostInstallStatus,
    flog: *const dsl.FallbackLog,
) void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"event\":\"post_install\",\"name\":") catch return;
    output.jsonStr(w, name) catch return;
    w.writeAll(",\"status\":\"") catch return;
    w.writeAll(@tagName(status)) catch return;
    w.writeAll("\",\"entries\":") catch return;
    const entries_json = flog.toJson(allocator) catch return;
    defer allocator.free(entries_json);
    w.writeAll(entries_json) catch return;
    w.writeAll("}\n") catch return;
    io_mod.stdoutWriteAll(aw.written());
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

    var flog = dsl.FallbackLog.init(allocator);
    defer flog.deinit();

    // DSL errors reflect in `flog`; the router reads the log as the source
    // of truth so silent skips downgrade the same as hard failures.
    dsl.executePostInstall(allocator, .{
        .name = formula.name,
        .version = formula.version,
        .pkg_version = formula.pkg_version,
    }, post_install_src, prefix, &flog) catch {};
    routePostInstallOutcome(allocator, name, version_str, prefix, &flog, use_system_ruby_list);
    return .handled;
}

/// Locate a DSL post_install body for `name`: prefer a locally cloned
/// homebrew-core tap, fall back to the pinned GitHub fetch. Returned
/// slice (when non-null) is owned by the caller.
fn locateDslSource(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const tap_path = ruby_sub.findHomebrewCoreTap();
    var rb_buf: [1024]u8 = undefined;
    const rb_path = if (tap_path) |tp|
        ruby_sub.resolveFormulaRbPath(&rb_buf, tp, name)
    else
        null;
    if (rb_path) |sp| {
        if (ruby_sub.extractPostInstallBody(allocator, sp)) |s| return s;
    }
    return ruby_sub.fetchPostInstallFromGitHub(allocator, name);
}

/// End-to-end post_install dispatch shared by `install` and `migrate`:
/// locate a DSL source, run it through the interpreter and route the
/// outcome, or fall back to a system-Ruby subprocess (when the formula
/// is in `--use-system-ruby` scope) or the unified skip hint. Both
/// commands route through here so human + JSON envelopes match exactly.
pub fn drive(
    allocator: std.mem.Allocator,
    name: []const u8,
    version_str: []const u8,
    formula_json: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
) void {
    if (locateDslSource(allocator, name)) |src| {
        defer allocator.free(src);
        switch (executeDslPostInstall(
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

    if (useSystemRubyForFormula(use_system_ruby_list, name)) {
        output.warn("Running post_install for {s} via system Ruby...", .{name});
        ruby_sub.runPostInstall(allocator, name, version_str, prefix) catch |e| {
            output.warn("post_install failed for {s}: {s}", .{ name, ruby_sub.describeError(e) });
        };
    } else {
        output.warn("{s}: post_install skipped (use --use-system-ruby={s} or brew install {s})", .{ name, name, name });
    }
}
