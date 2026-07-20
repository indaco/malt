//! Shared outcome categorization for `mt migrate`. The parallel and serial
//! arms both drain a per-keg `KegResult` into the same six name lists; keeping
//! the six-way switch here makes adding a `KegResult` variant a one-site edit.

const std = @import("std");

const keg_mod = @import("keg.zig");

/// Six per-category name lists the migrate summary reads from. Holds pointers
/// because each arm owns the backing `ArrayList`s on its own stack.
pub const Buckets = struct {
    migrated: *std.ArrayList([]const u8),
    skipped_installed: *std.ArrayList([]const u8),
    skipped_post_install: *std.ArrayList([]const u8),
    skipped_no_bottle: *std.ArrayList([]const u8),
    failed: *std.ArrayList([]const u8),
    cancelled: *std.ArrayList([]const u8),

    pub fn record(
        self: Buckets,
        allocator: std.mem.Allocator,
        name: []const u8,
        result: keg_mod.KegResult,
    ) !void {
        switch (result) {
            .migrated => try self.migrated.append(allocator, name),
            .skipped_installed => try self.skipped_installed.append(allocator, name),
            .skipped_post_install => try self.skipped_post_install.append(allocator, name),
            .skipped_no_bottle => try self.skipped_no_bottle.append(allocator, name),
            .failed_api, .failed_download, .failed_install => try self.failed.append(allocator, name),
            .cancelled => try self.cancelled.append(allocator, name),
        }
    }
};

/// Widest name length for progress-bar label alignment, clamped to 255 —
/// `label_width` is a `u8`, so longer names just align to the cap.
pub fn maxNameLen(names: []const []const u8) u8 {
    var m: u8 = 0;
    for (names) |n| {
        const len: u8 = @intCast(@min(n.len, 255));
        if (len > m) m = len;
    }
    return m;
}

test "record routes each KegResult variant to its category" {
    const a = std.testing.allocator;
    var migrated: std.ArrayList([]const u8) = .empty;
    defer migrated.deinit(a);
    var skipped_installed: std.ArrayList([]const u8) = .empty;
    defer skipped_installed.deinit(a);
    var skipped_post_install: std.ArrayList([]const u8) = .empty;
    defer skipped_post_install.deinit(a);
    var skipped_no_bottle: std.ArrayList([]const u8) = .empty;
    defer skipped_no_bottle.deinit(a);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(a);
    var cancelled: std.ArrayList([]const u8) = .empty;
    defer cancelled.deinit(a);

    const b: Buckets = .{
        .migrated = &migrated,
        .skipped_installed = &skipped_installed,
        .skipped_post_install = &skipped_post_install,
        .skipped_no_bottle = &skipped_no_bottle,
        .failed = &failed,
        .cancelled = &cancelled,
    };

    try b.record(a, "m", .migrated);
    try b.record(a, "si", .skipped_installed);
    try b.record(a, "spi", .skipped_post_install);
    try b.record(a, "snb", .skipped_no_bottle);
    try b.record(a, "fa", .failed_api);
    try b.record(a, "fd", .failed_download);
    try b.record(a, "fi", .failed_install);
    try b.record(a, "c", .cancelled);

    try std.testing.expectEqual(@as(usize, 1), migrated.items.len);
    try std.testing.expectEqualStrings("m", migrated.items[0]);
    try std.testing.expectEqual(@as(usize, 1), skipped_installed.items.len);
    try std.testing.expectEqual(@as(usize, 1), skipped_post_install.items.len);
    try std.testing.expectEqual(@as(usize, 1), skipped_no_bottle.items.len);
    // All three failed_* collapse into `failed`.
    try std.testing.expectEqual(@as(usize, 3), failed.items.len);
    try std.testing.expectEqual(@as(usize, 1), cancelled.items.len);
    try std.testing.expectEqualStrings("c", cancelled.items[0]);
}

test "maxNameLen: empty is 0, mixed is the longest, over-long clamps to 255" {
    try std.testing.expectEqual(@as(u8, 0), maxNameLen(&.{}));
    try std.testing.expectEqual(@as(u8, 5), maxNameLen(&.{ "a", "abcde", "abc" }));
    const long = "x" ** 300;
    try std.testing.expectEqual(@as(u8, 255), maxNameLen(&.{long}));
}
