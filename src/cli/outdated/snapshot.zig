//! malt — outdated snapshot codec
//!
//! On-disk codec, types, and freshness helpers for the cached
//! `outdated.json` snapshot. Lives in its own module so the
//! orchestrator can read/write the cache without dragging in the
//! live-audit pipeline.

const std = @import("std");

const atomic = @import("../../fs/atomic.zig");
const output = @import("../../ui/output.zig");

/// Default max age (hours) for the cached `outdated.json` snapshot. Picked
/// to match the analysis doc: "shell-prompt integrations want instant
/// startup; ~daily refresh is plenty for security awareness".
pub const SNAPSHOT_DEFAULT_MAX_AGE_HOURS: u64 = 24;

/// Env var override for `SNAPSHOT_DEFAULT_MAX_AGE_HOURS`. Same lenient
/// parsing rules as `OUTDATED_WORKERS_ENV`.
pub const SNAPSHOT_MAX_AGE_ENV = "MALT_OUTDATED_MAX_AGE";

/// On-disk snapshot version. Mismatched snapshots are treated as misses
/// so a downgrade never tries to read a future shape.
pub const SNAPSHOT_VERSION: u32 = 1;

/// Snapshot filename under `{cache}/`.
pub const SNAPSHOT_FILE = "outdated.json";

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

/// Resolve the snapshot max-age threshold (in hours) from an env value.
/// Returns `null` for unset / empty / non-numeric so the caller can apply
/// `SNAPSHOT_DEFAULT_MAX_AGE_HOURS`; preserves an explicit `"0"` as `0`
/// so users who set the env to 0 actually get "always stale".
pub fn parseMaxAgeHoursEnv(s: ?[]const u8) ?u64 {
    const raw = s orelse return null;
    if (raw.len == 0) return null;
    return std.fmt.parseInt(u64, raw, 10) catch null;
}

/// True when `now_ms - generated_at_ms` exceeds the threshold. Future-
/// dated snapshots (clock skew) are treated as fresh — better than
/// surprising the user with a "stale" warning right after `mt update`.
pub fn isStale(generated_at_ms: i64, now_ms: i64, max_age_hours: u64) bool {
    if (now_ms <= generated_at_ms) return false;
    const age_ms: u64 = @intCast(now_ms - generated_at_ms);
    // Saturating multiply: a pathological env value (e.g. u64 max) folds
    // to "never stale" rather than wrapping to 0 and reporting fresh
    // snapshots as stale.
    const max_ms = std.math.mul(u64, max_age_hours, 60 * 60 * 1000) catch std.math.maxInt(u64);
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

    try w.print("{{\"version\":{d},\"generated_at_ms\":{d},\"formulas\":[", .{ SNAPSHOT_VERSION, snap.generated_at_ms });
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

    if (parsed.value.version != SNAPSHOT_VERSION) return error.InvalidSnapshot;

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
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, SNAPSHOT_FILE });
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

/// Free both arrays + every duped string in `snap`.
pub fn freeSnapshot(allocator: std.mem.Allocator, snap: OwnedSnapshot) void {
    freeEntrySlice(allocator, snap.formulas);
    freeEntrySlice(allocator, snap.casks);
}

test "parseMaxAgeHoursEnv yields null for null/empty/garbage so callers default" {
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeHoursEnv(null));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeHoursEnv(""));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeHoursEnv("nope"));
    try std.testing.expectEqual(@as(?u64, null), parseMaxAgeHoursEnv("-3"));
}

test "parseMaxAgeHoursEnv preserves explicit 0 as 'always stale'" {
    // The user reaches for 0 to opt out of caching; treating it as
    // 'fall back to default' would silently re-enable the snapshot.
    try std.testing.expectEqual(@as(?u64, 0), parseMaxAgeHoursEnv("0"));
}

test "parseMaxAgeHoursEnv parses positive integers verbatim" {
    try std.testing.expectEqual(@as(?u64, 1), parseMaxAgeHoursEnv("1"));
    try std.testing.expectEqual(@as(?u64, 12), parseMaxAgeHoursEnv("12"));
    try std.testing.expectEqual(@as(?u64, 168), parseMaxAgeHoursEnv("168"));
}

test "isStale flips at the max-age boundary in milliseconds" {
    const hour_ms: i64 = 60 * 60 * 1000;
    // Same instant -> fresh.
    try std.testing.expect(!isStale(0, 0, 24));
    // Exactly at the boundary -> still fresh.
    try std.testing.expect(!isStale(0, 24 * hour_ms, 24));
    // One ms past the boundary -> stale.
    try std.testing.expect(isStale(0, 24 * hour_ms + 1, 24));
    // Future-dated snapshot (clock skew) -> treated as fresh.
    try std.testing.expect(!isStale(100 * hour_ms, 0, 24));
    // Custom threshold honoured.
    try std.testing.expect(isStale(0, 2 * hour_ms, 1));
    try std.testing.expect(!isStale(0, 1 * hour_ms, 2));
}

test "isStale with max_age_hours == 0 marks any non-zero age as stale" {
    try std.testing.expect(!isStale(0, 0, 0));
    try std.testing.expect(isStale(0, 1, 0));
}

test "isStale folds a u64-overflowing threshold to 'never stale'" {
    // A pathological MALT_OUTDATED_MAX_AGE shouldn't wrap to 0 ms and
    // report otherwise-fresh snapshots as stale.
    try std.testing.expect(!isStale(0, std.math.maxInt(i64), std.math.maxInt(u64)));
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
        \\{"version":1,"generated_at_ms":1700000000000,"formulas":[{"name":"alpha","installed":"1.0","latest":"2.0"}],"casks":[{"name":"beta","installed":"3.0","latest":"3.5"}]}
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
    // Missing required field.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":1,\"formulas\":[],\"casks\":[]}"),
    );
    // Wrong type for formulas.
    try std.testing.expectError(
        error.InvalidSnapshot,
        parseSnapshot(std.testing.allocator, "{\"version\":1,\"generated_at_ms\":0,\"formulas\":\"x\",\"casks\":[]}"),
    );
}

test "parseSnapshot bounds per-string allocation against tampered input" {
    // Build a JSON document with a single name field exceeding the
    // per-value cap. The typed parser must reject it without inflating
    // memory to the size of the malicious string.
    const oversized_len = snapshot_max_value_len + 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"version\":1,\"generated_at_ms\":0,\"formulas\":[{\"name\":\"");
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
        \\{"version":1,"generated_at_ms":0,"formulas":[],"casks":[],"future":42}
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
        \\{"version":1,"generated_at_ms":0,"formulas":[],"casks":[]}
    ;
    try std.testing.expectEqualStrings(want, json);
}
