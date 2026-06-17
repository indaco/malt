//! malt — the tab contract + shared widgets for `mt tui`.
//!
//! Leaf module. Defines what a tab *is* so every tab plugs in the same way:
//! a module exposing `State` (carrying a `chrome: Chrome` the shell drives),
//! `title`, `step` (domain keys only), and `render`. `verify` checks the shape
//! at comptime, so adding a non-conforming tab is a build error — no runtime
//! vtable. `Frame` is the bounded frame-byte appender every renderer paints
//! into; `paintRows` is the shared list painter and the single place row
//! content is stripped of line-breaking controls before it reaches the frame.

const std = @import("std");
const color = @import("../ui/color.zig");
const scroll_list = @import("scroll_list.zig");
const layout = @import("layout.zig");
const filter_input = @import("filter_input.zig");
const keys = @import("keys.zig");
const term = @import("term.zig");

pub const Key = keys.Key;
pub const Rect = layout.Rect;

/// Cross-cutting per-tab state the shell owns the logic for (filter editing,
/// list navigation). Every tab `State` embeds one so the shell touches it
/// uniformly while the tab still owns its whole struct.
pub const Chrome = struct {
    filter: filter_input.Filter = .{},
    view: scroll_list.View = .{},
};

/// A bounded frame-byte appender. Writes stop at the buffer end (the frame is
/// truncated, never overflows) — same discipline as `layout.render`.
pub const Frame = struct {
    buf: []u8,
    len: usize = 0,

    pub fn slice(self: *const Frame) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn put(self: *Frame, bytes: []const u8) void {
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }

    /// Position the cursor (1-based). A 32-byte scratch always fits a CUP.
    pub fn moveTo(self: *Frame, row: u16, col: u16) void {
        var tmp: [32]u8 = undefined;
        self.put(term.cursorMove(&tmp, row, col) catch return);
    }

    /// Paint untrusted row content as inert text: TAB becomes a space and every
    /// C0 control byte — ESC included — plus DEL is dropped, so a child-derived
    /// row can neither re-drive the cursor (ESC/CSI), set the window title (OSC),
    /// inject an extra frame line (LF/CR/VT/FF), nor disturb column alignment
    /// (TAB). Printable bytes and UTF-8 continuation bytes (≥ 0x80) pass through.
    /// Every tab paints row content through here, so frame integrity is enforced
    /// in this one choke point rather than trusted to each renderer.
    pub fn putContent(self: *Frame, bytes: []const u8) void {
        for (bytes) |b| switch (b) {
            '\t' => self.put(" "), // tab: collapse to one column
            0x00...0x08, 0x0a...0x1f, 0x7f => {}, // C0 controls (incl. ESC), CR/LF, DEL: drop
            else => self.put(&[_]u8{b}),
        };
    }
};

/// Paint `rows` into `rect`: clamp the view to the height, take the visible
/// window, position each row and paint it through `putContent`. The single
/// place row content reaches the frame — so the control-byte defense lives here once.
pub fn paintRows(f: *Frame, rows: []const []const u8, view: scroll_list.View, rect: Rect) void {
    const v = scroll_list.clamp(view, rows.len, rect.height);
    const win = scroll_list.visible(rows, v, rect.height);
    for (win, 0..) |row, i| {
        f.moveTo(rect.row + @as(u16, @intCast(i)), rect.col);
        f.putContent(scroll_list.truncate(row, rect.width));
    }
}

/// A multi-select row checkbox: unselected, selected, or blocked (a row that
/// can't be selected — pinned in Outdated, already-installed in Search).
pub const Check = enum { off, on, blocked };

/// Paint a selection checkbox at the cursor — the shared widget so Outdated and
/// Search read identically. The selected check carries its own success colour
/// via `put` (outside the `putContent` row sanitization). Always four cells
/// (`[x] `), so callers budget the rest of the row with `width -| 4`.
pub fn putCheckbox(f: *Frame, state: Check) void {
    switch (state) {
        .on => {
            f.put("[");
            f.put(color.roleCode(.success));
            f.put("✓");
            f.put(color.Style.reset.code());
            f.put("] ");
        },
        .off => f.put("[ ] "),
        .blocked => {
            f.put(color.roleCode(.muted));
            f.put("[-] ");
            f.put(color.Style.reset.code());
        },
    }
}

/// A full-width horizontal rule across `rect` at `row` — the shared `<hr>` of
/// the dashboard. `dimmed` muted-styles it (the band, detail pane, and chrome
/// separator) or leaves it in the terminal default (the footer divider), so
/// every rule is drawn by this one helper.
pub fn renderSeparator(f: *Frame, rect: Rect, row: u16, dimmed: bool) void {
    f.moveTo(row, rect.col);
    if (dimmed) f.put(color.roleCode(.muted));
    var i: u16 = 0;
    while (i < rect.width) : (i += 1) f.put("─");
    if (dimmed) f.put(color.Style.reset.code());
}

/// One column in a list heading: its `label`, the `width` it pads to (matching
/// the row's `appendPad`), and the `gap` of blank cells before it — 1 for a
/// normal column, 2 where the row uses a two-cell separator like `→ `. The first
/// column's gap is unused; the checkbox/dot prefix is the heading's `indent`.
pub const HeadingCol = struct { label: []const u8, width: u16, gap: u16 = 1 };

/// Paint a bold column heading at the top of `rect`: `indent` leading blanks for
/// a checkbox/dot prefix, then each column left-justified to its width and
/// preceded by its gap, so labels sit over `appendPad`-formatted values. The one
/// heading painter every list tab shares; width-truncated and reset like a row.
pub fn renderHeading(f: *Frame, rect: Rect, indent: u16, cols: []const HeadingCol) void {
    var b: [128]u8 = undefined;
    var hf: Frame = .{ .buf = &b };
    blanks(&hf, indent);
    for (cols, 0..) |c, i| {
        if (i != 0) blanks(&hf, c.gap);
        hf.put(c.label);
        if (c.label.len < c.width) blanks(&hf, c.width - @as(u16, @intCast(c.label.len)));
    }
    f.moveTo(rect.row, rect.col);
    f.put(color.Style.bold.code());
    f.putContent(scroll_list.truncate(hf.slice(), rect.width));
    f.put(color.Style.reset.code());
}

fn blanks(f: *Frame, n: u16) void {
    var i: u16 = 0;
    while (i < n) : (i += 1) f.put(" ");
}

/// Paint one dim line at the top of `rect` — the shared empty-state / "no
/// matches" placeholder so every tab's empty list reads the same way instead of
/// a blank pane. Content goes through `putContent` like every other row.
pub fn renderHint(f: *Frame, rect: Rect, msg: []const u8) void {
    if (rect.height == 0) return;
    f.moveTo(rect.row, rect.col);
    f.put(color.roleCode(.muted));
    f.putContent(scroll_list.truncate(msg, rect.width));
    f.put(color.Style.reset.code());
}

/// Comptime contract check: a conforming tab module exposes `State` (with a
/// `chrome: Chrome` field), `title`, `step`, and `render`. Called on each tab so
/// a missing or mis-typed piece fails the build, not the dashboard at runtime.
pub fn verify(comptime M: type) void {
    if (!@hasDecl(M, "State")) @compileError(@typeName(M) ++ ": tab must expose `pub const State`");
    if (!@hasField(M.State, "chrome")) @compileError(@typeName(M) ++ ".State must embed a `chrome` field");
    if (@FieldType(M.State, "chrome") != Chrome) @compileError(@typeName(M) ++ ".State.chrome must be tab.Chrome");
    for ([_][]const u8{ "title", "footerHint", "step", "render" }) |decl| {
        if (!@hasDecl(M, decl)) @compileError(@typeName(M) ++ ": tab must expose `pub fn " ++ decl ++ "`");
    }
}

// ─── tests ───────────────────────────────────────────────────────────

const GoodTab = struct {
    pub const State = struct { chrome: Chrome = .{} };
    pub fn title() []const u8 {
        return "Good";
    }
    pub fn footerHint() []const u8 {
        return "g: go";
    }
    pub fn step(s: *State, key: Key) void {
        _ = s;
        _ = key;
    }
    pub fn render(s: *const State, f: *Frame, r: Rect) void {
        _ = s;
        _ = f;
        _ = r;
    }
};

test "verify accepts a conforming tab module" {
    comptime verify(GoodTab);
}

test "putCheckbox renders each selection state with the right glyph" {
    const cases = [_]struct { state: Check, want: []const u8, absent: []const u8 }{
        .{ .state = .off, .want = "[ ] ", .absent = "✓" },
        .{ .state = .on, .want = "✓", .absent = "[-]" },
        .{ .state = .blocked, .want = "[-] ", .absent = "✓" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var f: Frame = .{ .buf = &buf };
        putCheckbox(&f, c.state);
        try std.testing.expect(std.mem.indexOf(u8, f.slice(), c.want) != null);
        try std.testing.expect(std.mem.indexOf(u8, f.slice(), c.absent) == null);
    }
}

test "putCheckbox colours only the selected check, leaving the brackets plain" {
    var buf: [64]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    putCheckbox(&f, .on);
    // A reset follows the check so the row content after it isn't tinted green.
    try std.testing.expect(std.mem.indexOf(u8, f.slice(), color.Style.reset.code()) != null);
}

test "renderHint paints the placeholder text into the frame" {
    var buf: [128]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    renderHint(&f, .{ .row = 2, .col = 1, .width = 40, .height = 6 }, "Nothing here.");
    try std.testing.expect(std.mem.indexOf(u8, f.slice(), "Nothing here.") != null);
}

test "renderSeparator paints a full-width rule, dim only when asked" {
    var buf: [256]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    renderSeparator(&f, .{ .row = 5, .col = 1, .width = 4, .height = 1 }, 5, true);
    const dim = f.slice();
    try std.testing.expect(std.mem.indexOf(u8, dim, color.roleCode(.muted)) != null);
    try std.testing.expect(std.mem.indexOf(u8, dim, "────") != null); // width box-drawing cells
    try std.testing.expect(std.mem.indexOf(u8, dim, color.Style.reset.code()) != null);

    // Undimmed: the bare rule, terminal default — no muted SGR, no reset.
    var pbuf: [256]u8 = undefined;
    var pf: Frame = .{ .buf = &pbuf };
    renderSeparator(&pf, .{ .row = 1, .col = 1, .width = 4, .height = 1 }, 1, false);
    const plain = pf.slice();
    try std.testing.expect(std.mem.indexOf(u8, plain, "────") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, color.roleCode(.muted)) == null);
}

test "renderHeading lays bold columns with an indent and per-column gaps" {
    var buf: [256]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    renderHeading(&f, .{ .row = 1, .col = 1, .width = 80, .height = 1 }, 2, &.{
        .{ .label = "A", .width = 4 },
        .{ .label = "B", .width = 4, .gap = 2 },
    });
    const out = f.slice();
    try std.testing.expect(std.mem.indexOf(u8, out, color.Style.bold.code()) != null);
    // 2-space indent, A padded to width 4, then a 2-cell gap before B.
    try std.testing.expect(std.mem.indexOf(u8, out, "  A" ++ " " ** 5 ++ "B") != null);
}

test "renderHeading truncates to the rect width and still closes the bold" {
    var buf: [512]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    // Width 6 is narrower than the heading: it must cut cleanly, never overflow.
    renderHeading(&f, .{ .row = 1, .col = 1, .width = 6, .height = 1 }, 2, &.{
        .{ .label = "NAME", .width = 22 },
        .{ .label = "VERSION", .width = 14 },
    });
    const out = f.slice();
    try std.testing.expect(std.mem.indexOf(u8, out, "VERSION") == null); // cut past the width
    try std.testing.expect(std.mem.indexOf(u8, out, color.Style.reset.code()) != null); // bold still closed
}

test "renderHint on a zero-height rect is a clean no-op" {
    var buf: [64]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    renderHint(&f, .{ .row = 1, .col = 1, .width = 40, .height = 0 }, "x"); // must not trap
    try std.testing.expectEqual(@as(usize, 0), f.slice().len);
}

test "Frame.put is bounded and never overflows the buffer" {
    var buf: [4]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    f.put("abcdef"); // longer than the buffer
    try std.testing.expectEqualStrings("abcd", f.slice());
}

test "Frame.moveTo emits a 1-based CUP sequence" {
    var buf: [32]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    f.moveTo(3, 5);
    try std.testing.expectEqualStrings("\x1b[3;5H", f.slice());
}

test "Frame.putContent strips line breakers and turns tab into a space" {
    var buf: [32]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    f.putContent("a\nb\tc\rd\x0b\x0ce"); // LF, TAB, CR, VT, FF
    try std.testing.expectEqualStrings("ab cde", f.slice());
}

test "putContent drops an ESC so a child row cannot re-drive the cursor or set color" {
    var buf: [32]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    f.putContent("\x1b[1mX\x1b[0m"); // an SGR a hostile package name might carry
    try std.testing.expectEqualStrings("[1mX[0m", f.slice()); // ESC bytes gone; the remnant is inert text
    try std.testing.expect(std.mem.indexOfScalar(u8, f.slice(), 0x1b) == null);
}

test "putContent strips the control introducers from a hostile row (OSC + BEL + erase)" {
    var buf: [64]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    // An OSC title-set, a BEL, and an erase-display a hostile child name might carry.
    f.putContent("x\x1b]0;pwn\x07y\x1b[2J");
    const out = f.slice();
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) == null); // no ESC → no CSI/OSC executes
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null); // BEL dropped
    try std.testing.expect(std.mem.indexOf(u8, out, "x") != null and std.mem.indexOf(u8, out, "y") != null);
}

test "paintRows positions each row and a row's embedded newline never injects a frame line" {
    var buf: [128]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    const rows = [_][]const u8{ "x\ny", "z" };
    paintRows(&f, &rows, .{}, .{ .row = 1, .col = 1, .width = 10, .height = 2 });
    // A frame positions with cursor moves and carries no raw newline.
    try std.testing.expect(std.mem.indexOfScalar(u8, f.slice(), '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, f.slice(), "xy") != null); // the \n was stripped
    try std.testing.expect(std.mem.indexOf(u8, f.slice(), "z") != null);
}
