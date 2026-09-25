//! malt — restore command integration tests.
//!
//! Drives `restore.execute` against a scratch MALT_PREFIX so the
//! arg-parsing, file-read, parse and dry-run reporting branches land
//! on the coverage map. The actual install-delegation path is left to
//! the install tests — restore just emits the argv and forwards.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const restore = malt.cli_restore;
const output = malt.output;
const test_io = @import("test_io");

const c = test_io.c;

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        // Process-unique: a bare timestamp collides between overlapping runs.
        const raw = try test_io.uniqueTempPath(allocator, "restore", tag);
        defer allocator.free(raw);
        const path = try allocator.dupeZ(u8, raw);
        errdefer allocator.free(path);
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

test "execute --dry-run routes tap-slug lines to the batch their kind names" {
    // Formula lines install with `--formula` and cask lines with `--cask`, so
    // a tap keg built from Casks/ must reach the cask batch to be rebuilt.
    var s = try Scratch.init(testing.allocator, "dry_tap");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path,
        \\formula acme/tools/foo
        \\cask acme/tools/bar
        \\formula wget
        \\
    );

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    output.setDryRun(true);
    defer output.setDryRun(false);
    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{path});

    try testing.expect(std.mem.indexOf(u8, captured.items, "formula acme/tools/foo") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "cask    acme/tools/bar") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "formula wget") != null);
}

fn dryRunCapture(path: []const u8, captured: *std.ArrayList(u8)) !void {
    output.beginStderrCapture(testing.allocator, captured);
    defer output.endStderrCapture();
    output.setDryRun(true);
    defer output.setDryRun(false);
    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{path});
}

test "execute --dry-run shows a recorded version beside the name it installs" {
    // Install has no version pin: forwarding `wget@1.24` looked up a package
    // of that literal name, so every pinned line failed to restore.
    var s = try Scratch.init(testing.allocator, "dry_versions");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path,
        \\formula wget 1.24
        \\formula postgresql@16 16.4
        \\cask acme/tools/baz 3.0
        \\
    );

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try dryRunCapture(path, &captured);

    try testing.expect(std.mem.indexOf(u8, captured.items, "formula wget (1.24)") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "formula postgresql@16 (16.4)") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "cask    acme/tools/baz (3.0)") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "wget@") == null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "installs the current release") != null);
}

test "execute asks install for the bare name of a pinned line" {
    // Offline, install names what it failed to fetch: that is the exact
    // name restore forwarded.
    var s = try Scratch.init(testing.allocator, "real_versions");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "formula zzrestore 1.24\n");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &captured);
    defer output.endStderrCapture();

    var ctx = malt.app_ctx.debug_ctx;
    ctx.offline = true;
    try testing.expectError(error.RestoreFailed, restore.execute(&ctx, testing.allocator, &.{path}));
    try testing.expect(std.mem.indexOf(u8, captured.items, "'zzrestore'") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "zzrestore@") == null);
}

test "execute warns once that an older backup's name@version lines need rewriting" {
    // Such a line reads as one package name; guessing the split would break
    // versioned formulas like `postgresql@16`.
    var s = try Scratch.init(testing.allocator, "legacy_pins");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "formula wget@1.24.5\ncask firefox@120.0\nformula jq\n");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try dryRunCapture(path, &captured);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, captured.items, "rewrite"));
    try testing.expect(std.mem.indexOf(u8, captured.items, "2 lines") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "wget@1.24.5") != null);
}

test "execute trusts `@` names in a backup written with separate version fields" {
    var s = try Scratch.init(testing.allocator, "current_format");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try malt.backup.writeHeader(&aw.writer);
    try aw.writer.writeAll("formula postgresql@16 16.4\n");
    try writeFile(path, aw.written());

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try dryRunCapture(path, &captured);

    try testing.expect(std.mem.indexOf(u8, captured.items, "rewrite") == null);
}

test "execute --dry-run says nothing about versions for an unpinned backup" {
    var s = try Scratch.init(testing.allocator, "dry_unpinned");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "formula wget\n");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try dryRunCapture(path, &captured);

    try testing.expect(std.mem.indexOf(u8, captured.items, "installs the current release") == null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "formula wget\n") != null);
}

test "execute points each local note at its rebuild command, even with no entries" {
    // A local keg's recipe lives outside any tap; only the user can rebuild it.
    var s = try Scratch.init(testing.allocator, "local_note");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path, "# local lx /src/my dir/l'x.rb\n");

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    try dryRunCapture(path, &captured);

    try testing.expect(std.mem.indexOf(u8, captured.items, "mt install --local '/src/my dir/l'\\''x.rb'") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "No entries found") != null);
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

// --- service-entry dispatch ---------------------------------------------

test "execute summary line carries formula + cask + service counts in that order" {
    // Pin the exact summary phrasing so users grepping for "service(s)"
    // in their restore output don't suddenly miss it after a future
    // formatting tweak.
    var s = try Scratch.init(testing.allocator, "summary");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path,
        \\formula wget
        \\cask firefox
        \\service postgresql@16
        \\
    );

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer output.endStderrCapture();

    output.setDryRun(true);
    defer output.setDryRun(false);

    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{path});

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "1 formula(e), 1 cask(s) and 1 service(s)") != null);
}

test "execute --dry-run buckets a service entry and prints it after formulas/casks" {
    // T-042 surface contract: services arrive ordered after kegs so the
    // launchd bootstrap happens once the keg backing each service exists.
    var s = try Scratch.init(testing.allocator, "dry_services");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    try writeFile(path,
        \\formula postgresql@16
        \\service postgresql@16
        \\
    );

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer output.endStderrCapture();

    output.setDryRun(true);
    defer output.setDryRun(false);

    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{path});

    // Summary line counts services alongside formulae and casks.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "1 service(s)") != null);
    // Per-entry dry-run line for the service surfaces with the full label.
    const svc_line = std.mem.indexOf(u8, stderr_buf.items, "service postgresql@16") orelse
        return error.MissingServiceDryRunLine;
    const formula_line = std.mem.indexOf(u8, stderr_buf.items, "formula postgresql@16") orelse
        return error.MissingFormulaDryRunLine;
    // Services must come after kegs in dispatch order.
    try testing.expect(svc_line > formula_line);
}

test "execute warns-and-continues when a service entry can't be bootstrapped" {
    // Acceptance: missing kegs (no services row to look up) must not
    // fail the restore. The supervisor returns ServiceNotFound; restore
    // catches it, surfaces a warning naming the service, and returns
    // success so the rest of the backup keeps applying.
    var s = try Scratch.init(testing.allocator, "missing_keg_service");
    defer s.deinit(testing.allocator);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/snap.txt", .{s.path});
    defer testing.allocator.free(path);
    // db/ must exist so services_cmd can open the DB and init the schema.
    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{s.path});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    try writeFile(path, "service ghost_service\n");

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &stderr_buf);
    defer output.endStderrCapture();

    // Not dry-run — exercise the real dispatch arm.
    try restore.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{path});

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "ghost_service") != null);
}
