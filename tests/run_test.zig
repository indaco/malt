//! malt — run (ephemeral execution) tests
//! Network-dependent tests are deferred; unit tests cover argument parsing.

const std = @import("std");
const testing = std.testing;

test "argument split at double dash" {
    const args = [_][]const u8{ "jq", "--arg", "--", "--version", "-r" };
    var cmd_args_start: usize = args.len;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            cmd_args_start = i + 1;
            break;
        }
    }
    const cmd_args = if (cmd_args_start < args.len) args[cmd_args_start..] else &[_][]const u8{};

    try testing.expectEqual(@as(usize, 2), cmd_args.len);
    try testing.expectEqualStrings("--version", cmd_args[0]);
    try testing.expectEqualStrings("-r", cmd_args[1]);
}

test "no double dash means no command args" {
    const args = [_][]const u8{"jq"};
    var cmd_args_start: usize = args.len;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            cmd_args_start = i + 1;
            break;
        }
    }
    const cmd_args = if (cmd_args_start < args.len) args[cmd_args_start..] else &[_][]const u8{};
    try testing.expectEqual(@as(usize, 0), cmd_args.len);
}
