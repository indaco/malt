//! Canonical tap identity — the one place a `user/repo` tap slug is
//! folded to the single form every layer keys on.
//!
//! A leaf on purpose: both `core/tap.zig` (URL synthesis, registry
//! writes) and `db/schema.zig` (the migration that repairs stored rows)
//! need it, and a leaf cannot import `core`. Sharing the runtime helper
//! is what keeps the migration from drifting away from the live rule.

const std = @import("std");

/// Buffer size every caller should use for a slug. `validateTapName`
/// caps a component at 64, but `parseTapName` on the install path does
/// not validate length at all, and GitHub itself allows 39 + 100 — so
/// size to the forge's limit, not malt's.
pub const max_slug_len = 256;

/// Fold a validated `user/repo` slug to Homebrew's canonical identity:
/// both components ASCII-downcased, and one anchored `homebrew-` /
/// `linuxbrew-` stripped from the repo component. The stripped form is
/// the *identity*; the git repo is addressed as `homebrew-<repo>` on top
/// of it, which is why `linuxbrew-x` and `homebrew-x` collapse together.
///
/// Returns `null` on a slug with no `/` or a `buf` too small — callers
/// already validate the shape and fail on their own terms.
///
/// The strip is not looped: `user/homebrew-homebrew-x` canonicalizes to
/// `user/homebrew-x`, matching brew's anchored regex.
pub fn canonicalTapSlug(buf: []u8, slug: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, slug, '/') orelse return null;
    const user = slug[0..slash];
    var repo = slug[slash + 1 ..];

    // Compare case-insensitively: the downcase happens on the way out,
    // so `Homebrew-Tap` must strip too.
    for ([_][]const u8{ "homebrew-", "linuxbrew-" }) |prefix| {
        if (repo.len > prefix.len and std.ascii.eqlIgnoreCase(repo[0..prefix.len], prefix)) {
            repo = repo[prefix.len..];
            break;
        }
    }

    if (user.len + 1 + repo.len > buf.len) return null;
    _ = std.ascii.lowerString(buf[0..user.len], user);
    buf[user.len] = '/';
    _ = std.ascii.lowerString(buf[user.len + 1 ..][0..repo.len], repo);
    return buf[0 .. user.len + 1 + repo.len];
}

/// The git repo a canonical slug's `repo` component addresses. Homebrew
/// always re-prefixes the stripped identity, which is why a `linuxbrew-`
/// input still ends up at a `homebrew-` repo. Kept beside
/// `canonicalTapSlug` so the strip and the re-prefix can never drift.
///
/// Returns `null` when `buf` cannot hold the result.
pub fn synthRepo(buf: []u8, canonical_repo: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "homebrew-{s}", .{canonical_repo}) catch null;
}

test "synthRepo re-prefixes the stripped identity" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("homebrew-tap", synthRepo(&buf, "tap").?);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(synthRepo(&tiny, "tap") == null);
}

test "canonicalTapSlug strips one homebrew- prefix from the repo component" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("indaco/tap", canonicalTapSlug(&buf, "indaco/homebrew-tap").?);
    try std.testing.expectEqualStrings("indaco/tap", canonicalTapSlug(&buf, "indaco/tap").?);
    // Anchored, not looped — brew leaves the inner prefix in place.
    try std.testing.expectEqualStrings("indaco/homebrew-tap", canonicalTapSlug(&buf, "indaco/homebrew-homebrew-tap").?);
}

test "canonicalTapSlug folds linuxbrew- onto the same identity as homebrew-" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("u/x", canonicalTapSlug(&buf, "u/linuxbrew-x").?);
    try std.testing.expectEqualStrings("u/x", canonicalTapSlug(&buf, "u/homebrew-x").?);
}

test "canonicalTapSlug downcases both components" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "haseebkhalid1507/tap",
        canonicalTapSlug(&buf, "HaseebKhalid1507/Homebrew-Tap").?,
    );
    try std.testing.expectEqualStrings("homebrew/core", canonicalTapSlug(&buf, "Homebrew/homebrew-core").?);
}

test "canonicalTapSlug leaves a prefix that is the whole repo component alone" {
    var buf: [128]u8 = undefined;
    // Stripping would leave an empty repo, which is not a tap identity.
    try std.testing.expectEqualStrings("u/homebrew-", canonicalTapSlug(&buf, "u/homebrew-").?);
    try std.testing.expectEqualStrings("u/homebrew", canonicalTapSlug(&buf, "u/homebrew").?);
}

test "canonicalTapSlug rejects a slug with no slash and a buffer that cannot hold the result" {
    var buf: [128]u8 = undefined;
    try std.testing.expect(canonicalTapSlug(&buf, "noslash") == null);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(canonicalTapSlug(&tiny, "user/repo") == null);
    // Exactly-fitting buffers are accepted.
    var exact: [9]u8 = undefined;
    try std.testing.expectEqualStrings("user/repo", canonicalTapSlug(&exact, "user/repo").?);
}

test "canonicalTapSlug preserves the dots, underscores and dashes validateComponent allows" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("my.user_1/my-tap.rb", canonicalTapSlug(&buf, "My.User_1/Homebrew-My-Tap.RB").?);
}
