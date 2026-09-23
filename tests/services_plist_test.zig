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

test "stop_timeout renders ExitTimeOut so launchd waits before SIGKILL" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.postgresql@17",
        .program_args = &.{"/opt/malt/opt/postgresql@17/bin/postgres"},
        .stdout_path = "/tmp/o",
        .stderr_path = "/tmp/e",
        .stop_timeout = 120,
    };
    try plist.render(spec, &aw.writer);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "    <key>ExitTimeOut</key>\n    <integer>120</integer>\n") != null);
}

test "absent stop_timeout leaves ExitTimeOut to launchd's default" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const spec: plist.ServiceSpec = .{
        .label = "com.malt.redis",
        .program_args = &.{"/opt/malt/opt/redis/bin/redis-server"},
        .stdout_path = "/tmp/o",
        .stderr_path = "/tmp/e",
    };
    try plist.render(spec, &aw.writer);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "ExitTimeOut") == null);
}

test "an API service's environment_variables reach the rendered plist" {
    // Live `postgresql@17` service block, end to end.
    var f = try malt.formula.parseFormula(testing.allocator,
        \\{"name":"postgresql@17","full_name":"postgresql@17","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":true,"post_install_defined":false,"versions":{"stable":"17.6"},"dependencies":[],"service":{"run":["$HOMEBREW_PREFIX/opt/postgresql@17/bin/postgres","-D","$HOMEBREW_PREFIX/var/postgresql@17"],"run_type":"immediate","keep_alive":{"always":true},"environment_variables":{"LC_ALL":"en_US.UTF-8"},"working_dir":"$HOMEBREW_PREFIX","log_path":"$HOMEBREW_PREFIX/var/log/postgresql@17.log","error_log_path":"$HOMEBREW_PREFIX/var/log/postgresql@17.log","stop_timeout":120}}
    );
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try malt.install_service.specFromDef(arena.allocator(), f.service.?, f.name, "/opt/malt");
    try plist.validate(spec, "/opt/malt/Cellar/postgresql@17/17.6", "/opt/malt");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try plist.render(spec, &aw.writer);

    const want =
        \\    <key>WorkingDirectory</key>
        \\    <string>/opt/malt</string>
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>LC_ALL</key>
        \\        <string>en_US.UTF-8</string>
        \\    </dict>
        \\    <key>StandardOutPath</key>
        \\
    ;
    try testing.expect(std.mem.indexOf(u8, aw.written(), want) != null);
}

test "a NUL smuggled into an API environment value fails validation" {
    // JSON can escape a NUL that would cut the plist string short.
    var f = try malt.formula.parseFormula(testing.allocator,
        \\{"name":"x","full_name":"x","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":0,"keg_only":false,"post_install_defined":false,"versions":{"stable":"1.0"},"dependencies":[],"service":{"run":["$HOMEBREW_PREFIX/opt/x/bin/x"],"environment_variables":{"A":"ok\u0000tail"}}}
    );
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const spec = try malt.install_service.specFromDef(arena.allocator(), f.service.?, f.name, "/opt/malt");
    try testing.expectError(plist.ValidationError.EmbeddedNul, plist.validate(spec, "/opt/malt/Cellar/x/1.0", "/opt/malt"));
}

/// Captures warnings so a test can assert what the user is told.
const WarnLog = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    fn record(ctx: ?*anyopaque, msg: []const u8) void {
        const self: *WarnLog = @ptrCast(@alignCast(ctx.?));
        const n = @min(msg.len, self.buf.len);
        @memcpy(self.buf[0..n], msg[0..n]);
        self.len = n;
    }
    fn swallow(_: ?*anyopaque, _: []const u8) void {}
    fn sink(self: *WarnLog) malt.install_sink.OutputSink {
        return .{ .ctx = self, .writeInfo = swallow, .writeWarn = record, .writeSuccess = swallow, .writeErr = swallow };
    }
    fn text(self: *const WarnLog) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Writes `<dir>/<services>/<name>.env` and returns `dir`'s real path.
fn writeOverride(io: std.Io, dir: std.Io.Dir, buf: []u8, services: []const u8, name: []const u8, body: []const u8) ![]const u8 {
    try dir.createDirPath(io, services);
    var sub_buf: [128]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&sub_buf, "{s}/{s}.env", .{ services, name }), .data = body });
    return buf[0..try std.Io.Dir.realPath(dir, io, buf)];
}

/// An environ carrying only `XDG_CONFIG_HOME=<root>`, owned by `aa`.
fn xdgEnviron(aa: std.mem.Allocator, root: []const u8) !std.process.Environ {
    const entries = try aa.allocSentinel(?[*:0]const u8, 1, null);
    entries[0] = (try std.fmt.allocPrintSentinel(aa, "XDG_CONFIG_HOME={s}", .{root}, 0)).ptr;
    return .{ .block = .{ .slice = entries } };
}

fn postgresSpec(aa: std.mem.Allocator) !plist.ServiceSpec {
    return .{
        .label = "com.malt.postgresql@17",
        .program_args = &.{ "/opt/malt/opt/postgresql@17/bin/postgres", "-D", "/opt/malt/var/postgresql@17" },
        .stdout_path = "/opt/malt/var/log/postgresql@17.log",
        .stderr_path = "/opt/malt/var/log/postgresql@17.log",
        .env = try aa.dupe(plist.EnvPair, &.{.{ .key = "LC_ALL", .value = "en_US.UTF-8" }}),
    };
}

test "a user's service .env override lands in the rendered plist over the formula's environment" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try writeOverride(io, tmp.dir, &root_buf, "malt/services", "postgresql@17", "# survives upgrades\nPGPORT=5433\nLC_ALL=C\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const environ = try xdgEnviron(aa, root);

    var log: WarnLog = .{};
    const spec = malt.install_service.withEnvOverrides(io, aa, environ, try postgresSpec(aa), "postgresql@17", log.sink()).?;
    try testing.expectEqualStrings("", log.text());
    try plist.validate(spec, "/opt/malt/Cellar/postgresql@17/17.6", "/opt/malt");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try plist.render(spec, &aw.writer);
    const want =
        \\    <key>EnvironmentVariables</key>
        \\    <dict>
        \\        <key>LC_ALL</key>
        \\        <string>C</string>
        \\        <key>PGPORT</key>
        \\        <string>5433</string>
        \\    </dict>
        \\
    ;
    try testing.expect(std.mem.indexOf(u8, aw.written(), want) != null);
}

test "without XDG_CONFIG_HOME the override is read from ~/.config" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try writeOverride(io, tmp.dir, &root_buf, ".config/malt/services", "redis", "REDIS_PORT=6380\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    // A relative XDG_CONFIG_HOME is invalid per the spec and must be ignored.
    const xdg = "XDG_CONFIG_HOME=relative/cfg";
    const home_kv = try std.fmt.allocPrintSentinel(aa, "HOME={s}", .{home}, 0);
    const entries = [_:null]?[*:0]const u8{ xdg, home_kv.ptr };
    const environ: std.process.Environ = .{ .block = .{ .slice = entries[0..2 :null] } };

    var log: WarnLog = .{};
    const base: plist.ServiceSpec = .{ .label = "com.malt.redis", .program_args = &.{"/opt/malt/bin/redis-server"}, .stdout_path = "/o", .stderr_path = "/e" };
    const spec = malt.install_service.withEnvOverrides(io, aa, environ, base, "redis", log.sink()).?;
    try testing.expectEqual(@as(usize, 1), spec.env.len);
    try testing.expectEqualStrings("REDIS_PORT", spec.env[0].key);
    try testing.expectEqualStrings("6380", spec.env[0].value);
}

test "a refused override file warns with its line and asks the caller to keep the plist as is" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    // The good line must not half-apply once a later line is refused.
    const root = try writeOverride(io, tmp.dir, &root_buf, "malt/services", "postgresql@17", "PGPORT=5433\nDYLD_INSERT_LIBRARIES=/tmp/x.dylib\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const environ = try xdgEnviron(aa, root);

    var log: WarnLog = .{};
    // Null, not the formula spec: rewriting would drop overrides already live.
    try testing.expect(malt.install_service.withEnvOverrides(io, aa, environ, try postgresSpec(aa), "postgresql@17", log.sink()) == null);
    try testing.expect(std.mem.indexOf(u8, log.text(), "postgresql@17.env:2") != null);
    try testing.expect(std.mem.indexOf(u8, log.text(), "DYLD_") != null);
}

test "no override file and no HOME leave the spec untouched and silent" {
    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var log: WarnLog = .{};
    const base = try postgresSpec(aa);
    const spec = malt.install_service.withEnvOverrides(io, aa, .empty, base, "postgresql@17", log.sink()).?;
    try testing.expectEqual(base.env.ptr, spec.env.ptr);

    const entries = [_:null]?[*:0]const u8{"XDG_CONFIG_HOME=/nonexistent-malt-cfg"};
    const environ: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const spec2 = malt.install_service.withEnvOverrides(io, aa, environ, base, "postgresql@17", log.sink()).?;
    try testing.expectEqual(base.env.ptr, spec2.env.ptr);
    try testing.expectEqualStrings("", log.text());
}

test "an oversized override file is refused whole rather than applied truncated" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const body = try aa.alloc(u8, malt.services_env_override.max_bytes + 1);
    @memset(body, '#');
    @memcpy(body[0..7], "PGPORT=");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try writeOverride(io, tmp.dir, &root_buf, "malt/services", "postgresql@17", body);
    const environ = try xdgEnviron(aa, root);

    var log: WarnLog = .{};
    try testing.expect(malt.install_service.withEnvOverrides(io, aa, environ, try postgresSpec(aa), "postgresql@17", log.sink()) == null);
    try testing.expect(std.mem.indexOf(u8, log.text(), "larger than") != null);
}

test "a service name that is not a path component never reaches the filesystem" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    // A file the traversal would land on if the name were joined blindly.
    const root = try writeOverride(io, tmp.dir, &root_buf, "malt", "escape", "PGPORT=1\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const environ = try xdgEnviron(aa, root);

    var log: WarnLog = .{};
    const base = try postgresSpec(aa);
    const spec = malt.install_service.withEnvOverrides(io, aa, environ, base, "../escape", log.sink()).?;
    try testing.expectEqual(base.env.ptr, spec.env.ptr);
}

test "an override path that is not a readable file warns instead of passing silently" {
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "malt/services/postgresql@17.env");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &root_buf)];
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const environ = try xdgEnviron(aa, root);

    var log: WarnLog = .{};
    const base = try postgresSpec(aa);
    try testing.expect(malt.install_service.withEnvOverrides(io, aa, environ, base, "postgresql@17", log.sink()) == null);
    try testing.expect(std.mem.indexOf(u8, log.text(), "ignored") != null);
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "a FIFO at the override path is refused without blocking" {
    // A blocking read here would hang an upgrade while it holds malt.lock.
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "malt/services");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &root_buf)];
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const fifo = try std.fmt.allocPrintSentinel(aa, "{s}/malt/services/postgresql@17.env", .{root}, 0);
    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));

    var log: WarnLog = .{};
    try testing.expect(malt.install_service.withEnvOverrides(io, aa, try xdgEnviron(aa, root), try postgresSpec(aa), "postgresql@17", log.sink()) == null);
    try testing.expect(std.mem.indexOf(u8, log.text(), "not a regular file") != null);
}

test "an override file other users can write is refused" {
    // Anyone who can write it could inject code into the job via the environment.
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try writeOverride(io, tmp.dir, &root_buf, "malt/services", "postgresql@17", "PGPORT=5433\n");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const path = try std.fmt.allocPrintSentinel(aa, "{s}/malt/services/postgresql@17.env", .{root}, 0);
    const environ = try xdgEnviron(aa, root);

    for ([_]std.c.mode_t{ 0o666, 0o620 }) |mode| {
        try testing.expectEqual(@as(c_int, 0), std.c.chmod(path, mode));
        var log: WarnLog = .{};
        try testing.expect(malt.install_service.withEnvOverrides(io, aa, environ, try postgresSpec(aa), "postgresql@17", log.sink()) == null);
        try testing.expect(std.mem.indexOf(u8, log.text(), "writable by other users") != null);
    }
    // Owner-only write is the normal case and applies.
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(path, 0o644));
    var log: WarnLog = .{};
    try testing.expectEqual(@as(usize, 2), (malt.install_service.withEnvOverrides(io, aa, environ, try postgresSpec(aa), "postgresql@17", log.sink()).?).env.len);
}

test "an override file reached through a symlink still applies" {
    // Dotfile managers link config into place; the checks judge the target.
    const io = std.Options.debug_io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try writeOverride(io, tmp.dir, &root_buf, "dotfiles", "postgresql@17", "PGPORT=5433\n");
    try tmp.dir.createDirPath(io, "malt/services");
    try tmp.dir.symLink(io, "../../dotfiles/postgresql@17.env", "malt/services/postgresql@17.env", .{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var log: WarnLog = .{};
    const spec = malt.install_service.withEnvOverrides(io, aa, try xdgEnviron(aa, root), try postgresSpec(aa), "postgresql@17", log.sink()).?;
    try testing.expectEqual(@as(usize, 2), spec.env.len);
    try testing.expectEqualStrings("", log.text());
}
