//! malt — launchd plist emitter tests

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const plist = malt.services_plist;

test "render minimal spec matches golden" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.wget",
        .program_args = &.{ "/opt/malt/opt/wget/bin/wget", "--version" },
        .stdout_path = "/opt/malt/var/log/wget.out",
        .stderr_path = "/opt/malt/var/log/wget.err",
    };
    try plist.render(spec, &aw.writer);

    const expected =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.malt.wget</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/malt/opt/wget/bin/wget</string>
        \\        <string>--version</string>
        \\    </array>
        \\    <key>StandardOutPath</key>
        \\    <string>/opt/malt/var/log/wget.out</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>/opt/malt/var/log/wget.err</string>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <dict>
        \\        <key>SuccessfulExit</key>
        \\        <false/>
        \\    </dict>
        \\</dict>
        \\</plist>
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
}

test "render full spec with env and working_dir" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.postgresql@16",
        .program_args = &.{"/opt/malt/opt/postgresql@16/bin/postgres"},
        .working_dir = "/opt/malt/var/postgresql@16",
        .env = &.{
            .{ .key = "PGDATA", .value = "/opt/malt/var/postgresql@16" },
            .{ .key = "LANG", .value = "en_US.UTF-8" },
        },
        .stdout_path = "/opt/malt/var/log/postgresql@16.out",
        .stderr_path = "/opt/malt/var/log/postgresql@16.err",
        .run_at_load = true,
        .keep_alive = true,
    };
    try plist.render(spec, &aw.writer);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "<key>WorkingDirectory</key>") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "<key>EnvironmentVariables</key>") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "<key>PGDATA</key>") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "<string>en_US.UTF-8</string>") != null);
}

test "XML-escapes special characters" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.<ampersand&test>",
        .program_args = &.{"/bin/echo"},
        .stdout_path = "/tmp/a\"b.log",
        .stderr_path = "/tmp/err.log",
    };
    try plist.render(spec, &aw.writer);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "&lt;ampersand&amp;test&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "a&quot;b.log") != null);
}

test "keep_alive false omits KeepAlive dict" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.oneshot",
        .program_args = &.{"/bin/true"},
        .stdout_path = "/tmp/o",
        .stderr_path = "/tmp/e",
        .keep_alive = false,
    };
    try plist.render(spec, &aw.writer);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "KeepAlive") == null);
}
