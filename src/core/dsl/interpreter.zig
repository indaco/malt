//! malt — DSL interpreter
//! Tree-walking evaluator with ExecContext for formula path bindings.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");
const ast = @import("ast.zig");
const values = @import("values.zig");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const sandbox = @import("sandbox.zig");
const fallback_log = @import("fallback_log.zig");
const builtins_root = @import("builtins/root.zig");
const formula_mod = @import("../formula.zig");

const Node = ast.Node;
const SourceLoc = ast.SourceLoc;
const Value = values.Value;
const FallbackLog = fallback_log.FallbackLog;
const FallbackEntry = fallback_log.FallbackEntry;
const FallbackReason = fallback_log.FallbackReason;
const Formula = formula_mod.Formula;

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

    // Local variable scope (stack for nested blocks)
    scopes: std.ArrayList(Scope),

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
        formula: *const Formula,
        malt_prefix: []const u8,
        flog: *FallbackLog,
    ) ExecContext {
        const cellar_path = std.fmt.allocPrint(arena, "{s}/Cellar/{s}/{s}", .{
            malt_prefix, formula.name, formula.version,
        }) catch malt_prefix;

        var paths = std.EnumArray(PathBinding, []const u8).initUndefined();
        paths.set(.prefix, cellar_path);
        paths.set(.bin, joinPath(arena, cellar_path, "bin"));
        paths.set(.sbin, joinPath(arena, cellar_path, "sbin"));
        paths.set(.lib, joinPath(arena, cellar_path, "lib"));
        paths.set(.libexec, joinPath(arena, cellar_path, "libexec"));
        paths.set(.include, joinPath(arena, cellar_path, "include"));
        paths.set(.share, joinPath(arena, cellar_path, "share"));
        paths.set(.pkgshare, std.fmt.allocPrint(arena, "{s}/share/{s}", .{ cellar_path, formula.name }) catch cellar_path);
        paths.set(.etc, joinPath(arena, malt_prefix, "etc"));
        // pkgetc: bare identifier in homebrew core (gnutls, openssl@3 …).
        paths.set(.pkgetc, std.fmt.allocPrint(arena, "{s}/etc/{s}", .{ malt_prefix, formula.name }) catch malt_prefix);
        paths.set(.var_dir, joinPath(arena, malt_prefix, "var"));
        paths.set(.opt_prefix, std.fmt.allocPrint(arena, "{s}/opt/{s}", .{ malt_prefix, formula.name }) catch malt_prefix);
        paths.set(.homebrew_prefix, malt_prefix);
        paths.set(.homebrew_cellar, joinPath(arena, malt_prefix, "Cellar"));

        var ctx = ExecContext{
            .arena = arena,
            .cellar_path = cellar_path,
            .malt_prefix = malt_prefix,
            .paths = paths,
            .scopes = .empty,
            .sandbox_root = malt_prefix,
            .fallback_log_writer = flog,
            .formula_name = formula.name,
            .methods = std.StringHashMap(ast.MethodDef).init(arena),
            .return_value = Value{ .nil = {} },
        };

        // Push initial scope
        ctx.pushScope();
        return ctx;
    }

    /// Arena owns every allocation — caller tears it down. No per-field free.
    pub fn deinit(_: *ExecContext) void {}

    pub fn resolveBinding(self: *ExecContext, name: []const u8) ?Value {
        // Check local scopes (innermost first). Stop at the first
        // is_method_frame scope so a def doesn't leak through caller
        // locals (Ruby lexical-scope behaviour for `def`).
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
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

    pub fn pushScope(self: *ExecContext) void {
        self.scopes.append(self.arena, Scope.init(self.arena)) catch {};
    }

    pub fn pushMethodScope(self: *ExecContext) void {
        self.scopes.append(self.arena, .{
            .locals = std.StringHashMap(Value).init(self.arena),
            .is_method_frame = true,
        }) catch {};
    }

    pub fn popScope(self: *ExecContext) void {
        // Arena owns the scope's locals — dropping the stack slot is enough.
        _ = self.scopes.pop();
    }

    pub fn setLocal(self: *ExecContext, name: []const u8, value: Value) void {
        if (self.scopes.items.len > 0) {
            self.scopes.items[self.scopes.items.len - 1].locals.put(name, value) catch {};
        }
    }
};

pub const Interpreter = struct {
    ctx: *ExecContext,
    /// Mirror of `ctx.arena` — held for brevity in hot eval paths.
    allocator: std.mem.Allocator,

    pub fn init(ctx: *ExecContext) Interpreter {
        return .{
            .ctx = ctx,
            .allocator = ctx.arena,
        };
    }

    pub fn execute(self: *Interpreter, nodes: []const *const Node) DslError!void {
        for (nodes) |node| {
            _ = self.eval(node) catch |e| switch (e) {
                DslError.PostInstallFailed => return e,
                DslError.PathSandboxViolation => {
                    self.ctx.fallback_log_writer.log(.{
                        .formula = self.ctx.formula_name,
                        .reason = .sandbox_violation,
                        .detail = "path sandbox violation during execution",
                        .loc = node.loc,
                    });
                    return e;
                },
                // Top-level `return` exits the post_install body cleanly.
                // Formulas use `return if <guard>` to short-circuit; the
                // value is discarded because there's no caller.
                DslError.ReturnSignal => {
                    self.ctx.return_value = Value{ .nil = {} };
                    return;
                },
                DslError.UnknownMethod => continue, // Non-fatal
                DslError.UnsupportedNode => continue, // Non-fatal
                else => continue,
            };
        }
    }

    fn eval(self: *Interpreter, node: *const Node) DslError!Value {
        return switch (node.kind) {
            .string_literal => |sl| self.evalStringLiteral(&sl),
            .int_literal => |i| Value{ .int = i },
            .float_literal => |f| Value{ .float = f },
            .bool_literal => |b| Value{ .bool = b },
            .nil_literal => Value{ .nil = {} },
            .symbol_literal => |s| Value{ .symbol = s },
            .heredoc_literal => |h| Value{ .string = h },
            .identifier => |name| self.evalIdentifier(name, node.loc),
            .assignment => |a| self.evalAssignment(&a),
            .method_call => |mc| self.evalMethodCall(&mc, node.loc),
            .path_join => |pj| self.evalPathJoin(&pj),
            .array_literal => |elems| self.evalArray(elems),
            .hash_literal => |entries| self.evalHash(entries),
            .block => |stmts| self.evalBlock(stmts),
            .postfix_if => |pf| self.evalPostfixIf(&pf),
            .postfix_unless => |pu| self.evalPostfixUnless(&pu),
            .if_else => |ie| self.evalIfElse(&ie),
            .unless_statement => |us| self.evalUnless(&us),
            .each_loop => |el| self.evalEachLoop(&el),
            .begin_rescue => |br| self.evalBeginRescue(&br),
            .raise_statement => |rs| self.evalRaise(&rs),
            .logical_and => |la| self.evalLogicalAnd(&la),
            .logical_or => |lo| self.evalLogicalOr(&lo),
            .logical_not => |operand| self.evalLogicalNot(operand),
            .interpolation => Value{ .nil = {} },
            .method_def => |md| self.evalMethodDef(&md),
            .return_statement => |rs| self.evalReturn(&rs),
        };
    }

    /// Register a user method into the ExecContext's method table. The body
    /// and params borrow the parser arena's allocation.
    fn evalMethodDef(self: *Interpreter, md: *const ast.MethodDef) DslError!Value {
        self.ctx.methods.put(md.name, md.*) catch return DslError.OutOfMemory;
        return Value{ .nil = {} };
    }

    /// Evaluate the optional return value, stash it on the context, and
    /// raise ReturnSignal so the nearest call frame (or top-level) unwinds.
    fn evalReturn(self: *Interpreter, rs: *const ast.ReturnStatement) DslError!Value {
        self.ctx.return_value = if (rs.value) |v| try self.eval(v) else Value{ .nil = {} };
        return DslError.ReturnSignal;
    }

    /// Invoke a user-defined method. Pushes a method-frame scope, binds
    /// positional params, runs the body, and catches a ReturnSignal so
    /// `return` unwinds the call but not the outer block. Missing args
    /// are bound to nil, extras are dropped — same policy as lenient
    /// Ruby method dispatch for the formulas we care about.
    fn invokeUserMethod(
        self: *Interpreter,
        md: ast.MethodDef,
        args: []const Value,
    ) DslError!Value {
        self.ctx.pushMethodScope();
        defer self.ctx.popScope();

        for (md.params, 0..) |pname, i| {
            const v = if (i < args.len) args[i] else Value{ .nil = {} };
            self.ctx.setLocal(pname, v);
        }

        // Ruby implicit-return: the last expression's value is the method's
        // return value unless an explicit `return` unwinds earlier. Non-fatal
        // diagnostics (unknown_method, unsupported_node) keep going so a
        // helper doesn't abort on a single unrecognised construct.
        var last: Value = Value{ .nil = {} };
        for (md.body) |stmt| {
            last = self.eval(stmt) catch |e| switch (e) {
                DslError.ReturnSignal => {
                    const v = self.ctx.return_value;
                    self.ctx.return_value = Value{ .nil = {} };
                    return v;
                },
                DslError.UnknownMethod, DslError.UnsupportedNode => continue,
                else => return e,
            };
        }
        return last;
    }

    fn evalStringLiteral(self: *Interpreter, sl: *const ast.StringLiteral) DslError!Value {
        if (sl.parts.len == 1) {
            switch (sl.parts[0]) {
                .literal => |lit| return Value{ .string = lit },
                .interpolation => |interp_node| {
                    const val = try self.eval(interp_node);
                    return Value{ .string = val.asString(self.allocator) catch return DslError.OutOfMemory };
                },
            }
        }

        // Multiple parts — concatenate
        var buf: std.ArrayList(u8) = .empty;
        for (sl.parts) |part| {
            switch (part) {
                .literal => |lit| buf.appendSlice(self.allocator, lit) catch return DslError.OutOfMemory,
                .interpolation => |interp_node| {
                    const val = try self.eval(interp_node);
                    const s = val.asString(self.allocator) catch return DslError.OutOfMemory;
                    buf.appendSlice(self.allocator, s) catch return DslError.OutOfMemory;
                },
            }
        }
        const result = buf.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .string = result };
    }

    fn evalIdentifier(self: *Interpreter, name: []const u8, loc: SourceLoc) DslError!Value {
        if (self.ctx.resolveBinding(name)) |val| return val;

        // Bare name resolves to a zero-arg user method call — Ruby treats
        // `foo` and `foo()` identically, and chain expressions like
        // `clang_config_file_dir.mkpath` parse as identifier + tail.
        if (self.ctx.methods.get(name)) |md| {
            return self.invokeUserMethod(md, &.{});
        }

        // Unknown identifier — log as non-fatal
        self.ctx.fallback_log_writer.log(.{
            .formula = self.ctx.formula_name,
            .reason = .unknown_method,
            .detail = name,
            .loc = loc,
        });
        return Value{ .nil = {} };
    }

    fn evalAssignment(self: *Interpreter, a: *const ast.Assignment) DslError!Value {
        const val = try self.eval(a.value);
        self.ctx.setLocal(a.name, val);
        return val;
    }

    fn evalMethodCall(self: *Interpreter, mc: *const ast.MethodCall, loc: SourceLoc) DslError!Value {
        // Evaluate arguments
        var eval_args: std.ArrayList(Value) = .empty;
        for (mc.args) |arg| {
            const val = try self.eval(arg);
            eval_args.append(self.allocator, val) catch return DslError.OutOfMemory;
        }
        const args_slice = eval_args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;

        const builtin_ctx = builtins_root.pathname.ExecCtx{
            .allocator = self.allocator,
            .cellar_path = self.ctx.cellar_path,
            .malt_prefix = self.ctx.malt_prefix,
        };

        if (mc.receiver) |receiver_node| {
            // Check for class method patterns: File.exist?, Dir.glob, Pathname.new
            if (receiver_node.kind == .identifier) {
                const class_name = receiver_node.kind.identifier;
                // 256 bytes accommodates every builtin key currently registered
                // (longest is a handful of chars). If an identifier is longer
                // than the buffer we simply skip class-dispatch rather than
                // silently falling back to `mc.method` and looking up the
                // wrong builtin — that used to shadow dispatch for any Ruby
                // identifier > ~30 chars.
                var compound_buf: [256]u8 = undefined;
                if (std.fmt.bufPrint(&compound_buf, "{s}.{s}", .{ class_name, mc.method })) |compound| {
                    if (builtins_root.bare_builtins.get(compound)) |func| {
                        return func(builtin_ctx, null, args_slice) catch |e| {
                            return mapBuiltinError(e);
                        };
                    }
                } else |_| {}
            }

            // Check for nested class::module patterns: Hardware::CPU.arch, OS.mac?
            // When receiver is itself a method_call (from :: chain), build compound key
            if (receiver_node.kind == .method_call) {
                const recv_mc = receiver_node.kind.method_call;
                if (recv_mc.receiver) |inner_recv| {
                    if (inner_recv.kind == .identifier) {
                        var compound_buf: [256]u8 = undefined;
                        if (std.fmt.bufPrint(&compound_buf, "{s}::{s}.{s}", .{
                            inner_recv.kind.identifier, recv_mc.method, mc.method,
                        })) |compound| {
                            if (builtins_root.bare_builtins.get(compound)) |func| {
                                return func(builtin_ctx, null, args_slice) catch |e| {
                                    return mapBuiltinError(e);
                                };
                            }
                        } else |_| {}
                    }
                }
            }

            // Receiver-based call
            const receiver_val = try self.eval(receiver_node);

            // Binary comparison operators: lowered by the parser to a
            // method_call with method = "<", ">", "<=", ">=", "==", "!=".
            // Handle upfront so subsequent `receiver_val == .array` checks
            // don't see a single-arg comparison as an Enumerable method.
            if (mc.blk == null and mc.block_pass == null and args_slice.len == 1 and isComparisonOp(mc.method)) {
                return Value{ .bool = compare(receiver_val, mc.method, args_slice[0]) };
            }

            // Handle .select { |x| ... } and .map { |x| ... } on arrays
            if (receiver_val == .array and mc.blk != null) {
                if (std.mem.eql(u8, mc.method, "select")) {
                    return self.evalArraySelect(receiver_val.array, mc.block_params, mc.blk.?);
                } else if (std.mem.eql(u8, mc.method, "map")) {
                    return self.evalArrayMap(receiver_val.array, mc.block_params, mc.blk.?);
                } else if (std.mem.eql(u8, mc.method, "reject")) {
                    return self.evalArrayReject(receiver_val.array, mc.block_params, mc.blk.?);
                } else if (std.mem.eql(u8, mc.method, "each")) {
                    return self.evalArrayEach(receiver_val.array, mc.block_params, mc.blk.?);
                }
            }

            // Enumerable methods on hash receivers — same shape as arrays
            // but the block is yielded (key, value) pairs. Covers llvm@21's
            // `{ darwin: ..., macosx: ... }.map do |system, version| ... end`.
            if (receiver_val == .hash and mc.blk != null) {
                if (std.mem.eql(u8, mc.method, "map")) {
                    return self.evalHashMap(receiver_val.hash, mc.block_params, mc.blk.?);
                } else if (std.mem.eql(u8, mc.method, "each")) {
                    return self.evalHashEach(receiver_val.hash, mc.block_params, mc.blk.?);
                } else if (std.mem.eql(u8, mc.method, "select")) {
                    return self.evalHashSelect(receiver_val.hash, mc.block_params, mc.blk.?);
                } else if (std.mem.eql(u8, mc.method, "reject")) {
                    return self.evalHashReject(receiver_val.hash, mc.block_params, mc.blk.?);
                }
            }

            // `&:sym` block-pass on the common Enumerable methods. The symbol
            // names a receiver builtin invoked per element — same effect as
            // `{ |x| x.sym }` without the block allocation.
            if (receiver_val == .array and mc.block_pass != null) {
                const bp_val = try self.eval(mc.block_pass.?);
                if (bp_val == .symbol) {
                    return self.dispatchBlockPassSym(mc.method, receiver_val.array, bp_val.symbol, loc);
                }
                self.ctx.fallback_log_writer.log(.{
                    .formula = self.ctx.formula_name,
                    .reason = .unsupported_node,
                    .detail = "block_pass with non-symbol expression",
                    .loc = loc,
                });
            }

            // Block-less `all?` / `any?` — Ruby semantics: truthiness of each element.
            if (receiver_val == .array and mc.blk == null and mc.block_pass == null) {
                if (std.mem.eql(u8, mc.method, "all?")) {
                    for (receiver_val.array) |it| if (!it.isTruthy()) return Value{ .bool = false };
                    return Value{ .bool = true };
                } else if (std.mem.eql(u8, mc.method, "any?")) {
                    for (receiver_val.array) |it| if (it.isTruthy()) return Value{ .bool = true };
                    return Value{ .bool = false };
                } else if (std.mem.eql(u8, mc.method, "<<") and args_slice.len == 1) {
                    // `arr << x` — return a fresh array with x appended.
                    // Ruby mutates in place; Values here are immutable so
                    // callers wanting mutation semantics reassign
                    // (`arr = arr << x`). Both shapes parse cleanly.
                    const out = self.allocator.alloc(Value, receiver_val.array.len + 1) catch return DslError.OutOfMemory;
                    @memcpy(out[0..receiver_val.array.len], receiver_val.array);
                    out[receiver_val.array.len] = args_slice[0];
                    return Value{ .array = out };
                }
            }

            // `hash.any?` / `hash.all?` without a block. Ruby's default is
            // non-empty / empty check for `any?` and "every value truthy"
            // for `all?` (treating pairs as `[k, v]` truthy-by-default, so
            // `all?` reduces to "no entries are nil/false values").
            if (receiver_val == .hash and mc.blk == null and mc.block_pass == null) {
                if (std.mem.eql(u8, mc.method, "any?")) {
                    return Value{ .bool = receiver_val.hash.len > 0 };
                } else if (std.mem.eql(u8, mc.method, "all?")) {
                    for (receiver_val.hash) |pair| if (!pair.value.isTruthy()) return Value{ .bool = false };
                    return Value{ .bool = true };
                } else if (std.mem.eql(u8, mc.method, "empty?")) {
                    return Value{ .bool = receiver_val.hash.len == 0 };
                } else if (std.mem.eql(u8, mc.method, "length") or std.mem.eql(u8, mc.method, "size")) {
                    return Value{ .int = @as(i64, @intCast(receiver_val.hash.len)) };
                }
            }

            // Look up in receiver builtins
            if (builtins_root.receiver_builtins.get(mc.method)) |func| {
                return func(builtin_ctx, receiver_val, args_slice) catch |e| {
                    return mapBuiltinError(e);
                };
            }

            // Unknown receiver method — log
            self.ctx.fallback_log_writer.log(.{
                .formula = self.ctx.formula_name,
                .reason = .unknown_method,
                .detail = mc.method,
                .loc = loc,
            });
            return Value{ .nil = {} };
        } else {
            // Bare call
            if (builtins_root.bare_builtins.get(mc.method)) |func| {
                return func(builtin_ctx, null, args_slice) catch |e| {
                    return mapBuiltinError(e);
                };
            }

            // User-defined method (from a `def ... end` earlier in this
            // post_install body). Invocation handles its own scope + return.
            if (self.ctx.methods.get(mc.method)) |md| {
                return self.invokeUserMethod(md, args_slice);
            }

            // Check if it's a binding used as a method
            if (self.ctx.resolveBinding(mc.method)) |val| {
                return val;
            }

            // Unknown bare method — log
            self.ctx.fallback_log_writer.log(.{
                .formula = self.ctx.formula_name,
                .reason = .unknown_method,
                .detail = mc.method,
                .loc = loc,
            });
            return Value{ .nil = {} };
        }
    }

    fn evalPathJoin(self: *Interpreter, pj: *const ast.PathJoin) DslError!Value {
        const left_val = try self.eval(pj.left);
        const right_val = try self.eval(pj.right);

        const left_str = left_val.asString(self.allocator) catch return DslError.OutOfMemory;
        const right_str = right_val.asString(self.allocator) catch return DslError.OutOfMemory;

        const joined = std.fs.path.join(self.allocator, &.{ left_str, right_str }) catch return DslError.OutOfMemory;
        return Value{ .pathname = joined };
    }

    fn evalArray(self: *Interpreter, elems: []const *const Node) DslError!Value {
        var arr: std.ArrayList(Value) = .empty;
        for (elems) |elem| {
            const val = try self.eval(elem);
            arr.append(self.allocator, val) catch return DslError.OutOfMemory;
        }
        const slice = arr.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .array = slice };
    }

    fn evalHash(self: *Interpreter, entries: []const ast.HashEntry) DslError!Value {
        var pairs: std.ArrayList(Value.HashPair) = .empty;
        for (entries) |entry| {
            const key = try self.eval(entry.key);
            const val = try self.eval(entry.value);
            pairs.append(self.allocator, .{ .key = key, .value = val }) catch return DslError.OutOfMemory;
        }
        const slice = pairs.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .hash = slice };
    }

    fn evalBlock(self: *Interpreter, stmts: []const *const Node) DslError!Value {
        var last: Value = Value{ .nil = {} };
        for (stmts) |stmt| {
            last = try self.eval(stmt);
        }
        return last;
    }

    fn evalPostfixIf(self: *Interpreter, pf: *const ast.PostfixIf) DslError!Value {
        const cond = try self.eval(pf.condition);
        if (cond.isTruthy()) {
            return self.eval(pf.body);
        }
        return Value{ .nil = {} };
    }

    fn evalPostfixUnless(self: *Interpreter, pu: *const ast.PostfixUnless) DslError!Value {
        const cond = try self.eval(pu.condition);
        if (!cond.isTruthy()) {
            return self.eval(pu.body);
        }
        return Value{ .nil = {} };
    }

    fn evalIfElse(self: *Interpreter, ie: *const ast.IfElse) DslError!Value {
        const cond = try self.eval(ie.condition);
        if (cond.isTruthy()) {
            return self.evalBlockSlice(ie.then_body);
        }
        for (ie.elsif_branches) |branch| {
            const branch_cond = try self.eval(branch.condition);
            if (branch_cond.isTruthy()) {
                return self.evalBlockSlice(branch.body);
            }
        }
        if (ie.else_body) |else_body| {
            return self.evalBlockSlice(else_body);
        }
        return Value{ .nil = {} };
    }

    fn evalUnless(self: *Interpreter, us: *const ast.UnlessStatement) DslError!Value {
        const cond = try self.eval(us.condition);
        if (!cond.isTruthy()) {
            return self.evalBlockSlice(us.body);
        }
        if (us.else_body) |else_body| {
            return self.evalBlockSlice(else_body);
        }
        return Value{ .nil = {} };
    }

    fn evalEachLoop(self: *Interpreter, el: *const ast.EachLoop) DslError!Value {
        const iterable = try self.eval(el.iterable);
        switch (iterable) {
            .array => |items| for (items) |item| {
                self.ctx.pushScope();
                defer self.ctx.popScope();
                if (el.params.len > 0) self.ctx.setLocal(el.params[0], item);
                _ = self.evalBlockSlice(el.body) catch |e| switch (e) {
                    DslError.PostInstallFailed, DslError.PathSandboxViolation, DslError.ReturnSignal => return e,
                    else => continue,
                };
            },
            .hash => |pairs| for (pairs) |pair| {
                // Hash iteration yields (key, value) — matches Ruby's
                // `hash.each do |k, v|` and the llvm@21 post_install shape.
                self.ctx.pushScope();
                defer self.ctx.popScope();
                self.bindHashPair(el.params, pair);
                _ = self.evalBlockSlice(el.body) catch |e| switch (e) {
                    DslError.PostInstallFailed, DslError.PathSandboxViolation, DslError.ReturnSignal => return e,
                    else => continue,
                };
            },
            else => return Value{ .nil = {} },
        }
        return Value{ .nil = {} };
    }

    fn evalBeginRescue(self: *Interpreter, br: *const ast.BeginRescue) DslError!Value {
        _ = self.evalBlockSlice(br.body) catch |e| switch (e) {
            // Sandbox violations are unrecoverable; `return` must unwind
            // past the rescue because Ruby's `rescue` does not catch
            // control-flow signals.
            DslError.PathSandboxViolation, DslError.ReturnSignal => return e,
            else => {
                // Execute rescue body — catches PostInstallFailed (raise), SystemCommandFailed, etc.
                return self.evalBlockSlice(br.rescue_body) catch Value{ .nil = {} };
            },
        };
        return Value{ .nil = {} };
    }

    fn evalRaise(self: *Interpreter, rs: *const ast.RaiseStatement) DslError!Value {
        if (rs.message) |msg_node| {
            const msg = try self.eval(msg_node);
            const msg_str = msg.asString(self.allocator) catch "raise";
            const f = fs_compat.stderrFile();
            f.writeAll("  x ") catch {};
            f.writeAll(msg_str) catch {};
            f.writeAll("\n") catch {};
        }
        return DslError.PostInstallFailed;
    }

    fn evalArraySelect(self: *Interpreter, items: []const Value, params: []const []const u8, blk: *const Node) DslError!Value {
        var result: std.ArrayList(Value) = .empty;
        for (items) |item| {
            self.ctx.pushScope();
            defer self.ctx.popScope();
            if (params.len > 0) self.ctx.setLocal(params[0], item);
            const val = try self.eval(blk);
            if (val.isTruthy()) {
                result.append(self.allocator, item) catch return DslError.OutOfMemory;
            }
        }
        const slice = result.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .array = slice };
    }

    fn evalArrayMap(self: *Interpreter, items: []const Value, params: []const []const u8, blk: *const Node) DslError!Value {
        var result: std.ArrayList(Value) = .empty;
        for (items) |item| {
            self.ctx.pushScope();
            defer self.ctx.popScope();
            if (params.len > 0) self.ctx.setLocal(params[0], item);
            const val = try self.eval(blk);
            result.append(self.allocator, val) catch return DslError.OutOfMemory;
        }
        const slice = result.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .array = slice };
    }

    fn evalArrayReject(self: *Interpreter, items: []const Value, params: []const []const u8, blk: *const Node) DslError!Value {
        var result: std.ArrayList(Value) = .empty;
        for (items) |item| {
            self.ctx.pushScope();
            defer self.ctx.popScope();
            if (params.len > 0) self.ctx.setLocal(params[0], item);
            const val = try self.eval(blk);
            if (!val.isTruthy()) {
                result.append(self.allocator, item) catch return DslError.OutOfMemory;
            }
        }
        const slice = result.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .array = slice };
    }

    fn evalArrayEach(self: *Interpreter, items: []const Value, params: []const []const u8, blk: *const Node) DslError!Value {
        for (items) |item| {
            self.ctx.pushScope();
            defer self.ctx.popScope();
            if (params.len > 0) self.ctx.setLocal(params[0], item);
            _ = self.eval(blk) catch |e| switch (e) {
                DslError.PostInstallFailed, DslError.PathSandboxViolation, DslError.ReturnSignal => return e,
                else => continue,
            };
        }
        return Value{ .nil = {} };
    }

    /// Bind a hash pair into the current scope for block evaluation. Two
    /// positional params → classic `|k, v|`; one param → the pair is
    /// bound to it (same shape as Ruby's `|kv|` destructuring). Zero
    /// params is legal but useless — nothing to reference.
    fn bindHashPair(self: *Interpreter, params: []const []const u8, pair: Value.HashPair) void {
        if (params.len == 0) return;
        if (params.len == 1) {
            const arr = self.allocator.alloc(Value, 2) catch return;
            arr[0] = pair.key;
            arr[1] = pair.value;
            self.ctx.setLocal(params[0], Value{ .array = arr });
            return;
        }
        self.ctx.setLocal(params[0], pair.key);
        self.ctx.setLocal(params[1], pair.value);
    }

    fn evalHashEach(self: *Interpreter, pairs: []const Value.HashPair, params: []const []const u8, blk: *const Node) DslError!Value {
        for (pairs) |pair| {
            self.ctx.pushScope();
            defer self.ctx.popScope();
            self.bindHashPair(params, pair);
            _ = self.eval(blk) catch |e| switch (e) {
                DslError.PostInstallFailed, DslError.PathSandboxViolation, DslError.ReturnSignal => return e,
                else => continue,
            };
        }
        return Value{ .nil = {} };
    }

    fn evalHashMap(self: *Interpreter, pairs: []const Value.HashPair, params: []const []const u8, blk: *const Node) DslError!Value {
        var out: std.ArrayList(Value) = .empty;
        for (pairs) |pair| {
            self.ctx.pushScope();
            defer self.ctx.popScope();
            self.bindHashPair(params, pair);
            const v = try self.eval(blk);
            out.append(self.allocator, v) catch return DslError.OutOfMemory;
        }
        const slice = out.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .array = slice };
    }

    fn evalHashSelect(self: *Interpreter, pairs: []const Value.HashPair, params: []const []const u8, blk: *const Node) DslError!Value {
        var out: std.ArrayList(Value.HashPair) = .empty;
        for (pairs) |pair| {
            self.ctx.pushScope();
            defer self.ctx.popScope();
            self.bindHashPair(params, pair);
            const v = try self.eval(blk);
            if (v.isTruthy()) out.append(self.allocator, pair) catch return DslError.OutOfMemory;
        }
        const slice = out.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .hash = slice };
    }

    fn evalHashReject(self: *Interpreter, pairs: []const Value.HashPair, params: []const []const u8, blk: *const Node) DslError!Value {
        var out: std.ArrayList(Value.HashPair) = .empty;
        for (pairs) |pair| {
            self.ctx.pushScope();
            defer self.ctx.popScope();
            self.bindHashPair(params, pair);
            const v = try self.eval(blk);
            if (!v.isTruthy()) out.append(self.allocator, pair) catch return DslError.OutOfMemory;
        }
        const slice = out.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .hash = slice };
    }

    /// Dispatch an Enumerable method whose block is `&:sym` shorthand. The
    /// per-element behavior is "invoke `sym` as a receiver method on the
    /// item", matched against the existing receiver-builtin table.
    fn dispatchBlockPassSym(
        self: *Interpreter,
        method: []const u8,
        items: []const Value,
        sym: []const u8,
        loc: SourceLoc,
    ) DslError!Value {
        if (std.mem.eql(u8, method, "all?")) return self.evalArrayAllByName(items, sym, loc);
        if (std.mem.eql(u8, method, "any?")) return self.evalArrayAnyByName(items, sym, loc);
        if (std.mem.eql(u8, method, "map")) return self.evalArrayMapByName(items, sym, loc);
        if (std.mem.eql(u8, method, "select")) return self.evalArraySelectByName(items, sym, loc);
        if (std.mem.eql(u8, method, "reject")) return self.evalArrayRejectByName(items, sym, loc);
        if (std.mem.eql(u8, method, "each")) return self.evalArrayEachByName(items, sym, loc);
        // Method doesn't route through the &:sym shortcut; log and return nil
        // so the host formula can continue.
        self.ctx.fallback_log_writer.log(.{
            .formula = self.ctx.formula_name,
            .reason = .unsupported_node,
            .detail = method,
            .loc = loc,
        });
        return Value{ .nil = {} };
    }

    /// Send the zero-arg method named `sym` to `item` via the receiver-builtin
    /// table. Unknown sym is logged non-fatally and yields nil — same policy
    /// as regular unknown receiver methods.
    fn sendByName(self: *Interpreter, item: Value, sym: []const u8, loc: SourceLoc) DslError!Value {
        const builtin_ctx = builtins_root.pathname.ExecCtx{
            .allocator = self.allocator,
            .cellar_path = self.ctx.cellar_path,
            .malt_prefix = self.ctx.malt_prefix,
        };
        if (builtins_root.receiver_builtins.get(sym)) |func| {
            return func(builtin_ctx, item, &.{}) catch |e| mapBuiltinError(e);
        }
        self.ctx.fallback_log_writer.log(.{
            .formula = self.ctx.formula_name,
            .reason = .unknown_method,
            .detail = sym,
            .loc = loc,
        });
        return Value{ .nil = {} };
    }

    fn evalArrayAllByName(self: *Interpreter, items: []const Value, sym: []const u8, loc: SourceLoc) DslError!Value {
        for (items) |item| {
            const v = try self.sendByName(item, sym, loc);
            if (!v.isTruthy()) return Value{ .bool = false };
        }
        return Value{ .bool = true };
    }

    fn evalArrayAnyByName(self: *Interpreter, items: []const Value, sym: []const u8, loc: SourceLoc) DslError!Value {
        for (items) |item| {
            const v = try self.sendByName(item, sym, loc);
            if (v.isTruthy()) return Value{ .bool = true };
        }
        return Value{ .bool = false };
    }

    fn evalArrayMapByName(self: *Interpreter, items: []const Value, sym: []const u8, loc: SourceLoc) DslError!Value {
        var out: std.ArrayList(Value) = .empty;
        for (items) |item| {
            const v = try self.sendByName(item, sym, loc);
            out.append(self.allocator, v) catch return DslError.OutOfMemory;
        }
        const slice = out.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .array = slice };
    }

    fn evalArraySelectByName(self: *Interpreter, items: []const Value, sym: []const u8, loc: SourceLoc) DslError!Value {
        var out: std.ArrayList(Value) = .empty;
        for (items) |item| {
            const v = try self.sendByName(item, sym, loc);
            if (v.isTruthy()) out.append(self.allocator, item) catch return DslError.OutOfMemory;
        }
        const slice = out.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .array = slice };
    }

    fn evalArrayRejectByName(self: *Interpreter, items: []const Value, sym: []const u8, loc: SourceLoc) DslError!Value {
        var out: std.ArrayList(Value) = .empty;
        for (items) |item| {
            const v = try self.sendByName(item, sym, loc);
            if (!v.isTruthy()) out.append(self.allocator, item) catch return DslError.OutOfMemory;
        }
        const slice = out.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return Value{ .array = slice };
    }

    fn evalArrayEachByName(self: *Interpreter, items: []const Value, sym: []const u8, loc: SourceLoc) DslError!Value {
        for (items) |item| {
            _ = self.sendByName(item, sym, loc) catch |e| switch (e) {
                DslError.PostInstallFailed, DslError.PathSandboxViolation => return e,
                else => continue,
            };
        }
        return Value{ .nil = {} };
    }

    fn evalLogicalAnd(self: *Interpreter, la: *const ast.LogicalBinary) DslError!Value {
        const left = try self.eval(la.left);
        if (!left.isTruthy()) return left;
        return self.eval(la.right);
    }

    fn evalLogicalOr(self: *Interpreter, lo: *const ast.LogicalBinary) DslError!Value {
        const left = try self.eval(lo.left);
        if (left.isTruthy()) return left;
        return self.eval(lo.right);
    }

    fn evalLogicalNot(self: *Interpreter, operand: *const Node) DslError!Value {
        const val = try self.eval(operand);
        return Value{ .bool = !val.isTruthy() };
    }

    fn evalBlockSlice(self: *Interpreter, nodes: []const *const Node) DslError!Value {
        var last: Value = Value{ .nil = {} };
        for (nodes) |node| {
            last = try self.eval(node);
        }
        return last;
    }

    fn mapBuiltinError(e: builtins_root.pathname.BuiltinError) DslError {
        return switch (e) {
            builtins_root.pathname.BuiltinError.PathSandboxViolation => DslError.PathSandboxViolation,
            builtins_root.pathname.BuiltinError.PostInstallFailed => DslError.PostInstallFailed,
            builtins_root.pathname.BuiltinError.SystemCommandFailed => DslError.SystemCommandFailed,
            builtins_root.pathname.BuiltinError.OutOfMemory => DslError.OutOfMemory,
            builtins_root.pathname.BuiltinError.UnknownMethod => DslError.UnknownMethod,
            builtins_root.pathname.BuiltinError.UnsupportedNode => DslError.UnsupportedNode,
            builtins_root.pathname.BuiltinError.ParseError => DslError.ParseError,
        };
    }
};

/// True when `method` is one of the six comparison operators the parser
/// lowers from binary `a OP b` into `method_call(receiver=a, method=OP)`.
fn isComparisonOp(method: []const u8) bool {
    const ops = [_][]const u8{ "<", ">", "<=", ">=", "==", "!=" };
    for (ops) |op| if (std.mem.eql(u8, method, op)) return true;
    return false;
}

/// Evaluate `left OP right`, degrading to `false` for cross-type or
/// nil-operand cases so a logical guard (`unless x < 1`) doesn't crash.
/// Matches Ruby's int/int and string/string total orders for equal types.
fn compare(left: Value, op: []const u8, right: Value) bool {
    // Equality / inequality work across every value pair.
    if (std.mem.eql(u8, op, "==")) return left.eql(right);
    if (std.mem.eql(u8, op, "!=")) return !left.eql(right);

    // Relational operators need a total order — only defined for same-type
    // int/int or string/string pairs. Mixed-kind / nil operands degrade
    // to false so callers observe a well-defined boolean.
    const ord: i8 = blk: {
        if (left == .int and right == .int) {
            break :blk if (left.int < right.int) @as(i8, -1) else if (left.int > right.int) @as(i8, 1) else 0;
        }
        const left_str: ?[]const u8 = switch (left) {
            .string, .pathname => |s| s,
            else => null,
        };
        const right_str: ?[]const u8 = switch (right) {
            .string, .pathname => |s| s,
            else => null,
        };
        if (left_str != null and right_str != null) {
            const o = std.mem.order(u8, left_str.?, right_str.?);
            break :blk switch (o) {
                .lt => @as(i8, -1),
                .gt => @as(i8, 1),
                .eq => @as(i8, 0),
            };
        }
        return false;
    };
    if (std.mem.eql(u8, op, "<")) return ord < 0;
    if (std.mem.eql(u8, op, ">")) return ord > 0;
    if (std.mem.eql(u8, op, "<=")) return ord <= 0;
    if (std.mem.eql(u8, op, ">=")) return ord >= 0;
    return false;
}

/// Execute a formula's post_install block.
pub fn executePostInstall(
    allocator: std.mem.Allocator,
    formula: *const Formula,
    ruby_source: []const u8,
    malt_prefix: []const u8,
    flog: *FallbackLog,
) DslError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = lexer_mod.Lexer.init(ruby_source);
    var parser = parser_mod.Parser.init(a, &lexer);
    const nodes = parser.parseBlock() catch |e| {
        // Surface accumulated parse diagnostics through the fallback log
        // so the CLI can print them with file:line context. Without this
        // the diagnostics ArrayList was filled and then dropped on return.
        for (parser.diagnostics.items) |d| {
            flog.log(.{
                .formula = formula.name,
                .reason = .parse_error,
                .detail = d.message,
                .loc = d.loc,
            });
        }
        return e;
    };

    var ctx = ExecContext.init(a, formula, malt_prefix, flog);
    defer ctx.deinit();
    var interp = Interpreter.init(&ctx);
    try interp.execute(nodes);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, sub: []const u8) []const u8 {
    return std.fs.path.join(allocator, &.{ base, sub }) catch base;
}
