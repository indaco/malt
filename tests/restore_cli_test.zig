//! malt — restore command integration tests.
//!
//! Drives `restore.execute` against a scratch MALT_PREFIX so the
//! arg-parsing, file-read, parse and dry-run reporting branches land
//! on the coverage map. The actual install-delegation path is left to
//! the install tests — restore just emits the argv and forwards.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const restore = malt.cli_restore;
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_restore_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

const DryRunGuard = struct {
    prior: bool,

    fn enable() DryRunGuard {
        const prior = output.isDryRun();
        output.setDryRun(true);
        output.setQuiet(true);
        return .{ .prior = prior };
    }
    fn disable(self: DryRunGuard) void {
        output.setDryRun(self.prior);
        output.setQuiet(false);
    }
};

fn writeFile(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        test_io.cwd().createDirPath(std.Options.debug_io, dir) catch {};
    }
    const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, content);
}

// --- early-return + arg parsing -----------------------------------------

test "execute --help short-circuits before opening the file" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    output.setQuiet(true);
    defer output.setQuiet(false);
    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute with no positional path returns MissingFileArgument" {
    var s = try Scratch.init(testing.allocator, "noargs");
    defer s.deinit(testing.allocator);
    output.setQuiet(true);
    defer output.setQuiet(false);
    try testing.expectError(
        restore.Error.MissingFileArgument,
        restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

test "execute on a missing file returns FileNotFound" {
    var s = try Scratch.init(testing.allocator, "missing");
    defer s.deinit(testing.allocator);
    output.setQuiet(true);
    defer output.setQuiet(false);
    try testing.expectError(
        restore.Error.FileNotFound,
        restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"/tmp/malt_restore_does_not_exist_xyz"}),
    );
}

test "execute rejects extra positional args" {
    var s = try Scratch.init(testing.allocator, "extra");
    defer s.deinit(testing.allocator);
    output.setQuiet(true);
    defer output.setQuiet(false);
    try testing.expectError(
        restore.Error.InvalidArgs,
        restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "/tmp/a", "/tmp/b" }),
    );
}

test "execute rejects unknown flags" {
    var s = try Scratch.init(testing.allocator, "unknown_flag");
    defer s.deinit(testing.allocator);
    output.setQuiet(true);
    defer output.setQuiet(false);
    try testing.expectError(
        restore.Error.InvalidArgs,
        restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--nope"}),
    );
}

// --- file parsing + dry-run path ---------------------------------------

test "execute on an empty file warns and returns without error" {
    var s = try Scratch.init(testing.allocator, "empty");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/empty.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "# only comments here\n");

    output.setQuiet(true);
    defer output.setQuiet(false);

    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{path});
}

test "execute --dry-run reports formula + cask entries without delegating" {
    var s = try Scratch.init(testing.allocator, "dry");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path,
        \\# malt backup
        \\formula wget
        \\formula jq@1.7
        \\cask firefox
        \\
    );

    const guard = DryRunGuard.enable();
    defer guard.disable();

    // Dry-run delegates nothing; just walks the parsed entries and prints them.
    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{path});
}

test "execute treats unknown kinds as comments and reports zero entries" {
    // backup.parseBackup is line-tolerant: anything that isn't a
    // recognised `formula <name>` / `cask <name>` is silently dropped,
    // so a file of garbage parses to an empty entry list and restore
    // takes the "No entries found" warn-and-return path — not an error.
    var s = try Scratch.init(testing.allocator, "garbage");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/bad.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "potato wget\n");

    output.setQuiet(true);
    defer output.setQuiet(false);
    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{path});
}
