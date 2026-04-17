//! malt — plist_mod.validate rules
//!
//! Locks in the service-file validation surface: no interpreter bait,
//! no path escape, argv length caps, NUL rejection, per-log-path
//! sandboxing. A hostile formula that smuggled a `service:` block in
//! through the post_install integrity gap (Finding #1) would still
//! have to pass these checks before launchd sees a plist.

const std = @import("std");
const testing = std.testing;
const plist = @import("malt").services_plist;

const cellar = "/opt/malt/Cellar/foo/1.0";
const prefix = "/opt/malt";
const good_out = "/opt/malt/var/log/foo.out";
const good_err = "/opt/malt/var/log/foo.err";

test "validate: happy path under cellar/bin passes" {
    const args = [_][]const u8{ "/opt/malt/Cellar/foo/1.0/bin/foo", "arg" };
    try plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .stdout_path = good_out,
        .stderr_path = good_err,
    }, cellar, prefix);
}

test "validate: happy path under malt_prefix/opt passes" {
    const args = [_][]const u8{ "/opt/malt/opt/foo/bin/foo", "arg" };
    try plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .stdout_path = good_out,
        .stderr_path = good_err,
    }, cellar, prefix);
}

fn expectHeadRejected(head: []const u8, expected: anyerror) !void {
    const args = [_][]const u8{ head, "arg" };
    const res = plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .stdout_path = good_out,
        .stderr_path = good_err,
    }, cellar, prefix);
    try testing.expectError(expected, res);
}

test "validate: /bin/sh rejected as interpreter bait" {
    try expectHeadRejected("/bin/sh", error.InterpreterBait);
}

test "validate: /bin/bash rejected as interpreter bait" {
    try expectHeadRejected("/bin/bash", error.InterpreterBait);
}

test "validate: /usr/bin/env rejected as interpreter bait" {
    try expectHeadRejected("/usr/bin/env", error.InterpreterBait);
}

test "validate: head outside cellar and prefix/opt rejected" {
    try expectHeadRejected("/usr/local/bin/evil", error.PathEscape);
}

test "validate: relative head rejected" {
    try expectHeadRejected("bin/foo", error.RelativeExecutable);
}

test "validate: empty program_args rejected" {
    try testing.expectError(error.Empty, plist.validate(.{
        .label = "com.malt.foo",
        .program_args = &.{},
        .stdout_path = good_out,
        .stderr_path = good_err,
    }, cellar, prefix));
}

test "validate: embedded NUL in arg rejected" {
    const args = [_][]const u8{ "/opt/malt/Cellar/foo/1.0/bin/foo", "ev\x00il" };
    try testing.expectError(error.EmbeddedNul, plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .stdout_path = good_out,
        .stderr_path = good_err,
    }, cellar, prefix));
}

test "validate: oversize arg rejected" {
    var big: [plist.MAX_ARG_LEN + 1]u8 = undefined;
    @memset(&big, 'a');
    const args = [_][]const u8{ "/opt/malt/Cellar/foo/1.0/bin/foo", big[0..] };
    try testing.expectError(error.ArgTooLong, plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .stdout_path = good_out,
        .stderr_path = good_err,
    }, cellar, prefix));
}

test "validate: too many args rejected" {
    var args: [plist.MAX_PROGRAM_ARGS + 1][]const u8 = undefined;
    args[0] = "/opt/malt/Cellar/foo/1.0/bin/foo";
    for (args[1..]) |*a| a.* = "x";
    try testing.expectError(error.TooManyArgs, plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .stdout_path = good_out,
        .stderr_path = good_err,
    }, cellar, prefix));
}

test "validate: working_dir escape rejected" {
    const args = [_][]const u8{"/opt/malt/Cellar/foo/1.0/bin/foo"};
    try testing.expectError(error.PathEscape, plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .working_dir = "/etc",
        .stdout_path = good_out,
        .stderr_path = good_err,
    }, cellar, prefix));
}

test "validate: stdout_path escape rejected" {
    const args = [_][]const u8{"/opt/malt/Cellar/foo/1.0/bin/foo"};
    try testing.expectError(error.PathEscape, plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .stdout_path = "/etc/malt.log",
        .stderr_path = good_err,
    }, cellar, prefix));
}

test "validate: stderr_path dot-dot escape rejected" {
    const args = [_][]const u8{"/opt/malt/Cellar/foo/1.0/bin/foo"};
    try testing.expectError(error.PathEscape, plist.validate(.{
        .label = "com.malt.foo",
        .program_args = args[0..],
        .stdout_path = good_out,
        .stderr_path = "/opt/malt/../etc/foo.err",
    }, cellar, prefix));
}
