const std = @import("std");

pub const default_max_token_bytes: usize = 128;

comptime {
    if (default_max_token_bytes > std.math.maxInt(u8)) {
        @compileError("persistent TextTermEntry.term_len is one byte; raise the text format before increasing default_max_token_bytes");
    }
}

pub const TokenizerOptions = struct {
    max_token_bytes: usize = default_max_token_bytes,
    emit_original_compound: bool = true,
    emit_cjk_bigrams: bool = true,
    emit_cjk_unigrams: bool = true,
};

pub const TokenList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) TokenList {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *TokenList) void {
        for (self.items.items) |token| self.allocator.free(token);
        self.items.deinit(self.allocator);
    }

    pub fn appendOwned(self: *TokenList, token: []u8, max_token_bytes: usize) !void {
        if (token.len == 0 or token.len > max_token_bytes) {
            self.allocator.free(token);
            return;
        }
        errdefer self.allocator.free(token);
        try self.items.append(self.allocator, token);
    }

    pub fn appendLowerAscii(self: *TokenList, bytes: []const u8, max_token_bytes: usize) !void {
        if (bytes.len == 0 or bytes.len > max_token_bytes) return;
        const token = try self.allocator.alloc(u8, bytes.len);
        errdefer self.allocator.free(token);
        for (bytes, 0..) |byte, i| token[i] = std.ascii.toLower(byte);
        try self.items.append(self.allocator, token);
    }

    pub fn contains(self: TokenList, needle: []const u8) bool {
        for (self.items.items) |token| {
            if (std.mem.eql(u8, token, needle)) return true;
        }
        return false;
    }
};

pub fn tokenize(allocator: std.mem.Allocator, input: []const u8, options: TokenizerOptions) !TokenList {
    try validateTokenizerOptions(options);
    var tokens = TokenList.init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    while (i < input.len) {
        const decoded = decodeUtf8(input, i);
        const cp = decoded.codepoint;
        if (isCjk(cp)) {
            var normalized = std.ArrayList(u8).empty;
            defer normalized.deinit(allocator);
            try appendNormalizedCjkCodepoint(&normalized, allocator, input, &i, decoded);
            while (i < input.len) {
                const next = decodeUtf8(input, i);
                if (!isCjk(next.codepoint)) {
                    if (isCjkJoiner(next.codepoint)) {
                        const after_joiner = i + next.len;
                        if (after_joiner < input.len and isCjk(decodeUtf8(input, after_joiner).codepoint)) {
                            i = after_joiner;
                            continue;
                        }
                    }
                    break;
                }
                try appendNormalizedCjkCodepoint(&normalized, allocator, input, &i, next);
            }
            try appendCjkTokens(&tokens, normalized.items, options);
        } else if (normalizedRunByte(cp)) |first_byte| {
            var run = std.ArrayList(u8).empty;
            defer run.deinit(allocator);
            try run.append(allocator, first_byte);
            i += decoded.len;
            while (i < input.len) {
                const next = decodeUtf8(input, i);
                const byte = normalizedRunByte(next.codepoint) orelse break;
                try run.append(allocator, byte);
                i += next.len;
            }
            try appendRunTokens(&tokens, run.items, options);
        } else {
            i += decoded.len;
        }
    }

    return tokens;
}

pub fn countTokens(allocator: std.mem.Allocator, input: []const u8, options: TokenizerOptions) !u64 {
    var tokens = try tokenize(allocator, input, options);
    defer tokens.deinit();
    return @intCast(tokens.items.items.len);
}

pub fn countTermInText(allocator: std.mem.Allocator, input: []const u8, term: []const u8) !u32 {
    var tokens = try tokenize(allocator, input, .{});
    defer tokens.deinit();
    var count: u32 = 0;
    for (tokens.items.items) |token| {
        if (std.mem.eql(u8, token, term)) {
            count = std.math.add(u32, count, 1) catch return error.RecordTooLarge;
        }
    }
    return count;
}

pub fn validateTokenizerOptions(options: TokenizerOptions) !void {
    if (options.max_token_bytes == 0) return error.Unsupported;
    if (options.emit_cjk_unigrams and options.max_token_bytes < 4) return error.Unsupported;
    if (options.emit_cjk_bigrams and options.max_token_bytes < 8) return error.Unsupported;
}

pub const Decoded = struct {
    codepoint: u21,
    len: usize,
};

pub fn decodeUtf8(bytes: []const u8, offset: usize) Decoded {
    const first = bytes[offset];
    if (first < 0x80) return .{ .codepoint = first, .len = 1 };
    if ((first & 0xe0) == 0xc0 and offset + 1 < bytes.len and isUtf8Continuation(bytes[offset + 1])) {
        const cp = (@as(u21, first & 0x1f) << 6) | @as(u21, bytes[offset + 1] & 0x3f);
        if (cp >= 0x80) return .{ .codepoint = cp, .len = 2 };
    }
    if ((first & 0xf0) == 0xe0 and offset + 2 < bytes.len and isUtf8Continuation(bytes[offset + 1]) and isUtf8Continuation(bytes[offset + 2])) {
        const cp = (@as(u21, first & 0x0f) << 12) |
            (@as(u21, bytes[offset + 1] & 0x3f) << 6) |
            @as(u21, bytes[offset + 2] & 0x3f);
        if (cp >= 0x800 and !(cp >= 0xd800 and cp <= 0xdfff)) return .{ .codepoint = cp, .len = 3 };
    }
    if ((first & 0xf8) == 0xf0 and offset + 3 < bytes.len and isUtf8Continuation(bytes[offset + 1]) and isUtf8Continuation(bytes[offset + 2]) and isUtf8Continuation(bytes[offset + 3])) {
        const cp = (@as(u21, first & 0x07) << 18) |
            (@as(u21, bytes[offset + 1] & 0x3f) << 12) |
            (@as(u21, bytes[offset + 2] & 0x3f) << 6) |
            @as(u21, bytes[offset + 3] & 0x3f);
        if (cp >= 0x10000 and cp <= 0x10ffff) return .{ .codepoint = cp, .len = 4 };
    }
    return .{ .codepoint = first, .len = 1 };
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

pub fn isCjk(cp: u21) bool {
    if (isCjkJoiner(cp)) return false;
    return (cp >= 0x4e00 and cp <= 0x9fff) or
        (cp >= 0x3400 and cp <= 0x4dbf) or
        (cp >= 0x20000 and cp <= 0x323af) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0x2f800 and cp <= 0x2fa1f) or
        (cp >= 0x3100 and cp <= 0x312f) or
        (cp >= 0x31a0 and cp <= 0x31bf) or
        (cp >= 0x3040 and cp <= 0x309f) or
        (cp >= 0x30a0 and cp <= 0x30ff) or
        (cp >= 0x31f0 and cp <= 0x31ff) or
        (cp >= 0xff66 and cp <= 0xff9f) or
        (cp >= 0xffa0 and cp <= 0xffdc) or
        (cp >= 0x1100 and cp <= 0x11ff) or
        (cp >= 0xa960 and cp <= 0xa97f) or
        (cp >= 0x3130 and cp <= 0x318f) or
        (cp >= 0xac00 and cp <= 0xd7af) or
        (cp >= 0xd7b0 and cp <= 0xd7ff);
}

pub fn isCjkJoiner(cp: u21) bool {
    return cp == '-' or
        cp == 0x00b7 or
        (cp >= 0xfe00 and cp <= 0xfe0f) or
        cp == 0x2010 or
        cp == 0x2011 or
        cp == 0x2012 or
        cp == 0x2013 or
        cp == 0x2014 or
        cp == 0x2015 or
        cp == 0x2212 or
        cp == 0x30a0 or
        cp == 0x30fb or
        (cp >= 0xe0100 and cp <= 0xe01ef) or
        cp == 0xff0d or
        cp == 0xff65;
}

pub fn normalizedRunByte(cp: u21) ?u8 {
    if (cp < 0x80) {
        const byte: u8 = @intCast(cp);
        return if (isRunByte(byte)) byte else null;
    }
    if (cp >= 0xff01 and cp <= 0xff5e) {
        const byte: u8 = @intCast(cp - 0xfee0);
        return if (isRunByte(byte)) byte else null;
    }
    return null;
}

pub fn isRunByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == '/';
}

fn appendRunTokens(tokens: *TokenList, run: []const u8, options: TokenizerOptions) !void {
    if (options.emit_original_compound and shouldEmitOriginal(run)) {
        try tokens.appendLowerAscii(run, options.max_token_bytes);
    }

    var part_start: ?usize = null;
    for (run, 0..) |byte, i| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (part_start == null) part_start = i;
        } else if (part_start) |start| {
            try appendIdentifierParts(tokens, run[start..i], options.max_token_bytes);
            part_start = null;
        }
    }
    if (part_start) |start| try appendIdentifierParts(tokens, run[start..], options.max_token_bytes);
}

pub fn shouldEmitOriginal(run: []const u8) bool {
    var has_compound_separator = false;
    var has_alpha = false;
    for (run) |byte| {
        has_compound_separator = has_compound_separator or byte == '_' or byte == '-' or byte == '.' or byte == '/';
        has_alpha = has_alpha or std.ascii.isAlphabetic(byte);
    }
    return has_alpha and (has_compound_separator or containsCamelBoundary(run));
}

pub fn containsCamelBoundary(run: []const u8) bool {
    if (run.len < 2) return false;
    for (run[1..], 1..) |byte, i| {
        const prev = run[i - 1];
        if (std.ascii.isUpper(byte) and (std.ascii.isLower(prev) or std.ascii.isDigit(prev))) return true;
        if (i + 1 < run.len and std.ascii.isUpper(prev) and std.ascii.isUpper(byte) and std.ascii.isLower(run[i + 1])) return true;
    }
    return false;
}

fn appendIdentifierParts(tokens: *TokenList, ident: []const u8, max_token_bytes: usize) !void {
    if (ident.len == 0) return;
    if (containsCamelBoundary(ident)) try tokens.appendLowerAscii(ident, max_token_bytes);

    var start: usize = 0;
    var i: usize = 1;
    while (i < ident.len) : (i += 1) {
        if (isCamelSplit(ident, i)) {
            try tokens.appendLowerAscii(ident[start..i], max_token_bytes);
            start = i;
        }
    }
    try tokens.appendLowerAscii(ident[start..], max_token_bytes);
}

pub fn isCamelSplit(bytes: []const u8, index: usize) bool {
    const current = bytes[index];
    const prev = bytes[index - 1];
    if (std.ascii.isUpper(current) and (std.ascii.isLower(prev) or std.ascii.isDigit(prev))) return true;
    if (index + 1 < bytes.len and std.ascii.isUpper(prev) and std.ascii.isUpper(current) and std.ascii.isLower(bytes[index + 1])) return true;
    return false;
}

pub fn appendNormalizedCjkCodepoint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8, offset: *usize, decoded: Decoded) !void {
    var cp = normalizeHalfwidthHangulJamo(normalizeHalfwidthKatakana(decoded.codepoint));
    offset.* += decoded.len;
    if (composeHangulSyllable(input, offset.*, cp)) |composed| {
        cp = composed.codepoint;
        offset.* = composed.next_offset;
        try appendUtf8(out, allocator, cp);
        return;
    }
    if (isJapaneseVoiceMark(decoded.codepoint)) return;

    if (offset.* < input.len and isJapaneseVoiceBase(cp)) {
        const next = decodeUtf8(input, offset.*);
        if (isJapaneseVoiceMark(next.codepoint)) {
            if (applyJapaneseVoiceMark(cp, next.codepoint)) |voiced| {
                cp = voiced;
                offset.* += next.len;
            }
        }
    }
    cp = normalizeHiraganaToKatakana(cp);
    try appendUtf8(out, allocator, cp);
}

const HangulComposition = struct {
    codepoint: u21,
    next_offset: usize,
};

fn composeHangulSyllable(input: []const u8, offset: usize, leading: u21) ?HangulComposition {
    const l_index = hangulLeadingIndex(leading) orelse return null;
    if (offset >= input.len) return null;
    const vowel = decodeUtf8(input, offset);
    const vowel_cp = normalizeHalfwidthHangulJamo(vowel.codepoint);
    const v_index = hangulVowelIndex(vowel_cp) orelse return null;

    var next_offset = offset + vowel.len;
    var t_index: u21 = 0;
    if (next_offset < input.len) {
        const trailing = decodeUtf8(input, next_offset);
        const trailing_cp = normalizeHalfwidthHangulJamo(trailing.codepoint);
        if (hangulTrailingIndex(trailing_cp)) |idx| {
            const after_trailing = next_offset + trailing.len;
            const compatibility_consonant_starts_next_syllable =
                hangulLeadingIndex(trailing_cp) != null and
                after_trailing < input.len and
                hangulVowelIndex(normalizeHalfwidthHangulJamo(decodeUtf8(input, after_trailing).codepoint)) != null;
            if (!compatibility_consonant_starts_next_syllable) {
                t_index = idx;
                next_offset = after_trailing;
            }
        }
    }

    const syllable = 0xac00 + ((l_index * 21 + v_index) * 28) + t_index;
    return .{ .codepoint = syllable, .next_offset = next_offset };
}

fn hangulLeadingIndex(cp: u21) ?u21 {
    return switch (cp) {
        0x1100 => 0,
        0x3131 => 0,
        0x1101 => 1,
        0x3132 => 1,
        0x1102 => 2,
        0x3134 => 2,
        0x1103 => 3,
        0x3137 => 3,
        0x1104 => 4,
        0x3138 => 4,
        0x1105 => 5,
        0x3139 => 5,
        0x1106 => 6,
        0x3141 => 6,
        0x1107 => 7,
        0x3142 => 7,
        0x1108 => 8,
        0x3143 => 8,
        0x1109 => 9,
        0x3145 => 9,
        0x110a => 10,
        0x3146 => 10,
        0x110b => 11,
        0x3147 => 11,
        0x110c => 12,
        0x3148 => 12,
        0x110d => 13,
        0x3149 => 13,
        0x110e => 14,
        0x314a => 14,
        0x110f => 15,
        0x314b => 15,
        0x1110 => 16,
        0x314c => 16,
        0x1111 => 17,
        0x314d => 17,
        0x1112 => 18,
        0x314e => 18,
        else => null,
    };
}

fn hangulVowelIndex(cp: u21) ?u21 {
    return switch (cp) {
        0x1161 => 0,
        0x314f => 0,
        0x1162 => 1,
        0x3150 => 1,
        0x1163 => 2,
        0x3151 => 2,
        0x1164 => 3,
        0x3152 => 3,
        0x1165 => 4,
        0x3153 => 4,
        0x1166 => 5,
        0x3154 => 5,
        0x1167 => 6,
        0x3155 => 6,
        0x1168 => 7,
        0x3156 => 7,
        0x1169 => 8,
        0x3157 => 8,
        0x116a => 9,
        0x3158 => 9,
        0x116b => 10,
        0x3159 => 10,
        0x116c => 11,
        0x315a => 11,
        0x116d => 12,
        0x315b => 12,
        0x116e => 13,
        0x315c => 13,
        0x116f => 14,
        0x315d => 14,
        0x1170 => 15,
        0x315e => 15,
        0x1171 => 16,
        0x315f => 16,
        0x1172 => 17,
        0x3160 => 17,
        0x1173 => 18,
        0x3161 => 18,
        0x1174 => 19,
        0x3162 => 19,
        0x1175 => 20,
        0x3163 => 20,
        else => null,
    };
}

fn hangulTrailingIndex(cp: u21) ?u21 {
    return switch (cp) {
        0x1100 => 1,
        0x11a8 => 1,
        0x3131 => 1,
        0x1101 => 2,
        0x11a9 => 2,
        0x3132 => 2,
        0x11aa => 3,
        0x3133 => 3,
        0x1102 => 4,
        0x11ab => 4,
        0x3134 => 4,
        0x11ac => 5,
        0x3135 => 5,
        0x11ad => 6,
        0x3136 => 6,
        0x1103 => 7,
        0x11ae => 7,
        0x3137 => 7,
        0x1105 => 8,
        0x11af => 8,
        0x3139 => 8,
        0x11b0 => 9,
        0x313a => 9,
        0x11b1 => 10,
        0x313b => 10,
        0x11b2 => 11,
        0x313c => 11,
        0x11b3 => 12,
        0x313d => 12,
        0x11b4 => 13,
        0x313e => 13,
        0x11b5 => 14,
        0x313f => 14,
        0x11b6 => 15,
        0x3140 => 15,
        0x1106 => 16,
        0x11b7 => 16,
        0x3141 => 16,
        0x1107 => 17,
        0x11b8 => 17,
        0x3142 => 17,
        0x11b9 => 18,
        0x3144 => 18,
        0x1109 => 19,
        0x11ba => 19,
        0x3145 => 19,
        0x110a => 20,
        0x11bb => 20,
        0x3146 => 20,
        0x110b => 21,
        0x11bc => 21,
        0x3147 => 21,
        0x110c => 22,
        0x11bd => 22,
        0x3148 => 22,
        0x110e => 23,
        0x11be => 23,
        0x314a => 23,
        0x110f => 24,
        0x11bf => 24,
        0x314b => 24,
        0x1110 => 25,
        0x11c0 => 25,
        0x314c => 25,
        0x1111 => 26,
        0x11c1 => 26,
        0x314d => 26,
        0x1112 => 27,
        0x11c2 => 27,
        0x314e => 27,
        else => null,
    };
}

fn appendUtf8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u21) !void {
    if (cp < 0x80) {
        try out.append(allocator, @intCast(cp));
    } else if (cp < 0x800) {
        try out.append(allocator, @intCast(0xc0 | (cp >> 6)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    } else if (cp < 0x10000) {
        try out.append(allocator, @intCast(0xe0 | (cp >> 12)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    } else {
        try out.append(allocator, @intCast(0xf0 | (cp >> 18)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    }
}

fn isHalfwidthKatakana(cp: u21) bool {
    return cp >= 0xff66 and cp <= 0xff9d;
}

fn isJapaneseVoiceMark(cp: u21) bool {
    return cp == 0xff9e or cp == 0xff9f or cp == 0x3099 or cp == 0x309a or cp == 0x309b or cp == 0x309c;
}

fn isJapaneseHandakutenMark(cp: u21) bool {
    return cp == 0xff9f or cp == 0x309a or cp == 0x309c;
}

fn isJapaneseVoiceBase(cp: u21) bool {
    return isHalfwidthKatakana(cp) or (cp >= 0x3040 and cp <= 0x30ff);
}

fn normalizeHalfwidthKatakana(cp: u21) u21 {
    return switch (cp) {
        0xff66 => 0x30f2,
        0xff67 => 0x30a1,
        0xff68 => 0x30a3,
        0xff69 => 0x30a5,
        0xff6a => 0x30a7,
        0xff6b => 0x30a9,
        0xff6c => 0x30e3,
        0xff6d => 0x30e5,
        0xff6e => 0x30e7,
        0xff6f => 0x30c3,
        0xff70 => 0x30fc,
        0xff71 => 0x30a2,
        0xff72 => 0x30a4,
        0xff73 => 0x30a6,
        0xff74 => 0x30a8,
        0xff75 => 0x30aa,
        0xff76 => 0x30ab,
        0xff77 => 0x30ad,
        0xff78 => 0x30af,
        0xff79 => 0x30b1,
        0xff7a => 0x30b3,
        0xff7b => 0x30b5,
        0xff7c => 0x30b7,
        0xff7d => 0x30b9,
        0xff7e => 0x30bb,
        0xff7f => 0x30bd,
        0xff80 => 0x30bf,
        0xff81 => 0x30c1,
        0xff82 => 0x30c4,
        0xff83 => 0x30c6,
        0xff84 => 0x30c8,
        0xff85 => 0x30ca,
        0xff86 => 0x30cb,
        0xff87 => 0x30cc,
        0xff88 => 0x30cd,
        0xff89 => 0x30ce,
        0xff8a => 0x30cf,
        0xff8b => 0x30d2,
        0xff8c => 0x30d5,
        0xff8d => 0x30d8,
        0xff8e => 0x30db,
        0xff8f => 0x30de,
        0xff90 => 0x30df,
        0xff91 => 0x30e0,
        0xff92 => 0x30e1,
        0xff93 => 0x30e2,
        0xff94 => 0x30e4,
        0xff95 => 0x30e6,
        0xff96 => 0x30e8,
        0xff97 => 0x30e9,
        0xff98 => 0x30ea,
        0xff99 => 0x30eb,
        0xff9a => 0x30ec,
        0xff9b => 0x30ed,
        0xff9c => 0x30ef,
        0xff9d => 0x30f3,
        else => cp,
    };
}

fn normalizeHalfwidthHangulJamo(cp: u21) u21 {
    return switch (cp) {
        0xffa0 => 0x1160,
        0xffa1 => 0x1100,
        0xffa2 => 0x1101,
        0xffa3 => 0x11aa,
        0xffa4 => 0x1102,
        0xffa5 => 0x11ac,
        0xffa6 => 0x11ad,
        0xffa7 => 0x1103,
        0xffa8 => 0x1104,
        0xffa9 => 0x1105,
        0xffaa => 0x11b0,
        0xffab => 0x11b1,
        0xffac => 0x11b2,
        0xffad => 0x11b3,
        0xffae => 0x11b4,
        0xffaf => 0x11b5,
        0xffb0 => 0x111a,
        0xffb1 => 0x1106,
        0xffb2 => 0x1107,
        0xffb3 => 0x1108,
        0xffb4 => 0x1121,
        0xffb5 => 0x1109,
        0xffb6 => 0x110a,
        0xffb7 => 0x110b,
        0xffb8 => 0x110c,
        0xffb9 => 0x110d,
        0xffba => 0x110e,
        0xffbb => 0x110f,
        0xffbc => 0x1110,
        0xffbd => 0x1111,
        0xffbe => 0x1112,
        0xffc2 => 0x1161,
        0xffc3 => 0x1162,
        0xffc4 => 0x1163,
        0xffc5 => 0x1164,
        0xffc6 => 0x1165,
        0xffc7 => 0x1166,
        0xffca => 0x1167,
        0xffcb => 0x1168,
        0xffcc => 0x1169,
        0xffcd => 0x116a,
        0xffce => 0x116b,
        0xffcf => 0x116c,
        0xffd2 => 0x116d,
        0xffd3 => 0x116e,
        0xffd4 => 0x116f,
        0xffd5 => 0x1170,
        0xffd6 => 0x1171,
        0xffd7 => 0x1172,
        0xffda => 0x1173,
        0xffdb => 0x1174,
        0xffdc => 0x1175,
        else => cp,
    };
}

fn normalizeHiraganaToKatakana(cp: u21) u21 {
    return if (cp >= 0x3041 and cp <= 0x3096) cp + 0x60 else cp;
}

fn applyJapaneseVoiceMark(cp: u21, mark: u21) ?u21 {
    if (isJapaneseHandakutenMark(mark)) {
        return switch (cp) {
            0x306f => 0x3071,
            0x3072 => 0x3074,
            0x3075 => 0x3077,
            0x3078 => 0x307a,
            0x307b => 0x307d,
            0x30cf => 0x30d1,
            0x30d2 => 0x30d4,
            0x30d5 => 0x30d7,
            0x30d8 => 0x30da,
            0x30db => 0x30dd,
            else => null,
        };
    }
    return switch (cp) {
        0x3046 => 0x3094,
        0x304b => 0x304c,
        0x304d => 0x304e,
        0x304f => 0x3050,
        0x3051 => 0x3052,
        0x3053 => 0x3054,
        0x3055 => 0x3056,
        0x3057 => 0x3058,
        0x3059 => 0x305a,
        0x305b => 0x305c,
        0x305d => 0x305e,
        0x305f => 0x3060,
        0x3061 => 0x3062,
        0x3064 => 0x3065,
        0x3066 => 0x3067,
        0x3068 => 0x3069,
        0x306f => 0x3070,
        0x3072 => 0x3073,
        0x3075 => 0x3076,
        0x3078 => 0x3079,
        0x307b => 0x307c,
        0x30a6 => 0x30f4,
        0x30ab => 0x30ac,
        0x30ad => 0x30ae,
        0x30af => 0x30b0,
        0x30b1 => 0x30b2,
        0x30b3 => 0x30b4,
        0x30b5 => 0x30b6,
        0x30b7 => 0x30b8,
        0x30b9 => 0x30ba,
        0x30bb => 0x30bc,
        0x30bd => 0x30be,
        0x30bf => 0x30c0,
        0x30c1 => 0x30c2,
        0x30c4 => 0x30c5,
        0x30c6 => 0x30c7,
        0x30c8 => 0x30c9,
        0x30cf => 0x30d0,
        0x30d2 => 0x30d3,
        0x30d5 => 0x30d6,
        0x30d8 => 0x30d9,
        0x30db => 0x30dc,
        0x30ef => 0x30f7,
        0x30f0 => 0x30f8,
        0x30f1 => 0x30f9,
        0x30f2 => 0x30fa,
        else => null,
    };
}

fn appendCjkTokens(tokens: *TokenList, bytes: []const u8, options: TokenizerOptions) !void {
    var offsets = std.ArrayList(usize).empty;
    defer offsets.deinit(tokens.allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        try offsets.append(tokens.allocator, i);
        i += decodeUtf8(bytes, i).len;
    }

    if (options.emit_cjk_unigrams) {
        for (0..offsets.items.len) |idx| {
            const start = offsets.items[idx];
            const end = if (idx + 1 < offsets.items.len) offsets.items[idx + 1] else bytes.len;
            const token = try tokens.allocator.dupe(u8, bytes[start..end]);
            try tokens.appendOwned(token, options.max_token_bytes);
        }
    }

    if (options.emit_cjk_bigrams and offsets.items.len >= 2) {
        for (0..offsets.items.len - 1) |idx| {
            const start = offsets.items[idx];
            const end = if (idx + 2 < offsets.items.len) offsets.items[idx + 2] else bytes.len;
            const token = try tokens.allocator.dupe(u8, bytes[start..end]);
            try tokens.appendOwned(token, options.max_token_bytes);
        }
    }
}

test "tokenizer splits code paths and preserves full path token" {
    var tokens = try tokenize(std.testing.allocator, "src/ql/executor.zig", .{});
    defer tokens.deinit();

    try std.testing.expect(tokens.contains("src/ql/executor.zig"));
    try std.testing.expect(tokens.contains("src"));
    try std.testing.expect(tokens.contains("ql"));
    try std.testing.expect(tokens.contains("executor"));
    try std.testing.expect(tokens.contains("zig"));
}

test "tokenizer splits camel identifiers and preserves normalized identifier" {
    var tokens = try tokenize(std.testing.allocator, "readEdgeIndexRecordsByNode", .{});
    defer tokens.deinit();

    try std.testing.expect(tokens.contains("readedgeindexrecordsbynode"));
    try std.testing.expect(tokens.contains("read"));
    try std.testing.expect(tokens.contains("edge"));
    try std.testing.expect(tokens.contains("index"));
    try std.testing.expect(tokens.contains("records"));
    try std.testing.expect(tokens.contains("by"));
    try std.testing.expect(tokens.contains("node"));
}

test "tokenizer handles dotted Zig symbols with whole and part terms" {
    var tokens = try tokenize(std.testing.allocator, "std.mem.Allocator", .{});
    defer tokens.deinit();

    try std.testing.expect(tokens.contains("std.mem.allocator"));
    try std.testing.expect(tokens.contains("std"));
    try std.testing.expect(tokens.contains("mem"));
    try std.testing.expect(tokens.contains("allocator"));
}

test "tokenizer caps adversarially long tokens" {
    var tokens = try tokenize(std.testing.allocator, "short aaaaaaaaaaaaaaaaaaaa", .{ .max_token_bytes = 8 });
    defer tokens.deinit();

    try std.testing.expect(tokens.contains("short"));
    try std.testing.expect(!tokens.contains("aaaaaaaaaaaaaaaaaaaa"));
}

test "tokenizer rejects options that cannot preserve CJK fallback terms" {
    try std.testing.expectError(error.Unsupported, tokenize(std.testing.allocator, "short", .{ .max_token_bytes = 0 }));
    try std.testing.expectError(error.Unsupported, tokenize(std.testing.allocator, "错误", .{ .max_token_bytes = 3 }));
    try std.testing.expectError(error.Unsupported, tokenize(std.testing.allocator, "错误", .{ .max_token_bytes = 7 }));

    var unigram_only = try tokenize(std.testing.allocator, "错误", .{ .max_token_bytes = 4, .emit_cjk_bigrams = false });
    defer unigram_only.deinit();
    try std.testing.expect(unigram_only.contains("错"));
    try std.testing.expect(!unigram_only.contains("错误"));
}

test "tokenizer emits CJK unigrams and bigrams" {
    var tokens = try tokenize(std.testing.allocator, "错误记录", .{});
    defer tokens.deinit();

    try std.testing.expect(tokens.contains("错"));
    try std.testing.expect(tokens.contains("误"));
    try std.testing.expect(tokens.contains("错误"));
    try std.testing.expect(tokens.contains("误记"));
    try std.testing.expect(tokens.contains("记录"));
}

test "tokenizer bridges narrow CJK joiners" {
    var chinese = try tokenize(std.testing.allocator, "错误-记录", .{});
    defer chinese.deinit();
    try std.testing.expect(chinese.contains("错误"));
    try std.testing.expect(chinese.contains("误记"));
    try std.testing.expect(chinese.contains("记录"));
    try std.testing.expect(!chinese.contains("-"));

    var japanese = try tokenize(std.testing.allocator, "エラー・解析", .{});
    defer japanese.deinit();
    try std.testing.expect(japanese.contains("ラー"));
    try std.testing.expect(japanese.contains("ー解"));
    try std.testing.expect(japanese.contains("解析"));
    try std.testing.expect(!japanese.contains("・"));

    var separated = try tokenize(std.testing.allocator, "错误 记录", .{});
    defer separated.deinit();
    try std.testing.expect(separated.contains("错误"));
    try std.testing.expect(separated.contains("记录"));
    try std.testing.expect(!separated.contains("误记"));
}

test "tokenizer bridges CJK variation selectors" {
    var bmp_selector = try tokenize(std.testing.allocator, "禰\u{fe00}豆子", .{});
    defer bmp_selector.deinit();
    try std.testing.expect(bmp_selector.contains("禰"));
    try std.testing.expect(bmp_selector.contains("禰豆"));
    try std.testing.expect(bmp_selector.contains("豆子"));
    try std.testing.expect(!bmp_selector.contains("\u{fe00}"));

    var supplementary_selector = try tokenize(std.testing.allocator, "禰\u{e0100}豆子", .{});
    defer supplementary_selector.deinit();
    try std.testing.expect(supplementary_selector.contains("禰"));
    try std.testing.expect(supplementary_selector.contains("禰豆"));
    try std.testing.expect(supplementary_selector.contains("豆子"));
    try std.testing.expect(!supplementary_selector.contains("\u{e0100}"));
}

test "tokenizer covers Japanese kana and Korean hangul fallback" {
    var japanese = try tokenize(std.testing.allocator, "解析エラー", .{});
    defer japanese.deinit();
    try std.testing.expect(japanese.contains("解析"));
    try std.testing.expect(japanese.contains("エラ"));
    try std.testing.expect(japanese.contains("ー"));

    var korean = try tokenize(std.testing.allocator, "오류기록", .{});
    defer korean.deinit();
    try std.testing.expect(korean.contains("오"));
    try std.testing.expect(korean.contains("오류"));
    try std.testing.expect(korean.contains("기록"));
}

test "tokenizer covers CJK compatibility, halfwidth kana folding, and Hangul extensions" {
    var bopomofo = try tokenize(std.testing.allocator, "ㄅㄆ索引", .{});
    defer bopomofo.deinit();
    try std.testing.expect(bopomofo.contains("ㄅ"));
    try std.testing.expect(bopomofo.contains("ㄅㄆ"));
    try std.testing.expect(bopomofo.contains("索引"));

    var halfwidth_kana = try tokenize(std.testing.allocator, "ｴﾗｰ解析", .{});
    defer halfwidth_kana.deinit();
    try std.testing.expect(halfwidth_kana.contains("エ"));
    try std.testing.expect(halfwidth_kana.contains("エラ"));
    try std.testing.expect(halfwidth_kana.contains("ラー"));
    try std.testing.expect(halfwidth_kana.contains("解析"));

    var voiced_kana = try tokenize(std.testing.allocator, "ｶﾞｲﾄﾞﾊﾟｽ", .{});
    defer voiced_kana.deinit();
    try std.testing.expect(voiced_kana.contains("ガ"));
    try std.testing.expect(voiced_kana.contains("ガイ"));
    try std.testing.expect(voiced_kana.contains("ドパ"));
    try std.testing.expect(voiced_kana.contains("パ"));

    var decomposed_kana = try tokenize(std.testing.allocator, "カ\u{3099}イド は\u{309a}す", .{});
    defer decomposed_kana.deinit();
    try std.testing.expect(decomposed_kana.contains("ガ"));
    try std.testing.expect(decomposed_kana.contains("ガイ"));
    try std.testing.expect(decomposed_kana.contains("パ"));
    try std.testing.expect(decomposed_kana.contains("パス"));
    try std.testing.expect(!decomposed_kana.contains("ぱ"));
    try std.testing.expect(!decomposed_kana.contains("ぱす"));
    try std.testing.expect(!decomposed_kana.contains("\u{3099}"));
    try std.testing.expect(!decomposed_kana.contains("\u{309a}"));

    var hiragana = try tokenize(std.testing.allocator, "えらーぱす", .{});
    defer hiragana.deinit();
    try std.testing.expect(hiragana.contains("エ"));
    try std.testing.expect(hiragana.contains("エラ"));
    try std.testing.expect(hiragana.contains("ラー"));
    try std.testing.expect(hiragana.contains("パス"));
    try std.testing.expect(!hiragana.contains("え"));
    try std.testing.expect(!hiragana.contains("えら"));

    var hangul_jamo = try tokenize(std.testing.allocator, "ꥠힰ", .{});
    defer hangul_jamo.deinit();
    try std.testing.expect(hangul_jamo.contains("ꥠ"));
    try std.testing.expect(hangul_jamo.contains("ꥠힰ"));

    var decomposed_hangul = try tokenize(std.testing.allocator, "오류기록", .{});
    defer decomposed_hangul.deinit();
    try std.testing.expect(decomposed_hangul.contains("오"));
    try std.testing.expect(decomposed_hangul.contains("오류"));
    try std.testing.expect(decomposed_hangul.contains("기록"));
    try std.testing.expect(!decomposed_hangul.contains("ᄋ"));
    try std.testing.expect(!decomposed_hangul.contains("오"));

    var compatibility_hangul = try tokenize(std.testing.allocator, "ㅇㅗㄹㅠㄱㅣㄹㅗㄱ", .{});
    defer compatibility_hangul.deinit();
    try std.testing.expect(compatibility_hangul.contains("오"));
    try std.testing.expect(compatibility_hangul.contains("오류"));
    try std.testing.expect(compatibility_hangul.contains("기록"));
    try std.testing.expect(!compatibility_hangul.contains("ㅇ"));
    try std.testing.expect(!compatibility_hangul.contains("ㅇㅗ"));

    var compatibility_hangul_final = try tokenize(std.testing.allocator, "ㄱㅏㄱ", .{});
    defer compatibility_hangul_final.deinit();
    try std.testing.expect(compatibility_hangul_final.contains("각"));
    try std.testing.expect(!compatibility_hangul_final.contains("가"));

    var halfwidth_hangul = try tokenize(std.testing.allocator, "\u{ffb7}\u{ffcc}\u{ffa9}\u{ffd7}\u{ffa1}\u{ffdc}\u{ffa9}\u{ffcc}\u{ffa1}", .{});
    defer halfwidth_hangul.deinit();
    try std.testing.expect(halfwidth_hangul.contains("오"));
    try std.testing.expect(halfwidth_hangul.contains("오류"));
    try std.testing.expect(halfwidth_hangul.contains("기록"));
    try std.testing.expect(!halfwidth_hangul.contains("\u{ffb7}"));
    try std.testing.expect(!halfwidth_hangul.contains("\u{ffb7}\u{ffcc}"));

    var extension_i = try tokenize(std.testing.allocator, "\u{2ebf0}索引", .{});
    defer extension_i.deinit();
    try std.testing.expect(extension_i.contains("\u{2ebf0}"));
    try std.testing.expect(extension_i.contains("\u{2ebf0}索"));
}

test "tokenizer folds fullwidth ASCII code text" {
    var symbol = try tokenize(std.testing.allocator, "ＩｎｖａｌｉｄＲｅｃｏｒｄ", .{});
    defer symbol.deinit();
    try std.testing.expect(symbol.contains("invalidrecord"));
    try std.testing.expect(symbol.contains("invalid"));
    try std.testing.expect(symbol.contains("record"));

    var path = try tokenize(std.testing.allocator, "ｓｒｃ／ｍａｉｎ．ｚｉｇ", .{});
    defer path.deinit();
    try std.testing.expect(path.contains("src/main.zig"));
    try std.testing.expect(path.contains("src"));
    try std.testing.expect(path.contains("main"));
    try std.testing.expect(path.contains("zig"));
}

test "tokenizer separates mixed code identifiers and CJK text" {
    var tokens = try tokenize(std.testing.allocator, "parse错误InvalidRecord", .{});
    defer tokens.deinit();

    try std.testing.expect(tokens.contains("parse"));
    try std.testing.expect(tokens.contains("错误"));
    try std.testing.expect(tokens.contains("invalidrecord"));
    try std.testing.expect(tokens.contains("invalid"));
    try std.testing.expect(tokens.contains("record"));
    try std.testing.expect(!tokens.contains("parse错误"));
    try std.testing.expect(!tokens.contains("误invalid"));
}

test "tokenizer treats invalid utf8 bytes as separators for CJK runs" {
    var tokens = try tokenize(std.testing.allocator, "错误\xc0\x80记录", .{});
    defer tokens.deinit();

    try std.testing.expect(tokens.contains("错误"));
    try std.testing.expect(tokens.contains("记录"));
    try std.testing.expect(!tokens.contains("误记"));
}

fn tokenizerAllocationFailure(allocator: std.mem.Allocator) !void {
    var tokens = try tokenize(allocator, "parse错误InvalidRecord std.mem.Allocator", .{});
    defer tokens.deinit();
    try std.testing.expect(tokens.contains("错误"));
    try std.testing.expect(tokens.contains("invalidrecord"));
    try std.testing.expect(tokens.contains("std.mem.allocator"));
}

test "tokenizer rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, tokenizerAllocationFailure, .{});
}

test "token count helper follows tokenizer options" {
    try std.testing.expectEqual(@as(u64, 4), try countTokens(std.testing.allocator, "src/main.zig", .{}));
    try std.testing.expectEqual(@as(u64, 3), try countTokens(std.testing.allocator, "错误", .{}));
    try std.testing.expectEqual(@as(u64, 2), try countTokens(std.testing.allocator, "错误", .{ .emit_cjk_bigrams = false }));
}

test "term frequency helper counts normalized tokens" {
    try std.testing.expectEqual(@as(u32, 2), try countTermInText(std.testing.allocator, "InvalidRecord invalid_record", "invalid"));
    try std.testing.expectEqual(@as(u32, 2), try countTermInText(std.testing.allocator, "错误错误", "错误"));
    try std.testing.expectEqual(@as(u32, 0), try countTermInText(std.testing.allocator, "错误记录", "missing"));
}
