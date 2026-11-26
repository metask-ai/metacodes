//! Bounded TOML 1.0 reader for interoperability with other agents' config files
//! (Codex `config.toml`). It builds a read-only tree in the caller's arena.
//!
//! Supported: tables, dotted and quoted keys, arrays of tables, inline tables,
//! arrays (multi-line, nested, trailing comma), basic / literal / multi-line
//! strings with every escape, decimal / hex / octal / binary integers with
//! underscores, floats (including inf/nan), booleans and the four date-time
//! forms (kept as their source text). Redefining a key or table is an error,
//! as the specification requires.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    /// Offset date-time, local date-time, local date or local time, verbatim.
    datetime: []const u8,
    array: []const Value,
    table: *Table,

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .table => |table| table.get(key),
            else => null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |value| value,
            else => null,
        };
    }
};

pub const Table = struct {
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(Value) = .empty,
    /// Defined by a `[header]` (or implicitly by a dotted header path) rather
    /// than by an inline table / dotted key, which may not be reopened.
    origin: Origin = .implicit,

    pub const Origin = enum { implicit, header, dotted, inline_table, array_element };

    pub fn get(self: *const Table, key: []const u8) ?Value {
        for (self.keys.items, self.values.items) |existing, value| {
            if (std.mem.eql(u8, existing, key)) return value;
        }
        return null;
    }

    fn indexOf(self: *const Table, key: []const u8) ?usize {
        for (self.keys.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, key)) return index;
        }
        return null;
    }

    pub fn count(self: *const Table) usize {
        return self.keys.items.len;
    }
};

pub const Limits = struct {
    max_bytes: usize = 4 * 1024 * 1024,
    max_depth: u16 = 64,
};

pub const Error = error{ OutOfMemory, InvalidToml };

pub const Diagnostic = struct {
    line: usize = 0,
};

/// Parse a document into its root table.
pub fn parse(arena: std.mem.Allocator, source: []const u8, limits: Limits, diagnostic: ?*Diagnostic) Error!*Table {
    if (source.len > limits.max_bytes) return error.InvalidToml;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidToml;
    const root = try arena.create(Table);
    root.* = .{ .origin = .header };
    var parser = Parser{ .arena = arena, .source = source, .root = root, .current = root, .limits = limits };
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) parser.index = 3;
    parser.parseDocument() catch |err| {
        if (diagnostic) |out| out.line = parser.line();
        return err;
    };
    return root;
}

const Parser = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,
    root: *Table,
    current: *Table,
    limits: Limits,

    fn line(self: *const Parser) usize {
        return std.mem.count(u8, self.source[0..@min(self.index, self.source.len)], "\n") + 1;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.index < self.source.len) self.source[self.index] else null;
    }

    fn skipBlanks(self: *Parser) void {
        while (self.peek()) |byte| {
            if (byte != ' ' and byte != '\t') return;
            self.index += 1;
        }
    }

    fn skipComment(self: *Parser) Error!void {
        if (self.peek() != '#') return;
        while (self.peek()) |byte| {
            if (byte == '\n') return;
            if ((byte < 0x20 and byte != '\t') or byte == 0x7f) {
                if (byte == '\r' and self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
                    self.index += 1;
                    continue;
                }
                return error.InvalidToml;
            }
            self.index += 1;
        }
    }

    /// After a statement: optional blanks and comment, then newline or EOF.
    fn expectLineEnd(self: *Parser) Error!void {
        self.skipBlanks();
        try self.skipComment();
        if (self.peek()) |byte| {
            if (byte == '\n') {
                self.index += 1;
                return;
            }
            if (byte == '\r' and self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
                self.index += 2;
                return;
            }
            return error.InvalidToml;
        }
    }

    /// Skip whitespace, newlines and comments (inside arrays).
    fn skipWhitespaceAndComments(self: *Parser) Error!void {
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\t', '\n' => self.index += 1,
                '\r' => {
                    if (self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
                        self.index += 2;
                    } else return error.InvalidToml;
                },
                '#' => try self.skipComment(),
                else => return,
            }
        }
    }

    fn parseDocument(self: *Parser) Error!void {
        while (true) {
            self.skipBlanks();
            const byte = self.peek() orelse return;
            switch (byte) {
                '\n', '\r', '#' => try self.expectLineEnd(),
                '[' => {
                    try self.parseHeader();
                    try self.expectLineEnd();
                },
                else => {
                    try self.parseKeyValue(self.current, 0);
                    try self.expectLineEnd();
                },
            }
        }
    }

    fn parseHeader(self: *Parser) Error!void {
        self.index += 1;
        const array_of_tables = self.peek() == '[';
        if (array_of_tables) self.index += 1;
        self.skipBlanks();
        const path = try self.parseKeyPath();
        self.skipBlanks();
        if (self.peek() != ']') return error.InvalidToml;
        self.index += 1;
        if (array_of_tables) {
            if (self.peek() != ']') return error.InvalidToml;
            self.index += 1;
        }

        var table = self.root;
        for (path[0 .. path.len - 1]) |key| table = try self.descend(table, key, .header_path);
        const last = path[path.len - 1];
        if (array_of_tables) {
            const element = try self.arena.create(Table);
            element.* = .{ .origin = .array_element };
            if (table.indexOf(last)) |index| {
                const existing = table.values.items[index];
                // Only an array of tables created by `[[...]]` may be extended.
                const items = switch (existing) {
                    .array => |items| items,
                    else => return error.InvalidToml,
                };
                if (items.len == 0 or items[0] != .table or items[0].table.origin != .array_element)
                    return error.InvalidToml;
                const grown = try self.arena.alloc(Value, items.len + 1);
                @memcpy(grown[0..items.len], items);
                grown[items.len] = .{ .table = element };
                table.values.items[index] = .{ .array = grown };
            } else {
                const items = try self.arena.alloc(Value, 1);
                items[0] = .{ .table = element };
                try table.keys.append(self.arena, last);
                try table.values.append(self.arena, .{ .array = items });
            }
            self.current = element;
            return;
        }
        if (table.indexOf(last)) |index| {
            const existing = table.values.items[index];
            const child = switch (existing) {
                .table => |child| child,
                else => return error.InvalidToml,
            };
            // A table may be declared once; one created implicitly by a
            // longer header path may still be declared explicitly.
            if (child.origin != .implicit) return error.InvalidToml;
            child.origin = .header;
            self.current = child;
            return;
        }
        const child = try self.arena.create(Table);
        child.* = .{ .origin = .header };
        try table.keys.append(self.arena, last);
        try table.values.append(self.arena, .{ .table = child });
        self.current = child;
    }

    const DescendMode = enum { header_path, dotted_key };

    /// Walk into (or create) the table `key` of `table` for a header path or a
    /// dotted key, enforcing which kinds of tables may be reopened.
    fn descend(self: *Parser, table: *Table, key: []const u8, mode: DescendMode) Error!*Table {
        if (table.indexOf(key)) |index| {
            switch (table.values.items[index]) {
                .table => |child| {
                    if (child.origin == .inline_table) return error.InvalidToml;
                    if (mode == .dotted_key and child.origin == .header) return error.InvalidToml;
                    return child;
                },
                .array => |items| {
                    // `[a.b]` after `[[a]]` addresses the last element.
                    if (mode != .header_path or items.len == 0 or items[items.len - 1] != .table or
                        items[items.len - 1].table.origin != .array_element)
                        return error.InvalidToml;
                    return items[items.len - 1].table;
                },
                else => return error.InvalidToml,
            }
        }
        const child = try self.arena.create(Table);
        child.* = .{ .origin = if (mode == .dotted_key) .dotted else .implicit };
        try table.keys.append(self.arena, key);
        try table.values.append(self.arena, .{ .table = child });
        return child;
    }

    fn parseKeyPath(self: *Parser) Error![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipBlanks();
            try parts.append(self.arena, try self.parseSimpleKey());
            self.skipBlanks();
            if (self.peek() != '.') break;
            self.index += 1;
        }
        return parts.toOwnedSlice(self.arena);
    }

    fn parseSimpleKey(self: *Parser) Error![]const u8 {
        const byte = self.peek() orelse return error.InvalidToml;
        switch (byte) {
            '"' => {
                if (std.mem.startsWith(u8, self.source[self.index..], "\"\"\"")) return error.InvalidToml;
                return self.parseBasicString();
            },
            '\'' => {
                if (std.mem.startsWith(u8, self.source[self.index..], "'''")) return error.InvalidToml;
                return self.parseLiteralString();
            },
            else => {
                const start = self.index;
                while (self.peek()) |current| {
                    if (!(std.ascii.isAlphanumeric(current) or current == '_' or current == '-')) break;
                    self.index += 1;
                }
                if (self.index == start) return error.InvalidToml;
                return self.source[start..self.index];
            },
        }
    }

    fn parseKeyValue(self: *Parser, table: *Table, depth: usize) Error!void {
        const path = try self.parseKeyPath();
        self.skipBlanks();
        if (self.peek() != '=') return error.InvalidToml;
        self.index += 1;
        self.skipBlanks();
        const value = try self.parseValue(depth + 1);
        var target = table;
        for (path[0 .. path.len - 1]) |key| target = try self.descend(target, key, .dotted_key);
        const last = path[path.len - 1];
        if (target.indexOf(last) != null) return error.InvalidToml;
        try target.keys.append(self.arena, last);
        try target.values.append(self.arena, value);
    }

    fn parseValue(self: *Parser, depth: usize) Error!Value {
        if (depth > self.limits.max_depth) return error.InvalidToml;
        const byte = self.peek() orelse return error.InvalidToml;
        const rest = self.source[self.index..];
        switch (byte) {
            '"' => {
                if (std.mem.startsWith(u8, rest, "\"\"\"")) return .{ .string = try self.parseMultilineBasic() };
                return .{ .string = try self.parseBasicString() };
            },
            '\'' => {
                if (std.mem.startsWith(u8, rest, "'''")) return .{ .string = try self.parseMultilineLiteral() };
                return .{ .string = try self.parseLiteralString() };
            },
            '[' => return self.parseArray(depth),
            '{' => return self.parseInlineTable(depth),
            't' => {
                if (std.mem.startsWith(u8, rest, "true") and isValueEnd(rest, 4)) {
                    self.index += 4;
                    return .{ .boolean = true };
                }
                return error.InvalidToml;
            },
            'f' => {
                if (std.mem.startsWith(u8, rest, "false") and isValueEnd(rest, 5)) {
                    self.index += 5;
                    return .{ .boolean = false };
                }
                return error.InvalidToml;
            },
            else => return self.parseNumberOrDate(),
        }
    }

    fn parseArray(self: *Parser, depth: usize) Error!Value {
        self.index += 1;
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            try self.skipWhitespaceAndComments();
            if (self.peek() == ']') {
                self.index += 1;
                break;
            }
            try items.append(self.arena, try self.parseValue(depth + 1));
            try self.skipWhitespaceAndComments();
            const separator = self.peek() orelse return error.InvalidToml;
            switch (separator) {
                ',' => self.index += 1,
                ']' => {
                    self.index += 1;
                    break;
                },
                else => return error.InvalidToml,
            }
        }
        return .{ .array = try items.toOwnedSlice(self.arena) };
    }

    fn parseInlineTable(self: *Parser, depth: usize) Error!Value {
        self.index += 1;
        const table = try self.arena.create(Table);
        table.* = .{ .origin = .inline_table };
        self.skipBlanks();
        if (self.peek() == '}') {
            self.index += 1;
            return .{ .table = table };
        }
        while (true) {
            self.skipBlanks();
            try self.parseKeyValue(table, depth);
            self.skipBlanks();
            const separator = self.peek() orelse return error.InvalidToml;
            self.index += 1;
            switch (separator) {
                ',' => continue,
                '}' => break,
                else => return error.InvalidToml,
            }
        }
        // Dotted keys inside an inline table build tables that are part of it.
        sealInline(table);
        return .{ .table = table };
    }

    fn parseBasicString(self: *Parser) Error![]const u8 {
        self.index += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const byte = self.peek() orelse return error.InvalidToml;
            switch (byte) {
                '"' => {
                    self.index += 1;
                    return out.toOwnedSlice(self.arena);
                },
                '\\' => try self.parseEscape(&out),
                '\n', '\r' => return error.InvalidToml,
                else => {
                    if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidToml;
                    try out.append(self.arena, byte);
                    self.index += 1;
                },
            }
        }
    }

    fn parseLiteralString(self: *Parser) Error![]const u8 {
        self.index += 1;
        const start = self.index;
        while (true) {
            const byte = self.peek() orelse return error.InvalidToml;
            if (byte == '\'') break;
            if (byte == '\n' or byte == '\r' or (byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidToml;
            self.index += 1;
        }
        const value = self.source[start..self.index];
        self.index += 1;
        return value;
    }

    fn parseMultilineBasic(self: *Parser) Error![]const u8 {
        self.index += 3;
        self.skipLeadingNewline();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const rest = self.source[self.index..];
            if (rest.len == 0) return error.InvalidToml;
            if (std.mem.startsWith(u8, rest, "\"\"\"")) {
                // Up to two quotes may sit right before the closing delimiter.
                var quotes: usize = 3;
                while (quotes < 5 and quotes < rest.len and rest[quotes] == '"') quotes += 1;
                try out.appendNTimes(self.arena, '"', quotes - 3);
                self.index += quotes;
                return out.toOwnedSlice(self.arena);
            }
            const byte = rest[0];
            if (byte == '\\') {
                // Line-ending backslash: trim the newline and following whitespace.
                var probe = self.index + 1;
                while (probe < self.source.len and (self.source[probe] == ' ' or self.source[probe] == '\t')) probe += 1;
                if (probe < self.source.len and (self.source[probe] == '\n' or self.source[probe] == '\r')) {
                    self.index = probe;
                    while (self.peek()) |current| {
                        if (current != ' ' and current != '\t' and current != '\n' and current != '\r') break;
                        self.index += 1;
                    }
                    continue;
                }
                try self.parseEscape(&out);
                continue;
            }
            if (byte == '\r') {
                if (rest.len < 2 or rest[1] != '\n') return error.InvalidToml;
                self.index += 1;
                continue;
            }
            if ((byte < 0x20 and byte != '\t' and byte != '\n') or byte == 0x7f) return error.InvalidToml;
            try out.append(self.arena, byte);
            self.index += 1;
        }
    }

    fn parseMultilineLiteral(self: *Parser) Error![]const u8 {
        self.index += 3;
        self.skipLeadingNewline();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const rest = self.source[self.index..];
            if (rest.len == 0) return error.InvalidToml;
            if (std.mem.startsWith(u8, rest, "'''")) {
                var quotes: usize = 3;
                while (quotes < 5 and quotes < rest.len and rest[quotes] == '\'') quotes += 1;
                try out.appendNTimes(self.arena, '\'', quotes - 3);
                self.index += quotes;
                return out.toOwnedSlice(self.arena);
            }
            const byte = rest[0];
            if (byte == '\r') {
                if (rest.len < 2 or rest[1] != '\n') return error.InvalidToml;
                self.index += 1;
                continue;
            }
            if ((byte < 0x20 and byte != '\t' and byte != '\n') or byte == 0x7f) return error.InvalidToml;
            try out.append(self.arena, byte);
            self.index += 1;
        }
    }

    fn skipLeadingNewline(self: *Parser) void {
        if (std.mem.startsWith(u8, self.source[self.index..], "\r\n")) {
            self.index += 2;
        } else if (self.peek() == '\n') {
            self.index += 1;
        }
    }

    fn parseEscape(self: *Parser, out: *std.ArrayList(u8)) Error!void {
        if (self.index + 1 >= self.source.len) return error.InvalidToml;
        const escape = self.source[self.index + 1];
        self.index += 2;
        switch (escape) {
            'b' => try out.append(self.arena, 0x08),
            't' => try out.append(self.arena, '\t'),
            'n' => try out.append(self.arena, '\n'),
            'f' => try out.append(self.arena, 0x0c),
            'r' => try out.append(self.arena, '\r'),
            'e' => try out.append(self.arena, 0x1b),
            '"' => try out.append(self.arena, '"'),
            '\\' => try out.append(self.arena, '\\'),
            'u', 'U' => {
                const digits: usize = if (escape == 'u') 4 else 8;
                if (self.index + digits > self.source.len) return error.InvalidToml;
                const codepoint = std.fmt.parseInt(u21, self.source[self.index .. self.index + digits], 16) catch
                    return error.InvalidToml;
                self.index += digits;
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidToml;
                try out.appendSlice(self.arena, buffer[0..length]);
            },
            else => return error.InvalidToml,
        }
    }

    fn parseNumberOrDate(self: *Parser) Error!Value {
        const start = self.index;
        while (self.peek()) |byte| {
            const part_of_token = std.ascii.isAlphanumeric(byte) or switch (byte) {
                '+', '-', '_', '.', ':' => true,
                // A space joins a date to its time ("1979-05-27 07:32:00").
                ' ' => self.index + 1 < self.source.len and std.ascii.isDigit(self.source[self.index + 1]) and
                    looksLikeDate(self.source[start..self.index]),
                else => false,
            };
            if (!part_of_token) break;
            self.index += 1;
        }
        const token = self.source[start..self.index];
        if (token.len == 0) return error.InvalidToml;
        if (looksLikeDate(token) or looksLikeTime(token)) return .{ .datetime = token };
        if (parseInteger(token)) |integer| return .{ .integer = integer };
        if (parseFloat(token)) |float| return .{ .float = float };
        return error.InvalidToml;
    }
};

fn sealInline(table: *Table) void {
    table.origin = .inline_table;
    for (table.values.items) |value| {
        if (value == .table) sealInline(value.table);
    }
}

fn isValueEnd(rest: []const u8, length: usize) bool {
    if (rest.len == length) return true;
    return switch (rest[length]) {
        ' ', '\t', '\n', '\r', ',', ']', '}', '#' => true,
        else => false,
    };
}

fn looksLikeDate(token: []const u8) bool {
    return token.len >= 10 and std.ascii.isDigit(token[0]) and std.ascii.isDigit(token[3]) and
        token[4] == '-' and token[7] == '-';
}

fn looksLikeTime(token: []const u8) bool {
    return token.len >= 8 and std.ascii.isDigit(token[0]) and token[2] == ':' and token[5] == ':';
}

fn validUnderscores(digits: []const u8, comptime isDigit: fn (u8) bool) bool {
    if (digits.len == 0) return false;
    for (digits, 0..) |byte, index| {
        if (byte == '_') {
            if (index == 0 or index + 1 == digits.len) return false;
            if (!isDigit(digits[index - 1]) or !isDigit(digits[index + 1])) return false;
        } else if (!isDigit(byte)) return false;
    }
    return true;
}

fn isDecimal(byte: u8) bool {
    return std.ascii.isDigit(byte);
}
fn isHex(byte: u8) bool {
    return std.ascii.isHex(byte);
}
fn isOctal(byte: u8) bool {
    return byte >= '0' and byte <= '7';
}
fn isBinary(byte: u8) bool {
    return byte == '0' or byte == '1';
}

fn stripUnderscores(buffer: []u8, digits: []const u8) []const u8 {
    var length: usize = 0;
    for (digits) |byte| {
        if (byte == '_') continue;
        buffer[length] = byte;
        length += 1;
    }
    return buffer[0..length];
}

fn parseInteger(token: []const u8) ?i64 {
    var buffer: [128]u8 = undefined;
    if (token.len > buffer.len) return null;
    if (token.len > 2 and token[0] == '0' and (token[1] == 'x' or token[1] == 'o' or token[1] == 'b')) {
        const digits = token[2..];
        const base: u8, const ok = switch (token[1]) {
            'x' => .{ 16, validUnderscores(digits, isHex) },
            'o' => .{ 8, validUnderscores(digits, isOctal) },
            else => .{ 2, validUnderscores(digits, isBinary) },
        };
        if (!ok) return null;
        return std.fmt.parseInt(i64, stripUnderscores(&buffer, digits), base) catch null;
    }
    const unsigned = if (token[0] == '+' or token[0] == '-') token[1..] else token;
    if (!validUnderscores(unsigned, isDecimal)) return null;
    if (unsigned.len > 1 and unsigned[0] == '0') return null;
    return std.fmt.parseInt(i64, stripUnderscores(&buffer, token), 10) catch null;
}

fn parseFloat(token: []const u8) ?f64 {
    const unsigned = if (token[0] == '+' or token[0] == '-') token[1..] else token;
    if (std.mem.eql(u8, unsigned, "inf")) return if (token[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    if (std.mem.eql(u8, unsigned, "nan")) return std.math.nan(f64);
    // Integer part, optional fraction, optional exponent; underscores only
    // between digits; a leading zero only on its own.
    var exponent_split = std.mem.indexOfAny(u8, unsigned, "eE");
    const mantissa = unsigned[0 .. exponent_split orelse unsigned.len];
    if (exponent_split) |split| {
        var exponent = unsigned[split + 1 ..];
        if (exponent.len != 0 and (exponent[0] == '+' or exponent[0] == '-')) exponent = exponent[1..];
        if (!validUnderscores(exponent, isDecimal)) return null;
    } else exponent_split = null;
    const dot = std.mem.indexOfScalar(u8, mantissa, '.');
    const integer_part = mantissa[0 .. dot orelse mantissa.len];
    if (!validUnderscores(integer_part, isDecimal)) return null;
    if (integer_part.len > 1 and integer_part[0] == '0') return null;
    if (dot) |position| {
        if (!validUnderscores(mantissa[position + 1 ..], isDecimal)) return null;
    } else if (exponent_split == null) return null;
    var buffer: [128]u8 = undefined;
    if (token.len > buffer.len) return null;
    return std.fmt.parseFloat(f64, stripUnderscores(&buffer, token)) catch null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn parseForTest(arena: *std.heap.ArenaAllocator, source: []const u8) Error!*Table {
    return parse(arena.allocator(), source, .{}, null);
}

test "Codex-shaped config: nested tables, quoted names, inline tables, arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parseForTest(&arena,
        \\model = "gpt-5" # comment
        \\[mcp_servers.knowforge]
        \\command = "python3"
        \\args = ["/a/server.py", 'C:\raw\path']
        \\startup_timeout_sec = 30.0
        \\
        \\[mcp_servers.knowforge.env]
        \\TOKEN = "x\u4e2d"
        \\
        \\[mcp_servers."my.server"]
        \\url = "https://example.com/mcp"
        \\enabled = false
        \\http_headers = { "X-Team" = "a", Authorization = "Bearer t" }
        \\env_vars = [
        \\  "PATH",   # trailing comment
        \\  { name = "TOKEN", source = "local" },
        \\]
        \\
        \\[projects."/Users/me/repo"]
        \\trust_level = "trusted"
    );
    try testing.expectEqualStrings("gpt-5", root.get("model").?.asString().?);
    const servers = root.get("mcp_servers").?;
    const knowforge = servers.get("knowforge").?;
    try testing.expectEqualStrings("python3", knowforge.get("command").?.asString().?);
    try testing.expectEqualStrings("C:\\raw\\path", knowforge.get("args").?.array[1].asString().?);
    try testing.expectEqual(@as(f64, 30.0), knowforge.get("startup_timeout_sec").?.float);
    try testing.expectEqualStrings("x中", knowforge.get("env").?.get("TOKEN").?.asString().?);
    const dotted = servers.get("my.server").?;
    try testing.expect(!dotted.get("enabled").?.boolean);
    try testing.expectEqualStrings("Bearer t", dotted.get("http_headers").?.get("Authorization").?.asString().?);
    try testing.expectEqual(@as(usize, 2), dotted.get("env_vars").?.array.len);
    try testing.expectEqualStrings("trusted", root.get("projects").?.get("/Users/me/repo").?.get("trust_level").?.asString().?);
}

test "strings, numbers, dates and arrays of tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parseForTest(&arena,
        \\basic = "tab\there \"q\""
        \\multi = """
        \\one \
        \\   two"""
        \\literal_multi = '''
        \\keep \n raw'''
        \\hex = 0xDEAD_beef
        \\big = 1_000
        \\neg = -17
        \\float = 6.626e-34
        \\inf = -inf
        \\when = 1979-05-27T07:32:00Z
        \\spaced = 1979-05-27 07:32:00
        \\[[profiles]]
        \\name = "a"
        \\[[profiles]]
        \\name = "b"
        \\[profiles.extra]
        \\x = 1
    );
    try testing.expectEqualStrings("tab\there \"q\"", root.get("basic").?.asString().?);
    try testing.expectEqualStrings("one two", root.get("multi").?.asString().?);
    try testing.expectEqualStrings("keep \\n raw", root.get("literal_multi").?.asString().?);
    try testing.expectEqual(@as(i64, 0xDEADBEEF), root.get("hex").?.integer);
    try testing.expectEqual(@as(i64, 1000), root.get("big").?.integer);
    try testing.expectEqual(@as(i64, -17), root.get("neg").?.integer);
    try testing.expect(root.get("inf").?.float < 0);
    try testing.expectEqualStrings("1979-05-27T07:32:00Z", root.get("when").?.datetime);
    try testing.expectEqualStrings("1979-05-27 07:32:00", root.get("spaced").?.datetime);
    const profiles = root.get("profiles").?.array;
    try testing.expectEqual(@as(usize, 2), profiles.len);
    try testing.expectEqualStrings("b", profiles[1].get("name").?.asString().?);
    try testing.expectEqual(@as(i64, 1), profiles[1].get("extra").?.get("x").?.integer);
}

test "redefinitions and malformed input are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "a = 1\na = 2",
        "[t]\n[t]",
        "a = {x = 1}\n[a]",
        "a.b = 1\n[a]",
        "a = \"unterminated",
        "a = 01",
        "a = 1__0",
        "a = [1 2]",
        "a =",
        "= 1",
        "a = 1 b = 2",
        "a = tru",
    };
    for (bad) |source| {
        if (parseForTest(&arena, source)) |_| {
            std.debug.print("accepted: {s}\n", .{source});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidToml, err);
    }
}

test "diagnostic reports the failing line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diagnostic = Diagnostic{};
    try testing.expectError(error.InvalidToml, parse(arena.allocator(), "a = 1\nb = 2\nc = ?\n", .{}, &diagnostic));
    try testing.expectEqual(@as(usize, 3), diagnostic.line);
}
