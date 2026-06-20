//! malt — service schedule model
//!
//! A std-only leaf shared by the formula parser and the plist emitter, so
//! neither side has to import the other just to name a schedule.

const std = @import("std");
const testing = std.testing;

/// One launchd `StartCalendarInterval` entry. Defined now so adding cron
/// support is purely additive; unused until then.
pub const CalendarInterval = struct {
    minute: ?u8 = null,
    hour: ?u8 = null,
    day: ?u8 = null,
    weekday: ?u8 = null,
    month: ?u8 = null,
};

/// How a service is scheduled under launchd.
pub const Schedule = union(enum) {
    /// `RunAtLoad true`, no interval — run once when loaded (today's default).
    immediate,
    /// `RunAtLoad false` + `StartInterval <secs>`.
    interval: u32,
    /// `StartCalendarInterval` — not emitted yet; reserved for cron support.
    calendar: []const CalendarInterval,
};

/// Upper bound on a `StartInterval`, in seconds. A year is far beyond any
/// real periodic service while keeping the value a small bounded integer —
/// the same value gates both the parser and `plist.validate`.
pub const max_interval_secs: u32 = 365 * 24 * 60 * 60;

/// Cap on enumerated `StartCalendarInterval` entries. A pathological cron
/// expansion (e.g. `*/1` across two fields) would otherwise produce a huge
/// plist; 60 covers every real formula ("every 5 minutes" is 12 entries)
/// while staying small. Gates both the cron parser and `plist.validate`.
pub const max_calendar_entries: usize = 60;

/// Render a short human label for a schedule, e.g. `"interval 300s"` or
/// `"cron 30 4 * * 6"`. `.immediate` yields `""` so a run-at-load service
/// shows no schedule. The label is the convenience cache stored on the
/// services row; the on-disk plist stays authoritative. Caller owns the slice.
pub fn scheduleLabel(allocator: std.mem.Allocator, sched: Schedule) std.mem.Allocator.Error![]u8 {
    return switch (sched) {
        .immediate => allocator.dupe(u8, ""),
        .interval => |secs| std.fmt.allocPrint(allocator, "interval {d}s", .{secs}),
        .calendar => |entries| calendarLabel(allocator, entries),
    };
}

/// Re-render calendar entries as a cron-order label `"cron <min> <hour> <dom>
/// <month> <dow>"`. `parseCron` emits the full cartesian product per field, so
/// collecting each field's distinct values reconstructs an equivalent
/// expression (`*` where every entry left the field unset).
fn calendarLabel(allocator: std.mem.Allocator, entries: []const CalendarInterval) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    // Allocating.Writer only fails on OOM; map that single cause back.
    w.writeAll("cron") catch return error.OutOfMemory;
    appendCronField(w, entries, "minute") catch return error.OutOfMemory;
    appendCronField(w, entries, "hour") catch return error.OutOfMemory;
    appendCronField(w, entries, "day") catch return error.OutOfMemory;
    appendCronField(w, entries, "month") catch return error.OutOfMemory;
    appendCronField(w, entries, "weekday") catch return error.OutOfMemory;
    return allocator.dupe(u8, aw.written());
}

fn appendCronField(w: *std.Io.Writer, entries: []const CalendarInterval, comptime field: []const u8) !void {
    try w.writeByte(' ');
    // A field unset in the first entry is unset in all (cron fields enumerate
    // together), so `*` covers it.
    if (entries.len == 0 or @field(entries[0], field) == null) return w.writeByte('*');
    var seen = [_]bool{false} ** 256;
    for (entries) |e| if (@field(e, field)) |v| {
        seen[v] = true;
    };
    var first = true;
    for (0..256) |v| if (seen[v]) {
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{d}", .{v});
    };
}

test "scheduleLabel: expanded entries collect each field's distinct values" {
    // `*/15 * * * *` expands to four minute entries; the label collects them
    // back into one comma list rather than printing four cron lines.
    const entries = [_]CalendarInterval{
        .{ .minute = 0 }, .{ .minute = 15 }, .{ .minute = 30 }, .{ .minute = 45 },
    };
    const label = try scheduleLabel(testing.allocator, .{ .calendar = &entries });
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("cron 0,15,30,45 * * * *", label);
}
