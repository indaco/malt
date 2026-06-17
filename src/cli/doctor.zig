//! malt — doctor command
//! System health check.

const std = @import("std");

const mount_c = @import("c_mount");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const patch = @import("../core/patch.zig");
const perms_mod = @import("../core/perms.zig");
const lock_mod = @import("../db/lock.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const tap_cache_mod = @import("../core/tap_cache.zig");
const tap_mod = @import("../core/tap.zig");
const clonefile = @import("../fs/clonefile.zig");
const parser = @import("../macho/parser.zig");
const client_mod = @import("../net/client.zig");
const mirror_mod = @import("../net/mirror.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
pub const cask_history = @import("doctor/cask_history.zig");
const fix_mod = @import("doctor/fix.zig");
pub const FixKind = fix_mod.FixKind;
pub const ManualKind = fix_mod.ManualKind;
pub const FixConditions = fix_mod.Conditions;
pub const FixPlan = fix_mod.Plan;
pub const planFixes = fix_mod.planFixes;
const post_install = @import("doctor/post_install.zig");
const render = @import("doctor/render.zig");
pub const CheckStatus = render.CheckStatus;
pub const CheckStyle = render.CheckStyle;
pub const renderCheckRow = render.renderCheckRow;
pub const Finding = render.Finding;
pub const writeChecksJson = render.writeChecksJson;

/// Render a check row to stderr (via the pure renderer) and, when a
/// finding sink is active, capture the structured finding so
/// `mt doctor --json` serializes `checks[]` from the same call that drew
/// the human row — one source of truth for both views. Pub so tests can
/// drive the row path directly.
pub fn printCheck(name: []const u8, status: CheckStatus, detail: ?[]const u8) void {
    // Under --json the sink is active: capture the structured finding for
    // stdout and skip the human row, so the JSON document isn't mirrored
    // onto stderr. The human path (no sink) renders as before.
    if (g_sink) |sink| {
        recordFinding(sink, name, status, detail);
        return;
    }
    render.printCheck(name, status, detail);
}
/// Per-check outcome; same tags the row renderer uses so the walker
/// can tally without re-translating.
pub const CheckResult = render.CheckStatus;
const help = @import("help.zig");

/// Shared context passed to every check.
pub const CheckCtx = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    io: std.Io,
    environ: std.process.Environ,
    /// Mirror snapshot — drives the API-reachable probe host and the
    /// "Mirror overrides" row. Defaults to upstream so tests and
    /// `debug_ctx`-shaped fixtures keep working without plumbing.
    mirrors: mirror_mod.Mirrors = .{},
    /// `MALT_OFFLINE` / `--offline` snapshot. Drives the "Offline mode"
    /// row and short-circuits the API-reachable probe so an air-gapped
    /// machine doesn't get a warn row for an expected network gap.
    offline: bool = false,
};

/// One entry in the health walk. `run` prints its row(s) and returns
/// the walker's tally tag.
pub const Check = struct {
    name: []const u8,
    run: *const fn (ctx: CheckCtx, name: []const u8) CheckResult,
};

pub const Tally = struct {
    warnings: u32 = 0,
    errors: u32 = 0,
};

// Single source of truth for the health walk — append one entry to add
// a check. Exposed `pub` so tests can run the production walker against
// a scratch prefix without re-listing the table.
pub const checks = [_]Check{
    .{ .name = "MALT_PREFIX", .run = checkMaltPrefix },
    .{ .name = "SQLite integrity", .run = checkSqliteIntegrity },
    .{ .name = "Directory structure", .run = checkDirectoryStructure },
    .{ .name = "Stale lock", .run = checkStaleLock },
    .{ .name = patch.external_tool_name, .run = checkExternalTool },
    .{ .name = "APFS volume", .run = checkApfs },
    .{ .name = "Prefix permissions", .run = checkPrefixPermissions },
    .{ .name = "Prefix on PATH", .run = checkPrefixPath },
    .{ .name = "Mirror overrides", .run = checkMirrorOverrides },
    .{ .name = "Offline mode", .run = checkOfflineMode },
    .{ .name = "API reachable", .run = checkApiReachable },
    .{ .name = "Orphaned store entries", .run = checkOrphanedStore },
    .{ .name = "Missing kegs", .run = checkMissingKegs },
    .{ .name = "Broken symlinks", .run = checkBrokenSymlinks },
    .{ .name = "Mach-O placeholders", .run = checkMachOPlaceholders },
    .{ .name = "Disk space", .run = checkDiskSpace },
    .{ .name = "Local formula sources", .run = checkLocalSources },
    .{ .name = "Dependency bin/sbin link census", .run = checkIsolationLeaks },
    .{ .name = "SSL CA bundle", .run = checkSslCaBundle },
};

/// Walks the table and tallies warn/err contributions. Exposed so
/// tests can drive a fake table hermetically.
pub fn runChecks(ctx: CheckCtx, table: []const Check) Tally {
    var tally: Tally = .{};
    for (table) |c| {
        switch (c.run(ctx, c.name)) {
            .ok => {},
            .warn_status => tally.warnings += 1,
            .err_status => tally.errors += 1,
        }
    }
    return tally;
}

/// Collects structured findings during a health walk so
/// `mt doctor --json` can serialize `checks[]`. The arena owns every
/// string and the list backing, so a single `deinit` frees the lot.
const FindingSink = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(render.Finding),

    fn init(gpa: std.mem.Allocator) FindingSink {
        return .{ .arena = .init(gpa), .list = .empty };
    }
    fn deinit(self: *FindingSink) void {
        self.arena.deinit();
    }
};

/// Active finding sink, set only while `collectFindings` drives the
/// walk; null on the human path so `printCheck` stays render-only and
/// pays nothing. Process-global to mirror the existing hint flags —
/// doctor is never run concurrently.
var g_sink: ?*FindingSink = null;

fn recordFinding(sink: *FindingSink, name: []const u8, status: CheckStatus, detail: ?[]const u8) void {
    const a = sink.arena.allocator();
    // Best-effort: an allocator failure drops one finding from the JSON
    // payload rather than aborting the whole doctor run.
    const id = findingId(a, name) catch return;
    const title = a.dupe(u8, name) catch return;
    const det = a.dupe(u8, detail orelse "") catch return;
    sink.list.append(a, .{ .id = id, .severity = status, .title = title, .detail = det }) catch {};
}

/// Stable machine id for a finding: a slug of its title — lowercased,
/// each run of non-alphanumeric bytes collapsed to a single `_`, edges
/// trimmed. The title is static, so the id is stable across runs.
fn findingId(a: std.mem.Allocator, title: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    var pending_sep = false;
    for (title) |ch| {
        const lower = std.ascii.toLower(ch);
        if (std.ascii.isAlphanumeric(lower)) {
            if (pending_sep and buf.items.len != 0) try buf.append(a, '_');
            pending_sep = false;
            try buf.append(a, lower);
        } else {
            pending_sep = true;
        }
    }
    return buf.toOwnedSlice(a);
}

/// Outcome of a finding-collecting walk: the populated sink plus the
/// same warn/err tally `runChecks` returns. Caller owns the sink.
pub const WalkResult = struct {
    sink: FindingSink,
    tally: Tally,

    pub fn deinit(self: *WalkResult) void {
        self.sink.deinit();
    }
    pub fn findings(self: *const WalkResult) []const render.Finding {
        return self.sink.list.items;
    }
};

/// Run the health walk while capturing each row as a structured finding.
/// Drives the same `runChecks` walker — identical stderr rows — with a
/// sink active, so the human rows and `checks[]` share one source of
/// truth. `collect=false` skips capture entirely (the human path pays
/// nothing). Caller owns the returned sink.
pub fn collectFindings(
    allocator: std.mem.Allocator,
    ctx: CheckCtx,
    table: []const Check,
    collect: bool,
) WalkResult {
    var sink = FindingSink.init(allocator);
    if (collect) g_sink = &sink;
    defer g_sink = null;
    const tally = runChecks(ctx, table);
    return .{ .sink = sink, .tally = tally };
}

/// Walk retained cask versions and emit the human report doctor surfaces
/// after the check rows (optionally a verbose entry list). The `--json`
/// view of this data is emitted as one member of the merged document in
/// `emitDoctorJson`, so this path is human-only. Held public so the
/// integration test can drive the same path `execute` uses.
pub fn emitCaskHistoryReport(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) void {
    var census = cask_history.collectCensus(allocator, io, prefix);
    defer census.deinit(allocator);

    if (census.entries.len == 0) return;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    cask_history.writeHumanSummary(&aw.writer, census) catch return;
    if (output.isVerbose()) {
        // Best-effort: a writer error here loses the entry rows but
        // the summary line is already in `aw` and worth flushing.
        cask_history.writeHumanEntries(&aw.writer, census) catch {};
    }
    output.writeStderrAll(aw.written());
}

/// Walk `<prefix>/cache/Tap` and emit the warmed tap-archive size as a
/// human line, silent when the cache is empty so the clean case adds no
/// noise. The `--json` view is a member of the merged document built in
/// `emitDoctorJson`. Pure read; safe to invoke from `execute` post-checks.
pub fn emitTapCacheReport(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) void {
    const bytes = tap_cache_mod.bytesUnder(io, allocator, prefix);

    if (bytes == 0) return;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var size_buf: [32]u8 = undefined;
    const size = formatBytes(bytes, &size_buf);
    aw.writer.print("  > Tap archive cache: {s}. Run: mt purge --cache\n", .{size}) catch return;
    output.writeStderrAll(aw.written());
}

/// Emit the registered-tap forge/host block doctor shows after the
/// check rows. Every tap carries its host (github.com included) so a
/// user can confirm which forge a tap resolves against — the off-GitHub
/// hosts are where a wrong registration silently resolves elsewhere.
/// Empty list writes nothing, keeping the no-tap case quiet. Pure for
/// byte-pinning tests.
pub fn writeTapForgeHuman(w: *std.Io.Writer, taps: []const tap_mod.TapInfo) !void {
    if (taps.len == 0) return;
    try w.writeAll("  > Registered taps:\n");
    for (taps) |t| {
        try w.print("        {s} [{s}]\n", .{ t.name, t.host });
    }
}

/// `mt doctor --json` payload for the registered taps. The `taps` array
/// stays present (empty, not omitted) so scripted consumers can always
/// read it. Strings route through `output.jsonStr` for escaping. Pure
/// for byte-pinning tests.
pub fn writeTapForgeField(w: *std.Io.Writer, taps: []const tap_mod.TapInfo) !void {
    try w.writeAll("\"taps\":[");
    for (taps, 0..) |t, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, t.name);
        try w.writeAll(",\"host\":");
        try output.jsonStr(w, t.host);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// Standalone `{"taps":[...]}` document. Pure for byte-pinning tests;
/// wraps `writeTapForgeField`.
pub fn writeTapForgeJson(w: *std.Io.Writer, taps: []const tap_mod.TapInfo) !void {
    try w.writeAll("{");
    try writeTapForgeField(w, taps);
    try w.writeAll("}\n");
}

/// Read the registered taps from the prefix DB. Returns `null` on any
/// DB/list failure so a caller drops the taps report rather than failing
/// the whole doctor run. Free with `freeTaps`.
fn collectTaps(allocator: std.mem.Allocator, prefix: []const u8) ?[]tap_mod.TapInfo {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return null;
    var db = sqlite.Database.open(db_path) catch return null;
    defer db.close();
    schema.initSchema(&db) catch {};
    return tap_mod.list(allocator, &db) catch null;
}

fn freeTaps(allocator: std.mem.Allocator, taps: []tap_mod.TapInfo) void {
    for (taps) |t| {
        allocator.free(t.name);
        allocator.free(t.url);
        allocator.free(t.host);
        if (t.commit_sha) |sha| allocator.free(sha);
    }
    allocator.free(taps);
}

/// Emit the registered-tap forge/host block as human lines (silent when
/// no taps). The `--json` view is a member of the merged document built
/// in `emitDoctorJson`. Pure read; safe from `execute`'s post-check phase.
pub fn emitTapForgeReport(allocator: std.mem.Allocator, prefix: []const u8) void {
    const taps = collectTaps(allocator, prefix) orelse return;
    defer freeTaps(allocator, taps);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    writeTapForgeHuman(&aw.writer, taps) catch return;
    output.writeStderrAll(aw.written());
}

/// Compose the single versioned `mt doctor --json` document. Pure writer
/// (no IO/collection) so tests pin the exact bytes and confirm it parses
/// as one JSON object. The four data members are always present — empty
/// `checks`/`taps` arrays and zeroed `cask_history`/`tap_cache` rather
/// than omission — so consumers never special-case a missing key.
pub fn writeDoctorJson(
    w: *std.Io.Writer,
    findings: []const render.Finding,
    census: cask_history.Census,
    tap_cache_bytes: u64,
    taps: []const tap_mod.TapInfo,
) !void {
    try output.writeSchemaVersionPrefix(w);
    try render.writeChecksField(w, findings);
    try w.writeAll(",");
    try cask_history.writeField(w, census);
    try w.print(",\"tap_cache\":{{\"bytes\":{d}}}", .{tap_cache_bytes});
    try w.writeAll(",");
    try writeTapForgeField(w, taps);
    try w.writeAll("}\n");
}

/// Collect the three post-check data sources and emit them with the
/// checks as one merged `--json` document. Best-effort: a writer failure
/// drops the payload rather than aborting the run. Held public so the
/// integration tests can drive the same path `execute` uses under `--json`.
pub fn emitDoctorJson(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8, findings: []const render.Finding) void {
    var census = cask_history.collectCensus(allocator, io, prefix);
    defer census.deinit(allocator);
    const tap_cache_bytes = tap_cache_mod.bytesUnder(io, allocator, prefix);
    // Free the collected slice even when empty-but-allocated; only the
    // collection-failed (`null`) case substitutes a static empty slice.
    const taps_opt = collectTaps(allocator, prefix);
    defer if (taps_opt) |t| freeTaps(allocator, t);
    const taps: []const tap_mod.TapInfo = taps_opt orelse &.{};

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    writeDoctorJson(&aw.writer, findings, census, tap_cache_bytes, taps) catch return;
    output.writeStdoutAll(aw.written());
}

/// Local mirror of `cli/purge/util.zig::formatBytes` / the cask-history
/// formatter — doctor can't reach across the sibling-CLI boundary into
/// `cli/purge`, and the byte format must match what `purge --cache`
/// would surface so users see one number shape across both commands.
fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "doctor")) return;

    const prefix = atomic.maltPrefixOrAbort();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--post-install-status")) {
            post_install.checkPostInstallStatus(ctx, allocator, prefix);
            return;
        }
    }

    // Resolve the `--fix` selector up front so an unknown id fails fast
    // — before any check runs — and never reaches the mutating executor.
    const fix_req = fix_mod.parseFix(args);
    const fix_only: ?FixKind = switch (fix_req) {
        .none, .all => null,
        .one => |id| render.fixKindFromId(id) catch {
            output.err("unknown --fix id '{s}' (valid: {s})", .{ id, render.fix_ids_csv });
            std.process.exit(2);
        },
    };
    const fix_requested = fix_req.isRequested();

    resetVerboseHint();
    resetFixHint();
    // Capture findings only under --json; the human path stays render-only.
    const want_checks_json = output.isJson();
    // The progress line is human-only: --json keeps stderr silent.
    if (!want_checks_json) output.info("Running health checks...", .{});
    var walk = collectFindings(allocator, .{
        .allocator = allocator,
        .prefix = prefix,
        .io = ctx.io,
        .environ = ctx.environ,
        .mirrors = ctx.mirrors,
        .offline = ctx.offline,
    }, &checks, want_checks_json);
    defer walk.deinit();
    const tally = walk.tally;

    // `--json` is one merged, versioned document; the human view keeps the
    // three reports split so each renders in its own place after the rows.
    if (want_checks_json) {
        emitDoctorJson(allocator, ctx.io, prefix, walk.findings());
    } else {
        emitCaskHistoryReport(allocator, ctx.io, prefix);
        emitTapCacheReport(allocator, ctx.io, prefix);
        emitTapForgeReport(allocator, prefix);
    }

    if (fix_requested) {
        output.plain("", .{});
        const dry_run = output.isDryRun();
        if (dry_run) {
            output.info("Doctor fix plan (dry-run):", .{});
        } else {
            output.info("Applying safe-class fixes:", .{});
        }

        const outcome = fix_mod.executeFix(.{ .prefix = prefix, .io = ctx.io, .only = fix_only }, dry_run);

        if (outcome.plan.safe.count() == 0) {
            output.dim("no safe-class fixes to apply", .{});
        } else if (dry_run) {
            var it = outcome.plan.safe.iterator();
            while (it.next()) |kind| {
                output.dim("would {s}", .{fix_mod.safeLabel(kind)});
            }
        } else {
            if (outcome.stale_lock_removed) output.success("removed stale lock file", .{});
            if (outcome.broken_symlinks_removed > 0) {
                output.success("unlinked {d} broken symlink(s)", .{outcome.broken_symlinks_removed});
            }
            if (outcome.orphans_removed > 0) {
                output.success("swept {d} orphaned store entry(s)", .{outcome.orphans_removed});
            }
        }

        var mit = outcome.plan.manual.iterator();
        while (mit.next()) |kind| {
            output.warn("manual: {s}", .{fix_mod.manualHint(kind)});
        }
    }

    // The severity footer is the human view; --json carries each finding's
    // severity in the document itself. Suppress the stderr prints under
    // --json but keep the severity-based exit code — the TUI fix round-trip
    // depends on it.
    if (!want_checks_json) {
        output.plain("", .{});
        emitVerboseHintIfNeeded();
    }
    if (tally.errors > 0) {
        if (!want_checks_json) {
            output.err("{d} error(s), {d} warning(s)", .{ tally.errors, tally.warnings });
            emitFixHintIfNeeded(fix_requested);
        }
        std.process.exit(2);
    } else if (tally.warnings > 0) {
        if (!want_checks_json) {
            output.warn("{d} warning(s)", .{tally.warnings});
            emitFixHintIfNeeded(fix_requested);
        }
        std.process.exit(1);
    } else if (!want_checks_json) {
        output.success("Your malt installation is healthy", .{});
    }
}

/// Armed by any check that surfaces offenders the user could see
/// listed under `--verbose` (Mach-O placeholders, broken symlinks,
/// missing kegs, prefix-permissions). `execute` reads it after the
/// check loop to emit a dim "run with --verbose for the full list"
/// nudge. Reset by `resetVerboseHint` so re-entering the dispatcher
/// from tests starts clean.
var verbose_hint_armed: bool = false;

/// Test hook + production reset: clear the verbose-hint flag at the
/// top of every `execute` so a previous run on the same process
/// doesn't leak its state.
pub fn resetVerboseHint() void {
    verbose_hint_armed = false;
}

/// Internal arm — called by enumerable checks whenever they have
/// offenders, regardless of the verbose flag. `emitVerboseHintIfNeeded`
/// decides whether to surface the nudge.
fn armVerboseHint() void {
    verbose_hint_armed = true;
}

/// Emit a "run with --verbose for the full list" nudge after the
/// check loop when an enumerable check surfaced offenders AND
/// `--verbose` is off.
pub fn emitVerboseHintIfNeeded() void {
    if (output.isVerbose()) return;
    if (!verbose_hint_armed) return;
    output.dim("run with --verbose for the full list", .{});
}

/// Armed by any check that surfaces a condition `--fix` can act on
/// (stale lock with dead PID, orphan store entries, broken symlinks).
/// Manual-class issues do not arm: their inline rows already carry
/// the same remediation hint `--fix` would print, so the nudge would
/// be pure noise. `execute` reads it after the check loop to emit a
/// dim "run with --fix" suggestion.
var fix_hint_armed: bool = false;

/// Test hook + production reset: clear the fix-hint flag at the top
/// of every `execute` so a previous run on the same process doesn't
/// leak its state.
pub fn resetFixHint() void {
    fix_hint_armed = false;
}

/// Internal arm — called by checks that detect a safe-class
/// condition `--fix` can resolve. `emitFixHintIfNeeded` decides
/// whether to surface the nudge. `fix_class` is the safe-fix class the
/// offender belongs to; it also tags the just-rendered finding so
/// `mt doctor --json` reports the same `fixable`/`fix_class` the inline
/// nudge is driven by — one fixability signal for both views.
fn armFixHint(fix_class: FixKind) void {
    fix_hint_armed = true;
    if (g_sink) |sink| {
        if (sink.list.items.len != 0) {
            const last = &sink.list.items[sink.list.items.len - 1];
            last.fixable = true;
            last.fix_class = fix_class;
        }
    }
}

/// Emit a "run with --fix to apply safe-class fixes" nudge after the
/// check loop when a fixable condition was detected and `--fix` was
/// not already on the command line.
pub fn emitFixHintIfNeeded(fix_requested: bool) void {
    if (fix_requested) return;
    if (!fix_hint_armed) return;
    output.dim("run with --fix to apply safe-class fixes", .{});
}

/// Emit one dim/faint detail line indented under a check row, with a
/// `-` bullet so multiple rows read as a list. Routes through
/// `output.writeStderrAll` so doctor's stderr-capture tests see the
/// bytes; `std.debug.print` would bypass the capture buffer.
fn writeStyledDetail(text: []const u8) void {
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "    - {s}\n", .{text}) catch return;
    if (color.isColorEnabled()) {
        output.writeStderrAll(color.SemanticStyle.detail.code());
        output.writeStderrAll(line);
        output.writeStderrAll(color.Style.reset.code());
    } else {
        output.writeStderrAll(line);
    }
}

/// Stream the verbose-only entry list. Gated on `--verbose`; the
/// always-on first-3 hint lines (`checkPrefixPermissions`) call
/// `writeStyledDetail` directly so they share the styling without
/// the verbose gate.
fn writeVerboseList(entries: []const []const u8) void {
    if (!output.isVerbose()) return;
    for (entries) |e| writeStyledDetail(e);
}

fn freeOwnedStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
}

/// Extract the keg identifier (`<package> <version>`) from a
/// Cellar-relative file path of the form `<package>/<version>/<rest>`.
/// Returns null when the path has fewer than two slash-delimited
/// segments — those are walker artefacts we ignore here.
fn caskCellarKegKey(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const first_slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const rest = path[first_slash + 1 ..];
    const second_slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ path[0..first_slash], rest[0..second_slash] }) catch null;
}

// ── individual checks ────────────────────────────────────────────────
// `atomic.maltPrefixOrAbort()` validates the prefix upstream, so checks treat
// it as trusted.

fn checkMaltPrefix(ctx: CheckCtx, name: []const u8) CheckResult {
    const is_default = std.mem.eql(u8, ctx.prefix, "/opt/malt");
    var pbuf: [600]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &pbuf,
        "{s} {s}",
        .{ ctx.prefix, if (is_default) "(default)" else "(from MALT_PREFIX)" },
    ) catch ctx.prefix;
    printCheck(name, .ok, detail);
    return .ok;
}

fn checkSqliteIntegrity(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .err_status, "Prefix path too long");
        return .err_status;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .err_status, "Cannot open database");
        return .err_status;
    };
    defer db.close();

    // Schema is idempotent; the `PRAGMA integrity_check` below is the real probe.
    schema.initSchema(&db) catch {};

    var stmt = db.prepare("PRAGMA integrity_check;") catch {
        printCheck(name, .err_status, "Cannot run integrity check");
        return .err_status;
    };
    defer stmt.finalize();

    if (stmt.step() catch false) {
        if (stmt.columnText(0)) |r| {
            const txt = std.mem.sliceTo(r, 0);
            if (std.mem.eql(u8, txt, "ok")) {
                printCheck(name, .ok, null);
                return .ok;
            }
            printCheck(name, .err_status, "Database may be corrupt");
            return .err_status;
        }
    }
    // PRAGMA yielded no row — unreachable in practice; stay silent.
    return .ok;
}

fn checkDirectoryStructure(ctx: CheckCtx, name: []const u8) CheckResult {
    const dirs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "tmp", "cache", "db" };
    var first_missing_buf: [512]u8 = undefined;
    var first_missing_len: usize = 0;
    var missing: u32 = 0;
    for (dirs) |dir| {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ ctx.prefix, dir }) catch continue;
        std.Io.Dir.accessAbsolute(ctx.io, p, .{}) catch {
            if (first_missing_len == 0) {
                const s = std.fmt.bufPrint(&first_missing_buf, "{s}", .{p}) catch &[_]u8{};
                first_missing_len = s.len;
            }
            missing += 1;
        };
    }
    if (missing == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [640]u8 = undefined;
    const msg = if (missing == 1)
        std.fmt.bufPrint(&msg_buf, "Missing directory: {s}", .{first_missing_buf[0..first_missing_len]}) catch "Missing directory"
    else
        std.fmt.bufPrint(&msg_buf, "{d} missing directories (first: {s})", .{ missing, first_missing_buf[0..first_missing_len] }) catch "Missing directories";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

fn checkStaleLock(ctx: CheckCtx, name: []const u8) CheckResult {
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    const pid = lock_mod.LockFile.holderPid(ctx.io, lock_path);
    if (pid) |p| {
        const is_alive = std.c.kill(p, @enumFromInt(0)) == 0;
        var pid_buf: [256]u8 = undefined;
        if (is_alive) {
            const s = std.fmt.bufPrint(&pid_buf, "Lock held by active PID {d}", .{p}) catch "Lock held";
            printCheck(name, .warn_status, s);
        } else {
            const s = std.fmt.bufPrint(&pid_buf, "Stale lock from dead PID {d}. Run: rm {s}", .{ p, lock_path }) catch "Stale lock detected";
            printCheck(name, .warn_status, s);
            armFixHint(.stale_lock);
        }
        return .warn_status;
    }
    printCheck(name, .ok, null);
    return .ok;
}

fn checkExternalTool(ctx: CheckCtx, name: []const u8) CheckResult {
    // Row title is also the PATH binary to probe.
    if (externalToolAvailable(ctx.io, ctx.environ, name)) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var et_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &et_buf,
        "`{s}` not found on PATH. Install Xcode Command Line Tools: xcode-select --install",
        .{name},
    ) catch "External relocation tool missing. Install Xcode Command Line Tools.";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

fn checkApfs(ctx: CheckCtx, name: []const u8) CheckResult {
    if (clonefile.isApfs(ctx.prefix)) {
        printCheck(name, .ok, null);
        return .ok;
    }
    printCheck(name, .warn_status, "Not on APFS — clonefile unavailable");
    return .warn_status;
}

fn checkPrefixPermissions(ctx: CheckCtx, name: []const u8) CheckResult {
    // Cap the walk so pathological trees don't balloon doctor's memory.
    const findings = perms_mod.walkPrefix(
        ctx.io,
        ctx.allocator,
        ctx.prefix,
        perms_mod.currentUid(),
        32,
    ) catch {
        printCheck(name, .warn_status, "Walk failed");
        return .warn_status;
    };
    defer perms_mod.freeFindings(ctx.allocator, findings);

    if (findings.len == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var pm_buf: [256]u8 = undefined;
    const pm_msg = std.fmt.bufPrint(
        &pm_buf,
        "{d} path(s) with weak permissions under {s} — run `ls -l` or `chmod`",
        .{ findings.len, ctx.prefix },
    ) catch "Weak-permission paths under prefix";
    printCheck(name, .warn_status, pm_msg);
    armVerboseHint();
    // First few as a hint so the user knows where to look. Routes
    // through the shared styled-detail writer for parity with the
    // verbose lists below — capture-aware (so tests see the bytes)
    // and dim/faint on a tty.
    for (findings[0..@min(findings.len, 3)]) |f| {
        var line_buf: [1024]u8 = undefined;
        const reason = if (f.report.other_writable)
            "other-writable"
        else if (f.report.group_writable)
            "group-writable"
        else
            "wrong owner";
        const line = std.fmt.bufPrint(&line_buf, "{s} ({s})", .{ f.path, reason }) catch continue;
        writeStyledDetail(line);
    }
    return .warn_status;
}

/// Warn when the prefix's `bin` directory isn't on PATH — the common
/// cask-install symptom where `malt install`ed commands are "not found"
/// because nothing ever added `<prefix>/bin` to the user's shell.
fn checkPrefixPath(ctx: CheckCtx, name: []const u8) CheckResult {
    var bin_buf: [512]u8 = undefined;
    const bin = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    const path_env = std.process.Environ.getPosix(ctx.environ, "PATH") orelse "";
    if (pathContainsDir(path_env, bin)) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [640]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{s} is not on PATH — installed commands won't be found. Add: export PATH=\"{s}:$PATH\"",
        .{ bin, bin },
    ) catch "Prefix bin directory is not on PATH";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

/// Report offline-mode state so operators can confirm `MALT_OFFLINE` /
/// `--offline` landed correctly without re-grepping their shell config.
/// Always `.ok` — offline is a user choice, not a fault.
fn checkOfflineMode(ctx: CheckCtx, name: []const u8) CheckResult {
    printCheck(name, .ok, formatOfflineDetail(ctx.offline));
    return .ok;
}

/// Pure formatter for `checkOfflineMode`'s detail string. `pub` so the
/// doctor render test can pin the exact text without a process fixture.
pub fn formatOfflineDetail(offline: bool) []const u8 {
    return if (offline)
        "active — every fetch must serve from the snapshot cache"
    else
        "off";
}

fn checkApiReachable(ctx: CheckCtx, name: []const u8) CheckResult {
    // Offline mode flips the API-reachable check into a skip rather
    // than a warn: under offline there's no expectation of network
    // reachability, so a "Cannot reach" row would be noise.
    if (ctx.offline) {
        printCheck(name, .ok, "skipped — offline mode");
        return .ok;
    }
    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, ctx.allocator);
    defer http.deinit();
    const probe_url = mirror_mod.hostProbeUrl(ctx.mirrors.api_base);
    const status = http.head(probe_url) catch {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Cannot reach {s}", .{probe_url}) catch "Cannot reach API host";
        printCheck(name, .warn_status, msg);
        return .warn_status;
    };
    if (status >= 200 and status < 400) {
        printCheck(name, .ok, null);
        return .ok;
    }
    printCheck(name, .warn_status, "API returned error status");
    return .warn_status;
}

/// Report active corporate-mirror overrides so operators can confirm
/// `MALT_API_DOMAIN` / `MALT_BOTTLE_DOMAIN` (or the `HOMEBREW_*`
/// fallbacks) landed correctly. Emits the override URLs as the row
/// detail so the operator can eyeball the value without re-grepping
/// their shell config.
fn checkMirrorOverrides(ctx: CheckCtx, name: []const u8) CheckResult {
    if (!ctx.mirrors.api_overridden and !ctx.mirrors.bottle_overridden) {
        printCheck(name, .ok, "using upstream Homebrew defaults");
        return .ok;
    }
    var buf: [1024]u8 = undefined;
    const detail = formatMirrorOverrideDetail(&buf, ctx.mirrors);
    printCheck(name, .ok, detail);
    return .ok;
}

/// Pure formatter for `checkMirrorOverrides`'s detail string. `pub` so
/// the doctor render test can pin the exact text without a process
/// fixture.
pub fn formatMirrorOverrideDetail(buf: []u8, mirrors: mirror_mod.Mirrors) []const u8 {
    if (mirrors.api_overridden and mirrors.bottle_overridden) {
        return std.fmt.bufPrint(buf, "API={s}, Bottle={s}", .{ mirrors.api_base, mirrors.bottle_base }) catch
            "API + Bottle overrides active";
    }
    if (mirrors.api_overridden) {
        return std.fmt.bufPrint(buf, "API={s}", .{mirrors.api_base}) catch "API override active";
    }
    if (mirrors.bottle_overridden) {
        return std.fmt.bufPrint(buf, "Bottle={s}", .{mirrors.bottle_base}) catch "Bottle override active";
    }
    return "using upstream Homebrew defaults";
}

fn checkOrphanedStore(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer db.close();

    var store_path_buf: [512]u8 = undefined;
    const store_path = std.fmt.bufPrint(&store_path_buf, "{s}/store", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var store_dir = std.Io.Dir.openDirAbsolute(ctx.io, store_path, .{ .iterate = true }) catch {
        // store/ missing or unreadable — not an error, just skip.
        printCheck(name, .ok, null);
        return .ok;
    };
    defer store_dir.close(ctx.io);

    var orphan_count: u32 = 0;
    var iter = store_dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        // Each entry is a sha256 dir; classify via store_refs.
        var stmt = db.prepare(
            "SELECT refcount FROM store_refs WHERE store_sha256 = ?1;",
        ) catch continue;
        defer stmt.finalize();
        stmt.bindText(1, entry.name) catch continue;
        const has_row = stmt.step() catch false;
        if (has_row) {
            if (stmt.columnInt(0) <= 0) orphan_count += 1;
        } else {
            orphan_count += 1;
        }
    }

    if (orphan_count == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} orphaned store entry(s). Run: mt purge --store-orphans",
        .{orphan_count},
    ) catch "Orphaned store entries found. Run: mt purge --store-orphans";
    printCheck(name, .warn_status, msg);
    armFixHint(.orphaned_store);
    return .warn_status;
}

fn checkMissingKegs(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer db.close();

    var stmt = db.prepare("SELECT name, version, cellar_path FROM kegs;") catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer stmt.finalize();

    // Collect missing kegs so `--verbose` can name each one; under
    // default mode the list is just sized for the count.
    var offenders: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(ctx.allocator, &offenders);

    while (stmt.step() catch false) {
        const cellar_raw = stmt.columnText(2) orelse continue;
        const cellar_path = std.mem.sliceTo(cellar_raw, 0);
        std.Io.Dir.accessAbsolute(ctx.io, cellar_path, .{}) catch {
            const k_name = std.mem.sliceTo(stmt.columnText(0) orelse continue, 0);
            const k_ver = std.mem.sliceTo(stmt.columnText(1) orelse continue, 0);
            const row = std.fmt.allocPrint(ctx.allocator, "{s} {s}", .{ k_name, k_ver }) catch continue;
            offenders.append(ctx.allocator, row) catch {
                ctx.allocator.free(row);
                continue;
            };
        };
    }

    if (offenders.items.len == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} keg(s) in DB but missing on disk. Reinstall affected packages",
        .{offenders.items.len},
    ) catch "Missing keg directories detected. Reinstall affected packages";
    printCheck(name, .err_status, msg);
    armVerboseHint();
    writeVerboseList(offenders.items);
    return .err_status;
}

fn checkBrokenSymlinks(ctx: CheckCtx, name: []const u8) CheckResult {
    const link_dirs = [_][]const u8{ "bin", "lib", "include", "share", "sbin" };
    var offenders: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(ctx.allocator, &offenders);

    for (link_dirs) |subdir| {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ ctx.prefix, subdir }) catch continue;
        var dir = std.Io.Dir.openDirAbsolute(ctx.io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(ctx.io);

        var dir_iter = dir.iterate();
        while (dir_iter.next(ctx.io) catch null) |entry| {
            if (entry.kind == .sym_link) {
                _ = dir.statFile(ctx.io, entry.name, .{}) catch {
                    const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ subdir, entry.name }) catch continue;
                    offenders.append(ctx.allocator, path) catch {
                        ctx.allocator.free(path);
                        continue;
                    };
                    continue;
                };
            }
        }
    }

    if (offenders.items.len == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} broken symlink(s). Run: mt cleanup",
        .{offenders.items.len},
    ) catch "Broken symlinks found. Run: mt cleanup";
    printCheck(name, .warn_status, msg);
    armVerboseHint();
    armFixHint(.broken_symlinks);
    writeVerboseList(offenders.items);
    return .warn_status;
}

fn checkMachOPlaceholders(ctx: CheckCtx, name: []const u8) CheckResult {
    var cellar_root_buf: [512]u8 = undefined;
    const cellar_root = std.fmt.bufPrint(&cellar_root_buf, "{s}/Cellar", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };

    var cellar_dir = std.Io.Dir.openDirAbsolute(ctx.io, cellar_root, .{ .iterate = true }) catch {
        // No Cellar yet — nothing to scan.
        printCheck(name, .ok, null);
        return .ok;
    };
    defer cellar_dir.close(ctx.io);

    var walker = cellar_dir.walk(ctx.allocator) catch {
        printCheck(name, .warn_status, "Could not walk Cellar tree");
        return .warn_status;
    };
    defer walker.deinit();

    // Group by `<package> <version>` so the headline reports the
    // reinstall target — the user reinstalls the keg, not the file.
    // A single keg can bundle hundreds of placeholder-bearing files
    // (Python site-packages inside a meta-package, LLVM tools);
    // counting files there inflates the number without adding
    // actionable information.
    var groups: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        var it = groups.iterator();
        while (it.next()) |kv| ctx.allocator.free(kv.key_ptr.*);
        groups.deinit(ctx.allocator);
    }

    while (walker.next(ctx.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (hasUnpatchedPlaceholder(ctx.io, ctx.allocator, &cellar_dir, entry.path) catch false) {
            // Grouping is best-effort: an allocator failure here
            // drops the group entry, never silently triggers an
            // .ok outcome — the headline is still right because
            // it's derived from `groups.count()` which only grows
            // when the entry actually lands.
            const key = caskCellarKegKey(ctx.allocator, entry.path) orelse continue;
            const gop = groups.getOrPut(ctx.allocator, key) catch {
                ctx.allocator.free(key);
                continue;
            };
            if (gop.found_existing) ctx.allocator.free(key);
        }
    }

    if (groups.count() == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [512]u8 = undefined;
    const msg = blk: {
        if (output.isVerbose()) {
            // Verbose lists every package below; the (first: …) hint
            // would just duplicate the first row of that list.
            break :blk std.fmt.bufPrint(
                &msg_buf,
                "{d} package(s) ship Mach-O file(s) with unpatched @@HOMEBREW_* placeholders. Reinstall the affected packages.",
                .{groups.count()},
            ) catch "Mach-O files with unpatched @@HOMEBREW_* placeholders found.";
        }
        const first_key = first_key: {
            var it = groups.iterator();
            break :first_key if (it.next()) |kv| kv.key_ptr.* else "";
        };
        break :blk std.fmt.bufPrint(
            &msg_buf,
            "{d} package(s) ship Mach-O file(s) with unpatched @@HOMEBREW_* placeholders (first: {s}). Reinstall the affected packages.",
            .{ groups.count(), first_key },
        ) catch "Mach-O files with unpatched @@HOMEBREW_* placeholders found.";
    };
    printCheck(name, .err_status, msg);
    armVerboseHint();

    if (output.isVerbose()) {
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(ctx.allocator);
        var it = groups.iterator();
        while (it.next()) |kv| lines.append(ctx.allocator, kv.key_ptr.*) catch continue;
        writeVerboseList(lines.items);
    }
    return .err_status;
}

fn checkDiskSpace(ctx: CheckCtx, name: []const u8) CheckResult {
    const posix_path = std.posix.toPosixPath(ctx.prefix) catch {
        printCheck(name, .warn_status, "Cannot determine free disk space");
        return .warn_status;
    };
    var stat_buf: mount_c.struct_statfs = undefined;
    const rc = mount_c.statfs(&posix_path, &stat_buf);
    if (rc != 0) {
        printCheck(name, .warn_status, "Cannot determine free disk space");
        return .warn_status;
    }

    const free_bytes: u64 = @as(u64, @intCast(stat_buf.f_bavail)) * @as(u64, @intCast(stat_buf.f_bsize));
    const one_gb: u64 = 1024 * 1024 * 1024;
    if (free_bytes >= one_gb) {
        printCheck(name, .ok, null);
        return .ok;
    }
    const free_mb = free_bytes / (1024 * 1024);
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "Only {d} MB free (< 1 GB). Free up disk space",
        .{free_mb},
    ) catch "Low disk space (< 1 GB free)";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

/// Surface the dep-keg bin/sbin link census. Linked deps are the
/// default state, not a defect — the check stays at `.ok` severity so
/// `mt doctor` exits clean. Detail + enumeration only emit under
/// `--verbose` so default runs stay silent on this dimension and
/// downstream "grep for warnings" gates don't false-positive.
/// Detail line for the "SSL CA bundle" row. `null` when the bundle is
/// present (clean row); a short flag when it's missing. `pub` so the
/// render test can pin the text without a filesystem fixture.
pub fn formatSslCertDetail(present: bool) ?[]const u8 {
    return if (present)
        null
    else
        "ca-certificates installed but cert.pem isn't linked";
}

/// Check gated on its precondition: `<prefix>/etc/openssl@3/cert.pem` is
/// what OpenSSL reaches for at runtime, but it only exists once
/// `ca-certificates` is installed. A prefix that never installed it has no
/// bundle to verify — the absence is expected, not a defect — so the check
/// stays silent. When `ca-certificates` *is* installed but its bundle
/// isn't linked, that's a real misconfiguration: warn.
fn checkSslCaBundle(ctx: CheckCtx, name: []const u8) CheckResult {
    // Precondition: the `ca-certificates` opt link. Absent ⇒ nothing to
    // verify, so emit no row at all (default runs stay quiet on this).
    var opt_buf: [512]u8 = undefined;
    const opt = std.fmt.bufPrint(&opt_buf, "{s}/opt/ca-certificates", .{ctx.prefix}) catch return .ok;
    std.Io.Dir.cwd().access(ctx.io, opt, .{}) catch return .ok;

    var buf: [512]u8 = undefined;
    const cert = std.fmt.bufPrint(&buf, "{s}/etc/openssl@3/cert.pem", .{ctx.prefix}) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    const present = blk: {
        std.Io.Dir.cwd().access(ctx.io, cert, .{}) catch break :blk false;
        break :blk true;
    };
    const status: CheckStatus = if (present) .ok else .warn_status;
    printCheck(name, status, formatSslCertDetail(present));
    if (!present) {
        // Verbose-only remediation: the keg is on disk, so relink the
        // bundle by hand.
        var manual_buf: [768]u8 = undefined;
        const manual = std.fmt.bufPrint(
            &manual_buf,
            "ln -sf {s}/opt/ca-certificates/share/ca-certificates/cacert.pem {s}/etc/openssl@3/cert.pem",
            .{ ctx.prefix, ctx.prefix },
        ) catch "ln -sf <prefix>/opt/ca-certificates/share/ca-certificates/cacert.pem <prefix>/etc/openssl@3/cert.pem";
        writeVerboseList(&.{manual});
    }
    return status;
}

fn checkIsolationLeaks(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer db.close();

    if (!output.isVerbose()) {
        printCheck(name, .ok, null);
        return .ok;
    }

    var stmt = db.prepare(
        \\SELECT k.name
        \\FROM kegs k
        \\JOIN links l ON l.keg_id = k.id
        \\WHERE k.install_reason = 'dependency'
        \\  AND k.bin_isolated = 0
        \\  AND (l.link_path LIKE '%/bin/%' OR l.link_path LIKE '%/sbin/%')
        \\GROUP BY k.id
        \\ORDER BY k.name;
    ) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer stmt.finalize();

    var offenders: std.ArrayList([]u8) = .empty;
    defer freeOwnedStringList(ctx.allocator, &offenders);

    while (stmt.step() catch false) {
        const k_name = std.mem.sliceTo(stmt.columnText(0) orelse continue, 0);
        const row = std.fmt.allocPrint(
            ctx.allocator,
            "{s}   (mt link --isolate {s} to hide from PATH)",
            .{ k_name, k_name },
        ) catch continue;
        offenders.append(ctx.allocator, row) catch {
            ctx.allocator.free(row);
            continue;
        };
    }

    if (offenders.items.len == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d} dependency keg(s) link bin/sbin (use `mt link --isolate <name>` to hide).",
        .{offenders.items.len},
    ) catch "Dependency kegs are linked into bin/sbin.";
    printCheck(name, .ok, msg);
    writeVerboseList(offenders.items);
    return .ok;
}

fn checkLocalSources(ctx: CheckCtx, name: []const u8) CheckResult {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{ctx.prefix}, 0) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    var db = sqlite.Database.open(db_path) catch {
        printCheck(name, .ok, null);
        return .ok;
    };
    defer db.close();

    const missing = countMissingLocalSources(ctx.io, &db);
    if (missing.total == 0 or missing.stale == 0) {
        printCheck(name, .ok, null);
        return .ok;
    }
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "{d}/{d} local keg(s) reference a .rb that no longer exists on disk. Run `mt info <name>` to see which.",
        .{ missing.stale, missing.total },
    ) catch "Some local kegs reference a .rb that no longer exists.";
    printCheck(name, .warn_status, msg);
    return .warn_status;
}

/// True if `rel_path` inside `base_dir` is a Mach-O binary with at least one
/// load command that still contains `@@HOMEBREW_PREFIX@@` or
/// `@@HOMEBREW_CELLAR@@`. Any I/O or parser error is treated as "not bad" —
/// doctor's placeholder check is best-effort.
fn hasUnpatchedPlaceholder(
    io: std.Io,
    allocator: std.mem.Allocator,
    base_dir: *std.Io.Dir,
    rel_path: []const u8,
) !bool {
    var file = base_dir.openFile(io, rel_path, .{}) catch return false;
    defer file.close(io);

    var magic: [4]u8 = undefined;
    const n = file.readPositionalAll(io, &magic, 0) catch return false;
    if (n < 4) return false;
    if (!parser.isMachO(&magic)) return false;

    // Re-read the full file — parser needs the whole buffer.
    const stat = file.stat(io) catch return false;
    if (stat.size > 512 * 1024 * 1024) return false; // skip pathologically large files
    const data = allocator.alloc(u8, stat.size) catch return false;
    defer allocator.free(data);

    const read = file.readPositionalAll(io, data, 0) catch return false;
    if (read < data.len) return false;

    var macho = parser.parse(allocator, data) catch return false;
    defer macho.deinit();

    for (macho.paths) |lcp| {
        if (std.mem.indexOf(u8, lcp.path, "@@HOMEBREW_PREFIX@@") != null) return true;
        if (std.mem.indexOf(u8, lcp.path, "@@HOMEBREW_CELLAR@@") != null) return true;
    }
    return false;
}

/// True if `dir` appears as a complete, colon-separated entry in `path_env`.
/// Whole-entry match (not substring) so `/opt/malt/binary` never satisfies a
/// query for `/opt/malt/bin`; trailing slashes on either side are ignored.
/// `pub` so the membership logic is unit-tested without a fabricated environ.
pub fn pathContainsDir(path_env: []const u8, dir: []const u8) bool {
    const want = std.mem.trimEnd(u8, dir, "/");
    if (want.len == 0) return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, entry, "/"), want)) return true;
    }
    return false;
}

/// Fast existence check for a platform relocation tool on PATH.
/// Tries `/usr/bin/<tool>` first (where Xcode Command Line Tools land
/// install_name_tool) and then walks `PATH` entry-by-entry. `pub` so
/// the doctor render test can exercise both branches.
pub fn externalToolAvailable(io: std.Io, environ: std.process.Environ, tool: []const u8) bool {
    // Fast path for the common macOS case — avoids allocating a PATH
    // walk on every `mt doctor` invocation.
    var fast_buf: [64]u8 = undefined;
    const fast_path = std.fmt.bufPrint(&fast_buf, "/usr/bin/{s}", .{tool}) catch null;
    if (fast_path) |p| {
        if (std.Io.Dir.accessAbsolute(io, p, .{})) |_| return true else |_| {}
    }

    const path_env = std.process.Environ.getPosix(environ, "PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, tool }) catch continue;
        if (std.Io.Dir.accessAbsolute(io, full, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Summary of how many locally-installed kegs still point at their
/// original `.rb` source. `total` counts rows with `tap='local'`;
/// `stale` counts the subset whose `full_name` no longer exists on
/// disk. Keeping this pure (pass in the DB, no `output.*` calls) means
/// the check is exercisable from a hermetic unit test.
pub const LocalSourceCensus = struct {
    total: u32,
    stale: u32,
};

/// Walk `kegs WHERE tap='local'` and classify each row's recorded
/// source path as present or missing. Uses `accessAbsolute` (not a
/// full `openFile`) because we just need to know if the path resolves
/// — we are not reading the file. Silent on DB errors: a broken DB is
/// reported by the separate SQLite-integrity check above.
pub fn countMissingLocalSources(
    io: std.Io,
    db: *sqlite.Database,
) LocalSourceCensus {
    var census: LocalSourceCensus = .{ .total = 0, .stale = 0 };
    var stmt = db.prepare("SELECT full_name FROM kegs WHERE tap = 'local';") catch return census;
    defer stmt.finalize();
    while (stmt.step() catch false) {
        const path_ptr = stmt.columnText(0) orelse continue;
        const path = std.mem.sliceTo(path_ptr, 0);
        census.total += 1;
        std.Io.Dir.accessAbsolute(io, path, .{}) catch {
            census.stale += 1;
        };
    }
    return census;
}

// ── inline unit tests ───────────────────────────────────────────────
//
// Pure state-machine coverage for the fix-hint flag. Production walker
// coverage (which check arms the flag) lives in
// `tests/doctor_dispatch_test.zig` as integration; here we only pin
// the gating contract of the emit helper.

const testing = std.testing;

fn fixHintEmitted(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "safe-class fixes") != null;
}

fn captureFixEmit(allocator: std.mem.Allocator, fix_requested: bool) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    output.beginStderrCapture(allocator, &buf);
    defer output.endStderrCapture();
    emitFixHintIfNeeded(fix_requested);
    return buf;
}

test "findingId: slugifies a title into a stable lowercase id" {
    const cases = [_]struct { title: []const u8, id: []const u8 }{
        .{ .title = "MALT_PREFIX", .id = "malt_prefix" },
        .{ .title = "SQLite integrity", .id = "sqlite_integrity" },
        .{ .title = "Stale lock", .id = "stale_lock" },
        .{ .title = "Orphaned store entries", .id = "orphaned_store_entries" },
        .{ .title = "Mach-O placeholders", .id = "mach_o_placeholders" },
        .{ .title = "Dependency bin/sbin link census", .id = "dependency_bin_sbin_link_census" },
        .{ .title = "Prefix on PATH", .id = "prefix_on_path" },
    };
    for (cases) |c| {
        const got = try findingId(testing.allocator, c.title);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.id, got);
    }
}

test "findingId: collapses non-alphanumeric runs and trims the edges" {
    // Leading/trailing separators and repeated punctuation must never
    // leak doubled or edge underscores into the id.
    const got = try findingId(testing.allocator, "  A -- B/C  ");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a_b_c", got);
}

test "formatSslCertDetail: null when present, unlinked-bundle hint when absent" {
    try testing.expect(formatSslCertDetail(true) == null);
    const missing = formatSslCertDetail(false) orelse return error.TestUnexpectedResult;
    // The hint names the precondition (ca-certificates is installed) and
    // the actual fault (the bundle isn't linked) so a user can act on it.
    try testing.expect(std.mem.indexOf(u8, missing, "ca-certificates") != null);
    try testing.expect(std.mem.indexOf(u8, missing, "isn't linked") != null);
}

test "emitFixHintIfNeeded: silent without arming" {
    resetFixHint();
    var captured = try captureFixEmit(testing.allocator, false);
    defer captured.deinit(testing.allocator);
    try testing.expect(!fixHintEmitted(captured.items));
}

test "emitFixHintIfNeeded: emits when armed and --fix is off" {
    resetFixHint();
    armFixHint(.stale_lock);
    var captured = try captureFixEmit(testing.allocator, false);
    defer captured.deinit(testing.allocator);
    try testing.expect(fixHintEmitted(captured.items));
}

test "emitFixHintIfNeeded: silent when --fix was already passed" {
    resetFixHint();
    armFixHint(.stale_lock);
    var captured = try captureFixEmit(testing.allocator, true);
    defer captured.deinit(testing.allocator);
    try testing.expect(!fixHintEmitted(captured.items));
}

test "resetFixHint: clears a previously-armed flag" {
    resetFixHint();
    armFixHint(.stale_lock);
    resetFixHint();
    var captured = try captureFixEmit(testing.allocator, false);
    defer captured.deinit(testing.allocator);
    try testing.expect(!fixHintEmitted(captured.items));
}

test "emitTapCacheReport: silent on stderr when cache is empty" {
    // No `cache/Tap` entries → no extra line under the check rows.
    // A change that surfaced an "always-on" zero line would noise up
    // every clean run, so pin the silent shape.
    const allocator = testing.allocator;
    const ts = std.Io.Clock.real.now(std.Options.debug_io).toNanoseconds();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_doctor_tap_empty_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, prefix);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    output.beginStderrCapture(allocator, &buf);
    defer output.endStderrCapture();
    emitTapCacheReport(allocator, std.Options.debug_io, prefix);

    try testing.expectEqualStrings("", buf.items);
}

test "emitTapCacheReport: human one-liner when cache holds bytes" {
    const allocator = testing.allocator;
    const ts = std.Io.Clock.real.now(std.Options.debug_io).toNanoseconds();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&path_buf, "/tmp/malt_doctor_tap_full_{d}", .{ts});
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};

    var cache_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&cache_dir_buf, "{s}/cache/Tap", .{prefix});
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, cache_dir);

    var entry_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry = try std.fmt.bufPrint(&entry_buf, "{s}/{s}.tar.gz", .{ cache_dir, "ab" ** 32 });
    {
        const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, entry, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "x" ** 256);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    output.beginStderrCapture(allocator, &buf);
    defer output.endStderrCapture();
    emitTapCacheReport(allocator, std.Options.debug_io, prefix);

    try testing.expectEqualStrings(
        "  > Tap archive cache: 256.0 B. Run: mt purge --cache\n",
        buf.items,
    );
}

test "checks table includes the mirror-overrides row" {
    // Pins the wiring so a future shuffle of the static table can't
    // silently drop the operator's only signal that a mirror is active.
    var found = false;
    for (checks) |c| {
        if (std.mem.eql(u8, c.name, "Mirror overrides")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "pathContainsDir: matches a complete entry, ignores trailing slashes" {
    // The "Prefix on PATH" check is only correct if it matches whole PATH
    // entries — a substring match would falsely pass for `/opt/malt/binary`
    // when only `/opt/malt/bin` is wanted, hiding a broken PATH from the user.
    try testing.expect(pathContainsDir("/opt/malt/bin:/usr/bin", "/opt/malt/bin"));
    try testing.expect(pathContainsDir("/usr/bin:/opt/malt/bin", "/opt/malt/bin"));
    try testing.expect(pathContainsDir("/a:/opt/malt/bin:/b", "/opt/malt/bin"));
    // Trailing slash on either side must not defeat the match.
    try testing.expect(pathContainsDir("/opt/malt/bin/:/usr/bin", "/opt/malt/bin"));
    try testing.expect(pathContainsDir("/opt/malt/bin", "/opt/malt/bin/"));
}

test "pathContainsDir: rejects substrings, missing entries, and empties" {
    try testing.expect(!pathContainsDir("/opt/malt/binary:/usr/bin", "/opt/malt/bin"));
    try testing.expect(!pathContainsDir("/usr/bin:/usr/local/bin", "/opt/malt/bin"));
    try testing.expect(!pathContainsDir("", "/opt/malt/bin"));
    try testing.expect(!pathContainsDir("::", "/opt/malt/bin"));
    // A degenerate prefix must never match an empty PATH entry.
    try testing.expect(!pathContainsDir("/usr/bin::/bin", "/"));
}

test "checks table includes the prefix-on-PATH row" {
    // Pins the onboarding signal: without this row a cask user whose
    // /opt/malt/bin isn't exported gets no hint why installed commands
    // are "not found".
    var found = false;
    for (checks) |c| {
        if (std.mem.eql(u8, c.name, "Prefix on PATH")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "writeDoctorJson merges all four members under one versioned root" {
    const findings = [_]render.Finding{
        .{ .id = "stale_lock", .severity = .warn_status, .title = "Stale lock", .detail = "d", .fixable = true, .fix_class = .stale_lock },
    };
    const census: cask_history.Census = .{ .entries = &.{}, .total_bytes = 42 };
    const taps = [_]tap_mod.TapInfo{
        .{ .name = "u/r", .url = "", .host = "gitlab.com", .commit_sha = null },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeDoctorJson(&aw.writer, &findings, census, 7, &taps);

    try testing.expectEqualStrings(
        "{\"schema_version\":1," ++
            "\"checks\":[{\"id\":\"stale_lock\",\"severity\":\"warn\",\"title\":\"Stale lock\",\"detail\":\"d\",\"fixable\":true,\"fix_class\":\"stale_lock\"}]," ++
            "\"cask_history\":{\"retained_versions\":0,\"bytes\":42}," ++
            "\"tap_cache\":{\"bytes\":7}," ++
            "\"taps\":[{\"name\":\"u/r\",\"host\":\"gitlab.com\"}]}\n",
        aw.written(),
    );
}

test "writeDoctorJson stays one valid JSON object with schema_version on the empty case" {
    // The merged doc must parse as a single object (the old multi-document
    // concatenation did not) and carry the version even with nothing found.
    const census: cask_history.Census = .{ .entries = &.{}, .total_bytes = 0 };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeDoctorJson(&aw.writer, &.{}, census, 0, &.{});

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("checks").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("taps").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("tap_cache").?.object.get("bytes").?.integer);
}
