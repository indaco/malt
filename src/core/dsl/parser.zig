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
    /// Use `diagnostics()` from outside; the list is append-only internal state.
    _diagnostics: std.ArrayList(Diagnostic),
    current: Token,
    /// Recursive-descent nesting depth, bumped at every genuine recursion
    /// re-entry: parseExpression (brackets), parseUnaryNot (`!` chains), and
    /// parseBlock (statement blocks). One shared counter caps adversarial
    /// `(((…)))` / `!!!…` / nested `if…end` input before it exhausts the native
    /// stack (an uncatchable SIGSEGV), turning the abort into a catchable
    /// `ParseError` the caller can degrade on.
    depth: u32 = 0,

    /// Max nesting before a `ParseError`. No real homebrew-core formula nests
    /// anywhere near this. Kept conservative because the heaviest axis —
    /// `#{…}` interpolation — spawns a sub-parser and allocates per level, so
    /// the cap must leave ample margin under the multi-MB thread stack.
    pub const max_depth: u32 = 512;

    pub fn init(allocator: std.mem.Allocator, lex: *Lexer) Parser {
        const first = lex.next();
        return .{
            .lexer = lex,
            .allocator = allocator,
            ._diagnostics = .empty,
            .current = first,
        };
    }

    /// Read-only view of the accumulated parse diagnostics.
    pub fn diagnostics(self: *const Parser) []const Diagnostic {
        return self._diagnostics.items;
    }

    /// Parse a complete post_install block body (sequence of statements).
    pub fn parseBlock(self: *Parser) DslError![]const *const Node {
        // Nested if/unless/begin/each/def bodies recurse through here without
        // re-entering parseExpression, so cap block nesting on the same counter.
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return self.emitError("block nesting too deep");

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

    /// Optional `if`/`unless` postfix-guard wrap; used for exprs and `return`.
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
        // One of three depth choke points (with parseUnaryNot and parseBlock)
        // feeding a shared counter. This one caps bracket nesting — `()`, `[]`,
        // hash/array elements, call args all re-enter here.
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return self.emitError("expression nesting too deep");

        // Expression-form `if`/`unless` on RHS of assignment — lets
        // `x = if cond then a else b end` round-trip without call-site hacks.
        if (self.current.kind == .kw_if) return self.parseIf();
        if (self.current.kind == .kw_unless) return self.parseUnless();

        // Check for assignment: identifier followed by =
        if (self.current.kind == .identifier) {
            const name = self.current.lexeme;
            const loc = self.currentLoc();

            // Peek past newlines for `=`. All mutable lexer state — including
            // heredoc fields — must be saved, or a peek across a heredoc
            // boundary corrupts mid-collection state.
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
            // `!` self-recurses without re-entering parseExpression, so cap
            // `!!!…` chains on the shared counter or they overflow unchecked.
            self.depth += 1;
            defer self.depth -= 1;
            if (self.depth > max_depth) return self.emitError("expression nesting too deep");

            const loc = self.currentLoc();
            self.advanceToken();
            const operand = try self.parseUnaryNot();
            return self.allocNode(.{
                .loc = loc,
                .kind = .{ .logical_not = operand },
            });
        }
        return self.parseEquality();
    }

    /// `x == y` / `x != y`. Ruby precedence: higher than `&&`, lower than
    /// the relational operators. Lowered to a method_call so the
    /// interpreter's receiver-dispatch path handles both sides.
    fn parseEquality(self: *Parser) DslError!*const Node {
        var node = try self.parseRelational();
        while (true) {
            const op: ?[]const u8 = switch (self.current.kind) {
                .double_eq => "==",
                .not_eq => "!=",
                else => null,
            };
            if (op == null) break;
            const loc = self.currentLoc();
            self.advanceToken();
            const right = try self.parseRelational();
            node = try self.buildBinaryCall(node, op.?, right, loc);
        }
        return node;
    }

    /// `x < y` / `>` / `<=` / `>=`. Tighter than equality so
    /// `a < b == c` is `(a < b) == c`.
    fn parseRelational(self: *Parser) DslError!*const Node {
        var node = try self.parseMethodChain();
        while (true) {
            const op: ?[]const u8 = switch (self.current.kind) {
                .less_than => "<",
                .greater_than => ">",
                .less_eq => "<=",
                .greater_eq => ">=",
                else => null,
            };
            if (op == null) break;
            const loc = self.currentLoc();
            self.advanceToken();
            const right = try self.parseMethodChain();
            node = try self.buildBinaryCall(node, op.?, right, loc);
        }
        return node;
    }

    /// Lower a binary operator into a method_call node so the interpreter
    /// dispatches it through the same path as `<<` / `+` — keeps the AST
    /// compact and avoids a bespoke AST variant per operator.
    fn buildBinaryCall(
        self: *Parser,
        left: *const Node,
        op: []const u8,
        right: *const Node,
        loc: SourceLoc,
    ) DslError!*const Node {
        const args = self.allocator.alloc(*const Node, 1) catch return DslError.OutOfMemory;
        args[0] = right;
        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .method_call = .{
                .receiver = left,
                .method = op,
                .args = args,
                .blk = null,
                .block_params = &.{},
            } },
        });
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
            try self.parseParenArgList(&args, &block_pass);
        } else if (self.currentLooksLikeBareArg()) {
            // Bare arguments (no parens) — common for ohai, system, etc.
            try self.parseBareArgList(&args, &block_pass);
        }

        return self.finishCallWithBlock(loc, receiver, method, &args, block_pass);
    }

    /// True when the current token could open a paren-less argument list.
    fn currentLooksLikeBareArg(self: *const Parser) bool {
        const k = self.current.kind;
        return isExprStart(k) and k != .newline and k != .kw_if and
            k != .kw_unless and k != .kw_end and k != .kw_do and k != .dot;
    }

    /// Collect a paren-delimited argument list; stops at the matching
    /// `)` or on a block-pass `&<primary>`. Consumes the closing paren.
    fn parseParenArgList(
        self: *Parser,
        args: *std.ArrayList(*const Node),
        block_pass_out: *?*const Node,
    ) DslError!void {
        self.advanceToken(); // consume '('
        while (self.current.kind != .rparen and self.current.kind != .eof) {
            self.skipNewlines();
            if (self.current.kind == .rparen) break;
            switch (try self.parseOneArg()) {
                .arg => |a| {
                    // A `=>` after the arg starts an implicit trailing hash,
                    // which is terminal — the rest of the list is its pairs.
                    if (try self.maybeTrailingHash(args, a)) break;
                    args.append(self.allocator, a) catch return DslError.OutOfMemory;
                },
                .block_pass => |bp| {
                    block_pass_out.* = bp;
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
    }

    /// Collect a paren-less bare argument list (`method a, b, &:sym`).
    /// The caller has already verified `currentLooksLikeBareArg()`.
    fn parseBareArgList(
        self: *Parser,
        args: *std.ArrayList(*const Node),
        block_pass_out: *?*const Node,
    ) DslError!void {
        const first = try self.parseExpression();
        if (try self.maybeTrailingHash(args, first)) return;
        args.append(self.allocator, first) catch return DslError.OutOfMemory;
        while (self.current.kind == .comma) {
            self.advanceToken();
            self.skipNewlines();
            switch (try self.parseOneArg()) {
                .arg => |a| {
                    if (try self.maybeTrailingHash(args, a)) return;
                    args.append(self.allocator, a) catch return DslError.OutOfMemory;
                },
                .block_pass => |bp| {
                    block_pass_out.* = bp;
                    break;
                },
            }
        }
    }

    /// If the current token is `=>`, the just-parsed `key` opens an
    /// implicit trailing hash: every remaining comma-separated element is
    /// a `key => value` pair, folded into one hash_literal arg. Ruby
    /// lowers `f a, k1 => v1, k2 => v2` this way. Returns true when a hash
    /// was appended (the arg list is then terminal).
    fn maybeTrailingHash(
        self: *Parser,
        args: *std.ArrayList(*const Node),
        key: *const Node,
    ) DslError!bool {
        if (self.current.kind != .fat_arrow) return false;
        const hash = try self.parseTrailingHash(key);
        args.append(self.allocator, hash) catch return DslError.OutOfMemory;
        return true;
    }

    /// Collect `key => value (`,` key => value)*` into a hash_literal,
    /// starting from an already-parsed `first_key` sitting on `=>`. Stops
    /// at the first non-`=>` element so a malformed tail degrades instead
    /// of crashing — only one hash level is supported at this position.
    fn parseTrailingHash(self: *Parser, first_key: *const Node) DslError!*const Node {
        var entries: std.ArrayList(ast.HashEntry) = .empty;
        var key = first_key;
        while (true) {
            self.advanceToken(); // consume '=>'
            self.skipNewlines();
            const value = try self.parseExpression();
            entries.append(self.allocator, .{ .key = key, .value = value }) catch return DslError.OutOfMemory;
            if (self.current.kind != .comma) break;
            self.advanceToken(); // consume ','
            self.skipNewlines();
            // A trailing comma before the list close ends the hash.
            if (self.current.kind == .rparen or self.current.kind == .eof or
                self.current.kind == .newline) break;
            key = try self.parseExpression();
            if (self.current.kind != .fat_arrow) break;
        }
        const slice = entries.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return self.allocNode(.{
            .loc = first_key.loc,
            .kind = .{ .hash_literal = slice },
        });
    }

    /// Consume an optional `do |params| … end` or `{ |params| … }` tail
    /// and return the resulting block node, or null if neither is
    /// present. Block params are appended into `params_out`.
    fn parseOptionalBlock(
        self: *Parser,
        loc: SourceLoc,
        params_out: *std.ArrayList([]const u8),
    ) DslError!?*const Node {
        const close: TokenKind = switch (self.current.kind) {
            .kw_do => .kw_end,
            .lbrace => .rbrace,
            else => return null,
        };
        self.advanceToken();
        try self.parseBlockParams(params_out);
        const body = try self.parseBlock();
        if (self.current.kind == close) self.advanceToken();
        return try self.allocNode(.{ .loc = loc, .kind = .{ .block = body } });
    }

    /// Finalise a method_call node: handle the optional block tail and
    /// own the args / block_params slices. Shared between every call
    /// form so the ownership/cleanup pattern lives in one place.
    fn finishCallWithBlock(
        self: *Parser,
        loc: SourceLoc,
        receiver: ?*const Node,
        name: []const u8,
        args: *std.ArrayList(*const Node),
        block_pass: ?*const Node,
    ) DslError!*const Node {
        var block_params: std.ArrayList([]const u8) = .empty;
        const blk = try self.parseOptionalBlock(loc, &block_params);
        const args_slice = args.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        const params_slice = block_params.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .method_call = .{
                .receiver = receiver,
                .method = name,
                .args = args_slice,
                .blk = blk,
                .block_params = params_slice,
                .block_pass = block_pass,
            } },
        });
    }

    /// Dispatches one primary production to its form-specific helper.
    /// Each helper captures its own `loc`, advances past its tokens,
    /// and returns a fully-constructed Node. No shared mutation here.
    fn parsePrimary(self: *Parser) DslError!*const Node {
        return switch (self.current.kind) {
            .string_double => self.parseDoubleQuotedString(),
            .string_single => self.parseSingleQuotedString(),
            .percent_w => self.parsePercentWArray(),
            .heredoc_start => self.parseHeredocStart(),
            .heredoc_body => self.parseHeredocBody(),
            .integer => self.parseIntegerLit(),
            .float_lit => self.parseFloatLit(),
            .kw_true => self.parseBoolLit(true),
            .kw_false => self.parseBoolLit(false),
            .kw_nil => self.parseNilLit(),
            .symbol => self.parseSymbolLit(),
            .regex => self.parseRegexLit(),
            .identifier => self.parseIdentifierForm(),
            .lbracket => self.parseArrayLit(),
            .lbrace => self.parseHashLit(),
            .lparen => self.parseParenExpr(),
            else => self.emitError("unexpected token in expression"),
        };
    }

    fn parseDoubleQuotedString(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        const raw = self.current.lexeme;
        self.advanceToken();
        // Strip surrounding `"..."`, then lower `#{...}` into interpolation parts.
        const content = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
        const parts = try self.parseStringInterpolation(content, loc);
        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .string_literal = .{ .parts = parts } },
        });
    }

    fn parseSingleQuotedString(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        const raw = self.current.lexeme;
        self.advanceToken();
        // Single-quoted strings have no interpolation — one literal part.
        const content = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
        const parts = self.allocator.alloc(ast.StringPart, 1) catch return DslError.OutOfMemory;
        parts[0] = .{ .literal = content };
        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .string_literal = .{ .parts = parts } },
        });
    }

    fn parseHeredocStart(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken();
        const body = if (self.current.kind == .heredoc_body) self.current.lexeme else "";
        if (self.current.kind == .heredoc_body) self.advanceToken();
        return self.allocNode(.{ .loc = loc, .kind = .{ .heredoc_literal = body } });
    }

    fn parseHeredocBody(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        const body = self.current.lexeme;
        self.advanceToken();
        return self.allocNode(.{ .loc = loc, .kind = .{ .heredoc_literal = body } });
    }

    fn parseIntegerLit(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        const val = parseIntValue(self.current.lexeme);
        self.advanceToken();
        return self.allocNode(.{ .loc = loc, .kind = .{ .int_literal = val } });
    }

    fn parseFloatLit(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        const val = std.fmt.parseFloat(f64, self.current.lexeme) catch 0.0;
        self.advanceToken();
        return self.allocNode(.{ .loc = loc, .kind = .{ .float_literal = val } });
    }

    fn parseBoolLit(self: *Parser, v: bool) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken();
        return self.allocNode(.{ .loc = loc, .kind = .{ .bool_literal = v } });
    }

    fn parseNilLit(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken();
        return self.allocNode(.{ .loc = loc, .kind = .{ .nil_literal = {} } });
    }

    fn parseSymbolLit(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        const raw = self.current.lexeme;
        self.advanceToken();
        // Strip the leading `:`; the lexeme is `:name`.
        const name = if (raw.len > 1) raw[1..] else raw;
        return self.allocNode(.{ .loc = loc, .kind = .{ .symbol_literal = name } });
    }

    /// Regex literals are stored as a single-part string literal until
    /// a real regex engine is added; keeps the interpreter path uniform.
    fn parseRegexLit(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        const raw = self.current.lexeme;
        self.advanceToken();
        const parts = self.allocator.alloc(ast.StringPart, 1) catch return DslError.OutOfMemory;
        parts[0] = .{ .literal = raw };
        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .string_literal = .{ .parts = parts } },
        });
    }

    fn parsePercentWArray(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        // %w[word1 word2 ...] — split by whitespace into a string array.
        // Pre-count and bulk-allocate so a typical %w[...] costs three
        // allocs (StringParts, Nodes, *Node slice) instead of 1+2*N.
        const content = self.current.lexeme;
        self.advanceToken();

        var counter = std.mem.tokenizeAny(u8, content, " \t\n\r");
        var n: usize = 0;
        while (counter.next()) |_| n += 1;
        if (n == 0) {
            const empty: []const *const Node = &.{};
            return self.allocNode(.{ .loc = loc, .kind = .{ .array_literal = empty } });
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
        return self.allocNode(.{ .loc = loc, .kind = .{ .array_literal = elems } });
    }

    fn parseArrayLit(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken(); // '['
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
        return self.allocNode(.{ .loc = loc, .kind = .{ .array_literal = slice } });
    }

    fn parseHashLit(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        self.advanceToken(); // '{'
        var entries: std.ArrayList(ast.HashEntry) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            self.skipNewlines();
            if (self.current.kind == .rbrace) break;

            // Ruby's `{ name: value }` shorthand lowers to a symbol key —
            // recognise `identifier:` (single colon, not `::`) so the
            // identifier does not resolve as a method at eval time.
            const key_loc = self.currentLoc();
            var key: *const Node = undefined;
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
                // Not shorthand — rewind and re-parse as a full expression.
                self.lexer.* = lex_before;
                self.current = self.lexer.next();
            }

            key = try self.parseExpression();
            if (self.current.kind == .fat_arrow or self.current.kind == .colon) {
                self.advanceToken();
            }

            const value = try self.parseExpression();
            entries.append(self.allocator, .{ .key = key, .value = value }) catch return DslError.OutOfMemory;
            self.skipNewlines();
            if (self.current.kind == .comma) self.advanceToken();
        }
        if (self.current.kind == .rbrace) self.advanceToken();
        const slice = entries.toOwnedSlice(self.allocator) catch return DslError.OutOfMemory;
        return self.allocNode(.{ .loc = loc, .kind = .{ .hash_literal = slice } });
    }

    fn parseParenExpr(self: *Parser) DslError!*const Node {
        self.advanceToken(); // '('
        const inner = try self.parseExpression();
        if (self.current.kind == .rparen) self.advanceToken();
        return inner;
    }

    /// An identifier at expression position can be a plain reference,
    /// a call (bare, paren, or always-bare), or an `X[...]` index form
    /// for the built-in pseudo-modules `Dir`, `Formula`, `ENV`.
    fn parseIdentifierForm(self: *Parser) DslError!*const Node {
        const loc = self.currentLoc();
        const name = self.current.lexeme;

        // `lexer.peek()` saves every field `next()` may mutate —
        // including heredoc state — so a `Dir<<~EOS` peek restores
        // cleanly instead of leaving the lexer mid-collection.
        if (std.mem.eql(u8, name, "Dir") and self.lexer.peek().kind == .lbracket)
            return self.parseDirIndex(loc);
        if (std.mem.eql(u8, name, "Formula") and self.lexer.peek().kind == .lbracket)
            return self.parseFormulaIndex(loc);
        if (std.mem.eql(u8, name, "ENV") and self.lexer.peek().kind == .lbracket)
            return self.parseEnvIndex(loc);

        self.advanceToken(); // consume identifier

        // Always-bare methods (`cp`, `cp_r`) must be checked before the
        // lparen arm so `cp (expr).method, dest` keeps `(expr)` grouped
        // instead of consuming `(...)` as a paren-arg list.
        const starts_bare = self.currentLooksLikeBareArg();
        if (isAlwaysBareMethod(name) and starts_bare) return self.parseBareMethodCall(loc, name);
        if (self.current.kind == .lparen) return self.parseParenCall(loc, name);
        if (isBareCallMethod(name) and starts_bare) return self.parseBareMethodCall(loc, name);

        return self.allocNode(.{ .loc = loc, .kind = .{ .identifier = name } });
    }

    /// Build a bare (no receiver, no block) method_call node — shared
    /// by the Dir/Formula/ENV index rewrites.
    fn makeStaticMethodCall(
        self: *Parser,
        loc: SourceLoc,
        name: []const u8,
        args: []const *const Node,
    ) DslError!*const Node {
        return self.allocNode(.{
            .loc = loc,
            .kind = .{ .method_call = .{
                .receiver = null,
                .method = name,
                .args = args,
                .blk = null,
                .block_params = &.{},
            } },
        });
    }

    /// `Dir[expr, expr, ...]` → `Dir.glob(expr, expr, ...)`.
    fn parseDirIndex(self: *Parser, loc: SourceLoc) DslError!*const Node {
        self.advanceToken(); // 'Dir'
        self.advanceToken(); // '['
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
        return self.makeStaticMethodCall(loc, "Dir.glob", args_slice);
    }

    /// `Formula[name]` → `Formula.lookup(name)`.
    fn parseFormulaIndex(self: *Parser, loc: SourceLoc) DslError!*const Node {
        self.advanceToken(); // 'Formula'
        self.advanceToken(); // '['
        const name_expr = try self.parseExpression();
        if (self.current.kind == .rbracket) self.advanceToken();
        const args = self.allocator.alloc(*const Node, 1) catch return DslError.OutOfMemory;
        args[0] = name_expr;
        return self.makeStaticMethodCall(loc, "Formula.lookup", args);
    }

    /// `ENV[key]` reads → `ENV.get(key)`; `ENV[key] = value` writes
    /// → `ENV.set(key, value)`.
    fn parseEnvIndex(self: *Parser, loc: SourceLoc) DslError!*const Node {
        self.advanceToken(); // 'ENV'
        self.advanceToken(); // '['
        const key_expr = try self.parseExpression();
        if (self.current.kind == .rbracket) self.advanceToken();

        if (self.current.kind == .equals) {
            self.advanceToken();
            const val_expr = try self.parseExpression();
            const args = self.allocator.alloc(*const Node, 2) catch return DslError.OutOfMemory;
            args[0] = key_expr;
            args[1] = val_expr;
            return self.makeStaticMethodCall(loc, "ENV.set", args);
        }

        const args = self.allocator.alloc(*const Node, 1) catch return DslError.OutOfMemory;
        args[0] = key_expr;
        return self.makeStaticMethodCall(loc, "ENV.get", args);
    }

    /// Paren-delimited call: `name(args)`.
    fn parseParenCall(self: *Parser, loc: SourceLoc, name: []const u8) DslError!*const Node {
        var args: std.ArrayList(*const Node) = .empty;
        var block_pass: ?*const Node = null;
        try self.parseParenArgList(&args, &block_pass);
        return self.finishCallWithBlock(loc, null, name, &args, block_pass);
    }

    /// Bare (paren-less) call: `name a, b [&:sym] [do |x| … end]`.
    /// Used for both always-bare methods (cp, cp_r) and bare-capable
    /// methods (system, ohai, …).
    fn parseBareMethodCall(self: *Parser, loc: SourceLoc, name: []const u8) DslError!*const Node {
        var args: std.ArrayList(*const Node) = .empty;
        var block_pass: ?*const Node = null;
        try self.parseBareArgList(&args, &block_pass);
        return self.finishCallWithBlock(loc, null, name, &args, block_pass);
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
                .condition = elsif_cond,
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
                .condition = condition,
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
                .condition = condition,
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

    /// Collect a comma-separated ident list for `def` params; unknown tokens
    /// stop the loop and degrade the formula to `--use-system-ruby`.
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
                // Carry the depth budget so nested `#{…}` interpolation can't
                // reset it — a fresh sub-parser would otherwise start at 0 and
                // let deeply nested interpolation recurse past the cap.
                inner_parser.depth = self.depth;
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

    /// Parse one arg; `&<primary>` yields a block-pass (always last per
    /// Ruby grammar, callers break on it).
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

    fn emitError(self: *Parser, message: []const u8) DslError {
        // OOM here means we lose one diagnostic entry; ParseError still propagates.
        self._diagnostics.append(self.allocator, .{
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
            .{ "rm_f", {} },
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

// Adversarial deeply-nested input must hit the depth cap and surface a
// bounded `ParseError` with a diagnostic — never recurse into a native
// stack overflow. Balanced parens so that, without the guard, the body
// would parse cleanly; the guard is what converts it into an error.
test "parser: expression nesting beyond the depth limit is a bounded ParseError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = Parser.max_depth + 50;
    const src = try alloc.alloc(u8, n * 2 + 1);
    @memset(src[0..n], '(');
    src[n] = '1';
    @memset(src[n + 1 ..], ')');

    var lex = Lexer.init(src);
    var p = Parser.init(alloc, &lex);
    try std.testing.expectError(DslError.ParseError, p.parseBlock());

    var found = false;
    for (p.diagnostics()) |d| {
        if (std.mem.indexOf(u8, d.message, "nesting too deep") != null) found = true;
    }
    try std.testing.expect(found);
}

// `!` self-recurses in parseUnaryNot without re-entering parseExpression, so a
// `!!!…` chain bypasses the bracket guard. It must hit the shared cap instead
// of overflowing the native stack.
test "parser: unary-not chain beyond the depth limit is a bounded ParseError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = Parser.max_depth + 50;
    const src = try alloc.alloc(u8, n + 1);
    @memset(src[0..n], '!');
    src[n] = '1';

    var lex = Lexer.init(src);
    var p = Parser.init(alloc, &lex);
    try std.testing.expectError(DslError.ParseError, p.parseBlock());

    var found = false;
    for (p.diagnostics()) |d| {
        if (std.mem.indexOf(u8, d.message, "nesting too deep") != null) found = true;
    }
    try std.testing.expect(found);
}

// Nested if/unless/begin/each/def bodies recurse through parseBlock, not
// parseExpression — the condition's expression returns before the body
// descends. Deeply nested `if … end` must hit the shared cap, not overflow.
test "parser: block nesting beyond the depth limit is a bounded ParseError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `if 1\n` repeated — the guard fires mid-descent, before any matching end.
    const n = Parser.max_depth + 50;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i < n) : (i += 1) try buf.appendSlice(alloc, "if 1\n");

    var lex = Lexer.init(buf.items);
    var p = Parser.init(alloc, &lex);
    try std.testing.expectError(DslError.ParseError, p.parseBlock());

    var found = false;
    for (p.diagnostics()) |d| {
        if (std.mem.indexOf(u8, d.message, "nesting too deep") != null) found = true;
    }
    try std.testing.expect(found);
}

// No false positives: nesting at a depth no real formula approaches — across
// all three axes combined — must parse cleanly with no diagnostics.
test "parser: legitimate moderate nesting parses without tripping the guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 100 nested parens + a `!` + an if/end block: far deeper than any real
    // post_install, yet well under the cap.
    const k = 100;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "if !");
    try buf.appendNTimes(alloc, '(', k);
    try buf.appendSlice(alloc, "1");
    try buf.appendNTimes(alloc, ')', k);
    try buf.appendSlice(alloc, "\nohai \"ok\"\nend\n");

    var lex = Lexer.init(buf.items);
    var p = Parser.init(alloc, &lex);
    const nodes = try p.parseBlock();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics().len);
}

// Anti-regression: the counter must decrement on return, so many *sequential*
// (closed, non-nested) blocks far exceeding the cap never trip the guard — a
// missing decrement would falsely reject ordinary multi-statement formulas.
test "parser: sequential blocks past the cap do not trip the guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = Parser.max_depth + 200;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i < n) : (i += 1) try buf.appendSlice(alloc, "if 1\nohai \"x\"\nend\n");

    var lex = Lexer.init(buf.items);
    var p = Parser.init(alloc, &lex);
    const nodes = try p.parseBlock();
    try std.testing.expectEqual(@as(usize, n), nodes.len);
    try std.testing.expectEqual(@as(usize, 0), p.diagnostics().len);
}

// `#{…}` interpolation parses its inner expression with a fresh sub-parser; the
// depth budget is carried into it so deeply nested interpolation can't reset
// the counter and recurse unbounded. Running this without that carry overflows
// the native stack and aborts the runner, so completion *is* the proof.
test "parser: deeply nested interpolation stays bounded and does not overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // N levels of `"#{ … }"` nested inside each other, past the cap.
    const n = Parser.max_depth + 200;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i < n) : (i += 1) try buf.appendSlice(alloc, "\"#{");
    try buf.appendSlice(alloc, "1");
    i = 0;
    while (i < n) : (i += 1) try buf.appendSlice(alloc, "}\"");

    var lex = Lexer.init(buf.items);
    var p = Parser.init(alloc, &lex);
    // The guard fires deep inside, is caught at the interpolation boundary and
    // collapses to a literal, so the top-level parse completes — no crash.
    const nodes = try p.parseBlock();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
}
