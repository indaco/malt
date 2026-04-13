//! malt — DSL fallback log
//! Structured telemetry for operations the interpreter cannot handle.

const std = @import("std");
const ast = @import("ast.zig");

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
            const f = std.fs.File.stderr();
            f.writeAll("malt: fallback log dropped an entry due to OOM\n") catch {};
        };
    }

    pub fn hasErrors(self: *const FallbackLog) bool {
        return self.entries.items.len > 0;
    }

    pub fn hasFatal(self: *const FallbackLog) bool {
        for (self.entries.items) |entry| {
            switch (entry.reason) {
                .sandbox_violation, .system_command_failed, .parse_error => return true,
                else => {},
            }
        }
        return false;
    }

    /// Print every fatal entry to stderr in `tag:line:col: message` form so
    /// users debugging a broken `post_install` block can jump straight to
    /// the offending line. `tag` is typically the formula name. The
    /// non-fatal entries (unknown_method / unsupported_node) are
    /// intentionally skipped — those drive the `--use-system-ruby`
    /// fallback flow and would just be noise here.
    pub fn printFatal(self: *const FallbackLog, tag: []const u8) void {
        const f = std.fs.File.stderr();
        for (self.entries.items) |entry| {
            const fatal = switch (entry.reason) {
                .sandbox_violation, .system_command_failed, .parse_error => true,
                else => false,
            };
            if (!fatal) continue;
            var buf: [1024]u8 = undefined;
            const formatted = if (entry.loc) |loc|
                std.fmt.bufPrint(&buf, "  {s}:{d}:{d}: [{s}] {s}\n", .{
                    tag, loc.line, loc.col, @tagName(entry.reason), entry.detail,
                }) catch continue
            else
                std.fmt.bufPrint(&buf, "  {s}: [{s}] {s}\n", .{
                    tag, @tagName(entry.reason), entry.detail,
                }) catch continue;
            f.writeAll(formatted) catch {};
        }
    }

    /// Serialize to JSON for telemetry reporting.
    pub fn toJson(self: *const FallbackLog, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const writer = buf.writer(allocator);

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

        return buf.toOwnedSlice(allocator);
    }
};
