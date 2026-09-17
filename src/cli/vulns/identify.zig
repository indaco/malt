//! malt — OSV query key from a recipe's source url.
//! Ports Homebrew's `Vulns::Identify`: a forge url becomes the GIT-ecosystem
//! package name OSV indexes (`https://<host>/<owner>/<repo>`) and the release
//! tag is read from the archive or asset path, else the recipe's `version`.
//! Narrower than brew on purpose: one url (no `head`/`homepage` fallback,
//! since the recipe parser keeps neither), no Wayback prefix strip, and no
//! `tag:` spec - none of which a tap keg in the wild has needed yet.

const std = @import("std");

pub const Target = struct {
    /// Borrows the caller's buffer.
    repo_url: []const u8,
    /// Borrows `url` or `version`.
    tag: []const u8,
};

/// How a forge lays out the repository in its url path.
const PathRule = enum {
    /// `/<owner>/<repo>`, whatever follows.
    two_segment,
    /// `/<group>/.../<project>` up to a route marker or the end of the url.
    gitlab,
};

const forges = std.StaticStringMap(PathRule).initComptime(.{
    .{ "github.com", .two_segment },
    .{ "codeberg.org", .two_segment },
    .{ "gitlab.com", .gitlab },
    .{ "gitlab.gnome.org", .gitlab },
    .{ "gitlab.freedesktop.org", .gitlab },
    .{ "invent.kde.org", .gitlab },
});

/// Null when the url is not on a forge OSV indexes by repository.
pub fn identify(buf: []u8, url: []const u8, version: []const u8) ?Target {
    const after_scheme = stripScheme(url) orelse return null;
    const host_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    const host = after_scheme[0..host_end];
    const path = after_scheme[host_end..];
    const repo_path = switch (forges.get(host) orelse return null) {
        .two_segment => twoSegmentPath(path),
        .gitlab => gitlabPath(path),
    } orelse return null;

    const repo_url = std.fmt.bufPrint(buf, "https://{s}/{s}", .{ host, repo_path }) catch return null;
    // OSV's GIT ecosystem lowercases github paths (GitHub itself is
    // case-insensitive); the other forges are case-sensitive and kept as is.
    if (std.mem.eql(u8, host, "github.com")) _ = std.ascii.lowerString(repo_url, repo_url);

    const tag = tagOf(url) orelse version;
    if (tag.len == 0) return null;
    return .{ .repo_url = repo_url, .tag = tag };
}

fn stripScheme(url: []const u8) ?[]const u8 {
    inline for (.{ "https://", "http://" }) |scheme| {
        if (std.mem.startsWith(u8, url, scheme)) return url[scheme.len..];
    }
    return null;
}

/// `/a/b...` -> `a/b`, with a trailing `.git` dropped.
fn twoSegmentPath(path: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    const owner = it.next() orelse return null;
    const repo = it.next() orelse return null;
    if (owner.len == 0 or repo.len == 0) return null;
    return stripGit(path[1 .. 1 + owner.len + 1 + repo.len]);
}

/// The shortest run of two or more segments that ends at a route marker or
/// the url's end; host-level `/-/` and `/api/` routes are not projects.
fn gitlabPath(path: []const u8) ?[]const u8 {
    if (path.len < 2 or path[0] != '/') return null;
    const rel = path[1..];
    if (rel[0] == '-' or std.mem.startsWith(u8, rel, "api/")) return null;
    var segments: usize = 0;
    var end: usize = 0;
    while (end < rel.len) {
        const next = std.mem.indexOfScalarPos(u8, rel, end, '/') orelse rel.len;
        if (next == end) return null;
        segments += 1;
        end = next;
        if (segments >= 2 and endsProject(rel[end..])) return stripGit(rel[0..end]);
        end += 1;
    }
    return null;
}

fn endsProject(rest: []const u8) bool {
    if (rest.len == 0 or std.mem.eql(u8, rest, "/")) return true;
    inline for (.{ "/-/", "/uploads/", "/wikis/" }) |marker| {
        if (std.mem.startsWith(u8, rest, marker)) return true;
    }
    return false;
}

fn stripGit(repo_path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, repo_path, ".git")) repo_path[0 .. repo_path.len - ".git".len] else repo_path;
}

/// The tag encoded in an archive or release-asset url, if any.
fn tagOf(url: []const u8) ?[]const u8 {
    // Archive shapes end the url: `/<marker>/<tag><suffix>`.
    inline for (.{
        .{ "/archive/refs/tags/", ".tar.gz" },
        .{ "/archive/refs/tags/", ".zip" },
        .{ "/archive/", ".tar.gz" },
        .{ "/archive/", ".zip" },
    }) |shape| {
        if (std.mem.lastIndexOf(u8, url, shape[0])) |at| {
            const rest = url[at + shape[0].len ..];
            if (std.mem.endsWith(u8, rest, shape[1])) {
                const tag = rest[0 .. rest.len - shape[1].len];
                if (tag.len > 0 and std.mem.indexOfScalar(u8, tag, '/') == null) return tag;
            }
        }
    }
    // A release asset: `/releases/download/<tag>/<file>`.
    if (std.mem.indexOf(u8, url, "/releases/download/")) |at| {
        const rest = url[at + "/releases/download/".len ..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| if (slash > 0) return rest[0..slash];
    }
    if (std.mem.lastIndexOf(u8, url, "/tarball/")) |at| {
        const tag = url[at + "/tarball/".len ..];
        if (tag.len > 0 and std.mem.indexOfScalar(u8, tag, '/') == null) return tag;
    }
    return null;
}

// --- inline unit tests --------------------------------------------------

const testing = std.testing;

fn expectTarget(repo_url: []const u8, tag: []const u8, url: []const u8, version: []const u8) !void {
    var buf: [256]u8 = undefined;
    const t = identify(&buf, url, version) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(repo_url, t.repo_url);
    try testing.expectEqualStrings(tag, t.tag);
}

test "the tag is read from each archive and asset url shape" {
    const repo = "https://github.com/o/r";
    try expectTarget(repo, "v1.2.0", "https://github.com/o/r/archive/refs/tags/v1.2.0.tar.gz", "1.2.0");
    try expectTarget(repo, "v1.2.0", "https://github.com/o/r/archive/refs/tags/v1.2.0.zip", "1.2.0");
    try expectTarget(repo, "v1.2.0", "https://github.com/o/r/archive/v1.2.0.tar.gz", "1.2.0");
    try expectTarget(repo, "v1.2.0", "https://github.com/o/r/archive/v1.2.0.zip", "1.2.0");
    try expectTarget(repo, "v1.2.0", "https://github.com/o/r/releases/download/v1.2.0/r_darwin_arm64.tar.gz", "1.2.0");
    try expectTarget(repo, "v1.2.0", "https://github.com/o/r/tarball/v1.2.0", "1.2.0");
}

test "a github path is lowercased because OSV normalises it, other forges keep case" {
    try expectTarget("https://github.com/haseebkhalid1507/myx", "v0.5.0", "https://github.com/HaseebKhalid1507/Myx/releases/download/v0.5.0/myx.tar.gz", "0.5.0");
    try expectTarget("https://codeberg.org/Owner/Repo", "v2", "https://codeberg.org/Owner/Repo/archive/v2.tar.gz", "2");
}

test "the recipe version stands in when the url carries no tag" {
    // A head `.git` url names the repo but no release.
    try expectTarget("https://github.com/bjarneo/cliamp", "2.2.0", "https://github.com/bjarneo/cliamp.git", "2.2.0");
    // A bare asset with the tag only in the file name.
    try expectTarget("https://github.com/o/r", "1.0", "https://github.com/o/r/raw/main/r-1.0.tgz", "1.0");
    var buf: [256]u8 = undefined;
    try testing.expect(identify(&buf, "https://github.com/o/r.git", "") == null);
}

test "gitlab paths keep every subgroup and stop at the route marker" {
    // GitLab archives put a file segment after the tag, which none of the
    // tag shapes accept, so the recipe version is the query key - as in brew.
    try expectTarget("https://gitlab.com/xorg/lib/libx11", "1.8", "https://gitlab.com/xorg/lib/libx11/-/archive/libX11-1.8/libx11-libX11-1.8.tar.gz", "1.8");
    try expectTarget("https://gitlab.gnome.org/GNOME/glib", "2.80", "https://gitlab.gnome.org/GNOME/glib/-/archive/2.80/glib-2.80.tar.gz", "2.80");
    try expectTarget("https://gitlab.freedesktop.org/mesa/drm", "1.0", "https://gitlab.freedesktop.org/mesa/drm.git", "1.0");
    try expectTarget("https://invent.kde.org/graphics/okular", "1.0", "https://invent.kde.org/graphics/okular/uploads/abc/okular.tar.xz", "1.0");
    var buf: [256]u8 = undefined;
    // Host-level routes are not repositories.
    try testing.expect(identify(&buf, "https://gitlab.com/api/v4/projects/1", "1.0") == null);
    try testing.expect(identify(&buf, "https://gitlab.com/-/profile", "1.0") == null);
    // One segment is never a project.
    try testing.expect(identify(&buf, "https://gitlab.com/onlyowner", "1.0") == null);
}

test "an unknown host or a truncated forge path is not identifiable" {
    var buf: [256]u8 = undefined;
    // A Wayback-wrapped url is a deliberate gap, not an oversight.
    try testing.expect(identify(&buf, "https://web.archive.org/web/20180102/https://github.com/o/r/archive/v1.tar.gz", "1") == null);
    try testing.expect(identify(&buf, "https://example.com/o/r/archive/v1.tar.gz", "1") == null);
    try testing.expect(identify(&buf, "https://github.com/onlyowner", "1") == null);
    try testing.expect(identify(&buf, "https://notgithub.com/o/r", "1") == null);
    try testing.expect(identify(&buf, "ftp://github.com/o/r", "1") == null);
    var tiny: [8]u8 = undefined;
    try testing.expect(identify(&tiny, "https://github.com/o/r", "1") == null);
}
