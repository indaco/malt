//! malt — tap command
//! Manage taps (tap/untap).

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const tap_mod = @import("../core/tap.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub const TapNameError = error{InvalidTapName};

/// Reject malformed `user/repo` inputs before they're formatted into a
/// GitHub URL or stored as a tap name. No security boundary (no shell
/// expansion, no path traversal reaches disk) — this is just an early,
/// clear "bad input" rather than a confusing failure later.
///
/// Rules: exactly one `/`, each side 1–64 chars of [A-Za-z0-9._-], and
/// neither side starts with `.` (rules out `..` traversal and hidden
/// components).
pub fn validateTapName(name: []const u8) TapNameError!void {
    const slash = std.mem.findScalar(u8, name, '/') orelse return TapNameError.InvalidTapName;
    if (std.mem.findScalarPos(u8, name, slash + 1, '/') != null) return TapNameError.InvalidTapName;
    try validateComponent(name[0..slash]);
    try validateComponent(name[slash + 1 ..]);
}

fn validateComponent(part: []const u8) TapNameError!void {
    if (part.len == 0 or part.len > 64) return TapNameError.InvalidTapName;
    if (part[0] == '.') return TapNameError.InvalidTapName;
    for (part) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return TapNameError.InvalidTapName,
        }
    }
}

/// One row in the `--refresh --all` listing. Fields point at slices owned
/// by the surrounding `tap.list` result or the per-tap resolve buffer; the
/// row itself does not own memory.
const RefreshRow = struct {
    name: []const u8,
    old_sha: ?[]const u8,
    new_sha: ?[]const u8,
    status: RefreshStatus,
};

const RefreshStatus = enum { unchanged, moved, failed };

/// Classify a single tap row by its (old, new) SHA pair. `null` `new`
/// means the network lookup failed; the row is surfaced as `failed` so
/// users still see what would have moved had the resolve succeeded.
fn classifyRefresh(old: ?[]const u8, new: ?[]const u8) RefreshStatus {
    const new_sha = new orelse return .failed;
    if (old) |o| {
        if (std.mem.eql(u8, o, new_sha)) return .unchanged;
        return .moved;
    }
    return .moved;
}

/// True if any row would write a new SHA on apply. Failures alone do not
/// gate — there's nothing to apply for a row we couldn't resolve.
fn anyMoved(rows: []const RefreshRow) bool {
    for (rows) |r| if (r.status == .moved) return true;
    return false;
}

fn shortSha(sha: ?[]const u8) []const u8 {
    if (sha) |s| return s[0..@min(s.len, 7)];
    return "<unpinned>";
}

fn writeRefreshRowText(w: *std.Io.Writer, row: RefreshRow) !void {
    switch (row.status) {
        .unchanged => try w.print("  {s}: {s} (unchanged)\n", .{ row.name, shortSha(row.old_sha) }),
        .moved => try w.print("  {s}: {s} -> {s}\n", .{ row.name, shortSha(row.old_sha), shortSha(row.new_sha) }),
        .failed => try w.print("  {s}: {s} -> ??? (failed)\n", .{ row.name, shortSha(row.old_sha) }),
    }
}

fn writeRefreshRowsJson(w: *std.Io.Writer, rows: []const RefreshRow) !void {
    try w.writeAll("{\"taps\":[");
    for (rows, 0..) |row, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"tap\":");
        try output.jsonStr(w, row.name);
        try w.writeAll(",\"old_sha\":");
        if (row.old_sha) |s| try output.jsonStr(w, s) else try w.writeAll("null");
        try w.writeAll(",\"new_sha\":");
        if (row.new_sha) |s| try output.jsonStr(w, s) else try w.writeAll("null");
        try w.writeAll(",\"status\":");
        try output.jsonStr(w, @tagName(row.status));
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
}

/// Render one listing row: `name @ {7-char sha}` when pinned, or
/// `name (unpinned — run \`mt tap --refresh name\`)` when not. Caller owns
/// the returned slice. Kept in one place so the refresh hint stays in
/// sync with `mt tap --refresh` and the exact byte layout is testable.
fn formatTapLine(allocator: std.mem.Allocator, t: tap_mod.TapInfo) ![]u8 {
    if (t.commit_sha) |sha| {
        const short_len = @min(sha.len, 7);
        return std.fmt.allocPrint(allocator, "{s} @ {s}\n", .{ t.name, sha[0..short_len] });
    }
    return std.fmt.allocPrint(
        allocator,
        "{s} (unpinned — run `mt tap --refresh {s}`)\n",
        .{ t.name, t.name },
    );
}

test "formatTapLine renders short SHA for a pinned tap" {
    const line = try formatTapLine(std.testing.allocator, .{
        .name = "user/repo",
        .url = "https://x",
        .commit_sha = "0123456789abcdef0123456789abcdef01234567",
    });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("user/repo @ 0123456\n", line);
}

test "formatTapLine renders refresh hint for an unpinned tap" {
    const line = try formatTapLine(std.testing.allocator, .{
        .name = "user/repo",
        .url = "https://x",
        .commit_sha = null,
    });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "user/repo (unpinned — run `mt tap --refresh user/repo`)\n",
        line,
    );
}

// ───────────────────────────────────────────────────────────────────
// refresh-all row classifier + formatters. Pure data shaping so the
// `--yes` gate and the `{tap, old_sha, new_sha, status}` JSON contract
// can be pinned byte-for-byte without staging a real DB or network.
// ───────────────────────────────────────────────────────────────────

const sha_old = "0123456789abcdef0123456789abcdef01234567";
const sha_new = "abcdef0123456789abcdef0123456789abcdef01";

test "classifyRefresh: identical old/new → unchanged" {
    try std.testing.expectEqual(RefreshStatus.unchanged, classifyRefresh(sha_old, sha_old));
}

test "classifyRefresh: differing old/new → moved" {
    try std.testing.expectEqual(RefreshStatus.moved, classifyRefresh(sha_old, sha_new));
}

test "classifyRefresh: null new (failed resolve) → failed" {
    try std.testing.expectEqual(RefreshStatus.failed, classifyRefresh(sha_old, null));
    try std.testing.expectEqual(RefreshStatus.failed, classifyRefresh(null, null));
}

test "classifyRefresh: null old + new SHA → moved (newly pinned counts as a write)" {
    try std.testing.expectEqual(RefreshStatus.moved, classifyRefresh(null, sha_new));
}

test "anyMoved: empty list returns false" {
    try std.testing.expect(!anyMoved(&.{}));
}

test "anyMoved: all unchanged returns false" {
    const rows = [_]RefreshRow{
        .{ .name = "a/b", .old_sha = sha_old, .new_sha = sha_old, .status = .unchanged },
        .{ .name = "c/d", .old_sha = sha_old, .new_sha = sha_old, .status = .unchanged },
    };
    try std.testing.expect(!anyMoved(&rows));
}

test "anyMoved: any moved row returns true (failures alone do not gate)" {
    const only_failed = [_]RefreshRow{
        .{ .name = "a/b", .old_sha = sha_old, .new_sha = null, .status = .failed },
    };
    try std.testing.expect(!anyMoved(&only_failed));

    const with_moved = [_]RefreshRow{
        .{ .name = "a/b", .old_sha = sha_old, .new_sha = sha_old, .status = .unchanged },
        .{ .name = "c/d", .old_sha = sha_old, .new_sha = sha_new, .status = .moved },
    };
    try std.testing.expect(anyMoved(&with_moved));
}

test "writeRefreshRowText: moved row renders `old[..7] -> new[..7]`" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRefreshRowText(&aw.writer, .{
        .name = "user/repo",
        .old_sha = sha_old,
        .new_sha = sha_new,
        .status = .moved,
    });
    try std.testing.expectEqualStrings("  user/repo: 0123456 -> abcdef0\n", aw.written());
}

test "writeRefreshRowText: unchanged row marks the row as unchanged" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRefreshRowText(&aw.writer, .{
        .name = "user/repo",
        .old_sha = sha_old,
        .new_sha = sha_old,
        .status = .unchanged,
    });
    try std.testing.expectEqualStrings("  user/repo: 0123456 (unchanged)\n", aw.written());
}

test "writeRefreshRowText: failed row keeps the old SHA visible" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRefreshRowText(&aw.writer, .{
        .name = "user/repo",
        .old_sha = sha_old,
        .new_sha = null,
        .status = .failed,
    });
    try std.testing.expectEqualStrings("  user/repo: 0123456 -> ??? (failed)\n", aw.written());
}

test "writeRefreshRowText: unpinned old SHA is surfaced explicitly" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRefreshRowText(&aw.writer, .{
        .name = "user/repo",
        .old_sha = null,
        .new_sha = sha_new,
        .status = .moved,
    });
    try std.testing.expectEqualStrings("  user/repo: <unpinned> -> abcdef0\n", aw.written());
}

test "writeRefreshRowsJson: emits `{taps:[{tap,old_sha,new_sha,status},...]}`" {
    const rows = [_]RefreshRow{
        .{ .name = "a/b", .old_sha = sha_old, .new_sha = sha_new, .status = .moved },
        .{ .name = "c/d", .old_sha = sha_old, .new_sha = sha_old, .status = .unchanged },
        .{ .name = "e/f", .old_sha = null, .new_sha = null, .status = .failed },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRefreshRowsJson(&aw.writer, &rows);
    try std.testing.expectEqualStrings(
        "{\"taps\":[" ++
            "{\"tap\":\"a/b\",\"old_sha\":\"" ++ sha_old ++ "\",\"new_sha\":\"" ++ sha_new ++ "\",\"status\":\"moved\"}," ++
            "{\"tap\":\"c/d\",\"old_sha\":\"" ++ sha_old ++ "\",\"new_sha\":\"" ++ sha_old ++ "\",\"status\":\"unchanged\"}," ++
            "{\"tap\":\"e/f\",\"old_sha\":null,\"new_sha\":null,\"status\":\"failed\"}" ++
            "]}\n",
        aw.written(),
    );
}

test "writeRefreshRowsJson: empty input emits `{\"taps\":[]}`" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRefreshRowsJson(&aw.writer, &.{});
    try std.testing.expectEqualStrings("{\"taps\":[]}\n", aw.written());
}

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return run(ctx, allocator, args, .add);
}

/// Primitive entry point for core/bundle's dispatcher: add a single tap by
/// name. Argv parsing stays in `execute`; this is the non-argv seam.
pub fn tapAdd(ctx: *const AppCtx, allocator: std.mem.Allocator, name: []const u8) !void {
    const argv = [_][]const u8{name};
    return run(ctx, allocator, &argv, .add);
}

pub fn executeUntap(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return run(ctx, allocator, args, .remove);
}

const Action = enum { add, remove };

fn run(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8, action: Action) !void {
    if (help.showIfRequested(ctx, args, if (action == .add) "tap" else "untap")) return;

    // --refresh <name>: update the stored commit pin to current HEAD.
    // --pin <user/repo> <sha>: explicit pin; consumes the next two argv slots.
    // --refresh --all: walk every registered tap and refresh in batch.
    var refresh_target: ?[]const u8 = null;
    var refresh_all = false;
    var pin_slug: ?[]const u8 = null;
    var pin_sha: ?[]const u8 = null;
    var yes = false;
    var positional: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--refresh")) {
            refresh_target = "";
        } else if (std.mem.startsWith(u8, arg, "--refresh=")) {
            refresh_target = arg["--refresh=".len..];
        } else if (std.mem.eql(u8, arg, "--all")) {
            refresh_all = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            yes = true;
        } else if (std.mem.eql(u8, arg, "--pin")) {
            if (action != .add) {
                output.err("--pin is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            if (i + 2 >= args.len) {
                output.err("Usage: mt tap --pin user/repo <sha>", .{});
                return error.Aborted;
            }
            pin_slug = args[i + 1];
            pin_sha = args[i + 2];
            i += 2;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (positional == null) positional = arg;
        }
    }
    if (refresh_target) |rt| {
        if (rt.len == 0) refresh_target = positional;
    }

    const prefix = atomic.maltPrefixOrAbort();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix with no `db/` yet = no taps registered.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    if (pin_slug) |slug| {
        try pinTap(ctx, allocator, &db, slug, pin_sha.?);
        return;
    }

    if (refresh_all) {
        if (action != .add) {
            output.err("--refresh is only valid with `mt tap`", .{});
            return error.Aborted;
        }
        try refreshAll(ctx, allocator, &db, yes);
        return;
    }

    if (refresh_target) |target| {
        if (action != .add) {
            output.err("--refresh is only valid with `mt tap`", .{});
            return error.Aborted;
        }
        try refreshTap(ctx, allocator, &db, target);
        return;
    }

    if (positional == null) {
        if (action == .remove) {
            output.err("Usage: mt untap user/repo", .{});
            return error.Aborted;
        }
        // List taps
        const taps = tap_mod.list(allocator, &db) catch {
            output.err("Failed to list taps", .{});
            return error.Aborted;
        };
        defer allocator.free(taps);

        if (taps.len == 0) {
            output.info("No taps registered", .{});
            return;
        }

        for (taps) |t| {
            // Assemble the line once so stdout sees a single writeAll — a closed
            // pipe (head, grep -q, etc.) drops the full line rather than leaving
            // it half-written. Empty on OOM keeps the listing best-effort.
            const line = formatTapLine(allocator, t) catch "";
            defer if (line.len != 0) allocator.free(line);
            ctx.stdout.writeStreamingAll(ctx.io, line) catch {};
            allocator.free(t.name);
            allocator.free(t.url);
            if (t.commit_sha) |sha| allocator.free(sha);
        }
        return;
    }

    const name = positional.?;
    validateTapName(name) catch {
        output.err("Invalid tap '{s}'. Expected: user/repo with [A-Za-z0-9._-]", .{name});
        return error.Aborted;
    };

    switch (action) {
        .add => {
            const urls = try tap_mod.resolveTapBaseUrls(allocator, name);
            defer urls.deinit(allocator);

            // Resolve HEAD so the tap is pinned from day one. Failing
            // here beats silently registering an unpinned tap.
            const sha = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.api_head_url) catch |e| {
                output.err("Could not resolve {s}'s HEAD commit: {s}", .{ name, tap_mod.describeResolveError(e) });
                return error.Aborted;
            };
            defer allocator.free(sha);
            tap_mod.add(&db, name, urls.repo_url, sha) catch {
                output.err("Failed to add tap {s}", .{name});
                return error.Aborted;
            };
            output.info("Tapped {s} @ {s}", .{ name, sha[0..@min(sha.len, 7)] });
        },
        .remove => {
            tap_mod.remove(&db, name) catch {
                output.err("Failed to untap {s}", .{name});
                return error.Aborted;
            };
            output.info("Untapped {s}", .{name});
        },
    }
}

fn pinTap(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    slug: []const u8,
    sha: []const u8,
) !void {
    validateTapName(slug) catch {
        output.err("Invalid tap '{s}'. Expected: user/repo with [A-Za-z0-9._-]", .{slug});
        return error.Aborted;
    };
    tap_mod.validateCommitSha(sha) catch {
        output.err("Invalid SHA '{s}'. Expected a 40-char lowercase hex commit SHA.", .{sha});
        return error.Aborted;
    };

    // Route reachability through the same HTTP path as HEAD resolution so a
    // 200 here proves the SHA is fetchable from the exact repo subsequent
    // installs will use. A 404 means GitHub has no such commit on this repo.
    const commit_url = try tap_mod.resolveCommitUrl(allocator, slug, sha);
    defer allocator.free(commit_url);
    const echoed = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, commit_url) catch |e| {
        if (e == error.NotFound) {
            output.err("Cannot pin {s} @ {s}: GitHub has no such commit on this tap.", .{ slug, sha[0..@min(sha.len, 7)] });
        } else {
            output.err("Could not verify {s} @ {s}: {s}", .{ slug, sha[0..@min(sha.len, 7)], tap_mod.describeResolveError(e) });
        }
        return error.Aborted;
    };
    defer allocator.free(echoed);

    // Defensive: GitHub's `commits/<sha>` echoes the resolved full SHA. If
    // it differs, treat as unreachable rather than store a mismatched pin.
    if (!std.mem.eql(u8, echoed, sha)) {
        output.err("Cannot pin {s} @ {s}: GitHub returned a different SHA.", .{ slug, sha[0..@min(sha.len, 7)] });
        return error.Aborted;
    }

    const urls = try tap_mod.resolveTapBaseUrls(allocator, slug);
    defer urls.deinit(allocator);
    tap_mod.add(db, slug, urls.repo_url, sha) catch {
        output.err("Failed to pin {s}", .{slug});
        return error.Aborted;
    };
    output.info("Pinned {s} @ {s}", .{ slug, sha[0..@min(sha.len, 7)] });
}

/// Walk every registered tap, resolve current HEAD, emit a diff, and only
/// apply writes when `yes` is set. JSON consumers still see the full diff;
/// the `--yes` gate is independent of the output format.
fn refreshAll(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    yes: bool,
) !void {
    const taps = tap_mod.list(allocator, db) catch {
        output.err("Failed to list taps", .{});
        return error.Aborted;
    };
    defer {
        for (taps) |t| {
            allocator.free(t.name);
            allocator.free(t.url);
            if (t.commit_sha) |sha| allocator.free(sha);
        }
        allocator.free(taps);
    }

    // Resolve each tap's HEAD up-front so the diff display reflects the
    // full plan before any write happens — including the case where the
    // user immediately passes `--yes`.
    var new_shas: std.ArrayList(?[]const u8) = .empty;
    defer {
        for (new_shas.items) |maybe_sha| if (maybe_sha) |sha| allocator.free(sha);
        new_shas.deinit(allocator);
    }
    try new_shas.ensureTotalCapacityPrecise(allocator, taps.len);

    var rows: std.ArrayList(RefreshRow) = .empty;
    defer rows.deinit(allocator);
    try rows.ensureTotalCapacityPrecise(allocator, taps.len);

    for (taps) |t| {
        const new_sha = resolveOneHead(ctx, allocator, t.name) catch null;
        new_shas.appendAssumeCapacity(new_sha);
        rows.appendAssumeCapacity(.{
            .name = t.name,
            .old_sha = t.commit_sha,
            .new_sha = new_sha,
            .status = classifyRefresh(t.commit_sha, new_sha),
        });
    }

    try emitRefreshAll(ctx, rows.items);

    if (anyMoved(rows.items) and !yes) {
        output.err("Taps moved. Re-run with --yes to apply.", .{});
        return error.Aborted;
    }

    // Apply only the rows that actually moved; unchanged is a no-op and
    // failed has no SHA to write.
    for (rows.items) |row| {
        if (row.status != .moved) continue;
        const new_sha = row.new_sha orelse continue;
        tap_mod.updateCommit(db, row.name, new_sha) catch {
            output.err("Failed to update commit pin for {s}", .{row.name});
            return error.Aborted;
        };
    }
}

fn resolveOneHead(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    slug: []const u8,
) ![]const u8 {
    const urls = try tap_mod.resolveTapBaseUrls(allocator, slug);
    defer urls.deinit(allocator);
    return tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.api_head_url);
}

fn emitRefreshAll(ctx: *const AppCtx, rows: []const RefreshRow) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = ctx.stdout.writer(ctx.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    defer stdout.flush() catch {};

    if (output.isJson()) {
        try writeRefreshRowsJson(stdout, rows);
        return;
    }
    if (rows.len == 0) return;
    for (rows) |row| try writeRefreshRowText(stdout, row);
}

fn refreshTap(ctx: *const AppCtx, allocator: std.mem.Allocator, db: *sqlite.Database, name: []const u8) !void {
    validateTapName(name) catch {
        output.err("Invalid tap '{s}'. Expected: user/repo with [A-Za-z0-9._-]", .{name});
        return error.Aborted;
    };
    const urls = try tap_mod.resolveTapBaseUrls(allocator, name);
    defer urls.deinit(allocator);
    const sha = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.api_head_url) catch |e| {
        output.err("Could not resolve {s}'s HEAD commit: {s}", .{ name, tap_mod.describeResolveError(e) });
        return error.Aborted;
    };
    defer allocator.free(sha);
    tap_mod.updateCommit(db, name, sha) catch {
        output.err("Failed to update commit pin for {s}", .{name});
        return error.Aborted;
    };
    output.info("Refreshed {s} to {s}", .{ name, sha[0..@min(sha.len, 7)] });
}
