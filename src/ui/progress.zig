const std = @import("std");

pub const ProgressBar = struct {
    total: u64,
    current: u64,
    label: []const u8,

    /// Creates a new progress bar with the given label and total count.
    pub fn init(label: []const u8, total: u64) ProgressBar {
        return .{
            .total = total,
            .current = 0,
            .label = label,
        };
    }

    /// Updates the progress bar to the given current value.
    pub fn update(self: *ProgressBar, current: u64) void {
        self.current = current;
        _ = undefined;
    }

    /// Marks the progress bar as finished.
    pub fn finish(self: *ProgressBar) void {
        self.current = self.total;
        _ = undefined;
    }
};
