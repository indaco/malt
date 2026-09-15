//! malt — outdated snapshot codec
//!
//! On-disk codec, types, and freshness helpers for the cached
//! `outdated.json` snapshot. Lives in its own module so the
//! orchestrator can read/write the cache without dragging in the
//! live-audit pipeline.

const std = @import("std");

const atomic = @import("../../fs/atomic.zig");
const output = @import("../../ui/output.zig");

/// Default max age (minutes) for the cached `outdated.json` snapshot. Matched
/// to the per-formula HTTP cache TTL (api.zig `cache_ttl_secs = 300`): the
/// snapshot is built from that cache, so a longer window would let `mt outdated`
/// disagree with the always-live `mt upgrade`.
pub const snapshot_default_max_age_minutes: u64 = 5;

/// Env var override for `snapshot_default_max_age_minutes`. Same lenient
/// parsing rules as `outdated_workers_env`.
pub const snapshot_max_age_env = "MALT_OUTDATED_MAX_AGE";

/// On-disk snapshot version. Mismatched snapshots are treated as misses
/// so a downgrade never tries to read a future shape. Bumped to 2 when
/// `installed` changed from a bare version to a revision-qualified one:
/// a v1 snapshot's bare `installed` would mis-match the revision-aware
/// intersect, so old snapshots must be refused and recomputed.
pub const snapshot_version: u32 = 2;

/// Snapshot filename under `{cache}/`.
pub const snapshot_file = "outdated.json";

/// Result row for a single outdated package. All slices are owned by
/// the caller's allocator.
pub const OutdatedEntry = struct {
    name: []u8,
    installed: []u8,
    latest: []u8,
};

/// Cached `mt outdated` result. Snapshot trades freshness for instant
/// startup so shell-prompt integrations don't pay an API round-trip per
/// shell. All slices are owned by the parser's allocator (or by the
/// caller, when assembling an in-memory snapshot from `OutdatedEntry`).
pub const Snapshot = struct {
    /// `std.time.milliTimestamp()` at the moment the snapshot was generated.
    generated_at_ms: i64,
    formulas: []const OutdatedEntry,
    casks: []const OutdatedEntry,
};

/// Owned snapshot returned by `parseSnapshot`. Free with `freeSnapshot`.
/// Holds its own copy of every string so it outlives the parser arena.
pub const OwnedSnapshot = struct {
    generated_at_ms: i64,
    formulas: []OutdatedEntry,
    casks: []OutdatedEntry,
};

/// Resolve the snapshot max-age threshold (in minutes) from an env value.
/// Returns `null` for unset / empty / non-numeric so the caller can apply
/// `snapshot_default_max_age_minutes`; preserves an explicit `"0"` as `0`
/// so users who set the env to 0 actually get "always stale".
pub fn parseMaxAgeMinutesEnv(s: ?[]const u8) ?u64 {
    const raw = s orelse return null;
    if (raw.len == 0) return null;
    return std.fmt.parseInt(u64, raw, 10) catch null;
}

/// True when `now_ms - generated_at_ms` exceeds the threshold. Future-
/// dated snapshots (clock skew) are treated as fresh — better than
/// surprising the user with a "stale" warning right after `mt update`.
pub fn isStale(generated_at_ms: i64, now_ms: i64, max_age_minutes: u64) bool {
    if (now_ms <= generated_at_ms) return false;
    const age_ms: u64 = @intCast(now_ms - generated_at_ms);
    // Saturating multiply: a pathological env value (e.g. u64 max) folds
    // to "never stale" rather than wrapping to 0 and reporting fresh
    // snapshots as stale.
    const max_ms = std.math.mul(u64, max_age_minutes, 60 * 1000) catch std.math.maxInt(u64);
    return age_ms > max_ms;
}

pub const RenderError = error{ OutOfMemory, WriteFailed };

/// Render `snap` as a UTF-8 JSON document. Caller owns the returned
/// slice. Shape: `{ "version": N, "generated_at_ms": ms, "formulas":
/// [...], "casks": [...] }` — small enough to stream, stable enough to
/// parse on a downgrade.
pub fn renderSnapshot(allocator: std.mem.Allocator, snap: Snapshot) RenderError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"version\":{d},\"generated_at_ms\":{d},\"formulas\":[", .{ snapshot_version, snap.generated_at_ms });
    for (snap.formulas, 0..) |e, i| {
        if (i != 0) try w.writeAll(",");
        try writeEntryJson(w, e);
    }
    try w.writeAll("],\"casks\":[");
    for (snap.casks, 0..) |e, i| {
        if (i != 0) try w.writeAll(",");
        try writeEntryJson(w, e);
    }
    try w.writeAll("]}");

    return aw.toOwnedSlice();
}

fn writeEntryJson(w: *std.Io.Writer, e: OutdatedEntry) !void {
    try w.writeAll("{\"name\":");
    try output.jsonStr(w, e.name);
    try w.writeAll(",\"installed\":");
    try output.jsonStr(w, e.installed);
    try w.writeAll(",\"latest\":");
    try output.jsonStr(w, e.latest);
    try w.writeAll("}");
}

/// Per-string cap so a tampered snapshot can't push `std.json` into
/// an N-MiB allocation. Real names/versions are well under 256 bytes.
const snapshot_max_value_len: usize = 4 * 1024;

/// Typed schema avoids the `std.json.Value` tree; allocation is bounded
/// by the input size + the per-string cap above.
const SnapshotDoc = struct {
    version: u32,
    generated_at_ms: i64,
    formulas: []const EntryDoc,
    casks: []const EntryDoc,
};

const EntryDoc = struct {
    name: []const u8,
    installed: []const u8,
    latest: []const u8,
};

pub const SnapshotParseError = error{ InvalidSnapshot, OutOfMemory };

pub fn parseSnapshot(allocator: std.mem.Allocator, bytes: []const u8) SnapshotParseError!OwnedSnapshot {
    const opts: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .max_value_len = snapshot_max_value_len,
        // Force allocation so `max_value_len` applies to every string;
        // the default `.alloc_if_needed` borrows un-escaped values from
        // the input buffer and bypasses the cap.
        .allocate = .alloc_always,
    };
    const parsed = std.json.parseFromSlice(SnapshotDoc, allocator, bytes, opts) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSnapshot,
    };
    defer parsed.deinit();

    if (parsed.value.version != snapshot_version) return error.InvalidSnapshot;

    const formulas = try dupEntryDocs(allocator, parsed.value.formulas);
    errdefer freeEntrySlice(allocator, formulas);
    const casks = try dupEntryDocs(allocator, parsed.value.casks);

    return .{
        .generated_at_ms = parsed.value.generated_at_ms,
        .formulas = formulas,
        .casks = casks,
    };
}

fn dupEntryDocs(
    allocator: std.mem.Allocator,
    docs: []const EntryDoc,
) std.mem.Allocator.Error![]OutdatedEntry {
    const out = try allocator.alloc(OutdatedEntry, docs.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |e| {
            allocator.free(e.name);
            allocator.free(e.installed);
            allocator.free(e.latest);
        }
        allocator.free(out);
    }
    for (docs) |d| {
        const name = try allocator.dupe(u8, d.name);
        errdefer allocator.free(name);
        const installed = try allocator.dupe(u8, d.installed);
        errdefer allocator.free(installed);
        const latest = try allocator.dupe(u8, d.latest);
        out[filled] = .{ .name = name, .installed = installed, .latest = latest };
        filled += 1;
    }
    return out;
}

/// Free a caller-owned `[]OutdatedEntry` plus every duped string in it.
/// Shared by `parseSnapshot` error paths and `intersectWithDb`'s callers.
pub fn freeEntrySlice(allocator: std.mem.Allocator, slice: []OutdatedEntry) void {
    for (slice) |e| {
        allocator.free(e.name);
        allocator.free(e.installed);
        allocator.free(e.latest);
    }
    allocator.free(slice);
}

/// Resolve the absolute snapshot path under `cache_dir`. Caller frees.
pub fn snapshotPath(allocator: std.mem.Allocator, cache_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, snapshot_file });
}

/// Atomically write `snap` to `{cache_dir}/outdated.json`. Creates the
/// cache dir if missing — `mt update --check` may run before any other
/// command has touched the cache.
pub fn writeSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    snap: Snapshot,
) !void {
    // Best-effort: a real error here gets surfaced by atomicWriteFile below.
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch {};

    const path = try snapshotPath(allocator, cache_dir);
    defer allocator.free(path);
    const json = try renderSnapshot(allocator, snap);
    defer allocator.free(json);
    try atomic.atomicWriteFile(io, path, json);
}

/// Realistic snapshots are tens of KiB; 1 MiB refuses any inflated file
/// before bytes reach `std.json`.
const snapshot_read_cap: usize = 1 * 1024 * 1024;

/// Read the snapshot at `{cache_dir}/outdated.json`. Snapshot trades
/// freshness for instant startup; on any read or parse failure we
/// return null so callers fall back to a live recompute.
pub fn readSnapshot(io: std.Io, allocator: std.mem.Allocator, cache_dir: []const u8) ?OwnedSnapshot {
    const path = snapshotPath(allocator, cache_dir) catch return null;
    defer allocator.free(path);
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    const size: usize = @intCast(@min(@as(u64, snapshot_read_cap), st.size));
    const buf = allocator.alloc(u8, size) catch return null;
    const n = file.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    // Short read: shrink so caller-side free length matches.
    const bytes = if (n == buf.len) buf else blk: {
        if (allocator.resize(buf, n)) break :blk buf[0..n];
        const trimmed = allocator.alloc(u8, n) catch {
            allocator.free(buf);
            return null;
        };
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        break :blk trimmed;
    };
    defer allocator.free(bytes);
    return parseSnapshot(allocator, bytes) catch null;
}

/// Remove `{cache_dir}/outdated.json`. Deletes rather than prunes: a keg
/// moved below what the snapshot called current has no entry to drop, so
/// only a re-audit can represent it. Best-effort — absent is the goal — but
/// a file that stays put keeps misleading readers, so that is said aloud.
pub fn deleteSnapshot(io: std.Io, cache_dir: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cache_dir, snapshot_file }) catch return;
    std.Io.Dir.deleteFileAbsolute(io, path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => output.warn("Could not remove the stale outdated snapshot at {s}: {s}", .{ path, @errorName(e) }),
    };
}

pub const Table = enum { formulas, casks };

/// What a verb did to one package, as the snapshot needs to hear it.
pub const Change = union(enum) {
    removed,
    /// `installed` is the revision-qualified label the reader intersects on;
    /// `latest` is whatever the local API cache can still vouch for.
    moved: struct { installed: []const u8, latest: ?[]const u8 },
};

/// Edit one entry of `{cache_dir}/outdated.json` in place, keeping the
/// lease: a stale entry misleads the TUI's raw read, but dropping the file
/// costs every other keg its audit. Best-effort. An absent or unreadable
/// file is left alone (a verb never synthesises an audit); a keg the cache
/// cannot describe falls back to `deleteSnapshot`.
pub fn reconcileEntry(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    table: Table,
    name: []const u8,
    change: Change,
) void {
    const snap = readSnapshot(io, allocator, cache_dir) orelse return;
    defer freeSnapshot(allocator, snap);

    const upsert: ?OutdatedEntry = switch (change) {
        .removed => null,
        .moved => |m| blk: {
            const latest = m.latest orelse {
                deleteSnapshot(io, cache_dir);
                return;
            };
            if (std.mem.eql(u8, m.installed, latest)) break :blk null;
            break :blk .{ .name = @constCast(name), .installed = @constCast(m.installed), .latest = @constCast(latest) };
        },
    };

    const rows = switch (table) {
        .formulas => snap.formulas,
        .casks => snap.casks,
    };
    var edited: std.ArrayList(OutdatedEntry) = .empty;
    defer edited.deinit(allocator);
    var replaced = false;
    for (rows) |e| {
        if (!std.mem.eql(u8, e.name, name)) {
            edited.append(allocator, e) catch return;
        } else if (upsert != null and !replaced) {
            edited.append(allocator, upsert.?) catch return;
            replaced = true;
        }
    }
    if (upsert) |u| if (!replaced) edited.append(allocator, u) catch return;

    writeSnapshot(io, allocator, cache_dir, .{
        .generated_at_ms = snap.generated_at_ms,
        .formulas = if (table == .formulas) edited.items else snap.formulas,
        .casks = if (table == .casks) edited.items else snap.casks,
    }) catch |e| output.warn("Could not update the outdated snapshot under {s}: {s}", .{ cache_dir, @errorName(e) });
}

/// Free both arrays + every duped string in `snap`.
pub fn freeSnapshot(allocator: std.mem.Allocator, snap: OwnedSnapshot) void {
    freeEntrySlice(allocator, snap.formulas);
    freeEntrySlice(allocator, snap.casks);
}

test "parseMaxAgeMinutesEnv yields null for null/empty/garbage so callers default" {
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeMinutesEnv(null));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeMinutesEnv(""));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeMinutesEnv("nope"));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeMinutesEnv("-3"));
}

test "parseMaxAgeMinutesEnv preserves explicit 0 as 'always stale'" {
    // The user reaches for 0 to opt out of caching; treating it as
    // 'fall back to default' would silently re-enable the snapshot.
    try std.testing.expectEqual(@as(?u64, 0), parseMaxAgeMinutesEnv("0"));
}

test "parseMaxAgeMinutesEnv parses positive integers verbatim" {
    try std.testing.expectEqual(@as(?u64, 1), parseMaxAgeMinutesEnv("1"));
    try std.testing.expectEqual(@as(?u64, 12), parseMaxAgeMinutesEnv("12"));
    try std.testing.expectEqual(@as(?u64, 168), parseMaxAgeMinutesEnv("168"));
}

test "isStale flips at the max-age boundary in milliseconds" {
    const minute_ms: i64 = 60 * 1000;
    // Same instant -> fresh.
    try std.testing.expect(!isStale(0, 0, 24));
    // Exactly at the boundary -> still fresh.
    try std.testing.expect(!isStale(0, 24 * minute_ms, 24));
    // One ms past the boundary -> stale.
    try std.testing.expect(isStale(0, 24 * minute_ms + 1, 24));
    // Future-dated snapshot (clock skew) -> treated as fresh.
    try std.testing.expect(!isStale(100 * minute_ms, 0, 24));
    // Custom threshold honoured.
    try std.testing.expect(isStale(0, 2 * minute_ms, 1));
    try std.testing.expect(!isStale(0, 1 * minute_ms, 2));
}

test "isStale with max_age_minutes == 0 marks any non-zero age as stale" {
    try std.testing.expect(!isStale(0, 0, 0));
    try std.testing.expect(isStale(0, 1, 0));
}

test "isStale folds a u64-overflowing threshold to 'never stale'" {
    // A pathological MALT_OUTDATED_MAX_AGE shouldn't wrap to 0 ms and
    // report otherwise-fresh snapshots as stale.
    try std.testing.expect(!isStale(0, std.math.maxInt(i64), std.math.maxInt(u64)));
}

test "default snapshot max age tracks the api http cache (~5 minutes)" {
    // The snapshot must not outlive the per-formula HTTP cache it is built from
    // (api.zig cache_ttl_secs = 300s). A longer window lets `mt outdated` report
    // an upgrade the always-live `mt upgrade` already sees — or hide one.
    const min_ms: i64 = 60 * 1000;
    try std.testing.expect(!isStale(0, 5 * min_ms, snapshot_default_max_age_minutes));
    try std.testing.expect(isStale(0, 5 * min_ms + 1, snapshot_default_max_age_minutes));
}

test "renderSnapshot emits the canonical JSON shape" {
    const formulas = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    const casks = [_]OutdatedEntry{
        .{ .name = @constCast("beta"), .installed = @constCast("3.0"), .latest = @constCast("3.5") },
    };
    const snap: Snapshot = .{
        .generated_at_ms = 1_700_000_000_000,
        .formulas = &formulas,
        .casks = &casks,
    };
    const json = try renderSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    const want =
        \\{"version":2,"generated_at_ms":1700000000000,"formulas":[{"name":"alpha","installed":"1.0","latest":"2.0"}],"casks":[{"name":"beta","installed":"3.0","latest":"3.5"}]}
    ;
    try std.testing.expectEqualStrings(want, json);
}

test "parseSnapshot round-trips a rendered snapshot" {
    const formulas = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("bravo"), .installed = @constCast("3.0"), .latest = @constCast("3.5") },
    };
    const casks = [_]OutdatedEntry{
        .{ .name = @constCast("charlie"), .installed = @constCast("9.0"), .latest = @constCast("9.5") },
    };
    const snap: Snapshot = .{
        .generated_at_ms = 1_700_000_000_000,
        .formulas = &formulas,
        .casks = &casks,
    };
    const json = try renderSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    const parsed = try parseSnapshot(std.testing.allocator, json);
    defer freeSnapshot(std.testing.allocator, parsed);

    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), parsed.generated_at_ms);
    try std.testing.expectEqual(@as(usize, 2), parsed.formulas.len);
    try std.testing.expectEqualStrings("alpha", parsed.formulas[0].name);
    try std.testing.expectEqualStrings("1.0", parsed.formulas[0].installed);
    try std.testing.expectEqualStrings("2.0", parsed.formulas[0].latest);
    try std.testing.expectEqualStrings("bravo", parsed.formulas[1].name);
    try std.testing.expectEqual(@as(usize, 1), parsed.casks.len);
    try std.testing.expectEqualStrings("charlie", parsed.casks[0].name);
    try std.testing.expectEqualStrings("9.5", parsed.casks[0].latest);
}

test "parseSnapshot rejects mismatched version, missing fields, garbage" {
    try std.testing.expectError(error.InvalidSnapshot, parseSnapshot(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidSnapshot, parseSnapshot(std.testing.allocator, "not-json"));
    // Future schema version: refuse rather than guess.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":99,\"generated_at_ms\":0,\"formulas\":[],\"casks\":[]}"),
    );
    // v1 stored `installed` bare; reading it under the revision-qualified
    // shape would mis-match the intersect, so the old version is refused
    // and the caller recomputes.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":1,\"generated_at_ms\":0,\"formulas\":[],\"casks\":[]}"),
    );
    // Missing required field.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":2,\"formulas\":[],\"casks\":[]}"),
    );
    // Wrong type for formulas.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":2,\"generated_at_ms\":0,\"formulas\":\"x\",\"casks\":[]}"),
    );
}

test "parseSnapshot bounds per-string allocation against tampered input" {
    // Build a JSON document with a single name field exceeding the
    // per-value cap. The typed parser must reject it without inflating
    // memory to the size of the malicious string.
    const oversized_len = snapshot_max_value_len + 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"version\":2,\"generated_at_ms\":0,\"formulas\":[{\"name\":\"");
    try buf.appendNTimes(std.testing.allocator, 'a', oversized_len);
    try buf.appendSlice(std.testing.allocator, "\",\"installed\":\"1\",\"latest\":\"2\"}],\"casks\":[]}");

    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, buf.items),
    );
}

test "parseSnapshot tolerates unknown forward-compatible fields" {
    // Adding a field server-side shouldn't invalidate existing snapshots.
    const json =
        \\{"version":2,"generated_at_ms":0,"formulas":[],"casks":[],"future":42}
    ;
    const parsed = try parseSnapshot(std.testing.allocator, json);
    defer freeSnapshot(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 0), parsed.formulas.len);
}

test "renderSnapshot handles empty formula and cask lists" {
    const snap: Snapshot = .{
        .generated_at_ms = 0,
        .formulas = &[_]OutdatedEntry{},
        .casks = &[_]OutdatedEntry{},
    };
    const json = try renderSnapshot(std.testing.allocator, snap);
    defer std.testing.allocator.free(json);

    const want =
        \\{"version":2,"generated_at_ms":0,"formulas":[],"casks":[]}
    ;
    try std.testing.expectEqualStrings(want, json);
}

test "deleteSnapshot removes the file so the next reader must re-audit" {
    // A rollback moves a keg below what the snapshot calls current; that keg
    // has no entry to prune, so only an absent file makes readers recompute.
    const a = std.testing.allocator;
    const io = std.Options.debug_io;
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt_snap_delete_{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try writeSnapshot(io, a, dir, .{ .generated_at_ms = 1, .formulas = &.{}, .casks = &.{} });
    try std.testing.expect(readSnapshot(io, a, dir) != null);

    deleteSnapshot(io, dir);
    try std.testing.expect(readSnapshot(io, a, dir) == null);
}

test "deleteSnapshot warns when the file cannot be removed, but not when it is already gone" {
    // A stale snapshot that survives a rollback is the bug this guards
    // against; if the delete fails for any reason other than absence the
    // user must hear it, or `mt outdated` keeps lying with no signal.
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root bypasses the perm wall
    const a = std.testing.allocator;
    const io = std.Options.debug_io;
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/malt_snap_locked_{d}", .{std.c.getpid()}, 0);
    defer {
        _ = std.c.chmod(dir.ptr, 0o755);
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try writeSnapshot(io, a, dir, .{ .generated_at_ms = 1, .formulas = &.{}, .casks = &.{} });

    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(a);
    output.beginStderrCapture(a, &err_buf);
    defer output.endStderrCapture();

    _ = std.c.chmod(dir.ptr, 0o500);
    deleteSnapshot(io, dir);
    try std.testing.expect(std.mem.indexOf(u8, err_buf.items, "outdated snapshot") != null);

    _ = std.c.chmod(dir.ptr, 0o755);
    err_buf.clearRetainingCapacity();
    deleteSnapshot(io, dir);
    deleteSnapshot(io, dir);
    try std.testing.expectEqualStrings("", err_buf.items);
}

const ReconcileFixture = struct {
    dir: []const u8,
    dir_buf: [64]u8 = undefined,

    const io = std.Options.debug_io;
    const a = std.testing.allocator;
    const seed =
        \\{"version":2,"generated_at_ms":1700000000000,"formulas":[{"name":"wget","installed":"1.20","latest":"1.22"},{"name":"jq","installed":"1.7","latest":"1.8"}],"casks":[{"name":"wget","installed":"1","latest":"2"}]}
    ;

    fn init(self: *ReconcileFixture, comptime tag: []const u8) !void {
        self.dir = try std.fmt.bufPrint(&self.dir_buf, "/tmp/malt_snap_rec_{s}_{d}", .{ tag, std.c.getpid() });
        std.Io.Dir.cwd().deleteTree(io, self.dir) catch {};
        try self.write(seed);
    }

    fn deinit(self: *ReconcileFixture) void {
        std.Io.Dir.cwd().deleteTree(io, self.dir) catch {};
    }

    fn write(self: *ReconcileFixture, bytes: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, self.dir);
        const path = try snapshotPath(a, self.dir);
        defer a.free(path);
        try atomic.atomicWriteFile(io, path, bytes);
    }

    fn raw(self: *ReconcileFixture) !?[]u8 {
        const path = try snapshotPath(a, self.dir);
        defer a.free(path);
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close(io);
        const st = try file.stat(io);
        const buf = try a.alloc(u8, @intCast(st.size));
        errdefer a.free(buf);
        _ = try file.readPositionalAll(io, buf, 0);
        return buf;
    }

    fn parsed(self: *ReconcileFixture) !OwnedSnapshot {
        return readSnapshot(io, a, self.dir) orelse error.SnapshotUnreadable;
    }
};

fn expectNames(entries: []const OutdatedEntry, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, entries.len);
    for (entries, want) |e, w| try std.testing.expectEqualStrings(w, e.name);
}

test "reconcileEntry .removed drops only the named entry of the addressed table and keeps the lease" {
    // An uninstalled keg must leave the file, not take every other keg's
    // audit with it: the TUI paints the raw file, so a stray entry is a lie
    // but a deleted file is a re-audit for everyone.
    var fx: ReconcileFixture = undefined;
    try fx.init("removed");
    defer fx.deinit();

    reconcileEntry(ReconcileFixture.io, ReconcileFixture.a, fx.dir, .formulas, "wget", .removed);

    const snap = try fx.parsed();
    defer freeSnapshot(ReconcileFixture.a, snap);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), snap.generated_at_ms);
    try expectNames(snap.formulas, &.{"jq"});
    // Same token in the other table is a different package.
    try expectNames(snap.casks, &.{"wget"});
}

test "reconcileEntry .moved upserts a revision-qualified entry in place, or appends a new one" {
    var fx: ReconcileFixture = undefined;
    try fx.init("upsert");
    defer fx.deinit();
    const io = ReconcileFixture.io;
    const a = ReconcileFixture.a;

    // A rolled-back keg that the file already lists is rewritten where it
    // sits; `installed` is stored verbatim because the reader intersects
    // on the revision-qualified label.
    reconcileEntry(io, a, fx.dir, .formulas, "wget", .{ .moved = .{ .installed = "1.19_1", .latest = "1.22" } });
    {
        const snap = try fx.parsed();
        defer freeSnapshot(a, snap);
        try expectNames(snap.formulas, &.{ "wget", "jq" });
        try std.testing.expectEqualStrings("1.19_1", snap.formulas[0].installed);
        try std.testing.expectEqualStrings("1.22", snap.formulas[0].latest);
    }

    // An older local install of a keg the audit never saw is appended.
    reconcileEntry(io, a, fx.dir, .casks, "foo", .{ .moved = .{ .installed = "1.0", .latest = "2.0" } });
    {
        const snap = try fx.parsed();
        defer freeSnapshot(a, snap);
        try expectNames(snap.casks, &.{ "wget", "foo" });
        try std.testing.expectEqualStrings("2.0", snap.casks[1].latest);
        try std.testing.expectEqual(@as(i64, 1_700_000_000_000), snap.generated_at_ms);
    }
}

test "reconcileEntry .moved onto latest drops the entry" {
    // Landing on what upstream calls current is "not outdated"; an entry
    // with installed == latest would be a row the reader could never
    // explain.
    var fx: ReconcileFixture = undefined;
    try fx.init("current");
    defer fx.deinit();

    reconcileEntry(ReconcileFixture.io, ReconcileFixture.a, fx.dir, .formulas, "jq", .{ .moved = .{ .installed = "1.8", .latest = "1.8" } });

    const snap = try fx.parsed();
    defer freeSnapshot(ReconcileFixture.a, snap);
    try expectNames(snap.formulas, &.{"wget"});
}

test "reconcileEntry .moved without a known latest deletes the file" {
    // With no cached upstream version the file cannot describe the moved
    // keg, and an omission is exactly the lie a snapshot must never tell;
    // only an absent file forces the re-audit.
    var fx: ReconcileFixture = undefined;
    try fx.init("unknown");
    defer fx.deinit();

    reconcileEntry(ReconcileFixture.io, ReconcileFixture.a, fx.dir, .formulas, "wget", .{ .moved = .{ .installed = "1.19", .latest = null } });

    try std.testing.expectEqual(@as(?[]u8, null), try fx.raw());
}

test "reconcileEntry never creates a file, even when the change would delete one" {
    // A verb edits the audit it finds; synthesising one would hand the
    // reader a fresh lease on an empty set.
    var fx: ReconcileFixture = undefined;
    try fx.init("absent");
    defer fx.deinit();
    const io = ReconcileFixture.io;
    const a = ReconcileFixture.a;
    deleteSnapshot(io, fx.dir);

    reconcileEntry(io, a, fx.dir, .formulas, "wget", .removed);
    reconcileEntry(io, a, fx.dir, .formulas, "wget", .{ .moved = .{ .installed = "1.19", .latest = "1.22" } });
    reconcileEntry(io, a, fx.dir, .formulas, "wget", .{ .moved = .{ .installed = "1.19", .latest = null } });

    try std.testing.expectEqual(@as(?[]u8, null), try fx.raw());
}

test "reconcileEntry leaves a malformed file byte-identical" {
    // Readers already treat garbage as a miss; rewriting it would turn
    // "recompute" into a well-formed lie.
    var fx: ReconcileFixture = undefined;
    try fx.init("garbage");
    defer fx.deinit();
    const io = ReconcileFixture.io;
    const a = ReconcileFixture.a;
    try fx.write("{\"version\":1,\"formulas\":[}");

    reconcileEntry(io, a, fx.dir, .formulas, "wget", .removed);
    reconcileEntry(io, a, fx.dir, .formulas, "wget", .{ .moved = .{ .installed = "1.19", .latest = null } });

    const after = (try fx.raw()).?;
    defer a.free(after);
    try std.testing.expectEqualStrings("{\"version\":1,\"formulas\":[}", after);
}

test "reconcileEntry collapses a duplicated name to the one entry it was given" {
    // A tampered file naming a package twice must not come out of an edit
    // still naming it twice.
    var fx: ReconcileFixture = undefined;
    try fx.init("dupe");
    defer fx.deinit();
    const a = ReconcileFixture.a;
    try fx.write(
        \\{"version":2,"generated_at_ms":1,"formulas":[{"name":"wget","installed":"1.20","latest":"1.22"},{"name":"wget","installed":"1.19","latest":"1.22"}],"casks":[]}
    );

    reconcileEntry(ReconcileFixture.io, a, fx.dir, .formulas, "wget", .{ .moved = .{ .installed = "1.18", .latest = "1.22" } });

    const snap = try fx.parsed();
    defer freeSnapshot(a, snap);
    try expectNames(snap.formulas, &.{"wget"});
    try std.testing.expectEqualStrings("1.18", snap.formulas[0].installed);
}

test "reconcileEntry removing an absent name still yields a valid file with the same content" {
    var fx: ReconcileFixture = undefined;
    try fx.init("noop");
    defer fx.deinit();

    reconcileEntry(ReconcileFixture.io, ReconcileFixture.a, fx.dir, .casks, "nope", .removed);

    const after = (try fx.raw()).?;
    defer ReconcileFixture.a.free(after);
    try std.testing.expectEqualStrings(ReconcileFixture.seed, after);
}
