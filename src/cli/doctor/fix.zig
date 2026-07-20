//! malt — `mt doctor --fix` planner and executor.
//!
//! The planner is pure (no I/O) so the safe-vs-manual policy is unit-
//! testable; the executor wires it to the existing purge helpers and
//! filesystem primitives.

const std = @import("std");
const lock_mod = @import("../../db/lock.zig");
const sqlite = @import("../../db/sqlite.zig");

/// Auto-fix classes that are reversible and never touch user data.
pub const FixKind = enum { stale_lock, orphaned_store, broken_symlinks };

/// Classes severe enough that we never auto-run; doctor still prints
/// the manual command for the user to run themselves.
pub const ManualKind = enum {
    corrupt_database,
    missing_kegs,
    missing_directories,
    weak_permissions,
    mach_o_placeholders,
};

/// Observed health-check conditions. Boolean/count flags so the
/// planner stays pure and trivially testable.
pub const Conditions = struct {
    stale_lock: bool = false,
    orphan_store_count: u32 = 0,
    broken_symlink_count: u32 = 0,

    db_corrupt: bool = false,
    missing_kegs: bool = false,
    missing_dirs: bool = false,
    weak_permissions: bool = false,
    mach_o_placeholders: bool = false,
};

pub const Plan = struct {
    safe: std.EnumSet(FixKind) = .initEmpty(),
    manual: std.EnumSet(ManualKind) = .initEmpty(),

    pub fn isEmpty(self: Plan) bool {
        return self.safe.count() == 0 and self.manual.count() == 0;
    }

    /// Narrow a plan to a single safe class — the `--fix <id>` selector.
    /// Manual hints are dropped: a targeted fix reports only its class,
    /// not unrelated remediation noise.
    pub fn onlySafe(self: Plan, kind: FixKind) Plan {
        var p: Plan = .{};
        if (self.safe.contains(kind)) p.safe.insert(kind);
        return p;
    }
};

/// Pure: route conditions to the safe-fix set or the manual-command
/// set. Adding a new check means adding a flag here, never widening
/// the safe set without explicit policy review.
pub fn planFixes(c: Conditions) Plan {
    var plan: Plan = .{};
    if (c.stale_lock) plan.safe.insert(.stale_lock);
    if (c.orphan_store_count > 0) plan.safe.insert(.orphaned_store);
    if (c.broken_symlink_count > 0) plan.safe.insert(.broken_symlinks);

    if (c.db_corrupt) plan.manual.insert(.corrupt_database);
    if (c.missing_kegs) plan.manual.insert(.missing_kegs);
    if (c.missing_dirs) plan.manual.insert(.missing_directories);
    if (c.weak_permissions) plan.manual.insert(.weak_permissions);
    if (c.mach_o_placeholders) plan.manual.insert(.mach_o_placeholders);

    return plan;
}

// ── probes ──────────────────────────────────────────────────────────
//
// Probes mirror the cheap subset of the doctor walker, kept here so
// `--fix` does not depend on the UI-emitting check bodies.

const StaleLockState = enum { absent, live, stale };

fn probeStaleLockState(io: std.Io, prefix: []const u8) StaleLockState {
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch return .absent;
    const pid = lock_mod.LockFile.holderPid(io, lock_path) orelse return .absent;
    const is_alive = std.c.kill(pid, @enumFromInt(0)) == 0;
    return if (is_alive) .live else .stale;
}

/// True when the lock file holds a PID that no longer exists.
pub fn probeStaleLock(io: std.Io, prefix: []const u8) bool {
    return probeStaleLockState(io, prefix) == .stale;
}

/// Count broken symlinks under the prefix's link directories without
/// modifying anything. Mirrors the doctor check's traversal.
pub fn probeBrokenSymlinks(io: std.Io, prefix: []const u8) u32 {
    return walkBrokenSymlinks(io, prefix, false);
}

/// Walk the same directories the doctor check inspects and unlink each
/// broken symlink. Returns the number actually removed.
pub fn fixBrokenSymlinks(io: std.Io, prefix: []const u8) u32 {
    return walkBrokenSymlinks(io, prefix, true);
}

/// A broken symlink is one whose target genuinely does not exist. Any other
/// `statFile` failure (AccessDenied, …) means "can't tell" — the link is live,
/// so it must be left intact. Shared by the fix walk and the doctor check so
/// the two cannot drift into report-vs-remove disagreement.
pub fn isDanglingLinkError(err: anyerror) bool {
    return err == error.FileNotFound;
}

const link_dirs = [_][]const u8{ "bin", "lib", "include", "share", "sbin" };

/// Visit every *dangling* symlink under the prefix's link dirs: one target is
/// resolved per entry and only `FileNotFound` counts, so an inaccessible-but-
/// intact link is skipped. `visit` receives the open dir plus the subdir/name
/// pair. The single traversal behind both the fix walk and the doctor check, so
/// the two cannot report different link sets.
pub fn forEachBrokenSymlink(
    io: std.Io,
    prefix: []const u8,
    context: anytype,
    comptime visit: fn (@TypeOf(context), dir: std.Io.Dir, subdir: []const u8, name: []const u8) void,
) void {
    for (link_dirs) |subdir| {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ prefix, subdir }) catch continue;
        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .sym_link) continue;
            _ = dir.statFile(io, entry.name, .{}) catch |err| {
                if (isDanglingLinkError(err)) visit(context, dir, subdir, entry.name);
                continue;
            };
        }
    }
}

fn walkBrokenSymlinks(io: std.Io, prefix: []const u8, do_remove: bool) u32 {
    const Sweep = struct {
        io: std.Io,
        do_remove: bool,
        count: u32 = 0,
        fn visit(self: *@This(), dir: std.Io.Dir, _: []const u8, name: []const u8) void {
            // A link we cannot unlink was not removed — don't count it.
            if (self.do_remove) dir.deleteFile(self.io, name) catch return;
            self.count += 1;
        }
    };
    var sweep = Sweep{ .io = io, .do_remove = do_remove };
    forEachBrokenSymlink(io, prefix, &sweep, Sweep.visit);
    return sweep.count;
}

/// Clear the prefix's stale lock in place when its PID is dead — truncate,
/// never unlink, mirroring `LockFile.release`. Idempotent: a missing or live
/// lock file is a no-op (returns false).
pub fn fixStaleLock(io: std.Io, prefix: []const u8) bool {
    if (probeStaleLockState(io, prefix) != .stale) return false;
    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{prefix}) catch return false;
    // Unlinking would break flock exclusion: the inode is the lock identity.
    const file = std.Io.Dir.openFileAbsolute(io, lock_path, .{ .mode = .write_only }) catch return false;
    defer file.close(io);
    lock_mod.LockFile.clearInPlace(io, file) catch return false;
    return true;
}

/// Count orphaned store directories (entry on disk whose `store_refs`
/// refcount has dropped to <= 0). Shares one definition with the inline
/// doctor check and `purge --store-orphans` so all three report the same
/// entries.
pub fn probeOrphanedStoreCount(io: std.Io, prefix: []const u8) u32 {
    return walkOrphans(io, prefix, false).count;
}

/// Outcome of an orphan walk. Probe (`do_remove = false`): `count` is the
/// number of orphans detected, `blocked` is always 0. Reap (`do_remove =
/// true`): `count` is the number de-referenced (entry renamed out of the store
/// namespace and its ref row cleared, regardless of whether every byte was then
/// reclaimed); `blocked` is the number whose *entry dir* could not even be
/// renamed aside (permissions, an immutable entry dir), leaving it referenced.
/// A surviving immutable *child* is not blocked — the entry is already
/// de-referenced, so it counts as removed and the leftover bytes are a reclaim
/// concern, not store corruption. `reason` names the blocker so `--fix` can
/// explain a partial sweep rather than report a silent no-op.
pub const OrphanSweep = struct {
    count: u32 = 0,
    blocked: u32 = 0,
    reason: ?[]const u8 = null,
};

/// Sweep orphan store directories and clear their `store_refs` rows so
/// repeated `--fix` runs converge to zero. An orphan that cannot be removed
/// is surfaced via `blocked`/`reason`, not skipped silently — a blocked fix
/// must never be mistaken for a clean prefix.
pub fn fixOrphanedStore(io: std.Io, prefix: []const u8) OrphanSweep {
    return walkOrphans(io, prefix, true);
}

fn walkOrphans(io: std.Io, prefix: []const u8, do_remove: bool) OrphanSweep {
    var result: OrphanSweep = .{};
    // Reclaim `.malt-reap-*` leftovers from a prior sweep whose byte reclaim was
    // blocked, so un-reapable bytes cannot leak across runs. Reap path only — a
    // read-only probe must never mutate disk.
    if (do_remove) reapStaleLeftovers(io, prefix);

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return result;
    var db = sqlite.Database.open(db_path) catch return result;
    defer db.close();

    // Prepare the orphan-classification statement once, drive it per entry.
    var probe = OrphanProbe.init(&db) catch return result;
    defer probe.deinit();

    var store_path_buf: [512]u8 = undefined;
    const store_path = std.fmt.bufPrint(&store_path_buf, "{s}/store", .{prefix}) catch return result;
    var store_dir = std.Io.Dir.openDirAbsolute(io, store_path, .{ .iterate = true }) catch return result;
    defer store_dir.close(io);

    var iter = store_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (!probe.isOrphan(entry.name)) continue;
        if (do_remove and !removeEntry(io, prefix, &db, entry.name)) {
            result.blocked += 1;
            if (result.reason == null) result.reason = "could not remove store entry";
            continue;
        }
        result.count += 1;
    }
    return result;
}

/// Best-effort removal of `.malt-reap-*` staging dirs a previous sweep renamed
/// aside but could not fully delete (immutable child). Housekeeping, not an
/// orphan sweep — never counted. In-pass deletion mirrors `forEachBrokenSymlink`.
fn reapStaleLeftovers(io: std.Io, prefix: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, prefix, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, ".malt-reap-")) continue;
        var path_buf: [768]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ prefix, entry.name }) catch continue;
        std.Io.Dir.cwd().deleteTree(io, p) catch {};
    }
}

/// How many staging names to probe before giving up. Only a stranded
/// `.malt-reap-*` (an immutable child a prior sweep could not reclaim) occupies
/// a candidate, so one or two suffice in practice; the cap is a safety bound.
const reap_name_attempts: u8 = 16;

/// Remove one orphan's store dir and clear its ref row. Returns false when the
/// entry could not be de-referenced (an undeletable *entry dir* — permissions,
/// immutable flag), so the caller can report it as blocked.
///
/// `deleteTree` is non-atomic: a mid-tree failure on an undeletable *child* used
/// to leave the entry half-emptied while its ref row survived — a corrupt entry
/// the DB still called valid. Renaming the entry out of the referenced path
/// first makes the removal atomic from the ref row's view: once renamed, the row
/// is cleared and any surviving bytes are unreferenced junk, never a corrupt
/// referenced entry. Reap names are siblings of `store/` (never visited by its
/// iteration, same filesystem → no CrossDevice) and probed for a free slot so a
/// prior stranded leftover cannot block an otherwise-deletable entry.
fn removeEntry(io: std.Io, prefix: []const u8, db: *sqlite.Database, name: []const u8) bool {
    var entry_buf: [768]u8 = undefined;
    const entry_path = std.fmt.bufPrint(&entry_buf, "{s}/store/{s}", .{ prefix, name }) catch return false;

    var reap_buf: [768]u8 = undefined;
    var attempt: u8 = 0;
    const reap_path = while (attempt < reap_name_attempts) : (attempt += 1) {
        const candidate = (if (attempt == 0)
            std.fmt.bufPrint(&reap_buf, "{s}/.malt-reap-{s}", .{ prefix, name })
        else
            std.fmt.bufPrint(&reap_buf, "{s}/.malt-reap-{s}-{d}", .{ prefix, name, attempt })) catch return false;
        std.Io.Dir.renameAbsolute(entry_path, candidate, io) catch |e| switch (e) {
            // A non-empty stranded staging dir holds this name — try the next.
            error.DirNotEmpty => continue,
            // Undeletable entry dir (permissions/immutable): genuinely blocked.
            else => return false,
        };
        break candidate;
    } else return false;

    deleteRefRow(db, name);
    // Best-effort byte reclaim; a surviving immutable child is left unreferenced.
    std.Io.Dir.cwd().deleteTree(io, reap_path) catch {};
    return true;
}

/// A store entry is a purgeable orphan iff its `store_refs` row exists and
/// its refcount has dropped to <= 0 — the predicate `Store.orphans()` /
/// `purge --store-orphans` use. A *missing* row is a warm / in-flight commit
/// (`--download-only`, or an install interrupted before the ref is taken);
/// purge cannot clear it, so it is not an orphan. Detection and remediation
/// share this single definition.
pub fn isPurgeableOrphan(has_row: bool, refcount: i64) bool {
    return has_row and refcount <= 0;
}

/// Owns the orphan-classification statement so a sweep prepares it once and
/// drives it per entry via `reset` + rebind, instead of re-preparing the same
/// SQL for every store row. Borrows the `Database` (holds only the statement),
/// so the caller must keep `db` alive for the probe's lifetime.
pub const OrphanProbe = struct {
    stmt: sqlite.Statement,

    pub fn init(db: *sqlite.Database) sqlite.SqliteError!OrphanProbe {
        return .{ .stmt = try db.prepare("SELECT refcount FROM store_refs WHERE store_sha256 = ?1;") };
    }

    pub fn deinit(self: *OrphanProbe) void {
        self.stmt.finalize();
    }

    /// Classify one store entry. Fails closed to "not an orphan" on any DB
    /// error, preserving the reap loop's swallow-and-skip posture.
    pub fn isOrphan(self: *OrphanProbe, sha: []const u8) bool {
        self.stmt.reset() catch return false;
        self.stmt.bindText(1, sha) catch return false;
        const has_row = self.stmt.step() catch return false;
        const refcount: i64 = if (has_row) self.stmt.columnInt(0) else 0;
        return isPurgeableOrphan(has_row, refcount);
    }
};

fn deleteRefRow(db: *sqlite.Database, sha: []const u8) void {
    var stmt = db.prepare("DELETE FROM store_refs WHERE store_sha256 = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, sha) catch return;
    _ = stmt.step() catch {};
}

// ── flag parsing ────────────────────────────────────────────────────

/// How `--fix` was invoked. `--fix` alone applies every safe class
/// (today's behaviour); `--fix <id>` targets one class so the Doctor
/// tab can remediate just the finding under the cursor.
pub const FixRequest = union(enum) {
    /// `--fix` absent: doctor runs check-only.
    none,
    /// `--fix` with no id: apply every safe class.
    all,
    /// `--fix <id>`: apply only the named class. The id is validated
    /// against the published vocabulary by the caller.
    one: []const u8,

    pub fn isRequested(self: FixRequest) bool {
        return switch (self) {
            .none => false,
            .all, .one => true,
        };
    }
};

/// Parse the `--fix` selector from argv. The id is the token immediately
/// after `--fix` when it isn't another flag; a trailing `--fix` or one
/// followed by a flag is apply-all.
pub fn parseFix(args: []const []const u8) FixRequest {
    for (args, 0..) |a, i| {
        if (!std.mem.eql(u8, a, "--fix")) continue;
        if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
            return .{ .one = args[i + 1] };
        }
        return .all;
    }
    return .none;
}

// ── render ──────────────────────────────────────────────────────────
//
// Plan output stays consistent with the doctor row indent ("  ") so a
// `--fix --dry-run` block reads like an extension of the check list.

/// Imperative description of a safe-class fix, used for both the
/// dry-run plan and the post-action confirmation.
pub fn safeLabel(kind: FixKind) []const u8 {
    return switch (kind) {
        .stale_lock => "clear stale lock file",
        .orphaned_store => "sweep orphaned store entries",
        .broken_symlinks => "unlink broken symlinks under prefix",
    };
}

/// One-line manual-remediation hint for a dangerous class. Mirrors the
/// inline check-row hints (e.g. "Reinstall the affected packages") so
/// users see a single consistent voice.
pub fn manualHint(kind: ManualKind) []const u8 {
    return switch (kind) {
        .corrupt_database => "corrupt database — restore from backup or reinstall malt",
        .missing_kegs => "missing kegs — reinstall the affected packages",
        .missing_directories => "missing prefix directories — reinitialise the prefix",
        .weak_permissions => "weak permissions — review with `ls -l` and `chmod`",
        .mach_o_placeholders => "unpatched Mach-O placeholders — reinstall the affected packages",
    };
}

/// Render the plan deterministically. `dry_run` selects the verb tense
/// ("would" vs imperative). Pure: writer-based so tests assert bytes.
pub fn renderPlan(writer: *std.Io.Writer, plan: Plan, dry_run: bool) !void {
    if (plan.safe.count() == 0) {
        try writer.writeAll("  no safe-class fixes to apply\n");
    } else {
        try writer.writeAll(if (dry_run) "  would apply:\n" else "  applying:\n");
        var it = plan.safe.iterator();
        while (it.next()) |kind| {
            try writer.writeAll("    - ");
            try writer.writeAll(safeLabel(kind));
            try writer.writeAll("\n");
        }
    }

    if (plan.manual.count() == 0) return;
    try writer.writeAll("  manual action required:\n");
    var mit = plan.manual.iterator();
    while (mit.next()) |kind| {
        try writer.writeAll("  ");
        try writer.writeAll(manualHint(kind));
        try writer.writeAll("\n");
    }
}

// ── executor ────────────────────────────────────────────────────────

pub const FixCtx = struct {
    prefix: []const u8,
    io: std.Io,
    /// Pre-computed conditions; when null, the executor probes the
    /// safe-class conditions itself. Tests inject explicit conditions
    /// (including dangerous classes) without requiring a real prefix.
    conditions: ?Conditions = null,
    /// `--fix <id>` selector: when set, only this safe class is applied
    /// and reported. `null` is apply-all (the same executor, no filter).
    only: ?FixKind = null,
};

pub const FixOutcome = struct {
    plan: Plan,
    stale_lock_removed: bool = false,
    orphans_removed: u32 = 0,
    /// Orphans detected but not removable, with the blocker's reason — so a
    /// partial sweep is reported instead of read as "nothing to do".
    orphans_blocked: u32 = 0,
    orphans_block_reason: ?[]const u8 = null,
    broken_symlinks_removed: u32 = 0,
    /// Why the prefix-mutating sweeps were skipped, when they were: `Timeout` =
    /// a live op holds the lock; `DirMissing` = no db/ (nothing installed); the
    /// acquire failures are surfaced by the caller.
    mutations_skipped: ?lock_mod.LockError = null,

    pub fn fixesApplied(self: FixOutcome) u32 {
        var n: u32 = 0;
        if (self.stale_lock_removed) n += 1;
        n += self.orphans_removed;
        n += self.broken_symlinks_removed;
        return n;
    }
};

/// `stale_lock` is repaired without the lock (a dead holder has nothing to
/// serialize against); the two prefix mutations must run behind `malt.lock`.
fn requiresPrefixLock(kind: FixKind) bool {
    return switch (kind) {
        .stale_lock => false,
        .orphaned_store, .broken_symlinks => true,
    };
}

fn planNeedsPrefixLock(plan: Plan) bool {
    var it = plan.safe.iterator();
    while (it.next()) |kind| if (requiresPrefixLock(kind)) return true;
    return false;
}

/// Non-blocking single pass: doctor-fix skips fast, never waits behind a
/// live install (contrast uninstall's multi-second wait).
const fix_lock_timeout_ms: u32 = 0;

/// Drive the safe-fix policy end-to-end in three ordered steps. Pure of UI:
/// the caller emits styled lines from the returned outcome. In `dry_run`
/// mode no filesystem mutation happens.
pub fn executeFix(ctx: FixCtx, dry_run: bool) FixOutcome {
    const conditions: Conditions = ctx.conditions orelse .{
        .stale_lock = probeStaleLock(ctx.io, ctx.prefix),
        .orphan_store_count = probeOrphanedStoreCount(ctx.io, ctx.prefix),
        .broken_symlink_count = probeBrokenSymlinks(ctx.io, ctx.prefix),
    };
    // `--fix <id>` narrows the same plan to one class; apply-all leaves
    // the filter empty so this is the identical code path.
    const plan = if (ctx.only) |kind| planFixes(conditions).onlySafe(kind) else planFixes(conditions);

    var outcome: FixOutcome = .{ .plan = plan };
    // Early return keeps the acquire after it: `--fix --dry-run` never
    // touches the lock.
    if (dry_run) return outcome;

    // Step 1: reconcile the stale lock outside any held region — no acquire.
    if (plan.safe.contains(.stale_lock)) {
        outcome.stale_lock_removed = fixStaleLock(ctx.io, ctx.prefix);
    }

    // Step 2: the prefix-mutating classes run only while `malt.lock` is held.
    if (!planNeedsPrefixLock(plan)) return outcome;

    var lock_buf: [512]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/db/malt.lock", .{ctx.prefix}) catch return outcome;
    // The acquire IS the gate — do NOT re-probe `operationInFlight` first,
    // which would reopen the TOCTOU this closes.
    var lock = lock_mod.LockFile.acquire(ctx.io, lock_path, fix_lock_timeout_ms) catch |e| {
        // Any skip reason — live op, fresh prefix, or a real failure — is
        // recorded so the caller reports it, never a silent no-op.
        outcome.mutations_skipped = e;
        return outcome;
    };
    defer lock.release(ctx.io);

    if (plan.safe.contains(.orphaned_store)) {
        const sweep = fixOrphanedStore(ctx.io, ctx.prefix);
        outcome.orphans_removed = sweep.count;
        outcome.orphans_blocked = sweep.blocked;
        outcome.orphans_block_reason = sweep.reason;
    }
    if (plan.safe.contains(.broken_symlinks)) {
        outcome.broken_symlinks_removed = fixBrokenSymlinks(ctx.io, ctx.prefix);
    }
    return outcome;
}

// ── inline tests ─────────────────────────────────────────────────────

test "planFixes: clean conditions yield empty plan" {
    const plan = planFixes(.{});
    try std.testing.expect(plan.isEmpty());
}

test "FixOutcome: a blocked orphan is not an applied fix yet stays distinguishable from clean" {
    const plan = planFixes(.{});
    const clean: FixOutcome = .{ .plan = plan };
    const blocked: FixOutcome = .{
        .plan = plan,
        .orphans_blocked = 1,
        .orphans_block_reason = "could not remove store entry",
    };
    // A blocked entry was not removed, so it is not an applied fix.
    try std.testing.expectEqual(@as(u32, 0), clean.fixesApplied());
    try std.testing.expectEqual(@as(u32, 0), blocked.fixesApplied());
    // But the blocked outcome is legible: it carries a reason the clean one lacks.
    try std.testing.expect(clean.orphans_block_reason == null);
    try std.testing.expect(blocked.orphans_block_reason != null);
}

test "planFixes: stale lock joins the safe-fix set" {
    const plan = planFixes(.{ .stale_lock = true });
    try std.testing.expect(plan.safe.contains(.stale_lock));
    try std.testing.expectEqual(@as(usize, 0), plan.manual.count());
}

test "planFixes: any orphan count flips orphaned_store on" {
    const plan = planFixes(.{ .orphan_store_count = 1 });
    try std.testing.expect(plan.safe.contains(.orphaned_store));
}

test "planFixes: any broken-symlink count flips broken_symlinks on" {
    const plan = planFixes(.{ .broken_symlink_count = 4 });
    try std.testing.expect(plan.safe.contains(.broken_symlinks));
}

test "planFixes: zero orphan count does not flip orphaned_store" {
    const plan = planFixes(.{ .orphan_store_count = 0 });
    try std.testing.expect(!plan.safe.contains(.orphaned_store));
}

test "planFixes: corrupt DB is manual-only" {
    const plan = planFixes(.{ .db_corrupt = true });
    try std.testing.expectEqual(@as(usize, 0), plan.safe.count());
    try std.testing.expect(plan.manual.contains(.corrupt_database));
}

test "planFixes: missing kegs are manual-only" {
    const plan = planFixes(.{ .missing_kegs = true });
    try std.testing.expect(plan.manual.contains(.missing_kegs));
    try std.testing.expectEqual(@as(usize, 0), plan.safe.count());
}

test "planFixes: weak permissions stay manual" {
    const plan = planFixes(.{ .weak_permissions = true });
    try std.testing.expect(plan.manual.contains(.weak_permissions));
}

test "planFixes: missing directories stay manual" {
    const plan = planFixes(.{ .missing_dirs = true });
    try std.testing.expect(plan.manual.contains(.missing_directories));
}

test "planFixes: unpatched Mach-O placeholders stay manual" {
    const plan = planFixes(.{ .mach_o_placeholders = true });
    try std.testing.expect(plan.manual.contains(.mach_o_placeholders));
}

test "planFixes: safe and manual sets coexist" {
    const plan = planFixes(.{
        .stale_lock = true,
        .orphan_store_count = 2,
        .db_corrupt = true,
    });
    try std.testing.expect(plan.safe.contains(.stale_lock));
    try std.testing.expect(plan.safe.contains(.orphaned_store));
    try std.testing.expect(plan.manual.contains(.corrupt_database));
    try std.testing.expect(!plan.isEmpty());
}

test "onlySafe: keeps the targeted class, drops the other safe classes" {
    const plan = planFixes(.{ .stale_lock = true, .broken_symlink_count = 3 });
    const narrowed = plan.onlySafe(.stale_lock);
    try std.testing.expect(narrowed.safe.contains(.stale_lock));
    try std.testing.expect(!narrowed.safe.contains(.broken_symlinks));
    try std.testing.expectEqual(@as(usize, 1), narrowed.safe.count());
}

test "onlySafe: a class not in the plan yields an empty plan" {
    const plan = planFixes(.{ .stale_lock = true });
    const narrowed = plan.onlySafe(.orphaned_store);
    try std.testing.expect(narrowed.isEmpty());
}

test "onlySafe: drops manual hints so a targeted fix reports only its class" {
    const plan = planFixes(.{ .stale_lock = true, .db_corrupt = true });
    const narrowed = plan.onlySafe(.stale_lock);
    try std.testing.expect(narrowed.safe.contains(.stale_lock));
    try std.testing.expectEqual(@as(usize, 0), narrowed.manual.count());
}

fn renderToBuf(plan: Plan, dry_run: bool, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try renderPlan(&w, plan, dry_run);
    return w.buffered();
}

test "renderPlan: empty plan reports nothing to apply" {
    var buf: [256]u8 = undefined;
    const out = try renderToBuf(.{}, false, &buf);
    try std.testing.expectEqualStrings("  no safe-class fixes to apply\n", out);
}

test "renderPlan: dry-run uses 'would apply' verb" {
    var buf: [512]u8 = undefined;
    const plan = planFixes(.{ .stale_lock = true });
    const out = try renderToBuf(plan, true, &buf);
    try std.testing.expectEqualStrings(
        "  would apply:\n    - clear stale lock file\n",
        out,
    );
}

test "renderPlan: live run uses imperative 'applying' verb" {
    var buf: [512]u8 = undefined;
    const plan = planFixes(.{ .broken_symlink_count = 1 });
    const out = try renderToBuf(plan, false, &buf);
    try std.testing.expectEqualStrings(
        "  applying:\n    - unlink broken symlinks under prefix\n",
        out,
    );
}

test "renderPlan: manual section follows safe section" {
    var buf: [1024]u8 = undefined;
    const plan = planFixes(.{ .stale_lock = true, .db_corrupt = true });
    const out = try renderToBuf(plan, true, &buf);
    try std.testing.expectEqualStrings(
        "  would apply:\n" ++
            "    - clear stale lock file\n" ++
            "  manual action required:\n" ++
            "  corrupt database — restore from backup or reinstall malt\n",
        out,
    );
}

test "renderPlan: manual-only plan still emits the empty-safe header" {
    var buf: [1024]u8 = undefined;
    const plan = planFixes(.{ .missing_kegs = true });
    const out = try renderToBuf(plan, false, &buf);
    try std.testing.expectEqualStrings(
        "  no safe-class fixes to apply\n" ++
            "  manual action required:\n" ++
            "  missing kegs — reinstall the affected packages\n",
        out,
    );
}

test "renderPlan: every safe-fix kind has a label" {
    inline for (std.meta.fields(FixKind)) |f| {
        const kind: FixKind = @field(FixKind, f.name);
        try std.testing.expect(safeLabel(kind).len > 0);
    }
}

test "renderPlan: every manual kind has a hint" {
    inline for (std.meta.fields(ManualKind)) |f| {
        const kind: ManualKind = @field(ManualKind, f.name);
        try std.testing.expect(manualHint(kind).len > 0);
    }
}

test "parseFix: empty argv is check-only" {
    try std.testing.expect(parseFix(&.{}) == .none);
    try std.testing.expect(!parseFix(&.{}).isRequested());
}

test "parseFix: bare --fix is apply-all" {
    try std.testing.expect(parseFix(&.{"--fix"}) == .all);
    try std.testing.expect(parseFix(&.{"--fix"}).isRequested());
}

test "parseFix: only the exact flag matches" {
    try std.testing.expect(parseFix(&.{"--fixxx"}) == .none);
    try std.testing.expect(parseFix(&.{"fix"}) == .none);
}

test "parseFix: --fix position does not matter" {
    try std.testing.expect(parseFix(&.{ "--quiet", "--fix" }) == .all);
}

test "parseFix: --fix <id> captures the id" {
    const req = parseFix(&.{ "--fix", "stale_lock" });
    try std.testing.expect(req == .one);
    try std.testing.expectEqualStrings("stale_lock", req.one);
}

test "parseFix: a flag after --fix is apply-all, not an id" {
    // `--fix --verbose` must not read `--verbose` as a finding id.
    try std.testing.expect(parseFix(&.{ "--fix", "--verbose" }) == .all);
}

test "parseFix: an empty-string id is captured (caller rejects it as unknown)" {
    const req = parseFix(&.{ "--fix", "" });
    try std.testing.expect(req == .one);
    try std.testing.expectEqualStrings("", req.one);
}

test "executeFix: dry run does not touch filesystem state" {
    const outcome = executeFix(
        .{
            .prefix = "/nonexistent/malt/prefix",
            .io = std.Options.debug_io,
            .conditions = .{ .stale_lock = true, .broken_symlink_count = 1 },
        },
        true,
    );
    try std.testing.expectEqual(@as(u32, 0), outcome.fixesApplied());
    try std.testing.expect(outcome.plan.safe.contains(.stale_lock));
}

test "executeFix: empty conditions yield an empty plan" {
    const outcome = executeFix(
        .{
            .prefix = "/nonexistent",
            .io = std.Options.debug_io,
            .conditions = .{},
        },
        false,
    );
    try std.testing.expectEqual(@as(u32, 0), outcome.fixesApplied());
    try std.testing.expect(outcome.plan.isEmpty());
}

test "fixStaleLock: missing lock file is a no-op" {
    try std.testing.expect(!fixStaleLock(std.Options.debug_io, "/nonexistent/malt/prefix"));
}

test "probeStaleLock: missing prefix returns false" {
    try std.testing.expect(!probeStaleLock(std.Options.debug_io, "/nonexistent/malt/prefix"));
}

test "isPurgeableOrphan: only a refcount<=0 row is an orphan" {
    // Matches `Store.orphans()` (WHERE refcount <= 0) so detection and
    // remediation share one definition.
    try std.testing.expect(isPurgeableOrphan(true, 0));
    try std.testing.expect(isPurgeableOrphan(true, -1));
    try std.testing.expect(!isPurgeableOrphan(true, 1));
    // No ref row: a warm / in-flight commit purge cannot clear — not an orphan.
    try std.testing.expect(!isPurgeableOrphan(false, 0));
}

test "OrphanProbe: one probe reset-drives orphan / live-ref / no-row shas in sequence" {
    // Driving all three shas through a single probe is the point: it proves
    // reset-then-rebind works across rows — the lifecycle the old per-call
    // prepare/finalize never exercised.
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = pb[0..try std.Io.Dir.realPath(tmp.dir, io, &pb)];

    var db_buf: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_buf, "{s}/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try db.exec(
        \\CREATE TABLE store_refs (store_sha256 TEXT PRIMARY KEY, refcount INTEGER NOT NULL DEFAULT 1);
        \\INSERT INTO store_refs VALUES ('orphan', 0);
        \\INSERT INTO store_refs VALUES ('live', 2);
    );

    var probe = try OrphanProbe.init(&db);
    defer probe.deinit();
    try std.testing.expect(probe.isOrphan("orphan")); // row, refcount <= 0
    try std.testing.expect(!probe.isOrphan("live")); // row, refcount >= 1
    try std.testing.expect(!probe.isOrphan("missing")); // no row
    // Reusable after a positive hit: same probe instance, sha reused.
    try std.testing.expect(probe.isOrphan("orphan"));
}

test "isDanglingLinkError: only a missing target is dangling" {
    // The single source of truth for check and fix: FileNotFound → remove,
    // every other errno → leave intact (can't tell ≠ broken).
    try std.testing.expect(isDanglingLinkError(error.FileNotFound));
    try std.testing.expect(!isDanglingLinkError(error.AccessDenied));
    try std.testing.expect(!isDanglingLinkError(error.SymLinkLoop));
}

test "walkBrokenSymlinks: a dangling link is detected and removed" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const bin = try std.fmt.bufPrint(&pb, "{s}/bin", .{prefix});
    try std.Io.Dir.cwd().createDirPath(io, bin);
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&lb, "{s}/gone", .{bin});
    try std.Io.Dir.symLinkAbsolute(io, "/no/such/target", link, .{});

    try std.testing.expectEqual(@as(u32, 1), probeBrokenSymlinks(io, prefix));
    try std.testing.expectEqual(@as(u32, 1), fixBrokenSymlinks(io, prefix));
    // The dangling link is gone after the walk.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().deleteFile(io, link));
}

test "walkBrokenSymlinks: an intact link with an inaccessible target is left alone" {
    // A link whose target sits behind a permission wall is live and valid;
    // doctor must not report or remove it. AccessDenied ≠ missing.
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root bypasses the perm wall

    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bb: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = bb[0..try std.Io.Dir.realPath(tmp.dir, io, &bb)];

    // A real target under a mode-0 dir: stat traversal fails with EACCES.
    var wb: [std.fs.max_path_bytes]u8 = undefined;
    const walled = try std.fmt.bufPrint(&wb, "{s}/walled", .{prefix});
    try std.Io.Dir.cwd().createDirPath(io, walled);
    var tb: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&tb, "{s}/keg", .{walled});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, target, .{});
        f.close(io);
    }
    var walled_dir = try std.Io.Dir.openDirAbsolute(io, walled, .{});
    defer walled_dir.close(io);
    try walled_dir.setPermissions(io, std.Io.File.Permissions.fromMode(0));
    // Restore mode so tmp cleanup can recurse into the walled dir.
    defer walled_dir.setPermissions(io, std.Io.File.Permissions.fromMode(0o755)) catch {};

    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const bin = try std.fmt.bufPrint(&pb, "{s}/bin", .{prefix});
    try std.Io.Dir.cwd().createDirPath(io, bin);
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&lb, "{s}/wall", .{bin});
    try std.Io.Dir.symLinkAbsolute(io, target, link, .{});

    try std.testing.expectEqual(@as(u32, 0), probeBrokenSymlinks(io, prefix));
    try std.testing.expectEqual(@as(u32, 0), fixBrokenSymlinks(io, prefix));
    // The link entry survives the walk (readLink inspects the link, not the target).
    var rl: [std.fs.max_path_bytes]u8 = undefined;
    _ = try std.Io.Dir.readLinkAbsolute(io, link, &rl);
}
