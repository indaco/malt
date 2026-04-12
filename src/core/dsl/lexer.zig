//! malt — DSL lexer
//! Ruby subset tokenizer. Zero allocation — tokens reference source slices.

const std = @import("std");

pub const TokenKind = enum {
    // Literals
    string_double,
    string_single,
    heredoc_start,
    heredoc_body,
    integer,
    float_lit,
    symbol,

    // Identifiers and keywords
    identifier,
    kw_if,
    kw_unless,
    kw_else,
    kw_elsif,
    kw_end,
    kw_do,
    kw_each,
    kw_begin,
    kw_rescue,
    kw_nil,
    kw_true,
    kw_false,
    kw_def,
    kw_raise,

    // Operators
    dot,
    double_colon,
    pipe,
    comma,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    equals,
    fat_arrow,
    question_mark,
    bang,
    slash,
    plus,
    minus,
    star,
    ampersand,
    double_amp,
    double_pipe,
    tilde,
    colon,
    less_than,
    greater_than,
    double_eq,
    not_eq,

    // Interpolation
    interp_start,
    interp_end,

    // Percent-w word arrays
    percent_w, // %w[...] or %W[...] — content between delimiters

    // Regex
    regex,

    // Structure
    newline,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: u32,
    col: u32,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    /// Track whether last meaningful token could be a value (for / disambiguation).
    last_was_value: bool,
    /// Heredoc mode state
    heredoc_terminator: ?[]const u8,
    heredoc_collecting: bool,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
            .last_was_value = false,
            .heredoc_terminator = null,
            .heredoc_collecting = false,
        };
    }

    pub fn peek(self: *Lexer) Token {
        const saved_pos = self.pos;
        const saved_line = self.line;
        const saved_col = self.col;
        const saved_lwv = self.last_was_value;
        const saved_ht = self.heredoc_terminator;
        const saved_hc = self.heredoc_collecting;

        const tok = self.next();

        self.pos = saved_pos;
        self.line = saved_line;
        self.col = saved_col;
        self.last_was_value = saved_lwv;
        self.heredoc_terminator = saved_ht;
        self.heredoc_collecting = saved_hc;

        return tok;
    }

    pub fn next(self: *Lexer) Token {
        // If in heredoc collection mode, collect until terminator
        if (self.heredoc_collecting) {
            return self.collectHeredoc();
        }

        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, "");
        }

        const c = self.source[self.pos];

        // Newlines
        if (c == '\n') {
            const tok = self.makeToken(.newline, self.source[self.pos .. self.pos + 1]);
            self.advance();
            self.line += 1;
            self.col = 1;
            self.last_was_value = false;
            return tok;
        }

        // Semicolons treated as newlines
        if (c == ';') {
            const tok = self.makeToken(.newline, self.source[self.pos .. self.pos + 1]);
            self.advance();
            self.last_was_value = false;
            return tok;
        }

        // String literals
        if (c == '"') return self.lexDoubleString();
        if (c == '\'') return self.lexSingleString();

        // Heredoc
        if (c == '<' and self.remaining() >= 3 and self.source[self.pos + 1] == '<' and self.source[self.pos + 2] == '~') {
            return self.lexHeredocStart();
        }

        // Numbers
        if (std.ascii.isDigit(c)) return self.lexNumber();

        // %w[...] / %W[...] word arrays
        if (c == '%' and self.remaining() >= 3) {
            const next_ch = self.source[self.pos + 1];
            if ((next_ch == 'w' or next_ch == 'W') and (self.source[self.pos + 2] == '[' or self.source[self.pos + 2] == '(')) {
                return self.lexPercentW();
            }
        }

        // Symbol literal :name
        if (c == ':' and self.remaining() > 1) {
            const next_c = self.source[self.pos + 1];
            if (std.ascii.isAlphabetic(next_c) or next_c == '_') {
                return self.lexSymbol();
            }
            // : alone (for hash colon syntax)
            const tok = self.makeToken(.colon, self.source[self.pos .. self.pos + 1]);
            self.advance();
            self.last_was_value = false;
            return tok;
        }

        // Identifiers and keywords
        if (std.ascii.isAlphabetic(c) or c == '_') return self.lexIdentifier();

        // Operators and punctuation
        return self.lexOperator();
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.advance();
                continue;
            }
            // Comments
            if (c == '#' and (self.pos + 1 >= self.source.len or self.source[self.pos + 1] != '{')) {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advance();
                }
                continue;
            }
            break;
        }
    }

    fn lexDoubleString(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        self.advance(); // skip opening "

        // Find the end of the string, handling escapes
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\\') {
                self.advance(); // skip escape char
                if (self.pos < self.source.len) self.advance();
                continue;
            }
            // For Phase 1 we treat #{} as part of the string literal.
            // Phase 2 will add interpolation splitting.
            self.advance();
        }

        if (self.pos < self.source.len) {
            self.advance(); // skip closing "
        }

        self.last_was_value = true;
        return .{
            .kind = .string_double,
            .lexeme = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn lexSingleString(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        self.advance(); // skip opening '

        while (self.pos < self.source.len and self.source[self.pos] != '\'') {
            if (self.source[self.pos] == '\\') {
                self.advance();
                if (self.pos < self.source.len) self.advance();
                continue;
            }
            self.advance();
        }

        if (self.pos < self.source.len) {
            self.advance(); // skip closing '
        }

        self.last_was_value = true;
        return .{
            .kind = .string_single,
            .lexeme = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn lexHeredocStart(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;

        // Skip <<~
        self.advance();
        self.advance();
        self.advance();

        // Read terminator name
        const term_start = self.pos;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.advance();
        }
        self.heredoc_terminator = self.source[term_start..self.pos];
        // Skip to end of current line
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.advance();
        }
        if (self.pos < self.source.len) {
            self.advance(); // skip newline
            self.line += 1;
            self.col = 1;
        }
        self.heredoc_collecting = true;
        self.last_was_value = false;

        return .{
            .kind = .heredoc_start,
            .lexeme = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn collectHeredoc(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        const term = self.heredoc_terminator orelse {
            self.heredoc_collecting = false;
            return self.makeToken(.eof, "");
        };

        while (self.pos < self.source.len) {
            // Check if current line is the terminator
            const line_start = self.pos;
            // Skip leading whitespace
            while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) {
                self.advance();
            }
            const content_start = self.pos;
            // Read to end of line
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                self.advance();
            }
            const line_content = self.source[content_start..self.pos];

            if (std.mem.eql(u8, line_content, term)) {
                // Found terminator
                if (self.pos < self.source.len) {
                    self.advance(); // skip \n
                    self.line += 1;
                    self.col = 1;
                }
                self.heredoc_collecting = false;
                self.heredoc_terminator = null;
                self.last_was_value = true;
                return .{
                    .kind = .heredoc_body,
                    .lexeme = self.source[start..line_start],
                    .line = start_line,
                    .col = start_col,
                };
            }

            if (self.pos < self.source.len) {
                self.advance(); // skip \n
                self.line += 1;
                self.col = 1;
            }
            // line_start used above for heredoc boundary detection
        }

        // Unterminated heredoc — return what we have
        self.heredoc_collecting = false;
        self.heredoc_terminator = null;
        self.last_was_value = true;
        return .{
            .kind = .heredoc_body,
            .lexeme = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;

        // Handle 0x, 0o, 0b prefixes
        if (self.source[self.pos] == '0' and self.remaining() > 1) {
            const prefix = self.source[self.pos + 1];
            if (prefix == 'x' or prefix == 'X' or prefix == 'o' or prefix == 'O' or prefix == 'b' or prefix == 'B') {
                self.advance();
                self.advance();
                while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
                    self.advance();
                }
                self.last_was_value = true;
                return .{
                    .kind = .integer,
                    .lexeme = self.source[start..self.pos],
                    .line = start_line,
                    .col = start_col,
                };
            }
        }

        while (self.pos < self.source.len and (std.ascii.isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.advance();
        }

        // Check for float
        if (self.pos < self.source.len and self.source[self.pos] == '.' and
            self.pos + 1 < self.source.len and std.ascii.isDigit(self.source[self.pos + 1]))
        {
            self.advance(); // skip .
            while (self.pos < self.source.len and (std.ascii.isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.advance();
            }
            self.last_was_value = true;
            return .{
                .kind = .float_lit,
                .lexeme = self.source[start..self.pos],
                .line = start_line,
                .col = start_col,
            };
        }

        self.last_was_value = true;
        return .{
            .kind = .integer,
            .lexeme = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn lexSymbol(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        self.advance(); // skip :

        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.advance();
        }
        // Allow trailing ? or !
        if (self.pos < self.source.len and (self.source[self.pos] == '?' or self.source[self.pos] == '!')) {
            self.advance();
        }

        self.last_was_value = true;
        return .{
            .kind = .symbol,
            .lexeme = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn lexIdentifier(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;

        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.advance();
        }

        // Allow trailing ? or ! for method names
        if (self.pos < self.source.len and (self.source[self.pos] == '?' or self.source[self.pos] == '!')) {
            self.advance();
        }

        const lexeme = self.source[start..self.pos];
        const kind = identifyKeyword(lexeme);
        self.last_was_value = (kind == .identifier or kind == .kw_true or kind == .kw_false or kind == .kw_nil);

        return .{
            .kind = kind,
            .lexeme = lexeme,
            .line = start_line,
            .col = start_col,
        };
    }

    fn identifyKeyword(lexeme: []const u8) TokenKind {
        const keywords = std.StaticStringMap(TokenKind).initComptime(.{
            .{ "if", .kw_if },
            .{ "unless", .kw_unless },
            .{ "else", .kw_else },
            .{ "elsif", .kw_elsif },
            .{ "end", .kw_end },
            .{ "do", .kw_do },
            .{ "each", .kw_each },
            .{ "begin", .kw_begin },
            .{ "rescue", .kw_rescue },
            .{ "nil", .kw_nil },
            .{ "true", .kw_true },
            .{ "false", .kw_false },
            .{ "def", .kw_def },
            .{ "raise", .kw_raise },
        });
        return keywords.get(lexeme) orelse .identifier;
    }

    fn lexOperator(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        const c = self.source[self.pos];

        const result: struct { kind: TokenKind, len: u8 } = switch (c) {
            '.' => .{ .kind = .dot, .len = 1 },
            '|' => blk: {
                if (self.remaining() > 1 and self.source[self.pos + 1] == '|') {
                    break :blk .{ .kind = .double_pipe, .len = 2 };
                }
                break :blk .{ .kind = .pipe, .len = 1 };
            },
            ',' => .{ .kind = .comma, .len = 1 },
            '(' => .{ .kind = .lparen, .len = 1 },
            ')' => .{ .kind = .rparen, .len = 1 },
            '[' => .{ .kind = .lbracket, .len = 1 },
            ']' => .{ .kind = .rbracket, .len = 1 },
            '{' => .{ .kind = .lbrace, .len = 1 },
            '}' => .{ .kind = .rbrace, .len = 1 },
            '+' => .{ .kind = .plus, .len = 1 },
            '-' => .{ .kind = .minus, .len = 1 },
            '*' => .{ .kind = .star, .len = 1 },
            '&' => blk: {
                if (self.remaining() > 1 and self.source[self.pos + 1] == '&') {
                    break :blk .{ .kind = .double_amp, .len = 2 };
                }
                break :blk .{ .kind = .ampersand, .len = 1 };
            },
            '~' => .{ .kind = .tilde, .len = 1 },
            '?' => .{ .kind = .question_mark, .len = 1 },
            '!' => blk: {
                if (self.remaining() > 1 and self.source[self.pos + 1] == '=') {
                    break :blk .{ .kind = .not_eq, .len = 2 };
                }
                break :blk .{ .kind = .bang, .len = 1 };
            },
            '=' => blk: {
                if (self.remaining() > 1 and self.source[self.pos + 1] == '>') {
                    break :blk .{ .kind = .fat_arrow, .len = 2 };
                }
                if (self.remaining() > 1 and self.source[self.pos + 1] == '=') {
                    break :blk .{ .kind = .double_eq, .len = 2 };
                }
                break :blk .{ .kind = .equals, .len = 1 };
            },
            '<' => .{ .kind = .less_than, .len = 1 },
            '>' => .{ .kind = .greater_than, .len = 1 },
            '/' => blk: {
                // Context-sensitive: after value token it's division/path-join,
                // otherwise it starts a regex.
                if (self.last_was_value) {
                    break :blk .{ .kind = .slash, .len = 1 };
                }
                // Lex regex
                return self.lexRegex();
            },
            ':' => blk: {
                if (self.remaining() > 1 and self.source[self.pos + 1] == ':') {
                    break :blk .{ .kind = .double_colon, .len = 2 };
                }
                break :blk .{ .kind = .colon, .len = 1 };
            },
            else => {
                // Unknown character — skip it
                self.advance();
                self.last_was_value = false;
                return self.next();
            },
        };

        var i: u8 = 0;
        while (i < result.len) : (i += 1) {
            self.advance();
        }

        // Value-producing tokens
        self.last_was_value = switch (result.kind) {
            .rparen, .rbracket, .rbrace => true,
            else => false,
        };

        return .{
            .kind = result.kind,
            .lexeme = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn lexPercentW(self: *Lexer) Token {
        const start_line = self.line;
        const start_col = self.col;
        self.advance(); // skip %
        self.advance(); // skip w/W
        const open = self.source[self.pos];
        const close: u8 = if (open == '[') ']' else ')';
        self.advance(); // skip opening delimiter
        const content_start = self.pos;

        while (self.pos < self.source.len and self.source[self.pos] != close) {
            self.advance();
        }
        const content = self.source[content_start..self.pos];
        if (self.pos < self.source.len) self.advance(); // skip closing delimiter

        self.last_was_value = true;
        return .{
            .kind = .percent_w,
            .lexeme = content,
            .line = start_line,
            .col = start_col,
        };
    }

    fn lexRegex(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        self.advance(); // skip opening /

        while (self.pos < self.source.len and self.source[self.pos] != '/') {
            if (self.source[self.pos] == '\\') {
                self.advance();
                if (self.pos < self.source.len) self.advance();
                continue;
            }
            if (self.source[self.pos] == '\n') break; // unterminated
            self.advance();
        }

        if (self.pos < self.source.len and self.source[self.pos] == '/') {
            self.advance(); // skip closing /
            // Read flags
            while (self.pos < self.source.len and std.ascii.isAlphabetic(self.source[self.pos])) {
                self.advance();
            }
        }

        self.last_was_value = true;
        return .{
            .kind = .regex,
            .lexeme = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
            self.col += 1;
        }
    }

    fn remaining(self: *const Lexer) usize {
        return self.source.len - self.pos;
    }

    fn makeToken(self: *const Lexer, kind: TokenKind, lexeme: []const u8) Token {
        return .{
            .kind = kind,
            .lexeme = lexeme,
            .line = self.line,
            .col = self.col,
        };
    }
};
