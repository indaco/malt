//! Sink leaf for the TUI's shared read-model and effect ports. Both `app.zig`
//! (the hub) and every `*_tab.zig` import this *downward*: it names the types
//! they share so a tab never has to reach up into `app.zig` for them, which
//! would turn the hub into an import cycle. It imports only `std` and existing
//! tui leaves — never `app.zig` or any tab.

const std = @import("std");
const term = @import("term.zig");
const tab_bar = @import("tab_bar.zig");
const term_sanitize = @import("../ui/term_sanitize.zig");

const Tab = tab_bar.Tab;

/// The already-leaf terminal handle, re-exported so `Ctx` can name it without a
/// second import edge radiating from the hub.
pub const Term = term.Term;

/// Cap on the recoverable-error banner. An op label + an error name fit well
/// inside this; the cap keeps the buffer fixed so the banner never allocates.
pub const banner_max = 160;

/// A transient banner for a recoverable backend failure, shown in the footer.
/// Fixed buffer, no allocation, like the filter. Set when a delegated op fails
/// recoverably, cleared on the next keypress (`step`). The message is run
/// through `term_sanitize` at set-time because the op label may carry a
/// child-derived package name — the leaf's untrusted-input rule.
pub const Banner = struct {
    buf: [banner_max]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Banner) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isSet(self: *const Banner) bool {
        return self.len != 0;
    }

    pub fn clear(self: *Banner) void {
        self.len = 0;
    }

    /// Format "<op>: <reason>" into the fixed buffer, run through `term_sanitize`
    /// so a child-derived package name in `op` cannot inject escape sequences.
    /// Truncated at the cap; the footer render also strips line-breakers the
    /// sanitizer lets through (`putContent`).
    pub fn set(self: *Banner, op: []const u8, reason: []const u8) void {
        self.len = 0;
        var san = term_sanitize.Sanitizer.init();
        const sink: term_sanitize.Sink = .{ .ctx = self, .write_fn = appendSink };
        // The buffered sink never fails — it truncates at the cap — so the
        // sanitizer's propagated error cannot occur here; ignore it deliberately.
        san.feed(op, sink) catch {};
        san.feed(": ", sink) catch {};
        san.feed(reason, sink) catch {};
        san.flush(sink) catch {};
    }

    /// `term_sanitize.Sink` callback: append clean bytes, bounded by the cap.
    /// `@ptrCast` is the sink's `*anyopaque` → `*Banner` round-trip; the ctx was
    /// set from a `*Banner` just above, so the cast is sound.
    fn appendSink(ctx: *anyopaque, bytes: []const u8) term_sanitize.SinkError!void {
        const self: *Banner = @ptrCast(@alignCast(ctx));
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }
};

/// Mid-load repaint handle for the polled lazy reads: the controlling-tty fd and
/// the (resizable) frame buffer, threaded to wherever a lazy load runs so its
/// spinner can repaint without `spawn.zig` knowing about rendering.
pub const Painter = struct {
    fd: std.posix.fd_t,
    frame: *[]u8,
};

/// One in-flight background tab fetch: a non-blocking `mt <verb> --json` child
/// whose stdout the loop drains. `tab` routes the drained bytes to the owning
/// store; `max_ok_exit` tolerates Doctor's severity exits (≤2) where the others
/// require a clean 0.
pub const TabFetch = struct {
    tab: Tab,
    child: std.process.Child,
    fd: std.posix.fd_t, // the child's stdout, polled alongside the tty
    buf: std.ArrayList(u8) = .empty,
    max_ok_exit: u8,
};

/// At most one in-flight fetch per tab. Installed (a cheap DB read) and Search
/// (synchronous by design) never background-fetch, so their slots stay null.
pub const Fetches = std.EnumArray(Tab, ?TabFetch);

/// The genuinely multi-writer/multi-reader read-model: header counts, the
/// cross-tab dirty set, and the recoverable-failure banner. App-owned and passed
/// by pointer so cross-tab writers touch only these scalars, never another tab's
/// private storage.
pub const SharedModel = struct {
    installed_count: ?usize = null,
    outdated_count: ?usize = null,
    dirty: std.EnumSet(Tab) = .initEmpty(),
    banner: Banner = .{},
};

/// The effect ports bundle, passed by pointer to whatever performs an effect.
/// Names the leaves it composes (`Term`, `Painter`, `Fetches`) plus the shared
/// read-model — nothing here reaches back into the hub.
pub const Ctx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    term: *Term,
    painter: Painter,
    fetches: *Fetches,
    shared: *SharedModel,
};

test "SharedModel defaults and mutation mirror the old inline App fields" {
    var m: SharedModel = .{};
    try std.testing.expectEqual(@as(?usize, null), m.installed_count);
    try std.testing.expectEqual(@as(?usize, null), m.outdated_count);
    try std.testing.expect(!m.dirty.contains(.outdated));
    try std.testing.expect(!m.banner.isSet());

    m.installed_count = 3;
    m.outdated_count = 1;
    m.dirty.insert(.outdated);
    try std.testing.expectEqual(@as(?usize, 3), m.installed_count);
    try std.testing.expectEqual(@as(?usize, 1), m.outdated_count);
    try std.testing.expect(m.dirty.contains(.outdated));

    // The dirty set tracks tabs independently — a second mark leaves the first
    // set and an unmarked tab clear, so a cross-tab staleness never bleeds.
    m.dirty.insert(.services);
    try std.testing.expect(m.dirty.contains(.services));
    try std.testing.expect(m.dirty.contains(.outdated));
    try std.testing.expect(!m.dirty.contains(.installed));
}

test "banner formats op + reason and reports set/clear" {
    var b: Banner = .{};
    try std.testing.expect(!b.isSet());
    b.set("info for jq failed", "BadJson");
    try std.testing.expect(b.isSet());
    try std.testing.expectEqualStrings("info for jq failed: BadJson", b.slice());
    b.clear();
    try std.testing.expect(!b.isSet());
    try std.testing.expectEqualStrings("", b.slice());
}

test "banner sanitizes a child-derived op so a package name cannot inject escapes" {
    var b: Banner = .{};
    // A hostile tap could name a package with an OSC title-set; it must be dropped.
    b.set("info for \x1b]0;pwn\x07evil failed", "BadJson");
    try std.testing.expect(std.mem.indexOfScalar(u8, b.slice(), 0x1b) == null); // no stray ESC
    try std.testing.expect(std.mem.indexOf(u8, b.slice(), "evil failed: BadJson") != null);
}

test "banner truncates an over-cap op to the fixed buffer without overflow" {
    var b: Banner = .{};
    var huge: [banner_max * 2]u8 = undefined;
    @memset(&huge, 'x');
    b.set(&huge, "BadJson");
    try std.testing.expect(b.isSet());
    try std.testing.expect(b.slice().len <= banner_max); // bounded, no overrun
}

test "Ctx bundles the effect ports and points at the shared read-model" {
    try std.testing.expect(@hasField(Ctx, "io"));
    try std.testing.expect(@hasField(Ctx, "allocator"));
    // The mutable, borrowed handles are held by pointer; the small `Painter` is
    // passed by value, mirroring how the hub threads them today.
    try std.testing.expectEqual(*Term, @FieldType(Ctx, "term"));
    try std.testing.expectEqual(Painter, @FieldType(Ctx, "painter"));
    try std.testing.expectEqual(*Fetches, @FieldType(Ctx, "fetches"));
    try std.testing.expectEqual(*SharedModel, @FieldType(Ctx, "shared"));
}
