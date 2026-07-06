//! One definition of "safe path component" for tap-controlled strings.
//! Formula names/versions, cask tokens/versions, and service labels all reach
//! disk as single directory components; every ingestion point screens here.

const std = @import("std");

/// True when `s` is a usable single path component. Charset-agnostic so real
/// names/versions (`@`, `+`, `,`, `:`, dots) pass — it bars only what hops out
/// of a component: empty, `.`, an embedded `..`, a `/`, or a NUL.
pub fn isPathComponent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, ".")) return false;
    if (std.mem.indexOf(u8, s, "..") != null) return false; // also rejects ".."
    if (std.mem.indexOfScalar(u8, s, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, s, 0) != null) return false;
    return true;
}

test "isPathComponent rejects component-hopping shapes" {
    const bad = [_][]const u8{ "", ".", "..", "a/b", "../evil", "foo/", "a..b", "1..0", "a\x00b" };
    for (bad) |s| try std.testing.expect(!isPathComponent(s));
}

test "isPathComponent accepts real names and versions" {
    const ok = [_][]const u8{ "com.malt.redis", "openssl@3", "gtk+", "3.2.1+dfsg", "1.2,340:5", "a b" };
    for (ok) |s| try std.testing.expect(isPathComponent(s));
}
