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
const builtin = @import("builtin");
const sandbox = @import("dsl/sandbox.zig");
const sandbox_macos = @import("sandbox/macos.zig");
const fallback_log = @import("dsl/fallback_log.zig");
const atomic = @import("../fs/atomic.zig");
const ca_bundle = @import("ca_bundle.zig");
const clonefile = @import("../fs/clonefile.zig");
const fs_read = @import("../fs/read.zig");
const text_replace = @import("../text_replace.zig");
const glob_match = @import("../glob.zig");
const patch = @import("patch.zig");
const codesign = @import("../macho/codesign.zig");
const system_tools = @import("../system_tools.zig");

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
    run,
    move,
    warn,
    set_permissions,
    install_gzipped_executable,
    change_dylib_id,
    terminate_process,
    configure_clang_system,
    configure_gcc_runtime,
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
    .{ "run", .run },
    .{ "move", .move },
    .{ "warn", .warn },
    .{ "set_permissions", .set_permissions },
    .{ "install_gzipped_executable", .install_gzipped_executable },
    .{ "change_dylib_id", .change_dylib_id },
    .{ "terminate_process", .terminate_process },
    .{ "configure_clang_system", .configure_clang_system },
    .{ "configure_gcc_runtime", .configure_gcc_runtime },
});

/// Bookkeeping every step may carry: routing, gating, and audit hints that
/// say nothing about the work itself.
const common_keys = [_][]const u8{ "type", "guards", "id", "skip_audit" };

/// The fields each step actually honours. Anything else upstream sends is a
/// declaration this executor would drop on the floor.
fn honouredKeys(tag: StepTag) []const []const u8 {
    return switch (tag) {
        .mkdir_p,
        .touch,
        .compile_gsettings_schemas,
        .gio_querymodules,
        .update_mime_database,
        .update_desktop_database,
        .gtk_update_icon_cache,
        => &.{"path"},
        .gdk_pixbuf_query_loaders => &.{},
        .write => &.{ "path", "content", "overwrite" },
        .symlink => &.{ "source", "target", "force", "source_glob" },
        // `force` needs no branch: copy always replaces, as `cp_r` does.
        .copy => &.{ "source", "target", "recursive", "force" },
        .link_dir => &.{ "source", "target" },
        .link_children => &.{ "source", "target", "prefix", "suffix" },
        .remove => &.{ "paths", "recursive", "symlink_target_contains" },
        .inreplace => &.{ "path", "before", "after", "regexp" },
        .init_data_dir => &.{ "path", "using", "locale" },
        .run => &.{ "command", "args", "sudo" },
        // `force` is upstream's alias for `overwrite` on this step.
        .move => &.{ "source", "target", "overwrite", "force" },
        .warn => &.{"message"},
        .set_permissions => &.{ "paths", "permissions", "non_recursive" },
        .install_gzipped_executable => &.{ "source", "target" },
        .change_dylib_id => &.{ "source", "id", "resolve_source" },
        // Deliberately narrow: `sudo`/`must_succeed` would change what the
        // step is allowed to do, so they must refuse rather than be dropped.
        .terminate_process => &.{"name"},
        .configure_clang_system, .configure_gcc_runtime => &.{},
    };
}

/// Upstream compacts defaults away, so a key that survives into the JSON is
/// one the formula meant. Doing the work while ignoring it is worse than
/// refusing: the install looks complete and quietly is not.
fn unhonouredKey(ctx: StepsCtx, tag: StepTag, obj: std.json.ObjectMap) bool {
    var it = obj.iterator();
    keys: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        for (common_keys) |k| if (std.mem.eql(u8, key, k)) continue :keys;
        for (honouredKeys(tag)) |k| if (std.mem.eql(u8, key, k)) continue :keys;
        const detail = std.fmt.allocPrint(ctx.allocator, "{s} with {s}", .{ @tagName(tag), key }) catch key;
        logUnsupported(ctx, detail);
        return true;
    }
    return false;
}

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

    // Types with no entry above are refused here on purpose: php and the
    // legacy python/pypy bootstrappers are whole subsystems, and the glibc
    // runtime never reaches a macOS bottle. A loud skip beats a stub.
    const tag = step_map.get(step_type) orelse {
        logUnsupported(ctx, step_type);
        return false;
    };
    if (unhonouredKey(ctx, tag, obj)) return false;

    // Central, so a guard holds back every step type. Leaving this to each
    // step meant most of them ran regardless of what the formula declared.
    switch (evalGuards(ctx, obj)) {
        .met => {},
        .unmet => return true,
        .unsupported => {
            logUnsupported(ctx, "a guard this executor cannot evaluate");
            return false;
        },
    }

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
        .run => stepRun(ctx, obj),
        .move => stepMove(ctx, obj),
        .warn => stepWarn(ctx, obj),
        .set_permissions => stepSetPermissions(ctx, obj),
        .install_gzipped_executable => stepInstallGzippedExecutable(ctx, obj),
        .change_dylib_id => stepChangeDylibId(ctx, obj),
        .terminate_process => stepTerminateProcess(ctx, obj),
        .configure_clang_system => stepConfigureClangSystem(ctx),
        .configure_gcc_runtime => stepConfigureGccRuntime(ctx),
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
    prefix_var,
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
    .{ "var", .prefix_var },
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
        .prefix_var => std.fmt.allocPrint(a, "{s}/var", .{ctx.prefix}) catch null,
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
    libexec,
    pkgetc,
    pkgshare,
    opt_pkgshare,
    frameworks,
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
    // Keg-relative, unlike its prefix-scoped neighbours — same meaning a `run`
    // command's `libexec` base already carries.
    .{ "libexec", .libexec },
    .{ "pkgetc", .pkgetc },
    .{ "pkgshare", .pkgshare },
    .{ "opt_pkgshare", .opt_pkgshare },
    // Keg-relative, like `libexec`: upstream's `frameworks` is `prefix/Frameworks`.
    .{ "frameworks", .frameworks },
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
        .libexec => std.fmt.allocPrint(a, "{s}/libexec", .{ctx.keg_path}) catch null,
        .pkgetc => std.fmt.allocPrint(a, "{s}/etc/{s}", .{ ctx.prefix, ctx.name }) catch null,
        .pkgshare => std.fmt.allocPrint(a, "{s}/share/{s}", .{ ctx.prefix, ctx.name }) catch null,
        .opt_pkgshare => std.fmt.allocPrint(a, "{s}/opt/{s}/share/{s}", .{ ctx.prefix, ctx.name, ctx.name }) catch null,
        .frameworks => std.fmt.allocPrint(a, "{s}/Frameworks", .{ctx.keg_path}) catch null,
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
/// A null `key` resolves quietly, for callers that report the failure better
/// themselves than a second entry for the same spec would.
fn resolveSpec(ctx: StepsCtx, spec: std.json.ObjectMap, key: ?[]const u8) ?[]const u8 {
    const raw = getString(spec, "path") orelse {
        if (key) |k| logUnsupported(ctx, k);
        return null;
    };
    const path = expandTemplates(ctx, raw) catch return null;
    const base = getString(spec, "base") orelse "absolute";
    if (std.mem.eql(u8, base, "absolute") or std.mem.eql(u8, base, "relative")) return path;
    const root = resolveBase(ctx, base, getString(spec, "formula")) orelse {
        if (key != null)
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
    if (getFlag(obj, "source_glob")) return symlinkGlob(ctx, obj, source, target);
    mkParent(ctx, target);
    if (getFlag(obj, "force")) std.Io.Dir.cwd().deleteFile(ctx.io, target) catch {};
    std.Io.Dir.symLinkAbsolute(ctx.io, source, target, .{}) catch {};
    return true;
}

/// `source_glob`: the source's last component is a pattern and `target` is the
/// directory every match lands in, keeping its own name. Without this the
/// pattern would be symlinked verbatim and the files silently go unlinked.
fn symlinkGlob(ctx: StepsCtx, obj: std.json.ObjectMap, source: []const u8, target: []const u8) bool {
    const dir_path = std.fs.path.dirname(source) orelse return false;
    const pattern = std.fs.path.basename(source);

    std.Io.Dir.cwd().createDirPath(ctx.io, target) catch {};
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, dir_path, .{ .iterate = true }) catch return true;
    defer dir.close(ctx.io);

    const force = getFlag(obj, "force");
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (!glob_match.match(pattern, entry.name)) continue;
        const child = std.fs.path.join(ctx.allocator, &.{ dir_path, entry.name }) catch continue;
        const link_path = std.fs.path.join(ctx.allocator, &.{ target, entry.name }) catch continue;
        // Each match is its own write: a planted symlink must not redirect
        // one of them out of the prefix.
        if (!confined(ctx, link_path)) return false;
        if (force) std.Io.Dir.cwd().deleteFile(ctx.io, link_path) catch {};
        std.Io.Dir.symLinkAbsolute(ctx.io, child, link_path, .{}) catch {};
    }
    return true;
}

/// `guards` gate a step on a path's state. `unsupported` keeps a condition
/// this executor cannot check distinguishable from one that genuinely did not
/// hold, so a caller can refuse loudly instead of reading it as a skip.
const GuardOutcome = enum { met, unmet, unsupported };

const GuardCondition = enum { if_exists, unless_exists, on };

const guard_condition_map = std.StaticStringMap(GuardCondition).initComptime(.{
    .{ "if_exists", .if_exists },
    .{ "unless_exists", .unless_exists },
    .{ "on", .on },
});

fn evalGuards(ctx: StepsCtx, obj: std.json.ObjectMap) GuardOutcome {
    const guards = obj.get("guards") orelse return .met;
    if (guards != .array) return .met;
    for (guards.array.items) |item| {
        if (item != .object) continue;
        const raw = getString(item.object, "condition") orelse return .unsupported;
        const condition = guard_condition_map.get(raw) orelse return .unsupported;
        // Dispatched before any spec resolution: an `on` guard carries a
        // platform value and no path at all.
        const outcome = switch (condition) {
            .on => platformGuard(item.object),
            .if_exists => existsGuard(ctx, item.object, true),
            .unless_exists => existsGuard(ctx, item.object, false),
        };
        if (outcome != .met) return outcome;
    }
    return .met;
}

const Platform = enum { macos, linux };

const platform_map = std.StaticStringMap(Platform).initComptime(.{
    .{ "macos", .macos },
    .{ "linux", .linux },
});

/// malt builds macOS-only, so the platform is known at compile time — this is a
/// real evaluation, not a stub standing in for one.
fn platformGuard(spec: std.json.ObjectMap) GuardOutcome {
    const value = getString(spec, "value") orelse return .unsupported;
    return switch (platform_map.get(value) orelse return .unsupported) {
        .macos => .met,
        .linux => .unmet,
    };
}

fn existsGuard(ctx: StepsCtx, spec: std.json.ObjectMap, want_exists: bool) GuardOutcome {
    // A guard carries the same `{base, path}` spec as the step it gates, so it
    // must resolve the same way or it tests the wrong location.
    const path = resolveSpec(ctx, spec, null) orelse return .unsupported;
    return if (pathExists(ctx.io, path) == want_exists) .met else .unmet;
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

    const file = sandbox.openSourceNoFollow(ctx.io, path, ctx.keg_path, ctx.prefix) catch |e| {
        if (e == error.PathSandboxViolation) logViolation(ctx, path);
        return false;
    };
    defer file.close(ctx.io);
    const stat = file.stat(ctx.io) catch return false;
    if (stat.size > 4 * 1024 * 1024) return false;
    const content = fs_read.readFileAll(ctx.io, ctx.allocator, file, 4 * 1024 * 1024) catch return false;

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
    const paths_val = obj.get("paths") orelse {
        logUnsupported(ctx, "remove");
        return false;
    };
    if (paths_val != .array) {
        logUnsupported(ctx, "remove");
        return false;
    }

    const needle = getString(obj, "symlink_target_contains") orelse {
        if (getFlag(obj, "recursive")) return removeTrees(ctx, paths_val.array.items);
        // Neither a symlink guard nor an explicit recursive intent leaves
        // nothing to infer safely.
        logUnsupported(ctx, "remove without symlink_target_contains");
        return false;
    };

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

/// Retire a subtree this formula owns, so the `copy` that follows starts
/// clean. Confinement keeps it inside the prefix; `sharedPrefixDir` keeps it
/// off the top-level directories every other package also writes into.
fn removeTrees(ctx: StepsCtx, items: []const std.json.Value) bool {
    for (items) |item| {
        if (item != .object) continue;
        const spec = resolveSpec(ctx, item.object, "paths") orelse continue;
        // ruby names the tree to retire as `gems/bundler-*`; a literal path
        // matches nothing, so the stale copy would survive every upgrade.
        const paths = expandGlob(ctx, spec) orelse return false;
        for (paths) |path| {
            if (!confined(ctx, path)) return false;
            if (sharedPrefixDir(ctx, path)) {
                logUnsupported(ctx, "recursive remove of a shared prefix directory");
                return false;
            }
            std.Io.Dir.cwd().deleteTree(ctx.io, path) catch {};
        }
    }
    return true;
}

/// True for the prefix itself and its immediate children (`<prefix>/lib`,
/// `<prefix>/bin`, …) — shared ground, never one formula's to delete.
fn sharedPrefixDir(ctx: StepsCtx, path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (std.mem.eql(u8, trimmed, ctx.prefix)) return true;
    const parent = std.fs.path.dirname(trimmed) orelse return true;
    return std.mem.eql(u8, parent, ctx.prefix);
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

/// `move`: relocate a tree the formula shipped — nginx lifts its default
/// docroot out of the keg into `<prefix>/var`. Both ends are confined like
/// every other write.
fn stepMove(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const source = resolvePathSpec(ctx, obj, "source") orelse return false;
    const target = resolvePathSpec(ctx, obj, "target") orelse return false;
    // Checked before confinement so a bottle that shipped no source reports as
    // the mismatch it is, rather than as a fatal confinement violation.
    if (!pathExists(ctx.io, source)) {
        logUnsupported(ctx, "move whose source the bottle did not ship");
        return false;
    }
    if (!confinedSource(ctx, source)) return false;
    if (!confined(ctx, target)) return false;

    if (pathExists(ctx.io, target)) {
        // Refused rather than skipped: the declared relocation did not happen
        // and the source is still sitting where the formula left it.
        if (!getFlag(obj, "overwrite") and !getFlag(obj, "force")) {
            logUnsupported(ctx, "move onto an existing target without overwrite");
            return false;
        }
        // Swapped aside rather than deleted: if the relocation below fails,
        // whatever the user had there is still recoverable.
        const aside = asidePath(ctx, target) orelse return false;
        std.Io.Dir.cwd().deleteTree(ctx.io, aside) catch {};
        std.Io.Dir.renameAbsolute(target, aside, ctx.io) catch {
            logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "could not clear {s}", .{target}) catch target);
            return false;
        };
        mkParent(ctx, target);
        if (atomic.atomicRename(ctx.io, ctx.allocator, source, target)) |_| {
            std.Io.Dir.cwd().deleteTree(ctx.io, aside) catch {};
            return true;
        } else |_| {
            std.Io.Dir.renameAbsolute(aside, target, ctx.io) catch {};
            logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "could not relocate {s}", .{source}) catch source);
            return false;
        }
    }
    mkParent(ctx, target);
    // An aside can outlive a crash between the two renames below; drop it here
    // too, or it lingers in the prefix with nothing to reclaim it.
    std.Io.Dir.cwd().deleteTree(ctx.io, asidePath(ctx, target) orelse "") catch {};
    atomic.atomicRename(ctx.io, ctx.allocator, source, target) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "could not relocate {s}", .{source}) catch source);
        return false;
    };
    return true;
}

fn asidePath(ctx: StepsCtx, target: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(ctx.allocator, "{s}.malt-replaced", .{target}) catch null;
}

/// `warn`: upstream's `opoo`. Printing IS the step, so it must never reach
/// `logUnsupported` — that would downgrade a whole install over a message.
fn stepWarn(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const raw = getString(obj, "message") orelse {
        logUnsupported(ctx, "warn without a message");
        return false;
    };
    const message = expandTemplates(ctx, raw) catch raw;
    // The renderer writes notes verbatim, so the line ending is the caller's.
    ctx.flog.note(std.fmt.allocPrint(ctx.allocator, "{s}\n", .{message}) catch message);
    return true;
}

// --- permissions -----------------------------------------------------------

/// A `permissions` value: an absolute octal mode, or a symbolic clause applied
/// against whatever the file already carries.
const Mode = union(enum) {
    absolute: std.posix.mode_t,
    symbolic: struct {
        who: std.posix.mode_t,
        bits: std.posix.mode_t,
        op: enum { add, remove, set },
    },
};

/// Parse the two shapes homebrew-core ships: `0755` and `[ugoa]+[+-=][rwx]+`.
/// Null for anything else — approximating a mode is how a private key ends up
/// world-readable.
fn parseMode(spec: []const u8) ?Mode {
    if (spec.len == 0) return null;
    if (spec[0] >= '0' and spec[0] <= '7') {
        const parsed = std.fmt.parseInt(std.posix.mode_t, spec, 8) catch return null;
        // chmod(2) only consults the low bits; mask so a wide literal cannot
        // overflow the cast, matching the DSL chmod builtin.
        return .{ .absolute = parsed & 0o7777 };
    }

    var who: std.posix.mode_t = 0;
    var i: usize = 0;
    while (i < spec.len) : (i += 1) switch (spec[i]) {
        'u' => who |= 0o700,
        'g' => who |= 0o070,
        'o' => who |= 0o007,
        'a' => who |= 0o777,
        else => break,
    };
    if (who == 0 or i == spec.len) return null;

    const op: @FieldType(@FieldType(Mode, "symbolic"), "op") = switch (spec[i]) {
        '+' => .add,
        '-' => .remove,
        '=' => .set,
        else => return null,
    };
    i += 1;
    if (i == spec.len) return null;

    // r/w/x replicate across all three classes, then the who mask selects.
    var perm: std.posix.mode_t = 0;
    while (i < spec.len) : (i += 1) perm |= switch (spec[i]) {
        'r' => 0o444,
        'w' => 0o222,
        'x' => 0o111,
        else => return null,
    };
    return .{ .symbolic = .{ .who = who, .bits = perm & who, .op = op } };
}

fn applyMode(current: std.posix.mode_t, mode: Mode) std.posix.mode_t {
    return switch (mode) {
        .absolute => |m| m,
        .symbolic => |s| switch (s.op) {
            .add => current | s.bits,
            .remove => current & ~s.bits,
            .set => (current & ~s.who) | s.bits,
        },
    };
}

/// Follow a symlink the step named, the way `chmod(1)` does for an argument —
/// a linked prefix points `<prefix>/lib/...` at the Cellar, so refusing links
/// here would refuse the ordinary layout. (`-R` traversal is the opposite and
/// leaves links alone; `chmodTree` skips them.) Confinement lands on the
/// resolved file, so a link out of the keg is still refused.
fn resolveLink(ctx: StepsCtx, path: []const u8) []const u8 {
    var current = path;
    // Homebrew plants one hop; the bound just stops a cycle.
    for (0..8) |_| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.readLinkAbsolute(ctx.io, current, &buf) catch return current;
        const target = buf[0..n];
        // Duped off the stack buffer before it goes out of scope.
        current = if (std.fs.path.isAbsolute(target))
            ctx.allocator.dupe(u8, target) catch return current
        else
            std.fs.path.join(ctx.allocator, &.{ std.fs.path.dirname(current) orelse "/", target }) catch return current;
    }
    return current;
}

fn chmodConfined(ctx: StepsCtx, named: []const u8, mode: Mode) bool {
    const path = resolveLink(ctx, named);
    const file = sandbox.openTargetNoFollow(ctx.io, path, ctx.keg_path, ctx.prefix, .{ .write = false }) catch |e| {
        if (e == error.PathSandboxViolation) {
            logViolation(ctx, path);
            return false;
        }
        // A leaf that vanished between the walk and the open is a race, not a
        // refusal — `chmod -R` reports and keeps going rather than abandoning
        // the remaining paths. Visible, but it does not downgrade the install.
        ctx.flog.note(chmodDetail(ctx, "post_install: skipped, could not open", path));
        return true;
    };
    defer file.close(ctx.io);
    const current: std.posix.mode_t = switch (mode) {
        .absolute => 0,
        .symbolic => blk: {
            // A symbolic clause modifies what is already there, so an
            // unreadable mode would silently widen or narrow the result.
            const s = file.stat(ctx.io) catch {
                logUnsupported(ctx, chmodDetail(ctx, "could not read the current mode of", path));
                return false;
            };
            break :blk s.permissions.toMode() & 0o7777;
        },
    };
    file.setPermissions(ctx.io, .fromMode(applyMode(current, mode))) catch {
        // Reporting success here is how a private keg directory stays
        // world-readable with nothing in the log to say so.
        logUnsupported(ctx, chmodDetail(ctx, "could not chmod", path));
        return false;
    };
    return true;
}

fn chmodDetail(ctx: StepsCtx, what: []const u8, path: []const u8) []const u8 {
    return std.fmt.allocPrint(ctx.allocator, "{s} {s}\n", .{ what, path }) catch what;
}

fn chmodTree(ctx: StepsCtx, path: []const u8, mode: Mode) bool {
    if (!chmodConfined(ctx, path, mode)) return false;
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, path, .{ .iterate = true }) catch return true;
    defer dir.close(ctx.io);
    // Per-level guard, like the link_dir walk: a directory symlink must not
    // redirect the descent outside the prefix.
    sandbox.validateDirTarget(ctx.io, path, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, path);
        return false;
    };
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        // `chmod -R` walks past anything that is not a file or a directory;
        // refusing a symlink here would fail the step over a keg's own links.
        if (entry.kind != .directory and entry.kind != .file) continue;
        const child = std.fs.path.join(ctx.allocator, &.{ path, entry.name }) catch continue;
        const ok = if (entry.kind == .directory) chmodTree(ctx, child, mode) else chmodConfined(ctx, child, mode);
        if (!ok) return false;
    }
    return true;
}

/// `set_permissions`: chmod every path in the step's array that the formula
/// actually shipped. Upstream passes `-R` *unless* `non_recursive` is set, so
/// recursion is the default — inverting it silently under-applies the mode.
fn stepSetPermissions(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const paths_val = obj.get("paths") orelse {
        logUnsupported(ctx, "set_permissions without paths");
        return false;
    };
    if (paths_val != .array) {
        logUnsupported(ctx, "set_permissions with non-array paths");
        return false;
    }
    const permissions = getString(obj, "permissions") orelse {
        logUnsupported(ctx, "set_permissions without permissions");
        return false;
    };
    const mode = parseMode(permissions) orelse {
        logUnsupported(ctx, std.fmt.allocPrint(ctx.allocator, "set_permissions mode {s}", .{permissions}) catch "set_permissions mode");
        return false;
    };
    const recursive = !getFlag(obj, "non_recursive");

    for (paths_val.array.items) |item| {
        if (item != .object) continue;
        const spec = resolveSpec(ctx, item.object, "paths") orelse return false;
        const matches = expandGlob(ctx, spec) orelse return false;
        for (matches) |path| {
            // A path the formula declared but did not ship is a skip upstream
            // too: `existing_step_paths` filters before chmod runs.
            if (!pathExists(ctx.io, path)) continue;
            if (!confined(ctx, path)) return false;
            const ok = if (recursive) chmodTree(ctx, path, mode) else chmodConfined(ctx, path, mode);
            if (!ok) return false;
        }
    }
    return true;
}

/// Expand the pattern shapes upstream's path specs actually use: a `*` leaf,
/// optionally behind a `**/` descent. Null for anything else — an approximated
/// pattern chmods the wrong files rather than failing.
fn expandGlob(ctx: StepsCtx, spec: []const u8) ?[]const []const u8 {
    if (std.mem.indexOfScalar(u8, spec, '*') == null) {
        const one = ctx.allocator.alloc([]const u8, 1) catch return null;
        one[0] = spec;
        return one;
    }
    const dir_path = std.fs.path.dirname(spec) orelse return logUnexpandable(ctx, spec);
    const pattern = std.fs.path.basename(spec);
    if (std.mem.indexOfScalar(u8, pattern, '*') == null) return logUnexpandable(ctx, spec);

    const root, const descend = if (std.mem.indexOfScalar(u8, dir_path, '*') == null)
        .{ dir_path, false }
    else if (std.mem.endsWith(u8, dir_path, "/**"))
        .{ dir_path[0 .. dir_path.len - "/**".len], true }
    else
        return logUnexpandable(ctx, spec);

    // Every other step is confined at the point it mutates, which is enough
    // because it touches exactly the path it was given. Expansion is different:
    // it *reads* a whole subtree to discover paths, so an unchecked root would
    // hand a tap recursive enumeration of anywhere this user can read. Bound it
    // before the first opendir, not after.
    if (!withinBounds(ctx, root)) {
        logViolation(ctx, root);
        return null;
    }

    var out: std.ArrayList([]const u8) = .empty;
    collectMatches(ctx, root, pattern, descend, &out);
    return out.toOwnedSlice(ctx.allocator) catch null;
}

/// One entry per refusal: the callers cannot tell the shapes apart, so logging
/// is owned here rather than duplicated at each site.
fn logUnexpandable(ctx: StepsCtx, spec: []const u8) ?[]const []const u8 {
    logUnsupported(ctx, std.fmt.allocPrint(ctx.allocator, "a path pattern this executor cannot expand: {s}", .{spec}) catch "a path pattern this executor cannot expand");
    return null;
}

/// Boundary test with no I/O — the variant usable *before* a path has been
/// touched. Siblings: `confined` checks a write's parent chain, `confinedSource`
/// resolves and checks a read's own leaf; both hit the filesystem.
///
/// Defers to the same `validatePath` those two reach eventually, rather than
/// re-deriving the prefix test: nothing here normalises a path, so a bare
/// prefix comparison would accept `<prefix>/../../elsewhere`.
fn withinBounds(ctx: StepsCtx, path: []const u8) bool {
    sandbox.validatePath(path, ctx.keg_path, ctx.prefix) catch return false;
    return true;
}

fn collectMatches(
    ctx: StepsCtx,
    dir_path: []const u8,
    pattern: []const u8,
    descend: bool,
    out: *std.ArrayList([]const u8),
) void {
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        const child = std.fs.path.join(ctx.allocator, &.{ dir_path, entry.name }) catch continue;
        if (glob_match.match(pattern, entry.name)) out.append(ctx.allocator, child) catch return;
        if (descend and entry.kind == .directory) collectMatches(ctx, child, pattern, true, out);
    }
}

// --- gzipped executables ---------------------------------------------------

/// `install_gzipped_executable`: bazel and friends ship the real binary
/// gzipped so the bottle stays small. The archive is unlinked once unpacked,
/// or it ships in the keg.
fn stepInstallGzippedExecutable(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const source = resolvePathSpec(ctx, obj, "source") orelse return false;
    const target = resolvePathSpec(ctx, obj, "target") orelse return false;
    // A source the bottle did not ship is upstream's silent early return.
    if (!fileExists(ctx.io, source)) return true;
    if (!confinedSource(ctx, source)) return false;
    if (!confined(ctx, target)) return false;

    const dir = std.fs.path.dirname(target) orelse return false;
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
    const tmp = std.fmt.allocPrint(ctx.allocator, "{s}/.{s}.install-step", .{
        dir,
        std.fs.path.basename(target),
    }) catch return false;

    gunzipConfined(ctx, source, tmp) catch {
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "could not decompress {s}", .{source}) catch source);
        return false;
    };
    // Mode goes on before the rename publishes the file: the archive is gone
    // by the end, so a chmod that failed afterwards could never be retried —
    // every re-run would take the "source not shipped" exit and report success
    // over a binary nobody can execute.
    if (!chmodConfined(ctx, tmp, .{ .absolute = 0o755 })) {
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
        return false;
    }
    // No unlink first: rename replaces the destination atomically, so there is
    // never a moment where the executable is missing.
    atomic.atomicRename(ctx.io, ctx.allocator, tmp, target) catch {
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp) catch {};
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "could not place {s}", .{target}) catch target);
        return false;
    };
    std.Io.Dir.cwd().deleteFile(ctx.io, source) catch {};
    return true;
}

/// Ceiling on one unpacked executable. The archive is tap-supplied and a few
/// compressed KiB can expand without bound; the largest real payload
/// (bazel-real) is under a gigabyte, so this only ever catches a bomb.
const max_unpacked_bytes: u64 = 4 << 30;

fn gunzipConfined(ctx: StepsCtx, source: []const u8, dest: []const u8) !void {
    const in = try sandbox.openSourceNoFollow(ctx.io, source, ctx.keg_path, ctx.prefix);
    defer in.close(ctx.io);
    var in_buf: [16 * 1024]u8 = undefined;
    var in_reader = in.reader(ctx.io, &in_buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&in_reader.interface, .gzip, &window);

    const out = try sandbox.openTargetNoFollow(ctx.io, dest, ctx.keg_path, ctx.prefix, .{
        .write = true,
        .create = true,
        .truncate = true,
    });
    defer out.close(ctx.io);
    var out_buf: [16 * 1024]u8 = undefined;
    var out_writer = out.writerStreaming(ctx.io, &out_buf);
    var written: u64 = 0;
    while (true) {
        const n = decompress.reader.stream(&out_writer.interface, .limited(64 * 1024)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        written += n;
        if (written > max_unpacked_bytes) return error.StreamTooLong;
    }
    try out_writer.interface.flush();
}

// --- Mach-O and process tier -----------------------------------------------

/// `change_dylib_id`: ruby republishes its dylib under the versioned opt path
/// so dependents link against a stable name. The rewrite invalidates the
/// signature on arm64, so it is re-signed exactly as relocation does.
fn stepChangeDylibId(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const source = resolvePathSpec(ctx, obj, "source") orelse return false;
    const raw_id = getString(obj, "id") orelse {
        logUnsupported(ctx, "change_dylib_id without an id");
        return false;
    };
    const id = expandTemplates(ctx, raw_id) catch return false;

    // Bounded before the realpath probe, not after: resolving an arbitrary
    // path is itself a filesystem read a tap should not get.
    if (!withinBounds(ctx, source)) {
        logViolation(ctx, source);
        return false;
    }
    // The keg publishes the dylib as a symlink to its versioned twin, and the
    // install name belongs on the real file. Copied onto the arena because the
    // FallbackLog borrows every detail it is handed — a stack slice would be
    // reclaimed before the router renders it.
    const target = if (getFlag(obj, "resolve_source")) blk: {
        break :blk std.Io.Dir.realPathFileAbsoluteAlloc(ctx.io, source, ctx.allocator) catch source;
    } else source;
    if (!confined(ctx, target)) return false;

    const entries = [_]patch.OverflowEntry{dylibIdEntry(id)};
    patch.flushOverflow(ctx.io, ctx.allocator, target, &entries) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "could not set the install name of {s}", .{target}) catch target);
        return false;
    };
    if (codesign.isArm64()) codesign.adHocSign(ctx.io, ctx.allocator, target) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "could not re-sign {s}", .{target}) catch target);
        return false;
    };
    return true;
}

/// `-id` carries only the new name: LC_ID_DYLIB has a single slot, so the old
/// value is implicit.
fn dylibIdEntry(id: []const u8) patch.OverflowEntry {
    return .{ .cmd = @intFromEnum(std.macho.LC.ID_DYLIB), .old_path = "", .new_path = id };
}

/// `terminate_process`: stop a daemon the previous version left running.
/// Spawned directly rather than through `spawnFenced`: the fence governs
/// filesystem reach, and this sends a signal without touching the filesystem,
/// so it would constrain nothing. The argv is malt's own but for `name`, which
/// is validated below.
fn stepTerminateProcess(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const name = getString(obj, "name") orelse {
        logUnsupported(ctx, "terminate_process without a name");
        return false;
    };
    // The name is tap-controlled and killall has no `--` terminator, so a
    // leading dash would arrive as an option rather than a process name.
    if (name.len == 0 or name[0] == '-') {
        logUnsupported(ctx, "terminate_process with a name killall would read as an option");
        return false;
    }
    var child = std.process.spawn(ctx.io, .{
        .argv = &.{ system_tools.killall, name },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        logCmdFail(ctx, "killall failed to spawn");
        return false;
    };
    // A non-zero exit means nothing matched, which is the normal case on a
    // first install; only failing to spawn is a real failure.
    _ = child.wait(ctx.io) catch {};
    return true;
}

// --- toolchain configuration -----------------------------------------------

/// Toolchain root a malt-installed clang reads its SDK from. Duplicated from
/// the DSL process builtin on purpose: importing it would buy a dependency
/// edge for one string.
const command_line_tools = "/Library/Developer/CommandLineTools";

/// Upstream's set is `[:arm64, :x86_64, :aarch64, arch]`, and the host arch is
/// always already in it on macOS.
const clang_arches = [_][]const u8{ "arm64", "x86_64", "aarch64" };

/// `configure_clang_system`: without these a malt-installed clang has no
/// `-isysroot` and cannot find the macOS SDK.
fn stepConfigureClangSystem(ctx: StepsCtx) bool {
    const macos_major = sysctlMajor("kern.osproductversion") orelse {
        logUnsupported(ctx, "configure_clang_system without a readable macOS version");
        return false;
    };
    // Darwin's own major, not the product major: clang looks for
    // `<arch>-apple-darwin25.cfg` on macOS 26.
    const kernel_major = sysctlMajor("kern.osrelease") orelse {
        logUnsupported(ctx, "configure_clang_system without a readable kernel version");
        return false;
    };
    return writeClangConfigs(ctx, macos_major, kernel_major);
}

fn writeClangConfigs(ctx: StepsCtx, macos_major: u32, kernel_major: u32) bool {
    const a = ctx.allocator;
    // Prefix-scoped `etc`, not the keg's — clang reads one shared config dir.
    const etc = resolveBase(ctx, "etc", null) orelse return false;
    const config_dir = std.fs.path.join(a, &.{ etc, "clang" }) catch return false;

    var paths: [clang_arches.len * 2][]const u8 = undefined;
    for (clang_arches, 0..) |arch, i| {
        paths[i * 2] = std.fmt.allocPrint(a, "{s}/{s}-apple-darwin{d}.cfg", .{ config_dir, arch, kernel_major }) catch return false;
        paths[i * 2 + 1] = std.fmt.allocPrint(a, "{s}/{s}-apple-macosx{d}.cfg", .{ config_dir, arch, macos_major }) catch return false;
    }

    // Idempotent: a complete set stays exactly as the user has it. The `else`
    // runs only when the loop never broke, i.e. all six are already present.
    for (paths) |path| {
        if (!fileExists(ctx.io, path)) break;
    } else return true;

    const content = std.fmt.allocPrint(a, "-isysroot {s}/SDKs/MacOSX{d}.sdk\n", .{ command_line_tools, macos_major }) catch return false;
    if (!confined(ctx, config_dir)) return false;
    std.Io.Dir.cwd().createDirPath(ctx.io, config_dir) catch {};
    for (paths) |path| {
        // Atomic, like upstream: the only completeness check on the next run
        // is that all six files exist, so a torn write would be mistaken for
        // a finished one and leave clang without an SDK for good.
        atomic.atomicWriteFile(ctx.io, path, content) catch {
            logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "could not write {s}", .{path}) catch path);
            return false;
        };
    }
    return true;
}

/// `configure_gcc_runtime`: upstream's body returns unless it is running on
/// Linux, so on macOS this is genuinely nothing to do — a correct evaluation,
/// not a stub waiting to be filled in.
fn stepConfigureGccRuntime(ctx: StepsCtx) bool {
    ctx.flog.note("configure_gcc_runtime: Linux-only upstream, nothing to do here\n");
    return true;
}

/// Major component of a `kern.*` version sysctl, or null when it cannot be
/// read — the caller must refuse rather than name files after a guess.
/// `formula.zig` parses a major the same way; kept separate because it needs a
/// second sysctl this one does not, and answers with a sentinel rather than
/// null. Sharing would buy an edge into a large sibling for five lines.
fn sysctlMajor(name: [*:0]const u8) ?u32 {
    var buf: [32]u8 = undefined;
    var len: usize = buf.len;
    if (std.c.sysctlbyname(name, &buf, &len, null, 0) != 0) return null;
    const text = std.mem.sliceTo(buf[0..len], 0);
    const major = text[0 .. std.mem.indexOfScalar(u8, text, '.') orelse text.len];
    return std.fmt.parseInt(u32, major, 10) catch null;
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

// --- arbitrary commands ------------------------------------------------------

/// A `run` command's base is keg-relative: upstream resolves it through the
/// Formula object, so `bin` is `<keg>/bin` — not `<prefix>/bin`, which is what
/// the same token means as a *path* base in `base_map`.
const CommandBase = enum { keg, bin, sbin, lib, libexec };

const command_base_map = std.StaticStringMap(CommandBase).initComptime(.{
    .{ "prefix", .keg },
    .{ "bin", .bin },
    .{ "sbin", .sbin },
    .{ "lib", .lib },
    .{ "libexec", .libexec },
});

/// Absolute path to a `run` step's command, or null (already logged) when the
/// spec is malformed. A bare name is refused rather than resolved through the
/// fence's PATH: which binary that finds is not the formula's to decide.
fn resolveCommandPath(ctx: StepsCtx, obj: std.json.ObjectMap) ?[]const u8 {
    const spec = getObject(obj, "command") orelse {
        logUnsupported(ctx, "run without a command");
        return null;
    };
    const raw = getString(spec, "path") orelse {
        logUnsupported(ctx, "run without a command path");
        return null;
    };
    const path = expandTemplates(ctx, raw) catch return null;
    const base = getString(spec, "base") orelse "absolute";
    if (std.mem.eql(u8, base, "absolute")) {
        if (!std.fs.path.isAbsolute(path)) {
            logUnsupported(ctx, "run with a relative command");
            return null;
        }
        return path;
    }
    const tag = command_base_map.get(base) orelse {
        logUnsupported(ctx, std.fmt.allocPrint(ctx.allocator, "run command base {s}", .{base}) catch base);
        return null;
    };
    if (path.len == 0) {
        logUnsupported(ctx, "run with an empty command path");
        return null;
    }
    const root = if (tag == .keg)
        ctx.keg_path
    else
        std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.keg_path, @tagName(tag) }) catch return null;
    return std.fs.path.join(ctx.allocator, &.{ root, path }) catch null;
}

/// The formula's own helper: upstream's most common step, and the only one
/// whose argv the formula supplies wholesale. It goes through the same argv
/// lint and sandbox fence as every other spawn, with no extra grants.
fn stepRun(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    // Only an explicit `false` — the compacted default — is a request malt can
    // satisfy; malt never escalates.
    if (obj.get("sudo")) |v| {
        if (v != .bool or v.bool) {
            logUnsupported(ctx, "run with sudo");
            return false;
        }
    }

    const cmd = resolveCommandPath(ctx, obj) orelse return false;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(ctx.allocator, cmd) catch return false;
    if (obj.get("args")) |args_val| {
        if (args_val != .array) {
            logUnsupported(ctx, "run with non-array args");
            return false;
        }
        for (args_val.array.items) |item| {
            const raw = switch (item) {
                .string => |s| s,
                else => {
                    logUnsupported(ctx, "run with a non-string argument");
                    return false;
                },
            };
            const arg = expandTemplates(ctx, raw) catch return false;
            argv.append(ctx.allocator, arg) catch return false;
        }
    }
    // Lint before probing, so a traversal out of the keg reports as the
    // confinement violation it is rather than as a missing file.
    sandbox.validateArgv(argv.items, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, cmd);
        return false;
    };
    if (!fileExists(ctx.io, cmd)) {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} not found", .{cmd}) catch cmd);
        return false;
    }
    if (nativeCaBundle(ctx, argv.items, cmd)) |_| return true;
    return spawnFenced(ctx, argv.items, &.{}, std.fs.path.basename(cmd), .{});
}

/// `ca-certificates`' post-install forks openssl and security once per
/// certificate — ~800 processes for work `std.crypto` does in-process. When
/// the script is byte-for-byte the one the native builder was verified
/// against, build the bundle directly. Null means "not that script, or the
/// native path declined": the caller spawns it as usual.
///
/// The `security` children stay inside the same sandbox profile the script
/// ran under, so swapping the implementation does not widen what the work
/// may touch.
fn nativeCaBundle(ctx: StepsCtx, argv: []const []const u8, cmd: []const u8) ?void {
    // <source> <destination> is the only shape the builder replaces.
    if (argv.len != 3) return null;
    if (!ca_bundle.isKnownScript(ctx.io, cmd)) return null;

    buildCaBundle(ctx, argv) catch |err| {
        // The script was recognised but the work could not be done, so the
        // shipped script runs instead - correct, seconds slower. Say so:
        // silence here is how a lost fast path, or a trust store that stopped
        // answering, goes unnoticed on a user's machine.
        // Name the reason: a code that recurs on every install is a systemic
        // problem, and a bare "declined" cannot be told apart from a one-off.
        ctx.flog.note(std.fmt.allocPrint(
            ctx.allocator,
            "ca-certificates: native trust-store build declined ({s}), running the shipped script",
            .{@errorName(err)},
        ) catch "ca-certificates: native trust-store build declined, running the shipped script");
        return null;
    };
    return {};
}

fn buildCaBundle(ctx: StepsCtx, argv: []const []const u8) !void {
    // Recognising the script's bytes says nothing about its arguments, and any
    // formula can name this script. Running in-process skips the sandbox that
    // confined the spawned one, so the read and the write are confined here
    // instead — declining hands the step back to the fenced spawn.
    try sandbox.validatePath(argv[2], ctx.keg_path, ctx.prefix);

    // A lexical prefix check would let a link planted inside the keg read
    // whatever it points at, but refusing links outright is wrong too: malt's
    // own linker points `{prefix}/share/<name>` entries into the keg, and the
    // real source is one of them. Resolve first, then confine where it landed.
    try sandbox.validatePath(argv[1], ctx.keg_path, ctx.prefix);
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Read the resolved path, not the one handed in: opening the link again
    // would follow whatever it points at now, not what was just confined.
    const source_path = try sandbox.resolveConfined(ctx.io, &real_buf, argv[1], ctx.keg_path, ctx.prefix);

    // Cap generously but refuse a truncated read: a short source silently
    // drops trusted roots. Upstream's bundle is a few hundred KB.
    const max_source = 8 * 1024 * 1024;
    const source = try fs_read.readFileAllAbsolute(ctx.io, ctx.allocator, source_path, max_source);
    if (source.len == max_source) return error.SourceTruncated;

    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_s));
    const bundle = try ca_bundle.build(ctx.io, ctx.allocator, source, now, .{
        .keg_path = ctx.keg_path,
        .prefix = ctx.prefix,
    });

    const dir = std.fs.path.dirname(argv[2]) orelse return error.NoParentDirectory;
    // Confine before creating, not after: `validatePath` above is lexical, so
    // a destination under a symlinked directory inside the keg passes it, and
    // creating the tree first would plant directories wherever that link
    // points before the resolved check refuses. `validateWriteDir` resolves
    // the nearest ancestor that already exists, so it sees the link.
    try sandbox.validateWriteDir(ctx.io, argv[2], ctx.keg_path, ctx.prefix);
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    // 0644 explicitly: the script chmods it, and a restrictive umask would
    // otherwise leave the trust store unreadable to every other user.
    try atomic.atomicWriteFileMode(ctx.io, argv[2], bundle, @enumFromInt(0o644));
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
    // initdb takes no --tmpdir, so TMPDIR is the only way to keep its scratch
    // space inside the prefix, where the fence grants file creation.
    if (spawnFenced(ctx, plan.argv, &.{.{ .key = "TMPDIR", .value = tmpdir }}, using, .{ .allow_ipc = true })) return true;
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
    return runFormulaToolEnv(ctx, "gdk-pixbuf", "gdk-pixbuf-query-loaders", &.{"--update-cache"}, &.{
        .{ .key = "GDK_PIXBUF_MODULEDIR", .value = env.moduledir },
        .{ .key = "GDK_PIXBUF_MODULE_FILE", .value = env.module_file },
    });
}

/// Spawn `<prefix>/opt/<formula>/bin/<exe>` through the same argv lint +
/// sandbox fence as the DSL `system` builtin. Failure routes exactly like
/// a failed formula `system` call.
fn runFormulaTool(ctx: StepsCtx, tool_formula: []const u8, exe: []const u8, args: []const []const u8) bool {
    return runFormulaToolEnv(ctx, tool_formula, exe, args, &.{});
}

fn runFormulaToolEnv(ctx: StepsCtx, tool_formula: []const u8, exe: []const u8, args: []const []const u8, extra_env: []const EnvVar) bool {
    const tool = std.fmt.allocPrint(ctx.allocator, "{s}/opt/{s}/bin/{s}", .{ ctx.prefix, tool_formula, exe }) catch return false;
    if (!fileExists(ctx.io, tool)) {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} not found (is {s} installed?)", .{ exe, tool_formula }) catch exe);
        return false;
    }

    var argv = std.ArrayList([]const u8).empty;
    argv.append(ctx.allocator, tool) catch return false;
    argv.appendSlice(ctx.allocator, args) catch return false;

    return spawnFenced(ctx, argv.items, extra_env, exe, .{});
}

/// Step-specific variable layered on top of the scrubbed base environment.
const EnvVar = struct { key: []const u8, value: []const u8 };

fn buildChildEnv(ctx: StepsCtx, extra_env: []const EnvVar) error{OutOfMemory}!std.process.Environ.Map {
    var map = try sandbox_macos.buildFormulaEnv(ctx.allocator, ctx.environ, ctx.prefix);
    errdefer map.deinit();
    for (extra_env) |v| try map.put(v.key, v.value);
    return map;
}

/// Argv lint + sandbox fence + spawn + wait — the one exec chokepoint for
/// every tool and initialiser step. `label` names the child in the log.
/// `opts` carries per-spawn fence knobs (IPC only for the DB initialisers).
/// The child always starts from the scrubbed formula environment; `extra_env`
/// layers onto it, so no caller can fall back to inheriting malt's own.
fn spawnFenced(ctx: StepsCtx, argv: []const []const u8, extra_env: []const EnvVar, label: []const u8, opts: sandbox_macos.ProfileOpts) bool {
    sandbox.validateArgv(argv, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, argv[0]);
        return false;
    };
    var profile_opts = opts;
    profile_opts.home = std.process.Environ.getPosix(ctx.environ, "HOME");
    const fenced = sandbox.fenceArgv(ctx.allocator, argv, ctx.keg_path, ctx.prefix, profile_opts) catch {
        logViolation(ctx, argv[0]);
        return false;
    };

    var env_map = buildChildEnv(ctx, extra_env) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} failed to spawn", .{label}) catch label);
        return false;
    };
    defer env_map.deinit();

    const raw = sandbox_macos.rawPassthroughEnabled(ctx.environ);
    // Run the step in its own keg. An inherited cwd is wherever the user
    // invoked malt from, which the sandbox profile does not grant: anything
    // resolving it fails, and a relative path in a step is unusable.
    const cwd: std.process.Child.Cwd =
        if (ctx.keg_path.len > 0) .{ .path = ctx.keg_path } else .inherit;
    var child = std.process.spawn(ctx.io, .{
        .argv = fenced,
        .cwd = cwd,
        .stdout = sandbox_macos.childStdioMode(ctx.suppress_child_stdout, raw),
        .stderr = sandbox_macos.childStdioMode(false, raw),
        .environ_map = &env_map,
    }) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} failed to spawn", .{label}) catch label);
        return false;
    };
    const term = sandbox_macos.waitSanitizedChild(ctx.io, &child, .{}) catch {
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

/// Unlike `fileExists`, true for directories too.
fn pathExists(io: std.Io, path: []const u8) bool {
    return if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| true else |_| false;
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

test "execute refuses inreplace through a source symlink outside the prefix" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    var outside = try Scratch.init("steps_inreplace_source");
    defer outside.deinit();
    try std.Io.Dir.cwd().createDirPath(h.io, outside.base);
    const victim = outside.p("/victim");
    {
        const f = try std.Io.Dir.createFileAbsolute(h.io, victim, .{});
        defer f.close(h.io);
        try f.writeStreamingAll(h.io, "PRIVATE");
    }

    const etc = try std.fmt.allocPrint(a, "{s}/etc", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, etc);
    const link = try std.fmt.allocPrint(a, "{s}/leak.conf", .{etc});
    try std.Io.Dir.symLinkAbsolute(h.io, victim, link, .{});

    _ = execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"inreplace","path":{"base":"etc","path":"leak.conf"},
        \\  "before":"PRIVATE","after":"PRIVATE"}]
    ));

    try testing.expect(h.flog.hasFatal());
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try std.Io.Dir.readLinkAbsolute(h.io, link, &target_buf);
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

test "an unmet guard holds back every step type, not just the few that checked" {
    // `copy` is the dangerous one: running it anyway overwrites whatever the
    // formula was trying to preserve.
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/share/glow", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(io, src);
    const seed = try std.fmt.allocPrint(a, "{s}/glow.dat", .{src});
    (try std.Io.Dir.createFileAbsolute(io, seed, .{})).close(io);

    const json = try testFormulaJson(&h,
        \\[{"type":"copy","source":{"base":"prefix","path":"share/glow"},
        \\  "target":{"path":"{{HOMEBREW_PREFIX}}/share/copied"},
        \\  "guards":[{"condition":"if_exists","path":"{{HOMEBREW_PREFIX}}/share/absent"}]},
        \\ {"type":"mkdir_p","path":{"path":"{{HOMEBREW_PREFIX}}/share/made"},
        \\  "guards":[{"condition":"if_exists","path":"{{HOMEBREW_PREFIX}}/share/absent"}]},
        \\ {"type":"write","path":{"path":"{{HOMEBREW_PREFIX}}/etc/glow.conf"},"content":"x\n",
        \\  "guards":[{"condition":"if_exists","path":"{{HOMEBREW_PREFIX}}/share/absent"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());

    for ([_][]const u8{ "/share/copied", "/share/made", "/etc/glow.conf" }) |leaf| {
        const p = try std.fmt.allocPrint(a, "{s}{s}", .{ h.prefix, leaf });
        try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, p, .{}));
    }
}

test "an unless_exists guard protects a file the user already has" {
    // The condition formulas reach for when seeding config: write it once,
    // never over the copy the user has since edited.
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const varcfg = try std.fmt.allocPrint(a, "{s}/var/app", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, varcfg);
    const existing = try std.fmt.allocPrint(a, "{s}/app.conf", .{varcfg});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, existing, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "user edits\n");
    }

    const json = try testFormulaJson(&h,
        \\[{"type":"write","path":{"base":"var","path":"app/app.conf"},"content":"stock\n","overwrite":true,
        \\  "guards":[{"base":"var","path":"app/app.conf","condition":"unless_exists","id":"1"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());

    try testing.expectEqualStrings("user edits\n", try readBack(&h, existing));
}

test "an unless_exists guard lets the step run when the path is absent" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const json = try testFormulaJson(&h,
        \\[{"type":"write","path":{"base":"var","path":"app/app.conf"},"content":"stock\n",
        \\  "guards":[{"base":"var","path":"app/app.conf","condition":"unless_exists","id":"1"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    const written = try std.fmt.allocPrint(a, "{s}/var/app/app.conf", .{h.prefix});
    try std.Io.Dir.accessAbsolute(h.io, written, .{});
}

test "a guard resolves its base like the step it gates" {
    // Reading the guard's path raw would test the wrong location, and a guard
    // pointed at the wrong path is worse than no guard at all.
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    // Only the base-resolved location exists; the bare relative path does not.
    const seeded = try std.fmt.allocPrint(a, "{s}/var/marker", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/var", .{h.prefix}));
    (try std.Io.Dir.createFileAbsolute(io, seeded, .{})).close(io);

    const json = try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"made"},
        \\  "guards":[{"base":"var","path":"marker","condition":"if_exists","id":"1"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try std.Io.Dir.accessAbsolute(io, try std.fmt.allocPrint(a, "{s}/var/made", .{h.prefix}), .{});
}

test "the on guard admits a macOS step and skips a Linux one silently" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Upstream gates platform-specific steps with a guard carrying a value and
    // no path — a Linux-only step is a normal skip here, never a failure.
    const json = try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"mac"},
        \\  "guards":[{"condition":"on","value":"macos","id":"1"}]},
        \\ {"type":"mkdir_p","path":{"base":"var","path":"linux"},
        \\  "guards":[{"condition":"on","value":"linux","id":"2"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/var/mac", .{h.prefix}), .{});
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/var/linux", .{h.prefix}), .{}),
    );
}

test "the on guard routes an unknown platform value loudly" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // A platform malt cannot reason about must not read as "skip": the step's
    // work may still be required here.
    const json = try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"made"},
        \\  "guards":[{"condition":"on","value":"haiku","id":"1"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(h.flog.hasErrors());
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/var/made", .{h.prefix}), .{}),
    );
}

test "the on guard refuses a step whose platform value is missing entirely" {
    var h = try TestHarness.init();
    defer h.deinit();

    const json = try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"made"},
        \\  "guards":[{"condition":"on","id":"1"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(h.flog.hasErrors());
}

test "the libexec base resolves inside the keg, matching a run command's libexec" {
    var h = try TestHarness.init();
    defer h.deinit();
    const c = h.ctx();

    const resolved = resolveBase(c, "libexec", null).?;
    const expected = try std.fmt.allocPrint(h.arena.allocator(), "{s}/libexec", .{h.keg});
    try testing.expectEqualStrings(expected, resolved);
}

test "a key the executor does honour is not mistaken for an unknown one" {
    // `locale` reaches initdb's argv, so refusing it would be a false alarm.
    // The refusal list only earns its keep if it tracks what is implemented.
    var h = try TestHarness.init();
    defer h.deinit();

    const json = try testFormulaJson(&h,
        \\[{"type":"init_data_dir","path":{"base":"var","path":"pg"},"using":"postgresql_initdb","locale":"C"}]
    );
    try testing.expect(execute(h.ctx(), json));
    for (h.flog.entries()) |e| {
        try testing.expect(std.mem.indexOf(u8, e.detail, "locale") == null);
    }
}

test "a step carrying a key this executor does not honour refuses loudly" {
    // Upstream compacts defaults away, so a surviving key is one the formula
    // meant. Doing the work while ignoring it is the silent-wrong case.
    const refused = [_][]const u8{
        \\[{"type":"copy","source":{"base":"prefix","path":"share/*"},"target":{"path":"/tmp/x"},"source_glob":true}]
        ,
        \\[{"type":"symlink","source":{"base":"prefix","path":"bin/glow"},"target":{"path":"/tmp/x"},"resolve_source":true}]
        ,
        // A key upstream has not shipped yet must refuse too — that is the
        // point of listing what is honoured rather than what is not.
        \\[{"type":"touch","path":{"base":"etc","path":"glow.conf"},"mode":"0755"}]
        ,
    };
    for (refused) |steps_json| {
        var h = try TestHarness.init();
        defer h.deinit();
        try testing.expect(execute(h.ctx(), try testFormulaJson(&h, steps_json)));
        try testing.expect(h.flog.hasErrors());
    }
}

test "execute skips a remove whose if_exists guard is unmet" {
    // A first install has nothing to clean up. Reporting the step as
    // unsupported there downgrades the whole formula to the partial-skip
    // envelope over work that was never going to happen.
    var h = try TestHarness.init();
    defer h.deinit();

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","recursive":true,
        \\  "paths":[{"path":"{{HOMEBREW_PREFIX}}/lib/node_modules/npm"}],
        \\  "guards":[{"condition":"if_exists","path":"{{HOMEBREW_PREFIX}}/lib/node_modules/npm"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
}

test "execute removes a directory tree when the guard finds it" {
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const doomed = try std.fmt.allocPrint(a, "{s}/lib/node_modules/npm", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, doomed);
    const child = try std.fmt.allocPrint(a, "{s}/index.js", .{doomed});
    (try std.Io.Dir.createFileAbsolute(io, child, .{})).close(io);

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","recursive":true,
        \\  "paths":[{"path":"{{HOMEBREW_PREFIX}}/lib/node_modules/npm"}],
        \\  "guards":[{"condition":"if_exists","path":"{{HOMEBREW_PREFIX}}/lib/node_modules/npm"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, doomed, .{}));
}

test "execute refuses a recursive remove that would take a whole prefix dir" {
    // Confinement alone would allow this: `<prefix>/lib` is inside the
    // boundary. Formula data may retire its own subtree, never a shared
    // top-level directory holding every other package's files.
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const lib = try std.fmt.allocPrint(a, "{s}/lib", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, lib);

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","recursive":true,
        \\  "paths":[{"path":"{{HOMEBREW_PREFIX}}/lib"}],
        \\  "guards":[{"condition":"if_exists","path":"{{HOMEBREW_PREFIX}}/lib"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(h.flog.hasErrors());
    try std.Io.Dir.accessAbsolute(io, lib, .{});
}

test "a recursive remove unlinks a symlinked target instead of emptying it" {
    // Confinement checks the parent chain, not the leaf, so a planted link can
    // sit where the subtree is expected. Following it would delete a directory
    // the formula never owned.
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const precious = try std.fmt.allocPrint(a, "{s}/etc/precious", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, precious);
    const kept = try std.fmt.allocPrint(a, "{s}/keep.conf", .{precious});
    (try std.Io.Dir.createFileAbsolute(io, kept, .{})).close(io);

    const parent = try std.fmt.allocPrint(a, "{s}/lib/node_modules", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, parent);
    const link = try std.fmt.allocPrint(a, "{s}/npm", .{parent});
    try std.Io.Dir.symLinkAbsolute(io, precious, link, .{});

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","recursive":true,
        \\  "paths":[{"path":"{{HOMEBREW_PREFIX}}/lib/node_modules/npm"}],
        \\  "guards":[{"condition":"if_exists","path":"{{HOMEBREW_PREFIX}}/lib/node_modules/npm"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try std.Io.Dir.accessAbsolute(io, kept, .{});
}

test "execute still refuses a bare remove with neither guard nor recursive" {
    var h = try TestHarness.init();
    defer h.deinit();

    const json = try testFormulaJson(&h,
        \\[{"type":"remove","paths":[{"path":"{{HOMEBREW_PREFIX}}/bin/glow-init"}]}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(h.flog.hasErrors());
}

test "execute links every source_glob match into the target directory" {
    var h = try TestHarness.init();
    defer h.deinit();
    const io = h.io;
    const a = h.arena.allocator();

    const man_src = try std.fmt.allocPrint(a, "{s}/share/glow/man1", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(io, man_src);
    for ([_][]const u8{ "npm.1", "npx.1", "package-json.1", "unrelated.1" }) |leaf| {
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ man_src, leaf });
        (try std.Io.Dir.createFileAbsolute(io, p, .{})).close(io);
    }
    const man_dst = try std.fmt.allocPrint(a, "{s}/share/man/man1", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(io, man_dst);

    const json = try testFormulaJson(&h,
        \\[{"type":"symlink","force":true,"source_glob":true,
        \\  "source":{"base":"prefix","path":"share/glow/man1/{npm,npx,package-}*"},
        \\  "target":{"path":"{{HOMEBREW_PREFIX}}/share/man/man1"}}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());

    for ([_][]const u8{ "npm.1", "npx.1", "package-json.1" }) |leaf| {
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ man_dst, leaf });
        try std.Io.Dir.accessAbsolute(io, p, .{});
    }
    // A non-matching sibling must not be dragged along.
    const stray = try std.fmt.allocPrint(a, "{s}/unrelated.1", .{man_dst});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, stray, .{}));
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

test "init_data_dir points the initialiser at a tmpdir the fence can create in" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var h = try TestHarness.init();
    defer h.deinit();
    h.io = threaded.io();
    const a = h.arena.allocator();

    const keg_bin = try std.fmt.allocPrint(a, "{s}/bin", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, keg_bin);
    try std.Io.Dir.cwd().createDirPath(h.io, try std.fmt.allocPrint(a, "{s}/etc", .{h.prefix}));
    const seen = try std.fmt.allocPrint(a, "{s}/etc/seen.txt", .{h.prefix});
    {
        const f = try std.Io.Dir.createFileAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/initdb", .{keg_bin}), .{});
        defer f.close(h.io);
        var w = f.writer(h.io, &.{});
        try w.interface.print("#!" ++ "/bin/" ++ "sh\n/usr/bin/" ++ "env > '{s}'\n", .{seen});
        try w.interface.flush();
        try f.setPermissions(h.io, @enumFromInt(0o755));
    }

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"init_data_dir","path":{"base":"var","path":"postgresql"},"using":"postgresql_initdb"}]
    )));
    try testing.expect(!h.flog.hasErrors());

    var buf: [64 * 1024]u8 = undefined;
    const f = try std.Io.Dir.openFileAbsolute(h.io, seen, .{});
    defer f.close(h.io);
    var r = f.reader(h.io, &.{});
    const dump = buf[0..try r.interface.readSliceShort(&buf)];

    // initdb takes no --tmpdir, so TMPDIR is its only handle on scratch space.
    // The fence grants create under the prefix but only write-data under /tmp.
    try testing.expect(std.mem.indexOf(u8, dump, try std.fmt.allocPrint(a, "TMPDIR={s}/var/tmp\n", .{h.prefix})) != null);
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
    // Every type this executor gained is classified as native, so the doctor
    // probe stops reporting these formulas as partially covered.
    try testing.expect(allStepsSupported(a, try testFormulaJson(&h,
        \\[{"type":"configure_clang_system"},
        \\ {"type":"move","source":{"base":"var","path":"a"},"target":{"base":"var","path":"b"}},
        \\ {"type":"set_permissions","paths":[{"base":"var","path":"a"}],"permissions":"0755"}]
    )));
    try testing.expect(!allStepsSupported(a, try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"glow"}},
        \\ {"type":"configure_php"}]
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
        "init_data_dir",            "remove",                "inreplace",                 "run",
        "move",                     "warn",                  "set_permissions",           "install_gzipped_executable",
        "change_dylib_id",          "terminate_process",     "configure_clang_system",    "configure_gcc_runtime",
    };
    for (native) |t| try testing.expect(supportedStepType(t));
    // Deliberate loud skips: php and the legacy python/pypy bootstrappers are
    // whole projects, glibc never reaches a macOS bottle, and the rest have no
    // occurrence in homebrew-core to model against.
    const routed = [_][]const u8{
        "mkdir",         "move_children",     "move_contents",  "set_ownership",
        "configure_php", "bootstrap_cpython", "bootstrap_pypy", "configure_glibc_runtime",
        "frobnicate",
    };
    for (routed) |t| try testing.expect(!supportedStepType(t));
}

/// Parse one step object out of its JSON literal, for the helpers that take an
/// already-parsed step rather than a whole formula.
fn parseStep(h: *TestHarness, json: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, h.arena.allocator(), json, .{});
    return parsed.value.object;
}

test "resolveCommandPath resolves a command base against the keg, not the prefix" {
    // Upstream sends a command base through the Formula object, so `bin` here
    // means `<keg>/bin` — the opposite of what the same token means as a path
    // base. dbus (`bin/dbus-uuidgen`) and ca-certificates (`libexec/…`) would
    // both reach the wrong file under prefix semantics.
    var h = try TestHarness.init();
    defer h.deinit();
    const c = h.ctx();
    const a = h.arena.allocator();

    const cases = [_]struct { spec: []const u8, want: []const u8 }{
        .{ .spec =
        \\{"command":{"base":"bin","path":"dbus-uuidgen"}}
        , .want = try std.fmt.allocPrint(a, "{s}/bin/dbus-uuidgen", .{h.keg}) },
        .{ .spec =
        \\{"command":{"base":"libexec","path":"post-install"}}
        , .want = try std.fmt.allocPrint(a, "{s}/libexec/post-install", .{h.keg}) },
        .{ .spec =
        \\{"command":{"base":"sbin","path":"daemon"}}
        , .want = try std.fmt.allocPrint(a, "{s}/sbin/daemon", .{h.keg}) },
        .{ .spec =
        \\{"command":{"base":"lib","path":"helper"}}
        , .want = try std.fmt.allocPrint(a, "{s}/lib/helper", .{h.keg}) },
        .{ .spec =
        \\{"command":{"base":"prefix","path":"bin/tool"}}
        , .want = try std.fmt.allocPrint(a, "{s}/bin/tool", .{h.keg}) },
        // glib-networking ships a base-less absolute command carrying a token.
        .{ .spec =
        \\{"command":{"path":"{{HOMEBREW_PREFIX}}/opt/glib/bin/gio-querymodules"}}
        , .want = try std.fmt.allocPrint(a, "{s}/opt/glib/bin/gio-querymodules", .{h.prefix}) },
    };
    for (cases) |case| {
        const got = resolveCommandPath(c, try parseStep(&h, case.spec)) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(case.want, got);
    }
    try testing.expect(!h.flog.hasErrors());

    // A bare name would resolve through the fence's PATH; an empty or unknown
    // base has no keg-relative meaning. All three refuse loudly.
    const refused = [_][]const u8{
        \\{"command":{"path":"fc-cache"}}
        ,
        \\{"command":{"base":"libexec","path":""}}
        ,
        \\{"command":{"base":"home","path":"tool"}}
        ,
        \\{"command":{"base":"bin"}}
        ,
        \\{"args":["x"]}
        ,
    };
    for (refused) |spec| {
        try testing.expect(resolveCommandPath(c, try parseStep(&h, spec)) == null);
    }
    try testing.expectEqual(@as(usize, refused.len), h.flog.entries().len);
    for (h.flog.entries()) |e| try testing.expectEqual(fallback_log.FallbackReason.unknown_method, e.reason);
}

test "run executes the formula's own helper with its arguments expanded" {
    // The debug Io cannot spawn (no allocator for the child argv), so this is
    // the one step tier that needs a real threaded Io.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var h = try TestHarness.init();
    defer h.deinit();
    h.io = threaded.io();
    const a = h.arena.allocator();

    // A helper the keg "ships": a system tool whose effect is observable, so
    // the assertion covers the resolved base and the expanded argument rather
    // than just an exit code.
    const libexec = try std.fmt.allocPrint(a, "{s}/libexec", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, libexec);
    try std.Io.Dir.symLinkAbsolute(h.io, "/bin/mkdir", try std.fmt.allocPrint(a, "{s}/post-install", .{libexec}), .{});

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"run","command":{"base":"libexec","path":"post-install"},
        \\  "args":["-p","{{var}}/lib/dbus"]}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(usize, 1), h.flog.handled_top_level);

    // The created directory proves the child saw an expanded argument.
    try testing.expect(dirExists(h.io, try std.fmt.allocPrint(a, "{s}/var/lib/dbus", .{h.prefix})));
}

/// A secret plus an allowlisted locale var, shaped like malt's real environ.
/// The stand-in name is deliberate: the tap-resolution contract guard keeps
/// the real forge-token literal inside the forge seam.
const test_secret_environ: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{
    "MALT_SECRET_PROBE=sentinel-must-not-leak",
    "LANG=en_US.UTF-8",
    "PATH=/attacker/bin:/usr/bin:/bin",
} } };

test "run pins the child's working directory to the keg" {
    // An inherited cwd is wherever the user happened to run `mt` from: outside
    // the sandbox profile, so anything resolving it fails noisily, and a
    // relative path in a step lands somewhere unpredictable.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var h = try TestHarness.init();
    defer h.deinit();
    h.io = threaded.io();
    const a = h.arena.allocator();

    const libexec = try std.fmt.allocPrint(a, "{s}/libexec", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, libexec);
    try std.Io.Dir.symLinkAbsolute(h.io, "/bin/mkdir", try std.fmt.allocPrint(a, "{s}/post-install", .{libexec}), .{});

    // A relative argument resolves against the child's cwd, so where the
    // directory lands is the assertion.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"run","command":{"base":"libexec","path":"post-install"},
        \\  "args":["cwd-probe"]}]
    )));
    try testing.expect(dirExists(h.io, try std.fmt.allocPrint(a, "{s}/cwd-probe", .{h.keg})));
}

test "run hands the child a scrubbed environment, not malt's own" {
    // Seed the Io from the same environ main.zig seeds it from: with the
    // default `.empty` the child inherits nothing and this cannot observe an
    // inherit-everything spawn.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = test_secret_environ });
    defer threaded.deinit();
    var h = try TestHarness.init();
    defer h.deinit();
    h.io = threaded.io();
    h.environ = test_secret_environ;
    const a = h.arena.allocator();

    const libexec = try std.fmt.allocPrint(a, "{s}/libexec", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, libexec);
    try std.Io.Dir.cwd().createDirPath(h.io, try std.fmt.allocPrint(a, "{s}/etc", .{h.prefix}));
    const seen = try std.fmt.allocPrint(a, "{s}/etc/seen.txt", .{h.prefix});
    {
        const f = try std.Io.Dir.createFileAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/post-install", .{libexec}), .{});
        defer f.close(h.io);
        var w = f.writer(h.io, &.{});
        // Split literals: scripts/lint-spawn-invariants.sh greps src/ for
        // these argv shapes, string literals inside tests included.
        try w.interface.print("#!" ++ "/bin/" ++ "sh\n/usr/bin/" ++ "env > '{s}'\n", .{seen});
        try w.interface.flush();
        try f.setPermissions(h.io, @enumFromInt(0o755));
    }

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"run","command":{"base":"libexec","path":"post-install"}}]
    )));
    try testing.expect(!h.flog.hasErrors());

    var buf: [64 * 1024]u8 = undefined;
    const f = try std.Io.Dir.openFileAbsolute(h.io, seen, .{});
    defer f.close(h.io);
    var r = f.reader(h.io, &.{});
    const dump = buf[0..try r.interface.readSliceShort(&buf)];

    // The forge token and the user's PATH are the two the fence cannot cover:
    // the profile allows process-exec* and keg/tmp writes.
    try testing.expect(std.mem.indexOf(u8, dump, "sentinel-must-not-leak") == null);
    try testing.expect(std.mem.indexOf(u8, dump, "/attacker/bin") == null);
    try testing.expect(std.mem.indexOf(u8, dump, "PATH=" ++ sandbox_macos.sandbox_path ++ "\n") != null);
    // A scrub, not a wipe: build/locale keys still reach the child, and HOME
    // points at the prefix as it does for the DSL `system` builtin.
    try testing.expect(std.mem.indexOf(u8, dump, "LANG=en_US.UTF-8\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, try std.fmt.allocPrint(a, "HOME={s}\n", .{h.prefix})) != null);
}

test "a tool step's own env vars layer onto the scrubbed base" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = test_secret_environ });
    defer threaded.deinit();
    var h = try TestHarness.init();
    defer h.deinit();
    h.io = threaded.io();
    h.environ = test_secret_environ;
    const a = h.arena.allocator();

    // gdk-pixbuf-query-loaders is the one step that sets its own variables;
    // it derives them from the versioned module dir under the prefix.
    try std.Io.Dir.cwd().createDirPath(h.io, try std.fmt.allocPrint(a, "{s}/opt/gdk-pixbuf/lib/gdk-pixbuf-2.0/2.10.0", .{h.prefix}));
    const bin = try std.fmt.allocPrint(a, "{s}/opt/gdk-pixbuf/bin", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, bin);
    const seen = try std.fmt.allocPrint(a, "{s}/etc/seen.txt", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, try std.fmt.allocPrint(a, "{s}/etc", .{h.prefix}));
    {
        const f = try std.Io.Dir.createFileAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/gdk-pixbuf-query-loaders", .{bin}), .{});
        defer f.close(h.io);
        var w = f.writer(h.io, &.{});
        try w.interface.print("#!" ++ "/bin/" ++ "sh\n/usr/bin/" ++ "env > '{s}'\n", .{seen});
        try w.interface.flush();
        try f.setPermissions(h.io, @enumFromInt(0o755));
    }

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"gdk_pixbuf_query_loaders"}]
    )));
    try testing.expect(!h.flog.hasErrors());

    var buf: [64 * 1024]u8 = undefined;
    const f = try std.Io.Dir.openFileAbsolute(h.io, seen, .{});
    defer f.close(h.io);
    var r = f.reader(h.io, &.{});
    const dump = buf[0..try r.interface.readSliceShort(&buf)];

    try testing.expect(std.mem.indexOf(u8, dump, "GDK_PIXBUF_MODULEDIR=") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "GDK_PIXBUF_MODULE_FILE=") != null);
    // The step used to replace the whole environment with those two, leaving
    // the tool without a PATH; they now sit on top of the scrubbed base.
    try testing.expect(std.mem.indexOf(u8, dump, "PATH=" ++ sandbox_macos.sandbox_path ++ "\n") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "sentinel-must-not-leak") == null);
}

test "run can read a standard user font without opening the rest of HOME" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var h = try TestHarness.init();
    defer h.deinit();
    h.io = threaded.io();
    const a = h.arena.allocator();

    const home = try std.fmt.allocPrint(a, "{s}_home", .{h.prefix});
    defer std.Io.Dir.cwd().deleteTree(h.io, home) catch {};
    const fonts = try std.fmt.allocPrint(a, "{s}/Library/Fonts", .{home});
    const source = try std.fmt.allocPrint(a, "{s}/Probe.ttf", .{fonts});
    const copied = try std.fmt.allocPrint(a, "{s}/share/Probe.ttf", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, fonts);
    try std.Io.Dir.cwd().createDirPath(h.io, try std.fmt.allocPrint(a, "{s}/share", .{h.prefix}));
    {
        const f = try std.Io.Dir.createFileAbsolute(h.io, source, .{});
        defer f.close(h.io);
        try f.writeStreamingAll(h.io, "FONT");
    }

    const libexec = try std.fmt.allocPrint(a, "{s}/libexec", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, libexec);
    try std.Io.Dir.symLinkAbsolute(h.io, "/bin/cp", try std.fmt.allocPrint(a, "{s}/copy-font", .{libexec}), .{});

    const home_var = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{home}, 0);
    var env_entries = [_:null]?[*:0]const u8{home_var.ptr};
    h.environ = .{ .block = .{ .slice = &env_entries } };

    const steps = try std.fmt.allocPrint(
        a,
        \\[{{"type":"run","command":{{"base":"libexec","path":"copy-font"}},
        \\  "args":["{s}","{s}"]}}]
    ,
        .{ source, copied },
    );
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h, steps)));
    try testing.expect(!h.flog.hasErrors());
    const copied_file = try std.Io.Dir.openFileAbsolute(h.io, copied, .{});
    defer copied_file.close(h.io);
    var buf: [4]u8 = undefined;
    const n = try copied_file.readPositionalAll(h.io, &buf, 0);
    try testing.expectEqualStrings("FONT", buf[0..n]);
}

test "run refuses the execution fields malt does not honour" {
    // Compaction drops defaults, so a key that survives into the JSON is one
    // the formula meant. Running without honouring it would be a truncated
    // command, so each refuses instead.
    const refused = [_][]const u8{
        \\[{"type":"run","command":{"base":"bin","path":"t"},"sudo":true}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"sudo":"yes"}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"env":{"LC_ALL":"C"}}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"chdir":"/tmp"}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"stdin_path":"/dev/null"}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"stdout_path":"/tmp/o"}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"writable_paths":["/tmp"]}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"args":"--all"}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"args":[7]}]
        ,
    };
    for (refused) |steps_json| {
        var h = try TestHarness.init();
        defer h.deinit();
        try testing.expect(execute(h.ctx(), try testFormulaJson(&h, steps_json)));
        try testing.expect(h.flog.hasErrors());
        try testing.expect(!h.flog.hasFatal());
        try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
        try testing.expectEqual(fallback_log.FallbackReason.unknown_method, h.flog.entries()[0].reason);
        try testing.expectEqual(@as(usize, 0), h.flog.handled_top_level);
    }

    // `sudo: false` is the default spelled out, not a refusal.
    var h = try TestHarness.init();
    defer h.deinit();
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"run","command":{"base":"bin","path":"t"},"sudo":false}]
    )));
    try testing.expectEqual(fallback_log.FallbackReason.system_command_failed, h.flog.entries()[0].reason);
}

test "run refuses a guard it cannot evaluate rather than reading it as a skip" {
    // Treating an unevaluable condition as "declined to run" would turn a
    // missing feature into a silent no-op — the exact failure the loud
    // envelope exists for. A platform malt knows is evaluated instead; see the
    // on-guard tests.
    const unevaluable = [_][]const u8{
        \\[{"type":"run","command":{"base":"bin","path":"t"},
        \\  "guards":[{"condition":"on","value":"haiku","id":"1"}]}]
        ,
        \\[{"type":"run","command":{"base":"bin","path":"t"},
        \\  "guards":[{"condition":"if_exists","id":"1"}]}]
        ,
    };
    for (unevaluable) |steps_json| {
        var h = try TestHarness.init();
        defer h.deinit();
        try testing.expect(execute(h.ctx(), try testFormulaJson(&h, steps_json)));
        try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
        try testing.expectEqual(fallback_log.FallbackReason.unknown_method, h.flog.entries()[0].reason);
    }
}

test "run declines quietly when an if_exists guard is unmet" {
    var h = try TestHarness.init();
    defer h.deinit();

    // The command does not exist either; an unmet guard must short-circuit
    // before that would be reported.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"run","command":{"base":"bin","path":"t"},
        \\  "guards":[{"path":"{{etc}}/absent.conf","condition":"if_exists","id":"1"}]}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(usize, 1), h.flog.handled_top_level);
}

test "run cannot escape the keg through its command path" {
    // The base is keg-relative, so traversal in the path is the only way out;
    // the shared argv lint catches it before anything spawns.
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"run","command":{"base":"libexec","path":"../../../../../usr/bin/killall"}},
        \\ {"type":"mkdir_p","path":{"base":"var","path":"unreached"}}]
    )));
    try testing.expectEqual(fallback_log.FallbackReason.sandbox_violation, h.flog.entries()[0].reason);
    // A violation is fatal, so the following step never ran.
    try testing.expect(h.flog.hasFatal());
    try testing.expect(!dirExists(h.io, try std.fmt.allocPrint(h.arena.allocator(), "{s}/var/unreached", .{h.prefix})));
}

test "run reports a command missing from the keg as a loud failure" {
    // A helper the bottle should have shipped is a broken install, not an
    // unsupported step — it must not read as "malt can't do this".
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"run","command":{"base":"libexec","path":"post-install"}}]
    )));
    try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
    try testing.expectEqual(fallback_log.FallbackReason.system_command_failed, h.flog.entries()[0].reason);
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
    // dbus embeds `{{var}}` in a run argument; it resolved as a base but had
    // no inline mapping, so the token reached the child verbatim.
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(h.arena.allocator(), "{s}/var/lib/dbus", .{h.prefix}),
        try expandTemplates(c, "{{var}}/lib/dbus"),
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

// --- migrated step types ---------------------------------------------------

test "configure_clang_system writes one isysroot config per arch and target" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Driven with known versions: the point is the filenames and the exact
    // byte content, not whatever the host happens to report.
    try testing.expect(writeClangConfigs(h.ctx(), 26, 25));
    try testing.expect(!h.flog.hasErrors());

    const want = "-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk\n";
    for ([_][]const u8{ "arm64", "x86_64", "aarch64" }) |arch| {
        for ([_][]const u8{ "darwin25", "macosx26" }) |target| {
            const path = try std.fmt.allocPrint(a, "{s}/etc/clang/{s}-apple-{s}.cfg", .{ h.prefix, arch, target });
            const got = try fs_read.readFileAllAbsolute(h.io, a, path, 4096);
            try testing.expectEqualStrings(want, got);
        }
    }
}

test "configure_clang_system writes nothing when every config file already exists" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    try testing.expect(writeClangConfigs(h.ctx(), 26, 25));
    const probe = try std.fmt.allocPrint(a, "{s}/etc/clang/arm64-apple-darwin25.cfg", .{h.prefix});
    try atomic.atomicWriteFile(h.io, probe, "user edit\n");

    // A second run must leave a complete set exactly as the user has it.
    try testing.expect(writeClangConfigs(h.ctx(), 26, 25));
    try testing.expectEqualStrings("user edit\n", try fs_read.readFileAllAbsolute(h.io, a, probe, 4096));
}

test "configure_clang_system refuses rather than naming files from an unknown version" {
    // The version reads are the step's only inputs; an unreadable one must
    // yield null so the caller refuses, not a sentinel that names six files
    // after a number nothing produced.
    try testing.expect(sysctlMajor("kern.no_such_sysctl_for_malt") == null);
    try testing.expect(sysctlMajor("kern.osrelease") != null);
    try testing.expect(sysctlMajor("kern.osproductversion") != null);

    // The Darwin major and the macOS major are different numbers, which is the
    // whole reason the step reads two sysctls.
    try testing.expect(sysctlMajor("kern.osrelease").? != sysctlMajor("kern.osproductversion").?);
}

test "configure_gcc_runtime is a no-op on macOS rather than an unsupported step" {
    var h = try TestHarness.init();
    defer h.deinit();

    const json = try testFormulaJson(&h, "[{\"type\":\"configure_gcc_runtime\"}]");
    try testing.expect(execute(h.ctx(), json));
    // Upstream's body is Linux-only, so "handled, nothing to do" is correct —
    // routing it as unsupported would downgrade every gcc install.
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(usize, 1), h.flog.notes().len);
    // Notes render verbatim; without the newline the next line runs into it.
    try testing.expect(std.mem.endsWith(u8, h.flog.notes()[0], "\n"));
}

test "warn surfaces the formula's message instead of downgrading the install" {
    var h = try TestHarness.init();
    defer h.deinit();

    const json = try testFormulaJson(&h,
        \\[{"type":"warn","message":"A system my.cnf may interfere with {{name}}."}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(usize, 1), h.flog.notes().len);
    try testing.expectEqualStrings("A system my.cnf may interfere with glow.\n", h.flog.notes()[0]);
}

test "move relocates a tree and refuses an occupied target without overwrite" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/libexec/html", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, src);
    try atomic.atomicWriteFile(h.io, try std.fmt.allocPrint(a, "{s}/index.html", .{src}), "hi\n");

    const json = try testFormulaJson(&h,
        \\[{"type":"move","source":{"base":"libexec","path":"html"},"target":{"base":"var","path":"www"}}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    const moved = try std.fmt.allocPrint(a, "{s}/var/www/index.html", .{h.prefix});
    try testing.expectEqualStrings("hi\n", try fs_read.readFileAllAbsolute(h.io, a, moved, 64));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(h.io, src, .{}));

    // Second run: the docroot is the user's now, and the source is still in
    // the keg, so a silent skip would hide a relocation that did not happen.
    try std.Io.Dir.cwd().createDirPath(h.io, src);
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(h.flog.hasErrors());
    try testing.expectEqualStrings("hi\n", try fs_read.readFileAllAbsolute(h.io, a, moved, 64));
}

test "move overwrites an occupied target when the step asks for it" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/libexec/html", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, src);
    try atomic.atomicWriteFile(h.io, try std.fmt.allocPrint(a, "{s}/index.html", .{src}), "new\n");
    const dst = try std.fmt.allocPrint(a, "{s}/var/www", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, dst);
    try atomic.atomicWriteFile(h.io, try std.fmt.allocPrint(a, "{s}/stale.html", .{dst}), "old\n");

    const json = try testFormulaJson(&h,
        \\[{"type":"move","source":{"base":"libexec","path":"html"},"target":{"base":"var","path":"www"},"overwrite":true}]
    );
    try testing.expect(execute(h.ctx(), json));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqualStrings("new\n", try fs_read.readFileAllAbsolute(h.io, a, try std.fmt.allocPrint(a, "{s}/index.html", .{dst}), 64));
    // The whole tree is replaced, not merged.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/stale.html", .{dst}), .{}),
    );
}

test "move refuses a source that escapes the keg and prefix" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    var outside = try Scratch.init("steps_move_outside");
    defer outside.deinit();
    try std.Io.Dir.cwd().createDirPath(h.io, outside.base);
    try atomic.atomicWriteFile(h.io, outside.p("/secret"), "s\n");

    const json = try std.fmt.allocPrint(a,
        \\[{{"type":"move","source":{{"path":"{s}"}},"target":{{"base":"var","path":"stolen"}}}}]
    , .{outside.base});
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h, json)));
    try testing.expect(h.flog.hasErrors());
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/var/stolen", .{h.prefix}), .{}),
    );
}

test "set_permissions recurses by default and honours non_recursive" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Upstream passes -R unless non_recursive is set. Getting that backwards
    // leaves the tree under a declared directory at its bottled mode.
    const nested = try std.fmt.allocPrint(a, "{s}/var/tree/inner", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, nested);
    const leaf = try std.fmt.allocPrint(a, "{s}/leaf", .{nested});
    try atomic.atomicWriteFile(h.io, leaf, "x\n");

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","paths":[{"base":"var","path":"tree"}],"permissions":"0700"}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), try fileMode(h.io, leaf));

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","paths":[{"base":"var","path":"tree"}],"permissions":"0755","non_recursive":true}]
    )));
    // Only the named directory moved; the leaf kept the recursive run's mode.
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), try fileMode(h.io, leaf));
    try testing.expectEqual(
        @as(std.posix.mode_t, 0o755),
        try fileMode(h.io, try std.fmt.allocPrint(a, "{s}/var/tree", .{h.prefix})),
    );
}

test "set_permissions applies symbolic modes and skips paths that do not exist" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const file = try std.fmt.allocPrint(a, "{s}/share/glow/save", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(file).?);
    try atomic.atomicWriteFile(h.io, file, "x\n");
    try chmodPath(h.io, file, 0o644);

    // The second path was never shipped: upstream filters it out rather than
    // failing the step.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","non_recursive":true,"permissions":"g+w",
        \\  "paths":[{"base":"pkgshare","path":"save"},{"base":"pkgshare","path":"absent"}]}]
    )));
    try testing.expect(!h.flog.hasErrors());
    // g+w adds to what the file already carries; it does not replace it.
    try testing.expectEqual(@as(std.posix.mode_t, 0o664), try fileMode(h.io, file));
}

test "set_permissions refuses a symbolic mode it cannot parse" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","paths":[{"base":"var","path":"x"}],"permissions":"a+X"}]
    )));
    // Silently doing nothing is how a mode ends up wrong; refuse loudly.
    try testing.expect(h.flog.hasErrors());
}

test "parseMode covers the octal and symbolic spellings homebrew-core ships" {
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), parseMode("0700").?.absolute);
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), parseMode("755").?.absolute);
    // Masked, not truncated: chmod(2) only consults the low bits.
    try testing.expectEqual(@as(std.posix.mode_t, 0o7777), parseMode("77777").?.absolute);

    try testing.expectEqual(@as(std.posix.mode_t, 0o644), applyMode(0o644, parseMode("u+r").?));
    try testing.expectEqual(@as(std.posix.mode_t, 0o664), applyMode(0o644, parseMode("g+w").?));
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), applyMode(0o555, parseMode("u+w").?));
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), applyMode(0o660, parseMode("g-rw").?));
    try testing.expectEqual(@as(std.posix.mode_t, 0o744), applyMode(0o777, parseMode("go=r").?));
    try testing.expectEqual(@as(std.posix.mode_t, 0o777), applyMode(0o000, parseMode("a+rwx").?));

    // Anything outside that grammar has to refuse rather than approximate.
    for ([_][]const u8{ "", "+w", "u", "u+", "u?w", "a+X", "9999", "ugo" }) |bad| {
        try testing.expect(parseMode(bad) == null);
    }
}

test "set_permissions expands the glob shapes upstream path specs carry" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // redis names `modules/*`; python names `venv/scripts/**/*`. A literal
    // path never matches either, so the step would be a silent no-op.
    const modules = try std.fmt.allocPrint(a, "{s}/lib/glow/modules", .{h.prefix});
    const deep = try std.fmt.allocPrint(a, "{s}/lib/glow/scripts/common", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, modules);
    try std.Io.Dir.cwd().createDirPath(h.io, deep);
    const mod = try std.fmt.allocPrint(a, "{s}/one.so", .{modules});
    const activate = try std.fmt.allocPrint(a, "{s}/activate", .{deep});
    try atomic.atomicWriteFile(h.io, mod, "x\n");
    try atomic.atomicWriteFile(h.io, activate, "x\n");
    try chmodPath(h.io, mod, 0o600);
    try chmodPath(h.io, activate, 0o444);

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","paths":[{"base":"lib","path":"glow/modules/*"}],"permissions":"0755"},
        \\ {"type":"set_permissions","non_recursive":true,"permissions":"u+w",
        \\  "paths":[{"base":"lib","path":"glow/scripts/**/*"}]}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), try fileMode(h.io, mod));
    try testing.expectEqual(@as(std.posix.mode_t, 0o644), try fileMode(h.io, activate));
}

test "set_permissions refuses a pattern it cannot expand faithfully" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","paths":[{"base":"var","path":"a*/b/c"}],"permissions":"0755"}]
    )));
    try testing.expect(h.flog.hasErrors());
}

test "the frameworks base resolves inside the keg, matching upstream's prefix/Frameworks" {
    var h = try TestHarness.init();
    defer h.deinit();

    const resolved = resolveBase(h.ctx(), "frameworks", null).?;
    const expected = try std.fmt.allocPrint(h.arena.allocator(), "{s}/Frameworks", .{h.keg});
    try testing.expectEqualStrings(expected, resolved);
}

test "install_gzipped_executable unpacks, marks executable, and unlinks the source" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/libexec/bin/glow-real.gz", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(src).?);
    try atomic.atomicWriteFile(h.io, src, try gzipBytes(a, "\x7fELF payload\n"));

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"install_gzipped_executable","source":{"base":"libexec","path":"bin/glow-real.gz"},
        \\  "target":{"base":"libexec","path":"bin/glow-real"}}]
    )));
    try testing.expect(!h.flog.hasErrors());

    const target = try std.fmt.allocPrint(a, "{s}/libexec/bin/glow-real", .{h.keg});
    try testing.expectEqualStrings("\x7fELF payload\n", try fs_read.readFileAllAbsolute(h.io, a, target, 4096));
    // Without the exec bit the unpacked binary is unrunnable, and the archive
    // left behind would ship in the keg.
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), try fileMode(h.io, target));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(h.io, src, .{}));
}

test "install_gzipped_executable leaves no temp file behind on a corrupt source" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/libexec/bin/glow-real.gz", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(src).?);
    try atomic.atomicWriteFile(h.io, src, "not gzip at all");

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"install_gzipped_executable","source":{"base":"libexec","path":"bin/glow-real.gz"},
        \\  "target":{"base":"libexec","path":"bin/glow-real"}}]
    )));
    try testing.expect(h.flog.hasErrors());
    // A half-written dotfile in bin/ would ship in the keg and confuse linking.
    const tmp = try std.fmt.allocPrint(a, "{s}/libexec/bin/.glow-real.install-step", .{h.keg});
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(h.io, tmp, .{}));
    // The archive survives, so a re-run can still succeed.
    try std.Io.Dir.accessAbsolute(h.io, src, .{});
}

test "install_gzipped_executable is a silent no-op when the bottle shipped no archive" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"install_gzipped_executable","source":{"base":"libexec","path":"bin/absent.gz"},
        \\  "target":{"base":"libexec","path":"bin/absent"}}]
    )));
    try testing.expect(!h.flog.hasErrors());
}

test "change_dylib_id sets the install name on the real file behind a resolved source" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // The keg publishes the dylib as a symlink to its versioned twin. Which
    // file the rewrite lands on is the whole contract of `resolve_source`, and
    // the failure detail is the only place that choice is observable without a
    // real Mach-O to hand to install_name_tool.
    const real = try std.fmt.allocPrint(a, "{s}/lib/libruby.3.4.dylib", .{h.keg});
    const link = try std.fmt.allocPrint(a, "{s}/lib/libruby.dylib", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(real).?);
    try atomic.atomicWriteFile(h.io, real, "not a mach-o\n");
    try std.Io.Dir.symLinkAbsolute(h.io, real, link, .{});
    try std.Io.Dir.accessAbsolute(h.io, real, .{});

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"change_dylib_id","source":{"base":"prefix","path":"lib/libruby.dylib"},
        \\  "id":"{{HOMEBREW_PREFIX}}/opt/glow/lib/libruby.3.4.dylib","resolve_source":true}]
    )));
    try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
    const detail = h.flog.entries()[0].detail;
    // Naming the link would mean the realpath step was skipped. (The scratch
    // prefix lives under /tmp, itself a symlink on macOS, so the resolved path
    // leaves the harness prefix and is refused — the detail still records which
    // file the step chose, which is what `resolve_source` decides.)
    try testing.expect(std.mem.endsWith(u8, detail, "/lib/libruby.3.4.dylib"));
    try testing.expect(std.mem.indexOf(u8, detail, "Cellar/glow/1.2.3") != null);
}

test "change_dylib_id without resolve_source rewrites the path it was handed" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const real = try std.fmt.allocPrint(a, "{s}/lib/libruby.3.4.dylib", .{h.keg});
    const link = try std.fmt.allocPrint(a, "{s}/lib/libruby.dylib", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(real).?);
    try atomic.atomicWriteFile(h.io, real, "not a mach-o\n");
    try std.Io.Dir.symLinkAbsolute(h.io, real, link, .{});

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"change_dylib_id","source":{"base":"prefix","path":"lib/libruby.dylib"},
        \\  "id":"{{HOMEBREW_PREFIX}}/opt/glow/lib/libruby.dylib"}]
    )));
    try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
    try testing.expect(std.mem.indexOf(u8, h.flog.entries()[0].detail, link) != null);
}

test "change_dylib_id refuses a source that resolves outside the keg and prefix" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    var outside = try Scratch.init("steps_dylib_outside");
    defer outside.deinit();
    try std.Io.Dir.cwd().createDirPath(h.io, outside.base);
    try atomic.atomicWriteFile(h.io, outside.p("/libvictim.dylib"), "not macho\n");
    const link = try std.fmt.allocPrint(a, "{s}/lib/libruby.dylib", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(link).?);
    try std.Io.Dir.symLinkAbsolute(h.io, outside.p("/libvictim.dylib"), link, .{});

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"change_dylib_id","source":{"base":"prefix","path":"lib/libruby.dylib"},
        \\  "id":"{{HOMEBREW_PREFIX}}/opt/glow/lib/libruby.dylib","resolve_source":true}]
    )));
    try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
    try testing.expectEqual(fallback_log.FallbackReason.sandbox_violation, h.flog.entries()[0].reason);
    try testing.expectEqualStrings(
        "not macho\n",
        try fs_read.readFileAllAbsolute(h.io, a, outside.p("/libvictim.dylib"), 64),
    );
}

test "change_dylib_id refuses a step that names no id" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"change_dylib_id","source":{"base":"prefix","path":"lib/x.dylib"}}]
    )));
    try testing.expect(h.flog.hasErrors());
}

test "terminate_process treats an absent process as success" {
    // The debug Io cannot spawn, so this tier needs a real threaded Io.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var h = try TestHarness.init();
    defer h.deinit();
    h.io = threaded.io();

    // killall exits non-zero when nothing matched, which is the normal case on
    // a first install — reading that as failure would fail every such install.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"terminate_process","name":"malt-no-such-daemon"}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(usize, 1), h.flog.handled_top_level);
}

test "terminate_process refuses the privilege fields malt does not honour" {
    var h = try TestHarness.init();
    defer h.deinit();

    // `sudo` and `must_succeed` change what the step is allowed to do; dropping
    // them silently would be worse than not running the step at all.
    for ([_][]const u8{
        \\[{"type":"terminate_process","name":"gpg-agent","sudo":true}]
        ,
        \\[{"type":"terminate_process","name":"gpg-agent","must_succeed":true}]
        ,
    }) |steps| {
        var fresh = try TestHarness.init();
        defer fresh.deinit();
        try testing.expect(execute(fresh.ctx(), try testFormulaJson(&fresh, steps)));
        try testing.expect(fresh.flog.hasErrors());
    }
    try testing.expect(!h.flog.hasErrors());
}

// --- helpers for the step tests --------------------------------------------

fn fileMode(io: std.Io, path: []const u8) !std.posix.mode_t {
    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    const s = try f.stat(io);
    return s.permissions.toMode() & 0o7777;
}

fn chmodPath(io: std.Io, path: []const u8, mode: std.posix.mode_t) !void {
    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    try f.setPermissions(io, .fromMode(mode));
}

/// Minimal gzip stream: a single stored deflate block. Enough to exercise the
/// decompressor without pulling a compressor's 224 KiB of state into a test.
fn gzipBytes(a: std.mem.Allocator, payload: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &.{ 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff });
    try out.append(a, 0x01); // BFINAL=1, BTYPE=stored
    const len: u16 = @intCast(payload.len);
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
    try out.appendSlice(a, payload);
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, std.hash.Crc32.hash(payload))));
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, len)));
    return out.toOwnedSlice(a);
}

test "set_permissions walks past a symlink instead of failing the step on it" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Kegs are full of their own symlinks. `chmod -R` skips them; treating one
    // as a confinement violation would fail an install over ordinary layout.
    const tree = try std.fmt.allocPrint(a, "{s}/var/tree", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, tree);
    const real = try std.fmt.allocPrint(a, "{s}/real", .{tree});
    try atomic.atomicWriteFile(h.io, real, "x\n");
    try std.Io.Dir.symLinkAbsolute(h.io, "/etc/hosts", try std.fmt.allocPrint(a, "{s}/link", .{tree}), .{});

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","paths":[{"base":"var","path":"tree"}],"permissions":"0700"}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), try fileMode(h.io, real));
}

test "terminate_process refuses a name killall would read as an option" {
    var h = try TestHarness.init();
    defer h.deinit();

    // The name is tap-controlled and killall has no `--` terminator.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"terminate_process","name":"-9"}]
    )));
    try testing.expect(h.flog.hasErrors());
}

test "move reports a source the bottle never shipped as a mismatch, not a violation" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"move","source":{"base":"libexec","path":"absent"},"target":{"base":"var","path":"www"}},
        \\ {"type":"mkdir_p","path":{"base":"var","path":"after"}}]
    )));
    try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
    // A sandbox_violation is fatal and would abort every following step; a
    // missing source is a formula/bottle mismatch, not an escape attempt.
    try testing.expectEqual(fallback_log.FallbackReason.unknown_method, h.flog.entries()[0].reason);
    try std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(h.arena.allocator(), "{s}/var/after", .{h.prefix}), .{});
}

test "a step carrying both a platform and an existence guard evaluates both" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // ruby's change_dylib_id ships exactly this pair; one guard short-circuits
    // the other only if both are reached.
    const json =
        \\[{"type":"mkdir_p","path":{"base":"var","path":"made"},
        \\  "guards":[{"condition":"on","value":"macos","id":"1"},
        \\            {"base":"var","path":"marker","condition":"if_exists","id":"2"}]}]
    ;
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h, json)));
    try testing.expect(!h.flog.hasErrors());
    // The platform matched but the marker is absent, so the step stays unrun.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/var/made", .{h.prefix}), .{}),
    );

    try std.Io.Dir.cwd().createDirPath(h.io, try std.fmt.allocPrint(a, "{s}/var", .{h.prefix}));
    (try std.Io.Dir.createFileAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/var/marker", .{h.prefix}), .{})).close(h.io);
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h, json)));
    try std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/var/made", .{h.prefix}), .{});
}

test "a recursive remove expands the glob a formula names its stale tree with" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // ruby retires `gems/bundler-*`; a literal path matches nothing, so the
    // superseded copy would survive every upgrade.
    const gems = try std.fmt.allocPrint(a, "{s}/lib/gems", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, try std.fmt.allocPrint(a, "{s}/bundler-2.6.9", .{gems}));
    const keep = try std.fmt.allocPrint(a, "{s}/rake-13.2.1", .{gems});
    try std.Io.Dir.cwd().createDirPath(h.io, keep);

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"remove","recursive":true,"paths":[{"base":"lib","path":"gems/bundler-*"}]}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/bundler-2.6.9", .{gems}), .{}),
    );
    // Neighbours the pattern does not name must survive.
    try std.Io.Dir.accessAbsolute(h.io, keep, .{});
}

test "a globbed recursive remove still refuses a shared prefix directory" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Expansion happens before the shared-ground guard, so a pattern must not
    // be a way around it: `<prefix>/*` names every other package's ground.
    const lib = try std.fmt.allocPrint(a, "{s}/lib", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, lib);

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"remove","recursive":true,"paths":[{"base":"homebrew_prefix","path":"*"}]}]
    )));
    try testing.expect(h.flog.hasErrors());
    try std.Io.Dir.accessAbsolute(h.io, lib, .{});
}

test "a glob is refused when its root sits outside the keg and prefix" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Expansion reads a subtree to discover paths, so an unbounded root would
    // hand a tap recursive enumeration of anywhere this user can read — even
    // though the per-match confinement would still refuse the writes.
    var outside = try Scratch.init("steps_glob_outside");
    defer outside.deinit();
    try std.Io.Dir.cwd().createDirPath(h.io, outside.base);
    try atomic.atomicWriteFile(h.io, outside.p("/secret"), "s\n");

    inline for (.{
        \\[{{"type":"set_permissions","permissions":"0755","paths":[{{"path":"{s}/*"}}]}}]
        ,
        \\[{{"type":"remove","recursive":true,"paths":[{{"path":"{s}/**/*"}}]}}]
        ,
    }) |shape| {
        var fresh = try TestHarness.init();
        defer fresh.deinit();
        const json = try std.fmt.allocPrint(a, shape, .{outside.base});
        try testing.expect(execute(fresh.ctx(), try testFormulaJson(&fresh, json)));
        try testing.expectEqual(@as(usize, 1), fresh.flog.entries().len);
        try testing.expectEqual(fallback_log.FallbackReason.sandbox_violation, fresh.flog.entries()[0].reason);
    }
    try testing.expectEqualStrings("s\n", try fs_read.readFileAllAbsolute(h.io, a, outside.p("/secret"), 16));
}

test "configure_clang_system completes a set left half-written by an earlier run" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // An interrupted run leaves some of the six behind. The early exit only
    // fires on a complete set, so the rest must still be written.
    const dir = try std.fmt.allocPrint(a, "{s}/etc/clang", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, dir);
    const present = try std.fmt.allocPrint(a, "{s}/arm64-apple-darwin25.cfg", .{dir});
    try atomic.atomicWriteFile(h.io, present, "stale\n");

    try testing.expect(writeClangConfigs(h.ctx(), 26, 25));
    try testing.expect(!h.flog.hasErrors());

    const want = "-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk\n";
    const missing = try std.fmt.allocPrint(a, "{s}/x86_64-apple-macosx26.cfg", .{dir});
    try testing.expectEqualStrings(want, try fs_read.readFileAllAbsolute(h.io, a, missing, 4096));
    // The incomplete set is rewritten wholesale, matching upstream's all-or-none check.
    try testing.expectEqualStrings(want, try fs_read.readFileAllAbsolute(h.io, a, present, 4096));
}

test "configure_clang_system names its files from the host's own two versions" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Guards the seam between the sysctl reads and the writer: transposing the
    // two majors still writes six plausible files, all wrongly named.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h, "[{\"type\":\"configure_clang_system\"}]")));
    try testing.expect(!h.flog.hasErrors());

    const kernel = sysctlMajor("kern.osrelease").?;
    const macos = sysctlMajor("kern.osproductversion").?;
    try std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/etc/clang/arm64-apple-darwin{d}.cfg", .{ h.prefix, kernel }), .{});
    try std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/etc/clang/arm64-apple-macosx{d}.cfg", .{ h.prefix, macos }), .{});
}

test "install_gzipped_executable refuses a source or target outside the prefix" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    var outside = try Scratch.init("steps_gz_outside");
    defer outside.deinit();
    try std.Io.Dir.cwd().createDirPath(h.io, outside.base);
    try atomic.atomicWriteFile(h.io, outside.p("/payload.gz"), try gzipBytes(a, "payload\n"));

    // The step decompresses tap-controlled bytes and marks the result
    // executable, so both ends need the same boundary as every other write.
    const escaping_source = try std.fmt.allocPrint(a,
        \\[{{"type":"install_gzipped_executable","source":{{"path":"{s}/payload.gz"}},
        \\  "target":{{"base":"libexec","path":"bin/x"}}}}]
    , .{outside.base});
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h, escaping_source)));
    try testing.expect(h.flog.hasErrors());
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}/libexec/bin/x", .{h.keg}), .{}),
    );

    var h2 = try TestHarness.init();
    defer h2.deinit();
    const src = try std.fmt.allocPrint(h2.arena.allocator(), "{s}/libexec/payload.gz", .{h2.keg});
    try std.Io.Dir.cwd().createDirPath(h2.io, std.fs.path.dirname(src).?);
    try atomic.atomicWriteFile(h2.io, src, try gzipBytes(h2.arena.allocator(), "payload\n"));
    const escaping_target = try std.fmt.allocPrint(h2.arena.allocator(),
        \\[{{"type":"install_gzipped_executable","source":{{"base":"libexec","path":"payload.gz"}},
        \\  "target":{{"path":"{s}/planted"}}}}]
    , .{outside.base});
    try testing.expect(execute(h2.ctx(), try testFormulaJson(&h2, escaping_target)));
    try testing.expect(h2.flog.hasErrors());
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h2.io, outside.p("/planted"), .{}),
    );
}

test "move honours force as upstream's alias for overwrite" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    const src = try std.fmt.allocPrint(a, "{s}/libexec/html", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, src);
    try atomic.atomicWriteFile(h.io, try std.fmt.allocPrint(a, "{s}/index.html", .{src}), "new\n");
    const dst = try std.fmt.allocPrint(a, "{s}/var/www", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, dst);

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"move","source":{"base":"libexec","path":"html"},"target":{"base":"var","path":"www"},"force":true}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqualStrings(
        "new\n",
        try fs_read.readFileAllAbsolute(h.io, a, try std.fmt.allocPrint(a, "{s}/index.html", .{dst}), 64),
    );
    // Nothing of the swap-aside scaffolding may survive in the prefix.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(h.io, try std.fmt.allocPrint(a, "{s}.malt-replaced", .{dst}), .{}),
    );
}

test "steps that lose a field they cannot invent refuse instead of guessing" {
    // Each of these drops the one key that carries the step's whole intent.
    const shapes = [_][]const u8{
        \\[{"type":"warn"}]
        ,
        \\[{"type":"set_permissions","paths":[{"base":"var","path":"x"}]}]
        ,
        \\[{"type":"set_permissions","permissions":"0755"}]
        ,
        \\[{"type":"set_permissions","permissions":"0755","paths":{"base":"var","path":"x"}}]
        ,
        \\[{"type":"terminate_process"}]
        ,
    };
    for (shapes) |shape| {
        var h = try TestHarness.init();
        defer h.deinit();
        try testing.expect(execute(h.ctx(), try testFormulaJson(&h, shape)));
        try testing.expect(h.flog.hasErrors());
    }
}

test "set_permissions tolerates the empty and unmatched shapes upstream compacts to" {
    var h = try TestHarness.init();
    defer h.deinit();

    // An empty array, a non-object entry, and a glob that matches nothing are
    // all "nothing to do" upstream — none of them is an error.
    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","paths":[],"permissions":"0755"},
        \\ {"type":"set_permissions","paths":["oops"],"permissions":"0755"},
        \\ {"type":"set_permissions","paths":[{"base":"var","path":"nothing/here/*"}],"permissions":"0755"}]
    )));
    try testing.expect(!h.flog.hasErrors());
}

test "a glob root cannot walk out of the prefix through a parent reference" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // Textually inside the prefix, actually outside it. Nothing between the
    // spec and `openDirAbsolute` normalises a path, so a bare prefix compare
    // would admit this and hand a tap recursive enumeration of the disk.
    var outside = try Scratch.init("steps_dotdot");
    defer outside.deinit();
    try std.Io.Dir.cwd().createDirPath(h.io, outside.base);
    try atomic.atomicWriteFile(h.io, outside.p("/secret"), "s\n");

    const escape = try std.fmt.allocPrint(a, "{s}/..{s}", .{ h.prefix, outside.base });
    inline for (.{
        \\[{{"type":"set_permissions","permissions":"0777","paths":[{{"path":"{s}/*"}}]}}]
        ,
        \\[{{"type":"remove","recursive":true,"paths":[{{"path":"{s}/**/*"}}]}}]
        ,
        \\[{{"type":"change_dylib_id","source":{{"path":"{s}/secret"}},"id":"/x","resolve_source":true}}]
        ,
    }) |shape| {
        var fresh = try TestHarness.init();
        defer fresh.deinit();
        const json = try std.fmt.allocPrint(a, shape, .{escape});
        try testing.expect(execute(fresh.ctx(), try testFormulaJson(&fresh, json)));
        try testing.expectEqual(@as(usize, 1), fresh.flog.entries().len);
        try testing.expectEqual(fallback_log.FallbackReason.sandbox_violation, fresh.flog.entries()[0].reason);
    }
    try testing.expectEqualStrings("s\n", try fs_read.readFileAllAbsolute(h.io, a, outside.p("/secret"), 16));
}

test "withinBounds refuses what validatePath refuses" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const c = h.ctx();

    try testing.expect(withinBounds(c, try std.fmt.allocPrint(a, "{s}/lib", .{h.prefix})));
    try testing.expect(withinBounds(c, try std.fmt.allocPrint(a, "{s}/bin", .{h.keg})));
    // A parent reference, a relative path, and a sibling whose name merely
    // starts with the prefix all have to be refused.
    try testing.expect(!withinBounds(c, try std.fmt.allocPrint(a, "{s}/../etc", .{h.prefix})));
    try testing.expect(!withinBounds(c, "relative/path"));
    try testing.expect(!withinBounds(c, try std.fmt.allocPrint(a, "{s}evil/lib", .{h.prefix})));
    try testing.expect(!withinBounds(c, "/etc"));
}

test "resolveLink follows a chain, a relative hop, and gives up on a cycle" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();
    const c = h.ctx();

    const dir = try std.fmt.allocPrint(a, "{s}/lib", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, dir);
    const real = try std.fmt.allocPrint(a, "{s}/real", .{dir});
    try atomic.atomicWriteFile(h.io, real, "x\n");

    // Two hops, the second one relative — a keg's own link farm uses both.
    const mid = try std.fmt.allocPrint(a, "{s}/mid", .{dir});
    const top = try std.fmt.allocPrint(a, "{s}/top", .{dir});
    // Relative target, so not `symLinkAbsolute` — it asserts an absolute one.
    {
        var d = try std.Io.Dir.openDirAbsolute(h.io, dir, .{});
        defer d.close(h.io);
        try std.Io.Dir.symLink(d, h.io, "real", "mid", .{});
    }
    try std.Io.Dir.symLinkAbsolute(h.io, mid, top, .{});
    try testing.expectEqualStrings(real, resolveLink(c, top));

    // A cycle must terminate rather than spin; the caller then refuses it
    // because what comes back is still a symlink.
    const loop_a = try std.fmt.allocPrint(a, "{s}/loop_a", .{dir});
    const loop_b = try std.fmt.allocPrint(a, "{s}/loop_b", .{dir});
    try std.Io.Dir.symLinkAbsolute(h.io, loop_b, loop_a, .{});
    try std.Io.Dir.symLinkAbsolute(h.io, loop_a, loop_b, .{});
    const settled = resolveLink(c, loop_a);
    try testing.expect(std.mem.indexOf(u8, settled, "loop_") != null);

    // A plain file resolves to itself.
    try testing.expectEqualStrings(real, resolveLink(c, real));
}

test "a glob descent does not cross a symlinked directory boundary" {
    var h = try TestHarness.init();
    defer h.deinit();
    const a = h.arena.allocator();

    // A linked prefix is full of directory symlinks pointing back at the
    // Cellar. Descending through one would apply a mode to a tree the pattern
    // never named, so `**` stops at the boundary — same rule `chmod -R` uses.
    const root = try std.fmt.allocPrint(a, "{s}/var/tree", .{h.prefix});
    const elsewhere = try std.fmt.allocPrint(a, "{s}/var/elsewhere", .{h.prefix});
    try std.Io.Dir.cwd().createDirPath(h.io, root);
    try std.Io.Dir.cwd().createDirPath(h.io, elsewhere);
    const hidden = try std.fmt.allocPrint(a, "{s}/hidden", .{elsewhere});
    try atomic.atomicWriteFile(h.io, hidden, "x\n");
    try chmodPath(h.io, hidden, 0o600);
    try std.Io.Dir.symLinkAbsolute(h.io, elsewhere, try std.fmt.allocPrint(a, "{s}/link", .{root}), .{});

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"set_permissions","non_recursive":true,"permissions":"0755",
        \\  "paths":[{"base":"var","path":"tree/**/*"}]}]
    )));
    try testing.expect(!h.flog.hasErrors());
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), try fileMode(h.io, hidden));
}

test "parseMode refuses an octal literal too wide for a file mode" {
    // parseInt overflows before the mask can run, so the refusal comes from the
    // parse, not from truncation.
    try testing.expect(parseMode("7777777777777777777777") == null);
    try testing.expect(parseMode("0700") != null);
}

/// Minimal Mach-O dylib carrying one `LC_ID_DYLIB`. `install_name_tool`
/// accepts this shape, so the rewrite can be driven for real without a
/// compiler or a bottle. The embedded name is padded so a longer replacement
/// still fits its slot.
fn writeSynthDylib(io: std.Io, path: []const u8, id: []const u8) !void {
    const macho = std.macho;
    const lc_size = @sizeOf(macho.dylib_command);
    const slot = 256;
    const cmdsize: u32 = @intCast((lc_size + slot + 7) & ~@as(usize, 7));
    const header_size = @sizeOf(macho.mach_header_64);

    var buf: [header_size + 512]u8 = undefined;
    const total = header_size + cmdsize;
    @memset(buf[0..total], 0);

    const header = std.mem.bytesAsValue(macho.mach_header_64, buf[0..header_size]);
    header.* = .{
        .magic = macho.MH_MAGIC_64,
        // arm64 + MH_DYLIB: install_name_tool refuses anything it cannot
        // recognise as a dylib for this host.
        .cputype = macho.CPU_TYPE_ARM64,
        .filetype = macho.MH_DYLIB,
        .ncmds = 1,
        .sizeofcmds = cmdsize,
    };
    const dy = std.mem.bytesAsValue(macho.dylib_command, buf[header_size..][0..lc_size]);
    dy.* = .{
        .cmd = .ID_DYLIB,
        .cmdsize = cmdsize,
        .dylib = .{ .name = @intCast(lc_size), .timestamp = 0, .current_version = 0, .compatibility_version = 0 },
    };
    @memcpy(buf[header_size + lc_size ..][0..id.len], id);

    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, buf[0..total]);
}

/// The `LC_ID_DYLIB` name currently on disk. Read straight out of the file so
/// the assertion is the byte the linker would see, not malt's idea of it —
/// `patch.fileLinksPath` deliberately skips this load command.
fn readDylibId(io: std.Io, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const f = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    const data = try fs_read.readFileAll(io, a, f, 1 << 20);
    const header = std.mem.bytesAsValue(std.macho.mach_header_64, data[0..@sizeOf(std.macho.mach_header_64)]);
    var off: usize = @sizeOf(std.macho.mach_header_64);
    for (0..header.ncmds) |_| {
        const lc = std.mem.bytesAsValue(std.macho.load_command, data[off..][0..@sizeOf(std.macho.load_command)]);
        if (lc.cmd == .ID_DYLIB) {
            const dy = std.mem.bytesAsValue(std.macho.dylib_command, data[off..][0..@sizeOf(std.macho.dylib_command)]);
            return std.mem.sliceTo(data[off + dy.dylib.name ..], 0);
        }
        off += lc.cmdsize;
    }
    return null;
}

test "change_dylib_id rewrites the install name on a real Mach-O" {
    // Needs a threaded Io: the rewrite spawns the platform tool.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var h = try TestHarness.init();
    defer h.deinit();
    h.io = threaded.io();
    const a = h.arena.allocator();

    const dylib = try std.fmt.allocPrint(a, "{s}/lib/libsynth.dylib", .{h.keg});
    try std.Io.Dir.cwd().createDirPath(h.io, std.fs.path.dirname(dylib).?);
    try writeSynthDylib(h.io, dylib, "/placeholder/lib/libsynth.dylib");

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"change_dylib_id","source":{"base":"prefix","path":"lib/libsynth.dylib"},
        \\  "id":"{{HOMEBREW_PREFIX}}/opt/glow/lib/libsynth.dylib"}]
    )));

    // The substantive half: the new install name is on disk and the old one
    // is gone. Reading it back through malt's own Mach-O reader means a
    // wrong LC constant or a swapped argument cannot pass.
    const want = try std.fmt.allocPrint(a, "{s}/opt/glow/lib/libsynth.dylib", .{h.prefix});
    try testing.expectEqualStrings(want, (try readDylibId(h.io, a, dylib)).?);

    // The other half: on arm64 the rewrite invalidates the signature, so the
    // step re-signs. A hand-built dylib cannot satisfy codesign's strict
    // validation, so what this pins is that the failure is reported rather
    // than swallowed — a silent one would ship an unrunnable dylib.
    if (codesign.isArm64()) {
        try testing.expectEqual(@as(usize, 1), h.flog.entries().len);
        try testing.expectEqual(fallback_log.FallbackReason.system_command_failed, h.flog.entries()[0].reason);
        try testing.expect(std.mem.indexOf(u8, h.flog.entries()[0].detail, "libsynth.dylib") != null);
    } else {
        try testing.expect(!h.flog.hasErrors());
    }
}
