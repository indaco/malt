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

/// Doctor audits in the background; it exits by severity, so it tolerates ≤2.
pub const fetch_spec: ?tab.FetchSpec = .{ .verb = &.{"doctor"}, .max_ok_exit = 2, .refresh_op = "doctor refresh failed" };

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
const severity_order = [_]Severity{ .err, .warn, .info, .ok };

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
        // Only the tab knows its filtered row count, so the shell defers End here.
        .end => s.chrome.view.selected = filteredCount(s.items, s.chrome.filter.slice()) -| 1,
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
        .info => "ℹ",
    };
}

fn glyphStyle(sev: Severity) color.Role {
    return switch (sev) {
        .ok => .success,
        .warn => .warning,
        .err => .danger,
        // No dedicated info role; accent reads as a neutral highlight.
        .info => .accent,
    };
}

fn severityLabel(sev: Severity) []const u8 {
    return switch (sev) {
        .ok => "ok",
        .warn => "warning",
        .err => "error",
        .info => "in progress",
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
    /// In-progress (informational) findings — never actionable, never attention.
    info: usize = 0,
    ok: usize = 0,
    /// Fixable findings within err+warn — `ok`/`info` findings are never "fixable" work.
    fixable: usize = 0,

    fn total(self: Counts) usize {
        return self.err + self.warn + self.info + self.ok;
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
            .info => c.info += 1,
            .ok => c.ok += 1,
        }
        if ((fnd.severity == .err or fnd.severity == .warn) and fnd.fixable) c.fixable += 1;
    }
    return c;
}

/// The worst severity present — the verdict the banner reports.
fn worst(c: Counts) Severity {
    if (c.err > 0) return .err;
    if (c.warn > 0) return .warn;
    // In-progress outranks ok so the banner says "operation in progress"
    // rather than falsely "all checks passed" while a transient is shown.
    if (c.info > 0) return .info;
    return .ok;
}

fn verdictLabel(sev: Severity) []const u8 {
    return switch (sev) {
        // Worst severity only; `err` may sit over warnings too, so its label
        // covers both ("issues") while `warn` means warnings alone.
        .err => "issues found",
        .warn => "warnings found",
        .info => "operation in progress",
        .ok => "all checks passed",
    };
}

/// Rows the band occupies at full size, sans the reclaimable section: a dim rule,
/// the banner, the composition bar, the counts legend, the fixable line, a dim
/// rule. The enclosing rules set it apart from the list above and below.
const band_full_height: u16 = 6;
/// Smallest enclosed band: top rule, banner, bottom rule.
const band_min_height: u16 = 3;

/// Band rows to reserve from the top of `content`. The findings list is the
/// floor, so the band never claims the last row; below the enclosed minimum
/// (plus that one list row) it drops entirely.
fn bandCap(content_height: u16, full: u16) u16 {
    if (content_height < band_min_height + 1) return 0; // no room to enclose + a list row
    return @min(full, content_height -| 1);
}

/// Build the colored status banner (`✗ issues found` / `⚠ warnings found` /
/// `✓ all checks passed`) into `lb`; the worst severity drives both glyph and colour.
fn buildBanner(lb: *tab.Frame, c: Counts) void {
    const sev = worst(c);
    lb.put(color.roleCode(glyphStyle(sev)));
    lb.put(glyph(sev));
    lb.put(" ");
    lb.put(verdictLabel(sev));
    lb.put(color.Style.reset.code());
}

/// Cells per severity for a `bar`-wide stacked bar, summing to `bar`. Cumulative
/// rounding keeps the sum exact (the boundaries telescope, so they can't drift off
/// the bar width); a present-but-tiny bucket is then guaranteed ≥1 cell — stolen
/// from the largest segment — so it stays visible. Per-segment ceil scaling can't
/// be reused here: the segments sharing one bar must partition it, not overshoot.
/// Order matches `severity_order`: err → warn → info → ok.
fn compositionCells(c: Counts, bar: usize) [4]usize {
    const total = c.total(); // caller guards total > 0
    const b_err = (c.err * bar + total / 2) / total;
    const b_ew = ((c.err + c.warn) * bar + total / 2) / total;
    const b_ewi = ((c.err + c.warn + c.info) * bar + total / 2) / total;
    var seg = [4]usize{ b_err, b_ew - b_err, b_ewi - b_ew, bar - b_ewi };
    const counts = [4]usize{ c.err, c.warn, c.info, c.ok };
    for (counts, 0..) |n, i| {
        if (n > 0 and seg[i] == 0) {
            var max_i: usize = 0;
            for (seg, 0..) |v, j| {
                if (v > seg[max_i]) max_i = j;
            }
            seg[max_i] -= 1;
            seg[i] = 1;
        }
    }
    return seg;
}

/// Paint the stacked composition bar: err→warn→info→ok cells, each run in its severity
/// colour, on the shared `total` scale. Empty segments emit no colour, so adjacent
/// runs stay visually distinct.
fn buildCompositionBar(lb: *tab.Frame, c: Counts, bar: usize) void {
    const seg = compositionCells(c, bar);
    for (severity_order, seg) |sev, n| {
        if (n == 0) continue;
        lb.put(color.roleCode(glyphStyle(sev)));
        var i: usize = 0;
        while (i < n) : (i += 1) lb.put("█");
    }
    lb.put(color.Style.reset.code());
}

/// Narrowest width that still fits a useful bar; below it the histogram drops the
/// bar row and shows only the `✗N ⚠N ✓N  (N checks)` legend, which can't wrap into
/// the list.
const histogram_min_width: u16 = 36;
/// The bar never shrinks below this, so a present bucket can still show a cell.
const band_min_bar: u16 = 6;
/// Fixed bar width: the bars read the same on a laptop and a wall-wide terminal —
/// a wider pane carries more list, not a longer bar.
const band_bar_cells: u16 = 40;

/// Cells a band bar spans at `width`: the fixed width, clamped down only when the
/// pane is too narrow for it. Shared by the severity composition bar and the
/// reclaimable split so the two bars line up.
fn barWidth(width: u16) usize {
    return @min(@as(usize, band_bar_cells), @max(@as(usize, band_min_bar), width));
}

/// The histogram's counts legend: `✗N ⚠N ✓N  (N checks)` — the numbers and the
/// shared total, on their own row beneath the bar (the bar is the picture, this
/// the figures). Also the whole histogram when the pane is too narrow for a bar.
fn buildCountsLegend(lb: *tab.Frame, c: Counts) void {
    buildPlainCounts(lb, c);
    lb.put("  ");
    lb.put(color.roleCode(.muted));
    var nbuf: [32]u8 = undefined;
    lb.put(std.fmt.bufPrint(&nbuf, "({d} checks)", .{c.total()}) catch "");
    lb.put(color.Style.reset.code());
}

/// One severity's `glyph N` cell with the glyph in its colour — a space sets the
/// glyph off from its number so the count reads cleanly.
fn buildPlainCount(lb: *tab.Frame, sev: Severity, count: usize) void {
    lb.put(color.roleCode(glyphStyle(sev)));
    lb.put(glyph(sev));
    lb.put(color.Style.reset.code());
    var nbuf: [16]u8 = undefined;
    lb.put(std.fmt.bufPrint(&nbuf, " {d}", .{count}) catch "");
}

fn buildPlainCounts(lb: *tab.Frame, c: Counts) void {
    buildPlainCount(lb, .err, c.err);
    lb.put("  ");
    buildPlainCount(lb, .warn, c.warn);
    // Only while an operation is in flight, so the steady-state legend is unchanged.
    if (c.info > 0) {
        lb.put("  ");
        buildPlainCount(lb, .info, c.info);
    }
    lb.put("  ");
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

/// The CLI info-bullet glyph, with the same basic-tier `>` fallback the rest of
/// the CLI uses; our own constant bytes either way, so no new injection surface.
fn infoGlyph() []const u8 {
    return if (color.isEmojiEnabled()) "▸" else ">";
}

/// `mt purge` reclaims cask history and the tap cache with *different* flags, so
/// each bullet quotes the one that reclaims it — pinning a single hint onto a
/// combined total would mislead. Literal text mirroring the CLI's own guidance.
const cask_hint = "mt purge --old-versions";
const tap_hint = "mt purge --cache";

/// The header line: the combined reclaimable total only — no per-source figure and
/// no command hint, so it can't claim a flag reclaims more than it does. Saturating
/// add keeps a hostile near-u64-max payload from wrapping the total.
fn buildReclaimHeader(lb: *tab.Frame, rc: Reclaim) void {
    lb.put(color.roleCode(.muted));
    lb.put("Reclaimable: ");
    var bbuf: [24]u8 = undefined;
    lb.put(humanBytes(rc.cask_bytes +| rc.tap_cache_bytes, &bbuf));
    lb.put(color.Style.reset.code());
}

/// One source's bullet: `▸ <size> <label>`, muted — the size left-aligned under
/// the glyph and a single space to the label (no alignment padding). The command
/// hint lives on its own sub-line (`buildReclaimHint`), so the bullet reads as the
/// figure and the hint as the action. `label` carries any suffix (the cask's
/// retained-versions note).
fn buildReclaimBullet(lb: *tab.Frame, bytes: u64, label: []const u8) void {
    lb.put(color.roleCode(.muted));
    lb.put(infoGlyph());
    lb.put(" ");
    var bbuf: [24]u8 = undefined;
    lb.put(humanBytes(bytes, &bbuf));
    lb.put(" ");
    lb.put(label);
    lb.put(color.Style.reset.code());
}

/// A bullet's reclaiming command, indented onto its own dim sub-line beneath the
/// bullet so the action is visually subordinate to the figure.
fn buildReclaimHint(lb: *tab.Frame, hint: []const u8) void {
    lb.put(color.roleCode(.muted));
    lb.put("   → ");
    lb.put(hint);
    lb.put(color.Style.reset.code());
}

fn buildCaskBullet(lb: *tab.Frame, rc: Reclaim) void {
    var lblbuf: [48]u8 = undefined;
    const label = if (rc.retained_versions > 0)
        std.fmt.bufPrint(&lblbuf, "cask history ({d} old versions)", .{rc.retained_versions}) catch "cask history"
    else
        "cask history";
    buildReclaimBullet(lb, rc.cask_bytes, label);
}

/// A ratio bar only reads as a comparison when there are two values to compare;
/// with a single figure the wrapped text already says it all.
fn reclaimHasBar(rc: Reclaim) bool {
    return rc.cask_bytes > 0 and rc.tap_cache_bytes > 0;
}

/// Paint the reclaimable split as a contiguous two-tone stacked bar: the cask
/// share (secondary) abutting the tap-cache share (accent), full band-bar width.
/// Cask leads in `secondary` rather than `accent` so the dominant block isn't the
/// selection-highlight colour the tabs and list cursor already use. The labelled
/// bullets above are its legend, so the bar carries no inline text. Each side keeps
/// at least one cell so a tiny-but-present share stays visible.
fn paintRatioBar(f: *tab.Frame, rect: tab.Rect, row: u16, rc: Reclaim) void {
    const bar: u16 = @intCast(barWidth(rect.width));
    // u128 so the sum and the cell-scaling can't overflow on a hostile payload's
    // near-u64-max byte counts; the result is at most `bar`.
    const cells: u128 = bar;
    const total: u128 = @as(u128, rc.cask_bytes) + rc.tap_cache_bytes; // both > 0 here
    const share: u128 = (@as(u128, rc.cask_bytes) * cells + total / 2) / total; // rounded
    const cask_cells: u16 = @intCast(@max(@as(u128, 1), @min(cells - 1, share)));
    const cache_cells: u16 = bar - cask_cells;

    var lb_buf: [512]u8 = undefined;
    var lb: tab.Frame = .{ .buf = &lb_buf };
    lb.put(color.roleCode(.secondary));
    var i: u16 = 0;
    while (i < cask_cells) : (i += 1) lb.put("█");
    lb.put(color.roleCode(.accent));
    i = 0;
    while (i < cache_cells) : (i += 1) lb.put("█");
    lb.put(color.Style.reset.code());
    paintBandLine(f, rect, row, lb.slice());
}

/// Sources with something to reclaim — one bullet (plus its hint sub-line) each.
fn reclaimSourceCount(rc: Reclaim) u16 {
    return @as(u16, @intFromBool(rc.cask_bytes > 0)) + @intFromBool(rc.tap_cache_bytes > 0);
}

/// Rows the section needs: a blank spacer, the header, two rows per source
/// (bullet + hint sub-line), and the stacked bar when both sources are present.
/// The band reserves them up front so it can grow past its base height before the
/// list claims the rest.
fn reclaimRowCount(rc: Reclaim) u16 {
    return 2 + 2 * reclaimSourceCount(rc) + @as(u16, @intFromBool(reclaimHasBar(rc)));
}

/// Paint the section top-down — a blank spacer, the header total, the stacked bar
/// directly beneath it, then each source's bullet and its indented hint sub-line
/// (the bullets are the bar's legend) — into at most `max_rows` rows from
/// `start_row`, returning the rows used (spacer included). Lines are truncated,
/// never wrapped, so they can't bleed into the list; the per-source detail paints
/// last so it sheds first under height pressure, keeping the total and split.
fn paintReclaim(f: *tab.Frame, rect: tab.Rect, start_row: u16, rc: Reclaim, max_rows: u16) u16 {
    if (rect.width == 0 or max_rows == 0) return 0;
    var buf: [256]u8 = undefined;
    // Skip a blank spacer row only when the header still fits below it.
    var n: u16 = if (max_rows >= 2) 1 else 0;

    var hdr: tab.Frame = .{ .buf = &buf };
    buildReclaimHeader(&hdr, rc);
    paintBandLine(f, rect, start_row + n, hdr.slice());
    n += 1;

    if (reclaimHasBar(rc) and n < max_rows) {
        paintRatioBar(f, rect, start_row + n, rc);
        n += 1;
    }
    if (rc.cask_bytes > 0) {
        if (n >= max_rows) return n;
        var lb: tab.Frame = .{ .buf = &buf };
        buildCaskBullet(&lb, rc);
        paintBandLine(f, rect, start_row + n, lb.slice());
        n += 1;
        if (n >= max_rows) return n;
        var hb: tab.Frame = .{ .buf = &buf };
        buildReclaimHint(&hb, cask_hint);
        paintBandLine(f, rect, start_row + n, hb.slice());
        n += 1;
    }
    if (rc.tap_cache_bytes > 0) {
        if (n >= max_rows) return n;
        var lb: tab.Frame = .{ .buf = &buf };
        buildReclaimBullet(&lb, rc.tap_cache_bytes, "tap cache");
        paintBandLine(f, rect, start_row + n, lb.slice());
        n += 1;
        if (n >= max_rows) return n;
        var hb: tab.Frame = .{ .buf = &buf };
        buildReclaimHint(&hb, tap_hint);
        paintBandLine(f, rect, start_row + n, hb.slice());
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

/// Paint the health band into `rect` and return the rows used. The band is
/// enclosed by a dim rule top and bottom; inside, the segments shed lowest-signal
/// first (histogram, then the fixable line) so a short pane keeps the verdict. The
/// histogram is two rows — the composition bar then its counts legend — but
/// collapses to the legend alone on a pane too narrow for a bar.
fn renderBand(f: *tab.Frame, counts: Counts, reclaim: ?Reclaim, rect: tab.Rect) u16 {
    if (rect.height < band_min_height) return 0; // can't enclose even the banner
    var buf: [512]u8 = undefined; // wide enough for a full-row composition bar
    var used: u16 = 0;

    tab.renderSeparator(f, rect, rect.row + used, true);
    used += 1;

    var banner: tab.Frame = .{ .buf = &buf };
    buildBanner(&banner, counts);
    paintBandLine(f, rect, rect.row + used, banner.slice());
    used += 1;

    // The histogram needs a full-height band; it is the first segment shed. The
    // fixable call-to-action sheds after it but before the verdict.
    const show_hist = rect.height >= band_full_height;
    const show_fixable = rect.height >= band_full_height - 2;
    if (show_hist) {
        if (rect.width >= histogram_min_width) { // the bar's own row, full width
            var bar: tab.Frame = .{ .buf = &buf };
            buildCompositionBar(&bar, counts, barWidth(rect.width));
            paintBandLine(f, rect, rect.row + used, bar.slice());
            used += 1;
        }
        var legend: tab.Frame = .{ .buf = &buf };
        buildCountsLegend(&legend, counts);
        paintBandLine(f, rect, rect.row + used, legend.slice());
        used += 1;
    }
    if (show_fixable) {
        var fx: tab.Frame = .{ .buf = &buf };
        buildFixable(&fx, counts);
        paintBandLine(f, rect, rect.row + used, fx.slice());
        used += 1;
    }
    // The reclaimable section is lowest-signal: it fills whatever rows remain
    // between the segments above and the closing rule. So it grows the band when
    // there's room and is the first to shed when there isn't — it never wraps into
    // the list, only into rows the band reserved.
    if (reclaim) |rc| {
        const capacity: u16 = (rect.height -| 1) -| used; // rows left before the closing rule
        if (capacity > 0) used += paintReclaim(f, rect, rect.row + used, rc, capacity);
    }

    tab.renderSeparator(f, rect, rect.row + used, true);
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

    // An all-clear run (no filter, findings present, none needing attention and
    // none in progress) has no verdict to weigh: collapse the band to the calm
    // summary line, plus the reclaimable section when there is disk to reclaim.
    // In-progress (info) findings keep the band so the "operation in progress"
    // verdict still shows instead of a misleading all-clear.
    if (filter.len == 0 and counts.total() > 0 and counts.attention() == 0 and counts.info == 0) {
        renderAllClear(f, r, counts);
        if (reclaim) |rc| {
            const max = r.height -| 1; // the summary line takes the top row
            if (max > 0) _ = paintReclaim(f, r, r.row + 1, rc, max);
        }
        return;
    }

    var content: tab.Rect = r;
    // The band rides above the list: reserve its rows from the top before the
    // detail pane claims from the bottom, so the list gets height − band − detail.
    if (counts.total() > 0) {
        // A present advisory lets the band grow past full by however many rows it
        // wraps to at this width; bandCap still caps it so the list keeps a row.
        const adv_rows = if (reclaim) |rc| reclaimRowCount(rc) else 0;
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
    // The unfiltered all-clear summary is handled in `render`; here a filter that
    // matches only ok rows still lists them, so we always fall through to the list.
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
const info_only = [_]Row{
    .{ .id = "missing_kegs", .severity = .info, .title = "Missing kegs", .detail = "operation in progress", .fixable = false, .fix_class = .none },
    .{ .id = "malt_prefix", .severity = .ok, .title = "MALT_PREFIX", .detail = "/opt/malt", .fixable = false, .fix_class = .none },
};

// A skewed store (0 err, 2 warn, 16 ok) for the total-scaled composition bar:
// on a shared scale ok must dominate warn, not sit at near-parity.
const skew_0_2_16 = blk: {
    var rows: [18]Row = undefined;
    for (0..16) |i| rows[i] = .{ .id = "ok", .severity = .ok, .title = "ok" };
    rows[16] = .{ .id = "w", .severity = .warn, .title = "warn a", .fixable = true, .fix_class = .stale_lock };
    rows[17] = .{ .id = "w", .severity = .warn, .title = "warn b", .fixable = true, .fix_class = .stale_lock };
    break :blk rows;
};

test "matches is a case-insensitive substring; empty filter matches all" {
    try testing.expect(matches("SQLite integrity", ""));
    try testing.expect(matches("SQLite integrity", "sqlite"));
    try testing.expect(!matches("Stale lock", "zzz"));
}

test "End jumps to the last filtered row" {
    var s: State = .{ .items = &sample };
    step(&s, .end);
    try testing.expectEqual(@as(usize, 3), s.chrome.view.selected);
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

test "an info finding is in-progress: its own glyph, never counted as attention" {
    const items = [_]Row{
        .{ .id = "missing_kegs", .severity = .info, .title = "Missing kegs", .detail = "operation in progress", .fixable = false, .fix_class = .none },
    };
    const c = tally(&items, "");
    try testing.expectEqual(@as(usize, 1), c.info);
    try testing.expectEqual(@as(usize, 0), c.attention());
    try testing.expectEqualStrings("ℹ", glyph(.info));
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
    // No-data is not a verdict: neither the "all checks passed" banner nor the
    // all-clear line may appear — we can't vouch for checks we never received.
    try std.testing.expect(std.mem.indexOf(u8, out, "all checks passed") == null);
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
    try testing.expect(std.mem.indexOf(u8, out, "all checks passed") == null); // the band verdict is collapsed away
    try testing.expect(std.mem.indexOf(u8, out, "auto-fixable") == null); // and so is the fixable line
}

test "the all-clear collapse keeps the reclaimable section but drops the band verdict" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // Every check passes, but there is cask disk to reclaim: the reclaimable
    // section stays, the verdict/histogram/fixable band does not.
    const s: State = .{ .items = &all_ok, .stats = .{ .cask_bytes = 2048, .retained_versions = 1 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "All clear") != null); // the calm summary
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable:") != null); // reclaimable kept
    try testing.expect(std.mem.indexOf(u8, out, "all checks passed") == null); // verdict dropped
    try testing.expect(std.mem.indexOf(u8, out, "auto-fixable") == null); // fixable line dropped
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
    // all_ok has no band — its all-clear case is covered separately — so only the
    // attention verdicts are exercised here.
    const cases = [_]struct { items: []const Row, verdict: []const u8 }{
        .{ .items = &sample, .verdict = "issues found" }, // an err is present (may include warnings)
        .{ .items = &warn_only, .verdict = "warnings found" }, // warn is the worst, no errors
        .{ .items = &info_only, .verdict = "operation in progress" }, // info outranks ok
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
    try testing.expect(std.mem.indexOf(u8, out, "█") != null); // a composition bar is drawn
    try testing.expect(std.mem.indexOf(u8, out, "2") != null); // the warn count (only the histogram carries it)
}

// Count a composition-bar segment's cells. The banner and legend also carry these
// role codes, but always followed by a glyph — only the bar follows a role code
// with a `█`, so `open ++ "█"` pins the segment start unambiguously; count cells
// until the colour that ends it (`close`).
fn segCells(out: []const u8, open: []const u8, close: []const u8) usize {
    var pat: [48]u8 = undefined;
    // 48 bytes always holds a role-code escape plus one `█`; overflow is a test bug.
    const needle = std.fmt.bufPrint(&pat, "{s}█", .{open}) catch unreachable;
    const s = (std.mem.indexOf(u8, out, needle) orelse return 0) + open.len;
    const e = std.mem.indexOfPos(u8, out, s, close) orelse out.len;
    return std.mem.count(u8, out[s..e], "█");
}

test "the histogram is one bar scaled to the total, so ok dominates warn (not near-parity)" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &skew_0_2_16 }; // 0 err, 2 warn, 16 ok over a total of 18
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    const warn_cells = segCells(out, color.roleCode(.warning), color.roleCode(.success));
    const ok_cells = segCells(out, color.roleCode(.success), color.Style.reset.code());
    try testing.expect(warn_cells >= 1); // a present bucket stays visible
    try testing.expect(ok_cells > warn_cells * 2); // 16 vs 2 reads as dominance, not parity
    // The segments compose one bar: their cells sum to the bar's width.
    try testing.expectEqual(barWidth(80), warn_cells + ok_cells); // err is 0 here
}

test "an all-ok store collapses the band, so no composition bar is drawn" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const only_ok = [_]Row{
        .{ .id = "a", .severity = .ok, .title = "a" },
        .{ .id = "b", .severity = .ok, .title = "b" },
        .{ .id = "c", .severity = .ok, .title = "c" },
    };
    const st: State = .{ .items = &only_ok };
    render(&st, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    const ok_cells = segCells(out, color.roleCode(.success), color.Style.reset.code());
    try testing.expectEqual(@as(u16, 0), ok_cells); // all-clear collapses away the histogram
}

test "the histogram surfaces the total checks count alongside the bar" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &skew_0_2_16 }; // 18 checks total
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    try testing.expect(std.mem.indexOf(u8, f.slice(), "18 checks") != null);
}

// The 1-based screen row of the band line that paints `needle`, read from the
// `CUP` (`ESC [ row ; col H`) that positions it. Band text carries no capital `H`,
// so the nearest `H` before the needle is that line's cursor move.
fn bandRowOf(out: []const u8, needle: []const u8) u16 {
    const at = std.mem.indexOf(u8, out, needle).?;
    const h = std.mem.lastIndexOfScalar(u8, out[0..at], 'H').?;
    const esc = std.mem.lastIndexOf(u8, out[0..h], "\x1b[").?;
    var row: u16 = 0;
    var i = esc + 2;
    while (out[i] >= '0' and out[i] <= '9') : (i += 1) row = row * 10 + (out[i] - '0');
    return row;
}

test "the composition bar and the counts legend sit on their own rows" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &skew_0_2_16 }; // worst is warn → "warnings found" banner
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    // banner, then the bar on the next row, then the counts a row below that.
    try testing.expectEqual(@as(u16, 2), bandRowOf(out, "18 checks") - bandRowOf(out, "warnings found"));
}

test "a blank spacer separates the fixable line from the reclaimable section" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .cask_bytes = 2048, .retained_versions = 2 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 24 });
    const out = f.slice();
    // One blank row between the CTA and the header, so the two read as distinct.
    try testing.expectEqual(@as(u16, 2), bandRowOf(out, "Reclaimable:") - bandRowOf(out, "auto-fixable"));
}

test "each reclaimable bullet drops its purge hint onto an indented sub-line" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{
        .cask_bytes = 1288490189,
        .tap_cache_bytes = 88 * 1024 * 1024,
        .retained_versions = 4,
    } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 24 });
    const out = f.slice();
    // The hint is the row directly below its bullet, not trailing it inline.
    try testing.expectEqual(@as(u16, 1), bandRowOf(out, "mt purge --old-versions") - bandRowOf(out, "cask history (4 old versions)"));
    try testing.expectEqual(@as(u16, 1), bandRowOf(out, "mt purge --cache") - bandRowOf(out, "tap cache"));
}

test "the reclaimable bar is a contiguous two-tone stacked bar, not labelled rectangles" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .cask_bytes = 3 * 1024, .tap_cache_bytes = 1024 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 24 });
    const out = f.slice();
    // The cask (secondary) run abuts the cache (accent) run with only the colour
    // change between — a stacked split, not two text-labelled blocks with a gap.
    // Cask leads in `secondary`, not `accent`, so the dominant block isn't the
    // selection-highlight colour.
    var pat: [64]u8 = undefined;
    const seam = std.fmt.bufPrint(&pat, "█{s}█", .{color.roleCode(.accent)}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out, seam) != null);
}

test "the band bars keep a fixed width instead of widening with the terminal" {
    var a: [16384]u8 = undefined;
    var b: [16384]u8 = undefined;
    var fa: tab.Frame = .{ .buf = &a };
    var fb: tab.Frame = .{ .buf = &b };
    const s: State = .{ .items = &skew_0_2_16 }; // no reclaim → the only bar is the histogram
    render(&s, &fa, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    render(&s, &fb, .{ .row = 1, .col = 1, .width = 200, .height = 20 });
    // A far wider pane must not grow the bar: same cell count at 80 and 200 cols.
    try testing.expectEqual(std.mem.count(u8, fa.slice(), "█"), std.mem.count(u8, fb.slice(), "█"));
}

test "the counts legend spaces each glyph from its number" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &skew_0_2_16 }; // 0 err, 2 warn, 16 ok
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    // The glyph's colour resets, then a space sets the number off: `⚠<reset> 2`.
    var pat: [48]u8 = undefined;
    const warn = std.fmt.bufPrint(&pat, "⚠{s} 2", .{color.Style.reset.code()}) catch unreachable;
    try testing.expect(std.mem.indexOf(u8, out, warn) != null);
}

test "the reclaimable bullets left-align their sizes, each one space from its label" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // 180.7 MB cask + 2.0 MB tap: differently-sized figures.
    const s: State = .{ .items = &sample, .stats = .{
        .cask_bytes = 180 * 1024 * 1024 + 700 * 1024,
        .tap_cache_bytes = 2 * 1024 * 1024,
        .retained_versions = 2,
    } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 24 });
    const out = f.slice();
    // Every size starts right after the glyph and sits exactly one space from its
    // label — no alignment padding stretching the gap on the shorter figure.
    try testing.expect(std.mem.indexOf(u8, out, "▸ 180.7 MB cask history") != null);
    try testing.expect(std.mem.indexOf(u8, out, "▸ 2.0 MB tap cache") != null);
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
    try testing.expect(std.mem.indexOf(u8, out, "issues found") == null); // band suppressed
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null); // a list row survives
}

test "a short pane sheds the histogram but keeps the verdict, CTA, and the list" {
    var buf: [2048]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 5 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "█") == null); // histogram shed first (lowest signal)
    try testing.expect(std.mem.indexOf(u8, out, "issues found") != null); // verdict survives (highest signal)
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
    const verdict = std.mem.indexOf(u8, out, "issues found").?;
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
    try testing.expect(std.mem.indexOf(u8, out, "issues found") == null); // band dropped
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null); // list survives
}

test "the band paints above the findings list" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 80, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "issues found") != null); // banner present
    const verdict_at = std.mem.indexOf(u8, out, "issues found").?;
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

test "reclaimable breaks into a header total plus one labelled bullet per source" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    // 1.2 GB cask history over 4 retained versions + 88 MB tap cache.
    const s: State = .{ .items = &sample, .stats = .{
        .cask_bytes = 1288490189,
        .tap_cache_bytes = 88 * 1024 * 1024,
        .retained_versions = 4,
    } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    const out = f.slice();
    // Header carries the *total* only (1.2 GB + 88 MB ≈ 1.3 GB), no command hint.
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable: 1.3 GB") != null);
    // One bullet per non-zero source, each with its own size, label, and the hint
    // that actually reclaims it.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "▸"));
    try testing.expect(std.mem.indexOf(u8, out, "1.2 GB") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cask history (4 old versions)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "→ mt purge --old-versions") != null);
    try testing.expect(std.mem.indexOf(u8, out, "88.0 MB") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tap cache") != null);
    try testing.expect(std.mem.indexOf(u8, out, "→ mt purge --cache") != null);
    // The advisory rides in the band, above the findings list.
    const reclaim_at = std.mem.indexOf(u8, out, "Reclaimable:").?;
    const first_title_at = std.mem.indexOf(u8, out, "SQLite integrity").?;
    try testing.expect(reclaim_at < first_title_at);
}

test "the cask-inclusive total never wears the cache-only purge hint" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{
        .cask_bytes = 1288490189,
        .tap_cache_bytes = 88 * 1024 * 1024,
        .retained_versions = 4,
    } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    const out = f.slice();
    // The header line (everything before the first bullet) is the combined total;
    // pinning `--cache` to it would claim it reclaims cask history too. It must not.
    const header = out[0..std.mem.indexOf(u8, out, "▸").?];
    try testing.expect(std.mem.indexOf(u8, header, "Reclaimable:") != null);
    try testing.expect(std.mem.indexOf(u8, header, "mt purge") == null);
    // `--cache` appears only after the tap-cache label, never the cask one.
    const cache_at = std.mem.indexOf(u8, out, "--cache").?;
    const tap_at = std.mem.indexOf(u8, out, "tap cache").?;
    const cask_at = std.mem.indexOf(u8, out, "cask history").?;
    try testing.expect(tap_at < cache_at and cask_at < tap_at);
}

test "a cask-only store shows a header, one cask bullet, and no bar" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .cask_bytes = 2048, .retained_versions = 2 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable: 2.0 KB") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "▸")); // one source, one bullet
    try testing.expect(std.mem.indexOf(u8, out, "cask history (2 old versions)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "→ mt purge --old-versions") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tap cache") == null); // nothing to reclaim there
    try testing.expect(std.mem.indexOf(u8, out, color.roleCode(.secondary)) == null); // single source → no bar
}

test "a cache-only store shows a header, one tap bullet, and no bar" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .tap_cache_bytes = 512 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable: 512.0 B") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "▸"));
    try testing.expect(std.mem.indexOf(u8, out, "tap cache") != null);
    try testing.expect(std.mem.indexOf(u8, out, "→ mt purge --cache") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cask history") == null);
    try testing.expect(std.mem.indexOf(u8, out, color.roleCode(.secondary)) == null); // single source → no bar
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

test "the reclaimable bullet glyph falls back to ASCII when emoji are off" {
    color.setForTest(null, false); // emoji disabled, colour left to the environment
    defer color.setForTest(null, null);
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{ .cask_bytes = 2048, .retained_versions = 2 } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 100, .height = 20 });
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "▸") == null); // the emoji bullet is gone
    try testing.expect(std.mem.indexOf(u8, out, "> 2.0 KB") != null); // its basic-tier `>` stands in
}

test "the reclaimable section renders on a narrow pane without wrapping into the list" {
    var buf: [8192]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const s: State = .{ .items = &sample, .stats = .{
        .cask_bytes = 1288490189,
        .tap_cache_bytes = 88 * 1024 * 1024,
        .retained_versions = 4,
    } };
    render(&s, &f, .{ .row = 1, .col = 1, .width = 48, .height = 24 }); // ≤50 cols, must not crash
    const out = f.slice();
    try testing.expect(std.mem.indexOf(u8, out, "Reclaimable:") != null); // header survives the cut
    try testing.expect(std.mem.indexOf(u8, out, "SQLite integrity") != null); // the list stays the floor
}

test "conforms to the tab contract" {
    comptime tab.verify(@This());
}
