//! malt — list command
//! List installed packages.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const linker = @import("../core/linker.zig");
const schema = @import("../db/schema.zig");
const schema_report = @import("schema_report.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const dirsize = @import("../fs/dirsize.zig");
const tap_slug = @import("../tap_slug.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
const termsize = @import("../ui/termsize.zig");
const help = @import("help.zig");

pub fn execute(ctx: *const AppCtx, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "list")) return;

    // Parse per-command flags. `--json`, `--quiet`/`-q`, `--verbose`/`-v`,
    // and `--dry-run` are stripped by the global parser in `main.zig`
    // before we get here — read them via `output.isJson()` etc.
    var show_formula = false;
    var show_cask = false;
    var show_versions = false;
    var show_pinned = false;
    var show_size = false;
    var show_linked = false;
    var tap_filter: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            show_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            show_cask = true;
        } else if (std.mem.eql(u8, arg, "--versions") or std.mem.eql(u8, arg, "--version")) {
            show_versions = true;
        } else if (std.mem.eql(u8, arg, "--pinned")) {
            show_pinned = true;
        } else if (std.mem.eql(u8, arg, "--size")) {
            show_size = true;
        } else if (std.mem.eql(u8, arg, "--linked")) {
            show_linked = true;
        } else if (std.mem.eql(u8, arg, "--tap")) {
            if (i + 1 >= args.len) {
                output.err("--tap requires a label (e.g. `--tap user/repo`)", .{});
                return error.Aborted;
            }
            i += 1;
            tap_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--tap=")) {
            tap_filter = arg["--tap=".len..];
        }
    }
    // Rows are stored canonical; fold the filter so every spelling of a
    // tap selects the same set.
    var tap_filter_buf: [tap_slug.max_slug_len]u8 = undefined;
    if (tap_filter) |raw| tap_filter = tap_slug.canonicalTapSlug(&tap_filter_buf, raw) orelse raw;

    const json_mode = output.isJson();

    // If neither specified, show both
    if (!show_formula and !show_cask) {
        show_formula = true;
        show_cask = true;
    }

    // Open DB
    const prefix = atomic.maltPrefixOrAbort();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix with no `db/` yet = nothing installed. Treat as
        // empty output (rc=0), same contract as `ls` on an empty dir.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch |e| return schema_report.abortInitFailure(&db, e, prefix);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = ctx.stdout.writer(ctx.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};

    if (json_mode) {
        try writeJsonOutput(ctx, &db, prefix, show_formula, show_cask, show_pinned, show_size, show_linked, tap_filter, stdout);
    } else if (output.isVerbose() or output.isQuiet()) {
        // --debug implies verbose, so a debug transcript shows rows, not the grid.
        try writeHumanOutput(&db, show_formula, show_cask, show_versions, show_pinned, tap_filter, output.isQuiet(), stdout);
    } else {
        const width: ?u16 = if (termsize.winsize(ctx.stdout.handle)) |s| s.cols else |_| null;
        try writeCompactOutput(std.heap.page_allocator, &db, show_formula, show_cask, show_versions, show_pinned, tap_filter, width, stdout);
    }
}

/// Default human layout: `Formulae` / `Casks` sections of names packed into
/// columns, like `brew list`. `width` is the terminal's column count; null
/// means stdout is not a terminal.
pub fn writeCompactOutput(
    gpa: std.mem.Allocator,
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    show_pinned: bool,
    tap_filter: ?[]const u8,
    width: ?u16,
    stdout: *std.Io.Writer,
) !void {
    // A version column makes the grid ragged; keep brew's one-per-line shape.
    if (show_versions) return writeHumanOutput(db, show_formula, show_cask, true, show_pinned, tap_filter, false, stdout);
    // Piped output stays one bare name per line so `mt list | grep -x` works.
    const cols = width orelse return writeHumanOutput(db, show_formula, show_cask, false, show_pinned, tap_filter, true, stdout);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const has_tap = tap_filter != null;
    const formulae = if (show_formula) try collectNames(a, db, formulaListSql(show_pinned, has_tap), tap_filter) else &.{};
    const casks = if (show_cask) try collectNames(a, db, caskListSql(show_pinned, has_tap), tap_filter) else &.{};

    // Headers only disambiguate when both kinds are in scope.
    const headed = show_formula and show_cask;
    if (formulae.len > 0) try writeSection(stdout, headed, "Formulae", formulae, cols);
    if (casks.len > 0) {
        if (formulae.len > 0) try stdout.writeAll("\n");
        try writeSection(stdout, headed, "Casks", casks, cols);
    }
}

/// Column 0 of `sql`, duped into `a` so the grid can measure every name
/// before printing the first line.
fn collectNames(a: std.mem.Allocator, db: *sqlite.Database, sql: [:0]const u8, tap_filter: ?[]const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var stmt = db.prepare(sql) catch return &.{};
    defer stmt.finalize();
    if (tap_filter) |t| stmt.bindText(1, t) catch return &.{};
    while (stmt.step() catch false) {
        const name = stmt.columnText(0) orelse continue;
        try names.append(a, try a.dupe(u8, std.mem.sliceTo(name, 0)));
    }
    return names.items;
}

fn writeSection(w: *std.Io.Writer, headed: bool, title: []const u8, names: []const []const u8, width: u16) !void {
    if (headed) {
        writeStyledSpan(w, color.Style.bold.code(), title, "", "");
        try w.writeAll("\n");
    }
    try writeColumns(w, names, width);
}

/// Column-major grid (`ls -C` order). Never a trailing space.
fn writeColumns(w: *std.Io.Writer, names: []const []const u8, width: u16) !void {
    if (names.len == 0) return;
    var max_len: usize = 0;
    var ascii = true;
    for (names) |n| {
        max_len = @max(max_len, n.len);
        for (n) |b| ascii = ascii and std.ascii.isAscii(b);
    }
    const col_w = max_len + 2;
    // Byte length is display width only for ASCII, and a bidi control in a
    // tap-cask token would reorder its row, so non-ASCII gets one column.
    const ncols = if (ascii) @max(1, width / col_w) else 1;
    const nrows = (names.len + ncols - 1) / ncols;
    for (0..nrows) |r| {
        var i = r;
        while (i < names.len) : (i += nrows) {
            try w.writeAll(names[i]);
            if (i + nrows < names.len) try w.splatByteAll(' ', col_w - names[i].len);
        }
        try w.writeAll("\n");
    }
}

/// Row layout behind `--verbose`/`--quiet`. Pub for tests: assert the exact
/// bytes for the human path without staging a real DB-on-prefix +
/// stdout-capture rig.
///
/// `quiet`: the help text promises "Names only, one per line", so
/// decorations (bullet, version suffix, `[pinned]` tag) are suppressed and
/// each row is a bare name + `\n`.
pub fn writeHumanOutput(
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    show_pinned: bool,
    tap_filter: ?[]const u8,
    quiet: bool,
    stdout: *std.Io.Writer,
) !void {
    if (show_pinned) {
        try writePinnedHuman(db, show_formula, show_cask, show_versions, tap_filter, quiet, stdout);
        return;
    }

    if (show_formula) {
        const sql = formulaListSql(false, tap_filter != null);
        var stmt = db.prepare(sql) catch return;
        defer stmt.finalize();
        if (tap_filter) |t| stmt.bindText(1, t) catch return;

        while (stmt.step() catch false) {
            const name = stmt.columnText(0) orelse continue;
            const ver = stmt.columnText(1);
            const pinned = stmt.columnBool(2);
            const name_slice = std.mem.sliceTo(name, 0);

            if (quiet) {
                stdout.writeAll(name_slice) catch return;
                stdout.writeAll("\n") catch return;
                continue;
            }

            writeBulletPrefix(stdout);
            stdout.writeAll(name_slice) catch return;
            if (show_versions) {
                const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "?";
                writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " (", ver_slice, ")");
            }
            if (pinned) {
                writeStyledSpan(stdout, color.SemanticStyle.warn.code(), " [pinned]", "", "");
            }
            stdout.writeAll("\n") catch return;
        }
    }

    if (show_cask) {
        const sql = caskListSql(false, tap_filter != null);
        var stmt = db.prepare(sql) catch return;
        defer stmt.finalize();
        if (tap_filter) |t| stmt.bindText(1, t) catch return;

        while (stmt.step() catch false) {
            const token = stmt.columnText(0) orelse continue;
            const ver = stmt.columnText(1);
            const token_slice = std.mem.sliceTo(token, 0);

            if (quiet) {
                stdout.writeAll(token_slice) catch return;
                stdout.writeAll("\n") catch return;
                continue;
            }

            writeBulletPrefix(stdout);
            stdout.writeAll(token_slice) catch return;
            if (show_versions) {
                const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "?";
                writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " (", ver_slice, ")");
            }
            stdout.writeAll("\n") catch return;
        }
    }
}

/// Flag combinations for the kegs/casks list SELECT. Used as the switch
/// key in `formulaListSql` / `caskListSql` so the compiler enforces
/// exhaustive handling of every (pinned × tap) variant.
const ListSqlVariant = enum { plain, tap, pinned, pinned_tap };

fn listSqlVariant(show_pinned: bool, tap_filter: bool) ListSqlVariant {
    if (show_pinned and tap_filter) return .pinned_tap;
    if (show_pinned) return .pinned;
    if (tap_filter) return .tap;
    return .plain;
}

/// Compose the kegs SELECT with optional pinned + tap filters. The
/// `?1` placeholder is bound by the caller for the `.tap` / `.pinned_tap`
/// variants. Strict equality means NULL-tap rows never match — kegs are
/// always attributed at install time, so this is purely future-proofing.
fn formulaListSql(show_pinned: bool, tap_filter: bool) [:0]const u8 {
    return switch (listSqlVariant(show_pinned, tap_filter)) {
        .plain => "SELECT name, version, pinned, id, cellar_path FROM kegs ORDER BY name;",
        .tap => "SELECT name, version, pinned, id, cellar_path FROM kegs WHERE tap = ?1 ORDER BY name;",
        .pinned => "SELECT name, version, pinned, id, cellar_path FROM kegs WHERE pinned = 1 ORDER BY name;",
        .pinned_tap => "SELECT name, version, pinned, id, cellar_path FROM kegs WHERE pinned = 1 AND tap = ?1 ORDER BY name;",
    };
}

/// Cask counterpart to `formulaListSql`. NULL tap means "unattributed"
/// (v5-era rows pre-`casks.tap`) — strict equality keeps the filter
/// honest. The user-facing workaround (`mt upgrade <token>`) is in the
/// help string.
fn caskListSql(show_pinned: bool, tap_filter: bool) [:0]const u8 {
    return switch (listSqlVariant(show_pinned, tap_filter)) {
        .plain => "SELECT token, version, pinned, app_path FROM casks ORDER BY token;",
        .tap => "SELECT token, version, pinned, app_path FROM casks WHERE tap = ?1 ORDER BY token;",
        .pinned => "SELECT token, version, pinned, app_path FROM casks WHERE pinned = 1 ORDER BY token;",
        .pinned_tap => "SELECT token, version, pinned, app_path FROM casks WHERE pinned = 1 AND tap = ?1 ORDER BY token;",
    };
}

/// `--pinned` walks formulas + casks together so the output is a single
/// sorted list across both kinds, with a `[cask]` tag distinguishing
/// cask rows. The `[pinned]` tag is dropped — every row is pinned by
/// definition, so repeating it is noise.
fn writePinnedHuman(
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    tap_filter: ?[]const u8,
    quiet: bool,
    stdout: *std.Io.Writer,
) !void {
    const sql = pinnedUnionSql(show_formula, show_cask, tap_filter != null) orelse return;
    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();
    if (tap_filter) |t| stmt.bindText(1, t) catch return;

    while (stmt.step() catch false) {
        const name = stmt.columnText(0) orelse continue;
        const ver = stmt.columnText(1);
        const kind = stmt.columnText(2);
        const name_slice = std.mem.sliceTo(name, 0);
        const is_cask = if (kind) |k| std.mem.eql(u8, std.mem.sliceTo(k, 0), "cask") else false;

        if (quiet) {
            stdout.writeAll(name_slice) catch return;
            stdout.writeAll("\n") catch return;
            continue;
        }

        writeBulletPrefix(stdout);
        stdout.writeAll(name_slice) catch return;
        if (show_versions) {
            const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "?";
            writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " (", ver_slice, ")");
        }
        if (is_cask) {
            writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " [", "cask", "]");
        }
        stdout.writeAll("\n") catch return;
    }
}

/// Which kinds participate in the `--pinned` view. `.neither` short-circuits
/// the caller (no SELECT to run); the other three pick a UNION shape.
const PinnedUnionKind = enum { neither, formula_only, cask_only, both };

fn pinnedUnionKind(show_formula: bool, show_cask: bool) PinnedUnionKind {
    if (show_formula and show_cask) return .both;
    if (show_formula) return .formula_only;
    if (show_cask) return .cask_only;
    return .neither;
}

/// Build the SQL that drives the `--pinned` view. The 'formula' / 'cask'
/// literal column tags each row so the caller can render the right marker.
/// `?1` is bound once and reused across both UNION branches when
/// `tap_filter` is set — sqlite parameter reuse is well-defined.
fn pinnedUnionSql(show_formula: bool, show_cask: bool, tap_filter: bool) ?[:0]const u8 {
    // Column shape across every branch: name, version, kind, ref_id,
    // ref_path. `ref_id` is the keg id (NULL for casks); `ref_path` is the
    // keg's cellar_path or the cask's app_path — feeds size/linked extras.
    const kegs_select = "SELECT name, version, 'formula' AS kind, id AS ref_id, cellar_path AS ref_path FROM kegs WHERE pinned = 1";
    const casks_select = "SELECT token AS name, version, 'cask' AS kind, NULL AS ref_id, app_path AS ref_path FROM casks WHERE pinned = 1";
    return switch (pinnedUnionKind(show_formula, show_cask)) {
        .neither => null,
        .both => if (tap_filter)
            kegs_select ++ " AND tap = ?1 " ++
                "UNION ALL " ++
                casks_select ++ " AND tap = ?1 " ++
                "ORDER BY name;"
        else
            kegs_select ++ " " ++
                "UNION ALL " ++
                casks_select ++ " " ++
                "ORDER BY name;",
        .formula_only => if (tap_filter)
            kegs_select ++ " AND tap = ?1 ORDER BY name;"
        else
            kegs_select ++ " ORDER BY name;",
        .cask_only => if (tap_filter)
            casks_select ++ " AND tap = ?1 ORDER BY name;"
        else
            casks_select ++ " ORDER BY name;",
    };
}

/// Emit the leading cyan bullet + space, honouring `NO_COLOR`.
fn writeBulletPrefix(stdout: *std.Io.Writer) void {
    if (color.isColorEnabledFor(.stdout)) {
        stdout.writeAll(color.SemanticStyle.info.code()) catch return;
        stdout.writeAll("  ▸ ") catch return;
        stdout.writeAll(color.Style.reset.code()) catch return;
    } else {
        stdout.writeAll("  ▸ ") catch return;
    }
}

/// Emit `open + body + close`, wrapping the whole thing in `style` / reset
/// when colour is enabled. `open` or `close` may be empty.
fn writeStyledSpan(
    stdout: *std.Io.Writer,
    style_code: []const u8,
    open: []const u8,
    body: []const u8,
    close: []const u8,
) void {
    const use_color = color.isColorEnabledFor(.stdout);
    if (use_color) stdout.writeAll(style_code) catch return;
    stdout.writeAll(open) catch return;
    stdout.writeAll(body) catch return;
    stdout.writeAll(close) catch return;
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch return;
}

fn writeJsonOutput(
    ctx: *const AppCtx,
    db: *sqlite.Database,
    prefix: []const u8,
    show_formula: bool,
    show_cask: bool,
    show_pinned: bool,
    show_size: bool,
    show_linked: bool,
    tap_filter: ?[]const u8,
    stdout: *std.Io.Writer,
) !void {
    const start_ts = std.Io.Clock.real.now(ctx.io).toMilliseconds();
    try buildListJson(db, stdout, ctx.io, prefix, show_formula, show_cask, show_pinned, show_size, show_linked, tap_filter, start_ts);
}

/// Build the `{ "schema_version": 1, "installed": [...], "formulae": [...], "casks": [...], "time_ms": N }`
/// payload into `w`. Kept `pub` so tests can assert on the exact bytes without
/// going through a real file. On per-section SQLite failures we emit an empty
/// array for that section rather than truncating the whole document.
pub fn buildListJson(
    db: *sqlite.Database,
    w: *std.Io.Writer,
    io: std.Io,
    prefix: []const u8,
    show_formula: bool,
    show_cask: bool,
    show_pinned: bool,
    show_size: bool,
    show_linked: bool,
    tap_filter: ?[]const u8,
    start_ts: i64,
) !void {
    // `--size`/`--linked` enrich only the `installed` array; the legacy
    // formulae/casks arrays stay byte-stable for existing consumers.
    const extras: Extras = .{ .io = io, .prefix = prefix, .size = show_size, .linked = show_linked };

    try output.writeSchemaVersionPrefix(w);
    try w.writeAll("\"installed\":[");
    var first = true;
    if (show_pinned) {
        try writePinnedInstalled(db, w, show_formula, show_cask, tap_filter, extras, &first);
    } else {
        if (show_formula) try writeFormulaRows(db, w, false, tap_filter, .installed, extras, &first);
        if (show_cask) try writeCaskRows(db, w, false, tap_filter, .installed, extras, &first);
    }
    try w.writeAll("]");

    if (show_formula) {
        try w.writeAll(",\"formulae\":[");
        var legacy_first = true;
        try writeFormulaRows(db, w, show_pinned, tap_filter, .legacy, extras.legacy(), &legacy_first);
        try w.writeAll("]");
    }

    if (show_cask) {
        try w.writeAll(",\"casks\":[");
        var legacy_first = true;
        try writeCaskRows(db, w, show_pinned, tap_filter, .legacy, extras.legacy(), &legacy_first);
        try w.writeAll("]");
    }

    try output.jsonTimeSuffix(w, start_ts);
    try w.writeAll("}\n");
}

/// `installed` array under `--pinned`: one sorted run across formulas
/// and casks, each row carrying the `pinned: true` flag for parity with
/// the formula-only shape callers already consume.
fn writePinnedInstalled(
    db: *sqlite.Database,
    w: *std.Io.Writer,
    show_formula: bool,
    show_cask: bool,
    tap_filter: ?[]const u8,
    extras: Extras,
    first: *bool,
) !void {
    const sql = pinnedUnionSql(show_formula, show_cask, tap_filter != null) orelse return;
    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();
    if (tap_filter) |t| stmt.bindText(1, t) catch return;

    while (stmt.step() catch false) {
        const name = stmt.columnText(0) orelse continue;
        const ver = stmt.columnText(1);
        const kind = stmt.columnText(2);
        const name_slice = std.mem.sliceTo(name, 0);
        const is_cask = if (kind) |k| std.mem.eql(u8, std.mem.sliceTo(k, 0), "cask") else false;

        if (!first.*) try w.writeAll(",");
        first.* = false;
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, name_slice);
        try w.writeAll(",\"version\":");
        try output.jsonStr(w, if (ver) |v| std.mem.sliceTo(v, 0) else "");
        if (is_cask) {
            const app_path = if (stmt.columnText(4)) |p| std.mem.sliceTo(p, 0) else "";
            try w.writeAll(",\"type\":\"cask\",\"pinned\":true");
            try writeCaskSizeField(w, extras, name_slice, app_path);
            try writeLinkedField(w, extras, .cask, db);
            try w.writeAll("}");
        } else {
            const keg_id = stmt.columnInt(3);
            const cellar = if (stmt.columnText(4)) |c| std.mem.sliceTo(c, 0) else "";
            try w.writeAll(",\"type\":\"formula\",\"pinned\":true");
            try writeSizeField(w, extras, cellar);
            try writeLinkedField(w, extras, .{ .formula = keg_id }, db);
            try w.writeAll("}");
        }
    }
}

const RowShape = enum { installed, legacy };

/// Per-row enrichment for the `installed` array. The legacy arrays pass
/// `.legacy()` so their bytes stay stable for existing consumers.
const Extras = struct {
    io: std.Io,
    prefix: []const u8,
    size: bool,
    linked: bool,

    /// Same io/prefix but both opt-in fields off — for the legacy arrays.
    fn legacy(self: Extras) Extras {
        return .{ .io = self.io, .prefix = self.prefix, .size = false, .linked = false };
    }
};

/// Append `,"size_bytes":N` for a real on-disk directory when `--size`
/// is on. `dir` empty (or missing on disk) yields 0 — a partial keg must
/// not crash the writer.
fn writeSizeField(w: *std.Io.Writer, extras: Extras, dir: []const u8) !void {
    if (!extras.size) return;
    const bytes = if (dir.len == 0) 0 else dirsize.dirSizeBytes(extras.io, dir);
    // 40 > label (14) + max u64 (20 digits) — bufPrint cannot run out.
    var buf: [40]u8 = undefined;
    try w.writeAll(std.fmt.bufPrint(&buf, ",\"size_bytes\":{d}", .{bytes}) catch return);
}

fn writeFormulaRows(
    db: *sqlite.Database,
    w: *std.Io.Writer,
    show_pinned: bool,
    tap_filter: ?[]const u8,
    shape: RowShape,
    extras: Extras,
    first: *bool,
) !void {
    const sql = formulaListSql(show_pinned, tap_filter != null);

    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();
    if (tap_filter) |t| stmt.bindText(1, t) catch return;

    while (stmt.step() catch false) {
        const name = stmt.columnText(0) orelse continue;
        const ver = stmt.columnText(1);
        const pinned = stmt.columnBool(2);
        if (!first.*) try w.writeAll(",");
        first.* = false;
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, std.mem.sliceTo(name, 0));
        try w.writeAll(",\"version\":");
        try output.jsonStr(w, if (ver) |v| std.mem.sliceTo(v, 0) else "");
        switch (shape) {
            .installed => {
                const keg_id = stmt.columnInt(3);
                const cellar = if (stmt.columnText(4)) |c| std.mem.sliceTo(c, 0) else "";
                try w.writeAll(",\"type\":\"formula\",\"pinned\":");
                try w.writeAll(if (pinned) "true" else "false");
                try writeSizeField(w, extras, cellar);
                try writeLinkedField(w, extras, .{ .formula = keg_id }, db);
                try w.writeAll("}");
            },
            .legacy => {
                try w.writeAll(",\"pinned\":");
                try w.writeAll(if (pinned) "true" else "false");
                try w.writeAll("}");
            },
        }
    }
}

fn writeCaskRows(
    db: *sqlite.Database,
    w: *std.Io.Writer,
    show_pinned: bool,
    tap_filter: ?[]const u8,
    shape: RowShape,
    extras: Extras,
    first: *bool,
) !void {
    const sql = caskListSql(show_pinned, tap_filter != null);
    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();
    if (tap_filter) |t| stmt.bindText(1, t) catch return;

    while (stmt.step() catch false) {
        const token = stmt.columnText(0) orelse continue;
        const ver = stmt.columnText(1);
        const pinned = stmt.columnBool(2);
        const ver_str: []const u8 = if (ver) |v| std.mem.sliceTo(v, 0) else "";
        if (!first.*) try w.writeAll(",");
        first.* = false;
        switch (shape) {
            .installed => {
                const token_slice = std.mem.sliceTo(token, 0);
                const app_path = if (stmt.columnText(3)) |p| std.mem.sliceTo(p, 0) else "";
                try w.writeAll("{\"name\":");
                try output.jsonStr(w, token_slice);
                try w.writeAll(",\"version\":");
                try output.jsonStr(w, ver_str);
                try w.writeAll(",\"type\":\"cask\",\"pinned\":");
                try w.writeAll(if (pinned) "true" else "false");
                try writeCaskSizeField(w, extras, token_slice, app_path);
                try writeLinkedField(w, extras, .cask, db);
                try w.writeAll("}");
            },
            .legacy => {
                try w.writeAll("{\"token\":");
                try output.jsonStr(w, std.mem.sliceTo(token, 0));
                try w.writeAll(",\"version\":");
                try output.jsonStr(w, ver_str);
                try w.writeAll("}");
            },
        }
    }
}

/// A cask's on-disk footprint is its in-prefix `Caskroom/<token>` plus the
/// installed artifact at `app_path` (often a `.app` bundle outside the
/// prefix). The symlink-safe walk means a binary cask's `app_path`
/// symlink-into-Caskroom is never double-counted.
fn writeCaskSizeField(w: *std.Io.Writer, extras: Extras, token: []const u8, app_path: []const u8) !void {
    if (!extras.size) return;
    var total: u64 = 0;
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}/Caskroom/{s}", .{ extras.prefix, token })) |caskroom| {
        total +|= dirsize.dirSizeBytes(extras.io, caskroom);
    } else |_| {}
    if (app_path.len > 0) total +|= dirsize.dirSizeBytes(extras.io, app_path);
    // 40 > label (14) + max u64 (20 digits) — bufPrint cannot run out.
    var nb: [40]u8 = undefined;
    try w.writeAll(std.fmt.bufPrint(&nb, ",\"size_bytes\":{d}", .{total}) catch return);
}

/// `linked` source per kind: a formula keg consults the `links` table
/// (via `core/linker`); a cask has no prefix-link concept and is always
/// active once installed, so it reports `true`.
const LinkSource = union(enum) {
    formula: i64,
    cask,
};

fn writeLinkedField(w: *std.Io.Writer, extras: Extras, src: LinkSource, db: *sqlite.Database) !void {
    if (!extras.linked) return;
    const is_linked = switch (src) {
        .formula => |keg_id| linker.isKegLinked(db, keg_id),
        .cask => true,
    };
    try w.writeAll(",\"linked\":");
    try w.writeAll(if (is_linked) "true" else "false");
}

fn columnsFor(names: []const []const u8, width: u16) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    try writeColumns(&aw.writer, names, width);
    return aw.toOwnedSlice();
}

test "writeColumns fills column-major: reading down column 1 is names[0..nrows]" {
    const names = [_][]const u8{ "n0", "n1", "n2", "n3", "n4", "n5", "n6" };
    // col_w = 4; width 12 fits exactly 3 columns -> ceil(7/3) = 3 rows.
    const out = try columnsFor(&names, 12);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("n0  n3  n6\nn1  n4\nn2  n5\n", out);
}

test "writeColumns narrower than the longest name degrades to one column" {
    const names = [_][]const u8{ "a-very-long-name", "b" };
    const out = try columnsFor(&names, 4);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a-very-long-name\nb\n", out);
}

test "writeColumns survives a zero width (pty reporting 0 cols)" {
    const names = [_][]const u8{ "a", "b" };
    const out = try columnsFor(&names, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\nb\n", out);
}

test "writeColumns pads to the widest name and never leaves a trailing space" {
    const names = [_][]const u8{ "x", "longer", "yy", "z", "mid" };
    const out = try columnsFor(&names, 80);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("x       longer  yy      z       mid\n", out);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| try std.testing.expect(!std.mem.endsWith(u8, line, " "));
}

test "writeColumns with no names writes nothing" {
    const out = try columnsFor(&.{}, 80);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "writeColumns gives a non-ASCII name its own line so it cannot skew or reorder neighbours" {
    // "café" pads by bytes not cells; U+202E would flip the rest of its row.
    const names = [_][]const u8{ "café", "b", "evil\u{202E}", "d" };
    const out = try columnsFor(&names, 80);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("café\nb\nevil\u{202E}\nd\n", out);
}
