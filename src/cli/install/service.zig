//! Bridge from a formula's `service` block to the launchd `ServiceSpec`
//! the supervisor registers. Shared by install and upgrade so both paths
//! render the plist from the same definition.

const std = @import("std");

const confined_source = @import("../../fs/confined_source.zig");
const cron = @import("../../core/services/cron.zig");
const env_override = @import("../../core/services/env_override.zig");
const formula_mod = @import("../../core/formula.zig");
const plist_mod = @import("../../core/services/plist.zig");
const shipped_plist = @import("../../core/services/shipped_plist.zig");
const supervisor_mod = @import("../../core/services/supervisor.zig");
const sqlite = @import("../../db/sqlite.zig");
const fs_read = @import("../../fs/read.zig");
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

    // Values carry the token too (`PATH`, `HOME`); keys never do.
    const env = try aa.alloc(plist_mod.EnvPair, def.env.len);
    for (def.env, env) |src, *dst| dst.* = .{ .key = try aa.dupe(u8, src.key), .value = try plist_mod.expandPrefix(aa, src.value, prefix) };

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
        .env = env,
    };
}

/// Register (or re-register) the launchd service a formula's `service:`
/// block declares; without one, retire whatever a previous version
/// registered. Best-effort: failures warn but never fail the install or
/// upgrade that called it.
pub fn register(
    io: std.Io,
    environ: std.process.Environ,
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
        switch (refusal) {
            .ships_plist => |label| registerShipped(io, environ, allocator, db, label, formula.name, formula.pkg_version, prefix, sink),
            .unsupported => {
                // Core carries a bare tag so the wording stays in cli.
                sink.warn("could not register service for {s}: {s}", .{ formula.name, rb_parse.serviceRefusalReason(error.Unsupported) });
                warnKeptRow(db, formula.name, formula.pkg_version, sink);
            },
        }
        return;
    };
    registerDef(io, environ, allocator, db, def, formula.name, formula.pkg_version, prefix, sink);
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
/// tells a block the parser refused (already warned about) from no block;
/// `shipped_label` is the plist a `name`-only block says the keg carries.
pub fn registerRuby(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    block: ?rb_parse.RubyServiceBlock,
    declared: bool,
    shipped_label: ?[]const u8,
    name: []const u8,
    pkg_version: []const u8,
    prefix: []const u8,
    sink: sink_mod.OutputSink,
) void {
    const b = block orelse {
        if (shipped_label) |label| return registerShipped(io, environ, allocator, db, label, name, pkg_version, prefix, sink);
        if (!declared) return retireDropped(io, allocator, db, name, pkg_version, sink);
        // The parse site already said why the block was refused.
        warnKeptRow(db, name, pkg_version, sink);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const def = defFromRuby(arena.allocator(), b, name, pkg_version) orelse {
        sink.warn("could not register service for {s}: unsupported service block", .{name});
        warnKeptRow(db, name, pkg_version, sink);
        return;
    };
    if (b.declares_env) sink.warn("{s}: service environment_variables not applied (not read from tap or local formulas)", .{name});
    registerDef(io, environ, allocator, db, def, name, pkg_version, prefix, sink);
}

fn registerDef(
    io: std.Io,
    environ: std.process.Environ,
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
    const spec = specFromDef(arena.allocator(), def, name, prefix) catch return;
    registerSpec(io, environ, allocator, db, spec, name, pkg_version, prefix, sink);
}

/// Lift the plist a formula ships at `<keg>/<label>.plist` into malt's own
/// rendered service. The keg file is only ever read; every refusal keeps
/// the previous version's row the way an unreadable block does.
fn registerShipped(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    label: []const u8,
    name: []const u8,
    pkg_version: []const u8,
    prefix: []const u8,
    sink: sink_mod.OutputSink,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag: shipped_plist.Diag = .{};
    var reason_buf: [256]u8 = undefined;
    const spec = liftShipped(io, arena.allocator(), label, name, pkg_version, prefix, &diag) catch |err| {
        sink.warn("could not register service for {s}: {s}", .{ name, shippedRefusal(&reason_buf, err, diag) });
        warnKeptRow(db, name, pkg_version, sink);
        return;
    };
    registerSpec(io, environ, allocator, db, spec, name, pkg_version, prefix, sink);
}

const LiftError = shipped_plist.Error || error{ BadLabel, NotInKeg, LinksOut, Unreadable };

fn liftShipped(
    io: std.Io,
    aa: std.mem.Allocator,
    label: []const u8,
    name: []const u8,
    pkg_version: []const u8,
    prefix: []const u8,
    diag: *shipped_plist.Diag,
) LiftError!plist_mod.ServiceSpec {
    // Both become path components under the Cellar.
    if (!path_component.isPathComponent(label) or !path_component.isPathComponent(name)) return error.BadLabel;
    const keg = try std.fmt.allocPrint(aa, "{s}/Cellar/{s}/{s}", .{ prefix, name, pkg_version });
    const path = try std.fmt.allocPrint(aa, "{s}/{s}.plist", .{ keg, label });
    // Formulas ship `<label>.plist` as a link to their real file, and the
    // extractor lets a link climb one level above its root (the prefix,
    // once the keg is in the Cellar); resolve it, but only into the keg.
    var source = confined_source.openFile(io, aa, keg, path, .read_only) catch |err| return switch (err) {
        error.FileNotFound => error.NotInKeg,
        error.AccessDenied => error.LinksOut,
        else => error.Unreadable,
    };
    defer source.deinit(io);
    // One byte past the cap so an oversized file refuses instead of
    // lifting truncated.
    const bytes = fs_read.readFileAll(io, aa, source.file, shipped_plist.max_bytes + 1) catch return error.Unreadable;
    return shipped_plist.lift(aa, bytes, name, label, prefix, diag);
}

fn shippedRefusal(buf: []u8, err: LiftError, diag: shipped_plist.Diag) []const u8 {
    return switch (err) {
        error.NotInKeg => "declares a shipped plist that is not in the keg",
        error.BadLabel => "shipped plist label is not a plain file name",
        error.LinksOut => "shipped plist links outside the keg",
        error.Unreadable => "shipped plist could not be read",
        error.Malformed => "shipped plist is not a launchd plist malt can read",
        error.LabelMismatch => "shipped plist label does not match the declared service name",
        error.NoProgramArguments => "shipped plist has no ProgramArguments",
        // `max_key_len` keeps every key inside the caller's buffer.
        error.UnknownKey => std.fmt.bufPrint(buf, "shipped plist uses {s}, which malt does not adopt", .{diag.key}) catch unreachable,
        error.DuplicateKey => std.fmt.bufPrint(buf, "shipped plist repeats {s}", .{diag.key}) catch unreachable,
        error.BadValue => std.fmt.bufPrint(buf, "shipped plist gives {s} a shape malt does not adopt", .{diag.key}) catch unreachable,
        error.OutOfMemory => "out of memory",
    };
}

/// Every register path funnels here, so a user's overrides apply whether
/// the service came from the API, a Ruby block or a shipped plist.
fn registerSpec(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    formula_spec: plist_mod.ServiceSpec,
    name: []const u8,
    pkg_version: []const u8,
    prefix: []const u8,
    sink: sink_mod.OutputSink,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // The formula's argv may have changed, so a refused file cannot keep
    // the old plist here; it registers without overrides, as warned.
    const spec = withEnvOverrides(io, arena.allocator(), environ, formula_spec, name, sink) orelse formula_spec;

    // launchd creates the log files on first run; a missing dir surfaces there.
    var log_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_dir = std.fmt.bufPrint(&log_buf, "{s}/var/log", .{prefix}) catch return;
    std.Io.Dir.cwd().createDirPath(io, log_dir) catch {};

    var cellar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, name, pkg_version }) catch return;

    const ctx: supervisor_mod.SupervisorCtx = .{ .allocator = allocator, .io = io, .db = db };
    // Dropped first so an interrupted or failed register leaves no spec
    // for `services start` to roll back to.
    supervisor_mod.dropFormulaSpec(ctx, spec.label);
    supervisor_mod.register(ctx, spec, name, false, cellar_path, prefix) catch |err| {
        sink.warn("could not register service for {s}: {s}", .{ name, @errorName(err) });
        warnKeptRow(db, name, pkg_version, sink);
        return;
    };
    supervisor_mod.saveFormulaSpec(ctx, .{ .keg_name = name, .cellar_path = cellar_path, .spec = formula_spec }) catch
        sink.warn("{s}: edits to its service .env will need 'mt reinstall {s}' to apply", .{ name, name });

    // launchd keeps a loaded job's configuration until bootout, so a
    // rewritten plist only takes effect on restart. Never restart here: an
    // upgrade must not kill a daemon the user did not ask to stop.
    switch (supervisor_mod.queryRuntime(io, allocator, spec.label)) {
        .loaded, .running, .errored => sink.warn("{s} service re-registered; run 'mt services restart {s}' to apply it", .{ name, name }),
        .not_loaded => {},
    }
}

/// Layers `<config>/malt/services/<name>.env` over the formula's
/// environment. No file means no overrides and stays silent. Null when
/// the file exists but is refused (warned): the caller decides whether
/// to keep the plist it already has.
pub fn withEnvOverrides(
    io: std.Io,
    aa: std.mem.Allocator,
    environ: std.process.Environ,
    spec: plist_mod.ServiceSpec,
    name: []const u8,
    sink: sink_mod.OutputSink,
) ?plist_mod.ServiceSpec {
    const path = (overridePath(aa, environ, name) catch return spec) orelse return spec;
    const bytes = readOverrideFile(io, aa, path) catch |err| switch (err) {
        error.FileNotFound => return spec,
        else => {
            sink.warn("{s}: ignored {s}: {s}", .{ name, path, overrideReadRefusal(err) });
            return null;
        },
    };
    var diag: env_override.Diag = .{};
    const overrides = env_override.parse(aa, bytes, &diag) catch |err| {
        sink.warn("{s}: ignored {s}:{d}: {s}", .{ name, path, diag.line, overrideRefusal(err) });
        return null;
    };
    var out = spec;
    out.env = env_override.merge(aa, spec.env, overrides) catch return null;
    return out;
}

const OverrideReadError = error{ FileNotFound, NotRegular, OtherOwner, OthersCanWrite, TooLarge, Unreadable };

/// The file feeds a job's environment, so only its owner may be able to
/// write it; symlinks are followed (dotfile managers) and the target judged.
fn readOverrideFile(io: std.Io, aa: std.mem.Allocator, path: [:0]const u8) OverrideReadError![]u8 {
    // Non-blocking so a FIFO at the path cannot stall a locked upgrade.
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return switch (std.c.errno(fd)) {
        .NOENT, .NOTDIR => error.FileNotFound,
        else => error.Unreadable,
    };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.Unreadable;
    try checkOverrideOwner(@intCast(st.mode), @intCast(st.uid), @intCast(std.c.geteuid()));
    // One byte past the cap so an oversized file refuses instead of
    // applying truncated.
    const bytes = fs_read.readFileAll(io, aa, file, env_override.max_bytes + 1) catch return error.Unreadable;
    if (bytes.len > env_override.max_bytes) return error.TooLarge;
    return bytes;
}

fn checkOverrideOwner(mode: u32, uid: u32, euid: u32) OverrideReadError!void {
    if (mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotRegular;
    if (uid != euid) return error.OtherOwner;
    if (mode & 0o022 != 0) return error.OthersCanWrite;
}

fn overrideReadRefusal(err: OverrideReadError) []const u8 {
    return switch (err) {
        error.NotRegular => "not a regular file",
        error.OtherOwner => "owned by another user",
        error.OthersCanWrite => "writable by other users",
        error.TooLarge => std.fmt.comptimePrint("larger than {d} bytes", .{env_override.max_bytes}),
        error.Unreadable, error.FileNotFound => "unreadable",
    };
}

test "checkOverrideOwner accepts only an owner-only-writable regular file of the caller" {
    const reg: u32 = std.c.S.IFREG;
    try checkOverrideOwner(reg | 0o644, 501, 501);
    try checkOverrideOwner(reg | 0o600, 501, 501);
    try testing.expectError(error.OtherOwner, checkOverrideOwner(reg | 0o644, 0, 501));
    try testing.expectError(error.OthersCanWrite, checkOverrideOwner(reg | 0o646, 501, 501));
    try testing.expectError(error.OthersCanWrite, checkOverrideOwner(reg | 0o664, 501, 501));
    try testing.expectError(error.NotRegular, checkOverrideOwner(std.c.S.IFIFO | 0o600, 501, 501));
    try testing.expectError(error.NotRegular, checkOverrideOwner(std.c.S.IFDIR | 0o700, 501, 501));
}

/// Re-merges the user's override file into a registered service's plist,
/// so `services start` picks up an edit without a reinstall. Best-effort:
/// on any failure the existing plist is started as is.
pub fn refreshOverrides(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, db: *sqlite.Database, name: []const u8, sink: sink_mod.OutputSink) void {
    const label = supervisor_mod.resolveLabel(allocator, db, name) catch return;
    defer allocator.free(label);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    // Without the formula's own spec a user key cannot be told from a
    // formula key, so an older registration waits for its next register.
    const saved = supervisor_mod.loadFormulaSpec(aa, io, label) orelse return warnNeedsReinstall(io, aa, environ, db, label, sink);
    // The saved label picks which plist is rewritten.
    if (!std.mem.eql(u8, saved.spec.label, label)) return;
    const spec = withEnvOverrides(io, aa, environ, saved.spec, saved.keg_name, sink) orelse return;
    supervisor_mod.rewritePlist(.{ .allocator = allocator, .io = io, .db = db }, spec, saved.cellar_path) catch |err|
        sink.warn("{s}: could not apply service overrides: {s}", .{ saved.keg_name, @errorName(err) });
}

/// Only when the user wrote a file: silence would read as "applied".
fn warnNeedsReinstall(io: std.Io, aa: std.mem.Allocator, environ: std.process.Environ, db: *sqlite.Database, label: []const u8, sink: sink_mod.OutputSink) void {
    const keg = kegNameOf(aa, db, label) orelse return;
    const path = (overridePath(aa, environ, keg) catch return) orelse return;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return;
    sink.warn("{s}: run 'mt reinstall {s}' once to apply {s}", .{ keg, keg, path });
}

fn kegNameOf(aa: std.mem.Allocator, db: *sqlite.Database, label: []const u8) ?[]const u8 {
    var stmt = db.prepare("SELECT keg_name FROM services WHERE name = ?;") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, label) catch return null;
    if (!(stmt.step() catch false)) return null;
    return aa.dupe(u8, std.mem.sliceTo(stmt.columnText(0) orelse return null, 0)) catch null;
}

/// XDG says a relative `XDG_CONFIG_HOME` is invalid, so it falls back to
/// `~/.config` rather than resolving against the cwd.
fn overridePath(aa: std.mem.Allocator, environ: std.process.Environ, name: []const u8) !?[:0]const u8 {
    if (!path_component.isPathComponent(name)) return null;
    if (std.process.Environ.getPosix(environ, "XDG_CONFIG_HOME")) |xdg| if (std.fs.path.isAbsolute(xdg))
        return try std.fmt.allocPrintSentinel(aa, "{s}/malt/services/{s}.env", .{ xdg, name }, 0);
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return null;
    if (!std.fs.path.isAbsolute(home)) return null;
    return try std.fmt.allocPrintSentinel(aa, "{s}/.config/malt/services/{s}.env", .{ home, name }, 0);
}

fn overrideRefusal(err: env_override.Error) []const u8 {
    return switch (err) {
        error.MissingEquals => "expected KEY=VALUE",
        error.BadKey => "key must match [A-Za-z_][A-Za-z0-9_]* and fit the length limit",
        error.BadValue => "value is too long, not UTF-8, or contains a NUL or carriage return",
        error.ReservedKey => "PATH, HOME and DYLD_* cannot be overridden",
        error.OutOfMemory => "out of memory",
    };
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
/// path produces, minus `environment_variables`, so both share
/// `specFromDef` and `validate`. Null when any token is a shape malt
/// cannot render (`Dir.home`, a method call, an interpolation other than a
/// prefix root) or the schedule is out of bounds - the API side fails those
/// the same way, and a half-translated argv must never reach launchd.
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
/// Accepted shapes: `"literal"`, `"...#{<root>}..."`, `<root>`,
/// `<root>/"leaf"`, and `Formula["dep"].<root>/"leaf"` with an opt root.
fn rubyPath(aa: std.mem.Allocator, tok: []const u8, name: []const u8, pkg_version: []const u8) ?[]const u8 {
    if (tok.len >= 2 and tok[0] == '"' and tok[tok.len - 1] == '"') return rubyLiteral(aa, tok[1 .. tok.len - 1], name, pkg_version);
    if (std.mem.indexOf(u8, tok, "#{") != null) return null;

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
    const base = rootBase(aa, root, owner, name, pkg_version) orelse return null;
    const quoted = leaf orelse return base;
    if (quoted.len == 0 or quoted[quoted.len - 1] != '"') return null;
    const sub = quoted[0 .. quoted.len - 1];
    // Also catches a chained `/"a"/"b"` leaf, whose quotes would land in the path.
    if (!isVerbatim(sub)) return null;
    return std.fmt.allocPrint(aa, "{s}/{s}", .{ base, sub }) catch null;
}

/// Whether a quoted literal's body means the same in Ruby as its bytes,
/// `#{...}` aside. An inner `"` makes it several literals, escapes need a
/// Ruby lexer, and `#@ivar`/`#$global` interpolate state malt never has.
fn isVerbatim(body: []const u8) bool {
    return std.mem.indexOfAny(u8, body, "\"\\") == null and
        std.mem.indexOf(u8, body, "#@") == null and
        std.mem.indexOf(u8, body, "#$") == null;
}

/// Body of a quoted literal, with each `#{<root>}` rendered as its bare
/// token would be.
fn rubyLiteral(aa: std.mem.Allocator, body: []const u8, name: []const u8, pkg_version: []const u8) ?[]const u8 {
    if (!isVerbatim(body)) return null;
    if (std.mem.indexOf(u8, body, "#{") == null) return body;

    var out: std.ArrayList(u8) = .empty;
    var rest = body;
    while (std.mem.cut(u8, rest, "#{")) |cut| {
        const before, const after = cut;
        const ident, rest = std.mem.cut(u8, after, "}") orelse return null;
        const root = ruby_roots.get(ident) orelse return null;
        const base = rootBase(aa, root, name, name, pkg_version) orelse return null;
        out.appendSlice(aa, before) catch return null;
        out.appendSlice(aa, base) catch return null;
    }
    out.appendSlice(aa, rest) catch return null;
    return out.items;
}

/// `owner` names the opt link; keg-relative roots always use this keg's
/// Cellar leaf.
fn rootBase(aa: std.mem.Allocator, root: RubyRoot, owner: []const u8, name: []const u8, pkg_version: []const u8) ?[]const u8 {
    return switch (root) {
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
    } catch null;
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

test "specFromDef expands the Homebrew prefix token in every env value, keys untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def: formula_mod.ServiceDef = .{
        .run = &.{"/bin/true"},
        .env = &.{
            .{ .key = "PATH", .value = "$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:/usr/bin" },
            .{ .key = "LC_ALL", .value = "en_US.UTF-8" },
        },
    };
    const spec = try specFromDef(arena.allocator(), def, "x", "/opt/malt");
    try testing.expectEqual(@as(usize, 2), spec.env.len);
    try testing.expectEqualStrings("PATH", spec.env[0].key);
    try testing.expectEqualStrings("/opt/malt/bin:/opt/malt/sbin:/usr/bin", spec.env[0].value);
    try testing.expectEqualStrings("LC_ALL", spec.env[1].key);
    try testing.expectEqualStrings("en_US.UTF-8", spec.env[1].value);
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
    try testing.expect(defFromRuby(aa, .{ .run = &.{ "opt_bin/\"x\"", "Dir.home" } }, "foo", "1.0") == null);
    try testing.expect(defFromRuby(aa, .{ .run = &.{"opt_bin/\"x\""}, .log_path = "Dir.home" }, "foo", "1.0") == null);
}

test "defFromRuby renders a prefix root interpolated into a quoted literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const cases = [_]struct { tok: []const u8, want: []const u8 }{
        .{ .tok = "\"#{opt_bin}/x\"", .want = "$HOMEBREW_PREFIX/opt/foo/bin/x" },
        .{ .tok = "\"--config=#{etc}/x.conf\"", .want = "--config=$HOMEBREW_PREFIX/etc/x.conf" },
        .{ .tok = "\"#{var}/a:#{HOMEBREW_PREFIX}/b\"", .want = "$HOMEBREW_PREFIX/var/a:$HOMEBREW_PREFIX/b" },
        // Same Cellar leaf as bare `bin`, since `expandPrefix` has no Cellar token.
        .{ .tok = "\"#{bin}/x\"", .want = "$HOMEBREW_PREFIX/Cellar/foo/1.2_1/bin/x" },
    };
    for (cases) |case| {
        const def = defFromRuby(aa, .{ .run = &.{case.tok} }, "foo", "1.2_1") orelse return error.TestUnexpectedNull;
        try testing.expectEqualStrings(case.want, def.run[0]);
    }

    const def = defFromRuby(aa, .{
        .run = &.{"opt_bin/\"x\""},
        .log_path = "\"#{var}/log/x.log\"",
    }, "foo", "1.0") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("$HOMEBREW_PREFIX/var/log/x.log", def.log_path.?);
}

test "defFromRuby drops the service on an interpolation it cannot render" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const refused = [_][]const u8{
        "\"#{Dir.home}/x\"", // needs the install-time HOME
        "\"#{foo}\"", // not a known root
        "\"#{name}.conf\"", // no rendering in malt
        "\"#{opt_bin\"", // unterminated
        "\"a\\#{var}\"", // escapes need a real string lexer
        "\"a\\n\"",
        // Ruby's sigil shorthand interpolates too; verbatim would be wrong.
        "\"#@dir/x\"",
        "\"--pid=#$$\"",
        "\"#{Formula[\"d\"].opt_bin}/x\"",
        "#{var}", // unquoted
        "var/\"log/#{name}.log\"", // a leaf is not rendered
        "opt_bin/\"#{etc}\"",
        "var/\"log/#$$.log\"",
        "opt_bin/\"a\\\\b\"",
        "\"#{var}\" + \"/x\"", // an expression, not one literal
        "\"",
    };
    for (refused) |tok| {
        if (defFromRuby(aa, .{ .run = &.{tok} }, "foo", "1.0") != null) {
            std.debug.print("accepted: {s}\n", .{tok});
            return error.TestExpectedNull;
        }
    }
    try testing.expect(defFromRuby(aa, .{ .run = &.{"opt_bin/\"x\""}, .log_path = "\"#{Dir.home}/x.log\"" }, "foo", "1.0") == null);
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

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

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

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

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
    register(threaded.io(), .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "declares no service; retired the registration from the previous version") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service") == null);
}

test "register says a declared shipped plist is missing from the keg and registers nothing" {
    // The API renders a shipped plist as a `name`-only service object;
    // with no file to lift, the user must read why there is no service.
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

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: declares a shipped plist that is not in the keg") != null);
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

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: declares a shipped plist that is not in the keg") != null);
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
    registerRuby(threaded.io(), .empty, testing.allocator, &db, null, false, null, "tree", "2.2.1", "/p", sink_mod.terminal);

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

    registerRuby(std.Options.debug_io, .empty, testing.allocator, &db, null, true, null, "tree", "2.2.1", "/p", sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "tree 2.2.1: kept the service registration from the previous version") != null);
}

test "registerRuby keeps the row when the block has a token it cannot render" {
    // An upgrade whose block malt refuses leaves the old plist live; say so.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    registerRuby(std.Options.debug_io, .empty, testing.allocator, &db, .{ .run = &.{"\"a\\\\t\""} }, true, null, "tree", "2.2.1", "/p", sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: unsupported service block") != null);
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

    registerRuby(std.Options.debug_io, .empty, testing.allocator, &db, null, true, null, "tree", "2.2.1", "/p", sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

const shipd_json =
    \\{"name":"tree","full_name":"tree","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"2.2.1"},"dependencies":[],"service":{"name":{"macos":"org.example.shipd"}}}
;

/// A keg at `<prefix>/Cellar/tree/2.2.1` shipping `org.example.shipd.plist`
/// with `body`; returns the file's path.
fn seedShippedKeg(prefix: []const u8, body: []const u8) ![]u8 {
    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/tree/2.2.1", .{prefix});
    defer testing.allocator.free(keg);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, keg);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/org.example.shipd.plist", .{keg});
    errdefer testing.allocator.free(path);
    const f = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, body);
    return path;
}

fn shippedBody(aa: std.mem.Allocator, prefix: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(aa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>org.example.shipd</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}/opt/tree/bin/tree</string>
        \\        <string>--nofork</string>
        \\    </array>
        \\{s}
        \\</dict>
        \\</plist>
        \\
    , .{ prefix, extra });
}

fn renderedPlist(prefix: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/var/malt/services/com.malt.tree/service.plist", .{prefix});
    defer testing.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, testing.allocator, .unlimited);
}

test "register lifts the plist a core formula ships into a malt-rendered service" {
    // The row and the rendered plist are malt's own (`com.malt.<name>`,
    // under var/malt/services); the keg's file is input and stays as is.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try shippedBody(arena.allocator(), prefix,
        \\    <key>Sockets</key>
        \\    <dict>
        \\        <key>unix_domain_listener</key>
        \\        <dict>
        \\            <key>SecureSocketWithKey</key>
        \\            <string>TREE_SOCKET</string>
        \\        </dict>
        \\    </dict>
    );
    const keg_plist = try seedShippedKeg(prefix, body);
    defer testing.allocator.free(keg_plist);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    // The post-register probe spawns launchctl; the debug io cannot.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    register(threaded.io(), .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service") == null);
    const rendered = try renderedPlist(prefix);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "<string>com.malt.tree</string>") != null);
    const head = try std.fmt.allocPrint(testing.allocator, "<string>{s}/opt/tree/bin/tree</string>", .{prefix});
    defer testing.allocator.free(head);
    try testing.expect(std.mem.indexOf(u8, rendered, head) != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "<string>TREE_SOCKET</string>") != null);
    const after = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, keg_plist, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(body, after);
}

test "register lifts a shipped plist that the keg carries as a symlink to its real file" {
    // Formulas install `<label>.plist` as a link (`prefix.install_symlink`);
    // the extractor already confines link targets to the keg, so the open
    // must follow it rather than refuse it.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try shippedBody(arena.allocator(), prefix, "");
    const linked = try seedShippedKeg(prefix, body);
    defer testing.allocator.free(linked);
    const real = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/tree/2.2.1/macos_tree.plist", .{prefix});
    defer testing.allocator.free(real);
    try std.Io.Dir.renameAbsolute(linked, real, std.Options.debug_io);
    // Relative target, as `install_symlink` writes it.
    var keg = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, std.fs.path.dirname(real).?, .{});
    defer keg.close(std.Options.debug_io);
    try keg.symLink(std.Options.debug_io, "macos_tree.plist", "org.example.shipd.plist", .{});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    register(threaded.io(), .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service") == null);
}

test "register refreshes the previous version's row when the new keg's shipped plist lifts" {
    // An upgrade over an existing registration must replace the plist and
    // the row, not keep the old one behind a refusal.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keg_plist = try seedShippedKeg(prefix, try shippedBody(arena.allocator(), prefix, ""));
    defer testing.allocator.free(keg_plist);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    register(threaded.io(), .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(std.mem.indexOf(u8, buf.items, "kept the service registration") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service") == null);
    var stmt = try db.prepare("SELECT plist_path FROM services WHERE keg_name = 'tree';");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    const want = try std.fmt.allocPrint(testing.allocator, "{s}/var/malt/services/com.malt.tree/service.plist", .{prefix});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, std.mem.sliceTo(stmt.columnText(0).?, 0));
    const rendered = try renderedPlist(prefix);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "<string>--nofork</string>") != null);
}

test "register refuses a shipped label from the API that is not a plain file name" {
    // The JSON path carries the label straight from the API into a keg
    // path component; the gate must hold there, not only on the Ruby twin.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    const hostile =
        \\{"name":"tree","full_name":"tree","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"2.2.1"},"dependencies":[],"service":{"name":{"macos":"../../etc/evil"}}}
    ;
    var formula = try formula_mod.parseFormula(testing.allocator, hostile);
    defer formula.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, "/p", sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: shipped plist label is not a plain file name") != null);
}

test "register refuses a shipped plist whose symlink leaves the keg" {
    // The extractor allows a link one level above its root, which lands
    // under the prefix after the Cellar clone; the lift must not read
    // another formula's file as this one's service.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try shippedBody(arena.allocator(), prefix, "");
    const linked = try seedShippedKeg(prefix, body);
    defer testing.allocator.free(linked);
    const outside = try std.fmt.allocPrint(testing.allocator, "{s}/etc/evil.plist", .{prefix});
    defer testing.allocator.free(outside);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(outside).?);
    try std.Io.Dir.renameAbsolute(linked, outside, std.Options.debug_io);
    var keg = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, std.fs.path.dirname(linked).?, .{});
    defer keg.close(std.Options.debug_io);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    // Leaf link straight out of the keg.
    try keg.symLink(std.Options.debug_io, "../../../etc/evil.plist", "org.example.shipd.plist", .{});
    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);
    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: shipped plist links outside the keg") != null);

    // Leaf stays lexically in the keg; an intermediate directory link
    // carries it out.
    try keg.deleteFile(std.Options.debug_io, "org.example.shipd.plist");
    try keg.symLink(std.Options.debug_io, "../../..", "dir", .{});
    try keg.symLink(std.Options.debug_io, "dir/etc/evil.plist", "org.example.shipd.plist", .{});
    buf.clearRetainingCapacity();
    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);
    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: shipped plist links outside the keg") != null);
}

test "register refuses a shipped plist over the size cap even when its head parses" {
    // A complete document padded past the cap must refuse, not lift the
    // first 64 KiB.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pad = try arena.allocator().alloc(u8, shipped_plist.max_bytes);
    @memset(pad, ' ');
    const body = try std.mem.concat(arena.allocator(), u8, &.{ try shippedBody(arena.allocator(), prefix, ""), pad });
    const keg_plist = try seedShippedKeg(prefix, body);
    defer testing.allocator.free(keg_plist);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: shipped plist is not a launchd plist malt can read") != null);
}

test "register refuses a shipped plist that uses a key malt does not adopt and names it" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try shippedBody(arena.allocator(), prefix, "    <key>MachServices</key>\n    <dict/>");
    const keg_plist = try seedShippedKeg(prefix, body);
    defer testing.allocator.free(keg_plist);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: shipped plist uses MachServices, which malt does not adopt") != null);
    // The seeded row is the previous version's; a refusal keeps it.
    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "tree 2.2.1: kept the service registration from the previous version") != null);
}

test "register refuses a shipped plist whose Label is not the declared one" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try shippedBody(arena.allocator(), prefix, "");
    const other = try std.mem.replaceOwned(u8, arena.allocator(), body, "<string>org.example.shipd</string>", "<string>org.example.other</string>");
    const keg_plist = try seedShippedKeg(prefix, other);
    defer testing.allocator.free(keg_plist);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: shipped plist label does not match the declared service name") != null);
}

test "register refuses a shipped plist whose executable escapes the keg and opt roots" {
    // The lift is input to the same gate as a `run` block: a head outside
    // the keg or `<prefix>/opt` must never reach launchd.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try shippedBody(arena.allocator(), "/usr/local", "");
    const keg_plist = try seedShippedKeg(prefix, body);
    defer testing.allocator.free(keg_plist);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: InvalidService") != null);
}

test "register says it kept the previous row when the new keg's shipped plist fails validation" {
    // The validator refusal is the one arm that reads a lifted plist after
    // the lift succeeded; on upgrade it must say the old row survived like
    // every other refusal does.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try seedDroppedRow(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keg_plist = try seedShippedKeg(prefix, try shippedBody(arena.allocator(), "/usr/local", ""));
    defer testing.allocator.free(keg_plist);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, prefix, sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: InvalidService") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "tree 2.2.1: kept the service registration from the previous version") != null);
}

test "registerRuby lifts the plist a tap formula ships" {
    // The Ruby twin reaches the same lift through the label the block names.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try shippedBody(arena.allocator(), prefix, "");
    const keg_plist = try seedShippedKeg(prefix, body);
    defer testing.allocator.free(keg_plist);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    registerRuby(threaded.io(), .empty, testing.allocator, &db, null, true, "org.example.shipd", "tree", "2.2.1", prefix, sink_mod.terminal);

    try testing.expect(supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service") == null);
}

test "registerRuby refuses a shipped label that is not a plain file name" {
    // The label becomes a path component under the keg; `../x` would read
    // a plist from outside it.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();

    registerRuby(std.Options.debug_io, .empty, testing.allocator, &db, null, true, "../../etc/evil", "tree", "2.2.1", "/p", sink_mod.terminal);

    try testing.expect(!supervisor_mod.hasService(&db, "tree"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "could not register service for tree: shipped plist label is not a plain file name") != null);
}

/// An environ carrying only `XDG_CONFIG_HOME=<root>`, owned by `aa`.
fn xdgEnviron(aa: std.mem.Allocator, root: []const u8) !std.process.Environ {
    const entries = try aa.allocSentinel(?[*:0]const u8, 1, null);
    entries[0] = (try std.fmt.allocPrintSentinel(aa, "XDG_CONFIG_HOME={s}", .{root}, 0)).ptr;
    return .{ .block = .{ .slice = entries } };
}

fn writeEnvFile(cfg: []const u8, body: []const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/malt/services", .{cfg});
    defer testing.allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/tree.env", .{dir});
    defer testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = body });
}

test "refreshOverrides applies an edited .env to a registered service without a reinstall" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const keg_plist = try seedShippedKeg(prefix, try shippedBody(aa, prefix,
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>FROM_FORMULA</key>
        \\        <string>kept</string>
        \\    </dict>
    ));
    defer testing.allocator.free(keg_plist);

    const cfg = try std.fmt.allocPrint(aa, "{s}/cfg", .{prefix});
    try writeEnvFile(cfg, "OLD=1\n");
    const environ = try xdgEnviron(aa, cfg);

    // The post-register probe spawns launchctl; the debug io cannot.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    register(threaded.io(), environ, testing.allocator, &db, &formula, prefix, sink_mod.silent);
    const before = try renderedPlist(prefix);
    defer testing.allocator.free(before);
    try testing.expect(std.mem.indexOf(u8, before, "<key>OLD</key>") != null);

    // A key dropped from the file must leave the plist too; only the saved
    // formula spec can tell it apart from one the formula declares.
    try writeEnvFile(cfg, "NEW=2\n");
    refreshOverrides(std.Options.debug_io, environ, testing.allocator, &db, "com.malt.tree", sink_mod.silent);
    const after = try renderedPlist(prefix);
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "<key>OLD</key>") == null);
    try testing.expect(std.mem.indexOf(u8, after, "<key>NEW</key>") != null);
    try testing.expect(std.mem.indexOf(u8, after, "<key>FROM_FORMULA</key>") != null);

    try writeEnvFile(cfg, "");
    refreshOverrides(std.Options.debug_io, environ, testing.allocator, &db, "tree", sink_mod.silent);
    const cleared = try renderedPlist(prefix);
    defer testing.allocator.free(cleared);
    try testing.expect(std.mem.indexOf(u8, cleared, "<key>NEW</key>") == null);
    try testing.expect(std.mem.indexOf(u8, cleared, "<key>FROM_FORMULA</key>") != null);
}

test "refreshOverrides leaves a registration with no saved formula spec untouched" {
    // An older registration has no saved formula spec.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const keg_plist = try seedShippedKeg(prefix, try shippedBody(aa, prefix, ""));
    defer testing.allocator.free(keg_plist);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    register(threaded.io(), .empty, testing.allocator, &db, &formula, prefix, sink_mod.silent);
    const saved = try std.fmt.allocPrint(aa, "{s}/var/malt/services/com.malt.tree/formula.json", .{prefix});
    try std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, saved);
    const before = try renderedPlist(prefix);
    defer testing.allocator.free(before);

    const cfg = try std.fmt.allocPrint(aa, "{s}/cfg", .{prefix});
    try writeEnvFile(cfg, "NEW=2\n");
    const environ = try xdgEnviron(aa, cfg);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &buf);
    defer output.endStderrCapture();
    refreshOverrides(std.Options.debug_io, environ, testing.allocator, &db, "tree", sink_mod.terminal);
    const after = try renderedPlist(prefix);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    // The user wrote a file; saying nothing would read as "applied".
    try testing.expect(std.mem.indexOf(u8, buf.items, "mt reinstall tree") != null);
}

test "refreshOverrides ignores a saved spec whose label names another service" {
    // The label picks which plist gets rewritten; it must be the one asked for.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const keg_plist = try seedShippedKeg(prefix, try shippedBody(aa, prefix, ""));
    defer testing.allocator.free(keg_plist);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    register(threaded.io(), .empty, testing.allocator, &db, &formula, prefix, sink_mod.silent);

    var saved = supervisor_mod.loadFormulaSpec(aa, std.Options.debug_io, "com.malt.tree").?;
    saved.spec.label = "com.malt.other";
    const path = try std.fmt.allocPrint(aa, "{s}/var/malt/services/com.malt.tree/formula.json", .{prefix});
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = try std.json.Stringify.valueAlloc(aa, saved, .{}) });

    // A registered neighbour, so a misdirected write would land.
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, try supervisor_mod.serviceDir(aa, "com.malt.other"));

    const cfg = try std.fmt.allocPrint(aa, "{s}/cfg", .{prefix});
    try writeEnvFile(cfg, "NEW=2\n");
    const environ = try xdgEnviron(aa, cfg);
    refreshOverrides(std.Options.debug_io, environ, testing.allocator, &db, "tree", sink_mod.silent);

    const other = try std.fmt.allocPrint(aa, "{s}/var/malt/services/com.malt.other/service.plist", .{prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.Options.debug_io, other, .{}));
    const after = try renderedPlist(prefix);
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "<key>NEW</key>") == null);
}

test "refreshOverrides keeps the live overrides when the edited file is refused" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator, shipd_json);
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const keg_plist = try seedShippedKeg(prefix, try shippedBody(aa, prefix, ""));
    defer testing.allocator.free(keg_plist);
    const cfg = try std.fmt.allocPrint(aa, "{s}/cfg", .{prefix});
    const environ = try xdgEnviron(aa, cfg);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try writeEnvFile(cfg, "PGPORT=5433\n");
    register(threaded.io(), environ, testing.allocator, &db, &formula, prefix, sink_mod.silent);

    // A typo must not bring the job back on the formula's defaults.
    try writeEnvFile(cfg, "export PGPORT=5434\n");
    refreshOverrides(std.Options.debug_io, environ, testing.allocator, &db, "tree", sink_mod.silent);
    const after = try renderedPlist(prefix);
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "<string>5433</string>") != null);
}

test "register drops the previous formula spec before a registration that fails" {
    // A leftover copy would roll the next `services start` back to it.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var formula = try formula_mod.parseFormula(testing.allocator,
        \\{"name":"tree","full_name":"tree","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"2.2.1"},"dependencies":[],"service":{"run":["$HOMEBREW_PREFIX/opt/tree/bin/tree"],"environment_variables":{"A":"ok\u0000tail"}}}
    );
    defer formula.deinit();

    const prefix = try scratchPrefix();
    defer testing.allocator.free(prefix);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, prefix) catch {};
    const prev = try atomic.overridePrefixEnv(prefix);
    defer atomic.restorePrefixEnv(prev);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const dir = try supervisor_mod.serviceDir(aa, "com.malt.tree");
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, dir);
    const stale = try std.fmt.allocPrint(aa, "{s}/formula.json", .{dir});
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = stale, .data = "{}" });
    try std.Io.Dir.cwd().access(std.Options.debug_io, stale, .{});

    register(std.Options.debug_io, .empty, testing.allocator, &db, &formula, prefix, sink_mod.silent);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.Options.debug_io, stale, .{}));
}
