//! malt -- DSL parser tests
//! Tests for AST construction from Ruby subset source.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const dsl = malt.dsl;
const Lexer = dsl.lexer.Lexer;
const Parser = dsl.parser.Parser;
const Node = dsl.ast.Node;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

fn parseSource(arena: *std.heap.ArenaAllocator, src: []const u8) ![]const *const Node {
    const alloc = arena.allocator();
    var lex = Lexer.init(src);
    var p = Parser.init(alloc, &lex);
    return p.parseBlock();
}

// ---------------------------------------------------------------------------
// Simple method calls
// ---------------------------------------------------------------------------

test "parser: bare method call with string arg" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "ohai \"hello\"");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("ohai", mc.method);
    try testing.expect(mc.receiver == null);
    try testing.expectEqual(@as(usize, 1), mc.args.len);

    // The arg should be a string literal
    const arg = mc.args[0].kind.string_literal;
    try testing.expectEqual(@as(usize, 1), arg.parts.len);
    try testing.expectEqualStrings("hello", arg.parts[0].literal);
}

test "parser: method call with parens and multiple args" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "system(\"make\", \"install\")");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("system", mc.method);
    try testing.expect(mc.receiver == null);
    try testing.expectEqual(@as(usize, 2), mc.args.len);
}

test "parser: bare method call with multiple args" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "system \"make\", \"install\"");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("system", mc.method);
    try testing.expectEqual(@as(usize, 2), mc.args.len);
}

// ---------------------------------------------------------------------------
// Path join
// ---------------------------------------------------------------------------

test "parser: path join with slash" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "bin/\"foo\"");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    // bin/"foo" parsed as: identifier bin, then / triggers path_join
    // The parser first sees `bin` as identifier then the method chain
    // catches the slash. Let's check the node kind.
    switch (nodes[0].kind) {
        .path_join => |pj| {
            try testing.expectEqualStrings("bin", pj.left.kind.identifier);
            try testing.expectEqualStrings("foo", pj.right.kind.string_literal.parts[0].literal);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Assignment
// ---------------------------------------------------------------------------

test "parser: variable assignment" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "x = bin/\"foo\"");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const assign = nodes[0].kind.assignment;
    try testing.expectEqualStrings("x", assign.name);

    // Value should be a path_join
    switch (assign.value.kind) {
        .path_join => {},
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Postfix if / unless
// ---------------------------------------------------------------------------

test "parser: postfix if" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "ohai \"msg\" if true");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .postfix_if => |pf| {
            // body is the method call
            try testing.expectEqualStrings("ohai", pf.body.kind.method_call.method);
            // condition is true
            try testing.expect(pf.condition.kind.bool_literal);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: postfix unless" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "rm \"path\" unless true");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .postfix_unless => |pu| {
            try testing.expectEqualStrings("rm", pu.body.kind.method_call.method);
            try testing.expect(pu.condition.kind.bool_literal);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Array literal
// ---------------------------------------------------------------------------

test "parser: array literal" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "[1, 2, 3]");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const arr = nodes[0].kind.array_literal;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqual(@as(i64, 1), arr[0].kind.int_literal);
    try testing.expectEqual(@as(i64, 2), arr[1].kind.int_literal);
    try testing.expectEqual(@as(i64, 3), arr[2].kind.int_literal);
}

// ---------------------------------------------------------------------------
// if/else/end block
// ---------------------------------------------------------------------------

test "parser: if else end" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\if true
        \\  ohai "yes"
        \\else
        \\  ohai "no"
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .if_else => |ie| {
            try testing.expect(ie.condition.kind.bool_literal);
            try testing.expectEqual(@as(usize, 1), ie.then_body.len);
            try testing.expect(ie.else_body != null);
            try testing.expectEqual(@as(usize, 1), ie.else_body.?.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: if without else" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\if true
        \\  ohai "yes"
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const ie = nodes[0].kind.if_else;
    try testing.expect(ie.else_body == null);
}

// ---------------------------------------------------------------------------
// unless block
// ---------------------------------------------------------------------------

test "parser: unless block" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\unless false
        \\  ohai "yes"
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .unless_statement => |us| {
            try testing.expect(!us.condition.kind.bool_literal);
            try testing.expectEqual(@as(usize, 1), us.body.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// each loop with block
// ---------------------------------------------------------------------------

test "parser: each loop with brace block" {
    var arena = testArena();
    defer arena.deinit();

    const src = "[1, 2].each { |x| ohai \"hello\" }";
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .each_loop => |el| {
            try testing.expectEqual(@as(usize, 1), el.params.len);
            try testing.expectEqualStrings("x", el.params[0]);
            try testing.expectEqual(@as(usize, 1), el.body.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: each loop with do/end block" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\[1, 2].each do |x|
        \\  ohai "hello"
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .each_loop => |el| {
            try testing.expectEqual(@as(usize, 1), el.params.len);
            try testing.expectEqualStrings("x", el.params[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// begin/rescue
// ---------------------------------------------------------------------------

test "parser: begin rescue block" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\begin
        \\  system "might_fail"
        \\rescue
        \\  ohai "rescued"
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .begin_rescue => |br| {
            try testing.expectEqual(@as(usize, 1), br.body.len);
            try testing.expectEqual(@as(usize, 1), br.rescue_body.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Receiver method call
// ---------------------------------------------------------------------------

test "parser: receiver method call" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "prefix.mkpath");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("mkpath", mc.method);
    try testing.expect(mc.receiver != null);
    try testing.expectEqualStrings("prefix", mc.receiver.?.kind.identifier);
}

// ---------------------------------------------------------------------------
// Literals
// ---------------------------------------------------------------------------

test "parser: bool literals" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "true");
    try testing.expect(nodes[0].kind.bool_literal);

    const nodes2 = try parseSource(&arena, "false");
    try testing.expect(!nodes2[0].kind.bool_literal);
}

test "parser: nil literal" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "nil");
    switch (nodes[0].kind) {
        .nil_literal => {},
        else => return error.TestUnexpectedResult,
    }
}

test "parser: integer literal" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "42");
    try testing.expectEqual(@as(i64, 42), nodes[0].kind.int_literal);
}

test "parser: hex integer parsed correctly" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "0xFF");
    try testing.expectEqual(@as(i64, 255), nodes[0].kind.int_literal);
}

test "parser: octal integer parsed correctly" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "0o755");
    try testing.expectEqual(@as(i64, 493), nodes[0].kind.int_literal);
}

// ---------------------------------------------------------------------------
// Multiple statements
// ---------------------------------------------------------------------------

test "parser: multiple statements" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\ohai "hello"
        \\ohai "world"
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 2), nodes.len);
}

// ---------------------------------------------------------------------------
// Hash literal
// ---------------------------------------------------------------------------

test "parser: hash literal" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "{ \"a\" => 1 }");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .hash_literal => |entries| {
            try testing.expectEqual(@as(usize, 1), entries.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Raise statement
// ---------------------------------------------------------------------------

test "parser: raise statement" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "raise \"boom\"");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .raise_statement => |rs| {
            try testing.expect(rs.message != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Logical operators
// ---------------------------------------------------------------------------

test "parser: logical AND" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "x.exist? && y.exist?");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .logical_and => |la| {
            // left is x.exist? (method_call)
            try testing.expectEqualStrings("exist?", la.left.kind.method_call.method);
            // right is y.exist? (method_call)
            try testing.expectEqualStrings("exist?", la.right.kind.method_call.method);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: logical OR" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "a || b");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .logical_or => |lo| {
            try testing.expectEqualStrings("a", lo.left.kind.identifier);
            try testing.expectEqualStrings("b", lo.right.kind.identifier);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: logical NOT" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "!x.exist?");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .logical_not => |operand| {
            try testing.expectEqualStrings("exist?", operand.kind.method_call.method);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: logical AND with NOT on right" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "a.exist? && !b.symlink?");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .logical_and => |la| {
            try testing.expectEqualStrings("exist?", la.left.kind.method_call.method);
            // right should be logical_not
            switch (la.right.kind) {
                .logical_not => |operand| {
                    try testing.expectEqualStrings("symlink?", operand.kind.method_call.method);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// %w word arrays
// ---------------------------------------------------------------------------

test "parser: percent_w word array" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "%w[foo bar baz]");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .array_literal => |elems| {
            try testing.expectEqual(@as(usize, 3), elems.len);
            try testing.expectEqualStrings("foo", elems[0].kind.string_literal.parts[0].literal);
            try testing.expectEqualStrings("bar", elems[1].kind.string_literal.parts[0].literal);
            try testing.expectEqualStrings("baz", elems[2].kind.string_literal.parts[0].literal);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: percent_w empty array" {
    var arena = testArena();
    defer arena.deinit();

    // Edge case for the bulk-allocation rewrite — a zero-element %w must
    // produce an empty array_literal without trying to alloc(0) and own
    // a phantom slice.
    const nodes = try parseSource(&arena, "%w[]");
    try testing.expectEqual(@as(usize, 1), nodes.len);
    switch (nodes[0].kind) {
        .array_literal => |elems| try testing.expectEqual(@as(usize, 0), elems.len),
        else => return error.TestUnexpectedResult,
    }
}

test "parser: percent_w each loop" {
    var arena = testArena();
    defer arena.deinit();

    const src = "%w[a b c].each do |x|\nohai x\nend";
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .each_loop => |el| {
            // iterable should be an array_literal
            switch (el.iterable.kind) {
                .array_literal => |arr| {
                    try testing.expectEqual(@as(usize, 3), arr.len);
                },
                else => return error.TestUnexpectedResult,
            }
            try testing.expectEqual(@as(usize, 1), el.params.len);
            try testing.expectEqualStrings("x", el.params[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Dir[] and ENV[]
// ---------------------------------------------------------------------------

test "parser: Dir glob pattern" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "Dir[\"*.txt\"]");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("Dir.glob", mc.method);
    try testing.expectEqual(@as(usize, 1), mc.args.len);
}

test "parser: Dir peek preserves heredoc lexer state" {
    var arena = testArena();
    defer arena.deinit();

    // When `Dir` is immediately followed by `<<~EOS`, parsePrimary's peek
    // for `[` calls lexer.next() which starts a heredoc and mutates
    // heredoc_terminator / heredoc_collecting. A correct peek restores
    // that state; a buggy one leaves the lexer mid-collection, so the
    // subsequent advanceToken() collects from the wrong position and
    // swallows the `<<~EOS` start marker into the body.
    const nodes = try parseSource(&arena, "Dir<<~EOS\n  body\nEOS\n");

    try testing.expectEqual(@as(usize, 2), nodes.len);
    try testing.expectEqualStrings("Dir", nodes[0].kind.identifier);

    const body = nodes[1].kind.heredoc_literal;
    try testing.expect(std.mem.indexOf(u8, body, "<<~") == null);
    try testing.expectEqualStrings("  body\n", body);
}

test "parser: Formula peek preserves heredoc lexer state" {
    var arena = testArena();
    defer arena.deinit();

    // Same invariant as the Dir peek: the `Formula[` lookahead must not
    // leak heredoc state if the peek consumes a `<<~EOS` start marker.
    const nodes = try parseSource(&arena, "Formula<<~EOS\n  body\nEOS\n");

    try testing.expectEqual(@as(usize, 2), nodes.len);
    try testing.expectEqualStrings("Formula", nodes[0].kind.identifier);

    const body = nodes[1].kind.heredoc_literal;
    try testing.expect(std.mem.indexOf(u8, body, "<<~") == null);
    try testing.expectEqualStrings("  body\n", body);
}

test "parser: ENV peek preserves heredoc lexer state" {
    var arena = testArena();
    defer arena.deinit();

    // Same invariant as the Dir peek: the `ENV[` lookahead must not
    // leak heredoc state if the peek consumes a `<<~EOS` start marker.
    const nodes = try parseSource(&arena, "ENV<<~EOS\n  body\nEOS\n");

    try testing.expectEqual(@as(usize, 2), nodes.len);
    try testing.expectEqualStrings("ENV", nodes[0].kind.identifier);

    const body = nodes[1].kind.heredoc_literal;
    try testing.expect(std.mem.indexOf(u8, body, "<<~") == null);
    try testing.expectEqualStrings("  body\n", body);
}

test "parser: ENV read" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "ENV[\"HOME\"]");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("ENV.get", mc.method);
    try testing.expectEqual(@as(usize, 1), mc.args.len);
}

test "parser: ENV write" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "ENV[\"FOO\"] = \"bar\"");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("ENV.set", mc.method);
    try testing.expectEqual(@as(usize, 2), mc.args.len);
}

// ---------------------------------------------------------------------------
// String interpolation in parser
// ---------------------------------------------------------------------------

test "parser: string with interpolation" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "\"hello #{name}\"");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const sl = nodes[0].kind.string_literal;
    // Should have 2 parts: literal "hello " and interpolation of `name`
    try testing.expectEqual(@as(usize, 2), sl.parts.len);
    try testing.expectEqualStrings("hello ", sl.parts[0].literal);
    switch (sl.parts[1]) {
        .interpolation => |node| {
            try testing.expectEqualStrings("name", node.kind.identifier);
        },
        .literal => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Postfix unless with NOT
// ---------------------------------------------------------------------------

test "parser: postfix unless with logical not" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "rm \"path\" unless !path.exist?");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .postfix_unless => |pu| {
            try testing.expectEqualStrings("rm", pu.body.kind.method_call.method);
            // condition should be logical_not
            switch (pu.condition.kind) {
                .logical_not => |operand| {
                    try testing.expectEqualStrings("exist?", operand.kind.method_call.method);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Path join with interpolated string
// ---------------------------------------------------------------------------

test "parser: path join with interpolated string" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "HOMEBREW_PREFIX/\"share/man/#{man}\"");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    switch (nodes[0].kind) {
        .path_join => |pj| {
            try testing.expectEqualStrings("HOMEBREW_PREFIX", pj.left.kind.identifier);
            // right should be a string literal with interpolation parts
            const sl = pj.right.kind.string_literal;
            try testing.expect(sl.parts.len >= 2);
            try testing.expectEqualStrings("share/man/", sl.parts[0].literal);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Multi-line system call
// ---------------------------------------------------------------------------

test "parser: multi-line system call with continuation" {
    var arena = testArena();
    defer arena.deinit();

    const src = "system \"cmd\", \"--flag\",\n  \"arg\"";
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("system", mc.method);
    try testing.expectEqual(@as(usize, 3), mc.args.len);
}

// ---------------------------------------------------------------------------
// Method definitions (`def ... end`) and `return` statements
//
// These unlock running private helpers that formulas define inside
// post_install (e.g. llvm@21's `write_config_files(...)`). Without
// them the interpreter logs every helper call as unknown_method and
// leaves the work to `--use-system-ruby`.
// ---------------------------------------------------------------------------

test "parser: empty def with no params" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\def greet
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const md = nodes[0].kind.method_def;
    try testing.expectEqualStrings("greet", md.name);
    try testing.expectEqual(@as(usize, 0), md.params.len);
    try testing.expectEqual(@as(usize, 0), md.body.len);
}

test "parser: def with positional params" {
    var arena = testArena();
    defer arena.deinit();

    // Avoid `x + y` — the DSL has no arithmetic; keep the body shape
    // minimal and focus on param binding.
    const src =
        \\def write_cfg(name, body)
        \\  (share/name).write body
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const md = nodes[0].kind.method_def;
    try testing.expectEqualStrings("write_cfg", md.name);
    try testing.expectEqual(@as(usize, 2), md.params.len);
    try testing.expectEqualStrings("name", md.params[0]);
    try testing.expectEqualStrings("body", md.params[1]);
    try testing.expect(md.body.len >= 1);
}

test "parser: def with paren-less param list" {
    // Ruby permits `def name a, b` — older formulas still use it.
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\def greet name
        \\  ohai name
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const md = nodes[0].kind.method_def;
    try testing.expectEqualStrings("greet", md.name);
    try testing.expectEqual(@as(usize, 1), md.params.len);
    try testing.expectEqualStrings("name", md.params[0]);
}

test "parser: return with value" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "return 42");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const ret = nodes[0].kind.return_statement;
    try testing.expect(ret.value != null);
    try testing.expectEqual(@as(i64, 42), ret.value.?.kind.int_literal);
}

test "parser: bare return (no value) at statement boundary" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\return
        \\ohai "after"
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 2), nodes.len);

    const ret = nodes[0].kind.return_statement;
    try testing.expect(ret.value == null);
}

test "parser: return inside postfix if" {
    var arena = testArena();
    defer arena.deinit();

    // Exact shape used in llvm@21/openssl@3 post_install guards.
    const nodes = try parseSource(&arena, "return if false");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const postfix = nodes[0].kind.postfix_if;
    switch (postfix.body.kind) {
        .return_statement => {},
        else => return error.TestUnexpectedResult,
    }
}

test "parser: def body with return short-circuit" {
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\def early(x)
        \\  return 0 if x
        \\  1
        \\end
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const md = nodes[0].kind.method_def;
    try testing.expectEqualStrings("early", md.name);
    try testing.expectEqual(@as(usize, 2), md.body.len);
    switch (md.body[0].kind) {
        .postfix_if => |pf| switch (pf.body.kind) {
            .return_statement => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Block-pass argument (&:symbol) — Ruby's symbol-to-proc shorthand.
//
// Regression: llvm@21's `post_install` uses `config_files.all?(&:exist?)`;
// the parser must accept `&<primary>` inside any arg list and expose it on
// `MethodCall.block_pass` instead of tripping "unexpected token".
// ---------------------------------------------------------------------------

test "parser: block-pass with symbol on receiver method call" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "xs.all?(&:exist?)");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("all?", mc.method);
    try testing.expectEqual(@as(usize, 0), mc.args.len);
    try testing.expect(mc.block_pass != null);
    try testing.expectEqualStrings("exist?", mc.block_pass.?.kind.symbol_literal);
}

test "parser: block-pass mixed with regular positional arg" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "xs.inject(0, &:plus)");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("inject", mc.method);
    try testing.expectEqual(@as(usize, 1), mc.args.len);
    try testing.expectEqual(@as(i64, 0), mc.args[0].kind.int_literal);
    try testing.expect(mc.block_pass != null);
    try testing.expectEqualStrings("plus", mc.block_pass.?.kind.symbol_literal);
}

test "parser: block-pass on bare paren call" {
    var arena = testArena();
    defer arena.deinit();

    const nodes = try parseSource(&arena, "foo(&:bar)");
    try testing.expectEqual(@as(usize, 1), nodes.len);

    const mc = nodes[0].kind.method_call;
    try testing.expectEqualStrings("foo", mc.method);
    try testing.expect(mc.block_pass != null);
    try testing.expectEqualStrings("bar", mc.block_pass.?.kind.symbol_literal);
}

test "parser: llvm@21 post_install snippet parses with block-pass" {
    // Distilled from llvm@21.rb — reproduces the original `unexpected token`.
    var arena = testArena();
    defer arena.deinit();

    const src =
        \\config_files = [bin/"a", bin/"b"]
        \\return if config_files.all?(&:exist?)
    ;
    const nodes = try parseSource(&arena, src);
    try testing.expectEqual(@as(usize, 2), nodes.len);

    const postfix = nodes[1].kind.postfix_if;
    const cond_mc = postfix.condition.kind.method_call;
    try testing.expectEqualStrings("all?", cond_mc.method);
    try testing.expect(cond_mc.block_pass != null);
}
