const std = @import("std");

pub const TokenKind = enum {
    match_kw,
    where_kw,
    and_kw,
    return_kw,
    order_kw,
    by_kw,
    asc_kw,
    desc_kw,
    limit_kw,
    identifier,
    string,
    integer,
    star,
    range,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    colon,
    dash,
    arrow_left,
    arrow_right,
    comma,
    dot,
    equal,
    less,
    less_equal,
    greater,
    greater_equal,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) !Token {
        self.skipSpace();
        if (self.pos >= self.source.len) return .{ .kind = .eof, .lexeme = "" };

        const start = self.pos;
        const c = self.source[self.pos];
        self.pos += 1;
        return switch (c) {
            '(' => .{ .kind = .l_paren, .lexeme = self.source[start..self.pos] },
            ')' => .{ .kind = .r_paren, .lexeme = self.source[start..self.pos] },
            '[' => .{ .kind = .l_bracket, .lexeme = self.source[start..self.pos] },
            ']' => .{ .kind = .r_bracket, .lexeme = self.source[start..self.pos] },
            ':' => .{ .kind = .colon, .lexeme = self.source[start..self.pos] },
            ',' => .{ .kind = .comma, .lexeme = self.source[start..self.pos] },
            '.' => blk: {
                if (self.pos < self.source.len and self.source[self.pos] == '.') {
                    self.pos += 1;
                    break :blk .{ .kind = .range, .lexeme = self.source[start..self.pos] };
                }
                break :blk .{ .kind = .dot, .lexeme = self.source[start..self.pos] };
            },
            '*' => .{ .kind = .star, .lexeme = self.source[start..self.pos] },
            '=' => .{ .kind = .equal, .lexeme = self.source[start..self.pos] },
            '-' => blk: {
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    break :blk .{ .kind = .arrow_right, .lexeme = self.source[start..self.pos] };
                }
                break :blk .{ .kind = .dash, .lexeme = self.source[start..self.pos] };
            },
            '<' => blk: {
                if (self.pos < self.source.len and self.source[self.pos] == '-') {
                    self.pos += 1;
                    break :blk .{ .kind = .arrow_left, .lexeme = self.source[start..self.pos] };
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    break :blk .{ .kind = .less_equal, .lexeme = self.source[start..self.pos] };
                }
                break :blk .{ .kind = .less, .lexeme = self.source[start..self.pos] };
            },
            '>' => blk: {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    break :blk .{ .kind = .greater_equal, .lexeme = self.source[start..self.pos] };
                }
                break :blk .{ .kind = .greater, .lexeme = self.source[start..self.pos] };
            },
            '"' => try self.string(start),
            else => blk: {
                if (isIdentStart(c)) break :blk self.identifier(start);
                if (std.ascii.isDigit(c)) break :blk self.integer(start);
                return error.UnexpectedCharacter;
            },
        };
    }

    fn skipSpace(self: *Lexer) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) {
            self.pos += 1;
        }
    }

    fn identifier(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and isIdentContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        const lexeme = self.source[start..self.pos];
        if (std.ascii.eqlIgnoreCase(lexeme, "MATCH")) return .{ .kind = .match_kw, .lexeme = lexeme };
        if (std.ascii.eqlIgnoreCase(lexeme, "WHERE")) return .{ .kind = .where_kw, .lexeme = lexeme };
        if (std.ascii.eqlIgnoreCase(lexeme, "AND")) return .{ .kind = .and_kw, .lexeme = lexeme };
        if (std.ascii.eqlIgnoreCase(lexeme, "RETURN")) return .{ .kind = .return_kw, .lexeme = lexeme };
        if (std.ascii.eqlIgnoreCase(lexeme, "ORDER")) return .{ .kind = .order_kw, .lexeme = lexeme };
        if (std.ascii.eqlIgnoreCase(lexeme, "BY")) return .{ .kind = .by_kw, .lexeme = lexeme };
        if (std.ascii.eqlIgnoreCase(lexeme, "ASC")) return .{ .kind = .asc_kw, .lexeme = lexeme };
        if (std.ascii.eqlIgnoreCase(lexeme, "DESC")) return .{ .kind = .desc_kw, .lexeme = lexeme };
        if (std.ascii.eqlIgnoreCase(lexeme, "LIMIT")) return .{ .kind = .limit_kw, .lexeme = lexeme };
        return .{ .kind = .identifier, .lexeme = lexeme };
    }

    fn integer(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.pos += 1;
        }
        return .{ .kind = .integer, .lexeme = self.source[start..self.pos] };
    }

    fn string(self: *Lexer, start: usize) !Token {
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '"') break;
            if (self.source[self.pos] == '\n' or self.source[self.pos] == '\r') return error.UnterminatedString;
            if (self.source[self.pos] == '\\') {
                self.pos += 1;
                if (self.pos >= self.source.len) return error.UnterminatedString;
            }
            self.pos += 1;
        }
        if (self.pos >= self.source.len) return error.UnterminatedString;
        self.pos += 1;
        return .{ .kind = .string, .lexeme = self.source[start + 1 .. self.pos - 1] };
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

test "lexer tokenizes simple match" {
    var lexer = Lexer.init("MATCH (n:File) RETURN n");
    try std.testing.expectEqual(TokenKind.match_kw, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.l_paren, (try lexer.next()).kind);
    try std.testing.expectEqualStrings("n", (try lexer.next()).lexeme);
}

test "lexer keeps escaped quote inside string token" {
    var lexer = Lexer.init("WHERE n.name = \"a\\\"b\"");
    try std.testing.expectEqual(TokenKind.where_kw, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.identifier, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.dot, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.identifier, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.equal, (try lexer.next()).kind);
    const string = try lexer.next();
    try std.testing.expectEqual(TokenKind.string, string.kind);
    try std.testing.expectEqualStrings("a\\\"b", string.lexeme);
}

test "lexer rejects raw newline inside string token" {
    var lexer = Lexer.init("WHERE n.name = \"a\nb\"");
    try std.testing.expectEqual(TokenKind.where_kw, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.identifier, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.dot, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.identifier, (try lexer.next()).kind);
    try std.testing.expectEqual(TokenKind.equal, (try lexer.next()).kind);
    try std.testing.expectError(error.UnterminatedString, lexer.next());
}
