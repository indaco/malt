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

        // Assignment or expression statement
        const expr = try self.parseExpression();

        // Check for postfix if/unless
        if (self.current.kind == .kw_if) {
            self.advanceToken();
            const cond = try self.parseExpression();
            return self.allocNode(.{
                .loc = expr.loc,
                .kind = .{ .postfix_if = .{ .body = expr, .condition = cond } },
            });
        }
        if (self.current.kind == .kw_unless) {
            self.advanceToken();
            const cond = try self.parseExpression();
            return self.allocNode(.{
                .loc = expr.loc,
                .kind = .{ .postfix_unless = .{ .body = expr, .condition = cond } },
            });
        }

        return expr;
    }

    fn parseExpression(self: *Parser) DslError!*const Node {
        // Check for assignment: identifier followed by =
        if (self.current.kind == .identifier) {
            const name = self.current.lexeme;
            const loc = self.currentLoc();

            // Peek ahead to see if next non-newline token is =
            const saved_pos = self.lexer.pos;
            const saved_line = self.lexer.line;
            const saved_col = self.lexer.col;
            const saved_lwv = self.lexer.last_was_value;
            const next_tok = self.lexer.next();
            self.lexer.pos = saved_pos;
            self.lexer.line = saved_line;
            self.lexer.col = saved_col;
            self.lexer.last_was_value = saved_lwv;

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

    fn parseMethodChain(self: *Parser) DslError!*const Node {
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

        // Parse arguments
        var args: std.ArrayList(*const Node) = .empty;
        if (self.current.kind == .lparen) {
            self.advanceToken();
            while (self.current.kind != .rparen and self.current.kind != .eof) {
                self.skipNewlines();
                if (self.current.kind == .rparen) break;
                const arg = try self.parseExpression();
                args.append(self.allocator, arg) catch return DslError.OutOfMemory;
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
                const next_arg = try self.parseExpression();
                args.append(self.allocator, next_arg) catch return DslError.OutOfMemory;
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
                // %w[word1 word2 ...] — split by whitespace into string array
                const content = self.current.lexeme;
                self.advanceToken();
                var elems: std.ArrayList(*const Node) = .empty;
                var it = std.mem.tokenizeAny(u8, content, " \t\n\r");
                while (it.next()) |word| {
                    const word_node = self.allocNode(.{
                        .loc = loc,
                        .kind = .{ .string_literal = .{
                            .parts = blk: {
                                const parts = self.allocator.alloc(ast.StringPart, 1) catch return DslError.OutOfMemory;
                                parts[0] = .{ .literal = word };
                                break :blk parts;
                            },
                        } },
                    }) catch return DslError.OutOfMemory;
                    elems.append(self.allocator, word_node) catch return DslError.OutOfMemory;
                }
                const slice = elems.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
                return self.allocNode(.{
                    .loc = loc,
                    .kind = .{ .array_literal = slice },
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
                    const arg = try self.parseExpression();
                    args.append(self.allocator, arg) catch return DslError.OutOfMemory;
                    while (self.current.kind == .comma) {
                        self.advanceToken();
                        self.skipNewlines();
                        const next_arg = try self.parseExpression();
                        args.append(self.allocator, next_arg) catch return DslError.OutOfMemory;
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
                        } },
                    });
                }

                // Non-bare method call with parens: method(args)
                if (self.current.kind == .lparen) {
                    // method(args)
                    self.advanceToken();
                    var args: std.ArrayList(*const Node) = .empty;
                    while (self.current.kind != .rparen and self.current.kind != .eof) {
                        const arg = try self.parseExpression();
                        args.append(self.allocator, arg) catch return DslError.OutOfMemory;
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
                    const arg = try self.parseExpression();
                    args.append(self.allocator, arg) catch return DslError.OutOfMemory;
                    while (self.current.kind == .comma) {
                        self.advanceToken();
                        self.skipNewlines();
                        const next_arg = try self.parseExpression();
                        args.append(self.allocator, next_arg) catch return DslError.OutOfMemory;
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
                // Hash literal
                self.advanceToken();
                var entries: std.ArrayList(ast.HashEntry) = .empty;
                while (self.current.kind != .rbrace and self.current.kind != .eof) {
                    self.skipNewlines();
                    if (self.current.kind == .rbrace) break;

                    const key = try self.parseExpression();

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
