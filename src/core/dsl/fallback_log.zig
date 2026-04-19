//! malt — DSL fallback log
//! Structured telemetry for operations the interpreter cannot handle.

const std = @import("std");
const ast = @import("ast.zig");
const io_mod = @import("../../ui/io.zig");

pub const FallbackReason = enum {
    unknown_method,
    unsupported_node,
    sandbox_violation,
    system_command_failed,
    /// Parser diagnostic propagated from `Parser.diagnostics` after a
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
        self.entries.append(self.allocator, entry) catch {
            // This log is the user's only window into sandbox violations
            // and unsupported constructs; if it's dropping entries under
            // memory pressure the user deserves to know.
            io_mod.stderrWriteAll("malt: fallback log dropped an entry due to OOM\n");
        };
    }

    pub fn hasErrors(self: *const FallbackLog) bool {
        return self.entries.items.len > 0;
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
            io_mod.stderrWriteAll(formatted);
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
