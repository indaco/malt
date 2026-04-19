//! malt — update origin detection tests.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const origin = malt.update_origin;

const Case = struct {
    path: []const u8,
    want: origin.Origin,
};

test "classify covers every install shape the updater must distinguish" {
    const cases = [_]Case{
        // Direct: install.sh, manual copy, build output.
        .{ .path = "/usr/local/bin/malt", .want = .direct },
        .{ .path = "/opt/malt/bin/malt", .want = .direct },
        .{ .path = "/Users/alice/bin/malt", .want = .direct },
        .{ .path = "/tmp/malt-bench-main/build/malt", .want = .direct },
        // Unresolved brew shim — by contract, callers resolve first.
        .{ .path = "/opt/homebrew/bin/malt", .want = .direct },
        // Defensive: empty must not classify as homebrew.
        .{ .path = "", .want = .direct },
        // Brew formula (Cellar) — Apple Silicon, Intel, linuxbrew.
        .{ .path = "/opt/homebrew/Cellar/malt/0.6.0/bin/malt", .want = .homebrew },
        .{ .path = "/usr/local/Cellar/malt/0.6.0/bin/malt", .want = .homebrew },
        .{ .path = "/home/linuxbrew/.linuxbrew/Cellar/malt/0.6.0/bin/malt", .want = .homebrew },
        // Brew cask (Caskroom).
        .{ .path = "/opt/homebrew/Caskroom/malt/0.6.0/malt", .want = .homebrew },
        .{ .path = "/usr/local/Caskroom/malt/0.6.0/malt", .want = .homebrew },
    };

    for (cases) |c| {
        const got = origin.classify(c.path);
        testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("classify({s}) = .{s}, want .{s}\n", .{
                c.path, @tagName(got), @tagName(c.want),
            });
            return err;
        };
    }
}

test "classify is pure — repeated calls agree" {
    const p = "/opt/homebrew/Cellar/malt/0.6.0/bin/malt";
    try testing.expectEqual(origin.Origin.homebrew, origin.classify(p));
    try testing.expectEqual(origin.Origin.homebrew, origin.classify(p));
}

test "classify is slash-anchored — no false positives on 'cellar' substrings" {
    try testing.expectEqual(origin.Origin.direct, origin.classify("/Users/alice/wine-cellar/malt"));
    try testing.expectEqual(origin.Origin.direct, origin.classify("/tmp/cellarish/malt"));
}
