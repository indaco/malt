//! malt — DSL fallback_log module tests
//! Covers log, hasErrors, hasFatal, and toJson serialization.

const std = @import("std");
const testing = std.testing;
const dsl = @import("malt").dsl;
const FallbackLog = dsl.FallbackLog;
const FallbackEntry = dsl.FallbackEntry;
const FallbackReason = dsl.FallbackReason;

test "empty log reports no errors and no fatal" {
    var log = FallbackLog.init(testing.allocator);
    defer log.deinit();
    try testing.expect(!log.hasErrors());
    try testing.expect(!log.hasFatal());
}

test "hasErrors is true once any entry is logged" {
    var log = FallbackLog.init(testing.allocator);
    defer log.deinit();
    log.log(.{ .formula = "f", .reason = .unknown_method, .detail = "d", .loc = null });
    try testing.expect(log.hasErrors());
    try testing.expect(!log.hasFatal()); // unknown_method is non-fatal
}

test "hasFatal picks up sandbox_violation and system_command_failed" {
    var log_a = FallbackLog.init(testing.allocator);
    defer log_a.deinit();
    log_a.log(.{ .formula = "f", .reason = .sandbox_violation, .detail = "d", .loc = null });
    try testing.expect(log_a.hasFatal());

    var log_b = FallbackLog.init(testing.allocator);
    defer log_b.deinit();
    log_b.log(.{ .formula = "f", .reason = .system_command_failed, .detail = "d", .loc = null });
    try testing.expect(log_b.hasFatal());

    var log_c = FallbackLog.init(testing.allocator);
    defer log_c.deinit();
    log_c.log(.{ .formula = "f", .reason = .unsupported_node, .detail = "d", .loc = null });
    try testing.expect(!log_c.hasFatal());
}

// parse_error used to be fatal, which also killed the --use-system-ruby
// fallback path. Now it's logged with loc for the CLI but treated as
// recoverable so formulas using constructs the native DSL doesn't know
// yet can still be salvaged by the Ruby subprocess.
test "hasFatal does NOT trip on parse_error (fallback path stays open)" {
    var log = FallbackLog.init(testing.allocator);
    defer log.deinit();
    log.log(.{ .formula = "f", .reason = .parse_error, .detail = "unexpected token", .loc = .{ .line = 4, .col = 1 } });
    try testing.expect(log.hasErrors());
    try testing.expect(!log.hasFatal());
}

test "entries() preserves reason, detail, and loc in log order for the renderer" {
    // The log is pure: it hands the caller an ordered view and the caller
    // owns the `tag:line:col: [reason] detail` formatting. Pin the data the
    // renderer reads rather than the rendered bytes.
    var log = FallbackLog.init(testing.allocator);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 0), log.entries().len);

    log.log(.{ .formula = "wget", .reason = .unknown_method, .detail = "skip me", .loc = null });
    log.log(.{ .formula = "wget", .reason = .parse_error, .detail = "unexpected token", .loc = .{ .line = 12, .col = 4 } });
    log.log(.{ .formula = "wget", .reason = .sandbox_violation, .detail = "/etc/passwd", .loc = null });

    const items = log.entries();
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(FallbackReason.parse_error, items[1].reason);
    try testing.expectEqual(@as(u32, 12), items[1].loc.?.line);
    try testing.expectEqualStrings("/etc/passwd", items[2].detail);
}

test "toJson emits an empty array for no entries" {
    var log = FallbackLog.init(testing.allocator);
    defer log.deinit();

    const s = try log.toJson(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("[]", s);
}

test "toJson serialises formula/reason/detail and source location when present" {
    var log = FallbackLog.init(testing.allocator);
    defer log.deinit();

    log.log(.{
        .formula = "wget",
        .reason = .unknown_method,
        .detail = "some_method",
        .loc = .{ .line = 7, .col = 3 },
    });
    log.log(.{
        .formula = "curl",
        .reason = .unsupported_node,
        .detail = "node",
        .loc = null,
    });

    const s = try log.toJson(testing.allocator);
    defer testing.allocator.free(s);

    try testing.expect(std.mem.startsWith(u8, s, "["));
    try testing.expect(std.mem.endsWith(u8, s, "]"));
    try testing.expect(std.mem.indexOf(u8, s, "\"formula\":\"wget\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"reason\":\"unknown_method\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"detail\":\"some_method\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"line\":7") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"col\":3") != null);
    // Entry without loc should NOT emit line/col fields.
    try testing.expect(std.mem.indexOf(u8, s, "\"formula\":\"curl\"") != null);
    // Comma between the two entries.
    try testing.expect(std.mem.indexOf(u8, s, "},{") != null);
}
