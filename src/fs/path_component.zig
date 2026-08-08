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

/// True when `s` is a usable *relative subpath* — one or more components that
/// stay inside the directory it is resolved against. Unlike `isPathComponent`
/// it tolerates `/`, because some tap-controlled strings legitimately nest
/// (`binary "bin/tool"`, `app "Sub/My App.app"`). It still bars what hops out:
/// empty, absolute, a `..` component, an empty component (`a//b`), or a NUL.
///
/// `..` is rejected component-wise, not as a substring — a name like
/// `foo..bar` is a real filename and must survive.
pub fn isRelativeSubpath(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, s, 0) != null) return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return false; // leading, trailing, or doubled '/'
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

test "isRelativeSubpath rejects shapes that leave the base directory" {
    const bad = [_][]const u8{
        "",          "/abs/path", "..",   "../x",
        "a/../../b", "a/b/..",    "a//b", "a/",
        "/",         "a\x00b",    "../",  "sub/../../../etc",
    };
    for (bad) |s| try std.testing.expect(!isRelativeSubpath(s));
}

test "isRelativeSubpath accepts the nested names real casks ship" {
    const ok = [_][]const u8{
        "Firefox.app",        "Sub Dir/My App.app", "bin/tool",
        "a..b",               "foo..bar/baz",       "codex-aarch64-apple-darwin",
        "share/man/man1/x.1",
    };
    for (ok) |s| try std.testing.expect(isRelativeSubpath(s));
}

test "isPathComponent rejects component-hopping shapes" {
    const bad = [_][]const u8{ "", ".", "..", "a/b", "../evil", "foo/", "a..b", "1..0", "a\x00b" };
    for (bad) |s| try std.testing.expect(!isPathComponent(s));
}

test "isPathComponent accepts real names and versions" {
    const ok = [_][]const u8{ "com.malt.redis", "openssl@3", "gtk+", "3.2.1+dfsg", "1.2,340:5", "a b" };
    for (ok) |s| try std.testing.expect(isPathComponent(s));
}
