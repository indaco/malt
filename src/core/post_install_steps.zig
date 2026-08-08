//! malt — declarative post-install steps executor.
//!
//! Homebrew 6 migrates formula hooks from `def post_install` Ruby to a
//! literal-only `post_install_steps` array exposed through the formulae
//! API. This module interprets that array natively: path bases resolve
//! against the malt prefix, filesystem steps go through the same
//! keg-confinement guards as the DSL FS builtins, and tool steps spawn
//! through the same sandbox fence as the DSL `system` builtin.
//! Unsupported steps land in the FallbackLog so the shared outcome
//! router downgrades to the loud partial-skip envelope.

const std = @import("std");
const sandbox = @import("dsl/sandbox.zig");
const sandbox_macos = @import("sandbox/macos.zig");
const fallback_log = @import("dsl/fallback_log.zig");
const atomic = @import("../fs/atomic.zig");
const clonefile = @import("../fs/clonefile.zig");
const text_replace = @import("../text_replace.zig");

pub const FallbackLog = fallback_log.FallbackLog;

/// Formula-scoped inputs for base-token resolution and confinement.
pub const StepsCtx = struct {
    io: std.Io,
    /// Arena-backed: owns every resolved path, parsed JSON node, and log
    /// detail until the caller finishes routing the FallbackLog.
    allocator: std.mem.Allocator,
    name: []const u8,
    /// Raw upstream version — template tokens read it; the revision-suffixed
    /// cellar label lives in `keg_path` already.
    version: []const u8,
    /// malt prefix (the upstream HOMEBREW_PREFIX analogue).
    prefix: []const u8,
    /// `<prefix>/Cellar/<name>/<pkg_version>` — the `prefix` base token.
    keg_path: []const u8,
    flog: *FallbackLog,
    suppress_child_stdout: bool = false,
    /// Only consulted for the data-dir initialisers (`--user=$USER`).
    environ: std.process.Environ = .empty,
};

/// Step types this executor runs natively. Everything else routes to the
/// partial-skip envelope; doctor reads this to classify migrated formulas.
pub fn supportedStepType(step_type: []const u8) bool {
    return step_map.get(step_type) != null;
}

const StepTag = enum {
    mkdir_p,
    touch,
    write,
    symlink,
    copy,
    link_dir,
    link_children,
    remove,
    inreplace,
    compile_gsettings_schemas,
    gio_querymodules,
    gdk_pixbuf_query_loaders,
    gtk_update_icon_cache,
    update_mime_database,
    update_desktop_database,
    init_data_dir,
};

/// Single source of truth for the native step set: `runStep` dispatch and
/// the doctor-facing `supportedStepType` classifier both read it.
const step_map = std.StaticStringMap(StepTag).initComptime(.{
    .{ "mkdir_p", .mkdir_p },
    .{ "touch", .touch },
    .{ "write", .write },
    .{ "symlink", .symlink },
    .{ "copy", .copy },
    .{ "link_dir", .link_dir },
    .{ "link_children", .link_children },
    .{ "remove", .remove },
    .{ "inreplace", .inreplace },
    .{ "compile_gsettings_schemas", .compile_gsettings_schemas },
    .{ "gio_querymodules", .gio_querymodules },
    .{ "gdk_pixbuf_query_loaders", .gdk_pixbuf_query_loaders },
    .{ "gtk_update_icon_cache", .gtk_update_icon_cache },
    .{ "update_mime_database", .update_mime_database },
    .{ "update_desktop_database", .update_desktop_database },
    .{ "init_data_dir", .init_data_dir },
});

/// True when the formula JSON carries a non-empty steps array whose every
/// step type runs natively. Read-side classifier for the doctor probe —
/// execution itself routes per-step through the FallbackLog instead.
pub fn allStepsSupported(allocator: std.mem.Allocator, formula_json: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, formula_json, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const steps_val = root.get("post_install_steps") orelse return false;
    const steps = switch (steps_val) {
        .array => |a| a.items,
        else => return false,
    };
    if (steps.len == 0) return false;
    for (steps) |step_val| {
        const obj = switch (step_val) {
            .object => |o| o,
            else => return false,
        };
        const step_type = getString(obj, "type") orelse return false;
        if (!supportedStepType(step_type)) return false;
    }
    return true;
}

/// Interpret the formula JSON's `post_install_steps` array. Returns false
/// when the formula carries no steps (caller falls through to the Ruby-DSL
/// path); true means the steps were attempted and the FallbackLog is the
/// source of truth for routing, exactly like the DSL interpreter.
pub fn execute(ctx: StepsCtx, formula_json: []const u8) bool {
    // Parsed tree is arena-owned via ctx.allocator; no deinit needed.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, formula_json, .{}) catch return false;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const steps_val = root.get("post_install_steps") orelse return false;
    const steps = switch (steps_val) {
        .array => |a| a.items,
        else => return false,
    };
    if (steps.len == 0) return false;

    for (steps) |step_val| {
        ctx.flog.total_top_level += 1;
        const obj = switch (step_val) {
            .object => |o| o,
            else => {
                logUnsupported(ctx, "malformed step (not an object)");
                continue;
            },
        };
        if (runStep(ctx, obj)) ctx.flog.handled_top_level += 1;
        // A confinement violation or hard command failure aborts the rest,
        // mirroring the Ruby post_install path (a raised step ends the run)
        // and the DSL interpreter's stop-on-violation. Unknown/unsupported
        // steps only warn, so they don't abort.
        if (ctx.flog.hasFatal()) break;
    }
    return true;
}

fn runStep(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const step_type = getString(obj, "type") orelse {
        logUnsupported(ctx, "step without a type");
        return false;
    };

    // mkdir/move/move_children are defined upstream but unused in
    // homebrew-core today — routed loudly until a formula ships one.
    const tag = step_map.get(step_type) orelse {
        logUnsupported(ctx, step_type);
        return false;
    };
    return switch (tag) {
        .mkdir_p => stepMkdirP(ctx, obj),
        .touch => stepTouch(ctx, obj),
        .write => stepWrite(ctx, obj),
        .symlink => stepSymlink(ctx, obj),
        .copy => stepCopy(ctx, obj),
        .link_dir => stepLinkDir(ctx, obj),
        .link_children => stepLinkChildren(ctx, obj),
        .remove => stepRemove(ctx, obj),
        .inreplace => stepInreplace(ctx, obj),
        .compile_gsettings_schemas => runPathTool(ctx, obj, "glib", "glib-compile-schemas", &.{}),
        .gio_querymodules => runPathTool(ctx, obj, "glib", "gio-querymodules", &.{}),
        .update_mime_database => runPathTool(ctx, obj, "shared-mime-info", "update-mime-database", &.{}),
        .update_desktop_database => runPathTool(ctx, obj, "desktop-file-utils", "update-desktop-database", &.{}),
        .gdk_pixbuf_query_loaders => stepGdkPixbufQueryLoaders(ctx),
        .gtk_update_icon_cache => stepGtkUpdateIconCache(ctx, obj),
        .init_data_dir => stepInitDataDir(ctx, obj),
    };
}

// --- path resolution -------------------------------------------------------

/// Expand `{{token}}` template placeholders the way brew's installer does:
/// known tokens substitute, unknown ones stay verbatim.
pub fn expandTemplates(ctx: StepsCtx, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "{{") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, s, pos, "{{")) |start| {
        const end = std.mem.indexOfPos(u8, s, start + 2, "}}") orelse break;
        try out.appendSlice(ctx.allocator, s[pos..start]);
        const token = s[start + 2 .. end];
        if (templateValue(ctx, token)) |v| {
            try out.appendSlice(ctx.allocator, v);
        } else {
            try out.appendSlice(ctx.allocator, s[start .. end + 2]);
        }
        pos = end + 2;
    }
    try out.appendSlice(ctx.allocator, s[pos..]);
    return out.toOwnedSlice(ctx.allocator);
}

/// Note the split from `base_map` below: the `{{bin}}` *template* is the
/// keg's bin, while the `bin` *base* is `<prefix>/bin`. A keg-only formula
/// publishing its launcher uses both in one step.
const template_map = std.StaticStringMap(enum {
    name,
    version,
    version_major,
    version_major_minor,
    homebrew_prefix,
    prefix_etc,
    user,
    keg_bin,
    keg_libexec,
    pkgetc,
    pkgshare,
    opt_pkgshare,
    bash_completion,
    zsh_completion,
    fish_completion,
    pwsh_completion,
}).initComptime(.{
    .{ "name", .name },
    .{ "version", .version },
    .{ "version.major", .version_major },
    .{ "version.major_minor", .version_major_minor },
    .{ "HOMEBREW_PREFIX", .homebrew_prefix },
    .{ "etc", .prefix_etc },
    .{ "user", .user },
    .{ "bin", .keg_bin },
    // Also usable inline, not just as a base — an unresolved `{{pkgetc}}` reads
    // as a relative path and dies in the sandbox. Kept separate from `base_map`
    // on purpose: `bin`/`etc` mean different things on each side.
    .{ "libexec", .keg_libexec },
    .{ "pkgetc", .pkgetc },
    .{ "pkgshare", .pkgshare },
    .{ "opt_pkgshare", .opt_pkgshare },
    .{ "bash_completion", .bash_completion },
    .{ "zsh_completion", .zsh_completion },
    .{ "fish_completion", .fish_completion },
    .{ "pwsh_completion", .pwsh_completion },
});

fn templateValue(ctx: StepsCtx, token: []const u8) ?[]const u8 {
    const a = ctx.allocator;
    return switch (template_map.get(token) orelse return null) {
        .name => ctx.name,
        .version => ctx.version,
        .version_major => versionComponents(ctx.version, 1),
        .version_major_minor => versionComponents(ctx.version, 2),
        .homebrew_prefix => ctx.prefix,
        .prefix_etc => std.fmt.allocPrint(a, "{s}/etc", .{ctx.prefix}) catch null,
        // Null when the environment has no USER: the caller must refuse
        // rather than write an unresolved token into a live config.
        .user => std.process.Environ.getPosix(ctx.environ, "USER"),
        // Keg-relative; the layouts are Homebrew's standard completion dirs.
        .keg_bin => std.fmt.allocPrint(a, "{s}/bin", .{ctx.keg_path}) catch null,
        // Keg-relative, matching Homebrew's `libexec` in a formula body.
        .keg_libexec => std.fmt.allocPrint(a, "{s}/libexec", .{ctx.keg_path}) catch null,
        // Prefix-relative, matching `resolveBase` for the same names.
        .pkgetc => std.fmt.allocPrint(a, "{s}/etc/{s}", .{ ctx.prefix, ctx.name }) catch null,
        .pkgshare => std.fmt.allocPrint(a, "{s}/share/{s}", .{ ctx.prefix, ctx.name }) catch null,
        .opt_pkgshare => std.fmt.allocPrint(a, "{s}/opt/{s}/share/{s}", .{ ctx.prefix, ctx.name, ctx.name }) catch null,
        .bash_completion => std.fmt.allocPrint(a, "{s}/etc/bash_completion.d", .{ctx.keg_path}) catch null,
        .zsh_completion => std.fmt.allocPrint(a, "{s}/share/zsh/site-functions", .{ctx.keg_path}) catch null,
        .fish_completion => std.fmt.allocPrint(a, "{s}/share/fish/vendor_completions.d", .{ctx.keg_path}) catch null,
        .pwsh_completion => std.fmt.allocPrint(a, "{s}/share/pwsh/completions", .{ctx.keg_path}) catch null,
    };
}

/// First `n` dot-separated components of a version string.
fn versionComponents(version: []const u8, n: usize) []const u8 {
    var end: usize = 0;
    var seen: usize = 0;
    while (end < version.len) : (end += 1) {
        if (version[end] == '.') {
            seen += 1;
            if (seen == n) return version[0..end];
        }
    }
    return version;
}

const BaseTag = enum {
    homebrew_prefix,
    prefix,
    opt_prefix,
    var_dir,
    etc,
    lib,
    bin,
    pkgetc,
    pkgshare,
    opt_pkgshare,
    formula_pkgetc,
    formula_opt_prefix,
};

const base_map = std.StaticStringMap(BaseTag).initComptime(.{
    .{ "homebrew_prefix", .homebrew_prefix },
    .{ "prefix", .prefix },
    .{ "opt_prefix", .opt_prefix },
    .{ "var", .var_dir },
    .{ "etc", .etc },
    .{ "lib", .lib },
    .{ "bin", .bin },
    .{ "pkgetc", .pkgetc },
    .{ "pkgshare", .pkgshare },
    .{ "opt_pkgshare", .opt_pkgshare },
    .{ "formula_pkgetc", .formula_pkgetc },
    .{ "formula_opt_prefix", .formula_opt_prefix },
});

/// Map an upstream base token onto the malt prefix. Null means "no safe
/// mapping" — `home` deliberately so (it escapes the prefix and would fail
/// confinement anyway), formula-scoped bases without a formula, and any
/// token this executor does not know.
pub fn resolveBase(ctx: StepsCtx, base: []const u8, formula_ref: ?[]const u8) ?[]const u8 {
    const a = ctx.allocator;
    return switch (base_map.get(base) orelse return null) {
        .homebrew_prefix => ctx.prefix,
        .prefix => ctx.keg_path,
        .opt_prefix => std.fmt.allocPrint(a, "{s}/opt/{s}", .{ ctx.prefix, ctx.name }) catch null,
        .var_dir => std.fmt.allocPrint(a, "{s}/var", .{ctx.prefix}) catch null,
        .etc => std.fmt.allocPrint(a, "{s}/etc", .{ctx.prefix}) catch null,
        .lib => std.fmt.allocPrint(a, "{s}/lib", .{ctx.prefix}) catch null,
        .bin => std.fmt.allocPrint(a, "{s}/bin", .{ctx.prefix}) catch null,
        .pkgetc => std.fmt.allocPrint(a, "{s}/etc/{s}", .{ ctx.prefix, ctx.name }) catch null,
        .pkgshare => std.fmt.allocPrint(a, "{s}/share/{s}", .{ ctx.prefix, ctx.name }) catch null,
        .opt_pkgshare => std.fmt.allocPrint(a, "{s}/opt/{s}/share/{s}", .{ ctx.prefix, ctx.name, ctx.name }) catch null,
        .formula_pkgetc => {
            const f = formula_ref orelse return null;
            return std.fmt.allocPrint(a, "{s}/etc/{s}", .{ ctx.prefix, f }) catch null;
        },
        .formula_opt_prefix => {
            const f = formula_ref orelse return null;
            return std.fmt.allocPrint(a, "{s}/opt/{s}", .{ ctx.prefix, f }) catch null;
        },
    };
}

/// Resolve a `{base, path, formula}` spec into an absolute path, or null
/// (already logged) when the spec is malformed or the base has no mapping.
fn resolvePathSpec(ctx: StepsCtx, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const spec = getObject(obj, key) orelse {
        logUnsupported(ctx, key);
        return null;
    };
    return resolveSpec(ctx, spec, key);
}

/// Resolve one `{base, path, formula}` spec. Split out of `resolvePathSpec` so
/// steps carrying an array of specs can reuse the same base/template handling.
fn resolveSpec(ctx: StepsCtx, spec: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const raw = getString(spec, "path") orelse {
        logUnsupported(ctx, key);
        return null;
    };
    const path = expandTemplates(ctx, raw) catch return null;
    const base = getString(spec, "base") orelse "absolute";
    if (std.mem.eql(u8, base, "absolute") or std.mem.eql(u8, base, "relative")) return path;
    const root = resolveBase(ctx, base, getString(spec, "formula")) orelse {
        logUnsupported(ctx, std.fmt.allocPrint(ctx.allocator, "base {s}", .{base}) catch base);
        return null;
    };
    return std.fs.path.join(ctx.allocator, &.{ root, path }) catch null;
}

// --- filesystem tier -------------------------------------------------------

/// Confinement gate shared by every write path. Resolves the parent chain
/// (not just the literal string) so a symlink planted by an earlier step
/// can't redirect a `mkdir_p`/`write`/`init_data_dir` outside the prefix —
/// same resolved-boundary guard the DSL `cp`/`mv` builtins use, applied
/// before any filesystem mutation.
fn confined(ctx: StepsCtx, path: []const u8) bool {
    sandbox.validateWriteDir(ctx.io, path, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, path);
        return false;
    };
    return true;
}

fn mkParent(ctx: StepsCtx, path: []const u8) void {
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }
}

fn stepMkdirP(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const path = resolvePathSpec(ctx, obj, "path") orelse return false;
    if (!confined(ctx, path)) return false;
    std.Io.Dir.cwd().createDirPath(ctx.io, path) catch {};
    return true;
}

fn stepTouch(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const path = resolvePathSpec(ctx, obj, "path") orelse return false;
    if (!confined(ctx, path)) return false;
    mkParent(ctx, path);
    // Create (no truncate) through an O_NOFOLLOW handle, same as the DSL
    // touch builtin: a symlinked leaf must not reach outside the keg.
    const file = sandbox.openTargetNoFollow(ctx.io, path, ctx.keg_path, ctx.prefix, .{ .create = true }) catch |e| {
        if (e == error.PathSandboxViolation) logViolation(ctx, path);
        return e != error.PathSandboxViolation;
    };
    file.close(ctx.io);
    return true;
}

fn stepWrite(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const raw_content = getString(obj, "content") orelse {
        logUnsupported(ctx, "write without content");
        return false;
    };
    const path = resolvePathSpec(ctx, obj, "path") orelse return false;
    if (!confined(ctx, path)) return false;
    // Existing files are the user's unless the step opts into overwrite.
    if (!getFlag(obj, "overwrite") and fileExists(ctx.io, path)) return true;
    const content = expandTemplates(ctx, raw_content) catch return false;
    mkParent(ctx, path);
    const file = sandbox.openTargetNoFollow(ctx.io, path, ctx.keg_path, ctx.prefix, .{
        .write = true,
        .create = true,
        .truncate = true,
    }) catch |e| {
        if (e == error.PathSandboxViolation) logViolation(ctx, path);
        return e != error.PathSandboxViolation;
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, content) catch {};
    return true;
}

/// `copy`: materialise `source` at `target`, the way Homebrew's `cp_r` does —
/// an existing directory `target` receives the source as a child, matching
/// `cp -R`. The symlink steps that follow depend on that nesting.
fn stepCopy(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const target = resolvePathSpec(ctx, obj, "target") orelse return false;
    if (!confined(ctx, target)) return false;
    const source = resolvePathSpec(ctx, obj, "source") orelse return false;
    if (source.len == 0 or source[0] != '/') {
        logUnsupported(ctx, "copy with a relative source");
        return false;
    }
    // The source is cloned wholesale into the prefix, so it needs a boundary
    // too — otherwise a tap names any readable tree.
    if (!confinedSource(ctx, source)) return false;

    // An existing directory target receives the source as a child; anything
    // else is the destination path itself.
    var dest = target;
    if (isDir(ctx, target)) {
        dest = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ target, std.fs.path.basename(source) }) catch
            return false;
        if (!confined(ctx, dest)) return false;
    } else {
        mkParent(ctx, target);
    }

    // Always replace, as `cp_r` does — formulae omit `force` and rely on it.
    // Skipping an existing destination would leave a stale payload behind.
    std.Io.Dir.cwd().deleteTree(ctx.io, dest) catch {};

    // APFS clone: same bytes, no double disk cost, mtimes preserved.
    clonefile.cloneTree(ctx.io, ctx.allocator, source, dest) catch {
        logUnsupported(ctx, "copy (clone failed)");
        return false;
    };
    return true;
}

/// Confine a *read* source. Unlike `confined` this resolves the path itself,
/// not just its parent: the keg is tap-controlled, so the doorway can be the
/// source's own final component.
fn confinedSource(ctx: StepsCtx, path: []const u8) bool {
    if (isDir(ctx, path)) {
        sandbox.validateDirTarget(ctx.io, path, ctx.keg_path, ctx.prefix) catch {
            logViolation(ctx, path);
            return false;
        };
        return true;
    }
    const f = sandbox.openTargetNoFollow(ctx.io, path, ctx.keg_path, ctx.prefix, .{ .write = false }) catch {
        logViolation(ctx, path);
        return false;
    };
    f.close(ctx.io);
    return true;
}

fn isDir(ctx: StepsCtx, path: []const u8) bool {
    var d = std.Io.Dir.openDirAbsolute(ctx.io, path, .{}) catch return false;
    d.close(ctx.io);
    return true;
}

fn stepSymlink(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const target = resolvePathSpec(ctx, obj, "target") orelse return false;
    if (!confined(ctx, target)) return false;
    const source = resolvePathSpec(ctx, obj, "source") orelse return false;
    if (source.len == 0 or source[0] != '/') {
        // Still refused, but now only for a genuinely relative source. A
        // `{{bin}}`-style token used to land here because it survived
        // expansion unresolved, which read as relative.
        logUnsupported(ctx, "symlink with a relative source");
        return false;
    }
    mkParent(ctx, target);
    if (getFlag(obj, "force")) std.Io.Dir.cwd().deleteFile(ctx.io, target) catch {};
    std.Io.Dir.symLinkAbsolute(ctx.io, source, target, .{}) catch {};
    return true;
}

/// `guards` gate a step on the target's state. Only `if_exists` appears
/// upstream; an unknown condition counts as unmet, so the step is skipped
/// rather than run against an assumption that was never checked.
fn guardsSatisfied(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const guards = obj.get("guards") orelse return true;
    if (guards != .array) return true;
    for (guards.array.items) |item| {
        if (item != .object) continue;
        const raw = getString(item.object, "path") orelse return false;
        const path = expandTemplates(ctx, raw) catch return false;
        if (!std.mem.eql(u8, getString(item.object, "condition") orelse "", "if_exists")) return false;
        std.Io.Dir.accessAbsolute(ctx.io, path, .{}) catch return false;
    }
    return true;
}

/// Replace every line beginning with `literal` wholesale. Caller must have
/// verified the pattern fits via `anchoredLineLiteral`.
fn replaceAnchoredLines(ctx: StepsCtx, content: []const u8, literal: []const u8, after: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) out.append(ctx.allocator, '\n') catch return null;
        first = false;
        const repl = if (std.mem.startsWith(u8, line, literal)) after else line;
        out.appendSlice(ctx.allocator, repl) catch return null;
    }
    return out.toOwnedSlice(ctx.allocator) catch null;
}

/// The literal prefix of a `^<literal>.*` pattern — the one regexp shape
/// upstream uses — or null for anything else. There is no regex engine here,
/// so a pattern this cannot fully account for must reach the fallback rather
/// than be approximated against a live config.
fn anchoredLineLiteral(pattern: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, pattern, "^") or !std.mem.endsWith(u8, pattern, ".*")) return null;
    if (pattern.len < 4) return null;
    const literal = pattern[1 .. pattern.len - 2];
    for (literal) |c| switch (c) {
        '.', '[', ']', '(', ')', '{', '}', '*', '+', '?', '|', '\\', '^', '$' => return null,
        else => {},
    };
    return literal;
}

/// Substitute inside a config file the formula shipped earlier. The target is
/// live user configuration, so the write is atomic and anything uncertain —
/// unresolved template, empty needle, unsupported regexp — refuses instead.
fn stepInreplace(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    // An unmet guard is the step declining to run, not a failure to report.
    if (!guardsSatisfied(ctx, obj)) return true;

    const path = resolvePathSpec(ctx, obj, "path") orelse return false;
    if (!confined(ctx, path)) return false;

    const before = getString(obj, "before") orelse {
        logUnsupported(ctx, "inreplace");
        return false;
    };
    const after_raw = getString(obj, "after") orelse {
        logUnsupported(ctx, "inreplace");
        return false;
    };
    if (before.len == 0) {
        logUnsupported(ctx, "inreplace");
        return false;
    }
    const after = expandTemplates(ctx, after_raw) catch return false;
    if (std.mem.indexOf(u8, after, "{{") != null) {
        // Writing a literal `{{user}}` into a config is worse than not running.
        logUnsupported(ctx, "inreplace with an unresolved template");
        return false;
    }

    const file = std.Io.Dir.openFileAbsolute(ctx.io, path, .{}) catch return false;
    const stat = file.stat(ctx.io) catch {
        file.close(ctx.io);
        return false;
    };
    if (stat.size > 4 * 1024 * 1024) {
        file.close(ctx.io);
        return false;
    }
    const content = ctx.allocator.alloc(u8, stat.size) catch {
        file.close(ctx.io);
        return false;
    };
    const read = file.readPositionalAll(ctx.io, content, 0) catch {
        file.close(ctx.io);
        return false;
    };
    file.close(ctx.io);
    if (read < content.len) return false;

    const updated = if (getFlag(obj, "regexp")) blk: {
        const literal = anchoredLineLiteral(before) orelse {
            logUnsupported(ctx, "inreplace with an unsupported regexp");
            return false;
        };
        break :blk replaceAnchoredLines(ctx, content, literal, after) orelse return false;
    } else text_replace.replaceAll(ctx.allocator, content, before, after) catch return false;

    atomic.atomicReplaceFile(ctx.io, path, updated) catch return false;
    return true;
}

/// Retire a symlink this formula planted earlier, identified by a substring of
/// its target. Guarded, never unconditional: a real file or a link pointing
/// elsewhere belongs to something else and must survive. `readLinkAbsolute`
/// doubles as the type check, and the link is unlinked rather than followed.
fn stepRemove(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const needle = getString(obj, "symlink_target_contains") orelse {
        // Without the guard this would be an unconditional recursive delete
        // driven by formula data — not something to infer.
        logUnsupported(ctx, "remove without symlink_target_contains");
        return false;
    };
    const paths_val = obj.get("paths") orelse {
        logUnsupported(ctx, "remove");
        return false;
    };
    if (paths_val != .array) {
        logUnsupported(ctx, "remove");
        return false;
    }

    for (paths_val.array.items) |item| {
        if (item != .object) continue;
        const path = resolveSpec(ctx, item.object, "paths") orelse continue;
        if (!confined(ctx, path)) continue;

        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.readLinkAbsolute(ctx.io, path, &target_buf) catch continue;
        if (std.mem.indexOf(u8, target_buf[0..len], needle) == null) continue;
        std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
    }
    return true;
}

fn stepLinkChildren(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const source = resolvePathSpec(ctx, obj, "source") orelse return false;
    const target = resolvePathSpec(ctx, obj, "target") orelse return false;
    if (!confined(ctx, target)) return false;
    std.Io.Dir.cwd().createDirPath(ctx.io, target) catch {};
    // Same per-level guards as the DSL cp_r walk: neither side may resolve
    // out of the keg/prefix through a planted directory symlink.
    sandbox.validateDirTarget(ctx.io, target, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, target);
        return false;
    };
    sandbox.validateDirTarget(ctx.io, source, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, source);
        return false;
    };
    const link_prefix = expandTemplates(ctx, getString(obj, "prefix") orelse "") catch return false;
    const link_suffix = expandTemplates(ctx, getString(obj, "suffix") orelse "") catch return false;

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, source, .{ .iterate = true }) catch return true;
    defer dir.close(ctx.io);
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        const child = std.fs.path.join(ctx.allocator, &.{ source, entry.name }) catch continue;
        const link_name = std.fmt.allocPrint(ctx.allocator, "{s}{s}{s}", .{ link_prefix, entry.name, link_suffix }) catch continue;
        const link_path = std.fs.path.join(ctx.allocator, &.{ target, link_name }) catch continue;
        std.Io.Dir.cwd().deleteFile(ctx.io, link_path) catch {};
        std.Io.Dir.symLinkAbsolute(ctx.io, child, link_path, .{}) catch {};
    }
    return true;
}

fn stepLinkDir(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const source = resolvePathSpec(ctx, obj, "source") orelse return false;
    const target = resolvePathSpec(ctx, obj, "target") orelse return false;
    if (!confined(ctx, target)) return false;
    linkDirRecursive(ctx, source, target);
    return true;
}

/// Mirror of brew's link_dir walk: directories materialise as real dirs,
/// files and symlinks become symlinks, `.DS_Store` is skipped. Guarded per
/// level like the DSL cp_r walk.
fn linkDirRecursive(ctx: StepsCtx, src: []const u8, dst: []const u8) void {
    std.Io.Dir.cwd().createDirPath(ctx.io, dst) catch {};
    sandbox.validateDirTarget(ctx.io, dst, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, dst);
        return;
    };
    sandbox.validateDirTarget(ctx.io, src, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, src);
        return;
    };

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, src, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;
        const src_child = std.fs.path.join(ctx.allocator, &.{ src, entry.name }) catch continue;
        const dst_child = std.fs.path.join(ctx.allocator, &.{ dst, entry.name }) catch continue;
        if (entry.kind == .directory) {
            linkDirRecursive(ctx, src_child, dst_child);
        } else {
            std.Io.Dir.cwd().deleteFile(ctx.io, dst_child) catch {};
            std.Io.Dir.symLinkAbsolute(ctx.io, src_child, dst_child, .{}) catch {};
        }
    }
}

// --- tool tier -------------------------------------------------------------

/// Tool steps whose only argument is the step's resolved path.
fn runPathTool(ctx: StepsCtx, obj: std.json.ObjectMap, tool_formula: []const u8, exe: []const u8, extra: []const []const u8) bool {
    const path = resolvePathSpec(ctx, obj, "path") orelse return false;
    var args = std.ArrayList([]const u8).empty;
    args.appendSlice(ctx.allocator, extra) catch return false;
    args.append(ctx.allocator, path) catch return false;
    return runFormulaTool(ctx, tool_formula, exe, args.items);
}

fn stepGtkUpdateIconCache(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    // brew prefers gtk4's tool when any gtk4 is installed, else gtk+3's.
    const gtk4 = std.fmt.allocPrint(ctx.allocator, "{s}/opt/gtk4/bin/gtk4-update-icon-cache", .{ctx.prefix}) catch return false;
    if (fileExists(ctx.io, gtk4))
        return runPathTool(ctx, obj, "gtk4", "gtk4-update-icon-cache", &.{ "-q", "-t", "-f" });
    return runPathTool(ctx, obj, "gtk+3", "gtk3-update-icon-cache", &.{ "-q", "-t", "-f" });
}

// --- data-dir initialisers ---------------------------------------------------

const InitDataDirPlan = struct {
    /// Marker file (inside the data dir) whose presence means "already
    /// initialised — this is user data, never re-run".
    marker: []const u8,
    argv: []const []const u8,
};

/// Pure argv/marker construction for the three upstream initialisers.
/// Null for an unknown `using` — no safe way to guess a database init.
/// Binaries come from the formula's own keg; `--tmpdir` points inside the
/// prefix because the sandbox fence has no /tmp grant (brew uses /tmp).
const initialiser_map = std.StaticStringMap(enum { postgresql_initdb, mysql_initialize, mariadb_install_db }).initComptime(.{
    .{ "postgresql_initdb", .postgresql_initdb },
    .{ "mysql_initialize", .mysql_initialize },
    .{ "mariadb_install_db", .mariadb_install_db },
});

fn initDataDirPlan(ctx: StepsCtx, using: []const u8, datadir: []const u8, locale: ?[]const u8) ?InitDataDirPlan {
    const a = ctx.allocator;
    const tmpdir = std.fmt.allocPrint(a, "{s}/var/tmp", .{ctx.prefix}) catch return null;

    const tag = initialiser_map.get(using) orelse return null;

    // Postgres diverges (locale/encoding argv, top-level marker); handle it
    // before the shared mysql/mariadb shape below.
    if (tag == .postgresql_initdb) {
        var argv = std.ArrayList([]const u8).empty;
        argv.append(a, std.fmt.allocPrint(a, "{s}/bin/initdb", .{ctx.keg_path}) catch return null) catch return null;
        argv.append(a, std.fmt.allocPrint(a, "--locale={s}", .{locale orelse "en_US.UTF-8"}) catch return null) catch return null;
        argv.appendSlice(a, &.{ "-E", "UTF-8", datadir }) catch return null;
        return .{
            .marker = std.fmt.allocPrint(a, "{s}/PG_VERSION", .{datadir}) catch return null,
            .argv = argv.items,
        };
    }

    const mysql_like: struct { exe: []const u8, first: []const u8, marker_rel: []const u8 } = switch (tag) {
        .postgresql_initdb => unreachable, // handled above
        .mysql_initialize => .{ .exe = "mysqld", .first = "--initialize-insecure", .marker_rel = "mysql/general_log.CSM" },
        .mariadb_install_db => .{ .exe = "mysql_install_db", .first = "--verbose", .marker_rel = "mysql/user.frm" },
    };

    var argv = std.ArrayList([]const u8).empty;
    argv.append(a, std.fmt.allocPrint(a, "{s}/bin/{s}", .{ ctx.keg_path, mysql_like.exe }) catch return null) catch return null;
    argv.append(a, mysql_like.first) catch return null;
    // `--user` only matters when running as root (mysqld setuids then);
    // malt installs as the invoking user, so a missing USER is benign.
    if (std.process.Environ.getPosix(ctx.environ, "USER")) |user|
        argv.append(a, std.fmt.allocPrint(a, "--user={s}", .{user}) catch return null) catch return null;
    argv.append(a, std.fmt.allocPrint(a, "--basedir={s}", .{ctx.keg_path}) catch return null) catch return null;
    argv.append(a, std.fmt.allocPrint(a, "--datadir={s}", .{datadir}) catch return null) catch return null;
    argv.append(a, std.fmt.allocPrint(a, "--tmpdir={s}", .{tmpdir}) catch return null) catch return null;
    return .{
        .marker = std.fmt.allocPrint(a, "{s}/{s}", .{ datadir, mysql_like.marker_rel }) catch return null,
        .argv = argv.items,
    };
}

fn stepInitDataDir(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const using = getString(obj, "using") orelse {
        logUnsupported(ctx, "init_data_dir without an initialiser");
        return false;
    };
    const datadir = resolvePathSpec(ctx, obj, "path") orelse return false;
    if (!confined(ctx, datadir)) return false;
    const plan = initDataDirPlan(ctx, using, datadir, getString(obj, "locale")) orelse {
        logUnsupported(ctx, std.fmt.allocPrint(ctx.allocator, "init_data_dir ({s})", .{using}) catch using);
        return false;
    };
    // An initialised (or otherwise pre-populated) data dir is user data —
    // mirror brew's marker guard. A dir we did not create is never wiped
    // on failure below, so a partial init from a prior run is preserved
    // for inspection rather than silently destroyed.
    const preexisted = fileExists(ctx.io, plan.marker) or dirExists(ctx.io, datadir);
    if (fileExists(ctx.io, plan.marker)) return true;
    if (!fileExists(ctx.io, plan.argv[0])) {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} initialiser not found in the keg", .{using}) catch using);
        return false;
    }
    std.Io.Dir.cwd().createDirPath(ctx.io, datadir) catch {};
    // Never pre-create the marker's parent: the initialisers refuse a
    // non-empty data dir, and they create their own subtrees.
    const tmpdir = std.fmt.allocPrint(ctx.allocator, "{s}/var/tmp", .{ctx.prefix}) catch return false;
    std.Io.Dir.cwd().createDirPath(ctx.io, tmpdir) catch {};
    if (spawnFenced(ctx, plan.argv, null, using, .{ .allow_ipc = true })) return true;
    // A failed initialiser can leave a partial data dir; mysql/mariadb
    // then refuse the non-empty dir on every retry. Remove what this run
    // created so the next install/upgrade starts clean. postgres already
    // self-cleans, so this is a no-op there.
    if (!preexisted) std.Io.Dir.cwd().deleteTree(ctx.io, datadir) catch {};
    return false;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

const GdkPixbufEnv = struct {
    moduledir: []const u8,
    module_file: []const u8,
};

/// gdk-pixbuf-query-loaders derives both its loader scan dir and the
/// `--update-cache` write target from its build-time prefix, so under a
/// custom malt prefix it silently targets the baked upstream location
/// (and exits 0 even when that write fails). Derive the malt-prefix pair
/// from the keg's versioned module dir instead.
pub fn gdkPixbufEnvPaths(ctx: StepsCtx) ?GdkPixbufEnv {
    const opt_moddir = std.fmt.allocPrint(ctx.allocator, "{s}/opt/gdk-pixbuf/lib/gdk-pixbuf-2.0", .{ctx.prefix}) catch return null;
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, opt_moddir, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        return .{
            .moduledir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/gdk-pixbuf-2.0/{s}/loaders", .{ ctx.prefix, entry.name }) catch return null,
            .module_file = std.fmt.allocPrint(ctx.allocator, "{s}/lib/gdk-pixbuf-2.0/{s}/loaders.cache", .{ ctx.prefix, entry.name }) catch return null,
        };
    }
    return null;
}

fn stepGdkPixbufQueryLoaders(ctx: StepsCtx) bool {
    const env = gdkPixbufEnvPaths(ctx) orelse {
        logCmdFail(ctx, "gdk-pixbuf module dir not found under the prefix");
        return false;
    };
    // The tool exits 0 even when the cache write fails, so the target tree
    // must exist up front — same real-dirs-at-prefix layout brew links.
    if (!confined(ctx, env.moduledir)) return false;
    std.Io.Dir.cwd().createDirPath(ctx.io, env.moduledir) catch {};
    var env_map = std.process.Environ.Map.init(ctx.allocator);
    defer env_map.deinit();
    env_map.put("GDK_PIXBUF_MODULEDIR", env.moduledir) catch return false;
    env_map.put("GDK_PIXBUF_MODULE_FILE", env.module_file) catch return false;
    return runFormulaToolEnv(ctx, "gdk-pixbuf", "gdk-pixbuf-query-loaders", &.{"--update-cache"}, &env_map);
}

/// Spawn `<prefix>/opt/<formula>/bin/<exe>` through the same argv lint +
/// sandbox fence as the DSL `system` builtin. Failure routes exactly like
/// a failed formula `system` call.
fn runFormulaTool(ctx: StepsCtx, tool_formula: []const u8, exe: []const u8, args: []const []const u8) bool {
    return runFormulaToolEnv(ctx, tool_formula, exe, args, null);
}

fn runFormulaToolEnv(ctx: StepsCtx, tool_formula: []const u8, exe: []const u8, args: []const []const u8, env_map: ?*const std.process.Environ.Map) bool {
    const tool = std.fmt.allocPrint(ctx.allocator, "{s}/opt/{s}/bin/{s}", .{ ctx.prefix, tool_formula, exe }) catch return false;
    if (!fileExists(ctx.io, tool)) {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} not found (is {s} installed?)", .{ exe, tool_formula }) catch exe);
        return false;
    }

    var argv = std.ArrayList([]const u8).empty;
    argv.append(ctx.allocator, tool) catch return false;
    argv.appendSlice(ctx.allocator, args) catch return false;

    return spawnFenced(ctx, argv.items, env_map, exe, .{});
}

/// Argv lint + sandbox fence + spawn + wait — the one exec chokepoint for
/// every tool and initialiser step. `label` names the child in the log.
/// `opts` carries per-spawn fence knobs (IPC only for the DB initialisers).
fn spawnFenced(ctx: StepsCtx, argv: []const []const u8, env_map: ?*const std.process.Environ.Map, label: []const u8, opts: sandbox_macos.ProfileOpts) bool {
    sandbox.validateArgv(argv, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, argv[0]);
        return false;
    };
    const fenced = sandbox.fenceArgv(ctx.allocator, argv, ctx.keg_path, ctx.prefix, opts) catch {
        logViolation(ctx, argv[0]);
        return false;
    };

    var child = std.process.spawn(ctx.io, .{
        .argv = fenced,
        .stdout = if (ctx.suppress_child_stdout) .ignore else .inherit,
        .environ_map = env_map,
    }) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} failed to spawn", .{label}) catch label);
        return false;
    };
    const term = child.wait(ctx.io) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} did not terminate cleanly", .{label}) catch label);
        return false;
    };
    switch (term) {
        .exited => |code| {
            if (code == 0) return true;
            logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} exited with code {d}", .{ label, code }) catch label);
        },
        else => logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} terminated abnormally", .{label}) catch label),
    }
    return false;
}

// --- shared helpers --------------------------------------------------------

fn fileExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn getFlag(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn logUnsupported(ctx: StepsCtx, detail: []const u8) void {
    ctx.flog.log(.{ .formula = ctx.name, .reason = .unknown_method, .detail = detail, .loc = null });
}

fn logViolation(ctx: StepsCtx, path: []const u8) void {
    ctx.flog.log(.{ .formula = ctx.name, .reason = .sandbox_violation, .detail = path, .loc = null });
}

fn logCmdFail(ctx: StepsCtx, detail: []const u8) void {
    ctx.flog.log(.{ .formula = ctx.name, .reason = .system_command_failed, .detail = detail, .loc = null });
}

// --- tests -----------------------------------------------------------------
// Inline because base resolution, templating, and the FS tier are pure
// logic over a caller-supplied prefix; filesystem fixtures use `std.Io`
// directly, mirroring `ruby/source.zig`.

const testing = std.testing;

fn testIo() std.Io {
    return std.Options.debug_io;
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(testIo(), path) catch {};
}

fn uniquePrefix(io: std.Io) ![]u8 {
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const p = try std.fmt.allocPrint(testing.allocator, "/tmp/malt_steps_{s}", .{hex[0..]});
    try std.Io.Dir.cwd().createDirPath(io, p);
    return p;
}

/// Environment carrying a known `USER`, for steps that template it.
const test_user_environ: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"USER=ada"} } };

const TestHarness = struct {
    arena: std.heap.ArenaAllocator,
    flog: FallbackLog,
    prefix: []u8,
    keg: []const u8,
    io: std.Io,
    environ: std.process.Environ = .empty,

    fn init() !TestHarness {
        const io = testIo();
        const prefix = try uniquePrefix(io);
        errdefer testing.allocator.free(prefix);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const keg = try std.fmt.allocPrint(arena.allocator(), "{s}/Cellar/glow/1.2.3", .{prefix});
        try std.Io.Dir.cwd().createDirPath(io, keg);
        return .{
            .arena = arena,
            .flog = FallbackLog.init(testing.allocator),
            .prefix = prefix,
            .keg = keg,
            .io = io,
        };
    }

    fn ctx(self: *TestHarness) StepsCtx {
        return .{
            .io = self.io,
            .allocator = self.arena.allocator(),
            .name = "glow",
            .version = "1.2.3",
            .prefix = self.prefix,
            .keg_path = self.keg,
            .flog = &self.flog,
            .environ = self.environ,
        };
    }

    fn deinit(self: *TestHarness) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.prefix) catch {};
        testing.allocator.free(self.prefix);
        self.flog.deinit();
        self.arena.deinit();
    }
};

fn testFormulaJson(h: *TestHarness, steps_json: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        h.arena.allocator(),
        \\{{"name":"glow","versions":{{"stable":"1.2.3"}},"post_install_defined":false,"post_install_steps":{s}}}
    ,
        .{steps_json},
    );
}

test "expandTemplates substitutes known tokens and leaves unknown verbatim" {
    var h = try TestHarness.init();
    defer h.deinit();
    const c = h.ctx();

    try testing.expectEqualStrings("glow", try expandTemplates(c, "{{name}}"));
    try testing.expectEqualStrings("v1.2.3", try expandTemplates(c, "v{{version}}"));
    try testing.expectEqualStrings("1", try expandTemplates(c, "{{version.major}}"));
    try testing.expectEqualStrings("1.2", try expandTemplates(c, "{{version.major_minor}}"));
    const hp = try expandTemplates(c, "{{HOMEBREW_PREFIX}}/share");
    try testing.expect(std.mem.startsWith(u8, hp, h.prefix));
    try testing.expectEqualStrings("{{mystery}}", try expandTemplates(c, "{{mystery}}"));
    // Malformed input stays verbatim rather than corrupting the path.
    try testing.expectEqualStrings("a{{name", try expandTemplates(c, "a{{name"));
}

test "versionComponents degrades gracefully on dotless and short versions" {
    try testing.expectEqualStrings("9", versionComponents("9", 1));
    try testing.expectEqualStrings("9", versionComponents("9", 2));
    try testing.expectEqualStrings("2026-07-01", versionComponents("2026-07-01", 1));
}

test "initDataDirPlan omits --user when USER is absent from the environ" {
    // The harness environ is empty; --user only matters under root, so a
    // missing USER must degrade to omission, not a broken argv.
    var h = try TestHarness.init();
    defer h.deinit();

    const my = initDataDirPlan(h.ctx(), "mysql_initialize", "/p/var/mysql", null) orelse return error.TestUnexpectedResult;
    for (my.argv) |a| try testing.expect(!std.mem.startsWith(u8, a, "--user="));
}

test "resolveBase maps every observed upstream token into the malt prefix" {
    var h = try TestHarness.init();
    defer h.deinit();
    const c = h.ctx();
    const a = h.arena.allocator();

    const cases = [_]struct { base: []const u8, formula: ?[]const u8, want: []const u8 }{
        .{ .base = "homebrew_prefix", .formula = null, .want = try std.fmt.allocPrint(a, "{s}", .{h.prefix}) },
        .{ .base = "prefix", .formula = null, .want = h.keg },
        .{ .base = "opt_prefix", .formula = null, .want = try std.fmt.allocPrint(a, "{s}/opt/glow", .{h.prefix}) },
        .{ .base = "var", .formula = null, .want = try std.fmt.allocPrint(a, "{s}/var", .{h.prefix}) },
        .{ .base = "etc", .formula = null, .want = try std.fmt.allocPrint(a, "{s}/etc", .{h.prefix}) },
        .{ .base = "lib", .formula = null, .want = try std.fmt.allocPrint(a, "{s}/lib", .{h.prefix}) },
        .{ .base = "bin", .formula = null, .want = try std.fmt.allocPrint(a, "{s}/bin", .{h.prefix}) },
        .{ .base = "pkgetc", .formula = null, .want = try std.fmt.allocPrint(a, "{s}/etc/glow", .{h.prefix}) },
        .{ .base = "pkgshare", .formula = null, .want = try std.fmt.allocPrint(a, "{s}/share/glow", .{h.prefix}) },
        .{ .base = "opt_pkgshare", .formula = null, .want = try std.fmt.allocPrint(a, "{s}/opt/glow/share/glow", .{h.prefix}) },
        .{ .base = "formula_pkgetc", .formula = "ca-certificates", .want = try std.fmt.allocPrint(a, "{s}/etc/ca-certificates", .{h.prefix}) },
        .{ .base = "formula_opt_prefix", .formula = "ca-certificates", .want = try std.fmt.allocPrint(a, "{s}/opt/ca-certificates", .{h.prefix}) },
    };
    for (cases) |case| {
        const got = resolveBase(c, case.base, case.formula) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.want, got);
    }

    // `home` escapes the prefix; unknown tokens have no safe mapping.
    try testing.expect(resolveBase(c, "home", null) == null);
    try testing.expect(resolveBase(c, "carport", null) == null);
    // formula-scoped bases without a formula are malformed.
    try testing.expect(resolveBase(c, "formula_pkgetc", null) == null);
}

test "execute returns false when the formula carries no steps" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(!execute(h.ctx(), try testFormulaJson(&h, "[]")));
    try testing.expect(!execute(h.ctx(),
        \\{"name":"glow","versions":{"stable":"1.2.3"}}
    ));
    try testing.expect(!h.flog.hasErrors());
}

/// Seed `<prefix>/etc/<rel>` with `body` and return its absolute path.
fn seedEtc(h: *TestHarness, rel: []const u8, body: []const u8) ![]const u8 {
    const a = h.arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/etc/{s}", .{ h.prefix, rel });
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(h.io, d);
    const f = try std.Io.Dir.createFileAbsolute(h.io, path, .{});
    try f.writeStreamingAll(h.io, body);
    f.close(h.io);
    return path;
}

fn readBack(h: *TestHarness, path: []const u8) ![]const u8 {
    const f = try std.Io.Dir.openFileAbsolute(h.io, path, .{});
    defer f.close(h.io);
    const st = try f.stat(h.io);
    const buf = try h.arena.allocator().alloc(u8, st.size);
    _ = try f.readPositionalAll(h.io, buf, 0);
    return buf;
}

test "execute substitutes a literal inreplace and resolves the invoking user" {
    // Config templating is the whole point of these steps: the shipped file
    // carries a placeholder that only the installing machine can fill in.
    var h = try TestHarness.init();
    defer h.deinit();
    h.environ = test_user_environ;
    const path = try seedEtc(&h, "glow.conf", "username: \"@@PLACEHOLDER@@\"\n");

    const json = try testFormulaJson(&h,
        \\[{"type":"inreplace","path":{"base":"etc","path":"glow.conf"},
        \\  "before":"@@PLACEHOLDER@@","after":"{{user}}",
        \\  "guards":[{"path":"{{etc}}/glow.conf","condition":"if_exists","id":"1"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqualStrings("username: \"ada\"\n", try readBack(&h, path));
}

test "execute skips an inreplace whose if_exists guard is unmet" {
    // The guard exists because the target is a user config that may never
    // have been poured; creating it here would invent configuration.
    var h = try TestHarness.init();
    defer h.deinit();
    h.environ = test_user_environ;

    const json = try testFormulaJson(&h,
        \\[{"type":"inreplace","path":{"base":"etc","path":"absent.conf"},
        \\  "before":"x","after":"{{user}}",
        \\  "guards":[{"path":"{{etc}}/absent.conf","condition":"if_exists","id":"1"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    const missing = try std.fmt.allocPrint(h.arena.allocator(), "{s}/etc/absent.conf", .{h.prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(h.io, missing, .{}));
}

test "execute rewrites a whole line for the anchored regexp form" {
    var h = try TestHarness.init();
    defer h.deinit();
    h.environ = test_user_environ;
    const path = try seedEtc(&h, "glow.cfg", "keep=1\nglow_user=nobody\nkeep=2\n");

    const json = try testFormulaJson(&h,
        \\[{"type":"inreplace","path":{"base":"etc","path":"glow.cfg"},"regexp":true,
        \\  "before":"^glow_user=.*","after":"glow_user={{user}}",
        \\  "guards":[{"path":"{{etc}}/glow.cfg","condition":"if_exists","id":"1"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqualStrings("keep=1\nglow_user=ada\nkeep=2\n", try readBack(&h, path));
}

test "execute refuses a regexp outside the anchored-line subset" {
    // There is no regex engine here. Anything richer must reach the fallback
    // rather than be approximated — a near-miss silently corrupts a config.
    var h = try TestHarness.init();
    defer h.deinit();
    h.environ = test_user_environ;
    const body = "a=1\nb=2\n";
    const path = try seedEtc(&h, "rich.cfg", body);

    const json = try testFormulaJson(&h,
        \\[{"type":"inreplace","path":{"base":"etc","path":"rich.cfg"},"regexp":true,
        \\  "before":"^(a|b)=[0-9]+$","after":"z={{user}}"}]
    );
    _ = execute(h.ctx(), json);
    try testing.expectEqualStrings(body, try readBack(&h, path));
    // Assert the refusal itself, not just an unchanged file: a widened
    // allowlist would also leave this content alone, so only the step's own
    // outcome distinguishes "declined" from "ran and matched nothing".
    try testing.expectEqual(@as(usize, 0), h.flog.handled_top_level);
    try testing.expect(h.flog.entries().len > 0);
    try testing.expectEqual(fallback_log.FallbackReason.unknown_method, h.flog.entries()[0].reason);
}

test "execute refuses an anchored regexp whose literal hides metacharacters" {
    // `^…​.*` shaped but not literal: the middle is a character class, so the
    // prefix match this executor would do is not what the pattern means. Only
    // the metacharacter allowlist can catch this — the anchor checks pass.
    var h = try TestHarness.init();
    defer h.deinit();
    h.environ = test_user_environ;
    const body = "user1=x\nuserA=y\n";
    const path = try seedEtc(&h, "class.cfg", body);

    const json = try testFormulaJson(&h,
        \\[{"type":"inreplace","path":{"base":"etc","path":"class.cfg"},"regexp":true,
        \\  "before":"^user[0-9].*","after":"user={{user}}"}]
    );
    _ = execute(h.ctx(), json);
    try testing.expectEqualStrings(body, try readBack(&h, path));
    // Assert the refusal itself, not just an unchanged file: a widened
    // allowlist would also leave this content alone, so only the step's own
    // outcome distinguishes "declined" from "ran and matched nothing".
    try testing.expectEqual(@as(usize, 0), h.flog.handled_top_level);
    try testing.expect(h.flog.entries().len > 0);
    try testing.expectEqual(fallback_log.FallbackReason.unknown_method, h.flog.entries()[0].reason);
}

test "execute refuses an inreplace whose user token cannot be resolved" {
    // With no USER in the environment the replacement would write the literal
    // token into a live config, which is worse than not running at all.
    var h = try TestHarness.init();
    defer h.deinit();
    const body = "username: \"@@PLACEHOLDER@@\"\n";
    const path = try seedEtc(&h, "nouser.conf", body);

    const json = try testFormulaJson(&h,
        \\[{"type":"inreplace","path":{"base":"etc","path":"nouser.conf"},
        \\  "before":"@@PLACEHOLDER@@","after":"{{user}}"}]
    );
    _ = execute(h.ctx(), json);
    try testing.expectEqualStrings(body, try readBack(&h, path));
}

test "anchoredLineLiteral rejects patterns with nothing to anchor on" {
    // `^.*` matches every line; treating its empty literal as a prefix would
    // rewrite the whole file.
    try testing.expect(anchoredLineLiteral("^.*") == null);
    try testing.expect(anchoredLineLiteral("user=.*") == null); // unanchored
    try testing.expect(anchoredLineLiteral("^user=") == null); // no trailing .*
    try testing.expect(anchoredLineLiteral("") == null);
    try testing.expectEqualStrings("user=", anchoredLineLiteral("^user=.*").?);
}

test "replaceAnchoredLines preserves a file with no trailing newline" {
    var h = try TestHarness.init();
    defer h.deinit();
    const got = replaceAnchoredLines(h.ctx(), "a=1\nb=2", "b=", "b=9").?;
    try testing.expectEqualStrings("a=1\nb=9", got);
}

test "execute refuses an inreplace with an empty needle" {
    // An empty `before` would match everywhere; there is no sane rewrite.
    var h = try TestHarness.init();
    defer h.deinit();
    h.environ = test_user_environ;
    const body = "keep=1\n";
    const path = try seedEtc(&h, "empty.conf", body);

    const json = try testFormulaJson(&h,
        \\[{"type":"inreplace","path":{"base":"etc","path":"empty.conf"},"before":"","after":"x"}]
    );
    _ = execute(h.ctx(), json);
    try testing.expectEqualStrings(body, try readBack(&h, path));
    try testing.expectEqual(@as(usize, 0), h.flog.handled_top_level);
}

test "execute refuses a remove that carries no target guard" {
    // Without the guard this is an unconditional delete driven by formula data.
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, bin);
    const victim = try std.fmt.allocPrint(a, "{s}/keepme", .{bin});
    (try std.Io.Dir.createFileAbsolute(h.io, victim, .{})).close(h.io);

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","paths":[{"path":"{{HOMEBREW_PREFIX}}/bin/keepme"}]}]
    );
    _ = execute(h.ctx(), json);
    try std.Io.Dir.accessAbsolute(h.io, victim, .{});
    try testing.expectEqual(@as(usize, 0), h.flog.handled_top_level);
}

test "execute refuses to remove a path outside the prefix" {
    // Confinement, not the target guard, is what stops a crafted path here.
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const outside = try std.fmt.allocPrint(a, "{s}-escape", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, outside);
    defer std.Io.Dir.cwd().deleteTree(h.io, outside) catch {};
    const dest = try std.fmt.allocPrint(a, "{s}/Cellar/glow/x", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(dest).?);
    (try std.Io.Dir.createFileAbsolute(h.io, dest, .{})).close(h.io);
    const link = try std.fmt.allocPrint(a, "{s}/victim", .{outside});
    try std.Io.Dir.symLinkAbsolute(h.io, dest, link, .{});

    const json = try std.fmt.allocPrint(a,
        \\{{"name":"glow","versions":{{"stable":"1.2.3"}},"post_install_steps":[
        \\ {{"type":"remove","symlink_target_contains":"Cellar/glow/","paths":[{{"base":"absolute","path":"{s}"}}]}}]}}
    , .{link});
    _ = execute(h.ctx(), json);
    try std.Io.Dir.accessAbsolute(h.io, link, .{});
    // Assert the guard fired rather than the step quietly not resolving: a
    // surviving link proves nothing on its own.
    try testing.expect(h.flog.entries().len > 0);
    try testing.expectEqual(fallback_log.FallbackReason.sandbox_violation, h.flog.entries()[0].reason);
}

test "execute links keg-relative template paths into the prefix" {
    // A keg-only formula can still publish its launcher and completions from
    // post_install. Those steps name the source with a `{{bin}}`-style token
    // rather than a `base`, so the token has to resolve to a keg path — an
    // unexpanded one is not absolute and used to be refused as "relative".
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const seeds = [_][]const u8{ "bin", "etc/bash_completion.d", "share/zsh/site-functions", "share/fish/vendor_completions.d", "share/pwsh/completions" };
    const leaves = [_][]const u8{ "glow", "glow", "_glow", "glow.fish", "_glow.ps1" };
    for (seeds, leaves) |dir, leaf| {
        const d = try std.fmt.allocPrint(a, "{s}/{s}", .{ h.keg, dir });
        try std.Io.Dir.cwd().createDirPath(io, d);
        const f = try std.Io.Dir.createFileAbsolute(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ d, leaf }), .{});
        f.close(io);
    }

    const json = try testFormulaJson(&h,
        \\[{"type":"symlink","force":true,"source":{"path":"{{bin}}/glow"},"target":{"path":"{{HOMEBREW_PREFIX}}/bin/glow"}},
        \\ {"type":"symlink","force":true,"source":{"path":"{{bash_completion}}/glow"},"target":{"path":"{{HOMEBREW_PREFIX}}/etc/bash_completion.d/glow"}},
        \\ {"type":"symlink","force":true,"source":{"path":"{{zsh_completion}}/_glow"},"target":{"path":"{{HOMEBREW_PREFIX}}/share/zsh/site-functions/_glow"}},
        \\ {"type":"symlink","force":true,"source":{"path":"{{fish_completion}}/glow.fish"},"target":{"path":"{{HOMEBREW_PREFIX}}/share/fish/vendor_completions.d/glow.fish"}},
        \\ {"type":"symlink","force":true,"source":{"path":"{{pwsh_completion}}/_glow.ps1"},"target":{"path":"{{HOMEBREW_PREFIX}}/share/pwsh/completions/_glow.ps1"}}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(usize, 5), h.flog.handled_top_level);

    const links = [_][]const u8{
        try std.fmt.allocPrint(a, "{s}/bin/glow", .{h.prefix}),
        try std.fmt.allocPrint(a, "{s}/etc/bash_completion.d/glow", .{h.prefix}),
        try std.fmt.allocPrint(a, "{s}/share/zsh/site-functions/_glow", .{h.prefix}),
        try std.fmt.allocPrint(a, "{s}/share/fish/vendor_completions.d/glow.fish", .{h.prefix}),
        try std.fmt.allocPrint(a, "{s}/share/pwsh/completions/_glow.ps1", .{h.prefix}),
    };
    for (links) |p| try std.Io.Dir.accessAbsolute(io, p, .{});
}

test "execute removes a symlink whose target matches the guard" {
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const stale = try std.fmt.allocPrint(a, "{s}/glow-init", .{bin});
    const dest = try std.fmt.allocPrint(a, "{s}/bin/glow", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/bin", .{h.keg}));
    (try std.Io.Dir.createFileAbsolute(io, dest, .{})).close(io);
    try std.Io.Dir.symLinkAbsolute(io, dest, stale, .{});

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","symlink_target_contains":"Cellar/glow/","paths":[{"path":"{{HOMEBREW_PREFIX}}/bin/glow-init"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, stale, .{}));
}

test "execute leaves a regular file alone on remove" {
    // The guard names a symlink target, so a real file at that path is not the
    // thing the step meant to delete. Removing it would destroy user data.
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const real = try std.fmt.allocPrint(a, "{s}/glow-init", .{bin});
    (try std.Io.Dir.createFileAbsolute(io, real, .{})).close(io);

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","symlink_target_contains":"Cellar/glow/","paths":[{"path":"{{HOMEBREW_PREFIX}}/bin/glow-init"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try std.Io.Dir.accessAbsolute(io, real, .{});
}

test "execute keeps a symlink whose target does not match the guard" {
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, bin);
    const link = try std.fmt.allocPrint(a, "{s}/glow-init", .{bin});
    const dest = try std.fmt.allocPrint(a, "{s}/etc/elsewhere", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/etc", .{h.prefix}));
    (try std.Io.Dir.createFileAbsolute(io, dest, .{})).close(io);
    try std.Io.Dir.symLinkAbsolute(io, dest, link, .{});

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","symlink_target_contains":"Cellar/glow/","paths":[{"path":"{{HOMEBREW_PREFIX}}/bin/glow-init"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try std.Io.Dir.accessAbsolute(io, link, .{});
}

test "execute runs the filesystem tier natively and leaves the log clean" {
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    // A child for link_children / link_dir to walk.
    const share = try std.fmt.allocPrint(a, "{s}/share/glow", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(io, share);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, try std.fmt.allocPrint(a, "{s}/glow.dat", .{share}), .{});
        f.close(io);
    }

    const json = try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"log/{{name}}"}},
        \\ {"type":"touch","path":{"base":"var","path":"log/glow/access.log"}},
        \\ {"type":"write","path":{"base":"var","path":"glow/.env"},"content":"# {{name}}\n"},
        \\ {"type":"symlink","force":true,"source":{"base":"prefix","path":"share/glow/glow.dat"},"target":{"base":"etc","path":"glow.dat"}},
        \\ {"type":"link_children","source":{"base":"prefix","path":"share/glow"},"target":{"base":"homebrew_prefix","path":"bin"},"suffix":"-{{version.major}}"},
        \\ {"type":"link_dir","source":{"base":"prefix","path":"share/glow"},"target":{"base":"homebrew_prefix","path":"share/glow-mirror"}}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(usize, 6), h.flog.total_top_level);
    try testing.expectEqual(@as(usize, 6), h.flog.handled_top_level);

    const checks = [_][]const u8{
        try std.fmt.allocPrint(a, "{s}/var/log/glow/access.log", .{h.prefix}),
        try std.fmt.allocPrint(a, "{s}/var/glow/.env", .{h.prefix}),
        try std.fmt.allocPrint(a, "{s}/etc/glow.dat", .{h.prefix}),
        try std.fmt.allocPrint(a, "{s}/bin/glow.dat-1", .{h.prefix}),
        try std.fmt.allocPrint(a, "{s}/share/glow-mirror/glow.dat", .{h.prefix}),
    };
    for (checks) |p| {
        const f = std.Io.Dir.openFileAbsolute(io, p, .{}) catch return error.TestUnexpectedResult;
        f.close(io);
    }

    // Template expanded inside written content.
    var buf: [64]u8 = undefined;
    const env = try std.Io.Dir.openFileAbsolute(io, checks[1], .{});
    defer env.close(io);
    const n = try env.readPositionalAll(io, &buf, 0);
    try testing.expectEqualStrings("# glow\n", buf[0..n]);
}

test "write respects existing files unless overwrite is set" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const io = h.io;

    const path = try std.fmt.allocPrint(a, "{s}/etc/glow.conf", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
        try f.writeStreamingAll(io, "user edited\n");
        f.close(io);
    }

    // Default: an existing file is the user's — leave it alone.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"write","path":{"base":"etc","path":"glow.conf"},"content":"fresh\n"}]
    )));
    var buf: [64]u8 = undefined;
    {
        const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer f.close(io);
        const n = try f.readPositionalAll(io, &buf, 0);
        try testing.expectEqualStrings("user edited\n", buf[0..n]);
    }

    // overwrite:true replaces it.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"write","path":{"base":"etc","path":"glow.conf"},"content":"fresh\n","overwrite":true}]
    )));
    {
        const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer f.close(io);
        const n = try f.readPositionalAll(io, &buf, 0);
        try testing.expectEqualStrings("fresh\n", buf[0..n]);
    }
    try testing.expect(!h.flog.hasErrors());
}

test "a planted directory symlink cannot redirect a later step outside the prefix" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const io = h.io;

    // A genuinely-outside writable location: a SIBLING of the prefix, so
    // the component-boundary prefix check does not treat it as contained.
    const outside = try std.fmt.allocPrint(a, "{s}-OUTSIDE", .{h.prefix});
    std.Io.Dir.cwd().deleteTree(io, outside) catch {};
    try std.Io.Dir.cwd().createDirPath(io, outside);
    defer std.Io.Dir.cwd().deleteTree(io, outside) catch {};

    // Step 1 plants <prefix>/etc/la -> <outside>; step 2 tries to mkdir_p
    // and write *through* that symlink. Every mutating step must resolve
    // the parent chain and refuse, so nothing lands under <outside>.
    const json = try std.fmt.allocPrint(a,
        \\{{"name":"glow","versions":{{"stable":"1.2.3"}},"post_install_defined":false,"post_install_steps":[
        \\ {{"type":"symlink","force":true,"source":{{"base":"absolute","path":"{s}"}},"target":{{"base":"etc","path":"la"}}}},
        \\ {{"type":"mkdir_p","path":{{"base":"etc","path":"la/sub"}}}},
        \\ {{"type":"write","path":{{"base":"etc","path":"la/pwned"}},"content":"x"}}]}}
    , .{outside});
    try testing.expect(execute(h.ctx(), json));

    // The escape must have left nothing behind outside the prefix.
    const leaked_dir = try std.fmt.allocPrint(a, "{s}/sub", .{outside});
    const leaked_file = try std.fmt.allocPrint(a, "{s}/pwned", .{outside});
    try testing.expect(std.Io.Dir.openDirAbsolute(io, leaked_dir, .{}) == error.FileNotFound);
    try testing.expect(std.Io.Dir.openFileAbsolute(io, leaked_file, .{}) == error.FileNotFound);
    // And the redirect steps were refused as violations, not counted handled.
    try testing.expect(h.flog.hasFatal());
}

test "a step resolving outside the prefix is refused and logged as a sandbox violation" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Path is runtime-built so the target the refused step names is the very
    // one asserted absent below, even with test binaries running concurrently.
    var s = try Scratch.init("steps_escape_zz");
    defer s.deinit();
    const steps = try std.fmt.allocPrint(a,
        \\[{{"type":"mkdir_p","path":{{"base":"absolute","path":"{s}"}}}}]
    , .{s.base});

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h, steps)));
    try testing.expect(h.flog.hasFatal());
    var escaped = true;
    _ = std.Io.Dir.openDirAbsolute(h.io, s.base, .{}) catch {
        escaped = false;
    };
    try testing.expect(!escaped);
}

test "unknown step types downgrade to the loud partial skip" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"glow"}},
        \\ {"type":"frobnicate"}]
    )));
    try testing.expect(h.flog.hasErrors());
    try testing.expect(!h.flog.hasFatal());
    try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
    try testing.expectEqual(fallback_log.FallbackReason.unknown_method, h.flog.entries()[0].reason);
    // The supported step still ran and counted as handled.
    try testing.expectEqual(@as(usize, 2), h.flog.total_top_level);
    try testing.expectEqual(@as(usize, 1), h.flog.handled_top_level);
}

test "initDataDirPlan builds each initialiser's argv and marker" {
    var h = try TestHarness.init();
    defer h.deinit();
    const c = h.ctx();

    const pg = initDataDirPlan(c, "postgresql_initdb", "/p/var/postgresql", null) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/p/var/postgresql/PG_VERSION", pg.marker);
    try testing.expect(std.mem.endsWith(u8, pg.argv[0], "/bin/initdb"));
    try testing.expect(std.mem.startsWith(u8, pg.argv[0], h.keg));
    try testing.expectEqualStrings("--locale=en_US.UTF-8", pg.argv[1]);
    try testing.expectEqualStrings("/p/var/postgresql", pg.argv[pg.argv.len - 1]);

    // A step-supplied locale overrides the default.
    const pg_it = initDataDirPlan(c, "postgresql_initdb", "/p/var/postgresql", "it_IT.UTF-8") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("--locale=it_IT.UTF-8", pg_it.argv[1]);

    const my = initDataDirPlan(c, "mysql_initialize", "/p/var/mysql", null) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/p/var/mysql/mysql/general_log.CSM", my.marker);
    try testing.expect(std.mem.endsWith(u8, my.argv[0], "/bin/mysqld"));
    try testing.expectEqualStrings("--initialize-insecure", my.argv[1]);

    const maria = initDataDirPlan(c, "mariadb_install_db", "/p/var/mysql", null) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/p/var/mysql/mysql/user.frm", maria.marker);
    try testing.expect(std.mem.endsWith(u8, maria.argv[0], "/bin/mysql_install_db"));

    // The confined tmpdir replaces brew's /tmp — the fence has no /tmp grant.
    var found_tmpdir = false;
    for (my.argv) |a| {
        if (std.mem.startsWith(u8, a, "--tmpdir=")) {
            try testing.expect(std.mem.indexOf(u8, a, h.prefix) != null);
            found_tmpdir = true;
        }
    }
    try testing.expect(found_tmpdir);

    // Unknown initialisers have no safe plan.
    try testing.expect(initDataDirPlan(c, "sqlite_seed", "/p/var/x", null) == null);
}

test "init_data_dir skips initialisation when the marker file exists" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Marker present → already initialised; the step must count as handled
    // without spawning anything (no initdb exists in this fixture keg).
    const datadir = try std.fmt.allocPrint(a, "{s}/var/postgresql", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, datadir);
    {
        const f = try std.Io.Dir.createFileAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/PG_VERSION", .{datadir}), .{});
        f.close(h.io);
    }

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"init_data_dir","path":{"base":"var","path":"postgresql"},"using":"postgresql_initdb"}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(usize, 1), h.flog.handled_top_level);
}

test "a confinement violation aborts the remaining steps like the DSL interpreter" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    var s = try Scratch.init("steps_escape_abort");
    defer s.deinit();
    const steps = try std.fmt.allocPrint(a,
        \\[{{"type":"mkdir_p","path":{{"base":"absolute","path":"{s}"}}}},
        \\ {{"type":"mkdir_p","path":{{"base":"var","path":"after-violation"}}}}]
    , .{s.base});

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h, steps)));
    try testing.expect(h.flog.hasFatal());
    // The step after the violation must never have run.
    const after = try std.fmt.allocPrint(a, "{s}/var/after-violation", .{h.prefix});
    var ran_after = true;
    _ = std.Io.Dir.openDirAbsolute(h.io, after, .{}) catch {
        ran_after = false;
    };
    try testing.expect(!ran_after);
    try testing.expectEqual(@as(usize, 1), h.flog.total_top_level);
}

test "init_data_dir removes a datadir it created when the initialiser fails" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const io = h.io;

    // An initialiser that runs and exits non-zero: symlink to /usr/bin/false.
    const keg_bin = try std.fmt.allocPrint(a, "{s}/bin", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(io, keg_bin);
    try std.Io.Dir.symLinkAbsolute(io, "/usr/bin/false", try std.fmt.allocPrint(a, "{s}/mysqld", .{keg_bin}), .{});

    const step_json = try testFormulaJson(&h,
        \\[{"type":"init_data_dir","path":{"base":"var","path":"mysql"},"using":"mysql_initialize"}]
    );
    try testing.expect(execute(h.ctx(), step_json));
    try testing.expect(h.flog.hasErrors());
    // The datadir this run created must be gone so a retry starts clean —
    // mysqld refuses a non-empty datadir, so leftovers brick every retry.
    const datadir = try std.fmt.allocPrint(a, "{s}/var/mysql", .{h.prefix});
    var still_there = true;
    _ = std.Io.Dir.openDirAbsolute(io, datadir, .{}) catch {
        still_there = false;
    };
    try testing.expect(!still_there);

    // A pre-existing datadir is user data: a failed re-run must not touch it.
    try std.Io.Dir.cwd().createDirPath(io, datadir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, try std.fmt.allocPrint(a, "{s}/precious", .{datadir}), .{});
        f.close(io);
    }
    try testing.expect(execute(h.ctx(), step_json));
    const f = std.Io.Dir.openFileAbsolute(io, try std.fmt.allocPrint(a, "{s}/precious", .{datadir}), .{}) catch return error.TestUnexpectedResult;
    f.close(io);
}

test "init_data_dir with a missing initialiser binary fails loudly" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"init_data_dir","path":{"base":"var","path":"postgresql"},"using":"postgresql_initdb"}]
    )));
    try testing.expect(h.flog.hasErrors());
    try testing.expectEqual(fallback_log.FallbackReason.system_command_failed, h.flog.entries()[0].reason);
}

test "init_data_dir with an unknown initialiser downgrades to the partial skip" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"init_data_dir","path":{"base":"var","path":"x"},"using":"sqlite_seed"}]
    )));
    try testing.expect(h.flog.hasErrors());
    try testing.expect(!h.flog.hasFatal());
    try testing.expectEqual(fallback_log.FallbackReason.unknown_method, h.flog.entries()[0].reason);
}

test "a missing helper tool is a loud command failure, not a silent skip" {
    var h = try TestHarness.init();
    defer h.deinit();

    // No glib keg exists under the test prefix, so the tool can't resolve.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"compile_gsettings_schemas","path":{"base":"homebrew_prefix","path":"share/glib-2.0/schemas"}}]
    )));
    try testing.expect(h.flog.hasErrors());
    try testing.expectEqual(fallback_log.FallbackReason.system_command_failed, h.flog.entries()[0].reason);
}

test "allStepsSupported classifies migrated formulas for the doctor probe" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    try testing.expect(allStepsSupported(a, try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"glow"}},
        \\ {"type":"gtk_update_icon_cache","path":{"base":"homebrew_prefix","path":"share/icons"}}]
    )));
    try testing.expect(allStepsSupported(a, try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"glow"}},
        \\ {"type":"init_data_dir","path":{"base":"var","path":"glow"},"using":"postgresql_initdb"}]
    )));
    try testing.expect(!allStepsSupported(a, try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"glow"}},
        \\ {"type":"move","source":{"base":"var","path":"a"},"target":{"base":"var","path":"b"}}]
    )));
    // No steps at all → nothing to support.
    try testing.expect(!allStepsSupported(a, try testFormulaJson(&h, "[]")));
}

test "gdkPixbufEnvPaths derives the malt-prefix module dir and cache file" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // No gdk-pixbuf keg → no safe env to derive.
    try testing.expect(gdkPixbufEnvPaths(h.ctx()) == null);

    const moddir = try std.fmt.allocPrint(a, "{s}/opt/gdk-pixbuf/lib/gdk-pixbuf-2.0/2.10.0", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, moddir);

    const env = gdkPixbufEnvPaths(h.ctx()) orelse return error.TestUnexpectedResult;
    const want_dir = try std.fmt.allocPrint(a, "{s}/lib/gdk-pixbuf-2.0/2.10.0/loaders", .{h.prefix});
    const want_file = try std.fmt.allocPrint(a, "{s}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache", .{h.prefix});
    try testing.expectEqualStrings(want_dir, env.moduledir);
    try testing.expectEqualStrings(want_file, env.module_file);
}

test "gtk_update_icon_cache picks the gtk4 tool when present, else falls back to gtk+3" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // No gtk4 keg → the gtk+3 branch is chosen; the missing-tool failure
    // names the gtk3 binary, pinning the fallback selection.
    const step_json = try testFormulaJson(&h,
        \\[{"type":"gtk_update_icon_cache","path":{"base":"homebrew_prefix","path":"share/icons/hicolor"}}]
    );
    try testing.expect(execute(h.ctx(), step_json));
    try testing.expect(std.mem.indexOf(u8, h.flog.entries()[0].detail, "gtk3-update-icon-cache") != null);

    // A gtk4 probe file flips the selection; the failure now names the
    // gtk4 binary (present but not executable in this fixture).
    const gtk4_bin = try std.fmt.allocPrint(a, "{s}/opt/gtk4/bin", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, gtk4_bin);
    {
        const f = try std.Io.Dir.createFileAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/gtk4-update-icon-cache", .{gtk4_bin}), .{});
        f.close(h.io);
    }
    try testing.expect(execute(h.ctx(), step_json));
    const last = h.flog.entries()[h.flog.entries().len - 1];
    try testing.expect(std.mem.indexOf(u8, last.detail, "gtk4-update-icon-cache") != null);
}

test "link_children honours the link-name prefix and treats a missing source as a no-op" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const io = h.io;

    const share = try std.fmt.allocPrint(a, "{s}/share/glow", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(io, share);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, try std.fmt.allocPrint(a, "{s}/tool", .{share}), .{});
        f.close(io);
    }

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"link_children","source":{"base":"prefix","path":"share/glow"},"target":{"base":"homebrew_prefix","path":"bin"},"prefix":"{{name}}-"}]
    )));
    try testing.expect(!h.flog.hasErrors());
    const linked = try std.fmt.allocPrint(a, "{s}/bin/glow-tool", .{h.prefix});
    const f = std.Io.Dir.openFileAbsolute(io, linked, .{}) catch return error.TestUnexpectedResult;
    f.close(io);

    // Missing source dir: counted as handled with nothing created — the
    // upstream runner iterates zero children the same way.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"link_children","source":{"base":"prefix","path":"share/ghost"},"target":{"base":"homebrew_prefix","path":"bin"}}]
    )));
    try testing.expect(!h.flog.hasErrors());
}

test "supportedStepType matches the executable tier and rejects the rest" {
    const native = [_][]const u8{
        "mkdir_p",                  "touch",                 "write",                     "symlink",
        "link_dir",                 "link_children",         "compile_gsettings_schemas", "gio_querymodules",
        "gdk_pixbuf_query_loaders", "gtk_update_icon_cache", "update_mime_database",      "update_desktop_database",
        "init_data_dir",            "remove",                "inreplace",
    };
    for (native) |t| try testing.expect(supportedStepType(t));
    const routed = [_][]const u8{ "mkdir", "move", "move_children", "frobnicate" };
    for (routed) |t| try testing.expect(!supportedStepType(t));
}

test "expandTemplates resolves the keg/prefix tokens that only existed as bases" {
    // `{{libexec}}` and `{{pkgetc}}` resolve as *bases* but were absent from
    // the template map, so a step embedding one inline kept the literal
    // `{{...}}`, which then read as a relative path and died in the sandbox.
    // node (`{{libexec}}/lib/node_modules/npm`) and gnutls
    // (`{{pkgetc}}/cert.pem`) both hit this.
    var h = try TestHarness.init();
    defer h.deinit();
    const c = h.ctx();

    const libexec = try expandTemplates(c, "{{libexec}}/lib/node_modules/npm");
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(h.arena.allocator(), "{s}/libexec/lib/node_modules/npm", .{h.keg}),
        libexec,
    );
    const pkgetc = try expandTemplates(c, "{{pkgetc}}/cert.pem");
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(h.arena.allocator(), "{s}/etc/glow/cert.pem", .{h.prefix}),
        pkgetc,
    );
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(h.arena.allocator(), "{s}/share/glow", .{h.prefix}),
        try expandTemplates(c, "{{pkgshare}}"),
    );
    // `{{bin}}` must keep meaning the *keg's* bin: the template and base maps
    // disagree on that name on purpose, and merging them would repoint every
    // existing step.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(h.arena.allocator(), "{s}/bin", .{h.keg}),
        try expandTemplates(c, "{{bin}}"),
    );
}

test "copy places the source inside an existing directory target, not its contents" {
    // node's shape exactly: copy <keg>/libexec/lib/node_modules/npm into
    // <prefix>/lib/node_modules, which must yield .../node_modules/npm/... so
    // the symlink steps that follow can find bin/npm-cli.js. Copying the
    // *contents* instead leaves that symlink dangling and npm missing.
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/libexec/lib/node_modules/npm/bin", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, src);
    const cli = try std.fmt.allocPrint(a, "{s}/npm-cli.js", .{src});
    {
        const f = try std.Io.Dir.createFileAbsolute(h.io, cli, .{ .truncate = true });
        defer f.close(h.io);
        try f.writeStreamingAll(h.io, "#cli\n");
    }
    const dstdir = try std.fmt.allocPrint(a, "{s}/lib/node_modules", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, dstdir);

    const json = try testFormulaJson(&h,
        \\[{"type":"copy","force":true,
        \\  "source":{"path":"{{libexec}}/lib/node_modules/npm"},
        \\  "target":{"path":"{{HOMEBREW_PREFIX}}/lib/node_modules"}}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());

    // Landed as node_modules/npm/bin/npm-cli.js …
    const want = try std.fmt.allocPrint(a, "{s}/npm/bin/npm-cli.js", .{dstdir});
    try std.Io.Dir.accessAbsolute(h.io, want, .{});
    // … and not flattened one level up.
    const flat = try std.fmt.allocPrint(a, "{s}/bin/npm-cli.js", .{dstdir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(h.io, flat, .{}));
}

test "copy refuses a source outside the keg and prefix" {
    // The destination is confined; the source was only checked for being
    // absolute, so a tap could clone any readable tree into the prefix. Mirror
    // of the source-side guard the DSL's cp/cp_r already carry.
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const outside = try std.fmt.allocPrint(a, "{s}.outside", .{h.prefix});
    defer std.Io.Dir.cwd().deleteTree(h.io, outside) catch {};
    try std.Io.Dir.cwd().createDirPath(h.io, outside);
    {
        const f = try std.Io.Dir.createFileAbsolute(
            h.io,
            try std.fmt.allocPrint(a, "{s}/secret", .{outside}),
            .{ .truncate = true },
        );
        defer f.close(h.io);
        try f.writeStreamingAll(h.io, "private\n");
    }

    const json = try testFormulaJson(&h, try std.fmt.allocPrint(a,
        \\[{{"type":"copy",
        \\  "source":{{"path":"{s}"}},
        \\  "target":{{"path":"{{{{HOMEBREW_PREFIX}}}}/share/stolen"}}}}]
    , .{outside}));
    _ = execute(h.ctx(), json);
    try testing.expect(h.flog.hasErrors());

    const landed = try std.fmt.allocPrint(a, "{s}/share/stolen", .{h.prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(h.io, landed, .{}));
}

test "copy refuses a source that is a symlink out of the keg" {
    // The keg is tap-controlled, so a bottle can ship the doorway itself. The
    // DSL's cp/cp_r already refuse a symlink-leaf source; this step must too.
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const outside = try std.fmt.allocPrint(a, "{s}.outside", .{h.prefix});
    defer std.Io.Dir.cwd().deleteTree(h.io, outside) catch {};
    try std.Io.Dir.cwd().createDirPath(h.io, outside);
    {
        const f = try std.Io.Dir.createFileAbsolute(
            h.io,
            try std.fmt.allocPrint(a, "{s}/secret", .{outside}),
            .{ .truncate = true },
        );
        defer f.close(h.io);
        try f.writeStreamingAll(h.io, "private\n");
    }

    const libexec = try std.fmt.allocPrint(a, "{s}/libexec", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, libexec);
    const doorway = try std.fmt.allocPrint(a, "{s}/doorway", .{libexec});
    try std.Io.Dir.symLinkAbsolute(h.io, outside, doorway, .{});

    const json = try testFormulaJson(&h,
        \\[{"type":"copy",
        \\  "source":{"path":"{{libexec}}/doorway"},
        \\  "target":{"path":"{{HOMEBREW_PREFIX}}/share/stolen"}}]
    );
    _ = execute(h.ctx(), json);

    const landed = try std.fmt.allocPrint(a, "{s}/share/stolen/secret", .{h.prefix});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(h.io, landed, .{}));
}

test "copy refuses a target outside the keg and prefix" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/libexec", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, src);

    const json = try testFormulaJson(&h,
        \\[{"type":"copy","force":true,
        \\  "source":{"path":"{{libexec}}"},
        \\  "target":{"path":"/tmp/malt_copy_escape_target"}}]
    );
    _ = execute(h.ctx(), json);
    try testing.expect(h.flog.hasErrors());
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, "/tmp/malt_copy_escape_target", .{}),
    );
}

test "copy replaces a stale destination even without a force flag" {
    // Regression for a real upgrade failure: node's copy step carries no
    // `force`, so an implementation that skips an existing destination leaves
    // the previous npm in place. The keg moved to 11.19.0 while the prefix
    // stayed on 11.17.0 — the copy has to overwrite, as `cp_r` does.
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/libexec/lib/node_modules/npm", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, src);
    {
        const f = try std.Io.Dir.createFileAbsolute(
            h.io,
            try std.fmt.allocPrint(a, "{s}/version.txt", .{src}),
            .{ .truncate = true },
        );
        defer f.close(h.io);
        try f.writeStreamingAll(h.io, "new\n");
    }

    // A stale copy already sitting at the destination.
    const dstdir = try std.fmt.allocPrint(a, "{s}/lib/node_modules", .{h.prefix});
    const stale = try std.fmt.allocPrint(a, "{s}/npm", .{dstdir});
    try std.Io.Dir.cwd().createDirPath(h.io, stale);
    {
        const f = try std.Io.Dir.createFileAbsolute(
            h.io,
            try std.fmt.allocPrint(a, "{s}/version.txt", .{stale}),
            .{ .truncate = true },
        );
        defer f.close(h.io);
        try f.writeStreamingAll(h.io, "old\n");
    }

    const json = try testFormulaJson(&h,
        \\[{"type":"copy",
        \\  "source":{"path":"{{libexec}}/lib/node_modules/npm"},
        \\  "target":{"path":"{{HOMEBREW_PREFIX}}/lib/node_modules"}}]
    );
    try testing.expect(execute(h.ctx(), json));

    const got = try readBack(&h, try std.fmt.allocPrint(a, "{s}/version.txt", .{stale}));
    try testing.expectEqualStrings("new\n", got);
}
