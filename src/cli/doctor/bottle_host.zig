//! malt — doctor probe for kegs poured from a bottle built for a newer macOS.
//!
//! Bottle selection once ignored the host version, so a keg on disk can hold
//! binaries dyld refuses. The keg's recorded digest names the bottle it came
//! from; the bulk side-car or the cached formula document maps it to a tag.

const std = @import("std");
const output = @import("../../ui/output.zig");
const signals = @import("../../core/signals.zig");
const schema_report = @import("../schema_report.zig");
const formula_mod = @import("../../core/formula.zig");
const api_mod = @import("../../net/api.zig");
const cask_variation = @import("../../net/cask_variation.zig");
const install_args = @import("../install/args.zig");
const parser = @import("../../macho/parser.zig");

pub const Remedy = enum { reinstall, uninstall };
const Files = std.json.ArrayHashMap(formula_mod.BottleFile);

/// Whether `store_sha256` is the digest of a bottle built only for a macOS
/// newer than the host. A digest names one bottle, so a match is conclusive
/// whatever version the document describes; no match yields no verdict.
pub fn pouredTooNew(
    files: Files,
    store_sha256: []const u8,
    host_major: ?u32,
) bool {
    const host = host_major orelse return false; // same policy as bottleKey
    var newer = false;
    var it = files.map.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.value_ptr.sha256, store_sha256)) continue;
        // One loadable tag sharing the digest makes it a loadable bottle.
        const major = cask_variation.tagMajor(e.key_ptr.*) orelse return false;
        if (major <= host) return false;
        newer = true;
    }
    return newer;
}

/// Whether any bottle in `files` still carries `store_sha256`.
fn carriesDigest(files: Files, store_sha256: []const u8) bool {
    for (files.map.values()) |f| if (std.mem.eql(u8, f.sha256, store_sha256)) return true;
    return false;
}

/// The fix for a keg poured too new, or null when it is fine. A digest no
/// bottle carries any more (a rebuild, a moved-on version) falls back to
/// `keg_floor`, the macOS its binaries require. `reinstall` only works when a
/// bottle for this macOS exists.
pub fn remedyFor(files: Files, store_sha256: []const u8, host_major: ?u32, keg_floor: ?u32) ?Remedy {
    const host = host_major orelse return null;
    const too_new = pouredTooNew(files, store_sha256, host) or
        (!carriesDigest(files, store_sha256) and (keg_floor orelse 0) > host);
    if (!too_new) return null;
    var buf: [32]u8 = undefined;
    return if (cask_variation.bottleKey(&buf, files.map, host_major) == null) .uninstall else .reinstall;
}

pub const Report = struct {
    reinstall: u32 = 0,
    uninstall: u32 = 0,
    unchecked: u32 = 0,
    /// One `--verbose` line per flagged keg, naming its remedy.
    lines: std.ArrayList([]u8) = .empty,
    /// One `--verbose` line per keg there was no data to check.
    unchecked_lines: std.ArrayList([]u8) = .empty,

    pub fn count(self: Report) u32 {
        return self.reinstall + self.uninstall;
    }

    fn addUnchecked(self: *Report, allocator: std.mem.Allocator, name: []const u8) void {
        self.unchecked += 1;
        const line = std.fmt.allocPrint(allocator, "{s}: not checked", .{name}) catch return;
        self.unchecked_lines.append(allocator, line) catch allocator.free(line);
    }

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.lines.items) |l| allocator.free(l);
        self.lines.deinit(allocator);
        for (self.unchecked_lines.items) |l| allocator.free(l);
        self.unchecked_lines.deinit(allocator);
    }
};

/// Walk the core kegs and classify each against the bulk side-car, falling
/// back to its own cached formula document.
/// ponytail: cache-only, so a keg in neither is only counted as unchecked;
/// reading its binaries' LC_BUILD_VERSION would cover it, at a full Mach-O walk.
pub fn collect(
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []const u8,
    cache_dir: []const u8,
    host_major: ?u32,
) Report {
    var report: Report = .{};
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return report;
    var db = schema_report.openPreviewable(io, db_path, output.isDryRun()) catch return report;
    defer db.close();
    var stmt = db.prepare("SELECT name, tap, store_sha256, cellar_path FROM kegs ORDER BY name;") catch return report;
    defer stmt.finalize();

    const index_bytes = api_mod.readBottlesIndex(io, allocator, cache_dir);
    defer if (index_bytes) |b| allocator.free(b);
    var index: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer index.deinit(allocator);
    if (index_bytes) |b| {
        var it = std.mem.splitScalar(u8, b, '\n');
        while (it.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            index.put(allocator, line[0..tab], line[tab + 1 ..]) catch break;
        }
    }

    while (stmt.step() catch false) {
        if (signals.isInterrupted()) break;
        const name = std.mem.sliceTo(stmt.columnText(0) orelse continue, 0);
        const tap = if (stmt.columnText(1)) |t| std.mem.sliceTo(t, 0) else "";
        const sha = std.mem.sliceTo(stmt.columnText(2) orelse continue, 0);
        const keg_path = if (stmt.columnText(3)) |p| std.mem.sliceTo(p, 0) else "";
        // A tap or `--local` keg's digest is not in the core document.
        if (!install_args.isCoreTap(tap)) continue;
        // The name builds a cache path; a hand-edited row must not escape it.
        api_mod.validateName(name) catch continue;

        const verdict: ?Remedy = blk: {
            if (index.get(name)) |tags| {
                var files = parseTags(allocator, tags) catch {
                    report.addUnchecked(allocator, name);
                    continue;
                };
                defer files.deinit(allocator);
                break :blk judge(io, files, sha, keg_path, host_major);
            }
            const bytes = api_mod.readCacheAt(io, allocator, cache_dir, name, api_mod.BrewApi.prefixForKind(.formula)) orelse {
                report.addUnchecked(allocator, name);
                continue;
            };
            defer allocator.free(bytes);
            var formula = formula_mod.parseFormula(allocator, bytes) catch {
                report.addUnchecked(allocator, name);
                continue;
            };
            defer formula.deinit();
            break :blk judge(io, formula.bottle_files orelse break :blk null, sha, keg_path, host_major);
        };
        const remedy = verdict orelse continue;
        const line = switch (remedy) {
            .reinstall => std.fmt.allocPrint(allocator, "{s}: mt reinstall {s}", .{ name, name }),
            .uninstall => std.fmt.allocPrint(allocator, "{s}: no bottle for this macOS — mt uninstall {s}", .{ name, name }),
        } catch continue;
        report.lines.append(allocator, line) catch {
            allocator.free(line);
            continue;
        };
        switch (remedy) {
            .reinstall => report.reinstall += 1,
            .uninstall => report.uninstall += 1,
        }
    }
    return report;
}

/// `remedyFor`, reading the keg's binaries only when the digest cannot decide.
fn judge(io: std.Io, files: Files, sha: []const u8, keg_path: []const u8, host_major: ?u32) ?Remedy {
    const floor = if (host_major == null or carriesDigest(files, sha)) null else kegMacosFloor(io, keg_path);
    return remedyFor(files, sha, host_major, floor);
}

/// The macOS floor of the first Mach-O under the keg's `bin/` or `lib/`.
/// ponytail: one binary per keg, since Homebrew builds a keg against one
/// deployment target; a vendored older binary found first would hide it.
fn kegMacosFloor(io: std.Io, keg_path: []const u8) ?u32 {
    if (!std.fs.path.isAbsolute(keg_path)) return null;
    var keg = std.Io.Dir.openDirAbsolute(io, keg_path, .{}) catch return null;
    defer keg.close(io);
    for ([_][]const u8{ "bin", "lib" }) |sub| {
        var dir = keg.openDir(io, sub, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (binaryMacosFloor(io, dir, entry.name)) |floor| return floor;
        }
    }
    return null;
}

/// Reads only the first 16 KiB of the file (of this arch's slice when fat):
/// the load commands sit there, and kegs hold multi-megabyte dylibs.
fn binaryMacosFloor(io: std.Io, dir: std.Io.Dir, name: []const u8) ?u32 {
    const file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var n = file.readPositionalAll(io, &buf, 0) catch return null;
    if (parser.hostSliceOffset(buf[0..n])) |offset| n = file.readPositionalAll(io, &buf, offset) catch return null;
    return parser.minMacosMajor(buf[0..n]);
}

/// A side-car line's `<tag>=<sha256>,...` as a bottle map borrowing from it.
fn parseTags(allocator: std.mem.Allocator, tags: []const u8) !Files {
    var files: Files = .{};
    errdefer files.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, tags, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        try files.map.put(allocator, pair[0..eq], .{ .cellar = "", .url = "", .sha256 = pair[eq + 1 ..] });
    }
    return files;
}

const unchecked_note = "not checked: no cached formula data (mt outdated refreshes it)";

/// The row's detail, or null when there is nothing to say. Unchecked kegs are
/// named so an emptied cache never reads as an all-clear.
pub fn detail(buf: []u8, report: Report) ?[]const u8 {
    const fallback = "Some kegs were poured from a bottle built for a newer macOS; reinstall or uninstall them.";
    if (report.count() == 0) {
        if (report.unchecked == 0) return null;
        return std.fmt.bufPrint(buf, "{d} keg(s) " ++ unchecked_note, .{report.unchecked}) catch unchecked_note;
    }
    const head = std.fmt.bufPrint(
        buf,
        "{d} keg(s) were poured from a bottle built for a newer macOS and may fail to load: {d} to reinstall (mt reinstall <name>), {d} with no bottle for this macOS (mt uninstall <name>)",
        .{ report.count(), report.reinstall, report.uninstall },
    ) catch return fallback;
    if (report.unchecked == 0) return head;
    const tail = std.fmt.bufPrint(buf[head.len..], "; {d} more " ++ unchecked_note, .{report.unchecked}) catch return head;
    return buf[0 .. head.len + tail.len];
}

const testing = std.testing;
const arch = if (@import("builtin").cpu.arch == .aarch64) "arm64_" else "";
const sha_a = "a" ** 64;
const sha_b = "b" ** 64;

// Comptime literal: parseFormula may borrow from its input.
fn parseDoc(comptime files_json: []const u8) !formula_mod.Formula {
    return formula_mod.parseFormula(testing.allocator, "{\"name\":\"x\",\"full_name\":\"x\",\"versions\":{\"stable\":\"1.0\"},\"revision\":0," ++
        "\"bottle\":{\"stable\":{\"root_url\":\"https://x\",\"files\":{" ++ files_json ++ "}}}}");
}

fn bottle(comptime tag: []const u8, comptime sha: []const u8) []const u8 {
    return "\"" ++ tag ++ "\":{\"cellar\":\":any\",\"url\":\"https://x/b\",\"sha256\":\"" ++ sha ++ "\"}";
}

test "a digest only a newer macOS's bottle carries is flagged" {
    var f = try parseDoc(comptime bottle(arch ++ "golden_gate", sha_a) ++ "," ++ bottle(arch ++ "tahoe", sha_b));
    defer f.deinit();
    try testing.expect(pouredTooNew(f.bottle_files.?, sha_a, 26));
}

test "a digest from the host's own, an older, or the all bottle is fine" {
    var f = try parseDoc(comptime bottle(arch ++ "tahoe", sha_a) ++ "," ++ bottle(arch ++ "sonoma", sha_b) ++ "," ++ bottle("all", "c" ** 64));
    defer f.deinit();
    try testing.expect(!pouredTooNew(f.bottle_files.?, sha_a, 26));
    try testing.expect(!pouredTooNew(f.bottle_files.?, sha_b, 26));
    try testing.expect(!pouredTooNew(f.bottle_files.?, "c" ** 64, 26));
}

test "a digest on a tag this build cannot place is never flagged" {
    // A codename newer than the map, or another arch's tag: no floor to compare.
    const other = if (arch.len == 0) "arm64_golden_gate" else "golden_gate";
    var f = try parseDoc(comptime bottle("arm64_future_os", sha_a) ++ "," ++ bottle(other, sha_b));
    defer f.deinit();
    try testing.expect(!pouredTooNew(f.bottle_files.?, sha_a, 26));
    try testing.expect(!pouredTooNew(f.bottle_files.?, sha_b, 26));
}

test "a digest shared by a newer and a loadable tag is the same loadable bottle" {
    // Homebrew reuses one bottle across tags when its binaries run on both.
    var f = try parseDoc(comptime bottle(arch ++ "golden_gate", sha_a) ++ "," ++ bottle(arch ++ "tahoe", sha_a));
    defer f.deinit();
    try testing.expect(!pouredTooNew(f.bottle_files.?, sha_a, 26));
}

test "no verdict without a digest match, a recorded digest, or a known host" {
    var f = try parseDoc(comptime bottle(arch ++ "golden_gate", sha_a));
    defer f.deinit();
    // A version bump or rebuild moved the digest on: a miss, never a false
    // alarm. A keg adopted from brew's Cellar records an empty digest, which
    // never matches: the parser drops malformed ones.
    try testing.expect(!pouredTooNew(f.bottle_files.?, sha_b, 26));
    try testing.expect(!pouredTooNew(f.bottle_files.?, "", 26));
    try testing.expect(!pouredTooNew(f.bottle_files.?, sha_a, null));
}

test "remedyFor points at reinstall only when this macOS has a bottle" {
    var reinst = try parseDoc(comptime bottle(arch ++ "golden_gate", sha_a) ++ "," ++ bottle(arch ++ "tahoe", sha_b));
    defer reinst.deinit();
    try testing.expectEqual(@as(?Remedy, .reinstall), remedyFor(reinst.bottle_files.?, sha_a, 26, null));
    try testing.expectEqual(@as(?Remedy, null), remedyFor(reinst.bottle_files.?, sha_b, 26, null));

    // `mt reinstall` would fail with NoBottleAvailable here.
    var none = try parseDoc(comptime bottle(arch ++ "golden_gate", sha_a));
    defer none.deinit();
    try testing.expectEqual(@as(?Remedy, .uninstall), remedyFor(none.bottle_files.?, sha_a, 26, null));
}

test "remedyFor trusts the binaries' floor only when no bottle carries the digest" {
    var f = try parseDoc(comptime bottle(arch ++ "tahoe", sha_b));
    defer f.deinit();
    // sha_a was rebuilt away: the keg's own floor decides.
    try testing.expectEqual(@as(?Remedy, .reinstall), remedyFor(f.bottle_files.?, sha_a, 26, 27));
    try testing.expectEqual(@as(?Remedy, null), remedyFor(f.bottle_files.?, sha_a, 26, 26));
    try testing.expectEqual(@as(?Remedy, null), remedyFor(f.bottle_files.?, sha_a, 26, null));
    try testing.expectEqual(@as(?Remedy, null), remedyFor(f.bottle_files.?, sha_a, null, 27));
    // A digest the map still carries is conclusive, whatever a header says.
    try testing.expectEqual(@as(?Remedy, null), remedyFor(f.bottle_files.?, sha_b, 26, 27));
}

test "detail names both remedies with their counts" {
    var buf: [512]u8 = undefined;
    const text = detail(&buf, .{ .reinstall = 2, .uninstall = 1 }).?;
    try testing.expect(std.mem.startsWith(u8, text, "3 keg(s)"));
    try testing.expect(std.mem.indexOf(u8, text, "2 to reinstall (mt reinstall <name>)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1 with no bottle for this macOS (mt uninstall <name>)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not checked") == null);
}

test "detail admits kegs it could not check instead of a bare all-clear" {
    // `mt update` wipes the API cache, so right after it nothing is checkable.
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "4 keg(s) not checked: no cached formula data (mt outdated refreshes it)",
        detail(&buf, .{ .unchecked = 4 }).?,
    );
    const both = detail(&buf, .{ .uninstall = 1, .unchecked = 4 }).?;
    try testing.expect(std.mem.startsWith(u8, both, "1 keg(s) were poured"));
    try testing.expect(std.mem.endsWith(u8, both, "; 4 more not checked: no cached formula data (mt outdated refreshes it)"));
}

test "detail is silent when every keg checked out" {
    var buf: [512]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), detail(&buf, .{}));
}

test "a damaged side-car line yields only the pairs it can read" {
    var files = try parseTags(testing.allocator, "junk,," ++ arch ++ "tahoe=" ++ sha_a ++ ",=x");
    defer files.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), files.map.count());
    try testing.expectEqualStrings(sha_a, files.map.get(arch ++ "tahoe").?.sha256);
    // An empty tag can never be placed, so it can never flag a keg.
    try testing.expect(!pouredTooNew(files, "x", 26));
}
