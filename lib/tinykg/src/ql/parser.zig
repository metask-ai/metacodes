const std = @import("std");
const core = @import("../core.zig");
const ast = @import("ast.zig");
const lex = @import("lexer.zig");

pub const Parser = struct {
    lexer: lex.Lexer,
    current: lex.Token,

    pub fn init(source: []const u8) !Parser {
        var lexer = lex.Lexer.init(source);
        const first = try lexer.next();
        return .{ .lexer = lexer, .current = first };
    }

    pub fn parse(self: *Parser, allocator: std.mem.Allocator) !ast.Query {
        try self.expect(.match_kw);
        var owned_strings = std.ArrayList([]u8).empty;
        errdefer freeOwnedStringList(allocator, &owned_strings);

        var text_pattern: ?ast.TextPattern = null;
        var start = if (self.current.kind == .identifier and std.ascii.eqlIgnoreCase(self.current.lexeme, "TEXT")) blk: {
            text_pattern = try self.parseTextPattern(allocator, &owned_strings);
            break :blk ast.NodePattern{ .var_name = text_pattern.?.var_name, .kind = text_pattern.?.kind, .type_label = text_pattern.?.type_label };
        } else try self.parseNodePattern(allocator, &owned_strings);
        var segments = std.ArrayList(ast.PatternSegment).empty;
        errdefer segments.deinit(allocator);
        if (text_pattern != null and self.current.kind == .match_kw) {
            try self.advance();
            start = try self.parseNodePattern(allocator, &owned_strings);
            if (!std.mem.eql(u8, start.var_name, text_pattern.?.var_name)) return error.TextPatternStartMismatch;
        }
        while (self.current.kind == .dash or self.current.kind == .arrow_left) {
            const segment = try self.parsePatternSegment(allocator, &owned_strings);
            try segments.append(allocator, segment);
        }
        const pattern = ast.Pattern{
            .start = start,
            .segments = try segments.toOwnedSlice(allocator),
        };
        errdefer allocator.free(pattern.segments);

        var predicates = std.ArrayList(ast.Predicate).empty;
        errdefer predicates.deinit(allocator);
        if (self.current.kind == .where_kw) {
            try self.advance();
            while (true) {
                try predicates.append(allocator, try self.parsePredicate(allocator, &owned_strings));
                if (self.current.kind != .and_kw) break;
                try self.advance();
            }
        }
        const owned_predicates = try predicates.toOwnedSlice(allocator);
        errdefer allocator.free(owned_predicates);

        try self.expect(.return_kw);
        var returns = std.ArrayList(ast.Projection).empty;
        errdefer returns.deinit(allocator);
        while (true) {
            try returns.append(allocator, try self.parseProjection(allocator, &owned_strings));
            if (self.current.kind != .comma) break;
            try self.advance();
        }

        const order_by = if (self.current.kind == .order_kw)
            try self.parseOrderBy(allocator, &owned_strings)
        else
            null;

        var limit: ?usize = null;
        if (self.current.kind == .limit_kw) {
            try self.advance();
            const limit_text = self.current.lexeme;
            try self.expect(.integer);
            limit = try parseLimitValue(limit_text);
        }
        try self.expect(.eof);

        const owned_returns = try returns.toOwnedSlice(allocator);
        errdefer allocator.free(owned_returns);
        const owned_string_slice: []const []u8 = if (owned_strings.items.len == 0) &.{} else try owned_strings.toOwnedSlice(allocator);
        errdefer freeOwnedStringSlice(allocator, owned_string_slice);

        return .{
            .pattern = pattern,
            .text_pattern = text_pattern,
            .where_predicates = owned_predicates,
            .returns = owned_returns,
            .order_by = order_by,
            .limit = limit,
            .owned_strings = owned_string_slice,
        };
    }

    fn parseTextPattern(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) !ast.TextPattern {
        try self.expect(.identifier);
        const query_text = try self.parseStringValue(allocator, owned_strings);
        try self.expect(.string);
        if (!(self.current.kind == .identifier and std.ascii.eqlIgnoreCase(self.current.lexeme, "AS"))) return error.UnexpectedToken;
        try self.advance();
        const var_name = try ownLexeme(allocator, owned_strings, self.current.lexeme);
        try self.expect(.identifier);
        var kind: ?core.NodeKind = null;
        var type_label: ?[]const u8 = null;
        if (self.current.kind == .colon) {
            try self.advance();
            type_label = try ownLexeme(allocator, owned_strings, self.current.lexeme);
            kind = core.parseNodeKind(self.current.lexeme);
            try self.expect(.identifier);
        }
        return .{ .query = query_text, .var_name = var_name, .kind = kind, .type_label = type_label };
    }

    fn parseNodePattern(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) !ast.NodePattern {
        try self.expect(.l_paren);
        const var_name = try ownLexeme(allocator, owned_strings, self.current.lexeme);
        try self.expect(.identifier);
        var kind: ?core.NodeKind = null;
        var type_label: ?[]const u8 = null;
        if (self.current.kind == .colon) {
            try self.advance();
            type_label = try ownLexeme(allocator, owned_strings, self.current.lexeme);
            kind = core.parseNodeKind(self.current.lexeme);
            try self.expect(.identifier);
        }
        try self.expect(.r_paren);
        return .{ .var_name = var_name, .kind = kind, .type_label = type_label };
    }

    fn parseEdgePattern(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) !ast.EdgePattern {
        try self.expect(.l_bracket);
        var var_name: ?[]const u8 = null;
        var rel: ?core.RelKind = null;
        var rel_label: ?[]const u8 = null;
        if (self.current.kind == .identifier) {
            var_name = try ownLexeme(allocator, owned_strings, self.current.lexeme);
            try self.advance();
        }
        if (self.current.kind == .colon) {
            try self.advance();
            rel_label = try ownLexeme(allocator, owned_strings, self.current.lexeme);
            rel = core.parseRelKind(self.current.lexeme);
            try self.expect(.identifier);
        }
        var min_hops: u8 = 1;
        var max_hops: u8 = 1;
        if (self.current.kind == .star) {
            try self.advance();
            min_hops = try self.parseHopBound();
            try self.expect(.range);
            max_hops = try self.parseHopBound();
            if (max_hops < min_hops) return error.InvalidHopRange;
        }
        try self.expect(.r_bracket);
        return .{ .var_name = var_name, .rel = rel, .rel_label = rel_label, .min_hops = min_hops, .max_hops = max_hops };
    }

    fn parsePatternSegment(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) !ast.PatternSegment {
        var direction: ast.EdgeDirection = .outgoing;
        if (self.current.kind == .arrow_left) {
            try self.advance();
            var edge = try self.parseEdgePattern(allocator, owned_strings);
            try self.expect(.dash);
            edge.direction = .incoming;
            const right = try self.parseNodePattern(allocator, owned_strings);
            return .{ .edge = edge, .right = right };
        }

        try self.expect(.dash);
        var edge = try self.parseEdgePattern(allocator, owned_strings);
        switch (self.current.kind) {
            .arrow_right => {
                try self.advance();
                direction = .outgoing;
            },
            .dash => {
                try self.advance();
                direction = .undirected;
            },
            else => return error.UnexpectedToken,
        }
        edge.direction = direction;
        const right = try self.parseNodePattern(allocator, owned_strings);
        return .{ .edge = edge, .right = right };
    }

    fn parsePredicate(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) !ast.Predicate {
        const var_name = try ownLexeme(allocator, owned_strings, self.current.lexeme);
        try self.expect(.identifier);
        try self.expect(.dot);
        const property = try ownLexeme(allocator, owned_strings, self.current.lexeme);
        try self.expect(.identifier);
        const op = try self.parsePredicateOperator();
        const value = try self.parsePredicateValue(allocator, owned_strings);
        return .{ .var_name = var_name, .property = property, .op = op, .value = value };
    }

    fn parsePredicateOperator(self: *Parser) !ast.PredicateOperator {
        return switch (self.current.kind) {
            .equal => blk: {
                try self.advance();
                break :blk .eq;
            },
            .less => blk: {
                try self.advance();
                break :blk .lt;
            },
            .less_equal => blk: {
                try self.advance();
                break :blk .lte;
            },
            .greater => blk: {
                try self.advance();
                break :blk .gt;
            },
            .greater_equal => blk: {
                try self.advance();
                break :blk .gte;
            },
            else => error.UnexpectedToken,
        };
    }

    fn parsePredicateValue(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) ![]const u8 {
        if (self.current.kind == .integer) {
            const value = try ownLexeme(allocator, owned_strings, self.current.lexeme);
            try self.advance();
            return value;
        }
        const value = try self.parseStringValue(allocator, owned_strings);
        try self.expect(.string);
        return value;
    }

    fn parseStringValue(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) ![]const u8 {
        if (std.mem.indexOfScalar(u8, self.current.lexeme, '\\') == null) {
            return ownLexeme(allocator, owned_strings, self.current.lexeme);
        }
        const decoded = try unescapeString(allocator, self.current.lexeme);
        errdefer allocator.free(decoded);
        try owned_strings.append(allocator, decoded);
        return decoded;
    }

    fn parseProjection(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) !ast.Projection {
        const var_name = self.current.lexeme;
        try self.expect(.identifier);
        if (self.current.kind == .l_paren) {
            try self.advance();
            if (std.ascii.eqlIgnoreCase(var_name, "path")) {
                const from_var = try ownLexeme(allocator, owned_strings, self.current.lexeme);
                try self.expect(.identifier);
                try self.expect(.comma);
                const to_var = try ownLexeme(allocator, owned_strings, self.current.lexeme);
                try self.expect(.identifier);
                try self.expect(.r_paren);
                return .{ .path = .{ .from_var = from_var, .to_var = to_var } };
            }
            if (std.ascii.eqlIgnoreCase(var_name, "reachable")) {
                const from_var = try ownLexeme(allocator, owned_strings, self.current.lexeme);
                try self.expect(.identifier);
                try self.expect(.comma);
                const to_var = try ownLexeme(allocator, owned_strings, self.current.lexeme);
                try self.expect(.identifier);
                try self.expect(.comma);
                const rel = core.parseRelKind(self.current.lexeme) orelse return error.UnknownRelationKind;
                try self.expect(.identifier);
                try self.expect(.r_paren);
                return .{ .reachable = .{ .from_var = from_var, .to_var = to_var, .rel = rel } };
            }
            if (std.ascii.eqlIgnoreCase(var_name, "context")) {
                const focus_var = try ownLexeme(allocator, owned_strings, self.current.lexeme);
                try self.expect(.identifier);
                try self.expect(.r_paren);
                return .{ .context = .{ .var_name = focus_var } };
            }
            if (std.ascii.eqlIgnoreCase(var_name, "score")) {
                const scored_var = try ownLexeme(allocator, owned_strings, self.current.lexeme);
                try self.expect(.identifier);
                try self.expect(.r_paren);
                return .{ .score = .{ .var_name = scored_var } };
            }
            return error.UnknownFunction;
        }
        if (self.current.kind == .dot) {
            const owned_var_name = try ownLexeme(allocator, owned_strings, var_name);
            try self.advance();
            const property = try ownLexeme(allocator, owned_strings, self.current.lexeme);
            try self.expect(.identifier);
            return .{ .property = .{ .var_name = owned_var_name, .property = property } };
        }
        return .{ .variable = try ownLexeme(allocator, owned_strings, var_name) };
    }

    fn parseOrderBy(self: *Parser, allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8)) !ast.OrderBy {
        try self.expect(.order_kw);
        try self.expect(.by_kw);
        const var_name = try ownLexeme(allocator, owned_strings, self.current.lexeme);
        try self.expect(.identifier);
        try self.expect(.dot);
        const property = try ownLexeme(allocator, owned_strings, self.current.lexeme);
        try self.expect(.identifier);
        var direction: ast.OrderDirection = .asc;
        if (self.current.kind == .asc_kw) {
            try self.advance();
            direction = .asc;
        } else if (self.current.kind == .desc_kw) {
            try self.advance();
            direction = .desc;
        }
        return .{ .var_name = var_name, .property = property, .direction = direction };
    }

    fn expect(self: *Parser, kind: lex.TokenKind) !void {
        if (self.current.kind != kind) return error.UnexpectedToken;
        try self.advance();
    }

    fn parseHopBound(self: *Parser) !u8 {
        const text = self.current.lexeme;
        try self.expect(.integer);
        const value = std.fmt.parseInt(u8, text, 10) catch return error.InvalidHopRange;
        if (value == 0) return error.InvalidHopRange;
        return value;
    }

    fn advance(self: *Parser) !void {
        self.current = try self.lexer.next();
    }
};

fn parseLimitValue(text: []const u8) !usize {
    return std.fmt.parseInt(usize, text, 10) catch return error.InvalidLimit;
}

fn freeOwnedStringList(allocator: std.mem.Allocator, strings: *std.ArrayList([]u8)) void {
    for (strings.items) |string| allocator.free(string);
    strings.deinit(allocator);
}

fn freeOwnedStringSlice(allocator: std.mem.Allocator, strings: []const []u8) void {
    for (strings) |string| allocator.free(string);
    if (strings.len != 0) allocator.free(strings);
}

fn ownLexeme(allocator: std.mem.Allocator, owned_strings: *std.ArrayList([]u8), lexeme: []const u8) ![]const u8 {
    const owned = try allocator.dupe(u8, lexeme);
    errdefer allocator.free(owned);
    try owned_strings.append(allocator, owned);
    return owned;
}

fn unescapeString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const byte = raw[i];
        if (byte != '\\') {
            try out.append(allocator, byte);
            continue;
        }
        i += 1;
        if (i >= raw.len) return error.InvalidStringEscape;
        const escaped: u8 = switch (raw[i]) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => return error.InvalidStringEscape,
        };
        try out.append(allocator, escaped);
    }
    return out.toOwnedSlice(allocator);
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ast.Query {
    var parser = try Parser.init(source);
    return parser.parse(allocator);
}

test "parser parses edge match with predicate and limit" {
    const query = try parse(std.testing.allocator, "MATCH (f:file)-[:defines]->(s:function) WHERE f.text = \"src/main.zig\" RETURN s LIMIT 10");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqual(@as(usize, 10), query.limit.?);
    try std.testing.expectEqualStrings("s", query.returns[0].variable);
    try std.testing.expectEqual(core.RelKind.defines, query.pattern.segments[0].edge.rel.?);
}

test "parser parses edge variable match predicate" {
    const query = try parse(std.testing.allocator, "MATCH (a:document)-[e:references]->(b:observation) WHERE e.created_by = \"agent\" RETURN b LIMIT 10");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqualStrings("e", query.pattern.segments[0].edge.var_name.?);
    try std.testing.expectEqual(core.RelKind.references, query.pattern.segments[0].edge.rel.?);
    try std.testing.expectEqualStrings("e", query.where_predicates[0].var_name);
    try std.testing.expectEqualStrings("created_by", query.where_predicates[0].property);
}

test "parser parses property projection" {
    const query = try parse(std.testing.allocator, "MATCH (n:File) RETURN n.summary LIMIT 1");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqualStrings("n", query.returns[0].property.var_name);
    try std.testing.expectEqualStrings("summary", query.returns[0].property.property);
}

test "parser parses multi-hop and variable range edge" {
    const query = try parse(std.testing.allocator, "MATCH (a:task)-[:depends_on*1..3]->(b:task)-[:blocks]->(c:task) RETURN c");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqual(@as(usize, 2), query.pattern.segments.len);
    try std.testing.expectEqual(@as(u8, 1), query.pattern.segments[0].edge.min_hops);
    try std.testing.expectEqual(@as(u8, 3), query.pattern.segments[0].edge.max_hops);
}

test "parser parses multiple where predicates" {
    const query = try parse(std.testing.allocator, "MATCH (a:File)-[:DEFINES]->(b:Function) WHERE a.text = \"src/main.zig\" AND b.text = \"main\" RETURN a, b");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqual(@as(usize, 2), query.where_predicates.len);
    try std.testing.expectEqual(core.NodeKind.file, query.pattern.start.kind.?);
    try std.testing.expectEqual(core.RelKind.defines, query.pattern.segments[0].edge.rel.?);
}

test "parser parses numeric range predicate" {
    const query = try parse(std.testing.allocator, "MATCH (n:command) WHERE n.task_recorded_ns >= 42 RETURN n");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqual(@as(usize, 1), query.where_predicates.len);
    try std.testing.expectEqual(ast.PredicateOperator.gte, query.where_predicates[0].op);
    try std.testing.expectEqualStrings("42", query.where_predicates[0].value);
}

test "parser parses order by property" {
    const query = try parse(std.testing.allocator, "MATCH (n:command) WHERE n.task_event_ns >= 42 RETURN n.text ORDER BY n.task_event_ns ASC LIMIT 5");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqualStrings("n", query.order_by.?.var_name);
    try std.testing.expectEqualStrings("task_event_ns", query.order_by.?.property);
    try std.testing.expectEqual(ast.OrderDirection.asc, query.order_by.?.direction);
    try std.testing.expectEqual(@as(usize, 5), query.limit.?);
}

test "parser preserves custom node and relation labels" {
    const query = try parse(std.testing.allocator, "MATCH (h:Human)-[:Supports]->(m:Memory) RETURN m");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expect(query.pattern.start.kind == null);
    try std.testing.expectEqualStrings("Human", query.pattern.start.type_label.?);
    try std.testing.expect(query.pattern.segments[0].edge.rel == null);
    try std.testing.expectEqualStrings("Supports", query.pattern.segments[0].edge.rel_label.?);
    try std.testing.expectEqualStrings("Memory", query.pattern.segments[0].right.type_label.?);
}

test "parser decodes escaped string predicates" {
    const query = try parse(std.testing.allocator, "MATCH (f:File) WHERE f.text = \"src/\\\"main\\\"\\\\test.zig\" RETURN f");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqualStrings("src/\"main\"\\test.zig", query.where_predicates[0].value);
}

test "parser decodes escaped newline but rejects raw newline in string predicates" {
    const query = try parse(std.testing.allocator, "MATCH (f:File) WHERE f.text = \"line\\nb\" RETURN f");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqualStrings("line\nb", query.where_predicates[0].value);

    try std.testing.expectError(
        error.UnterminatedString,
        parse(std.testing.allocator, "MATCH (f:File) WHERE f.text = \"line\nb\" RETURN f"),
    );
}

test "parser rejects invalid string escape" {
    try std.testing.expectError(
        error.InvalidStringEscape,
        parse(std.testing.allocator, "MATCH (f:File) WHERE f.text = \"bad\\x\" RETURN f"),
    );
}

test "parser parses incoming and undirected edge patterns" {
    const incoming = try parse(std.testing.allocator, "MATCH (fn:Function)<-[:DEFINES]-(f:File) RETURN f");
    defer ast.freeQuery(std.testing.allocator, incoming);
    try std.testing.expectEqual(ast.EdgeDirection.incoming, incoming.pattern.segments[0].edge.direction);

    const undirected = try parse(std.testing.allocator, "MATCH (a:Task)-[:RELATED_TO]-(b:Task) RETURN b");
    defer ast.freeQuery(std.testing.allocator, undirected);
    try std.testing.expectEqual(ast.EdgeDirection.undirected, undirected.pattern.segments[0].edge.direction);
}

test "parser parses path projection" {
    const query = try parse(std.testing.allocator, "MATCH (a:Task)-[:DEPENDS_ON*1..3]->(b:Task) RETURN path(a,b)");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqual(ast.Projection.path, std.meta.activeTag(query.returns[0]));
    try std.testing.expectEqualStrings("a", query.returns[0].path.from_var);
    try std.testing.expectEqualStrings("b", query.returns[0].path.to_var);
}

test "parser parses reachable projection" {
    const query = try parse(std.testing.allocator, "MATCH (a:Task)-[:DEPENDS_ON]->(b:Task) RETURN reachable(a,b,DEPENDS_ON)");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqual(ast.Projection.reachable, std.meta.activeTag(query.returns[0]));
    try std.testing.expectEqual(core.RelKind.depends_on, query.returns[0].reachable.rel);
}

test "parser parses context projection" {
    const query = try parse(std.testing.allocator, "MATCH (n:Function) RETURN context(n)");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expectEqual(ast.Projection.context, std.meta.activeTag(query.returns[0]));
    try std.testing.expectEqualStrings("n", query.returns[0].context.var_name);
}

test "parser parses text match with score projection" {
    const query = try parse(std.testing.allocator, "MATCH TEXT \"edge index\" AS n:Task RETURN n, score(n) LIMIT 5");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expect(query.text_pattern != null);
    try std.testing.expectEqualStrings("edge index", query.text_pattern.?.query);
    try std.testing.expectEqualStrings("n", query.text_pattern.?.var_name);
    try std.testing.expectEqual(core.NodeKind.task, query.text_pattern.?.kind.?);
    try std.testing.expectEqual(ast.Projection.score, std.meta.activeTag(query.returns[1]));
}

test "parser parses text match followed by graph expansion" {
    const query = try parse(std.testing.allocator, "MATCH TEXT \"edge index\" AS o MATCH (o)-[:EVIDENCES]->(t:Task) RETURN t, score(o) LIMIT 5");
    defer ast.freeQuery(std.testing.allocator, query);
    try std.testing.expect(query.text_pattern != null);
    try std.testing.expectEqualStrings("o", query.pattern.start.var_name);
    try std.testing.expectEqual(@as(usize, 1), query.pattern.segments.len);
    try std.testing.expectEqual(core.RelKind.evidences, query.pattern.segments[0].edge.rel.?);
}

test "parser rejects text match followed by different start variable" {
    try std.testing.expectError(
        error.TextPatternStartMismatch,
        parse(std.testing.allocator, "MATCH TEXT \"edge index\" AS o MATCH (n)-[:EVIDENCES]->(t:Task) RETURN t, score(o) LIMIT 5"),
    );
}

test "parser result owns identifiers and string literals independent of source buffer" {
    const source = try std.testing.allocator.dupe(u8, "MATCH TEXT \"edge index\" AS o MATCH (o)-[:EVIDENCES]->(t:Task) WHERE t.text = \"repair\" RETURN t.text, score(o) LIMIT 5");
    defer std.testing.allocator.free(source);

    const query = try parse(std.testing.allocator, source);
    defer ast.freeQuery(std.testing.allocator, query);

    try std.testing.expect(!sliceInside(query.text_pattern.?.query, source));
    try std.testing.expect(!sliceInside(query.text_pattern.?.var_name, source));
    try std.testing.expect(!sliceInside(query.pattern.start.var_name, source));
    try std.testing.expect(!sliceInside(query.pattern.segments[0].right.var_name, source));
    try std.testing.expect(!sliceInside(query.where_predicates[0].var_name, source));
    try std.testing.expect(!sliceInside(query.where_predicates[0].property, source));
    try std.testing.expect(!sliceInside(query.where_predicates[0].value, source));
    try std.testing.expect(!sliceInside(query.returns[0].property.var_name, source));
    try std.testing.expect(!sliceInside(query.returns[0].property.property, source));
    try std.testing.expect(!sliceInside(query.returns[1].score.var_name, source));
}

test "parser frees owned pattern when later syntax fails" {
    try std.testing.expectError(
        error.UnexpectedToken,
        parse(std.testing.allocator, "MATCH (a:Task)-[:DEPENDS_ON]->(b:Task) WHERE a.text = \"x\""),
    );
}

test "parser frees owned predicates when return parsing fails" {
    try std.testing.expectError(
        error.UnexpectedToken,
        parse(std.testing.allocator, "MATCH (a:Task) WHERE a.text = \"x\" RETURN path(a,)"),
    );
}

fn parserAllocationFailure(allocator: std.mem.Allocator) !void {
    const query = try parse(allocator, "MATCH TEXT \"edge\\nindex\" AS o MATCH (o)-[:EVIDENCES]->(t:Task) WHERE t.text = \"repair\" RETURN t.text, score(o), path(o,t) LIMIT 5");
    defer ast.freeQuery(allocator, query);
    try std.testing.expect(query.text_pattern != null);
    try std.testing.expectEqualStrings("edge\nindex", query.text_pattern.?.query);
    try std.testing.expectEqual(@as(usize, 3), query.returns.len);
}

test "parser rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parserAllocationFailure, .{});
}

fn sliceInside(slice: []const u8, owner: []const u8) bool {
    const ptr = @intFromPtr(slice.ptr);
    const start = @intFromPtr(owner.ptr);
    return ptr >= start and ptr < start + owner.len;
}
