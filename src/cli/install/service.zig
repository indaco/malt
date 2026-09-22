//! Bridge from a formula's `service` block to the launchd `ServiceSpec`
//! the supervisor registers. Shared by install and upgrade so both paths
//! render the plist from the same definition.

const std = @import("std");

const cron = @import("../../core/services/cron.zig");
const formula_mod = @import("../../core/formula.zig");
const plist_mod = @import("../../core/services/plist.zig");
const supervisor_mod = @import("../../core/services/supervisor.zig");
const sqlite = @import("../../db/sqlite.zig");
const path_component = @import("../../fs/path_component.zig");
const rb_parse = @import("rb_parse.zig");
const sink_mod = @import("sink.zig");

const testing = std.testing;

/// Pure def -> spec mapping. Every string the spec points at is owned by
/// `aa`, so callers scope it to an arena that outlives `register`.
pub fn specFromDef(
    aa: std.mem.Allocator,
    def: formula_mod.ServiceDef,
    name: []const u8,
    prefix: []const u8,
) !plist_mod.ServiceSpec {
    // The Homebrew API renders service paths as `$HOMEBREW_PREFIX/...`;
    // launchd does not expand the token and the validator rejects it.
    const run = try aa.alloc([]const u8, def.run.len);
    for (def.run, 0..) |arg, i| run[i] = try plist_mod.expandPrefix(aa, arg, prefix);

    return .{
        .label = try std.fmt.allocPrint(aa, "com.malt.{s}", .{name}),
        .program_args = run,
        .working_dir = if (def.working_dir) |wd| try plist_mod.expandPrefix(aa, wd, prefix) else null,
        .stdout_path = if (def.log_path) |lp|
            try plist_mod.expandPrefix(aa, lp, prefix)
        else
            try std.fmt.allocPrint(aa, "{s}/var/log/{s}.out", .{ prefix, name }),
        .stderr_path = if (def.error_log_path) |elp|
            try plist_mod.expandPrefix(aa, elp, prefix)
        else
            try std.fmt.allocPrint(aa, "{s}/var/log/{s}.err", .{ prefix, name }),
        .schedule = def.schedule,
        .keep_alive = def.keep_alive,
        .stop_timeout = def.stop_timeout,
    };
}

/// Register (or re-register) the launchd service a formula's `service:`
/// block declares; without one, retire whatever a previous version
/// registered. Best-effort: failures warn but never fail the install or
/// upgrade that called it.
pub fn register(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    prefix: []const u8,
    sink: sink_mod.OutputSink,
) void {
    const def = formula.service orelse {
        // A refused block is still a declared service; only an absent
        // block retires the previous version's registration.
        const refusal = formula.service_refusal orelse return retireDropped(io, allocator, db, formula.name, formula.pkg_version, sink);
        // Core carries a bare tag so the wording stays in cli; map it
        // onto the Ruby parser's error set to share that wording.
        const reason = rb_parse.serviceRefusalReason(switch (refusal) {
            .ships_plist => error.ShipsOwnPlist,
            .unsupported => error.Unsupported,
        });
        sink.warn("could not register service for {s}: {s}", .{ formula.name, reason });
        warnKeptRow(db, formula.name, formula.pkg_version, sink);
        return;
    };
    registerDef(io, allocator, db, def, formula.name, formula.pkg_version, prefix, sink);
}

/// Without this the user would read the refusal as "no service" while
/// the old row lives on.
fn warnKeptRow(db: *sqlite.Database, name: []const u8, pkg_version: []const u8, sink: sink_mod.OutputSink) void {
    if (hasKegService(db, name)) sink.warn("{s} {s}: kept the service registration from the previous version", .{ name, pkg_version });
}

/// A dropped block leaves the previous version's row behind, and nothing
/// but uninstall would ever remove it.
fn retireDropped(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    pkg_version: []const u8,
    sink: sink_mod.OutputSink,
) void {
    if (!hasKegService(db, name)) return;
    const label = std.fmt.allocPrint(allocator, "com.malt.{s}", .{name}) catch return;
    defer allocator.free(label);
    applyDropped(io, allocator, db, name, pkg_version, label, supervisor_mod.probeRuntime(io, allocator, label), sink);
}

/// Keyed on the keg only: `supervisor.hasService` also matches the label,
/// which a formula name can spell.
fn hasKegService(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT 1 FROM services WHERE keg_name = ?;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

/// Takes the probed state as a value so every arm is testable without
/// launchctl. Loaded or unknown keeps the row so `mt services stop` can
/// still bootout the job. Retry advice names `mt reinstall`: an upgrade
/// stops at "already current" before it would reach here again.
fn applyDropped(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    pkg_version: []const u8,
    label: []const u8,
    state: ?supervisor_mod.RuntimeState,
    sink: sink_mod.OutputSink,
) void {
    switch (state orelse {
        sink.warn(
            "{s} {s} declares no service; could not ask launchd about the previous version's job, kept its registration - 'mt reinstall {s}' retries",
            .{ name, pkg_version, name },
        );
        return;
    }) {
        .not_loaded => {
            deleteKegService(db, name) catch {
                sink.warn("could not retire the previous version's service registration for {s}", .{name});
                return;
            };
            supervisor_mod.removeServiceDir(.{ .allocator = allocator, .io = io, .db = db }, label);
            sink.info("{s} {s} declares no service; retired the registration from the previous version", .{ name, pkg_version });
        },
        .loaded, .running, .errored => sink.warn(
            "{s} {s} declares no service; the job from the previous version is still loaded - run 'mt services stop {s}' then 'mt reinstall {s}' to retire it",
            .{ name, pkg_version, name, name },
        ),
    }
}

fn deleteKegService(db: *sqlite.Database, name: []const u8) !void {
    var stmt = try db.prepare("DELETE FROM services WHERE keg_name = ?;");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    _ = try stmt.step();
}

/// The Ruby-DSL twin of `register`: a tap or `--local` formula's textual
/// `service do` block. A block malt cannot translate warns and is dropped;
/// the keg is already committed, so the install still succeeds. `declared`
/// tells a block the parser refused (already warned about) from no block.
pub fn registerRuby(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    block: ?rb_parse.RubyServiceBlock,
    declared: bool,
    name: []const u8,
    pkg_version: []const u8,
    prefix: []const u8,
    sink: sink_mod.OutputSink,
) void {
    const b = block orelse {
        if (!declared) return retireDropped(io, allocator, db, name, pkg_version, sink);
        // The parse site already said why the block was refused.
        warnKeptRow(db, name, pkg_version, sink);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const def = defFromRuby(arena.allocator(), b, name, pkg_version) orelse {
        sink.warn("could not register service for {s}: unsupported service block", .{name});
        return;
    };
    registerDef(io, allocator, db, def, name, pkg_version, prefix, sink);
}

fn registerDef(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    def: formula_mod.ServiceDef,
    name: []const u8,
    pkg_version: []const u8,
    prefix: []const u8,
    sink: sink_mod.OutputSink,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const spec = specFromDef(aa, def, name, prefix) catch return;

    // launchd creates the log files on first run; a missing dir surfaces there.
    const log_dir = std.fmt.allocPrint(aa, "{s}/var/log", .{prefix}) catch return;
    std.Io.Dir.cwd().createDirPath(io, log_dir) catch {};

    const cellar_path = std.fmt.allocPrint(aa, "{s}/Cellar/{s}/{s}", .{ prefix, name, pkg_version }) catch return;

    supervisor_mod.register(.{ .allocator = allocator, .io = io, .db = db }, spec, name, false, cellar_path, prefix) catch |err| {
        sink.warn("could not register service for {s}: {s}", .{ name, @errorName(err) });
        return;
    };

    // launchd keeps a loaded job's configuration until bootout, so a
    // rewritten plist only takes effect on restart. Never restart here: an
    // upgrade must not kill a daemon the user did not ask to stop.
    switch (supervisor_mod.queryRuntime(io, allocator, spec.label)) {
        .loaded, .running, .errored => sink.warn("{s} service re-registered; run 'mt services restart {s}' to apply it", .{ name, name }),
        .not_loaded => {},
    }
}

/// Where a Ruby path token is rooted. Keg-relative roots are spelled out as
/// the Cellar leaf because `expandPrefix` only knows `$HOMEBREW_PREFIX`.
const RubyRoot = enum { opt_bin, opt_sbin, opt_libexec, opt_prefix, bin, sbin, libexec, prefix, @"var", etc, homebrew_prefix };

const ruby_roots = std.StaticStringMap(RubyRoot).initComptime(.{
    .{ "opt_bin", .opt_bin },
    .{ "opt_sbin", .opt_sbin },
    .{ "opt_libexec", .opt_libexec },
    .{ "opt_prefix", .opt_prefix },
    .{ "bin", .bin },
    .{ "sbin", .sbin },
    .{ "libexec", .libexec },
    .{ "prefix", .prefix },
    .{ "var", .@"var" },
    .{ "etc", .etc },
    .{ "HOMEBREW_PREFIX", .homebrew_prefix },
});

/// Translate a textual `service do` block into the `ServiceDef` the API
/// path produces, so both share `specFromDef` and `validate`. Null when any
/// token is a shape malt cannot render (`#{...}`, `Dir.home`, a method
/// call) or the schedule is out of bounds - the API side fails those the
/// same way, and a half-translated argv must never reach launchd.
pub fn defFromRuby(
    aa: std.mem.Allocator,
    block: rb_parse.RubyServiceBlock,
    name: []const u8,
    pkg_version: []const u8,
) ?formula_mod.ServiceDef {
    const run = aa.alloc([]const u8, block.run.len) catch return null;
    for (block.run, 0..) |tok, i| run[i] = rubyPath(aa, tok, name, pkg_version) orelse return null;

    return .{
        .run = run,
        .working_dir = if (block.working_dir) |t| rubyPath(aa, t, name, pkg_version) orelse return null else null,
        .log_path = if (block.log_path) |t| rubyPath(aa, t, name, pkg_version) orelse return null else null,
        .error_log_path = if (block.error_log_path) |t| rubyPath(aa, t, name, pkg_version) orelse return null else null,
        .keep_alive = block.keep_alive,
        .schedule = switch (block.run_type) {
            .immediate => .immediate,
            .interval => blk: {
                const secs = block.interval orelse return null;
                if (secs < 1 or secs > plist_mod.max_interval_secs) return null;
                break :blk .{ .interval = secs };
            },
            .cron => .{ .calendar = cron.parseCron(aa, block.cron orelse return null) catch return null },
        },
    };
}

/// One Ruby token -> a `$HOMEBREW_PREFIX`-rooted path or a bare literal.
/// Accepted shapes: `"literal"`, `<root>`, `<root>/"leaf"`, and
/// `Formula["dep"].<root>/"leaf"` with an opt root.
fn rubyPath(aa: std.mem.Allocator, tok: []const u8, name: []const u8, pkg_version: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, tok, "#{") != null) return null;
    if (tok.len >= 2 and tok[0] == '"' and tok[tok.len - 1] == '"') return tok[1 .. tok.len - 1];

    var owner = name;
    var rest = tok;
    if (std.mem.startsWith(u8, rest, "Formula[\"")) {
        const dep, const after = std.mem.cut(u8, rest["Formula[\"".len..], "\"].") orelse return null;
        if (!path_component.isPathComponent(dep)) return null;
        owner = dep;
        rest = after;
    }
    const root_tok, const leaf = std.mem.cut(u8, rest, "/\"") orelse .{ rest, null };
    const root = ruby_roots.get(root_tok) orelse return null;
    // `Formula["dep"].bin` would point into another keg's Cellar leaf, whose
    // version this formula cannot know.
    if (owner.ptr != name.ptr) switch (root) {
        .opt_bin, .opt_sbin, .opt_libexec, .opt_prefix => {},
        else => return null,
    };
    const base: []const u8 = switch (root) {
        .opt_bin => std.fmt.allocPrint(aa, "$HOMEBREW_PREFIX/opt/{s}/bin", .{owner}),
        .opt_sbin => std.fmt.allocPrint(aa, "$HOMEBREW_PREFIX/opt/{s}/sbin", .{owner}),
        .opt_libexec => std.fmt.allocPrint(aa, "$HOMEBREW_PREFIX/opt/{s}/libexec", .{owner}),
        .opt_prefix => std.fmt.allocPrint(aa, "$HOMEBREW_PREFIX/opt/{s}", .{owner}),
        .bin => std.fmt.allocPrint(aa, "$HOMEBREW_PREFIX/Cellar/{s}/{s}/bin", .{ name, pkg_version }),
        .sbin => std.fmt.allocPrint(aa, "$HOMEBREW_PREFIX/Cellar/{s}/{s}/sbin", .{ name, pkg_version }),
        .libexec => std.fmt.allocPrint(aa, "$HOMEBREW_PREFIX/Cellar/{s}/{s}/libexec", .{ name, pkg_version }),
        .prefix => std.fmt.allocPrint(aa, "$HOMEBREW_PREFIX/Cellar/{s}/{s}", .{ name, pkg_version }),
        .@"var" => aa.dupe(u8, "$HOMEBREW_PREFIX/var"),
        .etc => aa.dupe(u8, "$HOMEBREW_PREFIX/etc"),
        .homebrew_prefix => aa.dupe(u8, "$HOMEBREW_PREFIX"),
    } catch return null;
    const quoted = leaf orelse return base;
    if (quoted.len == 0 or quoted[quoted.len - 1] != '"') return null;
    const sub = quoted[0 .. quoted.len - 1];
    // A second `"` means a chained `/"a"/"b"` leaf; pasting it verbatim would
    // put quotes into the rendered path.
    if (std.mem.indexOfScalar(u8, sub, '"') != null) return null;
    return std.fmt.allocPrint(aa, "{s}/{s}", .{ base, sub }) catch null;
}

test "specFromDef expands the Homebrew prefix token in every path field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def: formula_mod.ServiceDef = .{
        .run = &.{ "$HOMEBREW_PREFIX/opt/redis/bin/redis-server", "--daemonize", "no" },
        .working_dir = "$HOMEBREW_PREFIX/var",
        .log_path = "$HOMEBREW_PREFIX/var/log/redis.log",
        .error_log_path = "$HOMEBREW_PREFIX/var/log/redis.err",
    };
    const spec = try specFromDef(arena.allocator(), def, "redis", "/opt/malt");
    try testing.expectEqualStrings("com.malt.redis", spec.label);
    try testing.expectEqual(@as(usize, 3), spec.program_args.len);
    try testing.expectEqualStrings("/opt/malt/opt/redis/bin/redis-server", spec.program_args[0]);
    try testing.expectEqualStrings("no", spec.program_args[2]);
    try testing.expectEqualStrings("/opt/malt/var", spec.working_dir.?);
    try testing.expectEqualStrings("/opt/malt/var/log/redis.log", spec.stdout_path);
    try testing.expectEqualStrings("/opt/malt/var/log/redis.err", spec.stderr_path);
}

test "specFromDef defaults the log paths under var/log and leaves working_dir unset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def: formula_mod.ServiceDef = .{ .run = &.{"/bin/true"} };
    const spec = try specFromDef(arena.allocator(), def, "dnsmasq", "/opt/malt");
    try testing.expectEqualStrings("/opt/malt/var/log/dnsmasq.out", spec.stdout_path);
    try testing.expectEqualStrings("/opt/malt/var/log/dnsmasq.err", spec.stderr_path);
    try testing.expect(spec.working_dir == null);
}

test "specFromDef copies keep_alive, schedule and stop_timeout through unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def: formula_mod.ServiceDef = .{
        .run = &.{"/bin/true"},
        .keep_alive = false,
        .schedule = .{ .interval = 300 },
        .stop_timeout = 45,
    };
    const spec = try specFromDef(arena.allocator(), def, "x", "/opt/malt");
    try testing.expect(!spec.keep_alive);
    try testing.expectEqual(@as(u32, 300), spec.schedule.interval);
    try testing.expectEqual(@as(?u32, 45), spec.stop_timeout);

    const plain: formula_mod.ServiceDef = .{ .run = &.{"/bin/true"} };
    const plain_spec = try specFromDef(arena.allocator(), plain, "x", "/opt/malt");
    try testing.expect(plain_spec.keep_alive);
    try testing.expect(plain_spec.schedule == .immediate);
    try testing.expect(plain_spec.stop_timeout == null);
}

test "defFromRuby translates opt_bin, literal and var tokens into the prefix vocabulary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const block: rb_parse.RubyServiceBlock = .{
        .run = &.{ "opt_bin/\"svcd\"", "\"--foreground\"", "var/\"svcd/data\"" },
        .working_dir = "var",
        .log_path = "var/\"log/svcd.log\"",
        .error_log_path = "var/\"log/svcd.err\"",
        .keep_alive = false,
    };
    const def = defFromRuby(arena.allocator(), block, "svcd", "1.0") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(usize, 3), def.run.len);
    try testing.expectEqualStrings("$HOMEBREW_PREFIX/opt/svcd/bin/svcd", def.run[0]);
    try testing.expectEqualStrings("--foreground", def.run[1]);
    try testing.expectEqualStrings("$HOMEBREW_PREFIX/var/svcd/data", def.run[2]);
    try testing.expectEqualStrings("$HOMEBREW_PREFIX/var", def.working_dir.?);
    try testing.expectEqualStrings("$HOMEBREW_PREFIX/var/log/svcd.log", def.log_path.?);
    try testing.expectEqualStrings("$HOMEBREW_PREFIX/var/log/svcd.err", def.error_log_path.?);
    try testing.expect(!def.keep_alive);
    try testing.expect(def.schedule == .immediate);
}

test "defFromRuby renders keg-relative tokens under the Cellar leaf and opt tokens under opt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const cases = [_]struct { tok: []const u8, want: []const u8 }{
        .{ .tok = "bin/\"x\"", .want = "$HOMEBREW_PREFIX/Cellar/foo/1.2_1/bin/x" },
        .{ .tok = "sbin/\"x\"", .want = "$HOMEBREW_PREFIX/Cellar/foo/1.2_1/sbin/x" },
        .{ .tok = "libexec/\"x\"", .want = "$HOMEBREW_PREFIX/Cellar/foo/1.2_1/libexec/x" },
        .{ .tok = "prefix/\"x\"", .want = "$HOMEBREW_PREFIX/Cellar/foo/1.2_1/x" },
        .{ .tok = "opt_sbin/\"x\"", .want = "$HOMEBREW_PREFIX/opt/foo/sbin/x" },
        .{ .tok = "opt_libexec/\"x\"", .want = "$HOMEBREW_PREFIX/opt/foo/libexec/x" },
        .{ .tok = "opt_prefix/\"x\"", .want = "$HOMEBREW_PREFIX/opt/foo/x" },
        .{ .tok = "etc/\"foo.conf\"", .want = "$HOMEBREW_PREFIX/etc/foo.conf" },
        .{ .tok = "HOMEBREW_PREFIX/\"x\"", .want = "$HOMEBREW_PREFIX/x" },
        .{ .tok = "HOMEBREW_PREFIX", .want = "$HOMEBREW_PREFIX" },
        .{ .tok = "Formula[\"node\"].opt_bin/\"node\"", .want = "$HOMEBREW_PREFIX/opt/node/bin/node" },
    };
    for (cases) |case| {
        const def = defFromRuby(aa, .{ .run = &.{case.tok} }, "foo", "1.2_1") orelse return error.TestUnexpectedNull;
        try testing.expectEqualStrings(case.want, def.run[0]);
    }
}

test "defFromRuby drops the service on a token shape it cannot render" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try testing.expect(defFromRuby(aa, .{ .run = &.{"\"#{opt_bin}/x\""} }, "foo", "1.0") == null);
    try testing.expect(defFromRuby(aa, .{ .run = &.{ "opt_bin/\"x\"", "Dir.home" } }, "foo", "1.0") == null);
    try testing.expect(defFromRuby(aa, .{ .run = &.{"opt_bin/\"x\""}, .log_path = "Dir.home" }, "foo", "1.0") == null);
}

test "defFromRuby maps run_type to a bounded schedule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const run: []const []const u8 = &.{"opt_bin/\"x\""};

    const iv = defFromRuby(aa, .{ .run = run, .run_type = .interval, .interval = 300 }, "foo", "1.0") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u32, 300), iv.schedule.interval);

    try testing.expect(defFromRuby(aa, .{ .run = run, .run_type = .interval, .interval = 0 }, "foo", "1.0") == null);
    try testing.expect(defFromRuby(aa, .{ .run = run, .run_type = .interval, .interval = plist_mod.max_interval_secs + 1 }, "foo", "1.0") == null);
    try testing.expect(defFromRuby(aa, .{ .run = run, .run_type = .interval }, "foo", "1.0") == null);

    const cr = defFromRuby(aa, .{ .run = run, .run_type = .cron, .cron = "0 4 * * *" }, "foo", "1.0") orelse return error.TestUnexpectedNull;
    try testing.expect(cr.schedule == .calendar);
    try testing.expectEqual(@as(?u8, 4), cr.schedule.calendar[0].hour);
    try testing.expect(defFromRuby(aa, .{ .run = run, .run_type = .cron, .cron = "not a cron" }, "foo", "1.0") == null);
    try testing.expect(defFromRuby(aa, .{ .run = run, .run_type = .cron }, "foo", "1.0") == null);
}

test "defFromRuby refuses a chained leaf whose quotes would land in the plist" {
    // `var/"log"/"x.log"` is legal Ruby, but pasting past the first `/"` would
    // write `var/log"/"x.log` into a path launchd then fails to open.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try testing.expect(defFromRuby(aa, .{ .run = &.{"opt_bin/\"x\""}, .log_path = "var/\"log\"/\"x.log\"" }, "foo", "1.0") == null);
    try testing.expect(defFromRuby(aa, .{ .run = &.{"opt_bin/\"a\"/\"b\""} }, "foo", "1.0") == null);
}

test "defFromRuby refuses a dependency reference that is not a plain formula name" {
    // The name becomes an `opt/<dep>` component; traversal in the rendered
    // path is `validate`'s job, but a slash here is simply not a formula.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try testing.expect(defFromRuby(aa, .{ .run = &.{"Formula[\"../..\"].opt_bin/\"evil\""} }, "foo", "1.0") == null);
    try testing.expect(defFromRuby(aa, .{ .run = &.{"Formula[\"a/b\"].opt_bin/\"x\""} }, "foo", "1.0") == null);
}

const atomic = @import("../../fs/atomic.zig");
const schema = @import("../../db/schema.zig");
const output = @import("../../ui/output.zig");

const dropped_json =
    \\{"name":"tree","full_name":"tree","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"2.2.1"},"dependencies":[]}
;

fn seedDroppedRow(db: *sqlite.Database) !void {
    try db.exec(
        \\INSERT INTO services (name, keg_name, plist_path, auto_start, last_status)
        \\VALUES ('com.malt.tree', 'tree', '/p/var/malt/services/com.malt.tree/service.plist', 0, 'registered');
    );
}

var prefix_seq: std.atomic.Value(u32) = .init(0);

/// A private prefix per call: the suite may run without the harness prefix
/// (the real `/opt/malt` is the fallback) or as several concurrent copies.
fn scratchPrefix() ![:0]const u8 {
    return std.fmt.allocPrintSentinel(testing.allocator, "/tmp/malt_retire_{d}_{d}", .{ std.c.getpid(), prefix_seq.fetchAdd(1, .monotonic) }, 0);
}

test "applyDropped retires the previous version's row when no job is loaded" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, dropped_json);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    const label = "com.malt.tree";
    const dir = try supervisor_mod.serviceDir(testing.allocator, label);
    defer testing.allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);

    applyDropped(std.Options.debug_io, testing.allocator, &db, "tree", "2.2.1", label, .not_loaded, sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.Options.debug_io, dir, .{}));
    try testing.expect(std.mem.indexOf(u8, buf.items, "declares no service") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "retired") != null);
}

test "applyDropped keeps the row when launchd could not be asked" {
    // A row deleted while its job is still loaded orphans a daemon nothing
    // can bootout; not knowing is not evidence that nothing is loaded.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, dropped_json);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    applyDropped(std.Options.debug_io, testing.allocator, &db, "tree", "2.2.1", "com.malt.tree", null, sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not ask launchd") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "mt reinstall tree") != null);
}

test "applyDropped keeps the row while the previous version's job is loaded" {
    // `mt services stop` resolves the plist through the row; deleting it
    // under a loaded job would orphan a daemon nothing can bootout.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, dropped_json);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    applyDropped(std.Options.debug_io, testing.allocator, &db, "tree", "2.2.1", "com.malt.tree", .running, sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "declares no service") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "mt services stop tree") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "mt reinstall tree") != null);
}

test "register stays silent for a formula that never had a service" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, dropped_json);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

    try testing.expectEqual(@as(usize, 0), buf.items.len);
    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
}

test "register keeps the row and says why when the new version's service block is unsupported" {
    // A `run` malt cannot read parses to no def; deleting the row here
    // would retire a service the formula still declares, with nothing to
    // bring it back.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    const unreadable =
        \\{"name":"tree","full_name":"tree","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"2.2.1"},"dependencies":[],"service":{"run":{"macos":42}}}
    ;
    var formula = try formula_mod.parseFormula(testing.allocator, unreadable);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: unsupported service block") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "tree 2.2.1: kept the service registration from the previous version") != null);
}

test "register retires the previous version's row when the new version's service is linux-only" {
    // A `linux`-only `run` is positive evidence the new version has no
    // macOS service, so the old row must go, not be kept behind a refusal.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    const linux_only =
        \\{"name":"tree","full_name":"tree","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"2.2.1"},"dependencies":[],"service":{"run":{"linux":["$HOMEBREW_PREFIX/opt/tree/bin/tree","system","service","--time","0"]},"run_type":"immediate","working_dir":"$HOMEBREW_PREFIX"}}
    ;
    var formula = try formula_mod.parseFormula(testing.allocator, linux_only);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    // The retire path deletes the label's service dir under the prefix.
    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);

    // The probe spawns launchctl; the debug io cannot.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    register(threaded.io(), testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "declares no service; retired the registration from the previous version") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service") == null);
}

test "register says a core formula ships its own plist and registers nothing" {
    // The API renders a shipped plist as a `name`-only service object;
    // the user must read why there is no malt service, as on the tap path.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    const ships_plist =
        \\{"name":"tree","full_name":"tree","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"2.2.1"},"dependencies":[],"service":{"name":{"macos":"org.freedesktop.dbus-session"}}}
    ;
    var formula = try formula_mod.parseFormula(testing.allocator, ships_plist);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: formula ships its own plist, which malt does not adopt") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "kept the service registration") == null);
}

test "register keeps the row and says why when the new version ships its own plist" {
    // The refusal reason and the kept-row line come from different facts;
    // an upgrade over a registration must print both.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    const ships_plist =
        \\{"name":"tree","full_name":"tree","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"2.2.1"},"dependencies":[],"service":{"name":{"macos":"org.freedesktop.dbus-session"}}}
    ;
    var formula = try formula_mod.parseFormula(testing.allocator, ships_plist);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: formula ships its own plist, which malt does not adopt") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "tree 2.2.1: kept the service registration from the previous version") != null);
}

test "registerRuby retires the previous version's row when the block is gone" {
    // Tap and --local upgrades take the Ruby twin; a dropped `service do`
    // must retire the row the same way the JSON path does.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    // The probe spawns launchctl; the debug io cannot.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    registerRuby(threaded.io(), testing.allocator, &db, null, false, "tree", "2.2.1", "/p", sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "declares no service") != null);
}

test "retireDropped ignores a registration that only shares the formula's name as a label" {
    // A formula literally named like another service's label must not
    // announce a retirement that touched nothing.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO services (name, keg_name, plist_path) VALUES ('com.malt.redis', 'redis', '/p/x.plist');
    );

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    retireDropped(std.Options.debug_io, testing.allocator, &db, "com.malt.redis", "1.0", sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "redis"));
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "registerRuby keeps the row when the block is declared but could not be read" {
    // The parse site already warned about the refused block; retiring
    // here would delete a service the formula still declares. Say the
    // old registration survived, or the parse-time warning reads as if
    // the keg now has no service at all.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    registerRuby(std.Options.debug_io, testing.allocator, &db, null, true, "tree", "2.2.1", "/p", sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "tree 2.2.1: kept the service registration from the previous version") != null);
}

test "registerRuby says nothing about a refused block on a fresh install" {
    // No previous registration to keep, and the parse site already said
    // why the block was refused.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    registerRuby(std.Options.debug_io, testing.allocator, &db, null, true, "tree", "2.2.1", "/p", sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}
