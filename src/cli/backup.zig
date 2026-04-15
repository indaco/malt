//! malt — backup command
//! Dumps the list of currently installed formulae and casks to a plain-text
//! file that `malt restore` can consume to reproduce the environment on
//! another machine.
//!
//! File format (one entry per line):
//!
//!   # comments start with a '#' and are ignored
//!   formula git
//!   formula wget
//!   cask firefox
//!   cask slack
//!
//! An optional `@<version>` suffix is written when `--versions` is passed and
//! honoured by `malt restore`.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const io_mod = @import("../ui/io.zig");
const help = @import("help.zig");

pub const Kind = enum { formula, cask };

/// A parsed backup entry. For entries produced by `parseBackup`, `name` and
/// `version` are slices into the input text and live as long as that text.
pub const Entry = struct {
    kind: Kind,
    name: []const u8,
    version: []const u8,
};

pub const Error = error{
    InvalidArgs,
    DatabaseError,
    OpenFileFailed,
    WriteFailed,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "backup")) return;

    var output_path: ?[]const u8 = null;
    var include_versions = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (i + 1 >= args.len) {
                output.err("--output requires a path argument", .{});
                return Error.InvalidArgs;
            }
            i += 1;
            output_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_path = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--versions")) {
            include_versions = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else {
            output.err("Unknown argument for backup: {s}", .{arg});
            return Error.InvalidArgs;
        }
    }

    // ── Open the database ────────────────────────────────────────────────
    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch
        return Error.DatabaseError;

    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database at {s}", .{db_path});
        return Error.DatabaseError;
    };
    defer db.close();
    schema.initSchema(&db) catch {};

    // ── Serialize into an in-memory buffer ───────────────────────────────
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try writeHeader(w);
    var count: usize = 0;

    // Directly-installed formulae only — dependencies are pulled transitively
    // by `malt install` during restore.
    const formulae_sql =
        "SELECT name, version FROM kegs " ++
        "WHERE install_reason = 'direct' " ++
        "ORDER BY name;";
    var fstmt = db.prepare(formulae_sql) catch null;
    if (fstmt) |*s| {
        defer s.finalize();
        while (s.step() catch false) {
            const name_ptr = s.columnText(0) orelse continue;
            const ver_ptr = s.columnText(1);
            const name = std.mem.sliceTo(name_ptr, 0);
            const version = if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "";
            try writeEntry(w, .formula, name, version, include_versions);
            count += 1;
        }
    }

    var cstmt = db.prepare("SELECT token, version FROM casks ORDER BY token;") catch null;
    if (cstmt) |*s| {
        defer s.finalize();
        while (s.step() catch false) {
            const name_ptr = s.columnText(0) orelse continue;
            const ver_ptr = s.columnText(1);
            const name = std.mem.sliceTo(name_ptr, 0);
            const version = if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "";
            try writeEntry(w, .cask, name, version, include_versions);
            count += 1;
        }
    }

    const bytes = aw.written();

    // ── Resolve destination and write ────────────────────────────────────
    if (output_path) |p| {
        if (std.mem.eql(u8, p, "-")) {
            io_mod.stdoutWriteAll(bytes);
            return;
        }
        try writeToPath(p, bytes);
        output.success("Backup written to {s} ({d} packages)", .{ p, count });
        return;
    }

    const default_path = try defaultBackupPath(allocator);
    defer allocator.free(default_path);
    try writeToPath(default_path, bytes);
    output.success("Backup written to {s} ({d} packages)", .{ default_path, count });
}

fn writeToPath(path: []const u8, bytes: []const u8) Error!void {
    // Create parent directories when the user supplied a nested path.
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) {
            if (std.fs.path.isAbsolute(dir)) {
                std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => {},
                };
            } else {
                std.fs.cwd().makePath(dir) catch {};
            }
        }
    }

    const file = if (std.fs.path.isAbsolute(path))
        std.fs.createFileAbsolute(path, .{ .truncate = true }) catch {
            output.err("Failed to create {s}", .{path});
            return Error.OpenFileFailed;
        }
    else
        std.fs.cwd().createFile(path, .{ .truncate = true }) catch {
            output.err("Failed to create {s}", .{path});
            return Error.OpenFileFailed;
        };
    defer file.close();
    file.writeAll(bytes) catch return Error.WriteFailed;
}

/// Write the canonical header block at the top of a backup file.
pub fn writeHeader(w: anytype) !void {
    try w.writeAll("# malt backup\n");
    try w.writeAll("# Generated by `malt backup`. Restore with `malt restore <file>`.\n");
    try w.writeAll("# Format: one entry per line — `formula <name>` or `cask <token>`.\n");
    try w.writeAll("# Lines starting with `#` are comments and are ignored on restore.\n");
    try w.writeAll("\n");
}

/// Serialize a single entry to `w` in the canonical format.
pub fn writeEntry(w: anytype, kind: Kind, name: []const u8, version: []const u8, include_versions: bool) !void {
    const prefix: []const u8 = switch (kind) {
        .formula => "formula ",
        .cask => "cask ",
    };
    try w.writeAll(prefix);
    try w.writeAll(name);
    if (include_versions and version.len > 0) {
        try w.writeAll("@");
        try w.writeAll(version);
    }
    try w.writeAll("\n");
}

/// Parse a single line. Returns null for blank lines, comments, and any line
/// that does not match the canonical `<kind> <name>[@<version>]` shape.
/// The returned `name` and `version` slices point into `line`.
pub fn parseLine(line: []const u8) ?Entry {
    var s = std.mem.trim(u8, line, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '#') return null;

    var kind: Kind = undefined;
    if (std.mem.startsWith(u8, s, "formula ")) {
        kind = .formula;
        s = std.mem.trim(u8, s["formula ".len..], " \t\r\n");
    } else if (std.mem.startsWith(u8, s, "cask ")) {
        kind = .cask;
        s = std.mem.trim(u8, s["cask ".len..], " \t\r\n");
    } else {
        return null;
    }
    if (s.len == 0) return null;

    var name = s;
    var version: []const u8 = "";
    if (std.mem.findScalar(u8, s, '@')) |idx| {
        name = s[0..idx];
        version = s[idx + 1 ..];
    }
    if (name.len == 0) return null;
    return .{ .kind = kind, .name = name, .version = version };
}

/// Parse an entire backup file into a freshly-allocated slice of entries.
/// The entries reference slices inside `text`, which must outlive them.
/// Callers own the returned slice and must free it via `allocator.free`.
pub fn parseBackup(allocator: std.mem.Allocator, text: []const u8) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (parseLine(line)) |entry| {
            try list.append(allocator, entry);
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Compute a default backup filename of the form
/// `malt-backup-YYYY-MM-DDTHH-MM-SS.txt` in the current working directory.
/// The timestamp uses UTC so two backups taken at the same wall-clock moment
/// collide deterministically across time zones.
pub fn defaultBackupPath(allocator: std.mem.Allocator) ![]u8 {
    const secs = std.time.timestamp();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = @intCast(@max(secs, 0)),
    };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_of_month: u16 = @as(u16, month_day.day_index) + 1;
    return std.fmt.allocPrint(
        allocator,
        "malt-backup-{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}.txt",
        .{
            year_day.year,
            month_day.month.numeric(),
            day_of_month,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}
