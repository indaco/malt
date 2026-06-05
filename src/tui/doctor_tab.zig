//! malt — Doctor tab for `mt tui` (placeholder; data lands in a later layer).

const tab = @import("tab.zig");

pub const State = struct { chrome: tab.Chrome = .{} };

pub fn title() []const u8 {
    return "Doctor";
}

pub fn step(s: *State, key: tab.Key) void {
    _ = s;
    _ = key;
}

pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    tab.paintRows(f, &placeholder, s.chrome.view, r);
}

const placeholder = [_][]const u8{"Doctor — no data yet"};

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}
