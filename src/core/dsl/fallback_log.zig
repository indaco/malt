//! malt — DSL fallback log
//! Structured telemetry for operations the interpreter cannot handle.

const std = @import("std");
const ast = @import("ast.zig");
const json_escape = @import("../json_escape.zig");

pub const FallbackReason = enum {
    unknown_method,
    unsupported_node,
    sandbox_violation,
    system_command_failed,
    /// Parser diagnostic propagated from `Parser.diagnostics()` after a
    /// `parseBlock` failure. Carries the offending line/col in `loc`.
    parse_error,
};

pub const FallbackEntry = struct {
    formula: []const u8,
    reason: FallbackReason,
    detail: []const u8,
    loc: ?ast.SourceLoc,
};

pub const FallbackLog = struct {
    _entries: std.ArrayList(FallbackEntry),
    /// Free-form diagnostics (raise messages, inreplace fallback warnings)
    /// the caller renders verbatim. Kept separate from `_entries` so a note
    /// never participates in routing (`hasErrors`/`hasFatal`/`toJson`).
    _notes: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    /// Set when an append fails under memory pressure. A pure log can't
    /// render, so the caller reads this at the rendering seam and warns
    /// that "post_install was partially skipped" was itself dropped.
    dropped_oom: bool = false,
    /// Top-level statements the interpreter attempted to evaluate. Bumped
    /// per-node by `Interpreter.execute`; tests construct synthetic logs by
    /// setting this directly.
    total_top_level: usize = 0,
    /// Top-level statements that completed without logging any new entry.
    /// `dslDidWork()` reads this so the post_install router can tell
    /// "DSL handled the body and warned" from "DSL handled none of it" —
    /// re-running a partially-applied body via Ruby double-stamps any
    /// non-idempotent side effect (counters, timestamps, version caches).
    handled_top_level: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FallbackLog {
        return .{
            ._entries = .empty,
            ._notes = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FallbackLog) void {
        for (self._notes.items) |n| self.allocator.free(n);
        self._notes.deinit(self.allocator);
        self._entries.deinit(self.allocator);
    }

    pub fn log(self: *FallbackLog, entry: FallbackEntry) void {
        self._entries.append(self.allocator, entry) catch {
            // Record the drop as a flag the caller renders — the pure log
            // never writes stderr itself.
            self.dropped_oom = true;
        };
    }

    /// Record a free-form diagnostic line, owning a copy. Append-only and
    /// OOM-tolerant: a failed dupe flags `dropped_oom` rather than raising.
    pub fn note(self: *FallbackLog, line: []const u8) void {
        const owned = self.allocator.dupe(u8, line) catch {
            self.dropped_oom = true;
            return;
        };
        self._notes.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            self.dropped_oom = true;
        };
    }

    /// Read-only view of the routing entries — callers render at their seam.
    pub fn entries(self: *const FallbackLog) []const FallbackEntry {
        return self._entries.items;
    }

    /// Read-only view of the diagnostic notes.
    pub fn notes(self: *const FallbackLog) []const []const u8 {
        return self._notes.items;
    }

    pub fn hasErrors(self: *const FallbackLog) bool {
        return self._entries.items.len > 0;
    }

    /// True when at least one top-level statement evaluated without a new
    /// fall-through being logged during it. The router uses this to gate
    /// the system-Ruby re-run: re-executing a body whose effects already
    /// landed double-stamps non-idempotent steps (counters, timestamps,
    /// version-stamped caches), so we accept the partial result instead.
    pub fn dslDidWork(self: *const FallbackLog) bool {
        return self.handled_top_level > 0;
    }

    pub fn hasFatal(self: *const FallbackLog) bool {
        return self.hasFatalSince(0);
    }

    /// Fatal among the entries appended after the first `start`, so one log
    /// can carry several phases and each is judged on its own.
    pub fn hasFatalSince(self: *const FallbackLog, start: usize) bool {
        for (self._entries.items[@min(start, self._entries.items.len)..]) |entry| {
            switch (entry.reason) {
                .sandbox_violation, .system_command_failed => return true,
                else => {},
            }
        }
        return false;
    }

    /// Serialize to JSON for telemetry reporting.
    pub fn toJson(self: *const FallbackLog, allocator: std.mem.Allocator) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("[");
        for (self._entries.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"formula\":");
            try json_escape.jsonStr(writer, entry.formula);
            try writer.writeAll(",\"reason\":\"");
            try writer.writeAll(@tagName(entry.reason));
            try writer.writeAll("\",\"detail\":");
            try json_escape.jsonStr(writer, entry.detail);
            if (entry.loc) |loc| {
                try writer.print(",\"line\":{d},\"col\":{d}", .{ loc.line, loc.col });
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        return aw.toOwnedSlice();
    }
};

test "dslDidWork: empty log reports no work done" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    try std.testing.expect(!flog.dslDidWork());
}

test "dslDidWork: entries alone do not imply work was done" {
    // A synthetic log with only logged entries (no successful statement
    // counted) reflects "DSL handled none of the body" — the router must
    // still treat this as a fall-back-eligible state.
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "x", .reason = .unknown_method, .detail = "h", .loc = null });
    try std.testing.expect(flog.hasErrors());
    try std.testing.expect(!flog.dslDidWork());
}

test "dslDidWork: at least one handled statement flips the signal" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    flog.total_top_level = 5;
    flog.handled_top_level = 4;
    flog.log(.{ .formula = "x", .reason = .unknown_method, .detail = "h", .loc = null });
    try std.testing.expect(flog.hasErrors());
    try std.testing.expect(flog.dslDidWork());
}

// Under memory pressure the diagnostic log itself can fail to grow. A
// pure log can't render, so it records the drop as a flag the caller
// reads at the rendering seam — no stderr write, no test capture.
test "log flags dropped_oom when the entry append OOMs and records nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var flog = FallbackLog.init(failing.allocator());
    defer flog.deinit();

    flog.log(.{ .formula = "demo", .reason = .unknown_method, .detail = "boom", .loc = null });

    try std.testing.expectEqual(@as(usize, 0), flog.entries().len);
    try std.testing.expect(flog.dropped_oom);
}

test "entries() exposes the logged entries without stderr capture" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "wget", .reason = .sandbox_violation, .detail = "/etc/passwd", .loc = null });

    const items = flog.entries();
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(FallbackReason.sandbox_violation, items[0].reason);
    try std.testing.expectEqualStrings("/etc/passwd", items[0].detail);
}

// The notes channel records free-form diagnostics (raise, inreplace
// fallback) the caller renders verbatim. It must stay independent of
// routing: a note alone is not an error and does not flip hasErrors.
test "note() records a diagnostic the caller can read, without affecting routing" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();

    flog.note("  x boom\n");

    try std.testing.expectEqual(@as(usize, 1), flog.notes().len);
    try std.testing.expectEqualStrings("  x boom\n", flog.notes()[0]);
    try std.testing.expect(!flog.hasErrors());
    try std.testing.expect(!flog.hasFatal());
    try std.testing.expectEqual(@as(usize, 0), flog.entries().len);
}

test "note() owns its copy: the source buffer may be reused after the call" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();

    var buf: [16]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    flog.note(buf[0..5]);
    @memcpy(buf[0..5], "world"); // clobber the source

    try std.testing.expectEqualStrings("hello", flog.notes()[0]);
}

test "note() preserves insertion order across multiple records" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();

    flog.note("first");
    flog.note("second");

    try std.testing.expectEqual(@as(usize, 2), flog.notes().len);
    try std.testing.expectEqualStrings("first", flog.notes()[0]);
    try std.testing.expectEqualStrings("second", flog.notes()[1]);
}

// Edge: the diagnostics channel is OOM-tolerant too. A failed dupe must
// flag the drop rather than record a dangling slice — same contract as
// `log`, so the caller's "dropped due to OOM" notice still fires.
test "note() flags dropped_oom and records nothing when the dupe OOMs" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var flog = FallbackLog.init(failing.allocator());
    defer flog.deinit();

    flog.note("would-be diagnostic");

    try std.testing.expectEqual(@as(usize, 0), flog.notes().len);
    try std.testing.expect(flog.dropped_oom);
}

test "toJson escapes quote, backslash and newline in formula and detail" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    const formula = "f\"o";
    const detail = "a\"b\\c\n";
    flog.log(.{ .formula = formula, .reason = .system_command_failed, .detail = detail, .loc = null });

    const j = try flog.toJson(std.testing.allocator);
    defer std.testing.allocator.free(j);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, j, .{});
    defer parsed.deinit();
    const obj = parsed.value.array.items[0].object;
    try std.testing.expectEqualStrings(formula, obj.get("formula").?.string);
    try std.testing.expectEqualStrings(detail, obj.get("detail").?.string);
}

test "toJson escapes terminal control bytes in detail" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "f", .reason = .system_command_failed, .detail = "\x1b]52;c;AAAA\x07", .loc = null });

    const j = try flog.toJson(std.testing.allocator);
    defer std.testing.allocator.free(j);

    try std.testing.expect(std.mem.indexOfScalar(u8, j, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, j, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\\u001b") != null);
}

test "toJson keeps the shape of escape-free entries" {
    var flog = FallbackLog.init(std.testing.allocator);
    defer flog.deinit();
    flog.log(.{ .formula = "wget", .reason = .unknown_method, .detail = "h", .loc = null });
    flog.log(.{ .formula = "wget", .reason = .parse_error, .detail = "h", .loc = .{ .line = 3, .col = 4 } });

    const j = try flog.toJson(std.testing.allocator);
    defer std.testing.allocator.free(j);

    try std.testing.expectEqualStrings(
        "[{\"formula\":\"wget\",\"reason\":\"unknown_method\",\"detail\":\"h\"}," ++
            "{\"formula\":\"wget\",\"reason\":\"parse_error\",\"detail\":\"h\",\"line\":3,\"col\":4}]",
        j,
    );
}
