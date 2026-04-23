//! Post-install routing for formulas that declare a Ruby hook.
//! Prefers the native DSL interpreter and, when a per-formula scope
//! opts in, falls back to a sandboxed `ruby` subprocess.

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
                output.warn("post_install subprocess failed for {s}: {s}", .{ name, @errorName(e) });
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

/// Run one DSL post_install attempt against `job`. Owns the formula +
/// FallbackLog lifetimes so callers don't have to replicate the cleanup
/// chain across every candidate source (local .rb, GitHub fetch).
///
/// Pub so install-pure tests can pin the outcome contract directly.
pub fn executeDslPostInstall(
    allocator: std.mem.Allocator,
    job: *const DownloadJob,
    post_install_src: []const u8,
    prefix: []const u8,
    use_system_ruby_list: []const []const u8,
) DslPostInstallOutcome {
    var formula = formula_mod.parseFormula(allocator, job.formula_json) catch {
        output.warn("post_install: failed to parse formula for {s}", .{job.name});
        return .parse_failed;
    };
    defer formula.deinit();

    var flog = dsl.FallbackLog.init(allocator);
    defer flog.deinit();

    // DSL errors reflect in `flog`; the router reads the log as the source
    // of truth so silent skips downgrade the same as hard failures.
    dsl.executePostInstall(allocator, &formula, post_install_src, prefix, &flog) catch {};
    routePostInstallOutcome(allocator, job.name, job.version_str, prefix, &flog, use_system_ruby_list);
    return .handled;
}
