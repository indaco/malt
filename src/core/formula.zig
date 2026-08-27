//! malt — Homebrew formula JSON parser
//! Parses formula metadata from the Homebrew API and selects
//! the correct bottle artifact for the current platform.

const std = @import("std");
const builtin = @import("builtin");

const service_types = @import("services/types.zig");
const cron = @import("services/cron.zig");
const path_component = @import("../fs/path_component.zig");
pub const Schedule = service_types.Schedule;

pub const FormulaError = error{
    InvalidJson,
    MissingField,
    NoBottleAvailable,
    /// `run_type` is neither immediate, interval, nor cron.
    UnknownRunType,
    /// `run_type :interval` with a missing, non-numeric, or out-of-range
    /// `interval`. Never falls back to `.immediate`.
    InvalidInterval,
    /// The embedded `name` or `version` carries a path separator or `..`,
    /// so it would hop out of its on-disk directory component.
    UnsafePathComponent,
};

/// Bottle descriptor for one platform. All three strings live in the
/// parent `Formula._parsed` (either source-borrowed or arena-allocated
/// by the JSON parser); callers that hold a `BottleFile` beyond
/// `Formula.deinit()` must dupe first.
pub const BottleFile = struct {
    cellar: []const u8,
    url: []const u8,
    sha256: []const u8,
};

/// Optional service definition lifted from the upstream Homebrew formula's
/// `service` block. Strings borrow from `Formula._parsed`.
pub const ServiceDef = struct {
    /// Argv passed to launchd's ProgramArguments. Always non-empty when the
    /// service block is present.
    run: []const []const u8,
    working_dir: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    error_log_path: ?[]const u8 = null,
    keep_alive: bool = true,
    schedule: Schedule = .immediate,
};

/// Format Homebrew's canonical on-disk version label into `buf`.
/// `revision > 0` appends `_<revision>` (matching Homebrew's
/// `PkgVersion`); otherwise the plain `version` is returned
/// unchanged. Revisions ≤ 0 are treated as zero — defensive against
/// upstream JSON glitches. Used everywhere a filesystem path under
/// `Cellar/<name>/` is assembled; getting this wrong produces
/// `dyld: Library not loaded` errors because bottles hard-code the
/// full path in LC_LOAD_DYLIB entries.
pub fn pkgVersion(buf: []u8, version: []const u8, revision: i64) ![]const u8 {
    if (revision <= 0) return std.fmt.bufPrint(buf, "{s}", .{version});
    return std.fmt.bufPrint(buf, "{s}_{d}", .{ version, revision });
}

/// A bottle placeholder whose value is a path inside one of the formula's
/// *dependencies*, resolved against the live prefix.
pub const Placeholder = struct {
    token: []const u8,
    value: []const u8,
};

/// Tokens whose value lives in a dependency's keg. A table because the token
/// set is upstream's: adding one is a data change.
const dependency_placeholders = [_]struct {
    token: []const u8,
    dep: []const u8,
    subpath: []const u8,
}{
    .{
        .token = "@@HOMEBREW_JAVA@@",
        .dep = "openjdk",
        .subpath = "libexec/openjdk.jdk/Contents/Home",
    },
};

/// Runtime dependency names from a keg's own `.brew/<name>.rb`, filled into
/// `out`. Callers holding a parsed `Formula` should use its `dependencies`;
/// this is for paths without one, where the DB rows describe a different
/// version than the keg on disk.
pub fn declaredDependencies(out: [][]const u8, rb_source: []const u8) []const []const u8 {
    const total = scanDeclaredDeps(out, rb_source, .runtime);
    // Truncates rather than fails: these callers describe a keg already on
    // disk, where a short list costs a placeholder, not a broken install.
    return out[0..@min(total, out.len)];
}

/// The deps an installer must actually pull in. Also drops `:optional`,
/// which Homebrew installs only when asked — so a plain install that pulled
/// them would exceed what the user requested.
///
/// Separate from `declaredDependencies` on purpose: that one answers "what
/// does this keg link at runtime" for a keg already on disk, and its answer
/// is baked into relocated bytes. Widening it would invalidate every cached
/// relocation to serve a caller that is not asking the same question.
pub fn declaredInstallDependencies(
    out: [][]const u8,
    rb_source: []const u8,
) error{TooManyDependencies}![]const []const u8 {
    const total = scanDeclaredDeps(out, rb_source, .install);
    // Refuses rather than truncates: silently installing a prefix of the list
    // lands a keg missing libraries, which surfaces far from the cause.
    if (total > out.len) return error.TooManyDependencies;
    return out[0..total];
}

/// The `:recommended` subset of `declaredInstallDependencies`. These still get
/// installed; the list only tells the installer whose failure it may downgrade
/// to a warning rather than fail the parent over.
pub fn declaredRecommendedDependencies(
    out: [][]const u8,
    rb_source: []const u8,
) error{TooManyDependencies}![]const []const u8 {
    const total = scanDeclaredDeps(out, rb_source, .recommended);
    if (total > out.len) return error.TooManyDependencies;
    return out[0..total];
}

/// Fill `out` with dependency names. Returns how many were *found*, which may
/// exceed `out.len` — the wrappers above differ only in what they do about that.
/// Which subset of `depends_on` lines a scan keeps.
const DepScan = enum {
    /// Everything the keg links at runtime.
    runtime,
    /// What an installer must pull in; `:optional` is opt-in only.
    install,
    /// The `:recommended` subset - the deps whose absence is survivable.
    recommended,
};

fn scanDeclaredDeps(out: [][]const u8, rb_source: []const u8, scan: DepScan) usize {
    const decl = "depends_on ";
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, rb_source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, decl)) continue;

        // Only the quoted form names a formula; `depends_on :xcode` and
        // friends are platform predicates, not kegs.
        const rest = trimmed[decl.len..];
        if (rest.len == 0 or rest[0] != '"') continue;
        const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse continue;

        // Trailing comments are prose, not markers - a `:recommended` mentioned
        // there once made a required dep's failure look survivable.
        const full_tail = rest[close..];
        const tail = if (std.mem.indexOfScalar(u8, full_tail, '#')) |h| full_tail[0..h] else full_tail;
        if (std.mem.indexOf(u8, tail, ":build") != null) continue;
        switch (scan) {
            .runtime => {},
            .install => if (std.mem.indexOf(u8, tail, ":optional") != null) continue,
            .recommended => if (std.mem.indexOf(u8, tail, ":recommended") == null) continue,
        }

        if (n < out.len) out[n] = rest[1..close];
        n += 1;
    }
    return n;
}

/// A `.rb` past this is not a formula; real ones are a few KB.
pub const max_rb_bytes: u64 = 1024 * 1024;

/// Read a formula's Ruby source at `rb_path`. Caller owns the bytes.
///
/// Null on any failure, and deliberately whole-or-nothing: a truncated Ruby
/// file is still *parseable*, just as a smaller formula. Every caller then
/// gets a plausible wrong answer instead of an error — dropped `depends_on`
/// lines bake the wrong path, and a clipped `post_install` body is one that
/// would run half an installation.
pub fn readFormulaSource(io: std.Io, allocator: std.mem.Allocator, rb_path: []const u8) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, rb_path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > max_rb_bytes) return null;
    const src = allocator.alloc(u8, stat.size) catch return null;
    const read = file.readPositionalAll(io, src, 0) catch 0;
    if (read < src.len) {
        allocator.free(src);
        return null;
    }
    return src;
}

/// The formula source a keg's bottle ships at `<keg_path>/.brew/<name>.rb`,
/// the input `declaredDependencies` parses.
pub fn readKegSource(
    io: std.Io,
    allocator: std.mem.Allocator,
    keg_path: []const u8,
    name: []const u8,
) ?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rb_path = std.fmt.bufPrint(&path_buf, "{s}/.brew/{s}.rb", .{ keg_path, name }) catch return null;
    return readFormulaSource(io, allocator, rb_path);
}

/// Resolve this formula's dependency-scoped placeholder into `buf`.
/// Null when it declares no matching dependency: guessing would bake a path
/// to a keg the formula never asked for.
pub fn dependencyPlaceholder(
    buf: []u8,
    prefix: []const u8,
    dependencies: []const []const u8,
) ?Placeholder {
    for (dependency_placeholders) |entry| {
        for (dependencies) |dep| {
            const pinned = dep.len > entry.dep.len and
                std.mem.startsWith(u8, dep, entry.dep) and
                dep[entry.dep.len] == '@';
            if (!std.mem.eql(u8, dep, entry.dep) and !pinned) continue;
            // Same screen as `perlPlaceholder`: the name becomes a directory
            // component, and withholding beats baking one that hops out of it.
            if (!path_component.isPathComponent(dep)) return null;

            const value = std.fmt.bufPrint(
                buf,
                "{s}/opt/{s}/{s}",
                .{ prefix, dep, entry.subpath },
            ) catch return null;
            return .{ .token = entry.token, .value = value };
        }
    }
    return null;
}

const perl_token = "@@HOMEBREW_PERL@@";
const perl_dep = "perl";

/// Sentinel for "could not read the macOS version"; `systemPerlPath` maps it
/// to the newest interpreter, since a stale versioned path is guaranteed
/// absent while the newest one is right for every macOS malt runs on.
const unknown_macos_major: u32 = std.math.maxInt(u32);

/// Interpreter each macOS release ships. Upstream pins the same versions, so
/// a relocated keg lands byte-identical to a brew-poured one.
fn systemPerlPath(macos_major: u32) []const u8 {
    if (macos_major >= 14) return "/usr/bin/perl5.34"; // Sonoma and later
    if (macos_major >= 11) return "/usr/bin/perl5.30"; // Big Sur and later
    return "/usr/bin/perl5.18";
}

fn macosMajorVersion() u32 {
    var buf: [32]u8 = undefined;
    var len: usize = buf.len;
    if (std.c.sysctlbyname("kern.osproductversion", &buf, &len, null, 0) != 0) return unknown_macos_major;
    const text = std.mem.sliceTo(buf[0..len], 0);
    const major = text[0 .. std.mem.indexOfScalar(u8, text, '.') orelse text.len];
    return std.fmt.parseInt(u32, major, 10) catch unknown_macos_major;
}

/// Resolve `@@HOMEBREW_PERL@@`, which bottles carry in the shebang of every
/// perl script they ship. Never null, unlike `dependencyPlaceholder`: the
/// token lands where the kernel expects an interpreter, so withholding a value
/// leaves an unrunnable script rather than a visible token. A formula that
/// brews perl gets that keg; everything else gets the system interpreter,
/// which is what `uses_from_macos "perl"` asks for.
pub fn perlPlaceholder(
    buf: []u8,
    prefix: []const u8,
    name: []const u8,
    dependencies: []const []const u8,
) Placeholder {
    const brewed: ?[]const u8 = if (isPerl(name)) name else blk: {
        for (dependencies) |dep| {
            if (isPerl(dep)) break :blk dep;
        }
        break :blk null;
    };

    // The name lands as a directory component in the baked path, so it is
    // screened like every other tap-controlled string that reaches disk.
    if (brewed) |dep| brewed_keg: {
        if (!path_component.isPathComponent(dep)) break :brewed_keg;
        const value = std.fmt.bufPrint(buf, "{s}/opt/{s}/bin/perl", .{ prefix, dep }) catch break :brewed_keg;
        return .{ .token = perl_token, .value = value };
    }
    return .{ .token = perl_token, .value = systemPerlPath(macosMajorVersion()) };
}

/// `perl` or a pinned `perl@5.xx`, which installs under its own `opt/` name.
fn isPerl(candidate: []const u8) bool {
    if (std.mem.eql(u8, candidate, perl_dep)) return true;
    return candidate.len > perl_dep.len and
        std.mem.startsWith(u8, candidate, perl_dep) and
        candidate[perl_dep.len] == '@';
}

/// Parsed Homebrew formula. Every `[]const u8` and `[]const []const u8`
/// field is owned by `_parsed` (either borrowed from the JSON source
/// buffer or allocated through the parse arena); valid only until
/// `deinit()`.
pub const Formula = struct {
    /// Borrowed from `_parsed`.
    name: []const u8,
    /// Borrowed from `_parsed`.
    full_name: []const u8,
    /// Borrowed from `_parsed`.
    tap: []const u8,
    /// Borrowed from `_parsed`.
    desc: []const u8,
    /// Borrowed from `_parsed`.
    version: []const u8,
    /// Canonical on-disk version name: equals `version` when
    /// `revision == 0`, else `<version>_<revision>` formatted into the
    /// parse arena. Use this for every Cellar/opt/receipt path — never
    /// raw `version`.
    pkg_version: []const u8,
    revision: i64,
    /// Borrowed from `_parsed` when present.
    license: ?[]const u8,
    /// Borrowed from `_parsed`.
    homepage: []const u8,
    /// Outer slice allocated through `_parsed.arena`; element strings
    /// live in `_parsed`.
    dependencies: []const []const u8,
    keg_only: bool,
    post_install_defined: bool,
    /// True when the formula carries a non-empty declarative
    /// `post_install_steps` array. Migrated formulas report
    /// `post_install_defined: false`, so this is what keeps the
    /// post-install gate open for them. The raw steps stay reachable
    /// through the formula JSON already threaded to the install path.
    has_post_install_steps: bool,
    /// Map storage is allocated through `_parsed.arena`; map keys and
    /// `BottleFile` string fields live in `_parsed`.
    bottle_files: ?std.json.ArrayHashMap(BottleFile),
    /// Borrowed from `_parsed`.
    bottle_root_url: ?[]const u8,
    /// Outer slice allocated through `_parsed.arena`; element strings
    /// live in `_parsed`.
    oldnames: []const []const u8,
    /// Optional launchd service block. Populated when the upstream formula
    /// JSON contains a `service` object with at least a `run` array.
    /// All string fields inside borrow from `_parsed`.
    service: ?ServiceDef = null,

    /// Holds the parsed JSON tree. Must stay alive as long as the Formula
    /// is in use because string fields point into the JSON source buffer.
    _parsed: std.json.Parsed(std.json.Value),

    /// True when installing must run a post-install phase — either the
    /// imperative `def post_install` or the declarative steps array.
    pub fn hasPostInstallHook(self: *const Formula) bool {
        return self.post_install_defined or self.has_post_install_steps;
    }

    pub fn deinit(self: *Formula) void {
        self._parsed.deinit();
    }
};

// Keep in sync with BottleInfo used by other modules.
pub const BottleInfo = BottleFile;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
}

/// Map a service block's `run_type` to a `Schedule`. Absent/`"immediate"`
/// keeps today's run-at-load behaviour; `"interval"` requires a numeric,
/// in-range `interval`; `"cron"` parses its expression into calendar entries;
/// anything else is rejected loudly so a mis-scheduled service never
/// materialises silently. Calendar entries are allocated in `arena`.
fn parseSchedule(arena: std.mem.Allocator, so: std.json.ObjectMap) !Schedule {
    const run_type = getString(so, "run_type") orelse return .immediate;
    if (std.mem.eql(u8, run_type, "immediate")) return .immediate;
    if (std.mem.eql(u8, run_type, "cron")) {
        // A missing `cron` string is a hard error, never a silent fallback.
        const expr = getString(so, "cron") orelse return cron.CronError.CronMalformed;
        return .{ .calendar = try cron.parseCron(arena, expr) };
    }
    if (!std.mem.eql(u8, run_type, "interval")) return FormulaError.UnknownRunType;

    const iv = so.get("interval") orelse return FormulaError.InvalidInterval;
    const secs = switch (iv) {
        .integer => |n| n,
        else => return FormulaError.InvalidInterval,
    };
    if (secs < 1 or secs > service_types.max_interval_secs) return FormulaError.InvalidInterval;
    return .{ .interval = @intCast(secs) };
}

fn getStringArray(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return &.{},
    };
    if (arr.items.len == 0) return &.{};
    const result = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        result[i] = switch (item) {
            .string => |s| s,
            else => "",
        };
    }
    return result;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parse a Homebrew formula JSON blob into a `Formula`.
/// The returned value borrows from the parsed JSON; call `deinit()` when done.
pub fn parseFormula(allocator: std.mem.Allocator, json_data: []const u8) !Formula {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_data,
        .{},
    ) catch return FormulaError.InvalidJson;
    errdefer parsed.deinit();
    // Funnel auxiliary slices through the parse arena so one
    // `_parsed.deinit()` reclaims them; otherwise the outer arrays leak.
    const arena = parsed.arena.allocator();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return FormulaError.InvalidJson,
    };

    // Required string fields
    const name = getString(root, "name") orelse return FormulaError.MissingField;
    // The embedded name never re-passes the requested-name screen yet becomes
    // every keg/cellar/receipt path; full_name is tap-qualified (`/`), so skip.
    if (!path_component.isPathComponent(name)) return FormulaError.UnsafePathComponent;
    const full_name = getString(root, "full_name") orelse name;
    const tap = getString(root, "tap") orelse "";
    const desc = getString(root, "desc") orelse "";
    const homepage = getString(root, "homepage") orelse "";
    const license = getString(root, "license");
    const revision = getInt(root, "revision");
    const keg_only = getBool(root, "keg_only");
    const post_install_defined = getBool(root, "post_install_defined");
    // The steps key is present (empty) on every formula; only a non-empty
    // array marks a steps-migrated hook.
    const has_post_install_steps = blk: {
        const v = root.get("post_install_steps") orelse break :blk false;
        break :blk v == .array and v.array.items.len > 0;
    };

    // versions.stable -> version
    const version_str = blk: {
        const versions_val = root.get("versions") orelse break :blk "";
        const versions_obj = switch (versions_val) {
            .object => |o| o,
            else => break :blk "",
        };
        break :blk getString(versions_obj, "stable") orelse "";
    };
    // version feeds pkg_version → the revision-tagged cellar/keg dir; an empty
    // version is legitimate, but a present one must stay a single component.
    if (version_str.len != 0 and !path_component.isPathComponent(version_str))
        return FormulaError.UnsafePathComponent;

    // dependencies
    const dependencies = try getStringArray(arena, root, "dependencies");

    // oldnames (may be absent)
    const oldnames = try getStringArray(arena, root, "oldnames");

    // service block (optional — Homebrew formulas opt in)
    var service_def: ?ServiceDef = null;
    if (root.get("service")) |sv| {
        if (sv == .object) {
            const so = sv.object;
            const run_val = so.get("run");
            if (run_val) |rv| {
                const items: ?[]std.json.Value = switch (rv) {
                    .array => |a| a.items,
                    .string => |s| blk: {
                        const one = try arena.alloc(std.json.Value, 1);
                        one[0] = .{ .string = s };
                        break :blk one;
                    },
                    else => null,
                };
                if (items) |arr| if (arr.len > 0) {
                    const run = try arena.alloc([]const u8, arr.len);
                    for (arr, 0..) |item, i| {
                        run[i] = switch (item) {
                            .string => |s| s,
                            else => "",
                        };
                    }
                    service_def = .{
                        .run = run,
                        .working_dir = getString(so, "working_dir"),
                        .log_path = getString(so, "log_path"),
                        .error_log_path = getString(so, "error_log_path"),
                        // The API encodes keep_alive as a directive object
                        // (`{"always": true}`, …), not just a bool — treat any
                        // present value as "keep alive" unless it is literally
                        // `false`, which malt renders as no KeepAlive.
                        .keep_alive = if (so.get("keep_alive")) |k|
                            (k != .bool or k.bool)
                        else
                            true,
                        .schedule = try parseSchedule(arena, so),
                    };
                };
            }
        }
    }

    // bottle.stable.root_url and bottle.stable.files
    var bottle_root_url: ?[]const u8 = null;
    var bottle_files: ?std.json.ArrayHashMap(BottleFile) = null;
    if (root.get("bottle")) |bottle_val| {
        if (bottle_val == .object) {
            const bottle_obj = bottle_val.object;
            if (bottle_obj.get("stable")) |stable_val| {
                if (stable_val == .object) {
                    const stable_obj = stable_val.object;
                    bottle_root_url = getString(stable_obj, "root_url");

                    if (stable_obj.get("files")) |files_val| {
                        if (files_val == .object) {
                            const files_obj = files_val.object;
                            var map = std.json.ArrayHashMap(BottleFile){};
                            var it = files_obj.iterator();
                            while (it.next()) |entry| {
                                const platform_name = entry.key_ptr.*;
                                const file_obj = switch (entry.value_ptr.*) {
                                    .object => |o| o,
                                    else => continue,
                                };
                                const bf = BottleFile{
                                    .cellar = getString(file_obj, "cellar") orelse "",
                                    .url = getString(file_obj, "url") orelse continue,
                                    .sha256 = getString(file_obj, "sha256") orelse "",
                                };
                                map.map.put(arena, platform_name, bf) catch continue;
                            }
                            bottle_files = map;
                        }
                    }
                }
            }
        }
    }

    // Pre-compute the revision-aware path label once into the parse
    // arena so every downstream consumer can borrow a stable slice
    // instead of re-formatting per call site.
    const pkg_version_str = blk: {
        if (revision <= 0) break :blk version_str;
        break :blk try std.fmt.allocPrint(arena, "{s}_{d}", .{ version_str, revision });
    };

    return Formula{
        .name = name,
        .full_name = full_name,
        .tap = tap,
        .desc = desc,
        .version = version_str,
        .pkg_version = pkg_version_str,
        .revision = revision,
        .license = license,
        .homepage = homepage,
        .dependencies = dependencies,
        .keg_only = keg_only,
        .post_install_defined = post_install_defined,
        .has_post_install_steps = has_post_install_steps,
        .bottle_files = bottle_files,
        .bottle_root_url = bottle_root_url,
        .oldnames = oldnames,
        .service = service_def,
        ._parsed = parsed,
    };
}

// ---------------------------------------------------------------------------
// Bottle selection
// ---------------------------------------------------------------------------

/// macOS version codenames in descending order (newest first).
const macos_arm64_platforms = [_][]const u8{
    "arm64_tahoe",
    "arm64_sequoia",
    "arm64_sonoma",
    "arm64_ventura",
    "arm64_monterey",
};

const macos_x86_platforms = [_][]const u8{
    "tahoe",
    "sequoia",
    "sonoma",
    "ventura",
    "monterey",
};

/// Select the best matching bottle for the current platform.
pub fn resolveBottle(formula: *const Formula) !BottleFile {
    const files = formula.bottle_files orelse return FormulaError.NoBottleAvailable;

    const candidates: []const []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &macos_arm64_platforms,
        .x86_64 => &macos_x86_platforms,
        else => &macos_arm64_platforms,
    };

    // Try each platform candidate in preference order
    for (candidates) |platform| {
        if (files.map.get(platform)) |bf| {
            return bf;
        }
    }

    // Fallback: "all" (used by some header-only / arch-independent bottles)
    if (files.map.get("all")) |bf| {
        return bf;
    }

    return FormulaError.NoBottleAvailable;
}

// ---------------------------------------------------------------------------
// Alias resolution
// ---------------------------------------------------------------------------

/// Check whether `name` is an old name for the formula described by `json_data`.
/// If so, return the formula's canonical name. Otherwise return null.
pub fn resolveAlias(allocator: std.mem.Allocator, name: []const u8, json_data: []const u8) !?[]const u8 {
    var formula = try parseFormula(allocator, json_data);
    defer formula.deinit();

    for (formula.oldnames) |oldname| {
        if (std.mem.eql(u8, oldname, name)) {
            // Dupe so caller owns the returned string beyond formula lifetime.
            return try allocator.dupe(u8, formula.name);
        }
    }

    return null;
}

/// Inverse of `pkgVersion`. Returns the upstream version slice (borrowed
/// from `label`) and the trailing revision integer. Anything that isn't
/// a strict `<…>_<digits>` suffix is treated as part of the version
/// (e.g. Homebrew-style `0.1.0_p1`), so the round-trip
/// `pkgVersion(parsePkgVersion(s)) == s` only holds for labels this
/// tool actually emits.
pub const ParsedPkgVersion = struct { version: []const u8, revision: i64 };

pub fn parsePkgVersion(label: []const u8) ParsedPkgVersion {
    const us = std.mem.lastIndexOfScalar(u8, label, '_') orelse
        return .{ .version = label, .revision = 0 };
    const tail = label[us + 1 ..];
    if (tail.len == 0) return .{ .version = label, .revision = 0 };
    const rev = std.fmt.parseInt(i64, tail, 10) catch
        return .{ .version = label, .revision = 0 };
    if (rev < 0) return .{ .version = label, .revision = 0 };
    return .{ .version = label[0..us], .revision = rev };
}

/// Direction of a version move, installed → upstream. `incomparable` is
/// load-bearing: a caller acting on `older` never acts on a guess.
pub const Rel = enum { older, same, newer, incomparable };

/// Which way upstream moved relative to what is installed, or decline.
/// Advisory: `outdated` still triggers on byte inequality, so a wrong
/// answer here mislabels a row and can never hide an upgrade. No
/// pre-release ranking table — measured over real Homebrew transitions it
/// buys almost nothing and costs confident wrong answers.
pub fn relate(installed: []const u8, upstream: []const u8) Rel {
    if (std.mem.eql(u8, installed, upstream)) return .same;

    const a = parsePkgVersion(installed);
    const b = parsePkgVersion(upstream);
    return switch (relateVersion(a.version, b.version)) {
        .same => if (b.revision > a.revision)
            .newer
        else if (b.revision < a.revision)
            .older
        else
            .same,
        .older => .older,
        .newer => .newer,
        .incomparable => .incomparable,
    };
}

/// Walk both versions in runs of digits and non-digits. Digit runs
/// compare numerically; a differing non-digit run gives up.
fn relateVersion(a: []const u8, b: []const u8) Rel {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const digits = std.ascii.isDigit(a[i]);
        if (digits != std.ascii.isDigit(b[j])) return .incomparable;

        const a_end = runEnd(a, i, digits);
        const b_end = runEnd(b, j, digits);
        if (digits) {
            switch (compareDigitRun(a[i..a_end], b[j..b_end])) {
                .lt => return .newer,
                .gt => return .older,
                .eq => {},
            }
        } else if (!std.mem.eql(u8, a[i..a_end], b[j..b_end])) return .incomparable;

        i = a_end;
        j = b_end;
    }
    if (i == a.len and j == b.len) return .same;

    // A tail with letters is a pre-release marker this refuses to rank; an
    // all-zero tail is the padding Homebrew applies anyway (`1.0` is `1.0.0`).
    const tail = if (i < a.len) a[i..] else b[j..];
    var significant = false;
    for (tail) |c| {
        if (std.ascii.isAlphabetic(c)) return .incomparable;
        if (std.ascii.isDigit(c) and c != '0') significant = true;
    }
    if (!significant) return .same;
    return if (i < a.len) .older else .newer;
}

fn runEnd(s: []const u8, start: usize, digits: bool) usize {
    var k = start;
    while (k < s.len and std.ascii.isDigit(s[k]) == digits) k += 1;
    return k;
}

/// Numeric order without parsing, so a long run (a date stamp) cannot
/// overflow.
fn compareDigitRun(a: []const u8, b: []const u8) std.math.Order {
    const x = std.mem.trimStart(u8, a, "0");
    const y = std.mem.trimStart(u8, b, "0");
    if (x.len != y.len) return std.math.order(x.len, y.len);
    return std.mem.order(u8, x, y);
}

/// Three-state currency verdict, installed vs upstream.
pub const Currency = enum { current, differs, unprovable };

/// The single policy behind "is this installed keg current?": qualify the
/// installed (version, revision) pair and byte-compare it to the already
/// revision-qualified `upstream`. malt mirrors the tap as the source of truth,
/// so it follows a move in BOTH directions; any inequality is `differs`, never
/// a silent "upstream is newer so we are fine". `unprovable` means the installed
/// version overflowed pkgVersion's buffer: a caller must treat it as not-current
/// (never skip a real upgrade), never as `current`.
///
/// The one anchor for the compare that used to be copy-pasted across the
/// outdated audit, the per-package fetch fallbacks, and the upgrade walks.
pub fn isCurrent(installed_version: []const u8, installed_revision: i64, upstream: []const u8) Currency {
    var buf: [256]u8 = undefined;
    const installed = pkgVersion(&buf, installed_version, installed_revision) catch return .unprovable;
    return if (std.mem.eql(u8, installed, upstream)) .current else .differs;
}

const testing = std.testing;

test "relate reads an ordinary forward move as newer" {
    // The overwhelmingly common case; multi-digit and date-stamped runs
    // both have to compare numerically rather than byte-wise.
    try testing.expectEqual(Rel.newer, relate("1.9", "1.10"));
    try testing.expectEqual(Rel.newer, relate("1.2.3", "1.2.4"));
    try testing.expectEqual(Rel.newer, relate("20240115", "20240116"));
}

test "relate lets the revision decide when the versions match" {
    // Keeps the comparator agreeing with `pkgVersion`'s own output.
    try testing.expectEqual(Rel.same, relate("1.2.3", "1.2.3"));
    try testing.expectEqual(Rel.newer, relate("1.2.3", "1.2.3_1"));
    try testing.expectEqual(Rel.older, relate("1.2.3_2", "1.2.3_1"));
}

test "relate reads a yanked release as older" {
    // A real pip-audit transition: the event this whole signal exists for.
    try testing.expectEqual(Rel.older, relate("2.4.15", "2.4.14"));
}

test "isCurrent qualifies the installed revision before comparing" {
    // A revision-only bump must read as `differs`, not a bare match, or a
    // 1.2.3 -> 1.2.3_1 upgrade would be silently skipped.
    try testing.expectEqual(Currency.current, isCurrent("1.2.3", 0, "1.2.3"));
    try testing.expectEqual(Currency.current, isCurrent("1.2.3", 1, "1.2.3_1"));
    try testing.expectEqual(Currency.differs, isCurrent("1.2.3", 0, "1.2.3_1"));
}

test "isCurrent follows the tap in both directions" {
    // A yank (upstream moves backward) is still `differs`: malt mirrors the tap,
    // so it never reads "we are newer" as up to date.
    try testing.expectEqual(Currency.differs, isCurrent("2.4.15", 0, "2.4.14"));
}

test "isCurrent declines to prove currency on an overflowing version" {
    // pkgVersion overflows past 256 bytes; the safe answer is `unprovable`, which
    // callers route to a re-check, never to `current`.
    const long = "1." ** 200;
    try testing.expectEqual(Currency.unprovable, isCurrent(long, 3, "whatever"));
}

test "relate catches a mistyped bump" {
    // A real llvm transition nobody intended, which review did not catch.
    try testing.expectEqual(Rel.older, relate("19.1.3", "1.19.4"));
}

test "relate gives up rather than rank pre-release markers" {
    // Ranking these is the tempting mistake: a wrong answer would turn a
    // legitimate upgrade into a false alarm.
    try testing.expectEqual(Rel.incomparable, relate("1.0rc2", "1.0"));
    try testing.expectEqual(Rel.incomparable, relate("1.0", "1.0beta"));
}

test "relate misreads a date-scheme change as older" {
    // A real minio transition, pinned deliberately: both sides open with a
    // digit run, so the walk answers confidently and wrongly. Recorded so
    // nobody "fixes" it by accident; nothing blocks on the label.
    try testing.expectEqual(Rel.older, relate("20250312180418", "2025-04-03T14-56-28Z"));
}

test "relate treats a zero-padded tail as the same version" {
    // Homebrew pads a missing component with zero, so `1.0` and `1.0.0` are
    // one version. Reading the longer side as newer would cry downgrade on a
    // tap that merely dropped a trailing `.0`.
    try testing.expectEqual(Rel.same, relate("1.0.0", "1.0"));
    try testing.expectEqual(Rel.same, relate("1.0", "1.0.0"));
    try testing.expectEqual(Rel.newer, relate("1.2", "1.2.3"));
    try testing.expectEqual(Rel.older, relate("1.2.3", "1.2"));
}

test "relate ignores leading zeros inside a component" {
    try testing.expectEqual(Rel.same, relate("1.02", "1.2"));
    try testing.expectEqual(Rel.newer, relate("1.02", "1.10"));
}

test "relate declines when the two sides start with different run kinds" {
    // Also the empty-label guard: nothing here may index past an end.
    try testing.expectEqual(Rel.incomparable, relate("1.0", "v1.0"));
    try testing.expectEqual(Rel.incomparable, relate("", "beta"));
    try testing.expectEqual(Rel.newer, relate("", "1.0"));
}

test "relate reads the version before the revision" {
    // A revision bump never rescues a version that moved backward.
    try testing.expectEqual(Rel.older, relate("1.2.4", "1.2.3_5"));
}

test "relate answers the same question both ways round" {
    // Swapping the arguments must mirror the answer, never invent or lose
    // one: `upgrade` reads the pair in the opposite order from `outdated`.
    const pairs = [_][2][]const u8{
        .{ "1.9", "1.10" },        .{ "1.2.3", "1.2.3_1" },
        .{ "2.4.15", "2.4.14" },   .{ "1.0rc2", "1.0" },
        .{ "1.0.0", "1.0" },       .{ "1.2.3,4567", "1.2.4,4600" },
        .{ "20240115", "2024-1" }, .{ "", "1.0" },
    };
    for (pairs) |p| {
        const forward = relate(p[0], p[1]);
        const back = relate(p[1], p[0]);
        try testing.expectEqual(switch (forward) {
            .older => Rel.newer,
            .newer => Rel.older,
            .same => Rel.same,
            .incomparable => Rel.incomparable,
        }, back);
    }
}

test "relate misreads a dropped cask build suffix as older" {
    // Measured at 7 in 54,850 real cask transitions. Special-casing it would
    // grow the comparator for a rounding error, so it is recorded, not fixed.
    try testing.expectEqual(Rel.older, relate("1.4.3,167", "1.4.3"));
}

test "relate walks cask-shaped build suffixes" {
    // The `,build` comma is an identical non-digit run and must not block.
    try testing.expectEqual(Rel.newer, relate("1.2.3,4567", "1.2.4,4600"));
}

test "parsePkgVersion splits revision suffix" {
    const r = parsePkgVersion("1.9.2_2");
    try testing.expectEqualStrings("1.9.2", r.version);
    try testing.expectEqual(@as(i64, 2), r.revision);
}

test "parsePkgVersion treats no-suffix as revision zero" {
    const r = parsePkgVersion("1.0.0");
    try testing.expectEqualStrings("1.0.0", r.version);
    try testing.expectEqual(@as(i64, 0), r.revision);
}

test "parsePkgVersion preserves non-numeric underscore tails" {
    // Homebrew patch-level versions like `0.1.0_p1` are part of the
    // upstream version, not a revision bump.
    const r = parsePkgVersion("0.1.0_p1");
    try testing.expectEqualStrings("0.1.0_p1", r.version);
    try testing.expectEqual(@as(i64, 0), r.revision);
}

test "parsePkgVersion round-trips with pkgVersion" {
    var buf: [64]u8 = undefined;
    const formatted = try pkgVersion(&buf, "3.14.4", 1);
    const r = parsePkgVersion(formatted);
    try testing.expectEqualStrings("3.14.4", r.version);
    try testing.expectEqual(@as(i64, 1), r.revision);
}

test "parseFormula rejects path separators in embedded name or version" {
    // `name` and `version` become on-disk directory components (keg, cellar,
    // receipt, service label); the JSON's own fields never re-pass the
    // fetch-time name screen, so parse must reject a component-hopping value.
    const bad = [_][]const u8{
        \\{"name":"../evil","versions":{"stable":"1.0"}}
        ,
        \\{"name":"a/b","versions":{"stable":"1.0"}}
        ,
        \\{"name":".","versions":{"stable":"1.0"}}
        ,
        \\{"name":"..","versions":{"stable":"1.0"}}
        ,
        \\{"name":"foo/","versions":{"stable":"1.0"}}
        ,
        \\{"name":"a\u0000b","versions":{"stable":"1.0"}}
        ,
        \\{"name":"ok","versions":{"stable":"../1.0"}}
        ,
        \\{"name":"ok","versions":{"stable":"1..0"}}
        ,
    };
    for (bad) |json| {
        try testing.expectError(FormulaError.UnsafePathComponent, parseFormula(testing.allocator, json));
    }

    // Real names/versions carry `@`, `+`, dots — charset-agnostic, must pass.
    const ok =
        \\{"name":"openssl@3","versions":{"stable":"3.2.1+dfsg"}}
    ;
    var formula = try parseFormula(testing.allocator, ok);
    defer formula.deinit();
    try testing.expectEqualStrings("openssl@3", formula.name);

    // A formula with no stable version parses to an empty version, unchanged.
    const nover =
        \\{"name":"nostable","versions":{}}
    ;
    var f2 = try parseFormula(testing.allocator, nover);
    defer f2.deinit();
    try testing.expectEqualStrings("", f2.version);
}

test "parseFormula flags a formula migrated to post_install_steps" {
    // Migrated formulas report post_install_defined=false and carry the
    // hook in a declarative steps array; the steps are what must keep the
    // install gate open, or post-install silently never runs.
    const json =
        \\{"name":"gdk-pixbuf","versions":{"stable":"2.44.3"},"post_install_defined":false,"post_install_steps":[{"type":"gdk_pixbuf_query_loaders"}]}
    ;
    var formula = try parseFormula(testing.allocator, json);
    defer formula.deinit();
    try testing.expect(!formula.post_install_defined);
    try testing.expect(formula.has_post_install_steps);
    try testing.expect(formula.hasPostInstallHook());
}

test "parseFormula ignores an empty post_install_steps array" {
    // The key is present (empty) on every formula; ca-certificates ships
    // post_install_defined=true with steps=[] — empty must not count.
    const json =
        \\{"name":"ca-certificates","versions":{"stable":"2026-07-01"},"post_install_defined":true,"post_install_steps":[]}
    ;
    var formula = try parseFormula(testing.allocator, json);
    defer formula.deinit();
    try testing.expect(!formula.has_post_install_steps);
    try testing.expect(formula.hasPostInstallHook());
}

test "parseFormula treats an absent post_install_steps key as no hook" {
    const json =
        \\{"name":"plain","versions":{"stable":"1.0"},"post_install_defined":false}
    ;
    var formula = try parseFormula(testing.allocator, json);
    defer formula.deinit();
    try testing.expect(!formula.has_post_install_steps);
    try testing.expect(!formula.hasPostInstallHook());
}

test "parseFormula releases every auxiliary allocation through deinit" {
    // testing.allocator (no arena wrapper) trips on any auxiliary slice
    // that escapes _parsed: dependencies, oldnames, service.run,
    // bottle_files map storage, and the revision-bumped pkg_version.
    const json =
        \\{"name":"alpha","full_name":"alpha","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":2,"keg_only":false,"post_install_defined":false,"versions":{"stable":"1.0"},"dependencies":["beta","gamma"],"oldnames":["alpha-old"],"service":{"run":["/usr/bin/alpha","--daemon"]},"bottle":{"stable":{"root_url":"https://example.test","files":{"arm64_sequoia":{"cellar":"/opt","url":"https://example.test/a","sha256":"deadbeef"}}}}}
    ;
    var formula = try parseFormula(testing.allocator, json);
    defer formula.deinit();
    try testing.expectEqualStrings("1.0_2", formula.pkg_version);
    try testing.expectEqual(@as(usize, 2), formula.dependencies.len);
    try testing.expectEqual(@as(usize, 1), formula.oldnames.len);
    try testing.expect(formula.service != null);
    try testing.expect(formula.bottle_files != null);
}

test "dependencyPlaceholder resolves a token against its declared dependency" {
    // Wrappers that carry the token are unrunnable until it is substituted,
    // and the value is a path into the dependency's keg, not the prefix.
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{ "openjdk", "ca-certificates" };
    const got = dependencyPlaceholder(&buf, "/opt/malt", &deps).?;
    try testing.expectEqualStrings("@@HOMEBREW_JAVA@@", got.token);
    try testing.expectEqualStrings(
        "/opt/malt/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
        got.value,
    );
}

test "dependencyPlaceholder keeps the version suffix of a pinned dependency" {
    // A pinned variant installs under its own opt/ name; folding it onto the
    // unpinned one would point the wrapper at a keg the formula didn't ask for.
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{"openjdk@21"};
    const got = dependencyPlaceholder(&buf, "/opt/malt", &deps).?;
    try testing.expectEqualStrings(
        "/opt/malt/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home",
        got.value,
    );
}

test "dependencyPlaceholder declines a formula with no matching dependency" {
    // Most bottles carry no such token; substituting a guessed value would
    // be worse than leaving them alone.
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{ "pcre2", "zstd" };
    try testing.expect(dependencyPlaceholder(&buf, "/opt/malt", &deps) == null);
}

/// Per-PID path: a fixed `/tmp` name races concurrent test binaries.
fn kegSourceFixture(io: std.Io, tag: []const u8, body: []const u8) ![]u8 {
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const keg = try std.fmt.allocPrint(testing.allocator, "/tmp/malt_keg_src_{s}_{s}", .{ hex[0..], tag });
    errdefer testing.allocator.free(keg);

    const brew_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.brew", .{keg});
    defer testing.allocator.free(brew_dir);
    try std.Io.Dir.cwd().createDirPath(io, brew_dir);

    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/pkg.rb", .{brew_dir});
    defer testing.allocator.free(rb);
    const f = try std.Io.Dir.createFileAbsolute(io, rb, .{});
    try f.writeStreamingAll(io, body);
    f.close(io);
    return keg;
}

test "readKegSource returns the formula source a bottle ships" {
    const io = std.Options.debug_io;
    const body = "class Pkg < Formula\n  depends_on \"perl\"\nend\n";
    const keg = try kegSourceFixture(io, "ok", body);
    defer {
        std.Io.Dir.cwd().deleteTree(io, keg) catch {};
        testing.allocator.free(keg);
    }

    const src = readKegSource(io, testing.allocator, keg, "pkg").?;
    defer testing.allocator.free(src);
    try testing.expectEqualStrings(body, src);

    // The whole point of the read: it feeds the dependency parse.
    var out: [8][]const u8 = undefined;
    const deps = declaredDependencies(&out, src);
    try testing.expectEqual(@as(usize, 1), deps.len);
    try testing.expectEqualStrings("perl", deps[0]);
}

test "readKegSource declines a keg that ships no formula source" {
    // A local-Cellar copy or hand-dropped tree has no `.brew/`; callers read
    // that as "declares nothing", never as a hard failure.
    const io = std.Options.debug_io;
    try testing.expect(readKegSource(io, testing.allocator, "/nonexistent/keg", "pkg") == null);
}

test "readKegSource declines a name that is not the keg's own formula" {
    const io = std.Options.debug_io;
    const keg = try kegSourceFixture(io, "wrongname", "class Pkg < Formula\nend\n");
    defer {
        std.Io.Dir.cwd().deleteTree(io, keg) catch {};
        testing.allocator.free(keg);
    }
    try testing.expect(readKegSource(io, testing.allocator, keg, "other") == null);
}

test "readKegSource declines an empty formula source" {
    // Zero bytes parses to zero dependencies either way, but it means the
    // bottle is malformed — say so rather than resolving against a guess.
    const io = std.Options.debug_io;
    const keg = try kegSourceFixture(io, "empty", "");
    defer {
        std.Io.Dir.cwd().deleteTree(io, keg) catch {};
        testing.allocator.free(keg);
    }
    try testing.expect(readKegSource(io, testing.allocator, keg, "pkg") == null);
}

test "perlPlaceholder points at the keg of a brewed perl" {
    // A formula that depends on perl directly must run under that keg's
    // interpreter, not the system one it was never built against.
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{ "perl", "libpng" };
    const got = perlPlaceholder(&buf, "/opt/malt", "imagemagick", &deps);
    try testing.expectEqualStrings("@@HOMEBREW_PERL@@", got.token);
    try testing.expectEqualStrings("/opt/malt/opt/perl/bin/perl", got.value);
}

test "perlPlaceholder keeps the version suffix of a pinned perl" {
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{"perl@5.40"};
    const got = perlPlaceholder(&buf, "/opt/malt", "pkg", &deps);
    try testing.expectEqualStrings("/opt/malt/opt/perl@5.40/bin/perl", got.value);
}

test "perlPlaceholder resolves perl itself against its own keg" {
    // `perl` declares no perl dependency, yet its own scripts carry the token.
    var buf: [256]u8 = undefined;
    const got = perlPlaceholder(&buf, "/opt/malt", "perl", &.{});
    try testing.expectEqualStrings("/opt/malt/opt/perl/bin/perl", got.value);
}

test "perlPlaceholder falls back to the system interpreter" {
    // Never null: an unresolved shebang is an unrunnable script, so the
    // interpreter macOS ships is the answer when nothing brews one.
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{ "cmake", "zstd" };
    const got = perlPlaceholder(&buf, "/opt/malt", "exiftool", &deps);
    try testing.expect(std.mem.startsWith(u8, got.value, "/usr/bin/perl"));
}

test "perlPlaceholder refuses a dependency name that hops out of its directory" {
    // The name is interpolated as a path component. A bottle's own .rb is the
    // source, so this is malformed input rather than an attack — but baking
    // the traversal would put an arbitrary path in a shebang.
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{"perl@../../../evil"};
    const got = perlPlaceholder(&buf, "/opt/malt", "pkg", &deps);
    try testing.expect(std.mem.startsWith(u8, got.value, "/usr/bin/perl"));
}

test "dependencyPlaceholder withholds a dependency name that hops out of its directory" {
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{"openjdk@../../.."};
    try testing.expect(dependencyPlaceholder(&buf, "/opt/malt", &deps) == null);
}

test "perlPlaceholder ignores a dependency that merely starts with perl" {
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{"perl-xml"};
    const got = perlPlaceholder(&buf, "/opt/malt", "pkg", &deps);
    try testing.expect(std.mem.startsWith(u8, got.value, "/usr/bin/perl"));
}

test "systemPerlPath tracks the interpreter each macOS release ships" {
    try testing.expectEqualStrings("/usr/bin/perl5.34", systemPerlPath(26));
    try testing.expectEqualStrings("/usr/bin/perl5.34", systemPerlPath(14));
    try testing.expectEqualStrings("/usr/bin/perl5.30", systemPerlPath(13));
    try testing.expectEqualStrings("/usr/bin/perl5.30", systemPerlPath(11));
    try testing.expectEqualStrings("/usr/bin/perl5.18", systemPerlPath(10));
    // An unreadable version reads as "current": a stale path is guaranteed
    // absent on a modern system, the newest one is right for every macOS
    // malt runs on.
    try testing.expectEqualStrings("/usr/bin/perl5.34", systemPerlPath(unknown_macos_major));
}

test "perlPlaceholder falls back to the system interpreter when the buffer is too small" {
    var buf: [4]u8 = undefined;
    const got = perlPlaceholder(&buf, "/opt/malt", "perl", &.{});
    try testing.expect(std.mem.startsWith(u8, got.value, "/usr/bin/perl"));
}

test "declaredDependencies reads the names a keg's own formula source declares" {
    var out: [8][]const u8 = undefined;
    const src =
        \\class Benerator < Formula
        \\  desc "x"
        \\  depends_on "openjdk@11"
        \\  depends_on "zstd"
        \\end
    ;
    const got = declaredDependencies(&out, src);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("openjdk@11", got[0]);
    try testing.expectEqualStrings("zstd", got[1]);
}

test "declaredDependencies skips build-only dependencies" {
    // Parity with the API `dependencies` field the install path uses: a
    // build-only jdk is not present at runtime, so resolving a token against
    // it would point at a keg that need not exist.
    var out: [8][]const u8 = undefined;
    const got = declaredDependencies(&out,
        \\  depends_on "cmake" => :build
        \\  depends_on "openjdk"
    );
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("openjdk", got[0]);
}

test "declaredInstallDependencies keeps recommended deps but drops optional ones" {
    // Homebrew installs `:recommended` by default and `:optional` only on
    // request; an installer that pulled the latter would exceed the ask.
    var out: [8][]const u8 = undefined;
    const got = try declaredInstallDependencies(&out,
        \\  depends_on "ffmpeg" => :recommended
        \\  depends_on "lua" => :optional
        \\  depends_on "cmake" => :build
        \\  depends_on "flac"
    );
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("ffmpeg", got[0]);
    try testing.expectEqualStrings("flac", got[1]);
}

test "declaredInstallDependencies refuses a list longer than the buffer" {
    // Installing a silent prefix of the list lands a keg missing libraries,
    // and the failure then surfaces far from its cause.
    const src =
        \\  depends_on "dep0"
        \\  depends_on "dep1"
        \\  depends_on "dep2"
        \\  depends_on "dep3"
        \\  depends_on "dep4"
    ;

    var small: [4][]const u8 = undefined;
    try testing.expectError(
        error.TooManyDependencies,
        declaredInstallDependencies(&small, src),
    );

    // Exactly at capacity still succeeds — the refusal is for overflow only.
    var exact: [5][]const u8 = undefined;
    const got = try declaredInstallDependencies(&exact, src);
    try testing.expectEqual(@as(usize, 5), got.len);
    try testing.expectEqualStrings("dep4", got[4]);
}

test "declaredDependencies truncates instead of refusing" {
    // Deliberately the other policy: its callers read a keg already on disk,
    // where a short list costs a placeholder rather than a broken install.
    const src =
        \\  depends_on "dep0"
        \\  depends_on "dep1"
        \\  depends_on "dep2"
    ;

    var out: [2][]const u8 = undefined;
    const got = declaredDependencies(&out, src);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("dep0", got[0]);
    try testing.expectEqualStrings("dep1", got[1]);
}

test "declaredDependencies still reports an optional dep as a runtime one" {
    // Its answer is baked into relocated bytes via the perl placeholder, so
    // narrowing it would invalidate every cached relocation. An optional dep
    // that IS installed is a runtime dep of the keg on disk.
    var out: [8][]const u8 = undefined;
    const got = declaredDependencies(&out,
        \\  depends_on "lua" => :optional
        \\  depends_on "cmake" => :build
    );
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("lua", got[0]);
}

test "declaredDependencies ignores commented and symbol forms" {
    var out: [8][]const u8 = undefined;
    const got = declaredDependencies(&out,
        \\  # depends_on "ghost"
        \\  depends_on :xcode
        \\  depends_on "real"
    );
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("real", got[0]);
}

test "declaredDependencies stops at the caller's capacity" {
    var out: [1][]const u8 = undefined;
    const got = declaredDependencies(&out,
        \\  depends_on "a"
        \\  depends_on "b"
    );
    try testing.expectEqual(@as(usize, 1), got.len);
}

test "declaredDependencies ignores an unterminated quote" {
    // A truncated or hand-edited .rb must yield nothing rather than a slice
    // running past the closing quote that isn't there.
    var out: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), declaredDependencies(&out, "  depends_on \"openjdk\n").len);
}

test "declaredDependencies handles a source with no dependencies" {
    var out: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), declaredDependencies(&out, "class X < Formula\nend\n").len);
}

test "declaredDependencies tolerates a zero-capacity buffer" {
    var out: [0][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), declaredDependencies(&out, "  depends_on \"openjdk\"\n").len);
}

test "dependencyPlaceholder declines an empty dependency list" {
    var buf: [256]u8 = undefined;
    try testing.expect(dependencyPlaceholder(&buf, "/opt/malt", &.{}) == null);
}

test "dependencyPlaceholder declines rather than truncate a too-small buffer" {
    // A truncated path would point somewhere real but wrong; refusing leaves
    // the token visible instead, which doctor then reports.
    var buf: [8]u8 = undefined;
    const deps = [_][]const u8{"openjdk"};
    try testing.expect(dependencyPlaceholder(&buf, "/opt/malt", &deps) == null);
}

test "dependencyPlaceholder does not mistake a lookalike dependency name" {
    // Only the exact name or an `@`-qualified variant counts — a longer name
    // that merely starts with it is a different formula.
    var buf: [256]u8 = undefined;
    const deps = [_][]const u8{"openjdk-doc"};
    try testing.expect(dependencyPlaceholder(&buf, "/opt/malt", &deps) == null);
}

test "declaredRecommendedDependencies returns only the recommended subset" {
    const rb =
        \\class Foo < Formula
        \\  depends_on "required-one"
        \\  depends_on "mongodb-database-tools" => :recommended
        \\  depends_on "mongosh" => :recommended
        \\  depends_on "cmake" => :build
        \\  depends_on "extra" => :optional
        \\end
    ;
    var buf: [8][]const u8 = undefined;
    const got = try declaredRecommendedDependencies(&buf, rb);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("mongodb-database-tools", got[0]);
    try std.testing.expectEqualStrings("mongosh", got[1]);
}

test "declaredRecommendedDependencies is empty when nothing is recommended" {
    const rb =
        \\class Foo < Formula
        \\  depends_on "required-one"
        \\  depends_on "cmake" => :build
        \\end
    ;
    var buf: [8][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try declaredRecommendedDependencies(&buf, rb)).len);
}

test "declaredRecommendedDependencies refuses rather than truncate an overlong list" {
    // A short list would silently mark a dep non-recommended, turning a
    // survivable skip into a hard failure (or the reverse).
    const rb =
        \\class Foo < Formula
        \\  depends_on "a" => :recommended
        \\  depends_on "b" => :recommended
        \\end
    ;
    var buf: [1][]const u8 = undefined;
    try std.testing.expectError(error.TooManyDependencies, declaredRecommendedDependencies(&buf, rb));
}

test "declaredRecommendedDependencies ignores a marker mentioned in a comment" {
    // Downgrading a required dep's failure to a warning would report a broken
    // install as a success.
    const rb =
        \\class Foo < Formula
        \\  depends_on "libfoo" # unlike the :recommended one, this is mandatory
        \\  depends_on "libbar" => :recommended
        \\end
    ;
    var buf: [8][]const u8 = undefined;
    const got = try declaredRecommendedDependencies(&buf, rb);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("libbar", got[0]);
}

test "declaredInstallDependencies keeps a dep whose comment mentions :optional" {
    const rb =
        \\class Foo < Formula
        \\  depends_on "libfoo" # not :optional despite the word
        \\end
    ;
    var buf: [8][]const u8 = undefined;
    const got = try declaredInstallDependencies(&buf, rb);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("libfoo", got[0]);
}
