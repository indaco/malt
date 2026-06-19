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

test "render interval schedule emits StartInterval and RunAtLoad false" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.backup",
        .program_args = &.{"/opt/malt/opt/backup/bin/backup"},
        .stdout_path = "/opt/malt/var/log/backup.out",
        .stderr_path = "/opt/malt/var/log/backup.err",
        .schedule = .{ .interval = 300 },
        // keep_alive is irrelevant for interval jobs — it must not appear.
        .keep_alive = true,
    };
    try plist.render(spec, &aw.writer);

    const expected =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.malt.backup</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/malt/opt/backup/bin/backup</string>
        \\    </array>
        \\    <key>StandardOutPath</key>
        \\    <string>/opt/malt/var/log/backup.out</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>/opt/malt/var/log/backup.err</string>
        \\    <key>RunAtLoad</key>
        \\    <false/>
        \\    <key>StartInterval</key>
        \\    <integer>300</integer>
        \\</dict>
        \\</plist>
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
}

test "render calendar schedule with one entry emits a StartCalendarInterval dict" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.report",
        .program_args = &.{"/opt/malt/opt/report/bin/report"},
        .stdout_path = "/opt/malt/var/log/report.out",
        .stderr_path = "/opt/malt/var/log/report.err",
        .schedule = .{ .calendar = &.{.{ .minute = 30, .hour = 4 }} },
    };
    try plist.render(spec, &aw.writer);

    const expected =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.malt.report</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/malt/opt/report/bin/report</string>
        \\    </array>
        \\    <key>StandardOutPath</key>
        \\    <string>/opt/malt/var/log/report.out</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>/opt/malt/var/log/report.err</string>
        \\    <key>RunAtLoad</key>
        \\    <false/>
        \\    <key>StartCalendarInterval</key>
        \\    <dict>
        \\        <key>Minute</key>
        \\        <integer>30</integer>
        \\        <key>Hour</key>
        \\        <integer>4</integer>
        \\    </dict>
        \\</dict>
        \\</plist>
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
}

test "render calendar schedule with many entries emits a StartCalendarInterval array" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.report",
        .program_args = &.{"/opt/malt/opt/report/bin/report"},
        .stdout_path = "/opt/malt/var/log/report.out",
        .stderr_path = "/opt/malt/var/log/report.err",
        .schedule = .{ .calendar = &.{ .{ .minute = 0 }, .{ .minute = 30 } } },
    };
    try plist.render(spec, &aw.writer);

    const expected =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>com.malt.report</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>/opt/malt/opt/report/bin/report</string>
        \\    </array>
        \\    <key>StandardOutPath</key>
        \\    <string>/opt/malt/var/log/report.out</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>/opt/malt/var/log/report.err</string>
        \\    <key>RunAtLoad</key>
        \\    <false/>
        \\    <key>StartCalendarInterval</key>
        \\    <array>
        \\        <dict>
        \\            <key>Minute</key>
        \\            <integer>0</integer>
        \\        </dict>
        \\        <dict>
        \\            <key>Minute</key>
        \\            <integer>30</integer>
        \\        </dict>
        \\    </array>
        \\</dict>
        \\</plist>
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
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
