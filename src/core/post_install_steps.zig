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
const fallback_log = @import("dsl/fallback_log.zig");

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
};

/// Step types this executor runs natively. Everything else routes to the
/// partial-skip envelope; doctor reads this to classify migrated formulas.
pub fn supportedStepType(step_type: []const u8) bool {
    const native = [_][]const u8{
        "mkdir_p",
        "touch",
        "write",
        "symlink",
        "link_dir",
        "link_children",
        "compile_gsettings_schemas",
        "gio_querymodules",
        "gdk_pixbuf_query_loaders",
        "gtk_update_icon_cache",
        "update_mime_database",
        "update_desktop_database",
    };
    for (native) |t| if (std.mem.eql(u8, t, step_type)) return true;
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
    }
    return true;
}

fn runStep(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const step_type = getString(obj, "type") orelse {
        logUnsupported(ctx, "step without a type");
        return false;
    };

    if (std.mem.eql(u8, step_type, "mkdir_p")) return stepMkdirP(ctx, obj);
    if (std.mem.eql(u8, step_type, "touch")) return stepTouch(ctx, obj);
    if (std.mem.eql(u8, step_type, "write")) return stepWrite(ctx, obj);
    if (std.mem.eql(u8, step_type, "symlink")) return stepSymlink(ctx, obj);
    if (std.mem.eql(u8, step_type, "link_dir")) return stepLinkDir(ctx, obj);
    if (std.mem.eql(u8, step_type, "link_children")) return stepLinkChildren(ctx, obj);
    if (std.mem.eql(u8, step_type, "compile_gsettings_schemas"))
        return runPathTool(ctx, obj, "glib", "glib-compile-schemas", &.{});
    if (std.mem.eql(u8, step_type, "gio_querymodules"))
        return runPathTool(ctx, obj, "glib", "gio-querymodules", &.{});
    if (std.mem.eql(u8, step_type, "update_mime_database"))
        return runPathTool(ctx, obj, "shared-mime-info", "update-mime-database", &.{});
    if (std.mem.eql(u8, step_type, "update_desktop_database"))
        return runPathTool(ctx, obj, "desktop-file-utils", "update-desktop-database", &.{});
    if (std.mem.eql(u8, step_type, "gdk_pixbuf_query_loaders"))
        return stepGdkPixbufQueryLoaders(ctx);
    if (std.mem.eql(u8, step_type, "gtk_update_icon_cache")) return stepGtkUpdateIconCache(ctx, obj);

    // init_data_dir spawns database initialisers (initdb/mysqld) with
    // formula-specific env contracts — routed loudly until they earn a
    // native runner. mkdir/move/move_children are defined upstream but
    // unused in homebrew-core today.
    const detail = if (getString(obj, "using")) |using|
        std.fmt.allocPrint(ctx.allocator, "{s} ({s})", .{ step_type, using }) catch step_type
    else
        step_type;
    logUnsupported(ctx, detail);
    return false;
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

fn templateValue(ctx: StepsCtx, token: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, token, "name")) return ctx.name;
    if (std.mem.eql(u8, token, "version")) return ctx.version;
    if (std.mem.eql(u8, token, "version.major")) return versionComponents(ctx.version, 1);
    if (std.mem.eql(u8, token, "version.major_minor")) return versionComponents(ctx.version, 2);
    if (std.mem.eql(u8, token, "HOMEBREW_PREFIX")) return ctx.prefix;
    return null;
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

/// Map an upstream base token onto the malt prefix. Null means "no safe
/// mapping" — `home` deliberately so (it escapes the prefix and would fail
/// confinement anyway), formula-scoped bases without a formula, and any
/// token this executor does not know.
pub fn resolveBase(ctx: StepsCtx, base: []const u8, formula_ref: ?[]const u8) ?[]const u8 {
    const a = ctx.allocator;
    if (std.mem.eql(u8, base, "homebrew_prefix")) return ctx.prefix;
    if (std.mem.eql(u8, base, "prefix")) return ctx.keg_path;
    if (std.mem.eql(u8, base, "opt_prefix"))
        return std.fmt.allocPrint(a, "{s}/opt/{s}", .{ ctx.prefix, ctx.name }) catch null;
    if (std.mem.eql(u8, base, "var"))
        return std.fmt.allocPrint(a, "{s}/var", .{ctx.prefix}) catch null;
    if (std.mem.eql(u8, base, "etc"))
        return std.fmt.allocPrint(a, "{s}/etc", .{ctx.prefix}) catch null;
    if (std.mem.eql(u8, base, "lib"))
        return std.fmt.allocPrint(a, "{s}/lib", .{ctx.prefix}) catch null;
    if (std.mem.eql(u8, base, "bin"))
        return std.fmt.allocPrint(a, "{s}/bin", .{ctx.prefix}) catch null;
    if (std.mem.eql(u8, base, "pkgetc"))
        return std.fmt.allocPrint(a, "{s}/etc/{s}", .{ ctx.prefix, ctx.name }) catch null;
    if (std.mem.eql(u8, base, "pkgshare"))
        return std.fmt.allocPrint(a, "{s}/share/{s}", .{ ctx.prefix, ctx.name }) catch null;
    if (std.mem.eql(u8, base, "opt_pkgshare"))
        return std.fmt.allocPrint(a, "{s}/opt/{s}/share/{s}", .{ ctx.prefix, ctx.name, ctx.name }) catch null;
    if (std.mem.eql(u8, base, "formula_pkgetc")) {
        const f = formula_ref orelse return null;
        return std.fmt.allocPrint(a, "{s}/etc/{s}", .{ ctx.prefix, f }) catch null;
    }
    if (std.mem.eql(u8, base, "formula_opt_prefix")) {
        const f = formula_ref orelse return null;
        return std.fmt.allocPrint(a, "{s}/opt/{s}", .{ ctx.prefix, f }) catch null;
    }
    return null;
}

/// Resolve a `{base, path, formula}` spec into an absolute path, or null
/// (already logged) when the spec is malformed or the base has no mapping.
fn resolvePathSpec(ctx: StepsCtx, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const spec = getObject(obj, key) orelse {
        logUnsupported(ctx, key);
        return null;
    };
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

/// Confinement gate shared by every write path: same predicate the DSL FS
/// builtins use, same fatal routing on refusal.
fn confined(ctx: StepsCtx, path: []const u8) bool {
    sandbox.validatePath(path, ctx.keg_path, ctx.prefix) catch {
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

fn stepSymlink(ctx: StepsCtx, obj: std.json.ObjectMap) bool {
    const target = resolvePathSpec(ctx, obj, "target") orelse return false;
    if (!confined(ctx, target)) return false;
    const source = resolvePathSpec(ctx, obj, "source") orelse return false;
    if (source.len == 0 or source[0] != '/') {
        // ponytail: relative symlink sources are unused upstream; extend
        // when a formula ships one.
        logUnsupported(ctx, "symlink with a relative source");
        return false;
    }
    mkParent(ctx, target);
    if (getFlag(obj, "force")) std.Io.Dir.cwd().deleteFile(ctx.io, target) catch {};
    std.Io.Dir.symLinkAbsolute(ctx.io, source, target, .{}) catch {};
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

    sandbox.validateArgv(argv.items, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, tool);
        return false;
    };
    const fenced = sandbox.fenceArgv(ctx.allocator, argv.items, ctx.keg_path, ctx.prefix) catch {
        logViolation(ctx, tool);
        return false;
    };

    var child = std.process.spawn(ctx.io, .{
        .argv = fenced,
        .stdout = if (ctx.suppress_child_stdout) .ignore else .inherit,
        .environ_map = env_map,
    }) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} failed to spawn", .{exe}) catch exe);
        return false;
    };
    const term = child.wait(ctx.io) catch {
        logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} did not terminate cleanly", .{exe}) catch exe);
        return false;
    };
    switch (term) {
        .exited => |code| {
            if (code == 0) return true;
            logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} exited with code {d}", .{ exe, code }) catch exe);
        },
        else => logCmdFail(ctx, std.fmt.allocPrint(ctx.allocator, "{s} terminated abnormally", .{exe}) catch exe),
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

fn uniquePrefix(io: std.Io) ![]u8 {
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const p = try std.fmt.allocPrint(testing.allocator, "/tmp/malt_steps_{s}", .{hex[0..]});
    try std.Io.Dir.cwd().createDirPath(io, p);
    return p;
}

const TestHarness = struct {
    arena: std.heap.ArenaAllocator,
    flog: FallbackLog,
    prefix: []u8,
    keg: []const u8,
    io: std.Io,

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

test "a step resolving outside the prefix is refused and logged as a sandbox violation" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"absolute","path":"/tmp/malt_steps_escape_zz"}}]
    )));
    try testing.expect(h.flog.hasFatal());
    var escaped = true;
    _ = std.Io.Dir.openDirAbsolute(h.io, "/tmp/malt_steps_escape_zz", .{}) catch {
        escaped = false;
    };
    try testing.expect(!escaped);
}

test "init_data_dir and unknown step types downgrade to the loud partial skip" {
    var h = try TestHarness.init();
    defer h.deinit();

    try testing.expect(execute(h.ctx(), try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"glow"}},
        \\ {"type":"init_data_dir","path":{"base":"var","path":"glow"},"using":"postgresql_initdb"},
        \\ {"type":"frobnicate"}]
    )));
    try testing.expect(h.flog.hasErrors());
    try testing.expect(!h.flog.hasFatal());
    try testing.expectEqual(@as(usize, 2), h.flog.entries().len);
    try testing.expectEqual(fallback_log.FallbackReason.unknown_method, h.flog.entries()[0].reason);
    // The supported step still ran and counted as handled.
    try testing.expectEqual(@as(usize, 3), h.flog.total_top_level);
    try testing.expectEqual(@as(usize, 1), h.flog.handled_top_level);
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
    try testing.expect(!allStepsSupported(a, try testFormulaJson(&h,
        \\[{"type":"mkdir_p","path":{"base":"var","path":"glow"}},
        \\ {"type":"init_data_dir","path":{"base":"var","path":"glow"},"using":"postgresql_initdb"}]
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

test "supportedStepType matches the executable tier and rejects the rest" {
    const native = [_][]const u8{
        "mkdir_p",                  "touch",                 "write",                     "symlink",
        "link_dir",                 "link_children",         "compile_gsettings_schemas", "gio_querymodules",
        "gdk_pixbuf_query_loaders", "gtk_update_icon_cache", "update_mime_database",      "update_desktop_database",
    };
    for (native) |t| try testing.expect(supportedStepType(t));
    const routed = [_][]const u8{ "init_data_dir", "mkdir", "move", "move_children", "frobnicate" };
    for (routed) |t| try testing.expect(!supportedStepType(t));
}
