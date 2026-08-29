//! What a valid install prefix is, and how to build a path from one.
//! The bound, the charset, the validator and the path-join primitives live
//! together so the rule and the number it enforces cannot drift apart.

const std = @import("std");

/// 512 bytes: ~4× real Homebrew prefix length, still small enough that
/// anything past it is either a bug or overflow bait. `fs/atomic.zig`
/// re-exports it for its env boundary.
pub const max_prefix_len: usize = 512;

/// Longest fixed suffix any caller appends (`/cache/migrate.progress.json`
/// = 28 B today); 64 leaves ~2× headroom for new fixed suffixes.
pub const max_path_suffix: usize = 64;

pub const PrefixError = error{
    Empty,
    NotAbsolute,
    DotDotComponent,
    EmbeddedNul,
    TooLong,
    EmptyComponent,
    DisallowedByte,
};

/// Single source of truth for the prefix charset. Matches
/// `validatePathForProfile` in `core/sandbox/macos.zig` so anything that
/// passes here is safe to interpolate into a Ruby single-quoted literal,
/// a sandbox-profile path string, or a shell argv.
pub fn isAllowedPrefixByte(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '+', '-', '/' => true,
        else => false,
    };
}

/// Validate a candidate install prefix. Called at the env boundary so
/// downstream code can assume absolute, NUL-free, traversal-free.
pub fn validatePrefix(prefix: []const u8) PrefixError!void {
    if (prefix.len == 0) return PrefixError.Empty;
    if (prefix.len > max_prefix_len) return PrefixError.TooLong;
    if (prefix[0] != '/') return PrefixError.NotAbsolute;
    if (std.mem.indexOfScalar(u8, prefix, 0) != null) return PrefixError.EmbeddedNul;
    // Tight charset closes the BUG-007/BUG-019 injection class — quotes,
    // backslashes, control bytes, parens etc. flow into single-quoted
    // Ruby literals and sandbox-profile strings unchanged.
    for (prefix) |b| if (!isAllowedPrefixByte(b)) return PrefixError.DisallowedByte;

    // Strip one trailing slash; `/opt/malt/` is fine, `//` inside is not.
    const trimmed = if (prefix.len > 1 and prefix[prefix.len - 1] == '/')
        prefix[0 .. prefix.len - 1]
    else
        prefix;
    if (trimmed.len == 1) return; // just "/" — no components to scan

    var it = std.mem.splitScalar(u8, trimmed, '/');
    _ = it.next(); // leading "/" yields an empty first slice
    while (it.next()) |comp| {
        if (comp.len == 0) return PrefixError.EmptyComponent;
        if (std.mem.eql(u8, comp, "..")) return PrefixError.DotDotComponent;
    }
}

pub fn describePrefixError(e: PrefixError) []const u8 {
    return switch (e) {
        PrefixError.Empty => "empty",
        PrefixError.NotAbsolute => "not an absolute path",
        PrefixError.DotDotComponent => "contains '..' component",
        PrefixError.EmbeddedNul => "contains NUL byte",
        PrefixError.TooLong => "exceeds 512 bytes",
        PrefixError.EmptyComponent => "contains empty path component ('//')",
        PrefixError.DisallowedByte => "contains a byte outside [a-zA-Z0-9._+-/]",
    };
}

/// Buffer size a call site must reserve so a validated prefix plus any
/// fixed suffix always fits without overflow.
pub const path_buf_len: usize = max_prefix_len + max_path_suffix;

comptime {
    std.debug.assert(max_prefix_len + max_path_suffix <= path_buf_len);
}

/// Format `base ++ suffix` into `buf`, returning the slice. Overflow maps to
/// a typed `error.NameTooLong` instead of truncating silently, so callers
/// fail loud. `suffix` is comptime so its length is checked against the
/// reserved headroom at build time.
pub fn join(buf: []u8, base: []const u8, comptime suffix: []const u8) error{NameTooLong}![]u8 {
    comptime std.debug.assert(suffix.len <= max_path_suffix);
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, suffix }) catch error.NameTooLong;
}

/// NUL-terminated variant of `join` for `sqlite.Database.open` sites that
/// need a `[:0]u8`. Overflow (including the sentinel byte) maps to
/// `error.NameTooLong`.
pub fn joinZ(buf: []u8, base: []const u8, comptime suffix: []const u8) error{NameTooLong}![:0]u8 {
    comptime std.debug.assert(suffix.len <= max_path_suffix);
    return std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ base, suffix }, 0) catch error.NameTooLong;
}

test "join fits" {
    var buf: [8]u8 = undefined;
    const s = try join(&buf, "abc", "/x");
    try std.testing.expectEqualStrings("abc/x", s);
}

test "join overflows into error.NameTooLong" {
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, join(&buf, "abcdef", "/xyz"));
}

test "join exact-fit boundary returns full slice" {
    var buf: [5]u8 = undefined;
    const s = try join(&buf, "abc", "/x");
    try std.testing.expectEqual(@as(usize, 5), s.len);
    try std.testing.expectEqualStrings("abc/x", s);
}

test "joinZ is NUL-terminated" {
    var buf: [8]u8 = undefined;
    const s = try joinZ(&buf, "abc", "/x");
    try std.testing.expectEqualStrings("abc/x", s);
    try std.testing.expect(buf[s.len] == 0);
}

test "joinZ overflows at the sentinel boundary" {
    // base+suffix == 5 fits a [5]u8, but the NUL needs a 6th byte.
    var buf: [5]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, joinZ(&buf, "abc", "/x"));
}

test "joinZ exact-fit boundary returns full slice" {
    // content 5 + NUL 1 == 6: a [6]u8 must accept, not over-reject by one.
    var buf: [6]u8 = undefined;
    const s = try joinZ(&buf, "abc", "/x");
    try std.testing.expectEqualStrings("abc/x", s);
    try std.testing.expect(buf[s.len] == 0);
}

test "bound constants are consistent" {
    try std.testing.expectEqual(@as(usize, 512), max_prefix_len);
    try std.testing.expectEqual(max_prefix_len + max_path_suffix, path_buf_len);
}

test "validatePrefix: default path is accepted" {
    try validatePrefix("/opt/malt");
}

test "validatePrefix: tmp sandbox prefix is accepted" {
    try validatePrefix("/tmp/malt_test_prefix");
}

test "validatePrefix: root '/' is accepted" {
    // Root alone is technically absolute and has no bad components; we
    // don't get to veto unusual-but-syntactically-valid prefixes.
    try validatePrefix("/");
}

test "validatePrefix: trailing slash is tolerated" {
    try validatePrefix("/opt/malt/");
}

test "validatePrefix: empty string rejected" {
    try std.testing.expectError(error.Empty, validatePrefix(""));
}

test "validatePrefix: relative path rejected" {
    try std.testing.expectError(error.NotAbsolute, validatePrefix("opt/malt"));
    try std.testing.expectError(error.NotAbsolute, validatePrefix("./malt"));
    try std.testing.expectError(error.NotAbsolute, validatePrefix("malt"));
}

test "validatePrefix: .. component rejected" {
    try std.testing.expectError(error.DotDotComponent, validatePrefix("/opt/../etc"));
    try std.testing.expectError(error.DotDotComponent, validatePrefix("/.."));
    try std.testing.expectError(error.DotDotComponent, validatePrefix("/opt/malt/.."));
}

test "validatePrefix: NUL byte rejected" {
    try std.testing.expectError(error.EmbeddedNul, validatePrefix("/opt/\x00malt"));
    try std.testing.expectError(error.EmbeddedNul, validatePrefix("/opt/malt\x00"));
}

test "validatePrefix: length > max_prefix_len rejected" {
    var buf: [max_prefix_len + 1]u8 = undefined;
    @memset(&buf, 'a');
    buf[0] = '/';
    try std.testing.expectError(error.TooLong, validatePrefix(&buf));
}

test "validatePrefix: length == max_prefix_len accepted" {
    var buf: [max_prefix_len]u8 = undefined;
    @memset(&buf, 'a');
    buf[0] = '/';
    try validatePrefix(&buf);
}

test "validatePrefix: '//' inside rejected" {
    try std.testing.expectError(error.EmptyComponent, validatePrefix("/opt//malt"));
    try std.testing.expectError(error.EmptyComponent, validatePrefix("//opt/malt"));
}

test "validatePrefix: single dot component is permitted (not our job to canonicalise)" {
    // A lone `.` is a valid filesystem path component; we only reject
    // the traversal primitive `..`. Keeping this permissive avoids
    // surprising users on paths like /opt/./malt.
    try validatePrefix("/opt/./malt");
}

test "validatePrefix: dotdot-like-but-not-exact component accepted" {
    // Make sure we don't over-match on .. — names like `foo..bar` are
    // not path traversal.
    try validatePrefix("/opt/foo..bar");
    try validatePrefix("/opt/..malt");
    try validatePrefix("/opt/malt..");
}

test "validatePrefix: single quote rejected" {
    try std.testing.expectError(error.DisallowedByte, validatePrefix("/tmp/m'x"));
}

test "validatePrefix: double quote rejected" {
    try std.testing.expectError(error.DisallowedByte, validatePrefix("/tmp/m\"x"));
}

test "validatePrefix: backslash rejected" {
    try std.testing.expectError(error.DisallowedByte, validatePrefix("/tmp/m\\x"));
}

test "validatePrefix: newline rejected" {
    try std.testing.expectError(error.DisallowedByte, validatePrefix("/tmp/m\nx"));
}

test "validatePrefix: control bytes rejected" {
    // 0x01 .. 0x1f and 0x7f all constitute injection-grade noise in any
    // shell-or-Ruby context the prefix flows into.
    var path: [10]u8 = "/tmp/m_x_y".*;
    inline for (.{ 0x01, 0x07, 0x1b, 0x1f, 0x7f }) |b| {
        path[6] = b;
        try std.testing.expectError(error.DisallowedByte, validatePrefix(&path));
    }
}

test "validatePrefix: valid-but-unusual chars accepted (+ . - _)" {
    // Real-world prefixes may include `+` (e.g. `/opt/malt+1.0`),
    // `-` (`/opt/foo-bar`), `.`, `_`. They must keep passing.
    try validatePrefix("/opt/malt+1.0");
    try validatePrefix("/opt/foo-bar.baz_qux");
    try validatePrefix("/opt/MALT");
}

test "describePrefixError: DisallowedByte has a descriptive string" {
    const desc = describePrefixError(error.DisallowedByte);
    try std.testing.expect(desc.len > 0);
}

// The charset is what closes the Ruby-wrapper / sandbox-profile injection
// vector: a prefix carrying a quote, backslash or control byte breaks out of
// the single-quoted literal each of those generators interpolates it into.
test "isAllowedPrefixByte: charset matches the documented contract" {
    // Centralised predicate used by prefix/name/version validation.
    // Contract: [a-zA-Z0-9._+\-/].
    const allowed = "abcXYZ0123456789._+-/";
    for (allowed) |b| try std.testing.expect(isAllowedPrefixByte(b));
    const denied = "'\"\\\n\t (){}[]$|;&<>*?#";
    for (denied) |b| try std.testing.expect(!isAllowedPrefixByte(b));
    // Control bytes: every byte below 0x20 plus DEL.
    var b: u8 = 0;
    while (b < 0x20) : (b += 1) try std.testing.expect(!isAllowedPrefixByte(b));
    try std.testing.expect(!isAllowedPrefixByte(0x7f));
    // High bit: not in the allowed set either.
    try std.testing.expect(!isAllowedPrefixByte(0x80));
    try std.testing.expect(!isAllowedPrefixByte(0xff));
}

test "describePrefixError: every error has a descriptive string" {
    // Compile-time-ish coverage: every arm of the switch must return
    // something non-empty so error output is useful.
    const cases = [_]PrefixError{
        error.Empty,
        error.NotAbsolute,
        error.DotDotComponent,
        error.EmbeddedNul,
        error.TooLong,
        error.EmptyComponent,
    };
    for (cases) |e| {
        const desc = describePrefixError(e);
        try std.testing.expect(desc.len > 0);
    }
}
