//! malt — DSL fallback log
//! Structured telemetry for operations the interpreter cannot handle.

const std = @import("std");
const ast = @import("ast.zig");
const output = @import("../../ui/output.zig");

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
    entries: std.ArrayList(FallbackEntry),
    allocator: std.mem.Allocator,
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
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FallbackLog) void {
        self.entries.deinit(self.allocator);
    }

    pub fn log(self: *FallbackLog, entry: FallbackEntry) void {
        // Silent drop on OOM: parent allocator failures surface elsewhere
        // and threading ctx through every call site just for a warning
        // would be more noise than signal.
        self.entries.append(self.allocator, entry) catch {};
    }

    pub fn hasErrors(self: *const FallbackLog) bool {
        return self.entries.items.len > 0;
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
        for (self.entries.items) |entry| {
            switch (entry.reason) {
                .sandbox_violation, .system_command_failed => return true,
                else => {},
            }
        }
        return false;
    }

    /// Print every fatal-or-diagnostic entry in `tag:line:col: message` form.
    /// `parse_error` is included so users see the exact file:line:col when the
    /// DSL falls back to `--use-system-ruby`; it is not treated as fatal by
    /// `hasFatal`, keeping the salvage path open.
    pub fn printFatal(self: *const FallbackLog, tag: []const u8) void {
        for (self.entries.items) |entry| {
            const printable = switch (entry.reason) {
                .sandbox_violation, .system_command_failed, .parse_error => true,
                else => false,
            };
            if (!printable) continue;
            var buf: [1024]u8 = undefined;
            const formatted = if (entry.loc) |loc|
                std.fmt.bufPrint(&buf, "  {s}:{d}:{d}: [{s}] {s}\n", .{
                    tag, loc.line, loc.col, @tagName(entry.reason), entry.detail,
                }) catch continue
            else
                std.fmt.bufPrint(&buf, "  {s}: [{s}] {s}\n", .{
                    tag, @tagName(entry.reason), entry.detail,
                }) catch continue;
            output.writeStderrAll(formatted);
        }
    }

    /// Print unknown_method / unsupported_node entries to stderr — the
    /// log-only reasons that `printFatal` intentionally skips. Called by
    /// the install CLI under `--verbose` so users can see which helpers
    /// the DSL silently downgraded instead of only the "partially skipped"
    /// hint.
    pub fn printUnknown(self: *const FallbackLog, tag: []const u8) void {
        for (self.entries.items) |entry| {
            const unknown = switch (entry.reason) {
                .unknown_method, .unsupported_node => true,
                else => false,
            };
            if (!unknown) continue;
            var buf: [1024]u8 = undefined;
            const formatted = if (entry.loc) |loc|
                std.fmt.bufPrint(&buf, "  {s}:{d}:{d}: [{s}] {s}\n", .{
                    tag, loc.line, loc.col, @tagName(entry.reason), entry.detail,
                }) catch continue
            else
                std.fmt.bufPrint(&buf, "  {s}: [{s}] {s}\n", .{
                    tag, @tagName(entry.reason), entry.detail,
                }) catch continue;
            output.writeStderrAll(formatted);
        }
    }

    /// Serialize to JSON for telemetry reporting.
    pub fn toJson(self: *const FallbackLog, allocator: std.mem.Allocator) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("[");
        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"formula\":\"");
            try writer.writeAll(entry.formula);
            try writer.writeAll("\",\"reason\":\"");
            try writer.writeAll(@tagName(entry.reason));
            try writer.writeAll("\",\"detail\":\"");
            try writer.writeAll(entry.detail);
            try writer.writeAll("\"");
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
