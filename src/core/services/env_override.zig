//! Per-service `<name>.env` overrides a user keeps outside the keg, so a
//! setting like `PGPORT=5433` survives the plist being re-rendered.
//!
//! Grammar: `KEY=VALUE` lines, blank lines and `#` comments; no quoting,
//! no expansion. The value is everything after the first `=`, verbatim.

const std = @import("std");
const plist = @import("plist.zig");
const types = @import("types.zig");

pub const EnvPair = types.EnvPair;

/// Larger than any sane override file; bounds the read.
pub const max_bytes: usize = 64 * 1024;

pub const Error = error{ MissingEquals, BadKey, BadValue, ReservedKey, OutOfMemory };

/// Where a parse failed, 1-based, for the warning.
pub const Diag = struct { line: usize = 0 };

/// All or nothing: one bad line refuses the file, so a typo never
/// half-applies.
pub fn parse(aa: std.mem.Allocator, bytes: []const u8, diag: *Diag) Error![]EnvPair {
    var out: std.ArrayList(EnvPair) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 0;
    while (it.next()) |raw| {
        line_no += 1;
        diag.line = line_no;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const lead = std.mem.trimStart(u8, line, " \t");
        if (lead.len == 0 or lead[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.MissingEquals;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (!isKey(key)) return error.BadKey;
        if (isReserved(key)) return error.ReservedKey;
        // NUL cuts the plist string short, a lone CR is not a line end, and
        // an over-long value would fail validation for the whole service.
        if (value.len > plist.max_arg_len or std.mem.indexOfAny(u8, value, "\x00\r") != null) return error.BadValue;
        // launchd refuses a plist string that is not UTF-8.
        if (!std.unicode.utf8ValidateSlice(value)) return error.BadValue;
        try out.append(aa, .{ .key = try aa.dupe(u8, key), .value = try aa.dupe(u8, value) });
    }
    return out.toOwnedSlice(aa);
}

fn isKey(key: []const u8) bool {
    if (key.len == 0 or key.len > plist.max_arg_len or std.ascii.isDigit(key[0])) return false;
    for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

// Guards against foot-guns, not attacks: the job must keep malt's search
// path and home, and `DYLD_*` breaks the argv-only launch. Who may write
// the file is the injection boundary, checked where it is opened.
fn isReserved(key: []const u8) bool {
    return std.mem.eql(u8, key, "PATH") or std.mem.eql(u8, key, "HOME") or std.mem.startsWith(u8, key, "DYLD_");
}

/// Overrides win key-for-key; new keys append in file order.
pub fn merge(aa: std.mem.Allocator, base: []const EnvPair, overrides: []const EnvPair) error{OutOfMemory}![]EnvPair {
    var out: std.ArrayList(EnvPair) = .empty;
    try out.appendSlice(aa, base);
    next: for (overrides) |o| {
        for (out.items) |*p| if (std.mem.eql(u8, p.key, o.key)) {
            p.value = o.value;
            continue :next;
        };
        try out.append(aa, o);
    }
    return out.toOwnedSlice(aa);
}

const testing = std.testing;

fn expectPairs(want: []const EnvPair, got: []const EnvPair) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(w.key, g.key);
        try testing.expectEqualStrings(w.value, g.value);
    }
}

fn parseStr(aa: std.mem.Allocator, bytes: []const u8) Error![]EnvPair {
    var diag: Diag = .{};
    return parse(aa, bytes, &diag);
}

test "parse reads KEY=VALUE lines and skips blanks and comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parseStr(arena.allocator(),
        \\# local postgres
        \\PGPORT=5433
        \\
        \\   # indented comment
        \\LC_ALL=en_US.UTF-8
    );
    try expectPairs(&.{ .{ .key = "PGPORT", .value = "5433" }, .{ .key = "LC_ALL", .value = "en_US.UTF-8" } }, got);
}

test "parse keeps the value verbatim: no quote stripping, no expansion, later = kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parseStr(arena.allocator(), "A=\"q\"\nB=$HOME/x\nC=a=b # not a comment\nD=\n_E1=  x  \n");
    try expectPairs(&.{
        .{ .key = "A", .value = "\"q\"" },
        .{ .key = "B", .value = "$HOME/x" },
        .{ .key = "C", .value = "a=b # not a comment" },
        .{ .key = "D", .value = "" },
        .{ .key = "_E1", .value = "  x  " },
    }, got);
}

test "parse drops a CRLF line ending instead of leaking CR into the value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try parseStr(arena.allocator(), "A=1\r\nB=2\r\n");
    try expectPairs(&.{ .{ .key = "A", .value = "1" }, .{ .key = "B", .value = "2" } }, got);
}

test "parse of an empty or comment-only file yields no pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try parseStr(arena.allocator(), "")).len);
    try testing.expectEqual(@as(usize, 0), (try parseStr(arena.allocator(), "# only\n\n")).len);
}

test "parse rejects malformed lines and reports the 1-based line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const Case = struct { src: []const u8, err: Error, line: usize };
    const cases = [_]Case{
        .{ .src = "A=1\nnoequals\n", .err = error.MissingEquals, .line = 2 },
        .{ .src = "=x\n", .err = error.BadKey, .line = 1 },
        .{ .src = "1A=x\n", .err = error.BadKey, .line = 1 },
        .{ .src = "A-B=x\n", .err = error.BadKey, .line = 1 },
        .{ .src = "export A=x\n", .err = error.BadKey, .line = 1 },
        .{ .src = " A=x\n", .err = error.BadKey, .line = 1 },
        .{ .src = "A =x\n", .err = error.BadKey, .line = 1 },
        .{ .src = "A=x\x00y\n", .err = error.BadValue, .line = 1 },
        .{ .src = "A=x\ry\n", .err = error.BadValue, .line = 1 },
        // A Latin-1 file: launchd rejects a plist string that is not UTF-8.
        .{ .src = "A=caf\xe9\n", .err = error.BadValue, .line = 1 },
    };
    for (cases) |c| {
        var diag: Diag = .{};
        try testing.expectError(c.err, parse(aa, c.src, &diag));
        try testing.expectEqual(c.line, diag.line);
    }
}

test "parse refuses a key or value launchd validation would reject, so the service still registers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const long = "x" ** (plist.max_arg_len + 1);
    var diag: Diag = .{};
    try testing.expectError(error.BadValue, parse(aa, "A=" ++ long, &diag));
    try testing.expectError(error.BadKey, parse(aa, "A" ++ long ++ "=1", &diag));
    // Exactly at the limit is still a value validation accepts.
    try testing.expectEqual(@as(usize, 1), (try parse(aa, "A=" ++ "x" ** plist.max_arg_len, &diag)).len);
}

test "parse refuses PATH, HOME and every DYLD_ key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "PATH=/x", "HOME=/x", "DYLD_INSERT_LIBRARIES=/x.dylib", "DYLD_=x" }) |line| {
        var diag: Diag = .{};
        try testing.expectError(error.ReservedKey, parse(arena.allocator(), line, &diag));
    }
    // Case-sensitive like the environment itself; only the exact names are reserved.
    const got = try parseStr(arena.allocator(), "PATHS=1\nMYHOME=2\nXDYLD_A=3\n");
    try testing.expectEqual(@as(usize, 3), got.len);
}

test "merge overrides a formula key in place and appends new keys in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try merge(
        arena.allocator(),
        &.{ .{ .key = "LC_ALL", .value = "en_US.UTF-8" }, .{ .key = "PATH", .value = "/opt/malt/bin" } },
        &.{ .{ .key = "PGPORT", .value = "5433" }, .{ .key = "LC_ALL", .value = "C" }, .{ .key = "PGPORT", .value = "5434" } },
    );
    try expectPairs(&.{
        .{ .key = "LC_ALL", .value = "C" },
        .{ .key = "PATH", .value = "/opt/malt/bin" },
        .{ .key = "PGPORT", .value = "5434" },
    }, got);
}

test "merge with no overrides keeps the formula environment unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base = [_]EnvPair{.{ .key = "A", .value = "1" }};
    try expectPairs(&base, try merge(arena.allocator(), &base, &.{}));
    try testing.expectEqual(@as(usize, 0), (try merge(arena.allocator(), &.{}, &.{})).len);
}
