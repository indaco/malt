//! malt — CLI flag drift guard
//!
//! The house rule is that a new CLI flag reaches help plus all three shells.
//! That rule was a convention with no gate, and completions drifted: flags
//! were advertised that no parser accepted, and real flags never reached a
//! shell.
//!
//! This test derives the truth from the parsers - a flag the code does not
//! accept is provably phantom, which no cross-shell comparison can prove -
//! and diffs it against each completion script. It runs inside
//! `zig build test`, so `just test`, `just pre-push`, `just lint` and the CI
//! `zig build test` step all inherit it with no extra wiring.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");

const completions = malt.completions;

/// Commands whose flags are checked, mapped to the `src/cli` paths that parse
/// them. Only the mapping is hand-maintained; the flags themselves are always
/// derived. A path that disappears fails loudly rather than silently skipping.
const Command = struct {
    name: []const u8,
    sources: []const []const u8,
    /// Commands that hand their argv to another command accept whatever the
    /// delegate accepts, so their completions cannot be checked for phantoms
    /// by scraping their own source.
    delegates: bool = false,
};

const commands = [_]Command{
    .{ .name = "install", .sources = &.{ "install.zig", "install" } },
    .{ .name = "reinstall", .sources = &.{"reinstall.zig"}, .delegates = true },
    .{ .name = "uninstall", .sources = &.{"uninstall.zig"} },
    .{ .name = "upgrade", .sources = &.{ "upgrade.zig", "upgrade" } },
    .{ .name = "outdated", .sources = &.{ "outdated.zig", "outdated" } },
    .{ .name = "list", .sources = &.{"list.zig"} },
    .{ .name = "info", .sources = &.{"info.zig"} },
    .{ .name = "search", .sources = &.{"search.zig"} },
    .{ .name = "uses", .sources = &.{"uses.zig"} },
    .{ .name = "deps", .sources = &.{"deps.zig"} },
    .{ .name = "which", .sources = &.{"which.zig"} },
    .{ .name = "tap", .sources = &.{"tap.zig"} },
    .{ .name = "migrate", .sources = &.{ "migrate.zig", "migrate" } },
    .{ .name = "rollback", .sources = &.{"rollback.zig"} },
    .{ .name = "link", .sources = &.{"link.zig"} },
    .{ .name = "services", .sources = &.{"services.zig"} },
    .{ .name = "bundle", .sources = &.{"bundle.zig"} },
    .{ .name = "run", .sources = &.{"run.zig"} },
    .{ .name = "backup", .sources = &.{"backup.zig"} },
    .{ .name = "restore", .sources = &.{"restore.zig"}, .delegates = true },
    .{ .name = "doctor", .sources = &.{ "doctor.zig", "doctor" } },
    .{ .name = "purge", .sources = &.{ "purge.zig", "purge" } },
    .{ .name = "update", .sources = &.{"update.zig"} },
};

/// Flags consumed centrally in `main.zig` before a command ever sees argv.
/// Per-command help documents them, and the shells offer them globally, so
/// they are not per-command drift.
const global_flags = [_][]const u8{
    "--verbose", "--debug",   "--quiet",
    "--json",    "--dry-run", "--output-format",
    "--help",    "--version", "--offline",
};

/// Deliberate exceptions, each with the reason it is not drift. Kept per
/// `command:flag` and asserted to still be needed, so stale entries fail
/// instead of accumulating.
const Exception = struct {
    command: []const u8,
    flag: []const u8,
    reason: []const u8,
};

const exceptions = [_]Exception{
    // Plural aliases accepted for Homebrew muscle memory. The shells offer the
    // singular canonical spelling on purpose - completing both doubles the
    // candidate list for no gain.
    .{ .command = "list", .flag = "--formulae", .reason = "plural alias; shells offer --formula" },
    .{ .command = "list", .flag = "--casks", .reason = "plural alias; shells offer --cask" },
    .{ .command = "search", .flag = "--formulae", .reason = "plural alias; shells offer --formula" },
    .{ .command = "search", .flag = "--casks", .reason = "plural alias; shells offer --cask" },
    .{ .command = "outdated", .flag = "--formulae", .reason = "plural alias; shells offer --formula" },

    // Advertised but unimplemented. These are real defects the guard found:
    // help and the shells promise a flag no parser reads, so passing it is
    // silently ignored. Listed here so the guard stays green while the
    // implement-or-remove call is made; delete the entry either way.
    .{ .command = "uninstall", .flag = "--zap", .reason = "documented at help.zig but no parser reads it" },
    .{ .command = "upgrade", .flag = "--all", .reason = "documented at help.zig but no parser reads it" },
    .{ .command = "services", .flag = "--system", .reason = "described in a supervisor comment; never implemented" },
};

fn isGlobal(flag: []const u8) bool {
    for (global_flags) |g| if (std.mem.eql(u8, g, flag)) return true;
    return false;
}

fn excepted(command: []const u8, flag: []const u8) bool {
    for (exceptions) |e| {
        if (std.mem.eql(u8, e.command, command) and std.mem.eql(u8, e.flag, flag)) return true;
    }
    return false;
}

const FlagSet = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) FlagSet {
        return .{ .allocator = allocator, .items = .empty };
    }

    fn deinit(self: *FlagSet) void {
        for (self.items.items) |s| self.allocator.free(s);
        self.items.deinit(self.allocator);
    }

    fn has(self: FlagSet, flag: []const u8) bool {
        for (self.items.items) |s| if (std.mem.eql(u8, s, flag)) return true;
        return false;
    }

    fn add(self: *FlagSet, flag: []const u8) !void {
        // Long flags only: short forms are spelled differently in every shell
        // and always accompany a long form in this CLI.
        if (!std.mem.startsWith(u8, flag, "--")) return;
        if (flag.len < 3) return;
        // `--flag=value` and `--flag` are the same flag to a user.
        const base = if (std.mem.indexOfScalar(u8, flag, '=')) |i| flag[0..i] else flag;
        if (isGlobal(base)) return;
        if (self.has(base)) return;
        try self.items.append(self.allocator, try self.allocator.dupe(u8, base));
    }
};

fn stripLineComment(line: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, line, "//") orelse return line;
    return line[0..idx];
}

/// Pull `--flag` literals out of argument-matching lines. Restricting to lines
/// that compare against argv is what keeps unrelated strings (help prose, URLs,
/// error messages) out of the parser set.
fn collectParserFlags(set: *FlagSet, src: []const u8) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = stripLineComment(raw);
        // Two parse idioms in this tree: direct argv comparison, and
        // StaticStringMap entries (`.{ "--cask", .cask },`) used by the
        // bigger commands.
        const matches = std.mem.indexOf(u8, line, "eql(u8,") != null or
            std.mem.indexOf(u8, line, "startsWith(u8,") != null or
            // StaticStringMap entries map a flag to an enum tag (`", .`).
            // Requiring the tag excludes argv literals like
            // `&.{ "--cask", name }`, which forward a flag to another command
            // rather than accepting one.
            (std.mem.indexOf(u8, line, ".{ \"--") != null and
                std.mem.indexOf(u8, line, "\", .") != null);
        if (!matches) continue;

        var rest = line;
        while (std.mem.indexOf(u8, rest, "\"--")) |start| {
            const after = rest[start + 1 ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
            try set.add(after[0..end]);
            rest = after[end..];
        }
    }
}

fn readSourceFlags(allocator: std.mem.Allocator, cmd: Command) !FlagSet {
    var set = FlagSet.init(allocator);
    errdefer set.deinit();

    for (cmd.sources) |entry| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "src/cli/{s}", .{entry});

        if (std.mem.endsWith(u8, entry, ".zig")) {
            const f = try test_io.cwd().openFile(std.Options.debug_io, path, .{});
            defer f.close(std.Options.debug_io);
            const src = try test_io.readFileToEndAlloc(f, allocator, 4 * 1024 * 1024);
            defer allocator.free(src);
            try collectParserFlags(&set, src);
            continue;
        }

        // Directory: every .zig under it belongs to the same command.
        var dir = try test_io.cwd().openDir(std.Options.debug_io, path, .{ .iterate = true });
        defer dir.close(std.Options.debug_io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(std.Options.debug_io)) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.basename, ".zig")) continue;
            const f = try ent.dir.openFile(std.Options.debug_io, ent.basename, .{});
            defer f.close(std.Options.debug_io);
            const src = try test_io.readFileToEndAlloc(f, allocator, 4 * 1024 * 1024);
            defer allocator.free(src);
            try collectParserFlags(&set, src);
        }
    }
    return set;
}

/// The bash per-command flag list. Scoped to the `cmd_flags` table so the
/// earlier positional-completion `case` cannot answer for a command.
fn bashFlags(allocator: std.mem.Allocator, command: []const u8) !FlagSet {
    var set = FlagSet.init(allocator);
    errdefer set.deinit();

    const script = completions.bash_script;
    const table_start = std.mem.indexOf(u8, script, "local cmd_flags=\"\"") orelse
        return error.MissingBashFlagTable;
    const table = script[table_start..];
    const table_end = std.mem.indexOf(u8, table, "esac") orelse return error.MissingBashFlagTable;

    var it = std.mem.splitScalar(u8, table[0..table_end], '\n');
    while (it.next()) |line| {
        const label_at = std.mem.indexOf(u8, line, command) orelse continue;
        // The label must be a whole word ending the case pattern, or `install`
        // matches inside `uninstall|remove)` and inherits its flag list.
        const after_label = line[label_at + command.len ..];
        if (!std.mem.startsWith(u8, after_label, ")") and
            !std.mem.startsWith(u8, after_label, "|")) continue;
        if (label_at > 0) {
            const before = line[label_at - 1];
            if (std.ascii.isAlphanumeric(before) or before == '-') continue;
        }
        var tok = std.mem.tokenizeAny(u8, line, " \"");
        while (tok.next()) |t| try set.add(t);
    }
    return set;
}

/// Locate a zsh `case` label, honouring alias labels like `list|ls)` and
/// `uninstall|remove)`. Matching a bare `<cmd>)` silently returns an empty set
/// for every aliased command, which reads as "no flags" instead of a miss.
fn zshCaseStart(script: []const u8, command: []const u8) ?usize {
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, script, '\n');
    while (it.next()) |line| {
        const line_start = offset;
        offset += line.len + 1;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.endsWith(u8, trimmed, ")")) continue;
        const label = trimmed[0 .. trimmed.len - 1];
        var alt = std.mem.splitScalar(u8, label, '|');
        while (alt.next()) |name| {
            if (std.mem.eql(u8, name, command)) return line_start + line.len;
        }
    }
    return null;
}

fn zshFlags(allocator: std.mem.Allocator, command: []const u8) !FlagSet {
    var set = FlagSet.init(allocator);
    errdefer set.deinit();

    const script = completions.zsh_script;
    const start = zshCaseStart(script, command) orelse return set;
    const body = script[start..];
    const end = std.mem.indexOf(u8, body, ";;") orelse return error.MissingZshCaseEnd;

    var rest = body[0..end];
    // `'--flag[desc]'` and `{--flag,-f}` are the two spellings zsh uses.
    while (std.mem.indexOf(u8, rest, "--")) |i| {
        const after = rest[i..];
        var j: usize = 0;
        while (j < after.len and (std.ascii.isAlphanumeric(after[j]) or
            after[j] == '-' or after[j] == '=')) : (j += 1)
        {}
        try set.add(after[0..j]);
        rest = after[j..];
    }
    return set;
}

fn fishFlags(allocator: std.mem.Allocator, command: []const u8) !FlagSet {
    var set = FlagSet.init(allocator);
    errdefer set.deinit();

    var marker_buf: [64]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "__malt_using_command {s}'", .{command});

    var it = std.mem.splitScalar(u8, completions.fish_script, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) == null) continue;
        const at = std.mem.indexOf(u8, line, " -l ") orelse continue;
        var tok = std.mem.tokenizeAny(u8, line[at + 4 ..], " ");
        const flag = tok.next() orelse continue;
        var buf: [64]u8 = undefined;
        const long = try std.fmt.bufPrint(&buf, "--{s}", .{flag});
        try set.add(long);
    }
    return set;
}

test "every parsed CLI flag reaches all three completion scripts" {
    const alloc = testing.allocator;
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(alloc);

    for (commands) |cmd| {
        var parsed = try readSourceFlags(alloc, cmd);
        defer parsed.deinit();

        var shells = [_]struct { name: []const u8, set: FlagSet }{
            .{ .name = "bash", .set = try bashFlags(alloc, cmd.name) },
            .{ .name = "zsh", .set = try zshFlags(alloc, cmd.name) },
            .{ .name = "fish", .set = try fishFlags(alloc, cmd.name) },
        };
        defer for (&shells) |*s| s.set.deinit();

        for (parsed.items.items) |flag| {
            if (excepted(cmd.name, flag)) continue;
            for (&shells) |*s| {
                if (s.set.has(flag)) continue;
                try report.appendSlice(alloc, "  ");
                try report.appendSlice(alloc, cmd.name);
                try report.appendSlice(alloc, ": ");
                try report.appendSlice(alloc, flag);
                try report.appendSlice(alloc, " parsed but missing from ");
                try report.appendSlice(alloc, s.name);
                try report.append(alloc, '\n');
            }
        }
    }

    if (report.items.len > 0) {
        std.debug.print("CLI flags missing from completions:\n{s}", .{report.items});
        return error.CompletionsMissingFlags;
    }
}

test "no completion advertises a flag the CLI cannot accept" {
    const alloc = testing.allocator;
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(alloc);

    for (commands) |cmd| {
        var parsed = try readSourceFlags(alloc, cmd);
        defer parsed.deinit();

        var shells = [_]struct { name: []const u8, set: FlagSet }{
            .{ .name = "bash", .set = try bashFlags(alloc, cmd.name) },
            .{ .name = "zsh", .set = try zshFlags(alloc, cmd.name) },
            .{ .name = "fish", .set = try fishFlags(alloc, cmd.name) },
        };
        defer for (&shells) |*s| s.set.deinit();

        if (cmd.delegates) continue;

        for (&shells) |*s| {
            for (s.set.items.items) |flag| {
                if (parsed.has(flag)) continue;
                if (excepted(cmd.name, flag)) continue;
                try report.appendSlice(alloc, "  ");
                try report.appendSlice(alloc, cmd.name);
                try report.appendSlice(alloc, ": ");
                try report.appendSlice(alloc, flag);
                try report.appendSlice(alloc, " offered by ");
                try report.appendSlice(alloc, s.name);
                try report.appendSlice(alloc, " but accepted by no parser\n");
            }
        }
    }

    if (report.items.len > 0) {
        std.debug.print("Phantom completion flags:\n{s}", .{report.items});
        return error.PhantomCompletionFlags;
    }
}

test "every exception is still needed" {
    const alloc = testing.allocator;
    for (exceptions) |e| {
        try testing.expect(e.reason.len > 0);
        for (commands) |cmd| {
            if (!std.mem.eql(u8, cmd.name, e.command)) continue;
            var parsed = try readSourceFlags(alloc, cmd);
            defer parsed.deinit();
            var bash = try bashFlags(alloc, cmd.name);
            defer bash.deinit();
            var zsh = try zshFlags(alloc, cmd.name);
            defer zsh.deinit();
            var fish = try fishFlags(alloc, cmd.name);
            defer fish.deinit();
            // An exception that no longer hides a real difference is stale.
            const differs = !parsed.has(e.flag) or
                !bash.has(e.flag) or !zsh.has(e.flag) or !fish.has(e.flag);
            if (!differs) {
                std.debug.print("stale exception: {s}:{s}\n", .{ e.command, e.flag });
                return error.StaleException;
            }
        }
    }
}
