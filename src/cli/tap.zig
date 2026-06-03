//! malt — tap command
//! Manage taps (tap/untap).

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const tap_mod = @import("../core/tap.zig");
const forge = @import("../core/forge.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub const TapNameError = error{InvalidTapName};

pub const RepoOverrideError = error{InvalidRepoOverride} || std.mem.Allocator.Error;

pub const ForgeHostError = error{InvalidForgeHost};

pub const RepoUrlError = error{InvalidRepoUrl} || std.mem.Allocator.Error;

/// Parse a full `https://<host>/<owner>/<repo>` registration URL into an
/// owned `(host, owner, repo)` triple, deriving the forge host so the
/// user need not name `--host` separately. Host and path components are
/// validated by the same rules `--host` and `--repo` enforce. A single
/// trailing slash is tolerated; deeper paths and non-https URLs are
/// rejected. Caller owns the triple via `TapPair.deinit`.
pub fn parseRepoUrl(allocator: std.mem.Allocator, raw: []const u8) RepoUrlError!tap_mod.TapPair {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, raw, scheme)) return error.InvalidRepoUrl;
    const rest = std.mem.trimEnd(u8, raw[scheme.len..], "/");
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidRepoUrl;
    const host = rest[0..slash];
    const path = rest[slash + 1 ..];
    validateForgeHost(host) catch return error.InvalidRepoUrl;
    validateTapName(path) catch return error.InvalidRepoUrl;
    const path_slash = std.mem.indexOfScalar(u8, path, '/').?;
    const owner = path[0..path_slash];
    const repo = path[path_slash + 1 ..];

    const host_owned = try allocator.dupe(u8, host);
    errdefer allocator.free(host_owned);
    const owner_owned = try allocator.dupe(u8, owner);
    errdefer allocator.free(owner_owned);
    const repo_owned = try allocator.dupe(u8, repo);
    return .{ .owner = owner_owned, .repo = repo_owned, .host = host_owned };
}

/// Validate a `--host` value as a bare forge host: an HTTPS host with no
/// scheme and no path. Rejecting `:` and `/` rules out `https://…`, a
/// trailing path, and `host:port` in one sweep; the dot requirement stops
/// a stray path fragment from masquerading as a host.
pub fn validateForgeHost(host: []const u8) ForgeHostError!void {
    if (host.len == 0 or host.len > 253) return error.InvalidForgeHost;
    if (host[0] == '.' or host[0] == '-') return error.InvalidForgeHost;
    if (host[host.len - 1] == '.' or host[host.len - 1] == '-') return error.InvalidForgeHost;
    var has_dot = false;
    for (host) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
        '.' => has_dot = true,
        else => return error.InvalidForgeHost,
    };
    if (!has_dot) return error.InvalidForgeHost;
}

/// Parse `--repo <owner>/<exact-repo>` into an owned `(owner, repo)`
/// pair. Reuses the slug-validation rules so the override can't sneak
/// past validateTapName by going through the flag. Caller owns both
/// slices via `TapPair.deinit`.
pub fn parseRepoOverride(allocator: std.mem.Allocator, raw: []const u8, host: []const u8) RepoOverrideError!tap_mod.TapPair {
    validateTapName(raw) catch return RepoOverrideError.InvalidRepoOverride;
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse unreachable;
    const owner = raw[0..slash];
    const repo = raw[slash + 1 ..];
    const owner_owned = try allocator.dupe(u8, owner);
    errdefer allocator.free(owner_owned);
    const repo_owned = try allocator.dupe(u8, repo);
    errdefer allocator.free(repo_owned);
    // `host` is the forge chosen via `--host` (or github.com by default);
    // pairing it here keeps the row's `(owner, repo, host)` self-consistent.
    const host_owned = try allocator.dupe(u8, host);
    return .{ .owner = owner_owned, .repo = repo_owned, .host = host_owned };
}

test "parseRepoOverride accepts user/repo and returns the owned pair" {
    const pair = try parseRepoOverride(std.testing.allocator, "aeroxy/ast-outline", "github.com");
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("aeroxy", pair.owner);
    try std.testing.expectEqualStrings("ast-outline", pair.repo);
    try std.testing.expectEqualStrings("github.com", pair.host);
}

test "parseRepoOverride threads the chosen forge host onto the pair" {
    const pair = try parseRepoOverride(std.testing.allocator, "mygroup/mytap", "gitlab.com");
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("mygroup", pair.owner);
    try std.testing.expectEqualStrings("mytap", pair.repo);
    try std.testing.expectEqualStrings("gitlab.com", pair.host);
}

test "parseRepoOverride rejects a malformed override (no slash, double slash, empty parts)" {
    try std.testing.expectError(RepoOverrideError.InvalidRepoOverride, parseRepoOverride(std.testing.allocator, "noslash", "github.com"));
    try std.testing.expectError(RepoOverrideError.InvalidRepoOverride, parseRepoOverride(std.testing.allocator, "user//repo", "github.com"));
    try std.testing.expectError(RepoOverrideError.InvalidRepoOverride, parseRepoOverride(std.testing.allocator, "user/", "github.com"));
    try std.testing.expectError(RepoOverrideError.InvalidRepoOverride, parseRepoOverride(std.testing.allocator, "/repo", "github.com"));
}

test "parseRepoOverride preserves hyphens, digits, dots in both components" {
    // GitHub allows these in user and repo names; the validator must
    // not reject them when a user passes them through --repo.
    const pair = try parseRepoOverride(std.testing.allocator, "user-1/some.repo_v2", "github.com");
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("user-1", pair.owner);
    try std.testing.expectEqualStrings("some.repo_v2", pair.repo);
}

test "parseRepoOverride rejects components longer than 64 chars" {
    // Pre-existing validateTapName cap. Documented here so a future
    // relaxation surfaces as a test diff rather than silent acceptance.
    const long = "a" ** 65 ++ "/" ++ "b" ** 4;
    try std.testing.expectError(RepoOverrideError.InvalidRepoOverride, parseRepoOverride(std.testing.allocator, long, "github.com"));
}

test "parseRepoOverride rejects a leading dot (path-traversal-shaped names)" {
    try std.testing.expectError(RepoOverrideError.InvalidRepoOverride, parseRepoOverride(std.testing.allocator, ".hidden/repo", "github.com"));
    try std.testing.expectError(RepoOverrideError.InvalidRepoOverride, parseRepoOverride(std.testing.allocator, "user/.hidden", "github.com"));
}

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

test "parseRepoUrl derives (host, owner, repo) from a full HTTPS repo URL" {
    const pair = try parseRepoUrl(std.testing.allocator, "https://gitlab.com/mygroup/mytap");
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gitlab.com", pair.host);
    try std.testing.expectEqualStrings("mygroup", pair.owner);
    try std.testing.expectEqualStrings("mytap", pair.repo);
}

test "parseRepoUrl tolerates a single trailing slash" {
    const pair = try parseRepoUrl(std.testing.allocator, "https://codeberg.org/o/r/");
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("codeberg.org", pair.host);
    try std.testing.expectEqualStrings("o", pair.owner);
    try std.testing.expectEqualStrings("r", pair.repo);
}

test "parseRepoUrl rejects non-https, missing-repo, deep-path, and bad-host URLs" {
    try std.testing.expectError(RepoUrlError.InvalidRepoUrl, parseRepoUrl(std.testing.allocator, "http://gitlab.com/o/r"));
    try std.testing.expectError(RepoUrlError.InvalidRepoUrl, parseRepoUrl(std.testing.allocator, "https://gitlab.com/o"));
    try std.testing.expectError(RepoUrlError.InvalidRepoUrl, parseRepoUrl(std.testing.allocator, "https://gitlab.com/o/r/sub"));
    try std.testing.expectError(RepoUrlError.InvalidRepoUrl, parseRepoUrl(std.testing.allocator, "https://gitlab .com/o/r"));
    try std.testing.expectError(RepoUrlError.InvalidRepoUrl, parseRepoUrl(std.testing.allocator, "https://gitlab.com//r"));
}

test "validateForgeHost accepts bare HTTPS hosts" {
    try validateForgeHost("gitlab.com");
    try validateForgeHost("codeberg.org");
    try validateForgeHost("git.example.com");
    try validateForgeHost("github.com");
}

test "validateForgeHost rejects schemes, paths, ports, and dotless hosts" {
    try std.testing.expectError(ForgeHostError.InvalidForgeHost, validateForgeHost("https://gitlab.com"));
    try std.testing.expectError(ForgeHostError.InvalidForgeHost, validateForgeHost("gitlab.com/group/tap"));
    try std.testing.expectError(ForgeHostError.InvalidForgeHost, validateForgeHost("gitlab.com:8443"));
    try std.testing.expectError(ForgeHostError.InvalidForgeHost, validateForgeHost("localhost"));
    try std.testing.expectError(ForgeHostError.InvalidForgeHost, validateForgeHost(""));
    try std.testing.expectError(ForgeHostError.InvalidForgeHost, validateForgeHost("gitlab .com"));
    try std.testing.expectError(ForgeHostError.InvalidForgeHost, validateForgeHost(".gitlab.com"));
    try std.testing.expectError(ForgeHostError.InvalidForgeHost, validateForgeHost("gitlab.com."));
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

/// Emit `[{ "name", "url", "commit_sha", "host" }, ...]\n` for `mt tap
/// --json`. `commit_sha` is `null` when the tap is unpinned; `host` names
/// the forge the tap resolves against. Kept `pub` so tests can pin the
/// exact bytes without staging a DB or running the dispatcher.
pub fn writeTapListJson(w: *std.Io.Writer, taps: []const tap_mod.TapInfo) !void {
    try w.writeAll("[");
    for (taps, 0..) |t, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, t.name);
        try w.writeAll(",\"url\":");
        try output.jsonStr(w, t.url);
        try w.writeAll(",\"commit_sha\":");
        if (t.commit_sha) |sha| try output.jsonStr(w, sha) else try w.writeAll("null");
        try w.writeAll(",\"host\":");
        try output.jsonStr(w, t.host);
        try w.writeAll("}");
    }
    try w.writeAll("]\n");
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
    // GitHub is the implicit default; tag only off-github taps so the
    // common listing stays uncluttered. A hostname fits in 256 bytes.
    var host_buf: [288]u8 = undefined;
    const host_tag: []const u8 = if (std.mem.eql(u8, t.host, "github.com"))
        ""
    else
        std.fmt.bufPrint(&host_buf, " [{s}]", .{t.host}) catch "";
    if (t.commit_sha) |sha| {
        const short_len = @min(sha.len, 7);
        return std.fmt.allocPrint(allocator, "{s} @ {s}{s}\n", .{ t.name, sha[0..short_len], host_tag });
    }
    return std.fmt.allocPrint(
        allocator,
        "{s} (unpinned — run `mt tap --refresh {s}`){s}\n",
        .{ t.name, t.name, host_tag },
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

test "formatTapLine annotates a non-github tap with its forge host" {
    // GitHub is the implicit default — only off-github taps carry the
    // host tag so the common listing stays uncluttered.
    const pinned = try formatTapLine(std.testing.allocator, .{
        .name = "grp/tap",
        .url = "https://gitlab.com/grp/tap",
        .commit_sha = "0123456789abcdef0123456789abcdef01234567",
        .host = "gitlab.com",
    });
    defer std.testing.allocator.free(pinned);
    try std.testing.expectEqualStrings("grp/tap @ 0123456 [gitlab.com]\n", pinned);

    const unpinned = try formatTapLine(std.testing.allocator, .{
        .name = "grp/tap",
        .url = "https://gitlab.com/grp/tap",
        .commit_sha = null,
        .host = "gitlab.com",
    });
    defer std.testing.allocator.free(unpinned);
    try std.testing.expectEqualStrings(
        "grp/tap (unpinned — run `mt tap --refresh grp/tap`) [gitlab.com]\n",
        unpinned,
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

test "writeTapListJson: empty input emits `[]\\n`" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeTapListJson(&aw.writer, &.{});
    try std.testing.expectEqualStrings("[]\n", aw.written());
}

test "writeTapListJson: escapes embedded quotes/backslashes in url so output is valid JSON" {
    const rows = [_]tap_mod.TapInfo{
        .{ .name = "user/repo", .url = "https://x/\"weird\\path\"", .commit_sha = null },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeTapListJson(&aw.writer, &rows);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"user/repo\",\"url\":\"https://x/\\\"weird\\\\path\\\"\",\"commit_sha\":null,\"host\":\"github.com\"}]\n",
        aw.written(),
    );
}

test "writeTapListJson: emits `name`, `url`, `commit_sha`, `host` per tap; null when unpinned" {
    const rows = [_]tap_mod.TapInfo{
        .{ .name = "user/repo", .url = "https://github.com/user/homebrew-repo", .commit_sha = sha_old },
        .{ .name = "grp/tap", .url = "https://gitlab.com/grp/tap", .commit_sha = null, .host = "gitlab.com" },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeTapListJson(&aw.writer, &rows);
    try std.testing.expectEqualStrings(
        "[" ++
            "{\"name\":\"user/repo\",\"url\":\"https://github.com/user/homebrew-repo\",\"commit_sha\":\"" ++ sha_old ++ "\",\"host\":\"github.com\"}," ++
            "{\"name\":\"grp/tap\",\"url\":\"https://gitlab.com/grp/tap\",\"commit_sha\":null,\"host\":\"gitlab.com\"}" ++
            "]\n",
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
    // --repo <owner>/<exact-repo>: pin the GitHub repo identifier for
    //   third-party taps whose repo does not carry the `homebrew-` prefix.
    // --force: rebind an existing row to a new --repo target, clearing
    //   the stale commit pin in the process.
    var refresh_target: ?[]const u8 = null;
    var refresh_all = false;
    var pin_slug: ?[]const u8 = null;
    var pin_sha: ?[]const u8 = null;
    var yes = false;
    var force = false;
    var repo_override: ?[]const u8 = null;
    // --host <forge-host>: register the tap against a non-GitHub forge.
    // --url <repo-url>: derive (host, owner, repo) from a full repo URL.
    // --forge <name>: pin the provider explicitly when the host can't
    //   reveal it (a custom-domain GitLab like code.acme.com).
    var host_flag: ?[]const u8 = null;
    var url_flag: ?[]const u8 = null;
    var forge_flag: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            if (action != .add) {
                output.err("--repo is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            if (i + 1 >= args.len) {
                output.err("Usage: mt tap <slug> --repo <owner>/<exact-repo>", .{});
                return error.Aborted;
            }
            repo_override = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--repo=")) {
            if (action != .add) {
                output.err("--repo is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            repo_override = arg["--repo=".len..];
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (action != .add) {
                output.err("--host is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            if (i + 1 >= args.len) {
                output.err("Usage: mt tap <slug> --host <forge-host>", .{});
                return error.Aborted;
            }
            host_flag = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            if (action != .add) {
                output.err("--host is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            host_flag = arg["--host=".len..];
        } else if (std.mem.eql(u8, arg, "--url")) {
            if (action != .add) {
                output.err("--url is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            if (i + 1 >= args.len) {
                output.err("Usage: mt tap <slug> --url https://<host>/<owner>/<repo>", .{});
                return error.Aborted;
            }
            url_flag = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--url=")) {
            if (action != .add) {
                output.err("--url is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            url_flag = arg["--url=".len..];
        } else if (std.mem.eql(u8, arg, "--forge")) {
            if (action != .add) {
                output.err("--forge is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            if (i + 1 >= args.len) {
                output.err("Usage: mt tap <slug> --host <host> --forge <provider> --repo <owner>/<repo>", .{});
                return error.Aborted;
            }
            forge_flag = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--forge=")) {
            if (action != .add) {
                output.err("--forge is only valid with `mt tap`", .{});
                return error.Aborted;
            }
            forge_flag = arg["--forge=".len..];
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

    // --repo / --force only make sense on the add path with a positional
    // slug. Refuse early so silent drops don't masquerade as success.
    if (repo_override != null) {
        if (refresh_all or refresh_target != null or pin_slug != null) {
            output.err("--repo cannot be combined with --refresh or --pin", .{});
            return error.Aborted;
        }
        if (positional == null) {
            output.err("Usage: mt tap <user>/<repo> --repo <owner>/<exact-repo>", .{});
            return error.Aborted;
        }
    }
    if (force and repo_override == null) {
        output.err("--force is only valid alongside --repo", .{});
        return error.Aborted;
    }

    // --url already carries host + owner/repo, so pairing it with --host
    // or --repo is contradictory. Refuse rather than silently pick one.
    if (url_flag != null and (host_flag != null or repo_override != null)) {
        output.err("--url cannot be combined with --host or --repo", .{});
        return error.Aborted;
    }
    // --host / --url need a positional slug to name the tap locally.
    if ((host_flag != null or url_flag != null) and positional == null) {
        output.err("Usage: mt tap <slug> --host <host> --repo <owner>/<repo>  (or --url <repo-url>)", .{});
        return error.Aborted;
    }
    if ((host_flag != null or url_flag != null) and
        (refresh_all or refresh_target != null or pin_slug != null))
    {
        output.err("--host/--url cannot be combined with --refresh or --pin", .{});
        return error.Aborted;
    }
    // Validate the forge host up front so an invalid `--host` reports the
    // real problem rather than a downstream "needs --repo" hint.
    if (host_flag) |h| validateForgeHost(h) catch {
        output.err("Invalid --host '{s}'. Expected a bare HTTPS host like gitlab.com (no scheme, no path).", .{h});
        return error.Aborted;
    };

    // --forge only resolves a custom-domain instance, so it needs a host
    // to pin. Map it to a known provider up front; an unknown name is a
    // typo, not a silent github fallback.
    var forge_hint: ?forge.Forge = null;
    if (forge_flag) |f| {
        // Checked before the host requirement so a `--forge --refresh` slip
        // gets the precise reason, not a misleading "needs --host".
        if (refresh_all or refresh_target != null or pin_slug != null) {
            output.err("--forge cannot be combined with --refresh or --pin", .{});
            return error.Aborted;
        }
        if (host_flag == null and url_flag == null) {
            output.err("--forge requires --host or --url (it pins the provider for a custom-domain instance).", .{});
            return error.Aborted;
        }
        forge_hint = std.meta.stringToEnum(forge.Forge, f) orelse {
            output.err("Unknown --forge '{s}'. Supported: github, gitlab, codeberg.", .{f});
            return error.Aborted;
        };
    }

    const prefix = atomic.maltPrefixOrAbort();

    // Listing-intent under `--json` needs a parseable empty array even on a
    // fresh prefix where `db/` doesn't exist — otherwise `jq` chokes on
    // silently-empty stdout. Detect intent from already-parsed argv.
    const is_listing = positional == null and pin_slug == null and
        refresh_target == null and !refresh_all;

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix with no `db/` yet = no taps registered.
        if (is_listing and output.isJson()) output.writeStdoutAll("[]\n");
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
        defer {
            for (taps) |t| {
                allocator.free(t.name);
                allocator.free(t.url);
                allocator.free(t.host);
                if (t.commit_sha) |sha| allocator.free(sha);
            }
            allocator.free(taps);
        }

        if (output.isJson()) {
            // Route through `output.writeStdoutAll` so tests can capture the
            // payload; one writeAll keeps a closed pipe from tearing the doc.
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try writeTapListJson(&aw.writer, taps);
            output.writeStdoutAll(aw.written());
            return;
        }

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
            // --url carries (host, owner, repo); --repo overrides the pair
            // on the chosen host; otherwise the helper reads the row,
            // falling back to the slug-derived `(user, "homebrew-" || repo)`
            // default — github.com only.
            const chosen_host: []const u8 = host_flag orelse "github.com";
            const target_pair = pair: {
                if (url_flag) |u| break :pair parseRepoUrl(allocator, u) catch |e| switch (e) {
                    error.InvalidRepoUrl => {
                        output.err("Invalid --url '{s}'. Expected https://<host>/<owner>/<repo>.", .{u});
                        return error.Aborted;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (repo_override) |rep| break :pair parseRepoOverride(allocator, rep, chosen_host) catch |e| switch (e) {
                    error.InvalidRepoOverride => {
                        output.err("Invalid --repo '{s}'. Expected: owner/exact-repo with [A-Za-z0-9._-]", .{rep});
                        return error.Aborted;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                break :pair tap_mod.effectiveOwnerRepo(allocator, &db, name, chosen_host) catch |e| switch (e) {
                    error.ExplicitRepoRequired => {
                        output.err("Registering a {s} tap needs an explicit repo — add --repo <owner>/<repo> or use --url <repo-url>. The homebrew-<repo> default only applies to github.com.", .{chosen_host});
                        return error.Aborted;
                    },
                    else => return e,
                };
            };
            defer target_pair.deinit(allocator);

            // Rebind policy: refuse if a row already pins a different
            // (owner, repo, host) unless --force. Matches the pin-stays-sticky
            // posture of `tap_mod.add`'s COALESCE on commit_sha.
            const stored_opt = tap_mod.getOwnerRepo(allocator, &db, name) catch null;
            defer if (stored_opt) |p| p.deinit(allocator);
            var rebinding = false;
            if (stored_opt) |stored| {
                const same = std.mem.eql(u8, stored.owner, target_pair.owner) and
                    std.mem.eql(u8, stored.repo, target_pair.repo) and
                    std.mem.eql(u8, stored.host, target_pair.host);
                if (!same) {
                    if (!force) {
                        output.err("Tap {s} is already bound to {s}/{s} on {s}. Re-run with --force to rebind to {s}/{s} on {s}.", .{ name, stored.owner, stored.repo, stored.host, target_pair.owner, target_pair.repo, target_pair.host });
                        return error.Aborted;
                    }
                    rebinding = true;
                }
            }

            // Off-GitHub forges register unpinned (no network at add time);
            // the row carries the host and, when the host can't reveal the
            // provider, an explicit `--forge` hint so resolution targets the
            // right forge. Rebinding onto another forge needs the host-aware
            // rebind a later task brings, so refuse it rather than half-apply.
            if (!std.mem.eql(u8, target_pair.host, "github.com")) {
                if (rebinding) {
                    output.err("Rebinding {s} onto {s} isn't supported yet — run `mt untap {s}` then re-register.", .{ name, target_pair.host, name });
                    return error.Aborted;
                }
                tap_mod.addWithForge(&db, name, target_pair.owner, target_pair.repo, target_pair.host, forge_hint, null) catch {
                    output.err("Failed to register tap {s}", .{name});
                    return error.Aborted;
                };
                output.info("Registered {s} → {s}/{s} on {s} (unpinned). Run `mt tap --refresh {s}` to pin its HEAD commit.", .{ name, target_pair.owner, target_pair.repo, target_pair.host, name });
                return;
            }

            // Apply the rebind before any HTTP work. Clearing the pin
            // upfront means a network failure leaves the row in the
            // "needs refresh" state rather than half-rebound with stale
            // SHA + new (owner, repo).
            if (rebinding) {
                tap_mod.rebind(&db, name, target_pair.owner, target_pair.repo) catch {
                    output.err("Failed to rebind tap {s}", .{name});
                    return error.Aborted;
                };
            }

            const urls = try forge.buildBaseUrls(allocator, .github, "github.com", target_pair.owner, target_pair.repo);
            defer urls.deinit(allocator);

            // Idempotent re-adds reuse the cached etag for stable taps —
            // a rebind cleared both fields above, so this is null on
            // that path.
            const cached_sha_opt = tap_mod.getCommitSha(allocator, &db, name) catch null;
            defer if (cached_sha_opt) |s| allocator.free(s);
            const cached_etag_opt = tap_mod.getHeadEtag(allocator, &db, name) catch null;
            defer if (cached_etag_opt) |e| allocator.free(e);

            var rerr_buf: [512]u8 = undefined;
            var head_res = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.forge, urls.api_head_url, cached_etag_opt) catch |e| {
                output.err("Could not resolve {s}'s HEAD commit: {s}", .{ name, tap_mod.describeResolveError(&rerr_buf, e, urls.forge, urls.host) });
                // Rebind already moved (owner, repo) and cleared the pin —
                // the row is unfetchable until `mt tap --refresh {slug}` lands a fresh SHA.
                if (rebinding) output.warn("Rebind applied with no pin — run `mt tap --refresh {s}` to recover.", .{name});
                return error.Aborted;
            };
            defer head_res.deinit();
            const sha = if (head_res.not_modified)
                (cached_sha_opt orelse {
                    output.err("Could not resolve {s}'s HEAD commit: 304 without cached sha", .{name});
                    return error.Aborted;
                })
            else
                (head_res.sha orelse {
                    output.err("Could not resolve {s}'s HEAD commit: empty response", .{name});
                    return error.Aborted;
                });
            tap_mod.add(&db, name, target_pair.owner, target_pair.repo, sha) catch {
                output.err("Failed to add tap {s}", .{name});
                return error.Aborted;
            };
            // Stamp the etag in the same row so the next resolve sends
            // If-None-Match. Best-effort — a failure here only costs us
            // an extra API call on the next round, never a wrong sha.
            // 304 path keeps the cached etag — it's still current.
            if (!head_res.not_modified) {
                if (head_res.etag) |et| tap_mod.updateHead(&db, name, sha, et) catch {};
            }
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

    // The row's forge selects both the `commits/<sha>` endpoint and the
    // parse/auth, so the pin is validated against the tap's own forge —
    // a non-github tap never 404s at api.github.com. The host names the
    // forge in failures (not a hard-coded "GitHub").
    const pair = try tap_mod.effectiveOwnerRepo(allocator, db, slug, "github.com");
    defer pair.deinit(allocator);

    // Route reachability through the same HTTP path as HEAD resolution so a
    // 200 here proves the SHA is fetchable from the exact repo subsequent
    // installs will use. /commits/<sha> is sha-pinned so the ETag has no
    // caching value — pass null and ignore any etag the server returns.
    const commit_url = try tap_mod.resolveCommitUrl(allocator, db, slug, sha);
    defer allocator.free(commit_url);
    var perr_buf: [512]u8 = undefined;
    var echoed_res = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, pair.forge, commit_url, null) catch |e| {
        if (e == error.NotFound) {
            output.err("Cannot pin {s} @ {s}: {s} has no such commit on this tap.", .{ slug, sha[0..@min(sha.len, 7)], pair.host });
        } else {
            output.err("Could not verify {s} @ {s}: {s}", .{ slug, sha[0..@min(sha.len, 7)], tap_mod.describeResolveError(&perr_buf, e, pair.forge, pair.host) });
        }
        return error.Aborted;
    };
    defer echoed_res.deinit();
    const echoed = echoed_res.sha orelse {
        output.err("Cannot pin {s} @ {s}: {s} returned an empty response.", .{ slug, sha[0..@min(sha.len, 7)], pair.host });
        return error.Aborted;
    };

    // Defensive: the forge's `commits/<sha>` echoes the resolved full SHA.
    // If it differs, treat as unreachable rather than store a mismatched pin.
    if (!std.mem.eql(u8, echoed, sha)) {
        output.err("Cannot pin {s} @ {s}: {s} returned a different SHA.", .{ slug, sha[0..@min(sha.len, 7)], pair.host });
        return error.Aborted;
    }

    tap_mod.add(db, slug, pair.owner, pair.repo, sha) catch {
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
            allocator.free(t.host);
            if (t.commit_sha) |sha| allocator.free(sha);
        }
        allocator.free(taps);
    }

    // Resolve each tap's HEAD up-front so the diff display reflects the
    // full plan before any write happens — including the case where the
    // user immediately passes `--yes`. Etag travels alongside the sha so
    // the post-confirm apply step writes both atomically via updateHead.
    var new_shas: std.ArrayList(?[]const u8) = .empty;
    var new_etags: std.ArrayList(?[]const u8) = .empty;
    defer {
        for (new_shas.items) |maybe_sha| if (maybe_sha) |sha| allocator.free(sha);
        new_shas.deinit(allocator);
        for (new_etags.items) |maybe_et| if (maybe_et) |et| allocator.free(et);
        new_etags.deinit(allocator);
    }
    try new_shas.ensureTotalCapacityPrecise(allocator, taps.len);
    try new_etags.ensureTotalCapacityPrecise(allocator, taps.len);

    var rows: std.ArrayList(RefreshRow) = .empty;
    defer rows.deinit(allocator);
    try rows.ensureTotalCapacityPrecise(allocator, taps.len);

    for (taps) |t| {
        const pair = resolveOneHead(ctx, allocator, db, t.name) catch null;
        const new_sha: ?[]const u8 = if (pair) |p| p.sha else null;
        const new_et: ?[]const u8 = if (pair) |p| p.etag else null;
        new_shas.appendAssumeCapacity(new_sha);
        new_etags.appendAssumeCapacity(new_et);
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
    // failed has no SHA to write. updateHead atomically pairs the new
    // sha with its etag — the next non-refresh resolve short-circuits.
    for (rows.items, new_etags.items) |row, maybe_et| {
        if (row.status != .moved) continue;
        const new_sha = row.new_sha orelse continue;
        tap_mod.updateHead(db, row.name, new_sha, maybe_et) catch {
            output.err("Failed to update commit pin for {s}", .{row.name});
            return error.Aborted;
        };
    }
}

/// Resolve a tap's HEAD on the `--refresh` path. Caller takes ownership
/// of both `sha` and `etag`; deinit by freeing each individually.
const RefreshedHead = struct { sha: []const u8, etag: ?[]const u8 };

fn resolveOneHead(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    slug: []const u8,
) !RefreshedHead {
    const urls = try tap_mod.resolveTapBaseUrls(allocator, db, slug);
    defer urls.deinit(allocator);
    // `tap --refresh` is the explicit "force fresh" verb — never send
    // If-None-Match so a stale-but-unmoved upstream still surfaces a
    // fresh body and the operator can confirm the tap really hasn't
    // budged. Per task implementation notes.
    var res = try tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.forge, urls.api_head_url, null);
    defer res.deinit();
    const sha = res.sha orelse return error.MalformedJson;
    const sha_owned = try allocator.dupe(u8, sha);
    errdefer allocator.free(sha_owned);
    const et_owned: ?[]const u8 = if (res.etag) |e| try allocator.dupe(u8, e) else null;
    return .{ .sha = sha_owned, .etag = et_owned };
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
    const urls = try tap_mod.resolveTapBaseUrls(allocator, db, name);
    defer urls.deinit(allocator);
    // Force fresh: bypass the cached etag so the operator sees the
    // current body. The new etag is still persisted afterwards so the
    // *next* non-refresh resolve can short-circuit.
    var rerr_buf: [512]u8 = undefined;
    var res = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.forge, urls.api_head_url, null) catch |e| {
        output.err("Could not resolve {s}'s HEAD commit: {s}", .{ name, tap_mod.describeResolveError(&rerr_buf, e, urls.forge, urls.host) });
        return error.Aborted;
    };
    defer res.deinit();
    const sha = res.sha orelse {
        output.err("Could not resolve {s}'s HEAD commit: empty response", .{name});
        return error.Aborted;
    };
    // updateHead pairs the new sha with the new etag atomically; falling
    // back to updateCommit if the row is absent isn't a concern here —
    // refresh runs against rows the user already `tap added`.
    tap_mod.updateHead(db, name, sha, res.etag) catch {
        output.err("Failed to update commit pin for {s}", .{name});
        return error.Aborted;
    };
    output.info("Refreshed {s} to {s}", .{ name, sha[0..@min(sha.len, 7)] });
}
