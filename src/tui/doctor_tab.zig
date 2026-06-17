//! malt — Doctor tab for `mt tui`: the health-check pane.
//!
//! Leaf module. Pure cores only: `step(state, key)` records a fix intent as a
//! `request` for the impure shell to delegate to the real `mt doctor --fix
//! <class>`; `render(state, frame, rect)` is a pure function of `(state, rect)`
//! so a resize is a re-render. The shell owns the finding data; `items` borrow
//! from that storage. Findings are shown severity-first (errors, then warnings,
//! then ok) for scan-ability, each with a local `✓`/`⚠`/`✗` glyph — the mapping
//! is **replicated** here, never imported from `cli/doctor/render.zig` (the leaf
//! rule). `f` fixes the selected finding, but **only** when it is `fixable`; the
//! token sent is its `fix_class`, the only thing `mt doctor --fix` resolves.

const std = @import("std");
const testing = std.testing;

const color = @import("../ui/color.zig");
const doctor_json = @import("json/doctor.zig");
pub const Row = doctor_json.Finding;
const Severity = doctor_json.Severity;
const detail_pane = @import("detail_pane.zig");
const scroll_list = @import("scroll_list.zig");
const tab = @import("tab.zig");

/// A fix effect the pure `step` defers to the impure shell, which performs it and
/// resets the field. `step` never does I/O — this is the command channel.
pub const Request = enum { none, fix };

pub const State = struct {
    chrome: tab.Chrome = .{},
    /// Findings, borrowed from shell-owned parse storage.
    items: []const Row = &.{},
    /// Reclaimable disk/tap totals, copied from the parse by the shell. Plain
    /// scalars (T-003's `Stats`), defaulted to zero so a tab built without a
    /// parse — or against an older `mt` — simply shows no reclaimable line.
    stats: doctor_json.Stats = .{},
    /// Pending fix effect for the shell to perform, then clear.
    request: Request = .none,
};

pub fn title() []const u8 {
    return "Doctor";
}

/// The tab's action keys, surfaced in the shared footer next to the global keys.
pub fn footerHint() []const u8 {
    return "f: fix";
}

/// Case-insensitive substring match of `filter` against a finding `title`. An
/// empty filter matches everything.
pub fn matches(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.ascii.indexOfIgnoreCase(name, filter) != null;
}

/// Display order: errors first, then warnings, then ok — the scan-ability sort.
/// Both the selection mapping and the renderer walk findings in this order so a
/// cursor lands on exactly the row painted at that screen position.
const severity_order = [_]Severity{ .err, .warn, .ok };

fn filteredCount(items: []const Row, filter: []const u8) usize {
    var n: usize = 0;
    for (items) |fnd| {
        if (matches(fnd.title, filter)) n += 1;
    }
    return n;
}

/// The `n`-th finding in filtered, severity-ordered display order, or null when
/// `n` is past the end. The single source of the display order, shared by the
/// selection and the renderer.
fn orderedNth(items: []const Row, filter: []const u8, n: usize) ?Row {
    var i: usize = 0;
    for (severity_order) |sev| {
        for (items) |fnd| {
            if (fnd.severity != sev) continue;
            if (!matches(fnd.title, filter)) continue;
            if (i == n) return fnd;
            i += 1;
        }
    }
    return null;
}

/// The finding the selection points at, after applying the filter and clamping
/// the (shell-driven, unbounded) selection into the filtered, severity-ordered
/// list. The shell reads its `fix_class` to build `mt doctor --fix <class>`.
pub fn selectedFinding(s: *const State) ?Row {
    const filter = s.chrome.filter.slice();
    const nf = filteredCount(s.items, filter);
    if (nf == 0) return null;
    const sel = @min(s.chrome.view.selected, nf - 1);
    return orderedNth(s.items, filter, sel);
}

/// Pure transition: `f` records a fix intent for the shell — but only when the
/// selected finding is `fixable`. A non-fixable finding's `f` is inert.
pub fn step(s: *State, key: tab.Key) void {
    switch (key) {
        .char => |c| if (c.len == 1 and c.bytes[0] == 'f') {
            const sel = selectedFinding(s) orelse return;
            if (sel.fixable) s.request = .fix;
        },
        else => {},
    }
}

/// Local severity → glyph mapping, replicated from the CLI doctor renderer (the
/// leaf rule forbids importing it). Exhaustive `switch`, no `else`, so a new
/// `Severity` is a compile error here.
fn glyph(sev: Severity) []const u8 {
    return switch (sev) {
        .ok => "✓",
        .warn => "⚠",
        .err => "✗",
    };
}

fn glyphStyle(sev: Severity) color.Role {
    return switch (sev) {
        .ok => .success,
        .warn => .warning,
        .err => .danger,
    };
}

fn severityLabel(sev: Severity) []const u8 {
    return switch (sev) {
        .ok => "ok",
        .warn => "warning",
        .err => "error",
    };
}

/// Byte formatter replicated from the CLI's `formatBytes` (the leaf rule forbids
/// importing `cli/*`) so a reclaimable figure reads identically across
/// `mt doctor` / `mt purge` and the TUI: same units, same 1024 step, same
/// one-decimal shape. Pinned to that shape by a boundary test.
fn humanBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

// ─── health band ─────────────────────────────────────────────────────

/// Per-severity tallies for the health band, plus the count of fixable findings
/// among the attention set (err+warn). Computed once and passed to the band.
const Counts = struct {
    err: usize = 0,
    warn: usize = 0,
    ok: usize = 0,
    /// Fixable findings within err+warn — `ok` findings are never "fixable" work.
    fixable: usize = 0,

    fn total(self: Counts) usize {
        return self.err + self.warn + self.ok;
    }
    fn attention(self: Counts) usize {
        return self.err + self.warn;
    }
};

/// One pass over the filtered findings, mirroring the list's filter so the band
/// and list always describe the same set.
fn tally(items: []const Row, filter: []const u8) Counts {
    var c: Counts = .{};
    for (items) |fnd| {
        if (!matches(fnd.title, filter)) continue;
        switch (fnd.severity) {
            .err => c.err += 1,
            .warn => c.warn += 1,
            .ok => c.ok += 1,
        }
        if (fnd.severity != .ok and fnd.fixable) c.fixable += 1;
    }
    return c;
}

/// The worst severity present — the verdict the banner reports.
fn worst(c: Counts) Severity {
    if (c.err > 0) return .err;
    if (c.warn > 0) return .warn;
    return .ok;
}

fn verdictLabel(sev: Severity) []const u8 {
    return switch (sev) {
        .err => "unhealthy",
        .warn => "needs attention",
        .ok => "healthy",
    };
}

/// Rows the band occupies at full size: a dim rule, the three segments, a dim
/// rule. The enclosing rules set it apart from the list above and below.
const band_full_height: u16 = 5;
/// Smallest enclosed band: top rule, banner, bottom rule.
const band_min_height: u16 = 3;

/// Band rows to reserve from the top of `content`. The findings list is the
/// floor, so the band never claims the last row; below the enclosed minimum
/// (plus that one list row) it drops entirely.
fn bandCap(content_height: u16, full: u16) u16 {
    if (content_height < band_min_height + 1) return 0; // no room to enclose + a list row
    return @min(full, content_height -| 1);
}

/// Build the colored status banner (`✗ unhealthy` / `⚠ needs attention` /
/// `✓ healthy`) into `lb`; the worst severity drives both glyph and colour.
fn buildBanner(lb: *tab.Frame, c: Counts) void {
    const sev = worst(c);
    lb.put(color.roleCode(glyphStyle(sev)));
    lb.put(glyph(sev));
    lb.put(" ");
    lb.put(verdictLabel(sev));
    lb.put(color.Style.reset.code());
}

/// Bar cells for the largest bucket; smaller buckets scale proportionally.
const histogram_cells: usize = 6;

/// Block cells proportional to `count`/`max` over the cell budget; any nonzero
/// count keeps at least one cell so a small-but-present bucket stays visible.
fn barCells(count: usize, max: usize) usize {
    if (count == 0 or max == 0) return 0;
    const scaled = (count * histogram_cells + max - 1) / max; // ceil
    return @min(histogram_cells, @max(@as(usize, 1), scaled));
}

/// One severity's `glyph bars count` cell, glyph and bars in the severity colour.
fn buildBar(lb: *tab.Frame, sev: Severity, count: usize, max: usize) void {
    lb.put(color.roleCode(glyphStyle(sev)));
    lb.put(glyph(sev));
    lb.put(" ");
    var i: usize = 0;
    while (i < barCells(count, max)) : (i += 1) lb.put("█");
    lb.put(color.Style.reset.code());
    lb.put(" ");
    var nbuf: [16]u8 = undefined;
    lb.put(std.fmt.bufPrint(&nbuf, "{d}", .{count}) catch "");
}

/// Narrowest width that still fits the three scaled bars; below it the histogram
/// drops the bars for a plain `✗N ⚠N ✓N` count line that can't wrap into the list.
const histogram_min_width: u16 = 36;

/// Build the severity histogram into `lb`: `✗ N  ⚠ N  ✓ N` as bars scaled to the
/// largest count, or a plain count line when the pane is too narrow for bars.
fn buildHistogram(lb: *tab.Frame, c: Counts, width: u16) void {
    if (width < histogram_min_width) return buildPlainCounts(lb, c);
    const max = @max(c.err, @max(c.warn, c.ok));
    buildBar(lb, .err, c.err, max);
    lb.put("  ");
    buildBar(lb, .warn, c.warn, max);
    lb.put("  ");
    buildBar(lb, .ok, c.ok, max);
}

/// One severity's `glyphN` cell with the glyph in its colour, for the narrow
/// fallback line.
fn buildPlainCount(lb: *tab.Frame, sev: Severity, count: usize) void {
    lb.put(color.roleCode(glyphStyle(sev)));
    lb.put(glyph(sev));
    lb.put(color.Style.reset.code());
    var nbuf: [16]u8 = undefined;
    lb.put(std.fmt.bufPrint(&nbuf, "{d}", .{count}) catch "");
}

fn buildPlainCounts(lb: *tab.Frame, c: Counts) void {
    buildPlainCount(lb, .err, c.err);
    lb.put(" ");
    buildPlainCount(lb, .warn, c.warn);
    lb.put(" ");
    buildPlainCount(lb, .ok, c.ok);
}

/// Build the call-to-action into `lb`: how many findings needing attention are
/// auto-fixable vs left to manual work. Muted — it's guidance, not a verdict.
fn buildFixable(lb: *tab.Frame, c: Counts) void {
    const manual = c.attention() - c.fixable; // fixable ⊆ attention, so this can't underflow
    lb.put(color.roleCode(.muted));
    var nbuf: [48]u8 = undefined;
    lb.put(std.fmt.bufPrint(&nbuf, "{d} auto-fixable · {d} manual", .{ c.fixable, manual }) catch "");
    lb.put(color.Style.reset.code());
}

/// The reclaimable-disk advisory, lifted from `Stats`. Present only when there is
/// something to reclaim — a clean store gets `null` and no row, so the band never
/// nags about zero bytes.
const Reclaim = struct {
    cask_bytes: u64,
    tap_cache_bytes: u64,
    retained_versions: usize,
};

fn reclaimFrom(stats: doctor_json.Stats) ?Reclaim {
    // A clean store has nothing to reclaim; suppressing the row avoids nagging it.
    if (stats.cask_bytes == 0 and stats.tap_cache_bytes == 0) return null;
    return .{
        .cask_bytes = stats.cask_bytes,
        .tap_cache_bytes = stats.tap_cache_bytes,
        .retained_versions = stats.retained_versions,
    };
}

/// The advisory's plain text (no colour, no line breaks): each present figure
/// paired with what it is, then the inert `→ mt purge --cache` guidance (text,
/// not a key binding). A zero figure is dropped so a cask-only or cache-only
/// store reads cleanly. The band colours and wraps it.
fn reclaimText(rc: Reclaim, buf: []u8) []const u8 {
    var fb: tab.Frame = .{ .buf = buf };
    var bbuf: [16]u8 = undefined; // humanBytes scratch; reused after each put copies it
    fb.put("Reclaimable: ");
    var have_segment = false;
    if (rc.cask_bytes > 0) {
        fb.put(humanBytes(rc.cask_bytes, &bbuf));
        fb.put(" cask history");
        if (rc.retained_versions > 0) {
            var rb: [32]u8 = undefined;
            fb.put(std.fmt.bufPrint(&rb, " ({d} old versions)", .{rc.retained_versions}) catch "");
        }
        have_segment = true;
    }
    if (rc.tap_cache_bytes > 0) {
        if (have_segment) fb.put(" · ");
        fb.put(humanBytes(rc.tap_cache_bytes, &bbuf));
        fb.put(" tap cache");
    }
    fb.put(" → mt purge --cache");
    return fb.slice();
}

/// Longest prefix of `text` for one `width`-column row, broken at the last space
/// that fits — or a hard rune-boundary break for a word wider than the row.
/// Rune- and escape-aware via `scroll_list.truncate`, so a break never splits a
/// multibyte glyph (`→`, `·`); the advisory wraps cleanly instead of truncating.
fn wrapChunk(text: []const u8, width: u16) []const u8 {
    const hard = scroll_list.truncate(text, width);
    if (hard.len == text.len) return hard; // the rest fits on one row
    var i = hard.len;
    while (i > 0) : (i -= 1) if (text[i - 1] == ' ') return text[0..i]; // break on a word boundary
    return hard; // a single word wider than the row: hard break
}

fn trimLeadingSpaces(s: []const u8) []const u8 {
    var r = s;
    while (r.len > 0 and r[0] == ' ') r = r[1..];
    return r;
}

/// A ratio bar only reads as a comparison when there are two values to compare;
/// with a single figure the wrapped text already says it all.
fn reclaimHasBar(rc: Reclaim) bool {
    return rc.cask_bytes > 0 and rc.tap_cache_bytes > 0;
}

/// Cells in the reclaimable ratio bar — small, inline, just enough to read the
/// split at a glance.
const ratio_bar_cells: u16 = 10;

/// Paint a compact two-tone bar showing how the reclaimable bytes split between
/// cask history (accent) and the tap cache (secondary), so their relative sizes
/// read at a glance. Each side keeps at least one cell so a tiny-but-present
/// share stays visible. Single row, truncated — the caller gates on two figures.
fn paintRatioBar(f: *tab.Frame, rect: tab.Rect, row: u16, rc: Reclaim) void {
    // u128 so the sum and the cell-scaling can't overflow on a hostile payload's
    // near-u64-max byte counts; the result is at most `ratio_bar_cells`.
    const cells: u128 = ratio_bar_cells;
    const total: u128 = @as(u128, rc.cask_bytes) + rc.tap_cache_bytes; // both > 0 here
    const share: u128 = (@as(u128, rc.cask_bytes) * cells + total / 2) / total; // rounded
    const cask_cells: u16 = @intCast(@max(@as(u128, 1), @min(cells - 1, share)));
    const cache_cells: u16 = ratio_bar_cells - cask_cells;

    var lb_buf: [256]u8 = undefined;
    var lb: tab.Frame = .{ .buf = &lb_buf };
    lb.put(color.roleCode(.muted));
    lb.put("cask ");
    lb.put(color.roleCode(.accent));
    var i: u16 = 0;
    while (i < cask_cells) : (i += 1) lb.put("█");
    lb.put(color.roleCode(.muted));
    lb.put(" cache ");
    lb.put(color.roleCode(.secondary));
    i = 0;
    while (i < cache_cells) : (i += 1) lb.put("█");
    lb.put(color.Style.reset.code());
    paintBandLine(f, rect, row, lb.slice());
}

/// Rows the wrapped advisory needs at `width` (text rows plus the ratio bar when
/// present), so the band can reserve them up front (and grow past its base
/// height) before the list claims the rest.
fn reclaimRowCount(rc: Reclaim, width: u16) u16 {
    if (width == 0) return 0;
    var tbuf: [256]u8 = undefined;
    var rest = reclaimText(rc, &tbuf);
    var n: u16 = 0;
    while (rest.len > 0) {
        const chunk = wrapChunk(rest, width);
        rest = trimLeadingSpaces(rest[chunk.len..]);
        n += 1;
    }
    return n + @as(u16, @intFromBool(reclaimHasBar(rc)));
}

/// Paint the advisory wrapped across at most `max_rows` muted rows from
/// `start_row`, returning the rows used. Each row is recoloured so a wrapped
/// continuation stays muted. It never wraps into the list because the band only
/// paints within the rows it reserved.
fn paintReclaim(f: *tab.Frame, rect: tab.Rect, start_row: u16, rc: Reclaim, max_rows: u16) u16 {
    if (rect.width == 0) return 0;
    var tbuf: [256]u8 = undefined;
    var rest = reclaimText(rc, &tbuf);
    var n: u16 = 0;
    while (rest.len > 0 and n < max_rows) {
        f.moveTo(start_row + n, rect.col);
        f.put(color.roleCode(.muted));
        const chunk = wrapChunk(rest, rect.width);
        f.putContent(chunk);
        f.put(color.Style.reset.code());
        rest = trimLeadingSpaces(rest[chunk.len..]);
        n += 1;
    }
    // The ratio bar follows the text, so under height pressure it sheds before
    // the actionable command does.
    if (reclaimHasBar(rc) and n < max_rows) {
        paintRatioBar(f, rect, start_row + n, rc);
        n += 1;
    }
    return n;
}

/// Paint one pre-built band line, width-truncated so it can never wrap into the
/// list (its colour codes ride along whole; counts/glyphs are our own bytes).
fn paintBandLine(f: *tab.Frame, rect: tab.Rect, row: u16, line: []const u8) void {
    f.moveTo(row, rect.col);
    f.put(scroll_list.truncate(line, rect.width));
}

/// A dim full-width rule, like the detail pane's, setting the band off from the
/// list above and below it.
fn paintRule(f: *tab.Frame, rect: tab.Rect, row: u16) void {
    f.moveTo(row, rect.col);
    f.put(color.roleCode(.muted));
    var i: u16 = 0;
    while (i < rect.width) : (i += 1) f.put("─");
    f.put(color.Style.reset.code());
}

/// Paint the health band into `rect` and return the rows used. The band is
/// enclosed by a dim rule top and bottom; inside, the segments shed lowest-signal
/// first (histogram, then the fixable line) so a short pane keeps the verdict.
fn renderBand(f: *tab.Frame, counts: Counts, reclaim: ?Reclaim, rect: tab.Rect) u16 {
    if (rect.height < band_min_height) return 0; // can't enclose even the banner
    var buf: [256]u8 = undefined;
    var used: u16 = 0;

    paintRule(f, rect, rect.row + used);
    used += 1;

    var banner: tab.Frame = .{ .buf = &buf };
    buildBanner(&banner, counts);
    paintBandLine(f, rect, rect.row + used, banner.slice());
    used += 1;

    // Histogram needs a full-height band; it is the first severity segment shed.
    const show_hist = rect.height >= band_full_height;
    // The fixable call-to-action sheds after the histogram but before the verdict.
    const show_fixable = rect.height >= band_full_height - 1;
    if (show_hist) {
        var hist: tab.Frame = .{ .buf = &buf };
        buildHistogram(&hist, counts, rect.width);
        paintBandLine(f, rect, rect.row + used, hist.slice());
        used += 1;
    }
    if (show_fixable) {
        var fx: tab.Frame = .{ .buf = &buf };
        buildFixable(&fx, counts);
        paintBandLine(f, rect, rect.row + used, fx.slice());
        used += 1;
    }
    // The reclaimable advisory is lowest-signal: it fills whatever rows remain
    // between the segments above and the closing rule, wrapping across them. So
    // it grows the band when there's room and is the first to shed when there
    // isn't — it never wraps into the list, only into rows the band reserved.
    if (reclaim) |rc| {
        const base: u16 = 1 + @as(u16, @intFromBool(show_hist)) + @as(u16, @intFromBool(show_fixable));
        const capacity: u16 = (rect.height -| 2) -| base; // rows between the rules left for it
        if (capacity > 0) used += paintReclaim(f, rect, rect.row + used, rc, capacity);
    }

    paintRule(f, rect, rect.row + used);
    used += 1;

    return used;
}

/// Pure render: the severity-ordered finding list and a detail pane for the
/// selected finding. The `f: fix` key lives in the shared footer (the detail
/// pane still shows whether the selected finding is fixable). The pane sizes to
/// its (wrapped) content, capped at half the height so the list survives. A pure
/// function of `(state, rect)` so a resize is a re-render.
pub fn render(s: *const State, f: *tab.Frame, r: tab.Rect) void {
    if (r.height == 0) return;
    const filter = s.chrome.filter.slice();
    const counts = tally(s.items, filter);

    const reclaim = reclaimFrom(s.stats);

    var content: tab.Rect = r;
    // The band rides above the list: reserve its rows from the top before the
    // detail pane claims from the bottom, so the list gets height − band − detail.
    if (counts.total() > 0) {
        // A present advisory lets the band grow past full by however many rows it
        // wraps to at this width; bandCap still caps it so the list keeps a row.
        const adv_rows = if (reclaim) |rc| reclaimRowCount(rc, content.width) else 0;
        const full = band_full_height + adv_rows;
        const budget = bandCap(content.height, full);
        if (budget > 0) {
            const used = renderBand(f, counts, reclaim, .{ .row = content.row, .col = content.col, .width = content.width, .height = budget });
            content.row += used;
            content.height -= used;
        }
    }

    const sel = selectedFinding(s);
    if (sel) |fnd| {
        var fix_buf: [96]u8 = undefined;
        const fix_value = if (fnd.fixable)
            std.fmt.bufPrint(&fix_buf, "f → mt doctor --fix {s}", .{doctor_json.fixClassTag(fnd.fix_class)}) catch "f: fix"
        else
            "not auto-fixable";
        const fields = [_]detail_pane.Field{
            .{ .label = "Severity", .value = severityLabel(fnd.severity) },
            .{ .label = "Fix", .value = fix_value },
            .{ .label = "Detail", .value = if (fnd.detail.len != 0) fnd.detail else "-" },
        };
        const dh = @min(detail_pane.neededRows(&fields, content.width), content.height / 2);
        if (dh > 0 and dh < content.height) {
            content.height -= dh;
            detail_pane.render(f, &fields, .{ .row = content.row + content.height, .col = content.col, .width = content.width, .height = dh });
        }
    }
    renderList(s, f, counts, content);
}

/// All checks passed: one calm summary line instead of a list of ok rows, in the
/// success role. Reuses the band's severity counts (no second pass over `items`)
/// and its truncating painter, so it degrades on a narrow pane like the band does.
fn renderAllClear(f: *tab.Frame, rect: tab.Rect, counts: Counts) void {
    var buf: [96]u8 = undefined;
    var line: tab.Frame = .{ .buf = &buf };
    line.put(color.roleCode(.success));
    line.put(glyph(.ok));
    line.put(" ");
    var nbuf: [48]u8 = undefined;
    line.put(std.fmt.bufPrint(&nbuf, "All clear - {d} checks passed, nothing to fix.", .{counts.total()}) catch "");
    line.put(color.Style.reset.code());
    paintBandLine(f, rect, rect.row, line.slice());
}

fn renderList(s: *const State, f: *tab.Frame, counts: Counts, rect: tab.Rect) void {
    if (rect.height == 0) return;
    const filter = s.chrome.filter.slice();
    // No-data stays neutral: we can't claim "all clear" for checks we never received.
    if (counts.total() == 0) return tab.renderHint(f, rect, if (filter.len != 0) "No matches." else "No findings.");
    // Only without a filter: "N checks passed" must mean the whole run, and a
    // filter that matches only ok rows should still list them.
    if (filter.len == 0 and counts.attention() == 0) return renderAllClear(f, rect, counts);
    const v = scroll_list.clamp(s.chrome.view, counts.total(), rect.height);

    var di: usize = 0;
    for (severity_order) |sev| {
        for (s.items) |fnd| {
            if (fnd.severity != sev) continue;
            if (!matches(fnd.title, filter)) continue;
            defer di += 1;
            if (di < v.offset) continue;
            const screen = di - v.offset;
            if (screen >= rect.height) return; // viewport full
            f.moveTo(rect.row + @as(u16, @intCast(screen)), rect.col);
            // The glyph keeps its own colour regardless of selection; the
            // reverse-video selection wraps only the title so the SGRs don't tangle.
            f.put(color.roleCode(glyphStyle(fnd.severity)));
            f.put(glyph(fnd.severity));
            f.put(color.Style.reset.code());
            f.put(" ");
            const selected = di == v.selected;
            if (selected) { // the accent backgrounds the cursor row under a theme
                f.put(color.selectionAccent());
                f.put(color.Style.reverse.code());
            }
            f.putContent(scroll_list.truncate(fnd.title, rect.width -| 2)); // 2 cols spent on the glyph
            if (selected) f.put(color.Style.reset.code());
        }
    }
}

// ─── tests ───────────────────────────────────────────────────────────

fn ch(c: u8) tab.Key {
    return .{ .char = .{ .bytes = .{ c, 0, 0, 0 }, .len = 1 } };
}

const sample = [_]Row{
    .{ .id = "malt_prefix", .severity = .ok, .title = "MALT_PREFIX", .detail = "/opt/malt (default)", .fixable = false, .fix_class = .none },
    .{ .id = "orphaned_store_entries", .severity = .warn, .title = "Orphaned store entries", .detail = "3 orphaned entries", .fixable = true, .fix_class = .orphaned_store },
    .{ .id = "sqlite_integrity", .severity = .err, .title = "SQLite integrity", .detail = "database malformed", .fixable = false, .fix_class = .none },
    .{ .id = "stale_lock", .severity = .warn, .title = "Stale lock", .detail = "dead PID 42", .fixable = true, .fix_class = .stale_lock },
};

// Worst-severity-is-warn and all-ok stores, for the band's verdict cases.
const warn_only = [_]Row{
    .{ .id = "stale_lock", .severity = .warn, .title = "Stale lock", .detail = "dead PID 42", .fixable = true, .fix_class = .stale_lock },
    .{ .id = "malt_prefix", .severity = .ok, .title = "MALT_PREFIX", .detail = "/opt/malt", .fixable = false, .fix_class = .none },
};
const all_ok = [_]Row{
    .{ .id = "malt_prefix", .severity = .ok, .title = "MALT_PREFIX", .detail = "/opt/malt", .fixable = false, .fix_class = .none },
};

test "matches is a case-insensitive substring; empty filter matches all" {
    try testing.expect(matches("SQLite integrity", ""));
    try testing.expect(matches("SQLite integrity", "sqlite"));
    try testing.expect(!matches("Stale lock", "zzz"));
}

test "selectedFinding orders by severity (err, then warn, then ok) and clamps" {
    var s: State = .{ .items = &sample };
    // Display order: sqlite (err), orphaned (warn), stale_lock (warn), malt_prefix (ok).
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("sqlite_integrity", selectedFinding(&s).?.id);
    s.chrome.view.selected = 1;
    try testing.expectEqualStrings("orphaned_store_entries", selectedFinding(&s).?.id);
    s.chrome.view.selected = 3;
    try testing.expectEqualStrings("malt_prefix", selectedFinding(&s).?.id);
    s.chrome.view.selected = 99; // clamps to the last ordered row
    try testing.expectEqualStrings("malt_prefix", selectedFinding(&s).?.id);
}

test "selectedFinding keeps input order within a severity bucket (stable sort)" {
    var s: State = .{ .items = &sample };
    // The two warnings keep their input order: orphaned (idx 1) before stale_lock (idx 3).
    s.chrome.view.selected = 1;
    try testing.expectEqualStrings("orphaned_store_entries", selectedFinding(&s).?.id);
    s.chrome.view.selected = 2;
    try testing.expectEqualStrings("stale_lock", selectedFinding(&s).?.id);
}

test "selectedFinding maps the cursor through the filter" {
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("lock"); // only "Stale lock" matches
    s.chrome.view.selected = 0;
    try testing.expectEqualStrings("stale_lock", selectedFinding(&s).?.id);
}

test "selectedFinding on an empty list is null" {
    const s: State = .{ .items = &.{} };
    try testing.expect(selectedFinding(&s) == null);
}

test "f on a fixable finding requests a fix" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // orphaned_store_entries — fixable
    step(&s, ch('f'));
    try testing.expectEqual(Request.fix, s.request);
}

test "f on a non-fixable finding is inert" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0; // sqlite_integrity — not fixable
    step(&s, ch('f'));
    try testing.expectEqual(Request.none, s.request);
}

test "an unrelated key leaves the request alone" {
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1;
    step(&s, ch('z'));
    try testing.expectEqual(Request.none, s.request);
    step(&s, .enter);
    try testing.expectEqual(Request.none, s.request);
}

test "render lists findings with a severity glyph and title" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 2, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null);
    try testing.expect(std.mem.indexOf(u8, out, "✗") != null); // err glyph
    try testing.expect(std.mem.indexOf(u8, out, "⚠") != null); // warn glyph
    try testing.expect(std.mem.indexOf(u8, out, "✓") != null); // ok glyph
    try testing.expect(std.mem.indexOf(u8, out, color.Style.red.code()) != null);
    try testing.expect(std.mem.indexOf(u8, out, color.Style.yellow.code()) != null);
    try testing.expect(std.mem.indexOf(u8, out, color.Style.green.code()) != null);
}

test "render groups errors above ok findings for scan-ability" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    const err_at = std.mem.indexOf(u8, out, "SQLite integrity").?;
    const ok_at = std.mem.indexOf(u8, out, "MALT_PREFIX").?;
    try testing.expect(err_at < ok_at); // the err finding paints before the ok one
}

test "selecting a finding shows its detail" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // orphaned_store_entries
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "3 orphaned entries") != null);
}

test "a fixable selection spells out the delegated fix in the detail pane" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 1; // fixable
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    // The detail pane names the exact delegated command, with the class token;
    // the `f` key itself now lives in the shared footer, not the tab body.
    try testing.expect(std.mem.indexOf(u8, f.slice(), "mt doctor --fix orphaned_store") != null);
}

test "footerHint exposes the fix key for the shared footer" {
    try testing.expect(std.mem.indexOf(u8, footerHint(), "f: fix") != null);
}

test "a non-fixable selection shows guidance, not the f key" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0; // sqlite_integrity — not fixable
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "f: fix") == null); // no fix key
    try testing.expect(std.mem.indexOf(u8, out, "not auto-fixable") != null); // guidance
}

test "render highlights the selected row" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.view.selected = 0;
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), color.Style.reverse.code()) != null);
}

test "render narrows to the filter" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("lock");
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Stale lock") != null);
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") == null); // filtered out
}

test "render reflows: the same state at two widths differs" {
    var a: [8192]u8 = undefined;
    var b: [8192]u8 = undefined;
    var fa: tab.Frame = .{ .buf = &a };
    var fb: tab.Frame = .{ .buf = &b };
    const s: State = .{ .items = &sample };
    render(&s, &fa, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    render(&s, &fb, .{ .row = 1, .col = 1, .width = 30, .height = 6 });
    try testing.expect(!std.mem.eql(u8, fa.slice(), fb.slice()));
}

test "a hostile finding title cannot inject a control sequence into the frame" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const evil = [_]Row{.{ .id = "x", .severity = .err, .title = "ev\x1b]0;pwn\x07il", .detail = "d" }};
    const s: State = .{ .items = &evil };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]0;pwn") == null); // OSC introducer broken
    try testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null); // BEL dropped
}

test "render on an empty list shows the no-findings placeholder, not a blank pane" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &.{} };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 }); // must not trap
    const out = f.slice();
    try std.testing.expect(std.mem.indexOf(u8, out, "No findings") != null);
    // No-data is not a verdict: neither the "healthy" banner nor the all-clear
    // line may appear — we can't vouch for checks we never received.
    try std.testing.expect(std.mem.indexOf(u8, out, "healthy") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "All clear") == null);
}

test "render shows an all-clear summary when every check passed, not a per-check list" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &all_ok }; // 1 ok, 0 err, 0 warn
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "All clear") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 checks passed") != null); // names the passed count
    try testing.expect(std.mem.indexOf(u8, out, color.roleCode(.success)) != null); // success role
}

test "an active filter matching only ok findings lists them, never the all-clear summary" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("malt"); // matches only MALT_PREFIX (ok)
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "All clear") == null); // "N passed" can't mean the whole run under a filter
    try testing.expect(std.mem.indexOf(u8, out, "MALT_PREFIX") != null); // the matching ok row is still listed
}

test "the all-clear summary truncates on a narrow pane" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &all_ok };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 18, .height = 4 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "All clear") != null); // the verdict survives the cut
    try testing.expect(std.mem.indexOf(u8, out, "nothing to fix.") == null); // the tail is dropped, never wrapped
}

test "an active filter with no matches still shows No matches, never the all-clear line" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var s: State = .{ .items = &sample };
    s.chrome.filter.push("zzz"); // matches nothing
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 16 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "No matches.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "All clear") == null);
}

test "the all-clear summary renders at height 1 without crashing" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &all_ok };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 }); // band suppressed; the list is the floor
    try testing.expect(std.mem.indexOf(u8, f.slice(), "All clear") != null);
}

test "render clamps to a height of one without crashing" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 }); // no list rows fit
}

// ─── health band ─────────────────────────────────────────────────────

test "the band's status banner reads the worst severity present" {
    const cases = [_]struct { items: []const Row, verdict: []const u8 }{
        .{ .items = &sample, .verdict = "unhealthy" }, // an err is present
        .{ .items = &warn_only, .verdict = "needs attention" }, // warn is the worst
        .{ .items = &all_ok, .verdict = "healthy" }, // nothing wrong
    };
    for (cases) |c| {
        var buf: [4096]u8 = undefined;
        var f: tab.Frame = .{ .buf = &buf };
        const s: State = .{ .items = c.items };
        render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
        try testing.expect(std.mem.indexOf(u8, f.slice(), c.verdict) != null);
    }
}

test "the band histogram shows a scaled bar and count per severity" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample }; // 1 err, 2 warn, 1 ok
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "█") != null); // bars scaled to the largest count
    try testing.expect(std.mem.indexOf(u8, out, "2") != null); // the warn count (only the histogram carries it)
}

test "the band histogram degrades to a plain count line on a narrow pane" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 30, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "█") == null); // bars shed at narrow width
    try testing.expect(std.mem.indexOf(u8, out, "2") != null); // the warn count still reported
}

test "the band's fixable line splits auto-fixable from manual over the attention set" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // sample: err+warn = 3 needing attention; 2 of them fixable (orphaned, stale_lock).
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "2 auto-fixable") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 manual") != null);
}

test "on a height-1 rect only the findings list renders, never the band" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "unhealthy") == null); // band suppressed
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null); // a list row survives
}

test "a short pane sheds the histogram but keeps the verdict, CTA, and the list" {
    var buf: [2048]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 5 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "█") == null); // histogram shed first (lowest signal)
    try testing.expect(std.mem.indexOf(u8, out, "unhealthy") != null); // verdict survives (highest signal)
    try testing.expect(std.mem.indexOf(u8, out, "auto-fixable") != null); // actionable CTA survives
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null); // the list is the floor
}

test "the band is enclosed by a dim rule above and below" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    const top_rule = std.mem.indexOf(u8, out, "─") orelse return error.NoTopRule;
    const verdict = std.mem.indexOf(u8, out, "unhealthy").?;
    const bottom_rule = std.mem.indexOfPos(u8, out, verdict, "─") orelse return error.NoBottomRule;
    const first_title = std.mem.indexOf(u8, out, "SQLite integrity").?;
    try testing.expect(top_rule < verdict); // rule above the banner
    try testing.expect(verdict < bottom_rule); // rule below the band content
    try testing.expect(bottom_rule < first_title); // and the list follows the lower rule
}

test "the band needs room for its enclosure, else only the list renders" {
    var buf: [2048]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    // 3 rows can't hold the enclosed band (rule+banner+rule) plus a list row.
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 3 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "unhealthy") == null); // band dropped
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null); // list survives
}

test "the band paints above the findings list" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "unhealthy") != null); // banner present
    const verdict_at = std.mem.indexOf(u8, out, "unhealthy").?;
    const first_title_at = std.mem.indexOf(u8, out, "SQLite integrity").?;
    try testing.expect(verdict_at < first_title_at); // banner precedes the list
}

// ─── reclaimable advisory ─────────────────────────────────────────────

test "humanBytes matches the CLI's formatBytes shape at the unit boundaries" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0.0 B", humanBytes(0, &buf));
    try testing.expectEqualStrings("1023.0 B", humanBytes(1023, &buf));
    try testing.expectEqualStrings("1.0 KB", humanBytes(1024, &buf));
    try testing.expectEqualStrings("1.5 KB", humanBytes(1536, &buf));
    try testing.expectEqualStrings("1.0 MB", humanBytes(1024 * 1024, &buf));
    try testing.expectEqualStrings("1.0 GB", humanBytes(1024 * 1024 * 1024, &buf));
}

test "the reclaimable line names both figures, the retained count, and the purge guidance" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // 1.2 GB cask history over 4 retained versions · 88 MB tap cache.
    const s: State = .{ .items = &sample, .stats = .{
        .cask_bytes = 1288490189,
        .tap_cache_bytes = 88 * 1024 * 1024,
        .retained_versions = 4,
    } };
    // A wide pane so the full phrasing fits (≈88 cols); narrow collapse is its own test.
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.2 GB cask history") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(4 old versions)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "88.0 MB tap cache") != null);
    try testing.expect(std.mem.indexOf(u8, out, "→ mt purge --cache") != null);
    // The advisory rides in the band, above the findings list.
    const reclaim_at = std.mem.indexOf(u8, out, "Reclaimable:").?;
    const first_title_at = std.mem.indexOf(u8, out, "SQLite integrity").?;
    try testing.expect(reclaim_at < first_title_at);
}

test "the reclaimable advisory wraps across rows on a narrow pane rather than truncating its command" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{
        .cask_bytes = 1288490189,
        .tap_cache_bytes = 88 * 1024 * 1024,
        .retained_versions = 4,
    } };
    // 40 cols can't fit the ~88-col advisory on one line: a single truncated row
    // would drop the command, so its presence proves the line wrapped.
    render(&s, &f, .{ .row = 1, .col = 1, .width = 40, .height = 24 });
    const out = f.slice();
    // Head ("Reclaimable:") and tail ("--cache") both present: they cannot share a
    // single 40-col row in the ~88-col advisory, so the line must have wrapped.
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "purge") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--cache") != null);
    // The (now taller) band still leaves the findings list as the floor.
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null);
}

test "a cask-only store names the cask figure and omits the tap-cache segment" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .cask_bytes = 2048, .retained_versions = 2 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "2.0 KB cask history") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(2 old versions)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tap cache") == null); // nothing to reclaim there
}

test "a cache-only store names the tap-cache figure and omits the cask segment" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .tap_cache_bytes = 512 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "512.0 B tap cache") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cask history") == null);
    try testing.expect(std.mem.indexOf(u8, out, "→ mt purge --cache") != null);
}

test "zero reclaimable bytes suppress the advisory, and the all-clear state stays clean" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // all_ok with default (zero) stats: nothing to reclaim on a clean store.
    const s: State = .{ .items = &all_ok };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable:") == null); // no nagging row
    try testing.expect(std.mem.indexOf(u8, out, "All clear") != null); // all-clear reads cleanly
}

test "the band suppresses the advisory at height 1, leaving only the list" {
    var buf: [1024]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .cask_bytes = 2048, .retained_versions = 2 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 1 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable:") == null); // band dropped whole
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null); // a list row survives
}

test "with both figures present the band shows a two-tone reclaimable ratio bar" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .cask_bytes = 3 * 1024, .tap_cache_bytes = 1024 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 24 });
    const out = f.slice();
    // The ratio bar is the only band element painted in the secondary role.
    try testing.expect(std.mem.indexOf(u8, out, color.roleCode(.secondary)) != null);
    try testing.expect(std.mem.indexOf(u8, out, "█") != null);
}

test "the ratio bar survives pathologically large byte figures without overflowing" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // A garbage/hostile doctor payload could carry near-u64-max byte counts; the
    // share maths must not overflow when scaling them to the bar's cell budget.
    const s: State = .{ .items = &sample, .stats = .{
        .cask_bytes = std.math.maxInt(u64),
        .tap_cache_bytes = std.math.maxInt(u64) - 1,
    } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 24 }); // must not trap
    try testing.expect(std.mem.indexOf(u8, f.slice(), color.roleCode(.secondary)) != null);
}

test "a single reclaimable figure shows no ratio bar — there is nothing to compare" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &all_ok, .stats = .{ .cask_bytes = 2048, .retained_versions = 1 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    // Cask-only: no second value, so no bar → the secondary role appears nowhere.
    try testing.expect(std.mem.indexOf(u8, f.slice(), color.roleCode(.secondary)) == null);
}

test "the purge guidance is inert: f on a non-fixable selection stays a no-op with stats present" {
    var s: State = .{ .items = &sample, .stats = .{ .cask_bytes = 2048, .tap_cache_bytes = 512 } };
    s.chrome.view.selected = 0; // sqlite_integrity — not fixable
    step(&s, ch('f'));
    try testing.expectEqual(Request.none, s.request); // the advisory added no action
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}
