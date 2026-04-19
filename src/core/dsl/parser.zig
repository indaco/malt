//! malt — DSL parser
//! Recursive-descent parser for the Ruby subset. Single-pass, no backtracking.

const std = @import("std");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");

const Node = ast.Node;
const SourceLoc = ast.SourceLoc;
const Token = lexer_mod.Token;
const TokenKind = lexer_mod.TokenKind;
const Lexer = lexer_mod.Lexer;

pub const DslError = error{
    ParseError,
    OutOfMemory,
};

pub const Diagnostic = struct {
    loc: SourceLoc,
    message: []const u8,
    severity: Severity,

    pub const Severity = enum { warning, err };
};

pub const Parser = struct {
    lexer: *Lexer,
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),
    current: Token,

    pub fn init(allocator: std.mem.Allocator, lex: *Lexer) Parser {
        const first = lex.next();
        return .{
            .lexer = lex,
            .allocator = allocator,
            .diagnostics = .empty,
            .current = first,
        };
    }

    /// Parse a complete post_install block body (sequence of statements).
    pub fn parseBlock(self: *Parser) DslError![]const *const Node {
        var stmts: std.ArrayList(*const Node) = .empty;

        while (self.current.kind != .eof and
            self.current.kind != .kw_end and
            self.current.kind != .kw_else and
            self.current.kind != .kw_elsif and
            self.current.kind != .kw_rescue and
            self.current.kind != .rbrace)
        {
            self.skipNewlines();
            if (self.current.kind == .eof or
                self.current.kind == .kw_end or
                self.current.kind == .kw_else or
                self.current.kind == .kw_elsif or
                self.current.kind == .kw_rescue or
                self.current.kind == .rbrace) break;

            const stmt = try self.parseStatement();
            stmts.append(self.allocator, stmt) catch return DslError.OutOfMemory;
            self.skipNewlines();
        }

        return stmts.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
    }

    fn parseStatement(self: *Parser) DslError!*const Node {
        // if statement
        if (self.current.kind == .kw_if) return self.parseIf();
        // unless statement
        if (self.current.kind == .kw_unless) return self.parseUnless();
        // begin/rescue
        if (self.current.kind == .kw_begin) return self.parseBeginRescue();
        // raise
        if (self.current.kind == .kw_raise) return self.parseRaise();
        // user-defined method
        if (self.current.kind == .kw_def) return self.parseDef();
        // return [expr] — eligible for postfix if/unless below.
        if (self.current.kind == .kw_return) {
            const ret = try self.parseReturn();
            return self.maybeWrapPostfix(ret);
        }

        // Assignment or expression statement
        const expr = try self.parseExpression();
        return self.maybeWrapPostfix(expr);
    }

    /// Wrap `body` in a postfix_if/postfix_unless if the current token is
    /// `if`/`unless`, otherwise return it unchanged. Used for both regular
    /// expression statements and `return` — Ruby lets either form appear
    /// with a trailing guard.
    fn maybeWrapPostfix(self: *Parser, body: *const Node) DslError!*const Node {
        if (self.current.kind == .kw_if) {
            self.advanceToken();
            const cond = try self.parseExpression();
            return self.allocNode(.{
                .loc = body.loc,
                .kind = .{ .postfix_if = .{ .body = body, .condition = cond } },
            });
        }
        if (self.current.kind == .kw_unless) {
            self.advanceToken();
            const cond = try self.parseExpression();
            return self.allocNode(.{
                .loc = body.loc,
                .kind = .{ .postfix_unless = .{ .body = body, .condition = cond } },
            });
        }
        return body;
    }

    fn parseExpression(self: *Parser) DslError!*const Node {
        // Check for assignment: identifier followed by =
        if (self.current.kind == .identifier) {
            const name = self.current.lexeme;
            const loc = self.currentLoc();

            // Peek ahead to see if next non-newline token is =. All
            // lexer state that `next()` may mutate must be saved here,
            // including the heredoc fields — otherwise a peek that
            // straddles a heredoc boundary would clobber the lexer's
            // mid-collection state.
            const saved_pos = self.lexer.pos;
            const saved_line = self.lexer.line;
            const saved_col = self.lexer.col;
            const saved_lwv = self.lexer.last_was_value;
            const saved_ht = self.lexer.heredoc_terminator;
            const saved_hc = self.lexer.heredoc_collecting;
            const next_tok = self.lexer.next();
            self.lexer.pos = saved_pos;
            self.lexer.line = saved_line;
            self.lexer.col = saved_col;
            self.lexer.last_was_value = saved_lwv;
            self.lexer.heredoc_terminator = saved_ht;
            self.lexer.heredoc_collecting = saved_hc;

            if (next_tok.kind == .equals) {
                self.advanceToken(); // consume identifier
                self.advanceToken(); // consume =
                const value = try self.parseExpression();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .assignment = .{ .name = name, .value = value } },
                });
            }
        }

        return self.parseLogicalOr();
    }

    fn parseLogicalOr(self: *Parser) DslError!*const Node {
        var node = try self.parseLogicalAnd();
        while (self.current.kind == .double_pipe) {
            const loc = self.currentLoc();
            self.advanceToken();
            const right = try self.parseLogicalAnd();
            node = self.allocNode(.{
                .loc = loc,
                .kind = .{ .logical_or = .{ .left = node, .right = right } },
            }) catch return DslError.OutOfMemory;
        }
        return node;
    }

    fn parseLogicalAnd(self: *Parser) DslError!*const Node {
        var node = try self.parseUnaryNot();
        while (self.current.kind == .double_amp) {
            const loc = self.currentLoc();
            self.advanceToken();
            const right = try self.parseUnaryNot();
            node = self.allocNode(.{
                .loc = loc,
                .kind = .{ .logical_and = .{ .left = node, .right = right } },
            }) catch return DslError.OutOfMemory;
        }
        return node;
    }

    fn parseUnaryNot(self: *Parser) DslError!*const Node {
        if (self.current.kind == .bang) {
            const loc = self.currentLoc();
            self.advanceToken();
            const operand = try self.parseUnaryNot();
            return self.allocNode(.{
                .loc = loc,
                .kind = .{ .logical_not = operand },
            });
        }
        return self.parseMethodChain();
    }

    /// Top of the chain precedence stack — shovel `<<` is Ruby's lowest
    /// chain operator, so it consumes fully-formed tight chains on both
    /// sides. Split out so `arr << share/"x"` parses as `arr << (share/"x")`.
    fn parseMethodChain(self: *Parser) DslError!*const Node {
        var node = try self.parseTightChain();
        while (self.current.kind == .less_less) {
            const loc = self.currentLoc();
            self.advanceToken(); // consume <<
            const right = try self.parseTightChain();
            const args = self.allocator.alloc(*const Node, 1) catch return DslError.OutOfMemory;
            args[0] = right;
            node = self.allocNode(.{
                .loc = loc,
                .kind = .{ .method_call = .{
                    .receiver = node,
                    .method = "<<",
                    .args = args,
                    .blk = null,
                    .block_params = &.{},
                } },
            }) catch return DslError.OutOfMemory;
        }
        return node;
    }

    /// Dot / path-join / module-separator bind tighter than shovel.
    /// Used both as the entry point from `parseMethodChain` and for each
    /// shovel operand, so `a << b.m / c` → `a << ((b.m) / c)`.
    fn parseTightChain(self: *Parser) DslError!*const Node {
        var node = try self.parsePrimary();
        while (true) {
            if (self.current.kind == .dot) {
                self.advanceToken(); // consume .
                node = try self.parseMethodCallTail(node);
            } else if (self.current.kind == .slash) {
                // Path join: expr / expr
                const loc = self.currentLoc();
                self.advanceToken(); // consume /
                const right = try self.parsePrimary();
                node = self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .path_join = .{ .left = node, .right = right } },
                }) catch return DslError.OutOfMemory;
            } else if (self.current.kind == .double_colon) {
                self.advanceToken(); // consume ::
                node = try self.parseMethodCallTail(node);
            } else {
                break;
            }
        }
        return node;
    }

    fn parseMethodCallTail(self: *Parser, receiver: *const Node) DslError!*const Node {
        if (self.current.kind != .identifier and
            self.current.kind != .kw_each)
        {
            return self.emitError("expected method name after '.'");
        }

        const method = self.current.lexeme;
        const loc = self.currentLoc();
        self.advanceToken();

        // .each with block
        if (std.mem.eql(u8, method, "each")) {
            return self.parseEachWithReceiver(receiver, loc);
        }

        // Parse arguments — paren list may end with `&<primary>` (block-pass).
        var args: std.ArrayList(*const Node) = .empty;
        var block_pass: ?*const Node = null;
        if (self.current.kind == .lparen) {
            self.advanceToken();
            while (self.current.kind != .rparen and self.current.kind != .eof) {
                self.skipNewlines();
                if (self.current.kind == .rparen) break;
                switch (try self.parseOneArg()) {
                    .arg => |a| args.append(self.allocator, a) catch return DslError.OutOfMemory,
                    .block_pass => |bp| {
                        block_pass = bp;
                        break;
                    },
                }
                self.skipNewlines();
                if (self.current.kind == .comma) {
                    self.advanceToken();
                    self.skipNewlines();
                }
            }
            if (self.current.kind == .rparen) self.advanceToken();
        } else if (isExprStart(self.current.kind) and
            self.current.kind != .newline and
            self.current.kind != .kw_if and
            self.current.kind != .kw_unless and
            self.current.kind != .kw_do and
            self.current.kind != .kw_end and
            self.current.kind != .dot)
        {
            // Bare arguments (no parens) — common for ohai, system, etc.
            const arg = try self.parseExpression();
            args.append(self.allocator, arg) catch return DslError.OutOfMemory;
            while (self.current.kind == .comma) {
                self.advanceToken();
                self.skipNewlines();
                switch (try self.parseOneArg()) {
                    .arg => |a| args.append(self.allocator, a) catch return DslError.OutOfMemory,
                    .block_pass => |bp| {
                        block_pass = bp;
                        break;
                    },
                }
            }
        }

        // Parse optional block
        var blk: ?*const Node = null;
        var block_params: std.ArrayList([]const u8) = .empty;
        if (self.current.kind == .kw_do) {
            self.advanceToken();
            try self.parseBlockParams(&block_params);
            const body = try self.parseBlock();
            if (self.current.kind == .kw_end) self.advanceToken();
            blk = try self.allocNode(.{
                .loc = loc,
                .kind = .{ .block = body },
            });
        } else if (self.current.kind == .lbrace) {
            self.advanceToken();
            try self.parseBlockParams(&block_params);
            const body = try self.parseBlock();
            if (self.current.kind == .rbrace) self.advanceToken();
            blk = try self.allocNode(.{
                .loc = loc,
                .kind = .{ .block = body },
            });
        }

        const args_slice = args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        const params_slice = block_params.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;

        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .method_call = .{
                .receiver = receiver,
                .method = method,
                .args = args_slice,
                .blk = blk,
                .block_params = params_slice,
                .block_pass = block_pass,
            } },
        });
    }

    fn parsePrimary(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();

        switch (self.current.kind) {
            .string_double => {
                const raw = self.current.lexeme;
                self.advanceToken();
                // Strip quotes
                const content = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                // Parse interpolation segments #{...}
                const parts = try self.parseStringInterpolation(content, loc);
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .string_literal = .{ .parts = parts } },
                });
            },
            .string_single => {
                const raw = self.current.lexeme;
                self.advanceToken();
                // Strip quotes — single-quoted strings have no interpolation
                const content = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .string_literal = .{
                        .parts = blk: {
                            const parts = self.allocator.alloc(ast.StringPart, 1) catch return DslError.OutOfMemory;
                            parts[0] = .{ .literal = content };
                            break :blk parts;
                        },
                    } },
                });
            },
            .percent_w => {
                // %w[word1 word2 ...] — split by whitespace into a string
                // array. Pre-count and bulk-allocate so a typical %w[...]
                // costs three allocs (StringParts, Nodes, *Node slice)
                // instead of 1+2*N from the previous per-word loop.
                const content = self.current.lexeme;
                self.advanceToken();

                var counter = std.mem.tokenizeAny(u8, content, " \t\n\r");
                var n: usize = 0;
                while (counter.next()) |_| n += 1;
                if (n == 0) {
                    const empty: []const *const Node = &.{};
                    return self.allocNode(.{
                        .loc = loc,
                        .kind = .{ .array_literal = empty },
                    });
                }

                const parts = self.allocator.alloc(ast.StringPart, n) catch return DslError.OutOfMemory;
                const nodes = self.allocator.alloc(Node, n) catch return DslError.OutOfMemory;
                const elems = self.allocator.alloc(*const Node, n) catch return DslError.OutOfMemory;

                var it = std.mem.tokenizeAny(u8, content, " \t\n\r");
                var i: usize = 0;
                while (it.next()) |word| : (i += 1) {
                    parts[i] = .{ .literal = word };
                    nodes[i] = .{
                        .loc = loc,
                        .kind = .{ .string_literal = .{ .parts = parts[i .. i + 1] } },
                    };
                    elems[i] = &nodes[i];
                }

                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .array_literal = elems },
                });
            },
            .heredoc_start => {
                // Advance past start, next token should be heredoc_body
                self.advanceToken();
                const body_lexeme = if (self.current.kind == .heredoc_body) self.current.lexeme else "";
                if (self.current.kind == .heredoc_body) self.advanceToken();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .heredoc_literal = body_lexeme },
                });
            },
            .heredoc_body => {
                const body_lexeme = self.current.lexeme;
                self.advanceToken();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .heredoc_literal = body_lexeme },
                });
            },
            .integer => {
                const val = parseIntValue(self.current.lexeme);
                self.advanceToken();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .int_literal = val },
                });
            },
            .float_lit => {
                const val = std.fmt.parseFloat(f64, self.current.lexeme) catch 0.0;
                self.advanceToken();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .float_literal = val },
                });
            },
            .kw_true => {
                self.advanceToken();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .bool_literal = true },
                });
            },
            .kw_false => {
                self.advanceToken();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .bool_literal = false },
                });
            },
            .kw_nil => {
                self.advanceToken();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .nil_literal = {} },
                });
            },
            .symbol => {
                const raw = self.current.lexeme;
                self.advanceToken();
                // Strip leading :
                const name = if (raw.len > 1) raw[1..] else raw;
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .symbol_literal = name },
                });
            },
            .regex => {
                // Store regex as a string for now
                const raw = self.current.lexeme;
                self.advanceToken();
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .string_literal = .{
                        .parts = blk: {
                            const parts = self.allocator.alloc(ast.StringPart, 1) catch return DslError.OutOfMemory;
                            parts[0] = .{ .literal = raw };
                            break :blk parts;
                        },
                    } },
                });
            },
            .identifier => {
                const name = self.current.lexeme;

                // --- Dir[expr] → Dir.glob(expr) ---
                if (std.mem.eql(u8, name, "Dir")) {
                    // Peek to see if next token is [
                    const saved_pos2 = self.lexer.pos;
                    const saved_line2 = self.lexer.line;
                    const saved_col2 = self.lexer.col;
                    const saved_lwv2 = self.lexer.last_was_value;
                    const peek_tok = self.lexer.next();
                    self.lexer.pos = saved_pos2;
                    self.lexer.line = saved_line2;
                    self.lexer.col = saved_col2;
                    self.lexer.last_was_value = saved_lwv2;

                    if (peek_tok.kind == .lbracket) {
                        self.advanceToken(); // consume "Dir"
                        self.advanceToken(); // consume "["
                        var args: std.ArrayList(*const Node) = .empty;
                        while (self.current.kind != .rbracket and self.current.kind != .eof) {
                            const arg = try self.parseExpression();
                            args.append(self.allocator, arg) catch return DslError.OutOfMemory;
                            if (self.current.kind == .comma) {
                                self.advanceToken();
                                self.skipNewlines();
                            }
                        }
                        if (self.current.kind == .rbracket) self.advanceToken();
                        const args_slice = args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                        return self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .method_call = .{
                                .receiver = null,
                                .method = "Dir.glob",
                                .args = args_slice,
                                .blk = null,
                                .block_params = &.{},
                            } },
                        });
                    }
                }

                // --- Formula["name"] → Formula.lookup(name) ---
                if (std.mem.eql(u8, name, "Formula")) {
                    const saved_pos4 = self.lexer.pos;
                    const saved_line4 = self.lexer.line;
                    const saved_col4 = self.lexer.col;
                    const saved_lwv4 = self.lexer.last_was_value;
                    const peek_tok3 = self.lexer.next();
                    self.lexer.pos = saved_pos4;
                    self.lexer.line = saved_line4;
                    self.lexer.col = saved_col4;
                    self.lexer.last_was_value = saved_lwv4;

                    if (peek_tok3.kind == .lbracket) {
                        self.advanceToken(); // consume "Formula"
                        self.advanceToken(); // consume "["
                        const name_expr = try self.parseExpression();
                        if (self.current.kind == .rbracket) self.advanceToken();
                        const args = self.allocator.alloc(*const Node, 1) catch return DslError.OutOfMemory;
                        args[0] = name_expr;
                        return self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .method_call = .{
                                .receiver = null,
                                .method = "Formula.lookup",
                                .args = args,
                                .blk = null,
                                .block_params = &.{},
                            } },
                        });
                    }
                }

                // --- ENV["key"] read / ENV["key"] = value write ---
                if (std.mem.eql(u8, name, "ENV")) {
                    const saved_pos3 = self.lexer.pos;
                    const saved_line3 = self.lexer.line;
                    const saved_col3 = self.lexer.col;
                    const saved_lwv3 = self.lexer.last_was_value;
                    const peek_tok2 = self.lexer.next();
                    self.lexer.pos = saved_pos3;
                    self.lexer.line = saved_line3;
                    self.lexer.col = saved_col3;
                    self.lexer.last_was_value = saved_lwv3;

                    if (peek_tok2.kind == .lbracket) {
                        self.advanceToken(); // consume "ENV"
                        self.advanceToken(); // consume "["
                        const key_expr = try self.parseExpression();
                        if (self.current.kind == .rbracket) self.advanceToken();

                        // Check for assignment: ENV["key"] = value
                        if (self.current.kind == .equals) {
                            self.advanceToken(); // consume =
                            const val_expr = try self.parseExpression();
                            // Emit as method_call to "ENV.set" with key and value args
                            var args: std.ArrayList(*const Node) = .empty;
                            args.append(self.allocator, key_expr) catch return DslError.OutOfMemory;
                            args.append(self.allocator, val_expr) catch return DslError.OutOfMemory;
                            const args_slice = args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                            return self.allocNode(.{
                                .loc = loc,
                                .kind = .{ .method_call = .{
                                    .receiver = null,
                                    .method = "ENV.set",
                                    .args = args_slice,
                                    .blk = null,
                                    .block_params = &.{},
                                } },
                            });
                        }

                        // Read form: ENV["key"]
                        var args: std.ArrayList(*const Node) = .empty;
                        args.append(self.allocator, key_expr) catch return DslError.OutOfMemory;
                        const args_slice = args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                        return self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .method_call = .{
                                .receiver = null,
                                .method = "ENV.get",
                                .args = args_slice,
                                .blk = null,
                                .block_params = &.{},
                            } },
                        });
                    }
                }

                self.advanceToken();

                // For methods that are ALWAYS bare-call (never use parens),
                // parse args as expressions — `cp (expr).method, dest`
                // needs `(expr)` parsed as grouped expression, not arg-list delimiters.
                if (isAlwaysBareMethod(name) and isExprStart(self.current.kind) and
                    self.current.kind != .newline and
                    self.current.kind != .kw_if and
                    self.current.kind != .kw_unless and
                    self.current.kind != .kw_end and
                    self.current.kind != .kw_do and
                    self.current.kind != .dot)
                {
                    var args: std.ArrayList(*const Node) = .empty;
                    var block_pass: ?*const Node = null;
                    const arg = try self.parseExpression();
                    args.append(self.allocator, arg) catch return DslError.OutOfMemory;
                    while (self.current.kind == .comma) {
                        self.advanceToken();
                        self.skipNewlines();
                        switch (try self.parseOneArg()) {
                            .arg => |a| args.append(self.allocator, a) catch return DslError.OutOfMemory,
                            .block_pass => |bp| {
                                block_pass = bp;
                                break;
                            },
                        }
                    }

                    // Parse optional block
                    var blk: ?*const Node = null;
                    var block_params: std.ArrayList([]const u8) = .empty;
                    if (self.current.kind == .kw_do) {
                        self.advanceToken();
                        try self.parseBlockParams(&block_params);
                        const body = try self.parseBlock();
                        if (self.current.kind == .kw_end) self.advanceToken();
                        blk = try self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .block = body },
                        });
                    } else if (self.current.kind == .lbrace) {
                        self.advanceToken();
                        try self.parseBlockParams(&block_params);
                        const body = try self.parseBlock();
                        if (self.current.kind == .rbrace) self.advanceToken();
                        blk = try self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .block = body },
                        });
                    }

                    const args_slice = args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                    const params_slice = block_params.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;

                    return self.allocNode(.{
                        .loc = loc,
                        .kind = .{ .method_call = .{
                            .receiver = null,
                            .method = name,
                            .args = args_slice,
                            .blk = blk,
                            .block_params = params_slice,
                            .block_pass = block_pass,
                        } },
                    });
                }

                // Non-bare method call with parens: method(args)
                if (self.current.kind == .lparen) {
                    // method(args) — may end with `&<primary>` block-pass.
                    self.advanceToken();
                    var args: std.ArrayList(*const Node) = .empty;
                    var block_pass: ?*const Node = null;
                    while (self.current.kind != .rparen and self.current.kind != .eof) {
                        switch (try self.parseOneArg()) {
                            .arg => |a| args.append(self.allocator, a) catch return DslError.OutOfMemory,
                            .block_pass => |bp| {
                                block_pass = bp;
                                break;
                            },
                        }
                        if (self.current.kind == .comma) {
                            self.advanceToken();
                            self.skipNewlines();
                        }
                    }
                    if (self.current.kind == .rparen) self.advanceToken();

                    // Parse optional block
                    var blk: ?*const Node = null;
                    var block_params: std.ArrayList([]const u8) = .empty;
                    if (self.current.kind == .kw_do) {
                        self.advanceToken();
                        try self.parseBlockParams(&block_params);
                        const body = try self.parseBlock();
                        if (self.current.kind == .kw_end) self.advanceToken();
                        blk = try self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .block = body },
                        });
                    } else if (self.current.kind == .lbrace) {
                        self.advanceToken();
                        try self.parseBlockParams(&block_params);
                        const body = try self.parseBlock();
                        if (self.current.kind == .rbrace) self.advanceToken();
                        blk = try self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .block = body },
                        });
                    }

                    const args_slice = args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                    const params_slice = block_params.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;

                    return self.allocNode(.{
                        .loc = loc,
                        .kind = .{ .method_call = .{
                            .receiver = null,
                            .method = name,
                            .args = args_slice,
                            .blk = blk,
                            .block_params = params_slice,
                            .block_pass = block_pass,
                        } },
                    });
                }

                // Check if this is a bare method call with arguments (no parens)
                // Only for known methods that take bare args
                if (isBareCallMethod(name) and isExprStart(self.current.kind) and
                    self.current.kind != .newline and
                    self.current.kind != .kw_if and
                    self.current.kind != .kw_unless and
                    self.current.kind != .kw_end and
                    self.current.kind != .kw_do and
                    self.current.kind != .dot)
                {
                    var args: std.ArrayList(*const Node) = .empty;
                    var block_pass: ?*const Node = null;
                    const arg = try self.parseExpression();
                    args.append(self.allocator, arg) catch return DslError.OutOfMemory;
                    while (self.current.kind == .comma) {
                        self.advanceToken();
                        self.skipNewlines();
                        switch (try self.parseOneArg()) {
                            .arg => |a| args.append(self.allocator, a) catch return DslError.OutOfMemory,
                            .block_pass => |bp| {
                                block_pass = bp;
                                break;
                            },
                        }
                    }

                    // Parse optional block
                    var blk: ?*const Node = null;
                    var block_params: std.ArrayList([]const u8) = .empty;
                    if (self.current.kind == .kw_do) {
                        self.advanceToken();
                        try self.parseBlockParams(&block_params);
                        const body = try self.parseBlock();
                        if (self.current.kind == .kw_end) self.advanceToken();
                        blk = try self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .block = body },
                        });
                    } else if (self.current.kind == .lbrace) {
                        self.advanceToken();
                        try self.parseBlockParams(&block_params);
                        const body = try self.parseBlock();
                        if (self.current.kind == .rbrace) self.advanceToken();
                        blk = try self.allocNode(.{
                            .loc = loc,
                            .kind = .{ .block = body },
                        });
                    }

                    const args_slice = args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                    const params_slice = block_params.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;

                    return self.allocNode(.{
                        .loc = loc,
                        .kind = .{ .method_call = .{
                            .receiver = null,
                            .method = name,
                            .args = args_slice,
                            .blk = blk,
                            .block_params = params_slice,
                            .block_pass = block_pass,
                        } },
                    });
                }

                // Plain identifier
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .identifier = name },
                });
            },
            .lbracket => {
                // Array literal
                self.advanceToken();
                var elems: std.ArrayList(*const Node) = .empty;
                while (self.current.kind != .rbracket and self.current.kind != .eof) {
                    self.skipNewlines();
                    if (self.current.kind == .rbracket) break;
                    const elem = try self.parseExpression();
                    elems.append(self.allocator, elem) catch return DslError.OutOfMemory;
                    self.skipNewlines();
                    if (self.current.kind == .comma) self.advanceToken();
                }
                if (self.current.kind == .rbracket) self.advanceToken();
                const slice = elems.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .array_literal = slice },
                });
            },
            .lbrace => {
                // Hash literal. Ruby's shorthand `{ name: value }` lowers
                // to a symbol key — recognise the `identifier:` case so
                // it doesn't get resolved as an unknown method/identifier
                // at interpret time.
                self.advanceToken();
                var entries: std.ArrayList(ast.HashEntry) = .empty;
                while (self.current.kind != .rbrace and self.current.kind != .eof) {
                    self.skipNewlines();
                    if (self.current.kind == .rbrace) break;

                    const key_loc = self.currentLoc();
                    var key: *const Node = undefined;
                    // Peek: if we see `identifier : ...` (single colon, not `::`),
                    // treat the identifier as a symbol literal.
                    if (self.current.kind == .identifier) {
                        const lex_before = self.lexer.*;
                        const ident_lexeme = self.current.lexeme;
                        self.advanceToken();
                        if (self.current.kind == .colon) {
                            self.advanceToken();
                            key = try self.allocNode(.{
                                .loc = key_loc,
                                .kind = .{ .symbol_literal = ident_lexeme },
                            });
                            const value = try self.parseExpression();
                            entries.append(self.allocator, .{ .key = key, .value = value }) catch return DslError.OutOfMemory;
                            self.skipNewlines();
                            if (self.current.kind == .comma) self.advanceToken();
                            continue;
                        }
                        // Not shorthand — rewind and parse as a full expression.
                        self.lexer.* = lex_before;
                        self.current = self.lexer.next();
                    }

                    key = try self.parseExpression();
                    if (self.current.kind == .fat_arrow) {
                        self.advanceToken();
                    } else if (self.current.kind == .colon) {
                        self.advanceToken();
                    }

                    const value = try self.parseExpression();
                    entries.append(self.allocator, .{ .key = key, .value = value }) catch return DslError.OutOfMemory;
                    self.skipNewlines();
                    if (self.current.kind == .comma) self.advanceToken();
                }
                if (self.current.kind == .rbrace) self.advanceToken();
                const slice = entries.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .hash_literal = slice },
                });
            },
            .lparen => {
                self.advanceToken();
                const inner = try self.parseExpression();
                if (self.current.kind == .rparen) self.advanceToken();
                return inner;
            },
            else => {
                return self.emitError("unexpected token in expression");
            },
        }
    }

    fn parseIf(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken(); // consume 'if'

        const condition = try self.parseExpression();
        self.skipNewlines();
        // Optional 'then'
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "then")) {
            self.advanceToken();
        }
        self.skipNewlines();

        const then_body = try self.parseBlock();

        var elsif_branches: std.ArrayList(ast.ElsifBranch) = .empty;
        while (self.current.kind == .kw_elsif) {
            self.advanceToken();
            const elsif_cond = try self.parseExpression();
            self.skipNewlines();
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "then")) {
                self.advanceToken();
            }
            self.skipNewlines();
            const elsif_body = try self.parseBlock();
            elsif_branches.append(self.allocator, .{
                .condition = try self.makeNodePtr(elsif_cond),
                .body = elsif_body,
            }) catch return DslError.OutOfMemory;
        }

        var else_body: ?[]const *const Node = null;
        if (self.current.kind == .kw_else) {
            self.advanceToken();
            self.skipNewlines();
            else_body = try self.parseBlock();
        }

        if (self.current.kind == .kw_end) self.advanceToken();

        const elsif_slice = elsif_branches.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;

        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .if_else = .{
                .condition = try self.makeNodePtr(condition),
                .then_body = then_body,
                .elsif_branches = elsif_slice,
                .else_body = else_body,
            } },
        });
    }

    fn parseUnless(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken(); // consume 'unless'

        const condition = try self.parseExpression();
        self.skipNewlines();

        const body = try self.parseBlock();

        var else_body: ?[]const *const Node = null;
        if (self.current.kind == .kw_else) {
            self.advanceToken();
            self.skipNewlines();
            else_body = try self.parseBlock();
        }

        if (self.current.kind == .kw_end) self.advanceToken();

        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .unless_statement = .{
                .condition = try self.makeNodePtr(condition),
                .body = body,
                .else_body = else_body,
            } },
        });
    }

    fn parseEachWithReceiver(self: *Parser, receiver: *const Node, loc: SourceLoc) DslError!*const Node {
        // .each do |x| ... end
        var block_params: std.ArrayList([]const u8) = .empty;

        if (self.current.kind == .kw_do) {
            self.advanceToken();
            try self.parseBlockParams(&block_params);
            const body = try self.parseBlock();
            if (self.current.kind == .kw_end) self.advanceToken();

            const params_slice = block_params.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
            return self.allocNode(.{
                .loc = loc,
                .kind = .{ .each_loop = .{
                    .iterable = receiver,
                    .params = params_slice,
                    .body = body,
                } },
            });
        } else if (self.current.kind == .lbrace) {
            self.advanceToken();
            try self.parseBlockParams(&block_params);
            const body = try self.parseBlock();
            if (self.current.kind == .rbrace) self.advanceToken();

            const params_slice = block_params.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
            return self.allocNode(.{
                .loc = loc,
                .kind = .{ .each_loop = .{
                    .iterable = receiver,
                    .params = params_slice,
                    .body = body,
                } },
            });
        }

        // .each without block — treat as method call
        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .method_call = .{
                .receiver = receiver,
                .method = "each",
                .args = &.{},
                .blk = null,
                .block_params = &.{},
            } },
        });
    }

    fn parseBeginRescue(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken(); // consume 'begin'
        self.skipNewlines();

        const body = try self.parseBlock();

        var rescue_body: []const *const Node = &.{};
        var exception_var: ?[]const u8 = null;
        if (self.current.kind == .kw_rescue) {
            self.advanceToken();
            // Optional exception class and variable: rescue SomeError => e
            if (self.current.kind == .identifier) {
                const maybe_class = self.current.lexeme;
                self.advanceToken();
                if (self.current.kind == .fat_arrow) {
                    self.advanceToken();
                    if (self.current.kind == .identifier) {
                        exception_var = self.current.lexeme;
                        self.advanceToken();
                    }
                } else {
                    // It might be a variable name or class; for Phase 1, treat as class
                    _ = maybe_class;
                }
            }
            self.skipNewlines();
            rescue_body = try self.parseBlock();
        }

        if (self.current.kind == .kw_end) self.advanceToken();

        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .begin_rescue = .{
                .body = body,
                .rescue_body = rescue_body,
                .exception_var = exception_var,
            } },
        });
    }

    fn parseRaise(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken(); // consume 'raise'

        var message: ?*const Node = null;
        if (self.current.kind != .newline and self.current.kind != .eof) {
            message = try self.parseExpression();
        }

        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .raise_statement = .{ .message = message } },
        });
    }

    /// Parse `def name[(params) | params] body end`. Paren-less forms are
    /// accepted because older homebrew-core formulas still use them.
    fn parseDef(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken(); // consume 'def'

        if (self.current.kind != .identifier) {
            return self.emitError("expected method name after 'def'");
        }
        const name = self.current.lexeme;
        self.advanceToken();

        var params: std.ArrayList([]const u8) = .empty;
        if (self.current.kind == .lparen) {
            self.advanceToken();
            try self.parseDefParams(&params);
            if (self.current.kind == .rparen) self.advanceToken();
        } else if (self.current.kind == .identifier) {
            try self.parseDefParams(&params);
        }

        self.skipNewlines();
        const body = try self.parseBlock();
        if (self.current.kind == .kw_end) self.advanceToken();

        const params_slice = params.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .method_def = .{
                .name = name,
                .params = params_slice,
                .body = body,
            } },
        });
    }

    /// Collect a comma-separated identifier list for `def` params. Shared
    /// between paren and bare forms; the caller consumes the paren (or
    /// newline) that terminates the list. Unknown tokens (default args,
    /// `*rest`, `&blk`) stop the loop — formulas using those degrade to
    /// `--use-system-ruby` via the sibling parse-check.
    fn parseDefParams(
        self: *Parser,
        params: *std.ArrayList([]const u8),
    ) DslError!void {
        while (self.current.kind == .identifier) {
            params.append(self.allocator, self.current.lexeme) catch return DslError.OutOfMemory;
            self.advanceToken();
            if (self.current.kind == .comma) {
                self.advanceToken();
                self.skipNewlines();
                continue;
            }
            break;
        }
    }

    fn parseReturn(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken(); // consume 'return'

        // Bare `return` must not greedily swallow the next statement.
        const has_value = switch (self.current.kind) {
            .newline, .eof, .kw_end, .kw_else, .kw_elsif, .kw_rescue, .rbrace, .kw_if, .kw_unless => false,
            else => true,
        };
        const value: ?*const Node = if (has_value) try self.parseExpression() else null;

        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .return_statement = .{ .value = value } },
        });
    }

    /// Parse a double-quoted string's content for #{...} interpolation segments.
    fn parseStringInterpolation(self: *Parser, content: []const u8, loc: SourceLoc) DslError![]const ast.StringPart {
        // Quick check: if no interpolation, return a single literal part
        if (std.mem.indexOf(u8, content, "#{") == null) {
            const parts = self.allocator.alloc(ast.StringPart, 1) catch return DslError.OutOfMemory;
            parts[0] = .{ .literal = content };
            return parts;
        }

        var parts_list: std.ArrayList(ast.StringPart) = .empty;
        var i: usize = 0;
        var literal_start: usize = 0;

        while (i < content.len) {
            if (i + 1 < content.len and content[i] == '#' and content[i + 1] == '{') {
                // Flush preceding literal
                if (i > literal_start) {
                    parts_list.append(self.allocator, .{ .literal = content[literal_start..i] }) catch return DslError.OutOfMemory;
                }
                // Find matching }
                var depth: u32 = 1;
                var j = i + 2;
                while (j < content.len and depth > 0) : (j += 1) {
                    if (content[j] == '{') depth += 1;
                    if (content[j] == '}') depth -= 1;
                }
                const expr_src = content[i + 2 .. j - 1];
                // Parse the expression inside #{...}
                var inner_lexer = lexer_mod.Lexer.init(expr_src);
                var inner_parser = Parser.init(self.allocator, &inner_lexer);
                const expr_node = inner_parser.parseExpression() catch {
                    // If parsing fails, treat as literal
                    parts_list.append(self.allocator, .{ .literal = content[i..j] }) catch return DslError.OutOfMemory;
                    i = j;
                    literal_start = i;
                    continue;
                };
                _ = loc;
                parts_list.append(self.allocator, .{ .interpolation = expr_node }) catch return DslError.OutOfMemory;
                i = j;
                literal_start = i;
            } else if (content[i] == '\\' and i + 1 < content.len) {
                // Skip escaped characters (keep them as literal)
                i += 2;
            } else {
                i += 1;
            }
        }

        // Flush trailing literal
        if (literal_start < content.len) {
            parts_list.append(self.allocator, .{ .literal = content[literal_start..] }) catch return DslError.OutOfMemory;
        }

        return parts_list.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
    }

    /// Parse a single arg inside a method-call arg list. Returns either a
    /// positional expression node or a block-pass payload (`&<primary>`).
    /// Block-pass is always the last arg per Ruby grammar; callers break
    /// out of their arg loop when they see one.
    const ArgOutcome = union(enum) {
        arg: *const Node,
        block_pass: *const Node,
    };

    fn parseOneArg(self: *Parser) DslError!ArgOutcome {
        if (self.current.kind == .ampersand) {
            self.advanceToken();
            const inner = try self.parsePrimary();
            return .{ .block_pass = inner };
        }
        return .{ .arg = try self.parseExpression() };
    }

    fn parseBlockParams(self: *Parser, params: *std.ArrayList([]const u8)) DslError!void {
        if (self.current.kind == .pipe) {
            self.advanceToken();
            while (self.current.kind == .identifier) {
                params.append(self.allocator, self.current.lexeme) catch return DslError.OutOfMemory;
                self.advanceToken();
                if (self.current.kind == .comma) self.advanceToken();
            }
            if (self.current.kind == .pipe) self.advanceToken();
        }
    }

    // -- Helpers --

    fn advanceToken(self: *Parser) void {
        self.current = self.lexer.next();
    }

    fn skipNewlines(self: *Parser) void {
        while (self.current.kind == .newline) {
            self.advanceToken();
        }
    }

    fn currentLoc(self: *const Parser) SourceLoc {
        return .{ .line = self.current.line, .col = self.current.col };
    }

    fn allocNode(self: *Parser, node: Node) DslError!*const Node {
        const ptr = self.allocator.create(Node) catch return DslError.OutOfMemory;
        ptr.* = node;
        return ptr;
    }

    fn makeNodePtr(self: *Parser, node: anytype) DslError!*const Node {
        // If already a pointer, return it directly
        if (@TypeOf(node) == *const Node) return node;
        // Otherwise it's a Node value — need to allocate
        return self.emitError("internal: cannot convert to node pointer");
    }

    fn emitError(self: *Parser, message: []const u8) DslError {
        self.diagnostics.append(self.allocator, .{
            .loc = self.currentLoc(),
            .message = message,
            .severity = .err,
        }) catch {};
        return DslError.ParseError;
    }

    fn isExprStart(kind: TokenKind) bool {
        return switch (kind) {
            .string_double,
            .string_single,
            .heredoc_start,
            .heredoc_body,
            .integer,
            .float_lit,
            .symbol,
            .identifier,
            .kw_true,
            .kw_false,
            .kw_nil,
            .lbracket,
            .lbrace,
            .lparen,
            .regex,
            .minus,
            .percent_w,
            .bang,
            => true,
            else => false,
        };
    }

    /// Methods where `(` should be parsed as a grouped expression, not paren-delimited args.
    /// These methods commonly appear as `cp (expr).children, dest` in Homebrew formulae.
    fn isAlwaysBareMethod(name: []const u8) bool {
        const always_bare = std.StaticStringMap(void).initComptime(.{
            .{ "cp", {} },
            .{ "cp_r", {} },
        });
        return always_bare.has(name);
    }

    fn isBareCallMethod(name: []const u8) bool {
        const bare_methods = std.StaticStringMap(void).initComptime(.{
            .{ "system", {} },
            .{ "ohai", {} },
            .{ "opoo", {} },
            .{ "odie", {} },
            .{ "mkdir_p", {} },
            .{ "rm", {} },
            .{ "rm_r", {} },
            .{ "rm_rf", {} },
            .{ "cp", {} },
            .{ "cp_r", {} },
            .{ "mv", {} },
            .{ "chmod", {} },
            .{ "touch", {} },
            .{ "ln_s", {} },
            .{ "ln_sf", {} },
            .{ "raise", {} },
            .{ "inreplace", {} },
            .{ "puts", {} },
            .{ "quiet_system", {} },
        });
        return bare_methods.has(name);
    }
};

fn parseIntValue(lexeme: []const u8) i64 {
    if (lexeme.len > 2) {
        if (lexeme[1] == 'x' or lexeme[1] == 'X') {
            return std.fmt.parseInt(i64, lexeme[2..], 16) catch 0;
        }
        if (lexeme[1] == 'o' or lexeme[1] == 'O') {
            return std.fmt.parseInt(i64, lexeme[2..], 8) catch 0;
        }
        if (lexeme[1] == 'b' or lexeme[1] == 'B') {
            return std.fmt.parseInt(i64, lexeme[2..], 2) catch 0;
        }
    }
    return std.fmt.parseInt(i64, lexeme, 10) catch 0;
}
