//! Pure argv + path helpers used by `cli/install.zig`. The path/predicate
//! helpers are allocation-free and filesystem-free so tests can call them
//! without fixtures; `parse` is the one exception — it takes the caller's
//! arena to build the package list and split the `--use-system-ruby=` scope.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;

/// Upper bound on MALT_PREFIX byte length. This is a sanity cap, not a
/// correctness gate: the Mach-O relocation pipeline (see
/// `src/core/patch.zig`) grows overflowing load-command slots via
/// `install_name_tool`, so realistic prefixes of any practical length
/// work without preflight rejection. The cap just keeps pathological
/// values from reaching the subprocess.
pub const max_prefix_sane_len: usize = 256;

pub const PrefixError = error{PrefixAbsurd};

/// Reject MALT_PREFIX values past the sanity cap. Exposed so `mt doctor`
/// can reuse the same rule.
pub fn checkPrefixSane(prefix: []const u8) PrefixError!void {
    if (prefix.len > max_prefix_sane_len) return error.PrefixAbsurd;
}

/// True when `arg` resolves to malt itself in any dispatcher-accepted
/// shape: `malt`/`mt`, `<user>/<repo>/malt`, or `*/malt.rb`. The last
/// path segment (with optional `.rb` stripped) is matched against the
/// binary names. `mt update` is the supported upgrade channel.
pub fn isSelfInstall(arg: []const u8) bool {
    const tail = if (std.mem.lastIndexOfScalar(u8, arg, '/')) |i| arg[i + 1 ..] else arg;
    const stem = if (std.mem.endsWith(u8, tail, ".rb")) tail[0 .. tail.len - 3] else tail;
    return std.mem.eql(u8, stem, "malt") or std.mem.eql(u8, stem, "mt");
}

/// Check if a package name is a tap formula (user/repo/formula format).
pub fn isTapFormula(name: []const u8) bool {
    var slash_count: u32 = 0;
    for (name) |ch| {
        if (ch == '/') slash_count += 1;
    }
    return slash_count == 2;
}

/// True when `tap_label` represents one of Homebrew's core taps. Empty
/// or NULL labels also count as core so legacy keg rows that predate
/// the tap-tracking column don't get mis-routed through the tap path.
pub fn isCoreTap(tap_label: []const u8) bool {
    if (tap_label.len == 0) return true;
    if (std.mem.eql(u8, tap_label, "homebrew/core")) return true;
    if (std.mem.eql(u8, tap_label, "homebrew/cask")) return true;
    return false;
}

/// Shape-based detection for a local `.rb` path argument (e.g.
/// `./wget.rb`, `/tmp/wget.rb`, `~/f/wget.rb`, `a/b/c/d.rb`). Pure:
/// no filesystem access, no allocation.
///
/// Tie-break with tap-form: the `.rb` suffix always wins. A bare tap
/// slug `user/repo/formula` has no suffix; `user/repo/formula.rb` is
/// treated as a path so the user does not get a confusing 404 from the
/// tap resolver.
pub fn isLocalFormulaPath(arg: []const u8) bool {
    if (!std.mem.endsWith(u8, arg, ".rb")) return false;
    if (arg.len == 0) return false;
    if (arg[0] == '/' or arg[0] == '~' or arg[0] == '.') return true;
    // Any embedded separator also flags it as a path (e.g. "a/b/c.rb").
    for (arg) |ch| if (ch == '/' or ch == '\\') return true;
    // Bare `wget.rb` with no separator is NOT auto-detected; require
    // `--local` to avoid shadowing a same-named formula on the API.
    return false;
}

/// Parse a tap formula name into user, repo, formula components.
pub fn parseTapName(name: []const u8) ?struct { user: []const u8, repo: []const u8, formula: []const u8 } {
    const first_slash = std.mem.findScalar(u8, name, '/') orelse return null;
    const rest = name[first_slash + 1 ..];
    const second_slash = std.mem.findScalar(u8, rest, '/') orelse return null;
    return .{
        .user = name[0..first_slash],
        .repo = rest[0..second_slash],
        .formula = rest[second_slash + 1 ..],
    };
}

/// True only when `url` is a well-formed `https://` URL with a host
/// component. The local-install path uses this to reject scheme
/// smuggling (file://, ftp://, data:) and downgrade attempts (http://)
/// before we ever hand the URL to the HTTP client. Strict lower-case
/// match keeps the allowlist tamper-resistant; real tap formulas never
/// use mixed-case schemes.
pub fn isAllowedArchiveUrl(url: []const u8) bool {
    const prefix = "https://";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const host_and_path = url[prefix.len..];
    // Reject `https://` with nothing after, or a leading slash that
    // would collapse the authority component.
    if (host_and_path.len == 0) return false;
    if (host_and_path[0] == '/') return false;
    return true;
}

/// Interpolate `#{version}` inside a URL. Falls back to the raw URL if
/// the buffer is too small (bufPrint error) — the caller's SHA check
/// will then fail fast if the server serves a different asset.
pub fn interpolateVersion(buf: []u8, url: []const u8, version: []const u8) []const u8 {
    const version_needle = "#" ++ "{version}";
    if (std.mem.indexOf(u8, url, version_needle)) |pos| {
        const before = url[0..pos];
        const after = url[pos + version_needle.len ..];
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ before, version, after }) catch url;
    }
    return url;
}

/// Interpolate both `#{version}` and `#{arch}` inside a URL. The arch
/// substitution is what cask DSL multi-arch downloads need — without
/// it, the SHA-verified fetch would 404 because the server never sees
/// a real per-arch suffix. Empty `arch_token` is valid (intel rows in
/// real casks routinely set `intel: ""`); the needle is replaced with
/// nothing rather than skipped. Falls back to the raw URL on any
/// bufPrint overflow so the caller's SHA check fails fast on truncation.
pub fn interpolateUrl(
    buf: []u8,
    url: []const u8,
    version: []const u8,
    arch_token: []const u8,
) []const u8 {
    const version_needle = "#" ++ "{version}";
    const arch_needle = "#" ++ "{arch}";
    const has_version = std.mem.indexOf(u8, url, version_needle) != null;
    const has_arch = std.mem.indexOf(u8, url, arch_needle) != null;
    if (!has_version and !has_arch) return url;

    // Walk the URL once and copy verbatim, expanding either needle at
    // its position. A single pass keeps the API allocation-free and
    // immune to nested substitutions (e.g. an arch token that happens
    // to contain `#{version}` literally is left alone).
    var written: usize = 0;
    var i: usize = 0;
    while (i < url.len) {
        if (has_version and std.mem.startsWith(u8, url[i..], version_needle)) {
            if (written + version.len > buf.len) return url;
            @memcpy(buf[written..][0..version.len], version);
            written += version.len;
            i += version_needle.len;
            continue;
        }
        if (has_arch and std.mem.startsWith(u8, url[i..], arch_needle)) {
            if (written + arch_token.len > buf.len) return url;
            @memcpy(buf[written..][0..arch_token.len], arch_token);
            written += arch_token.len;
            i += arch_needle.len;
            continue;
        }
        if (written + 1 > buf.len) return url;
        buf[written] = url[i];
        written += 1;
        i += 1;
    }
    return buf[0..written];
}

/// Expand a leading `~/` to `$HOME/...`. Returns the input unchanged
/// when no tilde prefix is present. Returns null when `$HOME` is
/// needed but unset.
pub fn expandTildePath(ctx: *const AppCtx, buf: []u8, arg: []const u8) ?[]const u8 {
    if (arg.len < 2 or arg[0] != '~' or arg[1] != '/') return arg;
    const home = std.process.Environ.getPosix(ctx.environ, "HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ home, arg[1..] }) catch null;
}

/// The eleven install modes as one typed value object. Populated from
/// argv in `cli/install.zig` and threaded through the phase code so read
/// sites name intent (`flags.fastpathEligible()`) instead of re-deriving
/// boolean algebra inline. Bare bools carry no allocation; `system_ruby`
/// borrows the caller's resolved scope slice.
pub const InstallFlags = struct {
    force_cask: bool = false,
    force_formula: bool = false,
    dry_run: bool = false,
    force: bool = false,
    local_only: bool = false,
    only_deps: bool = false,
    download_only: bool = false,
    isolate_deps: bool = false,
    /// Resolved `--use-system-ruby` scope. Empty means system ruby off.
    system_ruby: []const []const u8 = &.{},

    // ── Derived predicates: the flag interaction, named ───────────────

    /// Eligible for the idempotent fast path that skips DB/lock/HTTP.
    /// Only modes that change install semantics veto it; `download_only`,
    /// `isolate_deps`, and `force_formula` don't reach the fast path gate.
    pub fn fastpathEligible(self: InstallFlags) bool {
        return !self.force and !self.force_cask and !self.local_only and
            !self.dry_run and !self.only_deps;
    }

    /// Whether the `--force` pre-materialize prune should run.
    /// `--download-only` stops before materialize, so pruning then would
    /// delete an installed keg with nothing to repopulate it — download-only
    /// must never mutate the installed cellar.
    pub fn pruneForReinstall(self: InstallFlags) bool {
        return self.force and !self.download_only;
    }

    /// Whether this keg's bins are isolated out of PATH. Direct kegs (the
    /// names the user asked for) are never isolated even under
    /// `--isolate-deps` — the contract isolates transitive deps only.
    pub fn isolatesDep(self: InstallFlags, is_dep: bool) bool {
        return self.isolate_deps and is_dep;
    }
};

/// One variant per argv refusal. Data, not words: the orchestrator maps
/// each to its user-facing `sink.err` line and return code, so the leaf
/// stays UI-agnostic (the `checkPrefixSane` precedent).
pub const ParseError = enum {
    local_requires_path,
    local_with_cask,
    local_with_formula,
    local_with_system_ruby,
    download_only_with_only_deps,
    no_packages,
    self_install,
    ambiguous_system_ruby_scope,
};

/// The validated argv: resolved flags plus the package list. `quiet` /
/// `json` are surfaced (not applied) because touching `output` would break
/// the leaf boundary; `dry_run` here reflects only `--dry-run` in `args`,
/// leaving the global `output.isDryRun()` OR to the caller.
pub const Parsed = struct {
    flags: InstallFlags,
    packages: []const []const u8,
    quiet: bool,
    json: bool,
};

/// A tagged refusal. `arg` borrows into the caller's argv/package slice —
/// the offending package for `self_install`, the first package for
/// `ambiguous_system_ruby_scope`.
pub const Refusal = struct { err: ParseError, arg: []const u8 = "" };

pub const ParseResult = union(enum) {
    ok: Parsed,
    invalid: Refusal,
};

/// The install-contract checks that hold regardless of how the flags were
/// built: a non-empty package list and no self-install. The argv path runs
/// them inside `parse`; the struct-first path (`installAll`) runs the same
/// function in the orchestrator, so both entry points share one guarantee.
/// Pure and allocation-free — the offending name borrows into `packages`.
pub fn checkInstallable(packages: []const []const u8) ?Refusal {
    if (packages.len == 0) return .{ .err = .no_packages };
    // Refuse self-install in every shape the dispatcher accepts; `mt version
    // update` is the supported upgrade channel.
    for (packages) |pkg| {
        if (isSelfInstall(pkg)) return .{ .err = .self_install, .arg = pkg };
    }
    return null;
}

const InstallFlag = enum {
    cask,
    formula,
    dry_run,
    force,
    local,
    use_system_ruby,
    quiet,
    json,
    only_deps,
    download_only,
    isolate_deps,
};

const install_flag_map = std.StaticStringMap(InstallFlag).initComptime(.{
    .{ "--cask", .cask },
    .{ "--formula", .formula },
    .{ "--dry-run", .dry_run },
    .{ "--force", .force },
    .{ "--local", .local },
    .{ "--use-system-ruby", .use_system_ruby },
    .{ "--quiet", .quiet },
    .{ "-q", .quiet },
    .{ "--json", .json },
    .{ "--only-deps", .only_deps },
    // brew-parity alias — `--only-dependencies` is what `brew install`
    // accepts, so muscle memory keeps working alongside the canonical
    // `--only-deps` spelling that mirrors `--isolate-deps`.
    .{ "--only-dependencies", .only_deps },
    .{ "--download-only", .download_only },
    .{ "--isolate-deps", .isolate_deps },
    // Long-form alias — mirrors the `--only-deps` / `--only-dependencies`
    // pair so the flag surface stays predictable.
    .{ "--isolate-dependencies", .isolate_deps },
});

/// Scan + validate the install argv in one place. Returns validated data or
/// a tagged refusal — never a message. `arena` builds the package list and
/// the split `--use-system-ruby=` scope; the caller owns it (the `installAll`
/// contract already threads a run arena).
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!ParseResult {
    var packages: std.ArrayList([]const u8) = .empty;
    var system_ruby: std.ArrayList([]const u8) = .empty;
    var flags: InstallFlags = .{};
    var quiet = false;
    var json = false;
    // A bare `--use-system-ruby` across multiple formulas would let one DSL
    // parse failure silently widen Ruby trust; resolved or rejected below.
    var use_system_ruby_bare = false;

    // StaticStringMap + exhaustive switch: the compiler checks every flag has
    // a handler, so adding a variant without wiring it fails to build.
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--use-system-ruby=")) {
            const list = arg["--use-system-ruby=".len..];
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |name| {
                if (name.len > 0) try system_ruby.append(arena, name);
            }
            continue;
        }
        if (install_flag_map.get(arg)) |flag| switch (flag) {
            .cask => flags.force_cask = true,
            .formula => flags.force_formula = true,
            .dry_run => flags.dry_run = true,
            .force => flags.force = true,
            .local => flags.local_only = true,
            .use_system_ruby => use_system_ruby_bare = true,
            .quiet => quiet = true,
            .json => json = true,
            .only_deps => flags.only_deps = true,
            .download_only => flags.download_only = true,
            .isolate_deps => flags.isolate_deps = true,
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try packages.append(arena, arg);
        }
    }

    if (flags.local_only and packages.items.len == 0) {
        return .{ .invalid = .{ .err = .local_requires_path } };
    }
    // Refuse ambiguous argv so `--local` cannot silently drop another mode.
    if (flags.local_only) {
        if (flags.force_cask) return .{ .invalid = .{ .err = .local_with_cask } };
        if (flags.force_formula) return .{ .invalid = .{ .err = .local_with_formula } };
        if (use_system_ruby_bare or system_ruby.items.len > 0) {
            return .{ .invalid = .{ .err = .local_with_system_ruby } };
        }
    }
    // --only-deps skips the requested package, --download-only skips
    // materialise+link entirely; refuse rather than pick a winner.
    if (flags.download_only and flags.only_deps) {
        return .{ .invalid = .{ .err = .download_only_with_only_deps } };
    }
    // Shared install-contract guard; the struct-first path runs the same one.
    if (checkInstallable(packages.items)) |refusal| return .{ .invalid = refusal };
    // Bare `--use-system-ruby` is only valid for a single formula.
    if (use_system_ruby_bare) {
        if (packages.items.len == 1) {
            try system_ruby.append(arena, packages.items[0]);
        } else {
            return .{ .invalid = .{ .err = .ambiguous_system_ruby_scope, .arg = packages.items[0] } };
        }
    }

    flags.system_ruby = system_ruby.items;
    return .{ .ok = .{ .flags = flags, .packages = packages.items, .quiet = quiet, .json = json } };
}

test "InstallFlags.fastpathEligible: clear when no semantic flag is set" {
    try std.testing.expect((InstallFlags{}).fastpathEligible());
}

test "InstallFlags.fastpathEligible: force/cask/local/dry_run/only_deps each veto it" {
    try std.testing.expect(!(InstallFlags{ .force = true }).fastpathEligible());
    try std.testing.expect(!(InstallFlags{ .force_cask = true }).fastpathEligible());
    try std.testing.expect(!(InstallFlags{ .local_only = true }).fastpathEligible());
    try std.testing.expect(!(InstallFlags{ .dry_run = true }).fastpathEligible());
    try std.testing.expect(!(InstallFlags{ .only_deps = true }).fastpathEligible());
}

test "InstallFlags.fastpathEligible: download_only/isolate_deps/force_formula do NOT gate it" {
    // These three are absent from the fast-path conjunction; the test
    // fails if someone folds one into it and narrows the fast path.
    try std.testing.expect((InstallFlags{ .download_only = true }).fastpathEligible());
    try std.testing.expect((InstallFlags{ .isolate_deps = true }).fastpathEligible());
    try std.testing.expect((InstallFlags{ .force_formula = true }).fastpathEligible());
}

test "InstallFlags.pruneForReinstall: only a plain --force prunes" {
    try std.testing.expect((InstallFlags{ .force = true }).pruneForReinstall());
    try std.testing.expect(!(InstallFlags{}).pruneForReinstall());
    try std.testing.expect(!(InstallFlags{ .download_only = true }).pruneForReinstall());
}

test "InstallFlags.pruneForReinstall: download-only vetoes the force prune" {
    // A --download-only run stops before materialize; pruning then would
    // delete an installed keg with nothing to repopulate it. The
    // !download_only guard is the keg-deletion invariant — this test
    // fails if someone later drops that guard.
    try std.testing.expect(!(InstallFlags{ .force = true, .download_only = true }).pruneForReinstall());
}

test "InstallFlags.isolatesDep: gated on isolate_deps AND is_dep" {
    try std.testing.expect((InstallFlags{ .isolate_deps = true }).isolatesDep(true));
    // A direct keg is never isolated, even under --isolate-deps.
    try std.testing.expect(!(InstallFlags{ .isolate_deps = true }).isolatesDep(false));
    try std.testing.expect(!(InstallFlags{}).isolatesDep(true));
    try std.testing.expect(!(InstallFlags{}).isolatesDep(false));
}

fn expectInvalid(res: ParseResult, want: ParseError) !void {
    switch (res) {
        .ok => return error.TestUnexpectedResult,
        .invalid => |v| try std.testing.expectEqual(want, v.err),
    }
}

test "parse: a bare package name yields ok with default flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parse(arena.allocator(), &.{"wget"});
    switch (res) {
        .invalid => return error.TestUnexpectedResult,
        .ok => |p| {
            try std.testing.expectEqual(@as(usize, 1), p.packages.len);
            try std.testing.expectEqualStrings("wget", p.packages[0]);
            try std.testing.expectEqual(InstallFlags{}, p.flags);
        },
    }
}

test "parse: --local without a path is refused (a .rb path is required)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectInvalid(try parse(arena.allocator(), &.{"--local"}), .local_requires_path);
}

test "parse: --local + --cask is refused (a .rb file is never a cask)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectInvalid(try parse(arena.allocator(), &.{ "--local", "--cask", "./x.rb" }), .local_with_cask);
}

test "parse: --local + --formula is refused (--local already selects formula)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectInvalid(try parse(arena.allocator(), &.{ "--local", "--formula", "./x.rb" }), .local_with_formula);
}

test "parse: --local + --use-system-ruby is refused (local runs no post_install)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectInvalid(try parse(arena.allocator(), &.{ "--local", "--use-system-ruby", "./x.rb" }), .local_with_system_ruby);
}

test "parse: --download-only + --only-deps is refused (they pull opposite ways)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectInvalid(try parse(arena.allocator(), &.{ "wget", "--download-only", "--only-deps" }), .download_only_with_only_deps);
}

test "parse: an empty package list is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectInvalid(try parse(arena.allocator(), &.{"--force"}), .no_packages);
}

test "parse: self-install is refused and carries the offending arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parse(arena.allocator(), &.{"malt"});
    switch (res) {
        .ok => return error.TestUnexpectedResult,
        .invalid => |v| {
            try std.testing.expectEqual(ParseError.self_install, v.err);
            try std.testing.expectEqualStrings("malt", v.arg);
        },
    }
}

test "parse: bare --use-system-ruby with multiple packages needs a scope" {
    // A bare flag across many formulas would let one DSL parse failure
    // silently widen Ruby trust across the rest — refuse and name the
    // first package so the caller can suggest the scoped form.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parse(arena.allocator(), &.{ "--use-system-ruby", "wget", "jq" });
    switch (res) {
        .ok => return error.TestUnexpectedResult,
        .invalid => |v| {
            try std.testing.expectEqual(ParseError.ambiguous_system_ruby_scope, v.err);
            try std.testing.expectEqualStrings("wget", v.arg);
        },
    }
}

test "parse: bare --use-system-ruby folds into scope for a single formula" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parse(arena.allocator(), &.{ "--use-system-ruby", "wget" });
    switch (res) {
        .invalid => return error.TestUnexpectedResult,
        .ok => |p| {
            try std.testing.expectEqual(@as(usize, 1), p.flags.system_ruby.len);
            try std.testing.expectEqualStrings("wget", p.flags.system_ruby[0]);
        },
    }
}

test "parse: --use-system-ruby=<scope> splits the comma list into system_ruby" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parse(arena.allocator(), &.{ "--use-system-ruby=wget,jq", "wget", "jq" });
    switch (res) {
        .invalid => return error.TestUnexpectedResult,
        .ok => |p| {
            try std.testing.expectEqual(@as(usize, 2), p.flags.system_ruby.len);
            try std.testing.expectEqualStrings("wget", p.flags.system_ruby[0]);
            try std.testing.expectEqualStrings("jq", p.flags.system_ruby[1]);
        },
    }
}

test "parse: dry_run reflects only --dry-run, never the global (leaf purity)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const with = try parse(arena.allocator(), &.{ "--dry-run", "wget" });
    switch (with) {
        .invalid => return error.TestUnexpectedResult,
        .ok => |p| try std.testing.expect(p.flags.dry_run),
    }
    // A bare invocation must leave dry_run false even if the process global
    // is on — the OR happens in the caller, not the leaf.
    const without = try parse(arena.allocator(), &.{"wget"});
    switch (without) {
        .invalid => return error.TestUnexpectedResult,
        .ok => |p| try std.testing.expect(!p.flags.dry_run),
    }
}

test "parse: --quiet / --json are surfaced on the result, not applied" {
    // The leaf must not call output.setQuiet/setMode; it reports intent and
    // the orchestrator applies it once, post-parse.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parse(arena.allocator(), &.{ "--quiet", "--json", "wget" });
    switch (res) {
        .invalid => return error.TestUnexpectedResult,
        .ok => |p| {
            try std.testing.expect(p.quiet);
            try std.testing.expect(p.json);
        },
    }
}

test "parse: brew-parity aliases resolve to the same flags as their canonical spelling" {
    // The relocated flag map must keep the long-form + `-q` aliases. A typo in
    // the move would silently route `--only-dependencies` into the package list
    // instead of setting only_deps — this guards the whole moved map.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try parse(arena.allocator(), &.{ "-q", "--only-dependencies", "--isolate-dependencies", "wget" });
    switch (res) {
        .invalid => return error.TestUnexpectedResult,
        .ok => |p| {
            try std.testing.expect(p.quiet);
            try std.testing.expect(p.flags.only_deps);
            try std.testing.expect(p.flags.isolate_deps);
            try std.testing.expectEqual(@as(usize, 1), p.packages.len);
            try std.testing.expectEqualStrings("wget", p.packages[0]);
        },
    }
}

test "checkInstallable: empty list and self-install refused, real names pass" {
    // The shared install-contract guard both the argv path and installAll
    // funnel through; a bundle member named `malt` is refused symmetrically.
    try std.testing.expectEqual(ParseError.no_packages, checkInstallable(&.{}).?.err);
    const refusal = checkInstallable(&.{ "wget", "malt" }).?;
    try std.testing.expectEqual(ParseError.self_install, refusal.err);
    try std.testing.expectEqualStrings("malt", refusal.arg);
    try std.testing.expect(checkInstallable(&.{ "wget", "jq" }) == null);
}

test "isCoreTap recognises homebrew/core and homebrew/cask" {
    try std.testing.expect(isCoreTap("homebrew/core"));
    try std.testing.expect(isCoreTap("homebrew/cask"));
}

test "isCoreTap treats empty string as core (legacy rows)" {
    // Pre-tap-tracking kegs have NULL/empty `tap`; they must keep
    // routing through the core API path.
    try std.testing.expect(isCoreTap(""));
}

test "isCoreTap rejects third-party tap labels" {
    try std.testing.expect(!isCoreTap("user/repo"));
    try std.testing.expect(!isCoreTap("acme/tools"));
    try std.testing.expect(!isCoreTap("homebrew/services"));
}

test "isCoreTap is exact-match (not prefix)" {
    // `homebrew/core-staging` is a hypothetical fork; treat it as third-party.
    try std.testing.expect(!isCoreTap("homebrew/core-staging"));
    try std.testing.expect(!isCoreTap("homebrew/cask-fonts"));
}
