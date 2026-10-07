//! malt — doctor "Bottles built for a newer macOS" integration tests.
//!
//! Seeds a scratch prefix with keg rows and cached formula documents, then
//! drives the probe with the host injected so the verdicts do not depend on
//! the machine running the suite.

const std = @import("std");
const builtin = @import("builtin");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const doctor = malt.doctor;
const bottle_host = doctor.bottle_host;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;
const api = malt.api;

const io = std.Options.debug_io;
const arch = if (builtin.cpu.arch == .aarch64) "arm64_" else "";
const newer_tag = arch ++ "golden_gate";
const host_tag = arch ++ "tahoe";
const host_major: u32 = 26;
const sha_a = "a" ** 64;
const sha_b = "b" ** 64;
const sha_c = "c" ** 64;

const Scratch = struct {
    path: []const u8,
    cache: []const u8,
    db: sqlite.Database,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const path = try test_io.uniqueTempPath(allocator, "doctor_bottle_host", tag);
        errdefer allocator.free(path);
        test_io.deleteTreeAbsolute(io, path) catch {};
        const cache = try std.fmt.allocPrint(allocator, "{s}/cache", .{path});
        errdefer allocator.free(cache);
        for ([_][]const u8{ "db", "cache/api" }) |sd| {
            const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, sd });
            defer allocator.free(dir);
            try test_io.cwd().createDirPath(io, dir);
        }
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{path}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .path = path, .cache = cache, .db = db };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        self.db.close();
        test_io.deleteTreeAbsolute(io, self.path) catch {};
        allocator.free(self.cache);
        allocator.free(self.path);
    }

    /// A keg row recording `sha`, plus (unless `files` is null) its cached
    /// formula document carrying `files` as the bottle map.
    fn seed(self: *Scratch, name: []const u8, tap: ?[]const u8, sha: []const u8, files: ?[]const u8) !void {
        var sql_buf: [1024]u8 = undefined;
        const tap_sql = if (tap) |t| try std.fmt.allocPrint(testing.allocator, "'{s}'", .{t}) else try testing.allocator.dupe(u8, "NULL");
        defer testing.allocator.free(tap_sql);
        const sql = try std.fmt.bufPrintSentinel(&sql_buf,
            \\INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path)
            \\VALUES ('{s}', '{s}', '1.0', 0, {s}, '{s}', '{s}/Cellar/{s}/1.0');
        , .{ name, name, tap_sql, sha, self.path, name }, 0);
        try self.db.exec(sql);

        const body = files orelse return;
        const doc = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"name\":\"{s}\",\"full_name\":\"{s}\",\"versions\":{{\"stable\":\"1.0\"}},\"revision\":0,\"bottle\":{{\"stable\":{{\"root_url\":\"https://x\",\"files\":{{{s}}}}}}}}}",
            .{ name, name, body },
        );
        defer testing.allocator.free(doc);
        var path_buf: [512]u8 = undefined;
        const doc_path = try std.fmt.bufPrint(&path_buf, "{s}/api/formula_{s}.json", .{ self.cache, name });
        try test_io.cwd().writeFile(io, .{ .sub_path = doc_path, .data = doc });
    }
};

/// The bulk-dump side-car `mt outdated` leaves behind.
fn writeBottlesIndex(s: *const Scratch, body: []const u8) !void {
    var buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/api/bottles_" ++ api.bottles_key ++ ".txt", .{s.cache});
    try test_io.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

/// A thin Mach-O declaring `minos_major` as its macOS floor, at
/// `Cellar/<name>/1.0/<rel>`; `fat` wraps it as this arch's slice.
fn writeKegBinary(s: *const Scratch, name: []const u8, rel: []const u8, minos_major: u32, fat: bool) !void {
    const macho = std.macho;
    const hs = @sizeOf(macho.mach_header_64);
    const cs = @sizeOf(macho.build_version_command);
    var thin: [hs + cs]u8 = @splat(0);
    std.mem.bytesAsValue(macho.mach_header_64, thin[0..hs]).* = .{ .magic = macho.MH_MAGIC_64, .ncmds = 1, .sizeofcmds = cs };
    std.mem.bytesAsValue(macho.build_version_command, thin[hs..][0..cs]).* = .{ .cmdsize = cs, .platform = .MACOS, .minos = minos_major << 16, .sdk = 0, .ntools = 0 };

    var buf: [64 + thin.len]u8 = @splat(0);
    const bytes: []const u8 = if (fat) blk: {
        const cpu: macho.cpu_type_t = if (builtin.cpu.arch == .aarch64) macho.CPU_TYPE_ARM64 else macho.CPU_TYPE_X86_64;
        std.mem.writeInt(u32, buf[0..4], macho.FAT_MAGIC, .big);
        std.mem.writeInt(u32, buf[4..8], 1, .big);
        std.mem.writeInt(i32, buf[8..12], cpu, .big);
        std.mem.writeInt(u32, buf[16..20], 64, .big);
        std.mem.writeInt(u32, buf[20..24], thin.len, .big);
        @memcpy(buf[64..], &thin);
        break :blk &buf;
    } else &thin;

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/Cellar/{s}/1.0/{s}", .{ s.path, name, rel });
    try test_io.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try test_io.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn bottle(comptime tag: []const u8, comptime sha: []const u8) []const u8 {
    return "\"" ++ tag ++ "\":{\"cellar\":\":any\",\"url\":\"https://x/b\",\"sha256\":\"" ++ sha ++ "\"}";
}

test "collect names each too-new core keg with the remedy that will work" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "remedies");
    defer s.deinit(allocator);
    try s.seed("regnone", null, sha_a, comptime bottle(newer_tag, sha_a));
    try s.seed("regreinst", "homebrew/core", sha_b, comptime bottle(newer_tag, sha_b) ++ "," ++ bottle(host_tag, sha_c));
    try s.seed("regok", null, sha_c, comptime bottle(host_tag, sha_c));

    var report = bottle_host.collect(allocator, io, s.path, s.cache, host_major);
    defer report.deinit(allocator);

    try testing.expectEqual(@as(u32, 1), report.reinstall);
    try testing.expectEqual(@as(u32, 1), report.uninstall);
    try testing.expectEqual(@as(usize, 2), report.lines.items.len);
    try testing.expectEqualStrings("regnone: no bottle for this macOS — mt uninstall regnone", report.lines.items[0]);
    try testing.expectEqualStrings("regreinst: mt reinstall regreinst", report.lines.items[1]);
}

test "collect skips kegs the core document cannot speak for" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "skips");
    defer s.deinit(allocator);
    const too_new = comptime bottle(newer_tag, sha_a);
    // A tap or `--local` keg's digest is a coincidence against the core
    // document, a keg adopted from brew's Cellar records no digest, and an
    // uncached keg has nothing to compare against.
    try s.seed("tapkeg", "user/tools", sha_a, too_new);
    try s.seed("localkeg", "local", sha_a, too_new);
    try s.seed("migrated", null, "", too_new);
    try s.seed("uncached", null, sha_a, null);

    var report = bottle_host.collect(allocator, io, s.path, s.cache, host_major);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(u32, 0), report.count());
    // Only the uncached core keg is one the check failed to look at.
    try testing.expectEqual(@as(u32, 1), report.unchecked);
    try testing.expectEqual(@as(usize, 1), report.unchecked_lines.items.len);
    try testing.expectEqualStrings("uncached: not checked", report.unchecked_lines.items[0]);
}

test "collect checks a keg from the bulk side-car when its own document is gone" {
    // `mt update` wipes per-formula documents; `mt outdated` rebuilds only
    // the bulk side-car, which must be enough to check every keg.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "side_car");
    defer s.deinit(allocator);
    try writeBottlesIndex(&s, "regside\t" ++ newer_tag ++ "=" ++ sha_a ++ "\n" ++
        "regreinst\t" ++ newer_tag ++ "=" ++ sha_b ++ "," ++ host_tag ++ "=" ++ sha_c ++ "\n" ++
        "regok\t" ++ host_tag ++ "=" ++ sha_c ++ "\n" ++
        "unbottled\t\n");
    try s.seed("regside", null, sha_a, null);
    try s.seed("regreinst", null, sha_b, null);
    try s.seed("regok", null, sha_c, null);
    try s.seed("unbottled", null, sha_a, null);
    try s.seed("gone", null, sha_a, null); // in neither source

    var report = bottle_host.collect(allocator, io, s.path, s.cache, host_major);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(u32, 1), report.reinstall);
    try testing.expectEqual(@as(u32, 1), report.uninstall);
    try testing.expectEqual(@as(u32, 1), report.unchecked);
    try testing.expectEqualStrings("regreinst: mt reinstall regreinst", report.lines.items[0]);
    try testing.expectEqualStrings("regside: no bottle for this macOS — mt uninstall regside", report.lines.items[1]);
    try testing.expectEqualStrings("gone: not checked", report.unchecked_lines.items[0]);
}

test "collect reads neither outside the API cache nor a corrupt document" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "untrusted");
    defer s.deinit(allocator);

    // `x/../../escaped` would resolve to `<cache>/escaped.json`; plant a damning
    // document there so only the name check keeps it unread.
    var buf: [512]u8 = undefined;
    try test_io.cwd().createDirPath(io, try std.fmt.bufPrint(&buf, "{s}/api/formula_x", .{s.cache}));
    try s.seed("x/../../escaped", null, sha_a, null);
    try test_io.cwd().writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&buf, "{s}/escaped.json", .{s.cache}),
        .data = "{\"name\":\"escaped\",\"full_name\":\"escaped\",\"versions\":{\"stable\":\"1.0\"},\"revision\":0," ++
            "\"bottle\":{\"stable\":{\"root_url\":\"https://x\",\"files\":{" ++ comptime bottle(newer_tag, sha_a) ++ "}}}}",
    });

    try s.seed("corrupt", null, sha_a, null);
    try test_io.cwd().writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&buf, "{s}/api/formula_corrupt.json", .{s.cache}),
        .data = "{not json",
    });

    var report = bottle_host.collect(allocator, io, s.path, s.cache, host_major);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(u32, 0), report.count());
    // The corrupt document is a keg left unchecked; the forged name is no keg.
    try testing.expectEqual(@as(u32, 1), report.unchecked);
}

test "a keg whose digest no bottle carries any more is judged by its binaries" {
    // A same-version rebuild moves the digest on; the floor dyld enforces
    // is still in the keg's own Mach-O headers.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "floor");
    defer s.deinit(allocator);
    const rebuilt = comptime bottle(host_tag, sha_c);
    try s.seed("rebuilt_new", null, sha_a, rebuilt);
    try writeKegBinary(&s, "rebuilt_new", "bin/tool", 27, false);
    try s.seed("rebuilt_fat", null, sha_a, comptime bottle(newer_tag, sha_b));
    try writeKegBinary(&s, "rebuilt_fat", "lib/libx.dylib", 27, true);
    try s.seed("rebuilt_ok", null, sha_a, rebuilt);
    try writeKegBinary(&s, "rebuilt_ok", "bin/tool", host_major, false);
    try s.seed("scripts_only", null, sha_a, rebuilt);
    var dir_buf: [512]u8 = undefined;
    try test_io.cwd().createDirPath(io, try std.fmt.bufPrint(&dir_buf, "{s}/Cellar/scripts_only/1.0/bin", .{s.path}));
    // A conclusive digest is never second-guessed by a header read.
    try s.seed("digest_ok", null, sha_c, rebuilt);
    try writeKegBinary(&s, "digest_ok", "bin/tool", 27, false);

    var report = bottle_host.collect(allocator, io, s.path, s.cache, host_major);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(u32, 1), report.reinstall);
    try testing.expectEqual(@as(u32, 1), report.uninstall);
    try testing.expectEqualStrings("rebuilt_fat: no bottle for this macOS — mt uninstall rebuilt_fat", report.lines.items[0]);
    try testing.expectEqualStrings("rebuilt_new: mt reinstall rebuilt_new", report.lines.items[1]);
}

test "collect never flags on an unreadable host version" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "null_host");
    defer s.deinit(allocator);
    try s.seed("regnone", null, sha_a, comptime bottle(newer_tag, sha_a));

    var report = bottle_host.collect(allocator, io, s.path, s.cache, null);
    defer report.deinit(allocator);
    try testing.expectEqual(@as(u32, 0), report.count());
}

test "the doctor walk carries the row, so --json reports it" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "walk");
    defer s.deinit(allocator);

    const prior = output.isQuiet();
    output.setQuiet(true);
    defer output.setQuiet(prior);
    var result = doctor.collectFindings(allocator, .{
        .allocator = allocator,
        .prefix = s.path,
        .io = io,
        .environ = .empty,
    }, &doctor.checks, true);
    defer result.deinit();

    for (result.findings()) |f| {
        if (std.mem.eql(u8, f.id, "bottles_built_for_a_newer_macos")) {
            try testing.expectEqual(doctor.CheckStatus.ok, f.severity);
            return;
        }
    }
    return error.MissingBottleHostFinding;
}
