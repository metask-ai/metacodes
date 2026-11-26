//! Bounded YAML-subset parser for Skill metadata: SKILL.md frontmatter and the
//! Codex `agents/openai.yaml` sidecar.
//!
//! Claude Code and Codex both read these files as YAML (Codex through
//! serde_yaml), so hand-written skills routinely use folded descriptions,
//! quoted strings and block lists. This parser accepts the block-style subset
//! those files use:
//!   - mappings and sequences nested by indentation (spaces only),
//!   - plain, single-quoted and double-quoted scalars, including multi-line
//!     folding,
//!   - literal `|` and folded `>` block scalars with chomping and indentation
//!     indicators,
//!   - flow sequences `[a, "b"]` and flow mappings `{a: b}`, possibly spanning
//!     lines,
//!   - comments, CRLF line endings and a leading UTF-8 byte-order mark.
//! Anchors, aliases, tags, directives and multi-document streams are rejected
//! instead of being misread.
//!
//! One deliberate leniency matches Codex's repair pass: a plain scalar value in
//! a block mapping runs to the end of its line, so `description: Deploy to AWS:
//! ECS` keeps the whole text instead of being a YAML error.
//!
//! Every node lives in the caller's arena.

const std = @import("std");

pub const Node = union(enum) {
    scalar: []const u8,
    sequence: []const Node,
    mapping: []const Entry,

    /// Value of `key` in a mapping; null for a missing key or a non-mapping.
    pub fn get(self: Node, key: []const u8) ?Node {
        const entries = switch (self) {
            .mapping => |value| value,
            else => return null,
        };
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    /// The text of a scalar; null for a sequence or mapping.
    pub fn text(self: Node) ?[]const u8 {
        return switch (self) {
            .scalar => |value| value,
            else => null,
        };
    }
};

pub const Entry = struct {
    key: []const u8,
    value: Node,
};

pub const Limits = struct {
    max_bytes: usize = 256 * 1024,
    max_depth: u16 = 32,
    max_nodes: u32 = 8192,
};

pub const Error = error{ OutOfMemory, InvalidYaml };

pub const Split = struct {
    /// The YAML text between the delimiter lines, CR bytes included.
    yaml: []const u8,
    /// Everything after the closing delimiter line.
    body: []const u8,
};

/// Locate the frontmatter block. Returns null when the document does not
/// open with a `---` line (after an optional UTF-8 BOM): such a file is all
/// body. An opened but never closed block is `error.InvalidYaml`.
pub fn splitFrontmatter(md: []const u8) error{InvalidYaml}!?Split {
    var rest = md;
    if (std.mem.startsWith(u8, rest, "\xEF\xBB\xBF")) rest = rest[3..];
    const first_end = std.mem.indexOfScalar(u8, rest, '\n') orelse {
        return if (isDelimiter(rest, "---")) error.InvalidYaml else null;
    };
    if (!isDelimiter(rest[0..first_end], "---")) return null;

    const yaml_start = first_end + 1;
    var cursor = yaml_start;
    while (cursor <= rest.len) {
        const line_end = std.mem.indexOfScalarPos(u8, rest, cursor, '\n') orelse rest.len;
        const line = rest[cursor..line_end];
        if (isDelimiter(line, "---") or isDelimiter(line, "...")) {
            const body_start = if (line_end < rest.len) line_end + 1 else rest.len;
            return .{ .yaml = rest[yaml_start..cursor], .body = rest[body_start..] };
        }
        if (line_end == rest.len) break;
        cursor = line_end + 1;
    }
    return error.InvalidYaml;
}

fn isDelimiter(line: []const u8, marker: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), marker);
}

/// Parse a YAML document whose root is a mapping. An empty document is an
/// empty mapping.
pub fn parse(arena: std.mem.Allocator, source: []const u8, limits: Limits) Error!Node {
    if (source.len > limits.max_bytes) return error.InvalidYaml;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidYaml;

    var lines: std.ArrayList(Line) = .empty;
    var iterator = std.mem.splitScalar(u8, source, '\n');
    while (iterator.next()) |raw_with_cr| {
        const raw = std.mem.trimEnd(u8, raw_with_cr, "\r");
        try lines.append(arena, try Line.init(raw));
    }

    var parser = Parser{ .arena = arena, .lines = lines.items, .limits = limits };
    parser.skipInsignificant();
    const first = parser.peek() orelse return .{ .mapping = &.{} };
    if (first.tab_indented) return error.InvalidYaml;
    if (std.mem.startsWith(u8, first.text, "---") or first.text[0] == '%')
        return error.InvalidYaml;
    if (isSequenceItem(first.text)) return error.InvalidYaml;
    const root = try parser.parseMapping(first.indent, 0);
    parser.skipInsignificant();
    if (parser.pos != parser.lines.len) return error.InvalidYaml;
    return root;
}

/// YAML 1.1 / Claude Code boolean spellings, case-insensitive.
pub fn parseBool(value: []const u8) ?bool {
    const truthy = [_][]const u8{ "true", "yes", "on", "1" };
    const falsy = [_][]const u8{ "false", "no", "off", "0" };
    for (truthy) |word| if (std.ascii.eqlIgnoreCase(value, word)) return true;
    for (falsy) |word| if (std.ascii.eqlIgnoreCase(value, word)) return false;
    return null;
}

const Line = struct {
    /// The line without its line terminator.
    raw: []const u8,
    /// Leading spaces. Only meaningful when `text` is non-empty.
    indent: usize,
    /// Content after the indentation, surrounding blanks removed. Empty for a
    /// blank line.
    text: []const u8,
    /// A tab follows the leading spaces. Block-scalar content may contain one,
    /// but such a line may not carry mapping or sequence structure.
    tab_indented: bool,

    fn init(raw: []const u8) Error!Line {
        var indent: usize = 0;
        while (indent < raw.len and raw[indent] == ' ') indent += 1;
        const rest = raw[indent..];
        const content = std.mem.trim(u8, rest, " \t");
        return .{
            .raw = raw,
            .indent = indent,
            .text = content,
            .tab_indented = content.len != 0 and rest[0] == '\t',
        };
    }

    fn isBlank(self: Line) bool {
        return self.text.len == 0;
    }

    fn isComment(self: Line) bool {
        return self.text.len != 0 and self.text[0] == '#';
    }
};

fn isSequenceItem(text: []const u8) bool {
    return text.len != 0 and text[0] == '-' and
        (text.len == 1 or text[1] == ' ' or text[1] == '\t');
}

const Parser = struct {
    arena: std.mem.Allocator,
    lines: []Line,
    pos: usize = 0,
    nodes: u32 = 0,
    limits: Limits,

    fn peek(self: *Parser) ?*Line {
        if (self.pos >= self.lines.len) return null;
        return &self.lines[self.pos];
    }

    fn skipInsignificant(self: *Parser) void {
        while (self.pos < self.lines.len) : (self.pos += 1) {
            const line = self.lines[self.pos];
            if (!line.isBlank() and !line.isComment()) return;
        }
    }

    fn charge(self: *Parser, depth: usize) Error!void {
        if (depth > self.limits.max_depth) return error.InvalidYaml;
        self.nodes += 1;
        if (self.nodes > self.limits.max_nodes) return error.InvalidYaml;
    }

    fn parseMapping(self: *Parser, indent: usize, depth: usize) Error!Node {
        try self.charge(depth);
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            self.skipInsignificant();
            const line = self.peek() orelse break;
            if (line.indent < indent) break;
            if (line.indent > indent or line.tab_indented) return error.InvalidYaml;
            if (isSequenceItem(line.text)) break;
            const split = try splitKey(self.arena, line.text);
            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.key, split.key)) return error.InvalidYaml;
            }
            self.pos += 1;
            const value = try self.parseValue(split.rest, indent, depth + 1);
            try entries.append(self.arena, .{ .key = split.key, .value = value });
        }
        return .{ .mapping = try entries.toOwnedSlice(self.arena) };
    }

    fn parseSequence(self: *Parser, indent: usize, depth: usize) Error!Node {
        try self.charge(depth);
        var items: std.ArrayList(Node) = .empty;
        while (true) {
            self.skipInsignificant();
            const line = self.peek() orelse break;
            if (line.indent != indent or !isSequenceItem(line.text)) {
                if (line.indent > indent) return error.InvalidYaml;
                break;
            }
            if (line.tab_indented) return error.InvalidYaml;
            const after_dash = line.text[1..];
            const content = std.mem.trimStart(u8, after_dash, " \t");
            if (content.len == 0 or content[0] == '#') {
                self.pos += 1;
                try items.append(self.arena, try self.parseNested(indent, depth + 1, false));
                continue;
            }
            const content_column = indent + 1 + (after_dash.len - content.len);
            if (isSequenceItem(content) or looksLikeMappingEntry(content)) {
                // `- key: value` / `- - item`: re-read this line as the first
                // line of a nested block that starts at the content column.
                line.indent = content_column;
                line.text = content;
                try items.append(self.arena, if (isSequenceItem(content))
                    try self.parseSequence(content_column, depth + 1)
                else
                    try self.parseMapping(content_column, depth + 1));
                continue;
            }
            self.pos += 1;
            try items.append(self.arena, try self.parseInlineValue(content, indent, depth + 1));
        }
        return .{ .sequence = try items.toOwnedSlice(self.arena) };
    }

    /// A value whose text starts on the line after its key or dash.
    fn parseNested(self: *Parser, parent_indent: usize, depth: usize, allow_compact_sequence: bool) Error!Node {
        const resume_pos = self.pos;
        self.skipInsignificant();
        if (self.peek()) |next| {
            if (next.indent > parent_indent) {
                return if (isSequenceItem(next.text))
                    self.parseSequence(next.indent, depth)
                else
                    self.parseMapping(next.indent, depth);
            }
            if (allow_compact_sequence and next.indent == parent_indent and isSequenceItem(next.text))
                return self.parseSequence(parent_indent, depth);
        }
        self.pos = resume_pos;
        try self.charge(depth);
        return .{ .scalar = "" };
    }

    /// The value after `key:` on the key's own line.
    fn parseValue(self: *Parser, rest: []const u8, parent_indent: usize, depth: usize) Error!Node {
        if (rest.len == 0 or rest[0] == '#') return self.parseNested(parent_indent, depth, true);
        return self.parseInlineValue(rest, parent_indent, depth);
    }

    fn parseInlineValue(self: *Parser, value: []const u8, parent_indent: usize, depth: usize) Error!Node {
        try self.charge(depth);
        return switch (value[0]) {
            '|', '>' => .{ .scalar = try self.parseBlockScalar(value, parent_indent) },
            '"', '\'' => .{ .scalar = try self.parseQuotedMultiline(value, parent_indent) },
            '[', '{' => self.parseFlowOrPlain(value, parent_indent, depth),
            '&', '*', '!' => error.InvalidYaml,
            else => .{ .scalar = try self.parsePlainMultiline(value, parent_indent) },
        };
    }

    fn parsePlainMultiline(self: *Parser, first: []const u8, parent_indent: usize) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.arena, std.mem.trimEnd(u8, stripComment(first), " \t"));
        var pending_breaks: usize = 0;
        var cursor = self.pos;
        while (cursor < self.lines.len) : (cursor += 1) {
            const line = self.lines[cursor];
            if (line.isBlank()) {
                pending_breaks += 1;
                continue;
            }
            if (line.indent <= parent_indent or line.isComment()) break;
            // YAML forbids `key: value` inside a multi-line plain scalar; an
            // over-indented key is a mistake, not continuation text.
            if (keyColon(line.text) != null) return error.InvalidYaml;
            if (pending_breaks == 0) {
                try out.append(self.arena, ' ');
            } else {
                try out.appendNTimes(self.arena, '\n', pending_breaks);
            }
            pending_breaks = 0;
            try out.appendSlice(self.arena, std.mem.trimEnd(u8, stripComment(line.text), " \t"));
            self.pos = cursor + 1;
        }
        return out.toOwnedSlice(self.arena);
    }

    fn parseBlockScalar(self: *Parser, header: []const u8, parent_indent: usize) Error![]const u8 {
        const folded = header[0] == '>';
        const Chomp = enum { clip, strip, keep };
        var chomp: Chomp = .clip;
        var explicit_indent: ?usize = null;
        var index: usize = 1;
        while (index < header.len and index <= 2) : (index += 1) {
            switch (header[index]) {
                '-' => chomp = .strip,
                '+' => chomp = .keep,
                '1'...'9' => explicit_indent = header[index] - '0',
                else => break,
            }
        }
        const trailer = std.mem.trimStart(u8, header[index..], " \t");
        if (trailer.len != 0 and trailer[0] != '#') return error.InvalidYaml;

        var content_indent: usize = if (explicit_indent) |value| parent_indent + value else 0;
        if (explicit_indent == null) {
            var probe = self.pos;
            while (probe < self.lines.len) : (probe += 1) {
                const line = self.lines[probe];
                if (line.isBlank()) continue;
                content_indent = line.indent;
                break;
            }
            if (content_indent <= parent_indent) return "";
        }

        var collected: std.ArrayList([]const u8) = .empty;
        while (self.pos < self.lines.len) {
            const line = self.lines[self.pos];
            if (line.isBlank()) {
                try collected.append(self.arena, "");
                self.pos += 1;
                continue;
            }
            if (line.indent < content_indent) break;
            try collected.append(self.arena, line.raw[content_indent..]);
            self.pos += 1;
        }

        var trailing_blank: usize = 0;
        while (trailing_blank < collected.items.len and
            collected.items[collected.items.len - 1 - trailing_blank].len == 0) trailing_blank += 1;
        const content_lines = collected.items[0 .. collected.items.len - trailing_blank];

        var out: std.ArrayList(u8) = .empty;
        for (content_lines, 0..) |line, line_index| {
            if (line_index != 0) {
                const previous = content_lines[line_index - 1];
                const joins = folded and previous.len != 0 and line.len != 0 and
                    !isMoreIndented(previous) and !isMoreIndented(line);
                if (joins) {
                    try out.append(self.arena, ' ');
                } else if (folded and line.len == 0 and previous.len != 0 and !isMoreIndented(previous)) {
                    // The break before a blank line is folded away; the blank
                    // line itself contributes the newline.
                } else {
                    try out.append(self.arena, '\n');
                }
            }
            try out.appendSlice(self.arena, line);
        }
        switch (chomp) {
            .strip => {},
            .clip => if (content_lines.len != 0) try out.append(self.arena, '\n'),
            .keep => {
                if (content_lines.len != 0) try out.append(self.arena, '\n');
                try out.appendNTimes(self.arena, '\n', trailing_blank);
            },
        }
        return out.toOwnedSlice(self.arena);
    }

    /// A quoted scalar may continue on following lines until its closing quote.
    fn parseQuotedMultiline(self: *Parser, first: []const u8, parent_indent: usize) Error![]const u8 {
        _ = parent_indent;
        var joined: std.ArrayList(u8) = .empty;
        try joined.appendSlice(self.arena, first);
        while (closingQuote(joined.items) == null) {
            if (self.pos >= self.lines.len) return error.InvalidYaml;
            try joined.append(self.arena, '\n');
            try joined.appendSlice(self.arena, self.lines[self.pos].raw);
            self.pos += 1;
        }
        const close = closingQuote(joined.items).?;
        const trailer = std.mem.trimStart(u8, joined.items[close + 1 ..], " \t");
        if (trailer.len != 0 and trailer[0] != '#') return error.InvalidYaml;
        return decodeQuoted(self.arena, joined.items[0 .. close + 1]);
    }

    /// Codex repairs a value that starts like a flow collection but is not one
    /// (`argument-hint: [pr] [priority]`, `description: [Beta] Does X`) by
    /// quoting it. When a one-line value fails flow parsing, read it as a plain
    /// scalar instead; a collection spanning lines must still be well formed.
    fn parseFlowOrPlain(self: *Parser, value: []const u8, parent_indent: usize, depth: usize) Error!Node {
        const resume_pos = self.pos;
        const saved_nodes = self.nodes;
        if (self.parseFlowMultiline(value, depth)) |node| {
            return node;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidYaml => {},
        }
        if (flowEnd(stripComment(value)) == null and !std.mem.containsAtLeast(u8, value, 1, "]") and
            !std.mem.containsAtLeast(u8, value, 1, "}"))
            return error.InvalidYaml;
        self.pos = resume_pos;
        self.nodes = saved_nodes;
        return .{ .scalar = try self.parsePlainMultiline(value, parent_indent) };
    }

    fn parseFlowMultiline(self: *Parser, first: []const u8, depth: usize) Error!Node {
        var joined: std.ArrayList(u8) = .empty;
        try joined.appendSlice(self.arena, stripComment(first));
        while (flowEnd(joined.items) == null) {
            if (self.pos >= self.lines.len) return error.InvalidYaml;
            const line = self.lines[self.pos];
            self.pos += 1;
            if (line.isComment()) continue;
            try joined.append(self.arena, ' ');
            try joined.appendSlice(self.arena, stripComment(line.text));
        }
        const end = flowEnd(joined.items).?;
        if (std.mem.trim(u8, joined.items[end + 1 ..], " \t").len != 0) return error.InvalidYaml;
        var flow = FlowParser{ .parser = self, .source = joined.items[0 .. end + 1] };
        const node = try flow.parseNode(depth);
        flow.skipSpaces();
        if (flow.index != flow.source.len) return error.InvalidYaml;
        return node;
    }
};

fn isMoreIndented(line: []const u8) bool {
    return line.len != 0 and (line[0] == ' ' or line[0] == '\t');
}

fn looksLikeMappingEntry(text: []const u8) bool {
    if (text[0] == '"' or text[0] == '\'') {
        const close = closingQuote(text) orelse return false;
        return close + 1 < text.len and text[close + 1] == ':' and
            (close + 2 == text.len or text[close + 2] == ' ' or text[close + 2] == '\t');
    }
    if (text[0] == '[' or text[0] == '{') return false;
    return keyColon(text) != null;
}

/// Index of the first `:` that ends a plain key (followed by blank or EOL).
fn keyColon(text: []const u8) ?usize {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '#' and index > 0 and (text[index - 1] == ' ' or text[index - 1] == '\t'))
            return null;
        if (text[index] != ':') continue;
        if (index + 1 == text.len or text[index + 1] == ' ' or text[index + 1] == '\t') return index;
    }
    return null;
}

const KeySplit = struct { key: []const u8, rest: []const u8 };

fn splitKey(arena: std.mem.Allocator, text: []const u8) Error!KeySplit {
    if (text[0] == '"' or text[0] == '\'') {
        const close = closingQuote(text) orelse return error.InvalidYaml;
        if (close + 1 >= text.len or text[close + 1] != ':') return error.InvalidYaml;
        const after = text[close + 2 ..];
        if (after.len != 0 and after[0] != ' ' and after[0] != '\t') return error.InvalidYaml;
        const key = try decodeQuoted(arena, text[0 .. close + 1]);
        return .{ .key = key, .rest = std.mem.trimStart(u8, after, " \t") };
    }
    switch (text[0]) {
        '[', '{', '&', '*', '!', '?', '|', '>', '%', '@', '`', ',' => return error.InvalidYaml,
        else => {},
    }
    const colon = keyColon(text) orelse return error.InvalidYaml;
    const key = std.mem.trimEnd(u8, text[0..colon], " \t");
    if (key.len == 0) return error.InvalidYaml;
    return .{ .key = key, .rest = std.mem.trimStart(u8, text[colon + 1 ..], " \t") };
}

/// Cut a ` #comment` from a plain scalar.
fn stripComment(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '#' and (index == 0 or text[index - 1] == ' ' or text[index - 1] == '\t'))
            return text[0..index];
    }
    return text;
}

/// Index of the quote closing the quoted scalar that opens `text`.
fn closingQuote(text: []const u8) ?usize {
    const quote = text[0];
    var index: usize = 1;
    while (index < text.len) : (index += 1) {
        if (quote == '"' and text[index] == '\\') {
            index += 1;
            continue;
        }
        if (text[index] != quote) continue;
        if (quote == '\'' and index + 1 < text.len and text[index + 1] == '\'') {
            index += 1;
            continue;
        }
        return index;
    }
    return null;
}

/// Index of the bracket closing the flow collection that opens `text`.
fn flowEnd(text: []const u8) ?usize {
    var depth: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            '"', '\'' => {
                const close = closingQuote(text[index..]) orelse return null;
                index += close;
            },
            '[', '{' => depth += 1,
            ']', '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    return null;
}

/// Decode a complete quoted scalar, quotes included, applying YAML line
/// folding to embedded line breaks.
fn decodeQuoted(arena: std.mem.Allocator, quoted: []const u8) Error![]const u8 {
    const quote = quoted[0];
    const inner = quoted[1 .. quoted.len - 1];
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < inner.len) {
        const byte = inner[index];
        if (byte == '\n') {
            // Fold: trailing blanks before the break and leading blanks after
            // it vanish; a single break becomes a space, each further empty
            // line a newline.
            while (out.items.len != 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t'))
                out.items.len -= 1;
            var breaks: usize = 0;
            while (index < inner.len) {
                if (inner[index] == '\n') {
                    breaks += 1;
                    index += 1;
                } else if (inner[index] == ' ' or inner[index] == '\t' or inner[index] == '\r') {
                    index += 1;
                } else break;
            }
            if (breaks == 1) {
                try out.append(arena, ' ');
            } else {
                try out.appendNTimes(arena, '\n', breaks - 1);
            }
            continue;
        }
        if (quote == '\'') {
            if (byte == '\'' and index + 1 < inner.len and inner[index + 1] == '\'') {
                try out.append(arena, '\'');
                index += 2;
                continue;
            }
            try out.append(arena, byte);
            index += 1;
            continue;
        }
        if (byte != '\\') {
            try out.append(arena, byte);
            index += 1;
            continue;
        }
        if (index + 1 >= inner.len) return error.InvalidYaml;
        const escape = inner[index + 1];
        index += 2;
        switch (escape) {
            '0' => try out.append(arena, 0),
            'a' => try out.append(arena, 0x07),
            'b' => try out.append(arena, 0x08),
            't', '\t' => try out.append(arena, '\t'),
            'n' => try out.append(arena, '\n'),
            'v' => try out.append(arena, 0x0b),
            'f' => try out.append(arena, 0x0c),
            'r' => try out.append(arena, '\r'),
            'e' => try out.append(arena, 0x1b),
            ' ' => try out.append(arena, ' '),
            '"' => try out.append(arena, '"'),
            '/' => try out.append(arena, '/'),
            '\\' => try out.append(arena, '\\'),
            'N' => try appendCodepoint(arena, &out, 0x85),
            '_' => try appendCodepoint(arena, &out, 0xa0),
            'L' => try appendCodepoint(arena, &out, 0x2028),
            'P' => try appendCodepoint(arena, &out, 0x2029),
            'x', 'u', 'U' => {
                const digits: usize = switch (escape) {
                    'x' => 2,
                    'u' => 4,
                    else => 8,
                };
                if (index + digits > inner.len) return error.InvalidYaml;
                const value = std.fmt.parseInt(u32, inner[index .. index + digits], 16) catch
                    return error.InvalidYaml;
                index += digits;
                if (value > 0x10ffff) return error.InvalidYaml;
                try appendCodepoint(arena, &out, @intCast(value));
            },
            '\n' => {
                // Escaped line break: join without a space, dropping the
                // next line's indentation.
                while (index < inner.len and (inner[index] == ' ' or inner[index] == '\t')) index += 1;
            },
            else => return error.InvalidYaml,
        }
    }
    return out.toOwnedSlice(arena);
}

fn appendCodepoint(arena: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) Error!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidYaml;
    try out.appendSlice(arena, buffer[0..length]);
}

const FlowParser = struct {
    parser: *Parser,
    source: []const u8,
    index: usize = 0,

    fn skipSpaces(self: *FlowParser) void {
        while (self.index < self.source.len and
            (self.source[self.index] == ' ' or self.source[self.index] == '\t')) self.index += 1;
    }

    fn parseNode(self: *FlowParser, depth: usize) Error!Node {
        try self.parser.charge(depth);
        self.skipSpaces();
        if (self.index >= self.source.len) return error.InvalidYaml;
        return switch (self.source[self.index]) {
            '[' => self.parseSequence(depth),
            '{' => self.parseMapping(depth),
            '"', '\'' => .{ .scalar = try self.parseQuoted() },
            '&', '*', '!' => error.InvalidYaml,
            else => .{ .scalar = self.parsePlain() },
        };
    }

    fn parseQuoted(self: *FlowParser) Error![]const u8 {
        const close = closingQuote(self.source[self.index..]) orelse return error.InvalidYaml;
        const quoted = self.source[self.index .. self.index + close + 1];
        self.index += close + 1;
        return decodeQuoted(self.parser.arena, quoted);
    }

    fn parsePlain(self: *FlowParser) []const u8 {
        const start = self.index;
        while (self.index < self.source.len) : (self.index += 1) {
            switch (self.source[self.index]) {
                ',', ']', '}' => break,
                ':' => if (self.index + 1 < self.source.len and
                    (self.source[self.index + 1] == ' ' or self.source[self.index + 1] == ','))
                    break,
                else => {},
            }
        }
        return std.mem.trim(u8, self.source[start..self.index], " \t");
    }

    fn parseSequence(self: *FlowParser, depth: usize) Error!Node {
        self.index += 1;
        var items: std.ArrayList(Node) = .empty;
        while (true) {
            self.skipSpaces();
            if (self.index >= self.source.len) return error.InvalidYaml;
            if (self.source[self.index] == ']') {
                self.index += 1;
                break;
            }
            try items.append(self.parser.arena, try self.parseNode(depth + 1));
            self.skipSpaces();
            if (self.index >= self.source.len) return error.InvalidYaml;
            switch (self.source[self.index]) {
                ',' => self.index += 1,
                ']' => {},
                else => return error.InvalidYaml,
            }
        }
        return .{ .sequence = try items.toOwnedSlice(self.parser.arena) };
    }

    fn parseMapping(self: *FlowParser, depth: usize) Error!Node {
        self.index += 1;
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            self.skipSpaces();
            if (self.index >= self.source.len) return error.InvalidYaml;
            if (self.source[self.index] == '}') {
                self.index += 1;
                break;
            }
            const key_node = try self.parseNode(depth + 1);
            const key = key_node.text() orelse return error.InvalidYaml;
            if (key.len == 0) return error.InvalidYaml;
            self.skipSpaces();
            if (self.index >= self.source.len or self.source[self.index] != ':') return error.InvalidYaml;
            self.index += 1;
            self.skipSpaces();
            const value: Node = if (self.index < self.source.len and
                (self.source[self.index] == ',' or self.source[self.index] == '}'))
                .{ .scalar = "" }
            else
                try self.parseNode(depth + 1);
            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.key, key)) return error.InvalidYaml;
            }
            try entries.append(self.parser.arena, .{ .key = key, .value = value });
            self.skipSpaces();
            if (self.index >= self.source.len) return error.InvalidYaml;
            switch (self.source[self.index]) {
                ',' => self.index += 1,
                '}' => {},
                else => return error.InvalidYaml,
            }
        }
        return .{ .mapping = try entries.toOwnedSlice(self.parser.arena) };
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn parseForTest(arena: *std.heap.ArenaAllocator, source: []const u8) Error!Node {
    return parse(arena.allocator(), source, .{});
}

fn expectScalar(node: Node, key: []const u8, expected: []const u8) !void {
    const value = node.get(key) orelse return error.TestExpectedKey;
    try testing.expectEqualStrings(expected, value.text() orelse return error.TestExpectedScalar);
}

test "splitFrontmatter: BOM, CRLF, missing and unterminated blocks" {
    const crlf = try splitFrontmatter("\xEF\xBB\xBF---\r\nname: x\r\n---\r\nbody\r\n");
    try testing.expectEqualStrings("name: x\r\n", crlf.?.yaml);
    try testing.expectEqualStrings("body\r\n", crlf.?.body);
    try testing.expect((try splitFrontmatter("# just a body\n")) == null);
    try testing.expectError(error.InvalidYaml, splitFrontmatter("---\nname: x\nno close\n"));
    const closed_at_eof = try splitFrontmatter("---\nname: x\n---");
    try testing.expectEqualStrings("", closed_at_eof.?.body);
    const dots = try splitFrontmatter("---\nname: x\n...\nbody");
    try testing.expectEqualStrings("body", dots.?.body);
}

test "plain, quoted and lenient colon scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parseForTest(&arena,
        \\name: "pdf"
        \\description: 'It''s a "PDF" skill'
        \\note: Deploy to AWS: ECS # trailing comment
        \\url: https://example.com/a#frag
        \\escaped: "tab\there \u4e2d \"q\""
        \\empty:
    );
    try expectScalar(root, "name", "pdf");
    try expectScalar(root, "description", "It's a \"PDF\" skill");
    try expectScalar(root, "note", "Deploy to AWS: ECS");
    try expectScalar(root, "url", "https://example.com/a#frag");
    try expectScalar(root, "escaped", "tab\there 中 \"q\"");
    try expectScalar(root, "empty", "");
}

test "folded and literal block scalars with chomping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parseForTest(&arena,
        \\description: >
        \\  MUST USE when the user
        \\  wants research.
        \\
        \\  Also when a URL appears.
        \\literal: |
        \\  line one
        \\    indented
        \\stripped: >-
        \\  a
        \\  b
        \\kept: |+
        \\  x
        \\
        \\next: done
    );
    try expectScalar(root, "description", "MUST USE when the user wants research.\nAlso when a URL appears.\n");
    try expectScalar(root, "literal", "line one\n  indented\n");
    try expectScalar(root, "stripped", "a b");
    try expectScalar(root, "kept", "x\n\n");
    try expectScalar(root, "next", "done");
}

test "multi-line plain and quoted scalars fold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parseForTest(&arena,
        \\description: first line
        \\  second line
        \\
        \\  new paragraph
        \\quoted: "a
        \\  b"
        \\after: ok
    );
    try expectScalar(root, "description", "first line second line\nnew paragraph");
    try expectScalar(root, "quoted", "a b");
    try expectScalar(root, "after", "ok");
}

test "block and flow sequences, nested mappings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parseForTest(&arena,
        \\allowed-tools:
        \\  - Read
        \\  - Bash(git *)
        \\compact:
        \\- a
        \\- b
        \\flow: [Read, "Grep, Glob", 'x']
        \\metadata:
        \\  short-description: short
        \\  version: "1.0"
        \\dependencies:
        \\  tools:
        \\    - type: mcp
        \\      value: github
        \\    - type: env
        \\inline_map: {a: 1, b: "two"}
        \\multi_flow: [one,
        \\  two]
    );
    const allowed = root.get("allowed-tools").?.sequence;
    try testing.expectEqual(@as(usize, 2), allowed.len);
    try testing.expectEqualStrings("Bash(git *)", allowed[1].text().?);
    try testing.expectEqual(@as(usize, 2), root.get("compact").?.sequence.len);
    const flow = root.get("flow").?.sequence;
    try testing.expectEqualStrings("Grep, Glob", flow[1].text().?);
    try expectScalar(root.get("metadata").?, "short-description", "short");
    const tools = root.get("dependencies").?.get("tools").?.sequence;
    try testing.expectEqual(@as(usize, 2), tools.len);
    try expectScalar(tools[0], "value", "github");
    try expectScalar(root.get("inline_map").?, "b", "two");
    try testing.expectEqualStrings("two", root.get("multi_flow").?.sequence[1].text().?);
    // A nested key never leaks into the root mapping.
    try testing.expect(root.get("short-description") == null);
}

test "one-line values that only look like flow collections stay text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try parseForTest(&arena,
        \\argument-hint: [pr-number] [priority]
        \\description: [Beta] Does X, then Y
        \\flow: [a, b]
        \\map: {k: v} trailing
    );
    try expectScalar(root, "argument-hint", "[pr-number] [priority]");
    try expectScalar(root, "description", "[Beta] Does X, then Y");
    try testing.expectEqual(@as(usize, 2), root.get("flow").?.sequence.len);
    try expectScalar(root, "map", "{k: v} trailing");
}

test "rejects constructs it cannot represent faithfully" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "name: &anchor x",
        "name: *alias",
        "name: !tag x",
        "name: a\nname: b",
        "name: x\n  stray: indent",
        "just text without a key",
        "name: \"unterminated",
        "- top level sequence",
        "list: [a, b",
        "\tname: tab indented",
    };
    for (bad) |source| {
        try testing.expectError(error.InvalidYaml, parseForTest(&arena, source));
    }
}

test "empty document is an empty mapping and comments are ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty = try parseForTest(&arena, "# only a comment\n\n");
    try testing.expectEqual(@as(usize, 0), empty.mapping.len);
    const crlf = try parseForTest(&arena, "name: x\r\ndescription: y\r\n");
    try expectScalar(crlf, "description", "y");
}

test "limits bound depth and size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidYaml, parse(arena.allocator(), "a:\n b:\n  c: d", .{ .max_depth = 2 }));
    try testing.expectError(error.InvalidYaml, parse(arena.allocator(), "a: b", .{ .max_bytes = 2 }));
}

test "parseBool accepts YAML 1.1 spellings case-insensitively" {
    try testing.expectEqual(@as(?bool, true), parseBool("Yes"));
    try testing.expectEqual(@as(?bool, false), parseBool("OFF"));
    try testing.expectEqual(@as(?bool, true), parseBool("1"));
    try testing.expectEqual(@as(?bool, null), parseBool("maybe"));
}
