//! malt — cron expression parser for launchd StartCalendarInterval
//!
//! Parses the 5-field cron grammar (minute hour day-of-month month
//! day-of-week) into one or more launchd CalendarInterval entries. Only the
//! subset launchd can represent is accepted; lists/steps/ranges enumerate into
//! the cartesian product of dicts (an absent field means "every"). Anything
//! launchd cannot express — named days/months, @macros, ?/L/W — is rejected
//! loudly so a schedule is never silently approximated. Field bounds are
//! validated here so every emitted value is a known-safe integer.

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");

pub const CalendarInterval = types.CalendarInterval;

pub const CronError = error{
    /// Wrong field count, an empty field, or an unparseable number/range.
    CronMalformed,
    /// A value sits outside its field's range (e.g. minute 60).
    CronOutOfRange,
    /// A token launchd cannot represent: named days/months, @macros, ?, L, W.
    CronUnsupported,
    /// The list/step/range expansion exceeds max_calendar_entries.
    CronTooComplex,
} || std.mem.Allocator.Error;

/// Cap on enumerated CalendarInterval entries; shared with `plist.validate`.
pub const max_calendar_entries = types.max_calendar_entries;

const FieldSpec = struct { min: u8, max: u8 };

/// Inclusive bounds per cron field, in grammar order:
/// minute hour day-of-month month day-of-week. Weekday allows 7 (Sunday)
/// which is canonicalised to 0 during parsing.
const field_specs = [5]FieldSpec{
    .{ .min = 0, .max = 59 }, // minute
    .{ .min = 0, .max = 23 }, // hour
    .{ .min = 1, .max = 31 }, // day-of-month
    .{ .min = 1, .max = 12 }, // month
    .{ .min = 0, .max = 7 }, // day-of-week
};

pub fn parseCron(allocator: std.mem.Allocator, expr: []const u8) CronError![]CalendarInterval {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return CronError.CronMalformed;
    // @macros (@daily, @reboot, …) replace the whole expression; launchd has
    // no equivalent, so reject before field splitting would call them malformed.
    if (trimmed[0] == '@') return CronError.CronUnsupported;

    var fields: [5][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |f| {
        if (n == 5) return CronError.CronMalformed; // too many fields
        fields[n] = f;
        n += 1;
    }
    if (n != 5) return CronError.CronMalformed;

    // A null set is a wildcard (`*`); a concrete set is the field's value list.
    var sets: [5]?Set = undefined;
    for (fields, 0..) |f, i| sets[i] = try parseField(f, field_specs[i], i == 4);

    // launchd ORs an array of dicts, so a cron list/step/range becomes the
    // cartesian product of the per-field value sets (wildcards contribute one
    // "every" slot each). The entry count is that product.
    var count: usize = 1;
    for (sets) |maybe| {
        if (maybe) |s| count *= s.count();
    }
    if (count > max_calendar_entries) return CronError.CronTooComplex;

    const out = try allocator.alloc(CalendarInterval, count);
    fillEntries(sets, out);
    return out;
}

const Set = std.StaticBitSet(64);

/// Parse one field into a value set, or null for `*` (launchd's "every").
/// Comma-separated parts each contribute their values to the set.
fn parseField(field: []const u8, spec: FieldSpec, is_weekday: bool) CronError!?Set {
    if (field.len == 0) return CronError.CronMalformed;
    if (field.len == 1 and field[0] == '*') return null;

    var set = Set.initEmpty();
    var it = std.mem.splitScalar(u8, field, ',');
    while (it.next()) |part| try parsePart(part, spec, is_weekday, &set);
    if (set.count() == 0) return CronError.CronMalformed;
    return set;
}

/// Add one comma-list part's values to `set`. A part is a single literal,
/// an inclusive range `a-b`, or either of those with a step `.../N` (where
/// a bare `*` base spans the field's whole range).
fn parsePart(part: []const u8, spec: FieldSpec, is_weekday: bool, set: *Set) CronError!void {
    if (part.len == 0) return CronError.CronMalformed;

    var base = part;
    var step: u8 = 1;
    if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
        base = part[0..slash];
        step = try parseNum(part[slash + 1 ..]);
        if (step == 0) return CronError.CronMalformed;
    }

    var lo: u8 = undefined;
    var hi: u8 = undefined;
    if (base.len == 1 and base[0] == '*') {
        lo = spec.min;
        hi = spec.max;
    } else if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
        lo = try parseNum(base[0..dash]);
        hi = try parseNum(base[dash + 1 ..]);
    } else {
        lo = try parseNum(base);
        hi = lo;
    }
    if (lo < spec.min or hi > spec.max or lo > hi) return CronError.CronOutOfRange;

    // launchd and cron both treat weekday 7 as Sunday; fold it onto 0 so the
    // emitted value is canonical and `0,7` dedups to one entry. The accumulator
    // is widened so a large step can't overflow u8 mid-stride (hi ≤ 59).
    var v: usize = lo;
    while (v <= hi) : (v += step) {
        const canon: u8 = if (is_weekday and v == 7) 0 else @intCast(v);
        set.set(canon);
    }
}

fn parseNum(s: []const u8) CronError!u8 {
    if (s.len == 0) return CronError.CronMalformed;
    // Non-digit bytes are names / Quartz tokens (MON, ?, L, 15W) launchd can't
    // express; an overflow is a value far past any field's range.
    return std.fmt.parseInt(u8, s, 10) catch |e| switch (e) {
        error.InvalidCharacter => CronError.CronUnsupported,
        error.Overflow => CronError.CronOutOfRange,
    };
}

/// Materialise the cartesian product of the field sets into `out` (length
/// already equals the product). Wildcard fields emit null; others step through
/// their values via an odometer with the weekday field varying fastest.
fn fillEntries(sets: [5]?Set, out: []CalendarInterval) void {
    var values: [5][64]u8 = undefined;
    var lens: [5]usize = undefined;
    var wild: [5]bool = undefined;
    for (sets, 0..) |maybe, i| {
        if (maybe) |s| {
            wild[i] = false;
            var m: usize = 0;
            var bit: usize = 0;
            while (bit < 64) : (bit += 1) {
                if (s.isSet(bit)) {
                    values[i][m] = @intCast(bit);
                    m += 1;
                }
            }
            lens[i] = m;
        } else {
            wild[i] = true;
            lens[i] = 1; // single "every" slot
        }
    }

    var idx = [_]usize{0} ** 5;
    var oi: usize = 0;
    while (oi < out.len) : (oi += 1) {
        var v: [5]?u8 = undefined;
        for (0..5) |i| v[i] = if (wild[i]) null else values[i][idx[i]];
        out[oi] = .{
            .minute = v[0],
            .hour = v[1],
            .day = v[2],
            .month = v[3],
            .weekday = v[4],
        };
        var k: usize = 5;
        while (k > 0) {
            k -= 1;
            idx[k] += 1;
            if (idx[k] < lens[k]) break;
            idx[k] = 0;
        }
    }
}

test "parseCron literal fields and * build a single dict" {
    const out = try parseCron(testing.allocator, "30 4 * * *");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(?u8, 30), out[0].minute);
    try testing.expectEqual(@as(?u8, 4), out[0].hour);
    try testing.expectEqual(@as(?u8, null), out[0].day);
    try testing.expectEqual(@as(?u8, null), out[0].month);
    try testing.expectEqual(@as(?u8, null), out[0].weekday);
}

test "parseCron all-wildcard yields one every-minute entry with no fields set" {
    // `* * * * *` is "every minute": a single dict with every field absent.
    const out = try parseCron(testing.allocator, "* * * * *");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(CalendarInterval{}, out[0]);
}

test "parseCron expands two list fields into their cartesian product" {
    // launchd ORs dicts, so two lists must enumerate every combination.
    const out = try parseCron(testing.allocator, "0,30 0,12 * * *");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 4), out.len);
    const want = [_][2]u8{ .{ 0, 0 }, .{ 0, 12 }, .{ 30, 0 }, .{ 30, 12 } };
    for (out, want) |e, w| {
        try testing.expectEqual(@as(?u8, w[0]), e.minute);
        try testing.expectEqual(@as(?u8, w[1]), e.hour);
    }
}

test "parseCron comma list expands one field into multiple dicts" {
    const out = try parseCron(testing.allocator, "0,30 12 * * *");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(?u8, 0), out[0].minute);
    try testing.expectEqual(@as(?u8, 30), out[1].minute);
    // Non-list fields repeat across every expanded entry.
    for (out) |e| try testing.expectEqual(@as(?u8, 12), e.hour);
}

test "parseCron range a-b enumerates each value" {
    const out = try parseCron(testing.allocator, "0 0 * * 1-5");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 5), out.len);
    for (out, 0..) |e, i| try testing.expectEqual(@as(?u8, @intCast(i + 1)), e.weekday);
}

test "parseCron step over wildcard enumerates the stride" {
    const out = try parseCron(testing.allocator, "*/15 * * * *");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 4), out.len);
    const want = [_]u8{ 0, 15, 30, 45 };
    for (out, want) |e, w| try testing.expectEqual(@as(?u8, w), e.minute);
}

test "parseCron step over a range honours both bounds" {
    const out = try parseCron(testing.allocator, "10-20/5 * * * *");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    const want = [_]u8{ 10, 15, 20 };
    for (out, want) |e, w| try testing.expectEqual(@as(?u8, w), e.minute);
}

test "parseCron weekday 7 canonicalises to Sunday 0" {
    const sun7 = try parseCron(testing.allocator, "0 0 * * 7");
    defer testing.allocator.free(sun7);
    try testing.expectEqual(@as(usize, 1), sun7.len);
    try testing.expectEqual(@as(?u8, 0), sun7[0].weekday);

    // `0,7` is Sunday twice — it must collapse to one entry, not two.
    const both = try parseCron(testing.allocator, "0 0 * * 0,7");
    defer testing.allocator.free(both);
    try testing.expectEqual(@as(usize, 1), both.len);
    try testing.expectEqual(@as(?u8, 0), both[0].weekday);
}

test "parseCron rejects an over-cap expansion" {
    // `*/1 * * * *` is 60 minute entries — exactly the cap, accepted.
    const ok = try parseCron(testing.allocator, "*/1 * * * *");
    defer testing.allocator.free(ok);
    try testing.expectEqual(max_calendar_entries, ok.len);

    // Two enumerated fields (60 minutes * 2 hours = 120) blow past the cap.
    try testing.expectError(CronError.CronTooComplex, parseCron(testing.allocator, "*/1 0-1 * * *"));
}

test "parseCron rejects tokens launchd cannot express as unsupported" {
    const unsupported = [_][]const u8{
        "@daily", // macro
        "@reboot", // macro
        "0 0 * * MON", // named weekday
        "0 0 * JAN *", // named month
        "0 0 ? * *", // Quartz no-op
        "0 0 L * *", // last-day-of-month
        "0 0 15W * *", // nearest weekday
    };
    for (unsupported) |expr| {
        try testing.expectError(CronError.CronUnsupported, parseCron(testing.allocator, expr));
    }
}

test "parseCron step past the field max stops without overflow" {
    // 59 + step would overflow a u8 mid-loop; the stride must terminate
    // cleanly with just the in-range value rather than trapping.
    const out = try parseCron(testing.allocator, "59/200 * * * *");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(?u8, 59), out[0].minute);
}

test "parseCron rejects out-of-range field values" {
    const out_of_range = [_][]const u8{
        "60 0 * * *", // minute past 59
        "0 24 * * *", // hour past 23
        "0 0 0 * *", // day-of-month below 1
        "0 0 32 * *", // day-of-month past 31
        "0 0 * 13 *", // month past 12
        "0 0 * * 8", // weekday past 7
        "5-1 * * * *", // reversed range
    };
    for (out_of_range) |expr| {
        try testing.expectError(CronError.CronOutOfRange, parseCron(testing.allocator, expr));
    }
}

test "parseCron rejects structurally malformed expressions" {
    const malformed = [_][]const u8{
        "", // empty
        "0 0 * *", // too few fields
        "0 0 * * * *", // too many fields
        "0,,30 * * * *", // empty list element
        "*/0 * * * *", // zero step
    };
    for (malformed) |expr| {
        try testing.expectError(CronError.CronMalformed, parseCron(testing.allocator, expr));
    }
}
