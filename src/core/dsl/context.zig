//! malt — DSL execution context
//! Holds the runtime state (scopes, path bindings, method table, fallback
//! log) the tree-walker operates against. Split out of `interpreter.zig`
//! so the DSL is free of the formula domain — callers hand in a narrow
//! `FormulaRef` projection.

const std = @import("std");
const ast = @import("ast.zig");
const values = @import("values.zig");
const fallback_log = @import("fallback_log.zig");

const Value = values.Value;
const FallbackLog = fallback_log.FallbackLog;

pub const DslError = error{
    ParseError,
    UnknownMethod,
    UnsupportedNode,
    PathSandboxViolation,
    PostInstallFailed,
    SystemCommandFailed,
    OutOfMemory,
    /// Control-flow signal raised by `return`. Callers that bound the
    /// unwind (a def call frame, the post_install top-level) catch it;
    /// block iterators propagate it so `return` inside `.each` exits the
    /// enclosing method instead of the iteration.
    ReturnSignal,
};

/// Scopes are arena-backed — no deinit; the post_install arena frees locals.
pub const Scope = struct {
    locals: std.StringHashMap(Value),
    /// Marks a def-call frame. Binding lookup stops here so a called
    /// method cannot see the caller's locals — matches Ruby's lexical
    /// scoping for `def`.
    is_method_frame: bool = false,

    pub fn init(arena: std.mem.Allocator) Scope {
        return .{ .locals = std.StringHashMap(Value).init(arena) };
    }
};

/// Formula path binding slots. Storage order mirrors EnumArray indexing;
/// `binding_map` translates DSL identifiers to these tags.
pub const PathBinding = enum {
    prefix,
    bin,
    sbin,
    lib,
    libexec,
    include,
    share,
    pkgshare,
    etc,
    pkgetc,
    var_dir,
    opt_prefix,
    homebrew_prefix,
    homebrew_cellar,
};

const binding_map = std.StaticStringMap(PathBinding).initComptime(.{
    .{ "prefix", PathBinding.prefix },
    .{ "bin", PathBinding.bin },
    .{ "sbin", PathBinding.sbin },
    .{ "lib", PathBinding.lib },
    .{ "libexec", PathBinding.libexec },
    .{ "include", PathBinding.include },
    .{ "share", PathBinding.share },
    .{ "pkgshare", PathBinding.pkgshare },
    .{ "etc", PathBinding.etc },
    .{ "pkgetc", PathBinding.pkgetc },
    .{ "var", PathBinding.var_dir },
    .{ "opt_prefix", PathBinding.opt_prefix },
    .{ "HOMEBREW_PREFIX", PathBinding.homebrew_prefix },
    .{ "HOMEBREW_CELLAR", PathBinding.homebrew_cellar },
});

/// Narrow projection; keeps DSL free of formula types.
pub const FormulaRef = struct {
    name: []const u8,
    version: []const u8,
    pkg_version: []const u8,
};

pub const ExecContext = struct {
    /// Caller-owned arena. Owns every path string, scope map, and the
    /// methods table; deinit is a no-op because the caller tears it down.
    arena: std.mem.Allocator,

    /// Cellar path for the current formula — also stored in `paths[.prefix]`,
    /// kept as a direct field so builtins (sandbox validation) can read it
    /// without a lookup.
    cellar_path: []const u8,
    malt_prefix: []const u8,

    /// All formula path bindings, indexed by `PathBinding`.
    paths: std.EnumArray(PathBinding, []const u8),

    /// Local-variable scope stack for nested blocks. Mutated by
    /// `pushScope`/`popScope`/`setLocal`; do not touch from builtins.
    _scopes: std.ArrayList(Scope),

    // Sandbox root for path validation
    sandbox_root: []const u8,

    // Fallback log writer
    fallback_log_writer: *FallbackLog,

    // Formula name for fallback log entries
    formula_name: []const u8,

    /// User-defined methods from `def ... end`. Entries borrow the parser
    /// arena; the map itself lives on `arena`.
    methods: std.StringHashMap(ast.MethodDef),

    // Value threaded through a `return` statement. The call-frame (or
    // top-level executor) reads + resets this when it catches ReturnSignal.
    return_value: Value,

    pub fn init(
        arena: std.mem.Allocator,
        ref: FormulaRef,
        malt_prefix: []const u8,
        flog: *FallbackLog,
    ) DslError!ExecContext {
        const cellar_path = std.fmt.allocPrint(arena, "{s}/Cellar/{s}/{s}", .{
            malt_prefix, ref.name, ref.version,
        }) catch malt_prefix;

        var paths = std.EnumArray(PathBinding, []const u8).initUndefined();
        paths.set(.prefix, cellar_path);
        paths.set(.bin, joinPath(arena, cellar_path, "bin"));
        paths.set(.sbin, joinPath(arena, cellar_path, "sbin"));
        paths.set(.lib, joinPath(arena, cellar_path, "lib"));
        paths.set(.libexec, joinPath(arena, cellar_path, "libexec"));
        paths.set(.include, joinPath(arena, cellar_path, "include"));
        paths.set(.share, joinPath(arena, cellar_path, "share"));
        paths.set(.pkgshare, std.fmt.allocPrint(arena, "{s}/share/{s}", .{ cellar_path, ref.name }) catch cellar_path);
        paths.set(.etc, joinPath(arena, malt_prefix, "etc"));
        // pkgetc: bare identifier in homebrew core (gnutls, openssl@3 …).
        paths.set(.pkgetc, std.fmt.allocPrint(arena, "{s}/etc/{s}", .{ malt_prefix, ref.name }) catch malt_prefix);
        paths.set(.var_dir, joinPath(arena, malt_prefix, "var"));
        paths.set(.opt_prefix, std.fmt.allocPrint(arena, "{s}/opt/{s}", .{ malt_prefix, ref.name }) catch malt_prefix);
        paths.set(.homebrew_prefix, malt_prefix);
        paths.set(.homebrew_cellar, joinPath(arena, malt_prefix, "Cellar"));

        var ctx = ExecContext{
            .arena = arena,
            .cellar_path = cellar_path,
            .malt_prefix = malt_prefix,
            .paths = paths,
            ._scopes = .empty,
            .sandbox_root = malt_prefix,
            .fallback_log_writer = flog,
            .formula_name = ref.name,
            .methods = std.StringHashMap(ast.MethodDef).init(arena),
            .return_value = Value{ .nil = {} },
        };

        // OOM here would leave callers with a zero-depth stack; surface it.
        try ctx.pushScope();
        return ctx;
    }

    /// Arena owns every allocation — caller tears it down. No per-field free.
    pub fn deinit(_: *ExecContext) void {}

    pub fn resolveBinding(self: *ExecContext, name: []const u8) ?Value {
        // Check local scopes (innermost first). Stop at the first
        // is_method_frame scope so a def doesn't leak through caller
        // locals (Ruby lexical-scope behaviour for `def`).
        var i = self._scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self._scopes.items[i];
            if (scope.locals.get(name)) |val| {
                return val;
            }
            if (scope.is_method_frame) break;
        }

        if (binding_map.get(name)) |tag| {
            return Value{ .pathname = self.paths.get(tag) };
        }
        return null;
    }

    // OOM on a scope push must not be swallowed: a silent drop leaves the
    // matching popScope tearing down the caller's scope, so outer locals
    // vanish and subsequent lookups return stale/nil under memory pressure.
    pub fn pushScope(self: *ExecContext) DslError!void {
        self._scopes.append(self.arena, Scope.init(self.arena)) catch return DslError.OutOfMemory;
    }

    pub fn pushMethodScope(self: *ExecContext) DslError!void {
        self._scopes.append(self.arena, .{
            .locals = std.StringHashMap(Value).init(self.arena),
            .is_method_frame = true,
        }) catch return DslError.OutOfMemory;
    }

    pub fn popScope(self: *ExecContext) void {
        // Arena owns the scope's locals — dropping the stack slot is enough.
        _ = self._scopes.pop();
    }

    pub fn setLocal(self: *ExecContext, name: []const u8, value: Value) DslError!void {
        if (self._scopes.items.len == 0) return;
        self._scopes.items[self._scopes.items.len - 1].locals.put(name, value) catch return DslError.OutOfMemory;
    }

    /// Current scope-stack depth. Tests use this to pin push/pop invariants.
    pub fn scopeDepth(self: *const ExecContext) usize {
        return self._scopes.items.len;
    }
};

pub fn joinPath(allocator: std.mem.Allocator, base: []const u8, sub: []const u8) []const u8 {
    return std.fs.path.join(allocator, &.{ base, sub }) catch base;
}
