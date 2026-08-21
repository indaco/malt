//! malt — list command
//! List installed packages.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const linker = @import("../core/linker.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const dirsize = @import("../fs/dirsize.zig");
const tap_slug = @import("../tap_slug.zig");
const color = @import("../ui/color.zig");
const output = @import("../ui/output.zig");
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
    schema.initSchema(&db) catch return;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = ctx.stdout.writer(ctx.io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};

    if (json_mode) {
        try writeJsonOutput(ctx, &db, prefix, show_formula, show_cask, show_pinned, show_size, show_linked, tap_filter, stdout);
    } else {
        try writeHumanOutput(&db, show_formula, show_cask, show_versions, show_pinned, tap_filter, stdout);
    }
}

/// Pub for tests: assert the exact bytes for the human path without
/// staging a real DB-on-prefix + stdout-capture rig.
///
/// Honours `output.isQuiet()`: under `--quiet` the help text promises
/// "Names only, one per line", so decorations (bullet, version suffix,
/// `[pinned]` tag) are suppressed and each row is a bare name + `\n`.
pub fn writeHumanOutput(
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    show_pinned: bool,
    tap_filter: ?[]const u8,
    stdout: *std.Io.Writer,
) !void {
    const quiet = output.isQuiet();

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
