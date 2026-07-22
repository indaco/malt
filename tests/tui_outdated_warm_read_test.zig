//! malt — integration tests for the Outdated tab's warm-read.
//!
//! Warm-read assembles the on-disk `outdated.json` snapshot into the Outdated
//! tab's rows at launch, so the dashboard opens with data instead of a spinner.
//! These pin that end-to-end wiring through a real cache file; the snapshot
//! parser's own shapes are unit-tested inline in `tui/json/snapshot.zig`.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const test_io = @import("test_io");
const outdated = malt.tui_tab_outdated;
const ctx = malt.tui_ctx;
const outdated_json = malt.tui_json_outdated;

/// Stands in for `std.testing.tmpDir`, which roots its scratch under
/// `.zig-cache` — a tree the build system rewrites underneath a running test.
const Scratch = struct {
    path: []const u8,
    dir: std.Io.Dir,

    fn init(tag: []const u8) !Scratch {
        const io = std.Options.debug_io;
        const raw = try test_io.uniqueTempPath(testing.allocator, "tui_warm_read", tag);
        errdefer testing.allocator.free(raw);
        test_io.deleteTreeAbsolute(io, raw) catch {};
        try test_io.cwd().createDirPath(io, raw);
        errdefer test_io.deleteTreeAbsolute(io, raw) catch {};
        return .{ .path = raw, .dir = try test_io.openDirAbsolute(io, raw, .{}) };
    }

    fn deinit(self: *Scratch) void {
        const io = std.Options.debug_io;
        self.dir.close(io);
        test_io.deleteTreeAbsolute(io, self.path) catch {};
        testing.allocator.free(self.path);
    }
};

test "warmRead seeds the tab and header count from a present snapshot" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scratch = try Scratch.init("present_snapshot");
    defer scratch.deinit();
    const cache_dir = scratch.path;
    var f = try scratch.dir.createFile(io, "outdated.json", .{});
    try f.writeStreamingAll(io, "{\"version\":2,\"generated_at_ms\":0,\"formulas\":[{\"name\":\"wget\",\"installed\":\"1.24.5\",\"latest\":\"1.25.0\"}],\"casks\":[{\"name\":\"firefox\",\"installed\":\"120\",\"latest\":\"121\"}]}");
    f.close(io);

    var st: outdated.State = .{};
    var storage: outdated.Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    outdated.warmRead(io, testing.allocator, cache_dir, &st, &storage, &shared);

    try testing.expectEqual(@as(usize, 2), st.items.len);
    try testing.expectEqualStrings("wget", st.items[0].name);
    try testing.expectEqual(outdated_json.Kind.cask, st.items[1].kind);
    try testing.expectEqual(@as(?usize, 2), shared.outdated_count); // header reflects the warm rows
    // Warm rows are provisional: no snapshot field supplies pinned, so it defaults safe.
    try testing.expect(!st.items[0].pinned);
}

test "warmRead on an absent snapshot leaves the tab empty and untouched" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var st: outdated.State = .{};
    var storage: outdated.Storage = .{};
    var shared: ctx.SharedModel = .{};
    defer storage.deinit(testing.allocator);
    outdated.warmRead(threaded.io(), testing.allocator, "/nonexistent/malt/cache", &st, &storage, &shared);
    try testing.expectEqual(@as(usize, 0), st.items.len);
    try testing.expect(storage.outdated == null); // nothing seeded on a miss
}
