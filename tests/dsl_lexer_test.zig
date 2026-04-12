//! malt -- DSL lexer tests
//! Tests for Ruby subset tokenization.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const dsl = malt.dsl;
const Lexer = dsl.lexer.Lexer;
const TokenKind = dsl.lexer.TokenKind;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn expectToken(lex: *Lexer, expected_kind: TokenKind, expected_lexeme: []const u8) !void {
    const tok = lex.next();
    try testing.expectEqual(expected_kind, tok.kind);
    try testing.expectEqualStrings(expected_lexeme, tok.lexeme);
}

fn expectKind(lex: *Lexer, expected_kind: TokenKind) !void {
    const tok = lex.next();
    try testing.expectEqual(expected_kind, tok.kind);
}

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

test "lexer: simple identifier" {
    var lex = Lexer.init("system");
    try expectToken(&lex, .identifier, "system");
    try expectKind(&lex, .eof);
}

test "lexer: identifier with trailing question mark" {
    var lex = Lexer.init("exist?");
    try expectToken(&lex, .identifier, "exist?");
    try expectKind(&lex, .eof);
}

test "lexer: identifier with trailing bang" {
    var lex = Lexer.init("save!");
    try expectToken(&lex, .identifier, "save!");
    try expectKind(&lex, .eof);
}

test "lexer: underscore identifier" {
    var lex = Lexer.init("my_var");
    try expectToken(&lex, .identifier, "my_var");
    try expectKind(&lex, .eof);
}

// ---------------------------------------------------------------------------
// String literals
// ---------------------------------------------------------------------------

test "lexer: double-quoted string" {
    var lex = Lexer.init("\"hello\"");
    try expectToken(&lex, .string_double, "\"hello\"");
    try expectKind(&lex, .eof);
}

test "lexer: single-quoted string" {
    var lex = Lexer.init("'hello'");
    try expectToken(&lex, .string_single, "'hello'");
    try expectKind(&lex, .eof);
}

test "lexer: empty double-quoted string" {
    var lex = Lexer.init("\"\"");
    try expectToken(&lex, .string_double, "\"\"");
    try expectKind(&lex, .eof);
}

test "lexer: string with escape" {
    var lex = Lexer.init("\"he\\\"llo\"");
    try expectToken(&lex, .string_double, "\"he\\\"llo\"");
    try expectKind(&lex, .eof);
}

// ---------------------------------------------------------------------------
// Integer literals
// ---------------------------------------------------------------------------

test "lexer: decimal integer" {
    var lex = Lexer.init("42");
    try expectToken(&lex, .integer, "42");
    try expectKind(&lex, .eof);
}

test "lexer: octal integer 0o755" {
    var lex = Lexer.init("0o755");
    try expectToken(&lex, .integer, "0o755");
    try expectKind(&lex, .eof);
}

test "lexer: hex integer 0xFF" {
    var lex = Lexer.init("0xFF");
    try expectToken(&lex, .integer, "0xFF");
    try expectKind(&lex, .eof);
}

test "lexer: binary integer 0b1010" {
    var lex = Lexer.init("0b1010");
    try expectToken(&lex, .integer, "0b1010");
    try expectKind(&lex, .eof);
}

// ---------------------------------------------------------------------------
// Float literals
// ---------------------------------------------------------------------------

test "lexer: float literal" {
    var lex = Lexer.init("3.14");
    try expectToken(&lex, .float_lit, "3.14");
    try expectKind(&lex, .eof);
}

// ---------------------------------------------------------------------------
// Symbol literals
// ---------------------------------------------------------------------------

test "lexer: symbol literal" {
    var lex = Lexer.init(":my_sym");
    try expectToken(&lex, .symbol, ":my_sym");
    try expectKind(&lex, .eof);
}

// ---------------------------------------------------------------------------
// Heredoc
// ---------------------------------------------------------------------------

test "lexer: heredoc start and body" {
    const src = "<<~EOS\n  content line\nEOS\n";
    var lex = Lexer.init(src);
    try expectKind(&lex, .heredoc_start);
    try expectKind(&lex, .heredoc_body);
    try expectKind(&lex, .eof);
}

// ---------------------------------------------------------------------------
// Keywords
// ---------------------------------------------------------------------------

test "lexer: keyword if" {
    var lex = Lexer.init("if");
    try expectToken(&lex, .kw_if, "if");
}

test "lexer: keyword unless" {
    var lex = Lexer.init("unless");
    try expectToken(&lex, .kw_unless, "unless");
}

test "lexer: keyword else" {
    var lex = Lexer.init("else");
    try expectToken(&lex, .kw_else, "else");
}

test "lexer: keyword end" {
    var lex = Lexer.init("end");
    try expectToken(&lex, .kw_end, "end");
}

test "lexer: keyword do" {
    var lex = Lexer.init("do");
    try expectToken(&lex, .kw_do, "do");
}

test "lexer: keyword begin" {
    var lex = Lexer.init("begin");
    try expectToken(&lex, .kw_begin, "begin");
}

test "lexer: keyword rescue" {
    var lex = Lexer.init("rescue");
    try expectToken(&lex, .kw_rescue, "rescue");
}

test "lexer: keyword nil" {
    var lex = Lexer.init("nil");
    try expectToken(&lex, .kw_nil, "nil");
}

test "lexer: keyword true" {
    var lex = Lexer.init("true");
    try expectToken(&lex, .kw_true, "true");
}

test "lexer: keyword false" {
    var lex = Lexer.init("false");
    try expectToken(&lex, .kw_false, "false");
}

test "lexer: keyword def" {
    var lex = Lexer.init("def");
    try expectToken(&lex, .kw_def, "def");
}

test "lexer: keyword raise" {
    var lex = Lexer.init("raise");
    try expectToken(&lex, .kw_raise, "raise");
}

// ---------------------------------------------------------------------------
// Operators
// ---------------------------------------------------------------------------

test "lexer: dot operator" {
    var lex = Lexer.init(".");
    try expectToken(&lex, .dot, ".");
}

test "lexer: colon standalone" {
    // A bare ':' that is not followed by an alphanumeric char produces
    // a colon token rather than a symbol.
    var lex = Lexer.init(": foo");
    try expectToken(&lex, .colon, ":");
    try expectToken(&lex, .identifier, "foo");
}

test "lexer: equals" {
    var lex = Lexer.init("=");
    try expectToken(&lex, .equals, "=");
}

test "lexer: fat arrow" {
    var lex = Lexer.init("=>");
    try expectToken(&lex, .fat_arrow, "=>");
}

test "lexer: slash after value is division" {
    // After a value token (e.g. identifier), / is slash not regex
    var lex = Lexer.init("bin/\"foo\"");
    try expectKind(&lex, .identifier); // bin (value)
    try expectKind(&lex, .slash); // /
    try expectKind(&lex, .string_double); // "foo"
}

test "lexer: plus minus" {
    var lex = Lexer.init("+ -");
    try expectToken(&lex, .plus, "+");
    try expectToken(&lex, .minus, "-");
}

test "lexer: double equals" {
    var lex = Lexer.init("==");
    try expectToken(&lex, .double_eq, "==");
}

test "lexer: not equals" {
    var lex = Lexer.init("!=");
    try expectToken(&lex, .not_eq, "!=");
}

test "lexer: comparison operators" {
    var lex = Lexer.init("< >");
    try expectToken(&lex, .less_than, "<");
    try expectToken(&lex, .greater_than, ">");
}

test "lexer: brackets and braces" {
    var lex = Lexer.init("[]{}()");
    try expectToken(&lex, .lbracket, "[");
    try expectToken(&lex, .rbracket, "]");
    try expectToken(&lex, .lbrace, "{");
    try expectToken(&lex, .rbrace, "}");
    try expectToken(&lex, .lparen, "(");
    try expectToken(&lex, .rparen, ")");
}

test "lexer: pipe and comma" {
    var lex = Lexer.init("|,");
    try expectToken(&lex, .pipe, "|");
    try expectToken(&lex, .comma, ",");
}

// ---------------------------------------------------------------------------
// Newlines
// ---------------------------------------------------------------------------

test "lexer: newlines between statements" {
    var lex = Lexer.init("foo\nbar");
    try expectToken(&lex, .identifier, "foo");
    try expectKind(&lex, .newline);
    try expectToken(&lex, .identifier, "bar");
    try expectKind(&lex, .eof);
}

test "lexer: semicolons as newlines" {
    var lex = Lexer.init("foo;bar");
    try expectToken(&lex, .identifier, "foo");
    try expectKind(&lex, .newline);
    try expectToken(&lex, .identifier, "bar");
}

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

test "lexer: comment is skipped" {
    var lex = Lexer.init("# this is a comment\nfoo");
    try expectKind(&lex, .newline);
    try expectToken(&lex, .identifier, "foo");
}

test "lexer: inline comment" {
    var lex = Lexer.init("foo # comment\nbar");
    try expectToken(&lex, .identifier, "foo");
    try expectKind(&lex, .newline);
    try expectToken(&lex, .identifier, "bar");
}

// ---------------------------------------------------------------------------
// Regex
// ---------------------------------------------------------------------------

test "lexer: regex literal at start" {
    // At start of input, / is regex (no prior value)
    var lex = Lexer.init("/pattern/i");
    try expectToken(&lex, .regex, "/pattern/i");
    try expectKind(&lex, .eof);
}

// ---------------------------------------------------------------------------
// Compound
// ---------------------------------------------------------------------------

test "lexer: method call sequence" {
    var lex = Lexer.init("ohai \"hello\"");
    try expectToken(&lex, .identifier, "ohai");
    try expectToken(&lex, .string_double, "\"hello\"");
    try expectKind(&lex, .eof);
}

test "lexer: chained method call" {
    var lex = Lexer.init("prefix.mkpath");
    try expectToken(&lex, .identifier, "prefix");
    try expectToken(&lex, .dot, ".");
    try expectToken(&lex, .identifier, "mkpath");
    try expectKind(&lex, .eof);
}

test "lexer: path join expression" {
    var lex = Lexer.init("bin/\"foo\"");
    try expectToken(&lex, .identifier, "bin");
    try expectToken(&lex, .slash, "/");
    try expectToken(&lex, .string_double, "\"foo\"");
    try expectKind(&lex, .eof);
}

// ---------------------------------------------------------------------------
// Logical operators
// ---------------------------------------------------------------------------

test "lexer: double ampersand operator" {
    var lex = Lexer.init("a && b");
    try expectToken(&lex, .identifier, "a");
    try expectToken(&lex, .double_amp, "&&");
    try expectToken(&lex, .identifier, "b");
    try expectKind(&lex, .eof);
}

test "lexer: double pipe operator" {
    var lex = Lexer.init("a || b");
    try expectToken(&lex, .identifier, "a");
    try expectToken(&lex, .double_pipe, "||");
    try expectToken(&lex, .identifier, "b");
    try expectKind(&lex, .eof);
}

test "lexer: bang prefix" {
    var lex = Lexer.init("!x");
    try expectToken(&lex, .bang, "!");
    try expectToken(&lex, .identifier, "x");
    try expectKind(&lex, .eof);
}

test "lexer: not equals operator" {
    var lex = Lexer.init("a != b");
    try expectToken(&lex, .identifier, "a");
    try expectToken(&lex, .not_eq, "!=");
    try expectToken(&lex, .identifier, "b");
    try expectKind(&lex, .eof);
}

test "lexer: percent_w with brackets" {
    var lex = Lexer.init("%w[word1 word2]");
    try expectToken(&lex, .percent_w, "word1 word2");
    try expectKind(&lex, .eof);
}

test "lexer: percent_W with brackets" {
    var lex = Lexer.init("%W[word1 word2]");
    try expectToken(&lex, .percent_w, "word1 word2");
    try expectKind(&lex, .eof);
}

test "lexer: percent_w with parens" {
    var lex = Lexer.init("%w(word1 word2)");
    try expectToken(&lex, .percent_w, "word1 word2");
    try expectKind(&lex, .eof);
}

test "lexer: string with interpolation syntax" {
    // Lexer Phase 1 treats #{} as part of the string_double token
    var lex = Lexer.init("\"hello #{name}\"");
    try expectToken(&lex, .string_double, "\"hello #{name}\"");
    try expectKind(&lex, .eof);
}

test "lexer: double-quoted empty string" {
    var lex = Lexer.init("\"\"");
    try expectToken(&lex, .string_double, "\"\"");
    try expectKind(&lex, .eof);
}

test "lexer: consecutive operators double_amp double_pipe" {
    var lex = Lexer.init("&&||");
    try expectToken(&lex, .double_amp, "&&");
    try expectToken(&lex, .double_pipe, "||");
    try expectKind(&lex, .eof);
}

test "lexer: method with bang suffix" {
    var lex = Lexer.init("gsub!");
    try expectToken(&lex, .identifier, "gsub!");
    try expectKind(&lex, .eof);
}
