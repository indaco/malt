//! malt — renders the passive "a newer malt is available" heads-up.
//!
//! Lives in `cli/` because it is presentation: `update/notifier` decides
//! whether a notice is due, this decides what it looks like. Keeping the
//! ANSI and the stderr writes on this side is what lets the notifier stay a
//! UI-agnostic leaf.

const std = @import("std");

const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
const release = @import("../update/release.zig");

/// Headline keeps the violet `notice` palette so an available update reads
/// as a heads-up, not a warning; the action hint stays dim — reference
/// material, not the message. Rendered inline (rather than via
/// `output.notice`/`output.dim`) so the layout can sit flush-left under a
/// blank-line separator, which reads better at the tail of any subcommand.
pub fn print(latest_tag: []const u8, current_version: []const u8) void {
    const latest_no_v = release.stripVPrefix(latest_tag);

    var notice_buf: [4096]u8 = undefined;
    const notice_msg = std.fmt.bufPrint(
        &notice_buf,
        "A newer malt is available: {s} (you're on {s}).",
        .{ latest_no_v, current_version },
    ) catch return;
    const dim_msg = "Run 'mt version update' to upgrade, or set MALT_NO_VERSION_NOTIFIER=1 to silence this.";

    const colorize = color.isColorEnabledForStderr();
    const emoji = color.isEmojiEnabled();
    const notice_prefix: []const u8 = if (emoji) "ⓘ " else "i ";
    const dim_prefix: []const u8 = if (emoji) "▸ " else "> ";

    // Blank line separates the heads-up from whatever the subcommand
    // printed last. Safe: notifier fires post-dispatch, no other worker
    // is writing concurrently here.
    output.writeStderrAll("\n");

    if (colorize) {
        output.writeStderrAll(color.SemanticStyle.notice.code());
        output.writeStderrAll(notice_prefix);
        output.writeStderrAll(color.Style.reset.code());
    } else {
        output.writeStderrAll(notice_prefix);
    }
    output.writeStderrAll(notice_msg);
    output.writeStderrAll("\n");

    if (colorize) {
        output.writeStderrAll(color.SemanticStyle.detail.code());
        output.writeStderrAll(dim_prefix);
        output.writeStderrAll(dim_msg);
        output.writeStderrAll(color.Style.reset.code());
    } else {
        output.writeStderrAll(dim_prefix);
        output.writeStderrAll(dim_msg);
    }
    output.writeStderrAll("\n");
}

// Pins the heads-up layout: blank-line separator + flush-left prefixes
// in both palettes. The blank line keeps the notice from sticking to a
// subcommand's last line of output; the flush margin keeps the glyphs
// aligned with the user's prompt regardless of which subcommand ran.
test "printNotice: blank-line + flush-left layout, color + emoji on (dark + basic)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    color.setForTest(true, true);
    color.setBackgroundForTest(color.Background.dark);
    color.setTruecolorForTest(false);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer {
        output.endStderrCapture();
        color.setForTest(null, null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
    }

    print("v0.11.6", "0.11.0");

    const want = "\n" ++
        "\x1b[35mⓘ \x1b[0mA newer malt is available: 0.11.6 (you're on 0.11.0).\n" ++
        "\x1b[2m▸ Run 'mt version update' to upgrade, or set MALT_NO_VERSION_NOTIFIER=1 to silence this.\x1b[0m\n";
    try std.testing.expectEqualStrings(want, buf.items);
}

test "printNotice: no color, no emoji → flush-left ASCII layout" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    color.setForTest(false, false);
    output.beginStderrCapture(std.testing.allocator, &buf);
    defer {
        output.endStderrCapture();
        color.setForTest(null, null);
    }

    print("v0.11.6", "0.11.0");

    const want = "\n" ++
        "i A newer malt is available: 0.11.6 (you're on 0.11.0).\n" ++
        "> Run 'mt version update' to upgrade, or set MALT_NO_VERSION_NOTIFIER=1 to silence this.\n";
    try std.testing.expectEqualStrings(want, buf.items);
}
