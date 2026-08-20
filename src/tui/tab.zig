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
const cmd = @import("cmd.zig");
const ctx = @import("ctx.zig");
const scroll_list = @import("scroll_list.zig");
const layout = @import("layout.zig");
const filter_input = @import("filter_input.zig");
const keys = @import("keys.zig");
const term = @import("term.zig");
const term_sanitize = @import("../ui/term_sanitize.zig");

pub const Key = keys.Key;
pub const Rect = layout.Rect;

/// Cross-cutting per-tab state the shell owns the logic for (filter editing,
/// list navigation). Every tab `State` embeds one so the shell touches it
/// uniformly while the tab still owns its whole struct.
pub const Chrome = struct {
    filter: filter_input.Filter = .{},
    view: scroll_list.View = .{},
};

/// A background tab's `--json` audit descriptor, declared beside the tab instead
/// of hand-switched in the shell: the `mt` subcommand `verb`, the exit tolerance
/// (Doctor exits by severity while still emitting findings, so it tolerates ≤2
/// where the others require a clean 0), and the `refresh_op` banner wording a
/// failed refresh shows. `null` for a tab that does not background-fetch.
pub const FetchSpec = struct {
    verb: []const []const u8,
    max_ok_exit: u8,
    refresh_op: []const u8,
    /// The tab's own parser, wrapped as a `cmd.ParseFn`. The tab already imports
    /// its `json/*` module for `render`, so it names it here too — this is how a
    /// background `read` `Cmd` carries the parser the interpreter calls, keeping the
    /// interpreter free of any tab/parser import.
    parse: cmd.ParseFn,
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

    /// Position the cursor, then erase to end of line — a self-erasing line for
    /// single-write rows that own their line from `col` rightward. The erase is a
    /// raw `put` on purpose: `putContent` strips ESC, so a row can never emit its
    /// own erase. Rows that paint several segments across one line (the header,
    /// the detail pane's indented continuations) must keep `moveTo` — a mid-row
    /// erase here would wipe an earlier segment.
    pub fn moveClear(self: *Frame, row: u16, col: u16) void {
        self.moveTo(row, col);
        self.put(term.seq.erase_line);
    }

    /// Paint untrusted row content as inert text: TAB becomes a space and every
    /// control byte is dropped, so a child-derived row can neither re-drive the
    /// cursor (ESC/CSI), set the window title (OSC), inject an extra frame line
    /// (LF/CR/VT/FF), nor disturb column alignment (TAB). Only well-formed UTF-8
    /// passes: a lone 0x9B/0x9D is an 8-bit CSI/OSC that needs no ESC, and only
    /// the pending-sequence state tells it from a continuation byte — so
    /// `term_sanitize.passableByte` owns that rule for both choke points.
    /// Every tab paints row content through here, so frame integrity is enforced
    /// in this one place rather than trusted to each renderer.
    pub fn putContent(self: *Frame, bytes: []const u8) void {
        // Per call, not a Frame field: a codepoint never spans two calls, so a
        // reused Frame cannot inherit a half-armed sequence from the last frame.
        var st: term_sanitize.Utf8State = .{};
        for (bytes) |b| {
            if (!term_sanitize.passableByte(b, &st)) continue;
            switch (b) {
                '\t' => self.put(" "), // tab: collapse to one column
                '\n' => {}, // passable for the stream caller; a row must not break the line
                else => self.put(&[_]u8{b}),
            }
        }
    }
};

/// Paint `rows` into `rect`: clamp the view to the height, take the visible
/// window, position-and-erase each row (`moveClear`) then paint it through
/// `putContent` — so a shorter repaint drops the previous row's tail. The single
/// place row content reaches the frame — so the control-byte defense lives here once.
pub fn paintRows(f: *Frame, rows: []const []const u8, view: scroll_list.View, rect: Rect) void {
    const v = scroll_list.clamp(view, rows.len, rect.height);
    const win = scroll_list.visible(rows, v, rect.height);
    for (win, 0..) |row, i| {
        f.moveClear(rect.row + @as(u16, @intCast(i)), rect.col);
        f.putContent(scroll_list.truncate(row, rect.width));
    }
    blankRemainder(f, rect, @intCast(win.len));
}

/// Blank every row of `rect` the caller left unpainted — from `painted` rows
/// down to the bottom edge — each self-erased via `moveClear`. So a region that
/// shrank between frames covers its whole rectangle and no stale row can survive
/// once the whole-screen clear is gone. `painted` is `visible`-clamped to the
/// height, so a full region blanks nothing. Shared: the per-tab list loops call
/// this after their own paint to close the same variable-height gap.
pub fn blankRemainder(f: *Frame, rect: Rect, painted: u16) void {
    var i = painted;
    while (i < rect.height) : (i += 1) f.moveClear(rect.row + i, rect.col);
}

/// Where a click landed: the list `index` it maps to, and whether that row has a
/// detail pane worth opening (`open`). The result type of the tab contract's
/// **optional** `hitTest(s, rect, click_row, click_col) ?Hit` decl. Optional
/// because only tabs with a clickable list implement it — the shell gates the
/// call on `@hasDecl`, so Doctor/Services/Outdated carry neither the method nor a
/// dead arm, and `verify` never requires it.
pub const Hit = struct { index: usize, open: bool };

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
    for ([_][]const u8{ "title", "footerHint", "step", "render", "update" }) |decl| {
        if (!@hasDecl(M, decl)) @compileError(@typeName(M) ++ ": tab must expose `pub fn " ++ decl ++ "`");
    }
    // A tab declares its background-fetch capability as data, read generically by
    // the shell; `null` for a synchronous tab. Total coverage, no runtime switch.
    if (!@hasDecl(M, "fetch_spec")) @compileError(@typeName(M) ++ ": tab must expose `pub const fetch_spec: ?FetchSpec`");
    if (@TypeOf(M.fetch_spec) != ?FetchSpec) @compileError(@typeName(M) ++ ".fetch_spec must be `?FetchSpec`");
    // `step`/`update` are the Elm effect seam: they return a `cmd.Cmd` and own the
    // tab's parse storage, so a conforming tab must expose one — reported here.
    if (!@hasDecl(M, "Storage")) @compileError(@typeName(M) ++ ": tab must expose `pub const Storage`");
    // `hitTest(s, rect, click_row, click_col) ?Hit` is an OPTIONAL contract decl:
    // only tabs with a clickable list expose it, and the shell gates the call on
    // `@hasDecl`. Deliberately not required here, so a tab with no detail pane
    // carries no dead arm.
}

// ─── tests ───────────────────────────────────────────────────────────

const GoodTab = struct {
    pub const State = struct { chrome: Chrome = .{} };
    pub const Storage = struct {
        pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
    pub const fetch_spec: ?FetchSpec = null;
    pub fn title() []const u8 {
        return "Good";
    }
    pub fn footerHint() []const u8 {
        return "g: go";
    }
    pub fn step(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, key: Key) cmd.Cmd {
        _ = allocator;
        _ = mt_path;
        _ = s;
        _ = storage;
        _ = key;
        return .none;
    }
    pub fn update(allocator: std.mem.Allocator, mt_path: []const u8, s: *State, storage: *Storage, shared: *ctx.SharedModel, msg: cmd.Msg) cmd.Cmd {
        _ = allocator;
        _ = mt_path;
        _ = s;
        _ = storage;
        _ = shared;
        _ = msg;
        return .none;
    }
    pub fn render(s: *const State, f: *Frame, r: Rect) void {
        _ = s;
        _ = f;
        _ = r;
    }
};

test "verify accepts a conforming tab module exposing step/update/Storage" {
    // The effect seam is checked here: a tab missing `update` or `Storage`, or with
    // the wrong `State.chrome` type, would not compile — the comptime guard the
    // migrated tabs rely on.
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

test "Frame.moveClear positions then erases to end of line" {
    var buf: [32]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    f.moveClear(3, 5);
    // CUP followed by a raw erase-to-EOL: the mechanism that lets a shorter
    // repaint drop the previous row's tail once the whole-screen clear is gone.
    try std.testing.expectEqualStrings("\x1b[3;5H\x1b[K", f.slice());
}

test "Frame.putContent strips line breakers and DEL, and turns tab into a space" {
    var buf: [32]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    f.putContent("a\nb\tc\rd\x0b\x0ce\x7f"); // LF, TAB, CR, VT, FF, DEL
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

test "putContent drops a lone 8-bit C1 introducer from row content" {
    var buf: [64]u8 = undefined;
    // A lone 0x9B/0x9D/0x9C is an 8-bit CSI/OSC/ST: no ESC, yet a terminal that
    // honours C1 controls executes it on the cursor moveClear just positioned.
    for ([_][]const u8{
        "\x9b31mX",
        "a\x9d0;pwn\x9c",
        "\xc0\xaf", // overlong: C0 is never a legal lead
        "\x80", // lone continuation byte
        "\xf5\x9b\x9d", // invalid lead: a length classifier would arm 3 bytes here
    }) |bad| {
        var f: Frame = .{ .buf = &buf };
        f.putContent(bad);
        for (f.slice()) |b| try std.testing.expect(b < 0x80 or b > 0x9F);
    }
}

test "putContent passes well-formed UTF-8 through byte-identically" {
    var buf: [64]u8 = undefined;
    // U+065B's own continuation byte is 0x9B, and app.zig paints a 4-byte
    // U+1D7F6: the filter must be UTF-8-aware, not a blanket C1 drop.
    for ([_][]const u8{ "caf\u{00e9} \u{2014} \u{1d7f6}", "\u{065b}", "\u{d6c0}" }) |ok| {
        var f: Frame = .{ .buf = &buf };
        f.putContent(ok);
        try std.testing.expectEqualStrings(ok, f.slice());
    }
}

test "putContent state is per call, so a split rune cannot arm the next row" {
    var buf: [64]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    f.putContent("a\xe2\x80"); // a rune cut short by a narrow-width hard break
    f.putContent("\x94b"); // fresh state: the orphan tail is a lone continuation
    // The truncated prefix stays as the maximal subpart a decoder eats as one
    // error; what must not happen is the next row completing it.
    try std.testing.expectEqualStrings("a\xe2\x80b", f.slice());
}

test "paintRows self-erases every painted row so a shorter repaint drops no tail" {
    var buf: [128]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    const rows = [_][]const u8{ "a-long-previous-row", "short" };
    paintRows(&f, &rows, .{}, .{ .row = 1, .col = 1, .width = 20, .height = 2 });
    // One erase-to-EOL per positioned row: the byte that clears the stale tail
    // once the whole-screen clear is gone. (CUP carries no bare `\x1b[K`.)
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, f.slice(), "\x1b[K"));
}

test "paintRows emits the erase raw yet still scrubs an erase carried in row content" {
    var buf: [64]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    const rows = [_][]const u8{"\x1b[Kx"}; // a hostile row carrying its own erase
    paintRows(&f, &rows, .{}, .{ .row = 1, .col = 1, .width = 10, .height = 1 });
    // Exactly one erase — the structural one from moveClear. The row's own
    // `\x1b[K` lost its ESC to putContent, so it can never drive a second erase.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, f.slice(), "\x1b[K"));
    try std.testing.expect(std.mem.indexOf(u8, f.slice(), "[Kx") != null); // inert remnant
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

test "paintRows blanks the whole rectangle so a shrunk list leaves no ghost rows" {
    var buf: [256]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    // Two rows into a five-tall region: the three rows the list no longer fills
    // must each be blanked, so nothing survives once the whole-screen clear goes.
    const rows = [_][]const u8{ "a", "b" };
    paintRows(&f, &rows, .{}, .{ .row = 1, .col = 1, .width = 20, .height = 5 });
    const out = f.slice();
    // Five self-erasing rows total: two painted, three remainder.
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, out, "\x1b[K"));
    // The remainder rows are addressed and erased in place.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3;1H\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4;1H\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[5;1H\x1b[K") != null);
}

test "paintRows on a full-height list blanks no extra row past the rectangle bottom" {
    var buf: [256]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    // List exactly fills the region: no remainder, and nothing addresses row 4.
    const rows = [_][]const u8{ "a", "b", "c" };
    paintRows(&f, &rows, .{}, .{ .row = 1, .col = 1, .width = 20, .height = 3 });
    const out = f.slice();
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\x1b[K"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4;1H") == null); // no write past the bottom edge
}

test "paintRows on an empty list blanks every row of the rectangle" {
    var buf: [256]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    // A filtered list with no matches: nothing painted, so all four rows are blanked.
    paintRows(&f, &.{}, .{}, .{ .row = 1, .col = 1, .width = 20, .height = 4 });
    const out = f.slice();
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\x1b[K"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4;1H\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[5;1H") == null); // no write past the bottom edge
}

test "blankRemainder addresses the unpainted rows relative to the rect origin" {
    var buf: [128]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    // Region at row 10, col 3, one row painted: only rows 11 and 12 are blanked,
    // rect-relative — the painted row 10 is left alone and nothing runs past 12.
    blankRemainder(&f, .{ .row = 10, .col = 3, .width = 20, .height = 3 }, 1);
    const out = f.slice();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\x1b[K"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[11;3H\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[12;3H\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[10;3H") == null); // caller's painted row untouched
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[13;3H") == null); // nothing past the bottom
}

test "blankRemainder is a no-op when the caller already filled the rectangle" {
    var buf: [64]u8 = undefined;
    var f: Frame = .{ .buf = &buf };
    // painted >= height: the `i < height` bound yields no rows, so nothing is emitted.
    blankRemainder(&f, .{ .row = 1, .col = 1, .width = 20, .height = 3 }, 3);
    try std.testing.expectEqual(@as(usize, 0), f.slice().len);
}
