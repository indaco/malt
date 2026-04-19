//! malt — version update tests.
//!
//! Matcher / walker coverage moved to tests/release_test.zig alongside
//! the `src/update/release.zig` module. This file now only pins the
//! version-string sanity guard.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const version_mod = malt.version;
const updater = malt.cli_version_update;

test "version value is non-empty and trimmed" {
    try testing.expect(version_mod.value.len > 0);
    try testing.expect(version_mod.value[version_mod.value.len - 1] != '\n');
    try testing.expect(version_mod.value[version_mod.value.len - 1] != ' ');
}

// --- parseArgs ------------------------------------------------------------
//
// Flag parsing is the tiniest possible target for drift: a typo or
// refactor that silently disables `--yes` in CI could leave the updater
// prompting forever. Pin each flag's recognised forms.

test "parseArgs: no flags yields all-false" {
    const opts = updater.parseArgs(&.{});
    try testing.expect(!opts.check);
    try testing.expect(!opts.yes);
    try testing.expect(!opts.no_verify);
    try testing.expect(!opts.cleanup);
}

test "parseArgs: --check sets check" {
    try testing.expect(updater.parseArgs(&.{"--check"}).check);
}

test "parseArgs: both long and short forms of --yes" {
    try testing.expect(updater.parseArgs(&.{"--yes"}).yes);
    try testing.expect(updater.parseArgs(&.{"-y"}).yes);
}

test "parseArgs: --no-verify and --cleanup are independent" {
    const opts = updater.parseArgs(&.{ "--no-verify", "--cleanup" });
    try testing.expect(opts.no_verify);
    try testing.expect(opts.cleanup);
    try testing.expect(!opts.yes);
}

test "parseArgs: unrecognised flags are ignored (do not crash)" {
    // Forward-compat: a user passing a flag from a newer version of
    // malt to an older binary should not crash the updater.
    const opts = updater.parseArgs(&.{ "--check", "--nonsense", "--yes" });
    try testing.expect(opts.check);
    try testing.expect(opts.yes);
}
