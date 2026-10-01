//! malt — bundle runner
//!
//! Installs every member of a `Manifest` by routing each item through a
//! caller-supplied `Dispatcher` (in-process) or a fallback `malt` subprocess
//! (when `Options.malt_bin` is set — tests use that to assert exit-code
//! propagation via `/usr/bin/false`). In-process is the production default:
//! it keeps SQLite warm and avoids per-fork output noise. The runner itself
//! depends on no `cli/*` module, so bundle tests link without dragging in
//! the whole CLI surface.
//!
//! core returns outcomes; UI renders at the boundary — `run()` produces a
//! `Report` that the caller (`cli/bundle.zig`) renders via `ui/output.*`.
//!
//! Each underlying primitive (install, tap, services start) is already
//! idempotent, so running a bundle twice is a no-op for already-installed
//! members.

const std = @import("std");
const builtin = @import("builtin");
const sqlite = @import("../../db/sqlite.zig");
const schema = @import("../../db/schema.zig");
const lock_mod = @import("../../db/lock.zig");
const atomic = @import("../../fs/atomic.zig");
const path_component = @import("../../fs/path_component.zig");
const signals = @import("../signals.zig");
const manifest_mod = @import("manifest.zig");

pub const RunnerError = error{
    DatabaseError,
    LockFailed,
    IoFailed,
    OutOfMemory,
    /// Production builds need a `Dispatcher` wired from the CLI layer;
    /// absence means the caller forgot to provide one and we refuse to
    /// silently do nothing.
    NoDispatcher,
    /// The manifest name would leave the bundles directory once formatted
    /// into the lock path.
    UnsafeName,
};

/// Closed error set every dispatcher exit must land on. Kept in
/// `core/bundle/runner.zig` so neither runner nor `cleanup.zig` has to
/// depend on `cli/*` to spell its members' failure modes; the CLI layer
/// narrows underlying CLI errors at the boundary (see `cli/bundle.zig`),
/// keeping the type-system check exhaustive without reverse-layering.
pub const DispatchError = error{
    /// In-process runner needs a dispatcher (and none was wired).
    NoDispatcher,
    /// Subprocess dispatch (`malt_bin`) exited non-zero.
    MemberFailed,
    /// Boundary narrowing tag: the error value carries no cause. Install
    /// members carry it on `MemberError.reason`; the uninstall primitive
    /// behind `cleanup.zig` prints its own.
    DispatchFailed,
    OutOfMemory,
};

pub fn describeError(err: RunnerError) []const u8 {
    return switch (err) {
        RunnerError.DatabaseError => "database error during bundle install",
        RunnerError.LockFailed => "could not acquire bundle lock",
        RunnerError.IoFailed => "filesystem error during bundle install",
        RunnerError.OutOfMemory => "out of memory during bundle install",
        RunnerError.NoDispatcher => "bundle runner called without a dispatcher and without malt_bin",
        RunnerError.UnsafeName => "bundle name is not a valid path component",
    };
}

pub const MemberKind = enum { tap, formula, cask, service_start };

/// First error line a member's install emitted, so the report can say why it
/// failed. Fixed-size and by value: failures stay allocation-free.
pub const MemberReason = struct {
    pub const capacity = 256;

    const State = enum(u8) { empty, header, busy, final };

    buf: [capacity]u8 = undefined,
    len: usize = 0,
    /// Install workers share the sink, so a recorder claims the slot before
    /// writing. Readers only look after `installAll` has joined them.
    state: std.atomic.Value(State) = .init(.empty),

    pub fn record(self: *MemberReason, line: []const u8) void {
        const msg = std.mem.trimStart(u8, line, " \t");
        // A blank line says nothing and must not displace a header.
        if (msg.len == 0) return;
        // A line ending in ':' only introduces the detail below it.
        const next: State = if (std.mem.endsWith(u8, msg, ":")) .header else .final;
        var cur = self.state.load(.acquire);
        while (cur == .empty or cur == .header) {
            cur = self.state.cmpxchgWeak(cur, .busy, .acq_rel, .acquire) orelse {
                var n = @min(msg.len, capacity);
                // Never end on a split codepoint: the terminal sanitizer would see garbage.
                if (n < msg.len) while (n > 0 and (msg[n] & 0xC0) == 0x80) : (n -= 1) {};
                @memcpy(self.buf[0..n], msg[0..n]);
                self.len = n;
                self.state.store(next, .release);
                return;
            };
        }
    }

    pub fn slice(self: *const MemberReason) []const u8 {
        return self.buf[0..self.len];
    }
};

/// One member whose install call returned a non-null error. `name` is
/// borrowed from the caller's `Manifest`; the caller must keep the
/// manifest alive until `Report.deinit`.
pub const MemberError = struct {
    kind: MemberKind,
    name: []const u8,
    err: DispatchError,
    reason: MemberReason = .{},
};

/// Entry in the dry-run preview list — what the CLI would render as
/// "would run: malt …" without actually forking.
pub const MemberPreview = struct {
    kind: MemberKind,
    name: []const u8,
};

/// Structured outcome of a `run()` call. The runner emits no UI; the
/// CLI renders this report via `ui/output.*`.
pub const Report = struct {
    allocator: std.mem.Allocator,
    failures: []MemberError,
    previews: []MemberPreview,
    /// When `recordBundle` failed (non-dry-run only), the `@errorName`
    /// of the cause. Borrowed from `@errorName`, so no free needed.
    db_record_error: ?[]const u8 = null,

    pub fn hasFailure(self: Report) bool {
        return self.failures.len > 0 or self.db_record_error != null;
    }

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.failures);
        self.allocator.free(self.previews);
        self.* = undefined;
    }
};

/// Layering seam: the CLI wires up a concrete implementation that forwards
/// to `cli/install`, `cli/tap`, `cli/services`. Keeping this as an injected
/// interface is what lets `core/bundle/runner.zig` avoid a `cli/*` import.
pub const Dispatcher = struct {
    ctx: ?*anyopaque = null,
    installFormula: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, reason: *MemberReason) DispatchError!void,
    installCask: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, reason: *MemberReason) DispatchError!void,
    tapAdd: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, reason: *MemberReason) DispatchError!void,
    serviceStart: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, reason: *MemberReason) DispatchError!void,
};

pub const Options = struct {
    /// When true, report what would be installed without forking subprocesses.
    dry_run: bool = false,
    /// Override the binary used for member installs. When set, each member
    /// is run via subprocess — test suites use this to substitute
    /// `/usr/bin/false` and assert exit-code propagation. Production
    /// callers leave it null and provide a `dispatcher` instead.
    malt_bin: ?[]const u8 = null,
    /// Override the install prefix used for the bundle lockfile. Tests use
    /// this to keep the lock under their per-test temp directory; production
    /// callers leave it null (which falls back to `MALT_PREFIX`).
    prefix: ?[]const u8 = null,
    /// In-process dispatcher injected from the CLI layer. Null is legal
    /// for `dry_run` and subprocess (`malt_bin`) paths; otherwise the
    /// runner records `NoDispatcher` as each member's failure.
    dispatcher: ?*const Dispatcher = null,
    /// Canonical path of the manifest being installed, recorded so
    /// `bundle remove --purge` can find it again.
    manifest_path: ?[]const u8 = null,
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    manifest: manifest_mod.Manifest,
    opts: Options,
) RunnerError!Report {
    const bundle_name = if (manifest.name.len > 0) manifest.name else "unnamed";
    // Manifest-supplied, and it lands in the lock path below; refuse outright
    // rather than sanitise, before createDirPath grants it any side effect.
    if (!path_component.isPathComponent(bundle_name)) return RunnerError.UnsafeName;

    // Bundles directory + advisory lock for idempotency.
    const prefix: []const u8 = opts.prefix orelse atomic.maltPrefixOrAbort();
    const bundles_dir = std.fmt.allocPrint(allocator, "{s}/var/malt/bundles", .{prefix}) catch
        return RunnerError.OutOfMemory;
    defer allocator.free(bundles_dir);
    // bundles/ may already exist; the lock file create below surfaces real errors.
    std.Io.Dir.cwd().createDirPath(io, bundles_dir) catch {};

    const lock_path = std.fmt.allocPrint(allocator, "{s}/{s}.lock", .{ bundles_dir, bundle_name }) catch
        return RunnerError.OutOfMemory;
    defer allocator.free(lock_path);

    var lock = if (!opts.dry_run)
        (lock_mod.LockFile.acquire(io, lock_path, 5_000) catch return RunnerError.LockFailed)
    else
        null;
    defer if (lock) |*l| l.release(io);

    var failures: std.ArrayList(MemberError) = .empty;
    errdefer failures.deinit(allocator);
    var previews: std.ArrayList(MemberPreview) = .empty;
    errdefer previews.deinit(allocator);

    // 1. taps
    for (manifest.taps) |t| {
        try recordMember(io, allocator, .{ .tap = t }, opts, &failures, &previews);
    }

    // 2. formulas
    for (manifest.formulas) |f| {
        try recordMember(io, allocator, .{ .formula = f.name }, opts, &failures, &previews);
    }

    // 3. casks
    for (manifest.casks) |c| {
        try recordMember(io, allocator, .{ .cask = c.name }, opts, &failures, &previews);
    }

    // 4. services start (auto_start only). Best-effort.
    for (manifest.services) |s| {
        if (!s.auto_start) continue;
        try recordMember(io, allocator, .{ .service_start = s.name }, opts, &failures, &previews);
    }

    var db_record_error: ?[]const u8 = null;
    // 5. Record bundle and members in DB (even on partial failure). Skipped
    //    in dry-run so the preview path stays read-only.
    // An interrupted run installed only part of the manifest; recording it
    // would claim members that never landed.
    if (!opts.dry_run and !signals.isInterrupted()) recordBundle(io, db, manifest, opts.manifest_path) catch |e| {
        // recordBundle's inferred set spans sqlite + clock; keep @errorName.
        db_record_error = @errorName(e);
    };

    // Own each slice before composing the return so an OOM on the second
    // toOwnedSlice cannot orphan the first.
    const owned_failures = failures.toOwnedSlice(allocator) catch return RunnerError.OutOfMemory;
    errdefer allocator.free(owned_failures);
    const owned_previews = previews.toOwnedSlice(allocator) catch return RunnerError.OutOfMemory;

    return .{
        .allocator = allocator,
        .failures = owned_failures,
        .previews = owned_previews,
        .db_record_error = db_record_error,
    };
}

const MemberCall = union(enum) {
    tap: []const u8,
    formula: []const u8,
    cask: []const u8,
    service_start: []const u8,

    fn kind(self: MemberCall) MemberKind {
        return switch (self) {
            .tap => .tap,
            .formula => .formula,
            .cask => .cask,
            .service_start => .service_start,
        };
    }

    fn name(self: MemberCall) []const u8 {
        return switch (self) {
            .tap => |n| n,
            .formula => |n| n,
            .cask => |n| n,
            .service_start => |n| n,
        };
    }
};

fn recordMember(
    io: std.Io,
    allocator: std.mem.Allocator,
    call: MemberCall,
    opts: Options,
    failures: *std.ArrayList(MemberError),
    previews: *std.ArrayList(MemberPreview),
) RunnerError!void {
    // A member is a whole install, so Ctrl-C cannot wait for the manifest to
    // drain. One guard covers all four member loops: the rest fall through.
    if (signals.isInterrupted()) return;

    if (opts.dry_run) {
        previews.append(allocator, .{ .kind = call.kind(), .name = call.name() }) catch
            return RunnerError.OutOfMemory;
        return;
    }

    var reason: MemberReason = .{};
    callMember(io, allocator, call, opts, &reason) catch |e| {
        failures.append(allocator, .{
            .kind = call.kind(),
            .name = call.name(),
            .err = e,
            .reason = reason,
        }) catch return RunnerError.OutOfMemory;
    };
}

fn callMember(io: std.Io, allocator: std.mem.Allocator, call: MemberCall, opts: Options, reason: *MemberReason) DispatchError!void {
    // Test escape hatch: when malt_bin is set, fall back to subprocess so
    // tests can substitute /usr/bin/false to assert exit-code propagation.
    if (opts.malt_bin) |bin| return runSubprocess(io, allocator, bin, call);

    const d = opts.dispatcher orelse return DispatchError.NoDispatcher;
    switch (call) {
        .tap => |n| try d.tapAdd(d.ctx, allocator, n, reason),
        .formula => |n| try d.installFormula(d.ctx, allocator, n, reason),
        .cask => |n| try d.installCask(d.ctx, allocator, n, reason),
        .service_start => |n| try d.serviceStart(d.ctx, allocator, n, reason),
    }
}

fn runSubprocess(io: std.Io, allocator: std.mem.Allocator, bin: []const u8, call: MemberCall) DispatchError!void {
    const argv = buildSubprocessArgv(allocator, bin, call) catch return DispatchError.OutOfMemory;
    defer allocator.free(argv);

    var child = std.process.spawn(io, .{ .argv = argv }) catch return DispatchError.MemberFailed;
    const term = child.wait(io) catch return DispatchError.MemberFailed;
    switch (term) {
        .exited => |code| if (code != 0) return DispatchError.MemberFailed,
        else => return DispatchError.MemberFailed,
    }
}

fn buildSubprocessArgv(allocator: std.mem.Allocator, bin: []const u8, call: MemberCall) ![][]const u8 {
    return switch (call) {
        .tap => |n| try allocator.dupe([]const u8, &.{ bin, "tap", n }),
        .formula => |n| try allocator.dupe([]const u8, &.{ bin, "install", n }),
        .cask => |n| try allocator.dupe([]const u8, &.{ bin, "install", "--cask", n }),
        .service_start => |n| try allocator.dupe([]const u8, &.{ bin, "services", "start", n }),
    };
}

fn recordBundle(
    io: std.Io,
    db: *sqlite.Database,
    manifest: manifest_mod.Manifest,
    manifest_path: ?[]const u8,
) !void {
    try schema.migrate(db);

    try db.beginTransaction();
    errdefer db.rollback();

    try writeBundle(io, db, if (manifest.name.len > 0) manifest.name else "unnamed", manifest_path, manifest);
    try db.commit();
}

/// Records `manifest` as bundle `name`: the row and every member. The one
/// write path for `install` and `import`; the caller owns the transaction,
/// so a failure leaves the previous bundle intact.
pub fn writeBundle(
    io: std.Io,
    db: *sqlite.Database,
    name: []const u8,
    manifest_path: ?[]const u8,
    manifest: manifest_mod.Manifest,
) sqlite.SqliteError!void {
    {
        // An upsert, not REPLACE: the delete half of REPLACE cascades
        // through the members, and the row should change in place.
        var stmt = try db.prepare(
            \\INSERT INTO bundles(name, manifest_path, created_at, version)
            \\VALUES (?, ?, ?, ?)
            \\ON CONFLICT(name) DO UPDATE SET manifest_path = excluded.manifest_path,
            \\  created_at = excluded.created_at, version = excluded.version;
        );
        defer stmt.finalize();
        try stmt.bindText(1, name);
        if (manifest_path) |p| try stmt.bindText(2, p) else try stmt.bindNull(2);
        try stmt.bindInt(3, std.Io.Clock.real.now(io).toSeconds());
        try stmt.bindInt(4, @intCast(manifest.version));
        _ = try stmt.step();
    }
    try replaceMembers(db, name, manifest);
}

fn replaceMembers(db: *sqlite.Database, name: []const u8, manifest: manifest_mod.Manifest) sqlite.SqliteError!void {
    // Clean previous members of this bundle to keep it idempotent. Scoped so
    // its finalize can't reset the error of a later failing insert.
    {
        var del = try db.prepare("DELETE FROM bundle_members WHERE bundle_name = ?;");
        defer del.finalize();
        try del.bindText(1, name);
        _ = try del.step();
    }

    var memb = try db.prepare(
        \\INSERT INTO bundle_members(bundle_name, kind, ref, spec)
        \\VALUES (?, ?, ?, NULL);
    );
    defer memb.finalize();

    for (manifest.taps) |t| {
        try memb.reset();
        try memb.bindText(1, name);
        try memb.bindText(2, "tap");
        try memb.bindText(3, t);
        _ = try memb.step();
    }
    for (manifest.formulas) |f| {
        try memb.reset();
        try memb.bindText(1, name);
        try memb.bindText(2, "formula");
        try memb.bindText(3, f.name);
        _ = try memb.step();
    }
    for (manifest.casks) |c| {
        try memb.reset();
        try memb.bindText(1, name);
        try memb.bindText(2, "cask");
        try memb.bindText(3, c.name);
        _ = try memb.step();
    }
    for (manifest.services) |s| {
        try memb.reset();
        try memb.bindText(1, name);
        try memb.bindText(2, "service");
        try memb.bindText(3, s.name);
        _ = try memb.step();
    }
}

test "replaceMembers swaps one bundle's members for the manifest's and leaves other bundles alone" {
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO bundles(name, manifest_path, created_at, version) VALUES ('a', NULL, 0, 1), ('b', NULL, 0, 1);
        \\INSERT INTO bundle_members(bundle_name, kind, ref) VALUES ('a', 'formula', 'stale'), ('b', 'formula', 'kept');
    );
    var formulas = [_]manifest_mod.FormulaEntry{.{ .name = "wget" }};
    var casks = [_]manifest_mod.CaskEntry{.{ .name = "firefox" }};
    var services = [_]manifest_mod.ServiceEntry{.{ .name = "redis" }};
    var taps = [_][]const u8{"user/repo"};
    var m = manifest_mod.Manifest.init(std.testing.allocator);
    defer m.deinit();
    m.taps = &taps;
    m.formulas = &formulas;
    m.casks = &casks;
    m.services = &services;

    try replaceMembers(&db, "a", m);

    const want = [_][2][]const u8{
        .{ "a", "cask:firefox" },  .{ "a", "formula:wget" }, .{ "a", "service:redis" },
        .{ "a", "tap:user/repo" }, .{ "b", "formula:kept" },
    };
    var stmt = try db.prepare("SELECT bundle_name, kind || ':' || ref FROM bundle_members ORDER BY 1, 2;");
    defer stmt.finalize();
    for (want) |w| {
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings(w[0], std.mem.sliceTo(stmt.columnText(0).?, 0));
        try std.testing.expectEqualStrings(w[1], std.mem.sliceTo(stmt.columnText(1).?, 0));
    }
    try std.testing.expect(!try stmt.step());
}

test "describeError gives every tag a distinct, non-empty message" {
    const tags = [_]RunnerError{
        RunnerError.DatabaseError, RunnerError.LockFailed,   RunnerError.IoFailed,
        RunnerError.OutOfMemory,   RunnerError.NoDispatcher, RunnerError.UnsafeName,
    };
    for (tags, 0..) |a, i| {
        try std.testing.expect(describeError(a).len > 0);
        for (tags[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, describeError(a), describeError(b)));
        }
    }
}

test "MemberReason keeps the first message and ignores later ones" {
    var r: MemberReason = .{};
    try std.testing.expectEqualStrings("", r.slice());
    r.record("offline mode: formula 'a' not cached");
    r.record("second line");
    try std.testing.expectEqualStrings("offline mode: formula 'a' not cached", r.slice());
}

test "MemberReason gives a trailing-colon header way to the detail line below it" {
    // A header alone ("N conflict(s) detected:") names no cause.
    var r: MemberReason = .{};
    r.record("foo: 2 symlink conflict(s) detected:");
    r.record("  bin/foo already linked by Cellar/bar/1.0");
    r.record("Uninstall the conflicting package first.");
    try std.testing.expectEqualStrings("bin/foo already linked by Cellar/bar/1.0", r.slice());

    // With no detail after it, the header is still better than nothing.
    var lone: MemberReason = .{};
    lone.record("foo: failed:");
    try std.testing.expectEqualStrings("foo: failed:", lone.slice());

    lone.record("   ");
    try std.testing.expectEqualStrings("foo: failed:", lone.slice());
}

test "MemberReason drops the indentation of a sub-line" {
    var r: MemberReason = .{};
    r.record("  \tfoo: DownloadFailed (after 3 attempts)");
    try std.testing.expectEqualStrings("foo: DownloadFailed (after 3 attempts)", r.slice());
}

test "MemberReason truncates at the buffer size on a UTF-8 boundary" {
    var r: MemberReason = .{};
    // A 2-byte codepoint straddling the cap must be dropped whole.
    var msg: [MemberReason.capacity + 1]u8 = undefined;
    @memset(msg[0 .. MemberReason.capacity - 1], 'a');
    msg[MemberReason.capacity - 1] = 0xC3;
    msg[MemberReason.capacity] = 0xA9;
    r.record(&msg);
    try std.testing.expectEqual(MemberReason.capacity - 1, r.slice().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.slice()));

    // A message that exactly fills the buffer is kept whole.
    var exact: MemberReason = .{};
    @memset(&msg, 'b');
    exact.record(msg[0..MemberReason.capacity]);
    try std.testing.expectEqual(MemberReason.capacity, exact.slice().len);

    // A 4-byte codepoint cut after its second byte backs off past all of it.
    var wide: [MemberReason.capacity + 2]u8 = undefined;
    @memset(wide[0 .. MemberReason.capacity - 2], 'c');
    @memcpy(wide[MemberReason.capacity - 2 ..], "\u{1F37A}");
    var w: MemberReason = .{};
    w.record(&wide);
    try std.testing.expectEqual(MemberReason.capacity - 2, w.slice().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(w.slice()));
}

test "MemberReason: concurrent recorders leave exactly one whole message" {
    // Install workers share the sink, so racing errs must never interleave.
    const msgs = [_][]const u8{ "first worker failed", "second worker failed", "third worker failed", "fourth worker failed" };
    var r: MemberReason = .{};
    var threads: [msgs.len]std.Thread = undefined;
    for (&threads, msgs) |*t, m| t.* = try std.Thread.spawn(.{}, MemberReason.record, .{ &r, m });
    for (threads) |t| t.join();
    for (msgs) |m| {
        if (std.mem.eql(u8, r.slice(), m)) return;
    }
    return error.TestUnexpectedResult;
}

const ReasonMock = struct {
    fn failWithReason(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, reason: *MemberReason) DispatchError!void {
        reason.record("offline mode: formula 'x' not cached");
        return DispatchError.DispatchFailed;
    }
    fn failSilently(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: *MemberReason) DispatchError!void {
        return DispatchError.DispatchFailed;
    }
    fn succeedAfterNote(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, reason: *MemberReason) DispatchError!void {
        reason.record("noise");
    }
};

test "recordMember carries the dispatcher's reason onto the failure" {
    const d: Dispatcher = .{
        .installFormula = ReasonMock.failWithReason,
        .installCask = ReasonMock.failSilently,
        .tapAdd = ReasonMock.succeedAfterNote,
        .serviceStart = ReasonMock.failSilently,
    };
    const opts: Options = .{ .dispatcher = &d };
    const a = std.testing.allocator;
    var failures: std.ArrayList(MemberError) = .empty;
    defer failures.deinit(a);
    var previews: std.ArrayList(MemberPreview) = .empty;
    defer previews.deinit(a);

    try recordMember(std.Options.debug_io, a, .{ .formula = "x" }, opts, &failures, &previews);
    try recordMember(std.Options.debug_io, a, .{ .cask = "y" }, opts, &failures, &previews);
    // A member that succeeds is not a failure, whatever it reported.
    try recordMember(std.Options.debug_io, a, .{ .tap = "z" }, opts, &failures, &previews);

    try std.testing.expectEqual(@as(usize, 2), failures.items.len);
    try std.testing.expectEqualStrings("offline mode: formula 'x' not cached", failures.items[0].reason.slice());
    // No reason recorded: the per-member slot starts empty, not stale.
    try std.testing.expectEqualStrings("", failures.items[1].reason.slice());
}
