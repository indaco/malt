//! malt — DSL interpreter
//! Tree-walking evaluator with ExecContext for formula path bindings.

const std = @import("std");
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
};

pub const Scope = struct {
    locals: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Scope {
        return .{ .locals = std.StringHashMap(Value).init(allocator) };
    }

    pub fn deinit(self: *Scope) void {
        self.locals.deinit();
    }
};

pub const ExecContext = struct {
    allocator: std.mem.Allocator,

    // Formula path bindings (all Pathname values)
    prefix: []const u8,
    cellar_path: []const u8,
    bin: []const u8,
    sbin: []const u8,
    lib: []const u8,
    libexec: []const u8,
    include_dir: []const u8,
    share: []const u8,
    pkgshare: []const u8,
    etc: []const u8,
    var_dir: []const u8,
    opt_prefix: []const u8,

    // Global constants
    malt_prefix: []const u8,
    homebrew_prefix: []const u8,
    homebrew_cellar: []const u8,

    // Local variable scope (stack for nested blocks)
    scopes: std.ArrayList(Scope),

    // Sandbox root for path validation
    sandbox_root: []const u8,

    // Fallback log writer
    fallback_log_writer: *FallbackLog,

    // Formula name for fallback log entries
    formula_name: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        formula: *const Formula,
        malt_prefix: []const u8,
        flog: *FallbackLog,
    ) ExecContext {
        const cellar_path = std.fmt.allocPrint(allocator, "{s}/Cellar/{s}/{s}", .{
            malt_prefix, formula.name, formula.version,
        }) catch malt_prefix;

        var ctx = ExecContext{
            .allocator = allocator,
            .prefix = malt_prefix,
            .cellar_path = cellar_path,
            .bin = joinPath(allocator, cellar_path, "bin"),
            .sbin = joinPath(allocator, cellar_path, "sbin"),
            .lib = joinPath(allocator, cellar_path, "lib"),
            .libexec = joinPath(allocator, cellar_path, "libexec"),
            .include_dir = joinPath(allocator, cellar_path, "include"),
            .share = joinPath(allocator, cellar_path, "share"),
            .pkgshare = std.fmt.allocPrint(allocator, "{s}/share/{s}", .{ cellar_path, formula.name }) catch cellar_path,
            .etc = joinPath(allocator, malt_prefix, "etc"),
            .var_dir = joinPath(allocator, malt_prefix, "var"),
            .opt_prefix = std.fmt.allocPrint(allocator, "{s}/opt/{s}", .{ malt_prefix, formula.name }) catch malt_prefix,
            .malt_prefix = malt_prefix,
            .homebrew_prefix = malt_prefix,
            .homebrew_cellar = joinPath(allocator, malt_prefix, "Cellar"),
            .scopes = .empty,
            .sandbox_root = malt_prefix,
            .fallback_log_writer = flog,
            .formula_name = formula.name,
        };

        // Push initial scope
        ctx.pushScope();
        return ctx;
    }

    pub fn resolveBinding(self: *ExecContext, name: []const u8) ?Value {
        // Check local scopes (innermost first)
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].locals.get(name)) |val| {
                return val;
            }
        }

        // Check formula path bindings
        const bindings = std.StaticStringMap(void).initComptime(.{
            .{ "prefix", {} },
            .{ "bin", {} },
            .{ "sbin", {} },
            .{ "lib", {} },
            .{ "libexec", {} },
            .{ "include", {} },
            .{ "share", {} },
            .{ "pkgshare", {} },
            .{ "etc", {} },
            .{ "var", {} },
            .{ "opt_prefix", {} },
            .{ "HOMEBREW_PREFIX", {} },
            .{ "HOMEBREW_CELLAR", {} },
        });

        if (bindings.has(name)) {
            return self.getPathBinding(name);
        }

        return null;
    }

    fn getPathBinding(self: *const ExecContext, name: []const u8) ?Value {
        if (std.mem.eql(u8, name, "prefix")) return Value{ .pathname = self.cellar_path };
        if (std.mem.eql(u8, name, "bin")) return Value{ .pathname = self.bin };
        if (std.mem.eql(u8, name, "sbin")) return Value{ .pathname = self.sbin };
        if (std.mem.eql(u8, name, "lib")) return Value{ .pathname = self.lib };
        if (std.mem.eql(u8, name, "libexec")) return Value{ .pathname = self.libexec };
        if (std.mem.eql(u8, name, "include")) return Value{ .pathname = self.include_dir };
        if (std.mem.eql(u8, name, "share")) return Value{ .pathname = self.share };
        if (std.mem.eql(u8, name, "pkgshare")) return Value{ .pathname = self.pkgshare };
        if (std.mem.eql(u8, name, "etc")) return Value{ .pathname = self.etc };
        if (std.mem.eql(u8, name, "var")) return Value{ .pathname = self.var_dir };
        if (std.mem.eql(u8, name, "opt_prefix")) return Value{ .pathname = self.opt_prefix };
        if (std.mem.eql(u8, name, "HOMEBREW_PREFIX")) return Value{ .pathname = self.homebrew_prefix };
        if (std.mem.eql(u8, name, "HOMEBREW_CELLAR")) return Value{ .pathname = self.homebrew_cellar };
        return null;
    }

    pub fn pushScope(self: *ExecContext) void {
        self.scopes.append(self.allocator, Scope.init(self.allocator)) catch {};
    }

    pub fn popScope(self: *ExecContext) void {
        if (self.scopes.items.len > 0) {
            var scope = self.scopes.pop() orelse return;
            scope.deinit();
        }
    }

    pub fn setLocal(self: *ExecContext, name: []const u8, value: Value) void {
        if (self.scopes.items.len > 0) {
            self.scopes.items[self.scopes.items.len - 1].locals.put(name, value) catch {};
        }
    }
};

pub const Interpreter = struct {
    ctx: *ExecContext,
    allocator: std.mem.Allocator,

    pub fn init(ctx: *ExecContext) Interpreter {
        return .{
            .ctx = ctx,
            .allocator = ctx.allocator,
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
        };
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
        const items = switch (iterable) {
            .array => |a| a,
            else => return Value{ .nil = {} },
        };

        for (items) |item| {
            self.ctx.pushScope();
            defer self.ctx.popScope();

            if (el.params.len > 0) {
                self.ctx.setLocal(el.params[0], item);
            }

            _ = self.evalBlockSlice(el.body) catch |e| switch (e) {
                DslError.PostInstallFailed, DslError.PathSandboxViolation => return e,
                else => continue,
            };
        }
        return Value{ .nil = {} };
    }

    fn evalBeginRescue(self: *Interpreter, br: *const ast.BeginRescue) DslError!Value {
        _ = self.evalBlockSlice(br.body) catch |e| switch (e) {
            // Only sandbox violations are truly unrecoverable
            DslError.PathSandboxViolation => return e,
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
            const f = std.fs.File.stderr();
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
    const nodes = try parser.parseBlock();

    var ctx = ExecContext.init(a, formula, malt_prefix, flog);
    var interp = Interpreter.init(&ctx);
    try interp.execute(nodes);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, sub: []const u8) []const u8 {
    return std.fs.path.join(allocator, &.{ base, sub }) catch base;
}
