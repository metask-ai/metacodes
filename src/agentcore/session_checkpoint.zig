//! AgentCore-owned Session checkpoint envelope and streaming codec.
//!
//! Persistence media, encryption, authenticity and retention remain Host
//! responsibilities. This module owns only the bounded canonical envelope.

const std = @import("std");
const core = @import("metacodes-core");
const Conversation = core.conversation.Conversation;
const message = core.message;
const SessionId = core.session_id.SessionId;

pub const STATE_SCHEMA_REVISION: u32 = 1;
/// Persisted compatibility marker for the current checkpoint envelope. This is
/// intentionally independent from the public AgentCore API table revision.
pub const CHECKPOINT_COMPATIBILITY_MARKER: u32 = 8;
pub const HEADER_BYTES: usize = 192;
pub const DIGEST_BYTES: usize = 32;
pub const MIN_CHECKPOINT_BUDGET: u64 = HEADER_BYTES + DIGEST_BYTES + 1;
pub const ABSOLUTE_MAX_CHECKPOINT_BYTES: u64 = 1024 * 1024 * 1024;
pub const DEFAULT_MAX_SECTION_BYTES: u64 = 256 * 1024 * 1024;
pub const DEFAULT_MAX_STRING_BYTES: u64 = 16 * 1024 * 1024;
pub const DEFAULT_MAX_MESSAGES: u64 = 1_000_000;
pub const DEFAULT_MAX_BLOCKS_PER_MESSAGE: u64 = 4096;
pub const DEFAULT_CHUNK_BYTES: u32 = 64 * 1024;
pub const MAX_CHUNK_BYTES: u32 = 1024 * 1024;

const magic = "METASK-R6-CKPT\x00\x00";
const section_count: u32 = 6;
const flag_has_compact_summary: u32 = 1 << 0;

pub const Error = error{
    OutOfMemory,
    InvalidBudget,
    ResourceLimit,
    Corrupt,
    UnsupportedSchema,
    IncompatibleAbi,
    SinkFailed,
    SourceFailed,
};

pub const Limits = struct {
    hard_bytes: u64,
    chunk_bytes: u32 = DEFAULT_CHUNK_BYTES,
    max_section_bytes: u64 = DEFAULT_MAX_SECTION_BYTES,
    max_string_bytes: u64 = DEFAULT_MAX_STRING_BYTES,
    max_messages: u64 = DEFAULT_MAX_MESSAGES,
    max_blocks_per_message: u64 = DEFAULT_MAX_BLOCKS_PER_MESSAGE,

    pub fn validate(self: Limits) Error!void {
        if (self.hard_bytes < MIN_CHECKPOINT_BUDGET or
            self.hard_bytes > ABSOLUTE_MAX_CHECKPOINT_BYTES or
            self.chunk_bytes == 0 or self.chunk_bytes > MAX_CHUNK_BYTES or
            self.max_section_bytes == 0 or
            self.max_section_bytes > ABSOLUTE_MAX_CHECKPOINT_BYTES or
            self.max_string_bytes == 0 or
            self.max_string_bytes > self.max_section_bytes or
            self.max_messages == 0 or self.max_blocks_per_message == 0)
            return error.InvalidBudget;
    }
};

pub const TerminalKind = enum(u32) {
    none = 0,
    run = 1,
    compact = 2,
    budget_exhausted = 3,
    resource_limit = 4,
};

pub const AuthoritySections = struct {
    skill: []const u8 = "",
    permission: []const u8 = "",
    mcp: []const u8 = "",
};

/// All slices are borrowed and must remain immutable for the synchronous
/// export call. No credential, callback, pointer or live handle field exists.
pub const Snapshot = struct {
    session_id: SessionId,
    checkpoint_generation: u64,
    last_run_id: u64,
    last_compact_id: u64,
    terminal_kind: TerminalKind,
    terminal_id: u64,
    model: []const u8,
    conversation: *const Conversation,
    policy_generation: u64 = 0,
    catalog_generation: u64 = 0,
    authority: AuthoritySections = .{},
};

pub const Descriptor = struct {
    session_id: SessionId,
    checkpoint_generation: u64,
    total_bytes: u64,
    last_run_id: u64,
    last_compact_id: u64,
    terminal_kind: TerminalKind,
    terminal_id: u64,
    policy_generation: u64,
    catalog_generation: u64,
};

pub const Decoded = struct {
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    model: []u8,
    conversation: Conversation,
    skill_state: []u8,
    permission_state: []u8,
    mcp_state: []u8,

    pub fn deinit(self: *Decoded) void {
        self.conversation.deinit();
        self.allocator.free(self.model);
        self.allocator.free(self.skill_state);
        self.allocator.free(self.permission_state);
        self.allocator.free(self.mcp_state);
        self.* = undefined;
    }
};

pub const Sink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

pub const Source = struct {
    ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, out: []u8) anyerror!usize,
};

pub const ExportReport = struct {
    total_bytes: u64,
    chunk_count: u64,
    digest: [DIGEST_BYTES]u8,
};

pub const Usage = struct {
    total_bytes: u64,
    message_bytes: u64,
    message_count: u64,
};

const Measurement = struct {
    total_bytes: u64,
    message_bytes: u64,
    message_count: u64,
    compact_boundary: u64,
    model_bytes: u64,
    summary_bytes: u64,
    skill_bytes: u64,
    permission_bytes: u64,
    mcp_bytes: u64,
    flags: u32,
};

pub fn exportToSink(snapshot: Snapshot, limits: Limits, sink: Sink) Error!ExportReport {
    try limits.validate();
    const measured = try measure(snapshot, limits);
    var header = encodeHeader(snapshot, measured);
    var writer = Writer.init(sink, limits, measured.total_bytes);
    try writer.writeHashed(&header);
    try writer.writeHashed(snapshot.model);
    if (snapshot.conversation.compact_summary) |summary|
        try writer.writeHashed(summary);
    try writer.writeHashed(snapshot.authority.skill);
    try writer.writeHashed(snapshot.authority.permission);
    try writer.writeHashed(snapshot.authority.mcp);
    for (snapshot.conversation.activeMessages()) |item|
        try writeMessage(&writer, item);
    var digest: [DIGEST_BYTES]u8 = undefined;
    writer.hasher.final(&digest);
    try writer.writeDigest(&digest);
    if (writer.written != measured.total_bytes) return error.Corrupt;
    return .{
        .total_bytes = measured.total_bytes,
        .chunk_count = writer.chunk_count,
        .digest = digest,
    };
}

/// Measure the exact canonical checkpoint representation without touching a
/// Host sink. Admission code uses this to preserve the durable-state invariant
/// before accepting another state change.
pub fn measureSnapshot(snapshot: Snapshot, limits: Limits) Error!Usage {
    const measured = try measure(snapshot, limits);
    return .{
        .total_bytes = measured.total_bytes,
        .message_bytes = measured.message_bytes,
        .message_count = measured.message_count,
    };
}

/// Exact encoded delta for one Message containing one text block. Text Runs
/// reserve their pre-admission root record through this; multimodal Runs use
/// `encodedUserPartsMessageBytes`.
pub fn encodedTextMessageBytes(bytes: []const u8) Error!u64 {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Corrupt;
    return checkedAdd(14, bytes.len);
}

/// Exact encoded delta for one user Message built from ordered text/image
/// parts, matching `measureMessage` byte for byte: 1 role byte + 4 count
/// bytes, then per block one tag byte plus 8-byte-length-prefixed strings
/// (text, or media_type then base64 data).
pub fn encodedUserPartsMessageBytes(parts: []const message.UserContentPart) Error!u64 {
    if (parts.len == 0) return error.Corrupt;
    var size: u64 = 1 + 4;
    for (parts) |part| {
        size = try checkedAdd(size, 1);
        switch (part) {
            .text => |bytes| {
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.Corrupt;
                size = try checkedAdd(try checkedAdd(size, 8), bytes.len);
            },
            .image => |image| {
                if (!std.unicode.utf8ValidateSlice(image.media_type) or
                    !std.unicode.utf8ValidateSlice(image.data))
                    return error.Corrupt;
                size = try checkedAdd(try checkedAdd(size, 8), image.media_type.len);
                size = try checkedAdd(try checkedAdd(size, 8), image.data.len);
            },
        }
    }
    return size;
}

pub fn decodeFromSource(
    allocator: std.mem.Allocator,
    source: Source,
    limits: Limits,
) Error!Decoded {
    try limits.validate();
    var reader = Reader.init(source, limits);
    var header: [HEADER_BYTES]u8 = undefined;
    try reader.readHashed(&header);
    const parsed = try parseHeader(&header, limits);
    reader.expected_total = parsed.measurement.total_bytes;

    const model = try reader.readOwned(
        allocator,
        parsed.measurement.model_bytes,
        parsed.payload_end,
    );
    errdefer allocator.free(model);
    if (model.len == 0 or !std.unicode.utf8ValidateSlice(model))
        return error.Corrupt;
    const summary = if ((parsed.measurement.flags & flag_has_compact_summary) != 0)
        try reader.readOwned(
            allocator,
            parsed.measurement.summary_bytes,
            parsed.payload_end,
        )
    else
        null;
    defer if (summary) |bytes| allocator.free(bytes);
    if (summary) |bytes| if (!std.unicode.utf8ValidateSlice(bytes))
        return error.Corrupt;

    const skill_state = try reader.readOwned(
        allocator,
        parsed.measurement.skill_bytes,
        parsed.payload_end,
    );
    errdefer allocator.free(skill_state);
    const permission_state = try reader.readOwned(
        allocator,
        parsed.measurement.permission_bytes,
        parsed.payload_end,
    );
    errdefer allocator.free(permission_state);
    const mcp_state = try reader.readOwned(
        allocator,
        parsed.measurement.mcp_bytes,
        parsed.payload_end,
    );
    errdefer allocator.free(mcp_state);

    var conversation = Conversation.init(allocator);
    errdefer conversation.deinit();
    // A checkpoint is resumable canonical state, not a transcript archive.
    // Materialize the compact summary as the first assistant message so a
    // later compact includes it even though the hidden raw prefix was omitted.
    if (summary) |bytes| try conversation.appendText(.assistant, bytes);
    var message_index: u64 = 0;
    while (message_index < parsed.measurement.message_count) : (message_index += 1) {
        const item = try readMessage(
            &reader,
            allocator,
            parsed.messages_end,
            limits,
        );
        conversation.append(item) catch |err| switch (err) {
            error.OutOfMemory => {
                item.deinit(allocator);
                return error.OutOfMemory;
            },
        };
    }
    if (reader.position != parsed.messages_end or
        parsed.measurement.compact_boundary != 0)
        return error.Corrupt;

    var expected_digest: [DIGEST_BYTES]u8 = undefined;
    reader.hasher.final(&expected_digest);
    var actual_digest: [DIGEST_BYTES]u8 = undefined;
    try reader.readUnhashed(&actual_digest);
    if (!std.mem.eql(u8, &expected_digest, &actual_digest))
        return error.Corrupt;
    var trailing: [1]u8 = undefined;
    const extra = source.read_fn(source.ctx, &trailing) catch
        return error.SourceFailed;
    if (extra != 0) return error.Corrupt;
    if (reader.position != parsed.measurement.total_bytes)
        return error.Corrupt;
    // Every byte has been hashed and the digest verified: the file is intact.
    // Only now may a withdrawn revision-16 document block (tag 7) turn the
    // result into "unsupported schema"; any earlier, the same answer could have
    // masked corruption. The decoded state is released by the errdefer chain.
    if (reader.withdrawn_blocks != 0) return error.UnsupportedSchema;

    return .{
        .allocator = allocator,
        .descriptor = parsed.descriptor,
        .model = model,
        .conversation = conversation,
        .skill_state = skill_state,
        .permission_state = permission_state,
        .mcp_state = mcp_state,
    };
}

fn measure(snapshot: Snapshot, limits: Limits) Error!Measurement {
    if (snapshot.checkpoint_generation == 0 or snapshot.model.len == 0 or
        !std.unicode.utf8ValidateSlice(snapshot.model))
        return error.Corrupt;
    try validateTerminal(snapshot);
    const model_bytes = try boundedLength(snapshot.model, limits);
    const summary_bytes = if (snapshot.conversation.compact_summary) |summary| blk: {
        if (!std.unicode.utf8ValidateSlice(summary)) return error.Corrupt;
        break :blk try boundedLength(summary, limits);
    } else 0;
    const skill_bytes = try boundedSection(snapshot.authority.skill, limits);
    const permission_bytes = try boundedSection(snapshot.authority.permission, limits);
    const mcp_bytes = try boundedSection(snapshot.authority.mcp, limits);
    const active_messages = snapshot.conversation.activeMessages();
    const message_count: u64 = @intCast(active_messages.len);
    const restored_message_count = try checkedAdd(
        message_count,
        @intFromBool(snapshot.conversation.compact_summary != null),
    );
    if (restored_message_count > limits.max_messages) return error.ResourceLimit;
    // Hidden pre-compact messages are transcript history, not resumable model
    // state. The summary section plus active messages is the exact projection
    // seen by the next provider call.
    const compact_boundary: u64 = 0;
    var message_bytes: u64 = 0;
    for (active_messages) |item|
        message_bytes = try checkedAdd(message_bytes, try measureMessage(item, limits));
    if (message_bytes > limits.max_section_bytes) return error.ResourceLimit;
    var payload_bytes = try checkedAdd(model_bytes, summary_bytes);
    payload_bytes = try checkedAdd(payload_bytes, skill_bytes);
    payload_bytes = try checkedAdd(payload_bytes, permission_bytes);
    payload_bytes = try checkedAdd(payload_bytes, mcp_bytes);
    payload_bytes = try checkedAdd(payload_bytes, message_bytes);
    var total_bytes = try checkedAdd(HEADER_BYTES, payload_bytes);
    total_bytes = try checkedAdd(total_bytes, DIGEST_BYTES);
    if (total_bytes > limits.hard_bytes or
        total_bytes > ABSOLUTE_MAX_CHECKPOINT_BYTES)
        return error.ResourceLimit;
    return .{
        .total_bytes = total_bytes,
        .message_bytes = message_bytes,
        .message_count = message_count,
        .compact_boundary = compact_boundary,
        .model_bytes = model_bytes,
        .summary_bytes = summary_bytes,
        .skill_bytes = skill_bytes,
        .permission_bytes = permission_bytes,
        .mcp_bytes = mcp_bytes,
        .flags = if (snapshot.conversation.compact_summary != null)
            flag_has_compact_summary
        else
            0,
    };
}

fn validateTerminal(snapshot: Snapshot) Error!void {
    try validateTerminalFields(
        snapshot.terminal_kind,
        snapshot.terminal_id,
        snapshot.last_run_id,
        snapshot.last_compact_id,
    );
}

fn validateTerminalFields(
    terminal_kind: TerminalKind,
    terminal_id: u64,
    last_run_id: u64,
    last_compact_id: u64,
) Error!void {
    switch (terminal_kind) {
        .none => if (terminal_id != 0 or last_run_id != 0 or
            last_compact_id != 0) return error.Corrupt,
        .run => if (terminal_id == 0 or
            terminal_id != last_run_id) return error.Corrupt,
        .compact => if (terminal_id == 0 or
            terminal_id != last_compact_id) return error.Corrupt,
        .budget_exhausted, .resource_limit => if (terminal_id == 0 or
            terminal_id != last_run_id) return error.Corrupt,
    }
}

fn boundedLength(bytes: []const u8, limits: Limits) Error!u64 {
    const value: u64 = @intCast(bytes.len);
    if (value > limits.max_string_bytes) return error.ResourceLimit;
    return value;
}

fn boundedSection(bytes: []const u8, limits: Limits) Error!u64 {
    const value: u64 = @intCast(bytes.len);
    if (value > limits.max_section_bytes) return error.ResourceLimit;
    return value;
}

fn measureMessage(item: message.Message, limits: Limits) Error!u64 {
    const block_count: u64 = @intCast(item.blocks.len);
    if (block_count > limits.max_blocks_per_message) return error.ResourceLimit;
    var size: u64 = 1 + 4;
    for (item.blocks) |block| {
        size = try checkedAdd(size, 1);
        switch (block) {
            .text, .thinking => |bytes| {
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.Corrupt;
                size = try addEncodedString(size, bytes, limits);
            },
            .tool_use => |tool| {
                if (!std.unicode.utf8ValidateSlice(tool.id) or
                    !std.unicode.utf8ValidateSlice(tool.name) or
                    !std.unicode.utf8ValidateSlice(tool.input))
                    return error.Corrupt;
                size = try addEncodedString(size, tool.id, limits);
                size = try addEncodedString(size, tool.name, limits);
                size = try addEncodedString(size, tool.input, limits);
            },
            .tool_result => |result| {
                if (!std.unicode.utf8ValidateSlice(result.tool_use_id) or
                    !std.unicode.utf8ValidateSlice(result.content))
                    return error.Corrupt;
                size = try addEncodedString(size, result.tool_use_id, limits);
                size = try addEncodedString(size, result.content, limits);
                size = try checkedAdd(size, 1);
            },
            .image => |image| {
                // 载荷是 base64(UTF-8 安全),复用字符串编码通道;原始图像字节绝不入 envelope。
                if (!std.unicode.utf8ValidateSlice(image.media_type) or
                    !std.unicode.utf8ValidateSlice(image.data))
                    return error.Corrupt;
                size = try addEncodedString(size, image.media_type, limits);
                size = try addEncodedString(size, image.data, limits);
            },
            .reasoning_item => |reasoning| {
                // Provider-private continuation JSON (UTF-8 by construction:
                // it is the server's own wire text) plus the model it belongs
                // to. Restored verbatim so a resumed Run can replay it.
                if (!std.unicode.utf8ValidateSlice(reasoning.model) or
                    !std.unicode.utf8ValidateSlice(reasoning.json))
                    return error.Corrupt;
                size = try addEncodedString(size, reasoning.model, limits);
                size = try addEncodedString(size, reasoning.json, limits);
            },
        }
    }
    return size;
}

fn addEncodedString(base: u64, bytes: []const u8, limits: Limits) Error!u64 {
    const length = try boundedLength(bytes, limits);
    return checkedAdd(try checkedAdd(base, 8), length);
}

fn encodeHeader(snapshot: Snapshot, measured: Measurement) [HEADER_BYTES]u8 {
    var out = [_]u8{0} ** HEADER_BYTES;
    @memcpy(out[0..magic.len], magic);
    putInt(&out, 16, u32, STATE_SCHEMA_REVISION);
    putInt(&out, 20, u32, CHECKPOINT_COMPATIBILITY_MARKER);
    putInt(&out, 24, u32, measured.flags);
    putInt(&out, 28, u32, section_count);
    putInt(&out, 32, u64, snapshot.checkpoint_generation);
    putInt(&out, 40, u64, snapshot.last_run_id);
    putInt(&out, 48, u64, snapshot.last_compact_id);
    putInt(&out, 56, u64, snapshot.terminal_id);
    putInt(&out, 64, u64, measured.total_bytes);
    putInt(&out, 72, u64, measured.message_bytes);
    putInt(&out, 80, u64, measured.message_count);
    putInt(&out, 88, u64, measured.compact_boundary);
    putInt(&out, 96, u64, measured.model_bytes);
    putInt(&out, 104, u64, measured.summary_bytes);
    putInt(&out, 112, u64, measured.skill_bytes);
    putInt(&out, 120, u64, measured.permission_bytes);
    putInt(&out, 128, u64, measured.mcp_bytes);
    @memcpy(out[136..160], snapshot.session_id.asSlice());
    putInt(&out, 160, u32, @intFromEnum(snapshot.terminal_kind));
    putInt(&out, 168, u64, snapshot.policy_generation);
    putInt(&out, 176, u64, snapshot.catalog_generation);
    return out;
}

const ParsedHeader = struct {
    descriptor: Descriptor,
    measurement: Measurement,
    messages_end: u64,
    payload_end: u64,
};

fn parseHeader(header: *const [HEADER_BYTES]u8, limits: Limits) Error!ParsedHeader {
    if (!std.mem.eql(u8, header[0..magic.len], magic)) return error.Corrupt;
    if (getInt(header, 16, u32) != STATE_SCHEMA_REVISION)
        return error.UnsupportedSchema;
    if (getInt(header, 20, u32) != CHECKPOINT_COMPATIBILITY_MARKER)
        return error.IncompatibleAbi;
    const flags = getInt(header, 24, u32);
    if ((flags & ~flag_has_compact_summary) != 0 or
        getInt(header, 28, u32) != section_count or
        !allZero(header[164..168]) or !allZero(header[184..192]))
        return error.Corrupt;
    const total_bytes = getInt(header, 64, u64);
    const message_bytes = getInt(header, 72, u64);
    const message_count = getInt(header, 80, u64);
    const compact_boundary = getInt(header, 88, u64);
    const model_bytes = getInt(header, 96, u64);
    const summary_bytes = getInt(header, 104, u64);
    const skill_bytes = getInt(header, 112, u64);
    const permission_bytes = getInt(header, 120, u64);
    const mcp_bytes = getInt(header, 128, u64);
    const restored_message_count = try checkedAdd(
        message_count,
        @intFromBool((flags & flag_has_compact_summary) != 0),
    );
    if (total_bytes < HEADER_BYTES + DIGEST_BYTES or
        compact_boundary != 0 or model_bytes == 0 or
        ((flags & flag_has_compact_summary) == 0 and summary_bytes != 0))
        return error.Corrupt;
    if (total_bytes > limits.hard_bytes or
        total_bytes > ABSOLUTE_MAX_CHECKPOINT_BYTES or
        message_bytes > limits.max_section_bytes or
        restored_message_count > limits.max_messages or
        model_bytes > limits.max_string_bytes or
        summary_bytes > limits.max_string_bytes or
        skill_bytes > limits.max_section_bytes or
        permission_bytes > limits.max_section_bytes or
        mcp_bytes > limits.max_section_bytes)
        return error.ResourceLimit;
    var payload_bytes = try checkedAdd(model_bytes, summary_bytes);
    payload_bytes = try checkedAdd(payload_bytes, skill_bytes);
    payload_bytes = try checkedAdd(payload_bytes, permission_bytes);
    payload_bytes = try checkedAdd(payload_bytes, mcp_bytes);
    payload_bytes = try checkedAdd(payload_bytes, message_bytes);
    const expected_total = try checkedAdd(
        try checkedAdd(HEADER_BYTES, payload_bytes),
        DIGEST_BYTES,
    );
    if (expected_total != total_bytes) return error.Corrupt;
    const session_id = SessionId.fromSlice(header[136..160]) orelse
        return error.Corrupt;
    const terminal_kind: TerminalKind = switch (getInt(header, 160, u32)) {
        0 => .none,
        1 => .run,
        2 => .compact,
        3 => .budget_exhausted,
        4 => .resource_limit,
        else => return error.Corrupt,
    };
    const descriptor = Descriptor{
        .session_id = session_id,
        .checkpoint_generation = getInt(header, 32, u64),
        .total_bytes = total_bytes,
        .last_run_id = getInt(header, 40, u64),
        .last_compact_id = getInt(header, 48, u64),
        .terminal_id = getInt(header, 56, u64),
        .terminal_kind = terminal_kind,
        .policy_generation = getInt(header, 168, u64),
        .catalog_generation = getInt(header, 176, u64),
    };
    if (descriptor.checkpoint_generation == 0) return error.Corrupt;
    try validateTerminalFields(
        descriptor.terminal_kind,
        descriptor.terminal_id,
        descriptor.last_run_id,
        descriptor.last_compact_id,
    );
    const messages_end = total_bytes - DIGEST_BYTES;
    return .{
        .descriptor = descriptor,
        .measurement = .{
            .total_bytes = total_bytes,
            .message_bytes = message_bytes,
            .message_count = message_count,
            .compact_boundary = compact_boundary,
            .model_bytes = model_bytes,
            .summary_bytes = summary_bytes,
            .skill_bytes = skill_bytes,
            .permission_bytes = permission_bytes,
            .mcp_bytes = mcp_bytes,
            .flags = flags,
        },
        .messages_end = messages_end,
        .payload_end = messages_end,
    };
}

const Writer = struct {
    sink: Sink,
    limits: Limits,
    expected_total: u64,
    written: u64 = 0,
    chunk_count: u64 = 0,
    hasher: std.crypto.hash.sha2.Sha256,

    fn init(sink: Sink, limits: Limits, expected_total: u64) Writer {
        return .{
            .sink = sink,
            .limits = limits,
            .expected_total = expected_total,
            .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        };
    }

    fn writeHashed(self: *Writer, bytes: []const u8) Error!void {
        try self.write(bytes, true);
    }

    fn writeDigest(self: *Writer, digest: *const [DIGEST_BYTES]u8) Error!void {
        try self.write(digest, false);
    }

    fn write(self: *Writer, bytes: []const u8, hash: bool) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = @min(
                bytes.len - offset,
                @as(usize, @intCast(self.limits.chunk_bytes)),
            );
            const part = bytes[offset..][0..count];
            const next = try checkedAdd(self.written, part.len);
            if (next > self.expected_total or next > self.limits.hard_bytes)
                return error.ResourceLimit;
            if (hash) self.hasher.update(part);
            self.sink.write_fn(self.sink.ctx, part) catch
                return error.SinkFailed;
            self.written = next;
            self.chunk_count = try checkedAdd(self.chunk_count, 1);
            offset += count;
        }
    }
};

const Reader = struct {
    source: Source,
    limits: Limits,
    expected_total: u64 = ABSOLUTE_MAX_CHECKPOINT_BYTES,
    position: u64 = 0,
    hasher: std.crypto.hash.sha2.Sha256,
    /// Revision-16 document blocks (tag 7) stepped over so far. Their schema
    /// verdict is delivered by `decodeFromSource` only after the digest verifies.
    withdrawn_blocks: u64 = 0,

    fn init(source: Source, limits: Limits) Reader {
        return .{
            .source = source,
            .limits = limits,
            .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
        };
    }

    fn readHashed(self: *Reader, out: []u8) Error!void {
        try self.read(out, true);
    }

    fn readUnhashed(self: *Reader, out: []u8) Error!void {
        try self.read(out, false);
    }

    fn read(self: *Reader, out: []u8, hash: bool) Error!void {
        const next = try checkedAdd(self.position, out.len);
        if (next > self.expected_total or next > self.limits.hard_bytes)
            return error.ResourceLimit;
        var offset: usize = 0;
        while (offset < out.len) {
            const read_count = self.source.read_fn(
                self.source.ctx,
                out[offset..],
            ) catch return error.SourceFailed;
            if (read_count == 0 or read_count > out.len - offset)
                return error.Corrupt;
            if (hash) self.hasher.update(out[offset..][0..read_count]);
            offset += read_count;
        }
        self.position = next;
    }

    fn readOwned(
        self: *Reader,
        allocator: std.mem.Allocator,
        length: u64,
        section_end: u64,
    ) Error![]u8 {
        const next = try checkedAdd(self.position, length);
        if (next > section_end) return error.Corrupt;
        const count = std.math.cast(usize, length) orelse
            return error.ResourceLimit;
        const out = allocator.alloc(u8, count) catch return error.OutOfMemory;
        errdefer allocator.free(out);
        try self.readHashed(out);
        return out;
    }
};

fn writeMessage(writer: *Writer, item: message.Message) Error!void {
    const role: u8 = switch (item.role) {
        .user => 1,
        .assistant => 2,
    };
    try writeInt(writer, u8, role);
    try writeInt(writer, u32, @intCast(item.blocks.len));
    for (item.blocks) |block| switch (block) {
        .text => |bytes| {
            try writeInt(writer, u8, 1);
            try writeString(writer, bytes);
        },
        .tool_use => |tool| {
            try writeInt(writer, u8, 2);
            try writeString(writer, tool.id);
            try writeString(writer, tool.name);
            try writeString(writer, tool.input);
        },
        .tool_result => |result| {
            try writeInt(writer, u8, 3);
            try writeString(writer, result.tool_use_id);
            try writeString(writer, result.content);
            try writeInt(writer, u8, @intFromBool(result.is_error));
        },
        .thinking => |bytes| {
            try writeInt(writer, u8, 4);
            try writeString(writer, bytes);
        },
        .image => |image| {
            try writeInt(writer, u8, 5);
            try writeString(writer, image.media_type);
            try writeString(writer, image.data);
        },
        .reasoning_item => |reasoning| {
            try writeInt(writer, u8, 6);
            try writeString(writer, reasoning.model);
            try writeString(writer, reasoning.json);
        },
    };
}

fn readMessage(
    reader: *Reader,
    allocator: std.mem.Allocator,
    messages_end: u64,
    limits: Limits,
) Error!message.Message {
    const role_value = try readInt(reader, u8, messages_end);
    const role: message.Role = switch (role_value) {
        1 => .user,
        2 => .assistant,
        else => return error.Corrupt,
    };
    const block_count = try readInt(reader, u32, messages_end);
    if (block_count > limits.max_blocks_per_message)
        return error.ResourceLimit;
    const blocks = allocator.alloc(message.Block, block_count) catch
        return error.OutOfMemory;
    errdefer allocator.free(blocks);
    var initialized: usize = 0;
    errdefer for (blocks[0..initialized]) |block| block.deinit(allocator);
    while (initialized < blocks.len) : (initialized += 1) {
        const tag = try readInt(reader, u8, messages_end);
        blocks[initialized] = switch (tag) {
            1 => .{ .text = try readString(reader, allocator, messages_end, limits) },
            2 => tool_use: {
                const id = try readString(reader, allocator, messages_end, limits);
                errdefer allocator.free(id);
                const name = try readString(reader, allocator, messages_end, limits);
                errdefer allocator.free(name);
                const input = try readString(reader, allocator, messages_end, limits);
                break :tool_use .{ .tool_use = .{ .id = id, .name = name, .input = input } };
            },
            3 => tool_result: {
                const tool_use_id = try readString(reader, allocator, messages_end, limits);
                errdefer allocator.free(tool_use_id);
                const content = try readString(reader, allocator, messages_end, limits);
                errdefer allocator.free(content);
                const is_error = try readInt(reader, u8, messages_end);
                if (is_error > 1) return error.Corrupt;
                break :tool_result .{ .tool_result = .{
                    .tool_use_id = tool_use_id,
                    .content = content,
                    .is_error = is_error == 1,
                } };
            },
            4 => .{ .thinking = try readString(reader, allocator, messages_end, limits) },
            5 => image: {
                const media_type = try readString(reader, allocator, messages_end, limits);
                errdefer allocator.free(media_type);
                const data = try readString(reader, allocator, messages_end, limits);
                break :image .{ .image = .{ .media_type = media_type, .data = data } };
            },
            // Tag 7 was revision 16's document block, withdrawn together with
            // first-class PDF input. A checkpoint carrying it is intact, not
            // damaged, so it must not report Corrupt — that would send a Host
            // hunting for storage faults. It is a schema this build no longer
            // supports, and the tag stays permanently reserved: any build that
            // ran main between the two revisions could have written one, so
            // reusing 7 for a different block would silently misread those
            // files. (The ABI revision number itself could safely return to 15
            // because no bundle was ever published at 16; a checkpoint on disk
            // has the wider exposure of the two.)
            //
            // The verdict is not delivered here: a damaged file whose bytes
            // merely happen to read as tag 7 would then report Unsupported and
            // hide real corruption. The block is decoded exactly as revision 16
            // decoded it (three length-prefixed UTF-8 strings: media_type, data,
            // title; then a u32 page count) and discarded, so a malformed block
            // still reports Corrupt; decoding continues to the digest, and
            // `decodeFromSource` fails closed with UnsupportedSchema only once
            // integrity has been verified.
            7 => withdrawn: {
                allocator.free(try readString(reader, allocator, messages_end, limits));
                allocator.free(try readString(reader, allocator, messages_end, limits));
                allocator.free(try readString(reader, allocator, messages_end, limits));
                _ = try readInt(reader, u32, messages_end);
                reader.withdrawn_blocks += 1;
                // Placeholder keeps `blocks` fully initialized for the cleanup
                // chain; it is never observable because the decode cannot
                // succeed once a withdrawn block was seen.
                break :withdrawn .{ .text = allocator.dupe(u8, "") catch
                    return error.OutOfMemory };
            },
            6 => reasoning_item: {
                const model = try readString(reader, allocator, messages_end, limits);
                errdefer allocator.free(model);
                const payload = try readString(reader, allocator, messages_end, limits);
                break :reasoning_item .{ .reasoning_item = .{ .model = model, .json = payload } };
            },
            else => return error.Corrupt,
        };
    }
    return .{ .role = role, .blocks = blocks };
}

fn writeString(writer: *Writer, bytes: []const u8) Error!void {
    try writeInt(writer, u64, @intCast(bytes.len));
    try writer.writeHashed(bytes);
}

fn readString(
    reader: *Reader,
    allocator: std.mem.Allocator,
    messages_end: u64,
    limits: Limits,
) Error![]u8 {
    const length = try readInt(reader, u64, messages_end);
    if (length > limits.max_string_bytes) return error.ResourceLimit;
    const bytes = try reader.readOwned(allocator, length, messages_end);
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        allocator.free(bytes);
        return error.Corrupt;
    }
    return bytes;
}

fn writeInt(writer: *Writer, comptime T: type, value: T) Error!void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try writer.writeHashed(&encoded);
}

fn readInt(
    reader: *Reader,
    comptime T: type,
    section_end: u64,
) Error!T {
    const next = try checkedAdd(reader.position, @sizeOf(T));
    if (next > section_end) return error.Corrupt;
    var encoded: [@sizeOf(T)]u8 = undefined;
    try reader.readHashed(&encoded);
    return std.mem.readInt(T, &encoded, .little);
}

fn putInt(
    out: *[HEADER_BYTES]u8,
    offset: usize,
    comptime T: type,
    value: T,
) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn getInt(
    header: *const [HEADER_BYTES]u8,
    offset: usize,
    comptime T: type,
) T {
    return std.mem.readInt(T, header[offset..][0..@sizeOf(T)], .little);
}

fn checkedAdd(a: anytype, b: anytype) Error!u64 {
    return std.math.add(u64, @intCast(a), @intCast(b)) catch
        return error.ResourceLimit;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

const TestSink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    max_chunk: usize = 0,

    fn write(raw: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *TestSink = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.max_chunk = @max(self.max_chunk, bytes.len);
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    fn deinit(self: *TestSink) void {
        self.bytes.deinit(self.allocator);
    }
};

const TestSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    step: usize = std.math.maxInt(usize),

    fn read(raw: *anyopaque, out: []u8) anyerror!usize {
        const self: *TestSource = @ptrCast(@alignCast(raw));
        if (self.offset == self.bytes.len) return 0;
        const count = @min(@min(out.len, self.step), self.bytes.len - self.offset);
        @memcpy(out[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};

fn testConversation(allocator: std.mem.Allocator) !Conversation {
    var conversation = Conversation.init(allocator);
    errdefer conversation.deinit();
    const blocks = try allocator.alloc(message.Block, 4);
    var initialized: usize = 0;
    errdefer for (blocks[0..initialized]) |block| block.deinit(allocator);
    errdefer allocator.free(blocks);
    blocks[0] = .{ .text = try allocator.dupe(u8, "hello") };
    initialized = 1;
    blocks[1] = .{ .thinking = try allocator.dupe(u8, "reasoning") };
    initialized = 2;
    blocks[2] = .{ .tool_use = .{
        .id = try allocator.dupe(u8, "call-1"),
        .name = try allocator.dupe(u8, "Read"),
        .input = try allocator.dupe(u8, "{\"path\":\"a\"}"),
    } };
    initialized = 3;
    blocks[3] = .{ .tool_result = .{
        .tool_use_id = try allocator.dupe(u8, "call-1"),
        .content = try allocator.dupe(u8, "ok"),
        .is_error = false,
    } };
    initialized = 4;
    try conversation.append(.{ .role = .assistant, .blocks = blocks });
    try conversation.restoreCompactState(1, "summary");
    return conversation;
}

test "Revision 6 checkpoint streams and round-trips canonical Conversation" {
    const allocator = std.testing.allocator;
    var conversation = try testConversation(allocator);
    defer conversation.deinit();
    const id = core.session_id.gen();
    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();
    const limits = Limits{ .hard_bytes = 1024 * 1024, .chunk_bytes = 7 };
    const report = try exportToSink(.{
        .session_id = id,
        .checkpoint_generation = 4,
        .last_run_id = 9,
        .last_compact_id = 3,
        .terminal_kind = .compact,
        .terminal_id = 3,
        .model = "test-model",
        .conversation = &conversation,
        .policy_generation = 2,
        .catalog_generation = 5,
        .authority = .{
            .skill = "skill-state",
            .permission = "permission-state",
            .mcp = "mcp-state",
        },
    }, limits, .{ .ctx = &sink, .write_fn = TestSink.write });
    try std.testing.expectEqual(@as(u64, sink.bytes.items.len), report.total_bytes);
    try std.testing.expect(sink.calls > 10);
    try std.testing.expect(sink.max_chunk <= 7);

    var source = TestSource{ .bytes = sink.bytes.items, .step = 3 };
    var decoded = try decodeFromSource(
        allocator,
        .{ .ctx = &source, .read_fn = TestSource.read },
        limits,
    );
    defer decoded.deinit();
    try std.testing.expectEqualStrings(id.asSlice(), decoded.descriptor.session_id.asSlice());
    try std.testing.expectEqual(@as(u64, 4), decoded.descriptor.checkpoint_generation);
    try std.testing.expectEqual(@as(u64, 9), decoded.descriptor.last_run_id);
    try std.testing.expectEqualStrings("test-model", decoded.model);
    try std.testing.expectEqual(@as(usize, 1), decoded.conversation.messages.items.len);
    try std.testing.expectEqualStrings(
        "summary",
        decoded.conversation.messages.items[0].blocks[0].text,
    );
    try std.testing.expect(decoded.conversation.compact_summary == null);
    try std.testing.expectEqual(@as(usize, 0), decoded.conversation.compact_boundary);
    try std.testing.expectEqualStrings("permission-state", decoded.permission_state);
}

test "Revision 6 checkpoint counts compact summary in restored message limit" {
    const allocator = std.testing.allocator;
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "hidden-prefix");
    try conversation.restoreCompactState(1, "summary");
    try conversation.appendText(.user, "active");

    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();
    const limits = Limits{
        .hard_bytes = 1024 * 1024,
        .max_messages = 1,
    };
    try std.testing.expectError(error.ResourceLimit, exportToSink(.{
        .session_id = core.session_id.gen(),
        .checkpoint_generation = 1,
        .last_run_id = 0,
        .last_compact_id = 0,
        .terminal_kind = .none,
        .terminal_id = 0,
        .model = "test-model",
        .conversation = &conversation,
    }, limits, .{ .ctx = &sink, .write_fn = TestSink.write }));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
}

test "Revision 6 checkpoint long Conversation honors exact byte and chunk budgets" {
    const allocator = std.testing.allocator;
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();

    const message_count = 4096;
    var index: usize = 0;
    while (index < message_count) : (index += 1) {
        var buffer: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &buffer,
            "message-{d}-payload-for-streaming-checkpoint-conformance",
            .{index},
        );
        try conversation.appendText(
            if (index % 2 == 0) .user else .assistant,
            text,
        );
    }
    try conversation.restoreCompactState(message_count / 2, "long-summary");

    const snapshot = Snapshot{
        .session_id = core.session_id.gen(),
        .checkpoint_generation = 11,
        .last_run_id = 37,
        .last_compact_id = 4,
        .terminal_kind = .run,
        .terminal_id = 37,
        .model = "long-session-model",
        .conversation = &conversation,
    };
    const roomy_limits = Limits{
        .hard_bytes = 16 * 1024 * 1024,
        .chunk_bytes = 31,
    };
    var measured_sink = TestSink{ .allocator = allocator };
    defer measured_sink.deinit();
    const measured = try exportToSink(
        snapshot,
        roomy_limits,
        .{ .ctx = &measured_sink, .write_fn = TestSink.write },
    );
    try std.testing.expect(measured.total_bytes > 100 * 1024);
    try std.testing.expect(measured.chunk_count > 1000);
    try std.testing.expect(measured_sink.max_chunk <= roomy_limits.chunk_bytes);

    var exact_sink = TestSink{ .allocator = allocator };
    defer exact_sink.deinit();
    const exact_limits = Limits{
        .hard_bytes = measured.total_bytes,
        .chunk_bytes = roomy_limits.chunk_bytes,
    };
    const exact = try exportToSink(
        snapshot,
        exact_limits,
        .{ .ctx = &exact_sink, .write_fn = TestSink.write },
    );
    try std.testing.expectEqual(measured.total_bytes, exact.total_bytes);

    var undersized_sink = TestSink{ .allocator = allocator };
    defer undersized_sink.deinit();
    var undersized_limits = exact_limits;
    undersized_limits.hard_bytes -= 1;
    try std.testing.expectError(error.ResourceLimit, exportToSink(
        snapshot,
        undersized_limits,
        .{ .ctx = &undersized_sink, .write_fn = TestSink.write },
    ));
    try std.testing.expectEqual(@as(usize, 0), undersized_sink.calls);

    var source = TestSource{ .bytes = exact_sink.bytes.items, .step = 13 };
    var decoded = try decodeFromSource(
        allocator,
        .{ .ctx = &source, .read_fn = TestSource.read },
        exact_limits,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, message_count / 2 + 1), decoded.conversation.len());
    try std.testing.expectEqual(@as(usize, 0), decoded.conversation.compact_boundary);
    try std.testing.expect(decoded.conversation.compact_summary == null);
    try std.testing.expectEqualStrings(
        "long-summary",
        decoded.conversation.messages.items[0].blocks[0].text,
    );
    try std.testing.expectEqualStrings(
        "message-4095-payload-for-streaming-checkpoint-conformance",
        decoded.conversation.messages.items[decoded.conversation.len() - 1].blocks[0].text,
    );

    var oversized_source = TestSource{ .bytes = exact_sink.bytes.items, .step = 17 };
    try std.testing.expectError(error.ResourceLimit, decodeFromSource(
        allocator,
        .{ .ctx = &oversized_source, .read_fn = TestSource.read },
        undersized_limits,
    ));
}

test "Revision 6 checkpoint snapshot surface excludes runtime capabilities" {
    const expected_fields = [_][]const u8{
        "session_id",
        "checkpoint_generation",
        "last_run_id",
        "last_compact_id",
        "terminal_kind",
        "terminal_id",
        "model",
        "conversation",
        "policy_generation",
        "catalog_generation",
        "authority",
    };
    const fields = @typeInfo(Snapshot).@"struct".fields;
    try std.testing.expectEqual(expected_fields.len, fields.len);
    inline for (fields, 0..) |field, field_index| {
        try std.testing.expectEqualStrings(expected_fields[field_index], field.name);
    }
}

test "Revision 6 checkpoint rejects budget before first sink write" {
    const allocator = std.testing.allocator;
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "payload");
    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();
    try std.testing.expectError(error.ResourceLimit, exportToSink(.{
        .session_id = core.session_id.gen(),
        .checkpoint_generation = 1,
        .last_run_id = 1,
        .last_compact_id = 0,
        .terminal_kind = .run,
        .terminal_id = 1,
        .model = "model",
        .conversation = &conversation,
    }, .{ .hard_bytes = MIN_CHECKPOINT_BUDGET }, .{
        .ctx = &sink,
        .write_fn = TestSink.write,
    }));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
}

test "Revision 6 checkpoint distinguishes unsupported schema and corruption" {
    const allocator = std.testing.allocator;
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();
    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();
    const limits = Limits{ .hard_bytes = 1024 * 1024 };
    _ = try exportToSink(.{
        .session_id = core.session_id.gen(),
        .checkpoint_generation = 1,
        .last_run_id = 0,
        .last_compact_id = 0,
        .terminal_kind = .none,
        .terminal_id = 0,
        .model = "model",
        .conversation = &conversation,
    }, limits, .{ .ctx = &sink, .write_fn = TestSink.write });

    const unsupported = try allocator.dupe(u8, sink.bytes.items);
    defer allocator.free(unsupported);
    std.mem.writeInt(u32, unsupported[16..20], 99, .little);
    var unsupported_source = TestSource{ .bytes = unsupported };
    try std.testing.expectError(error.UnsupportedSchema, decodeFromSource(
        allocator,
        .{ .ctx = &unsupported_source, .read_fn = TestSource.read },
        limits,
    ));

    const corrupt = try allocator.dupe(u8, sink.bytes.items);
    defer allocator.free(corrupt);
    corrupt[HEADER_BYTES] ^= 0xff;
    var corrupt_source = TestSource{ .bytes = corrupt };
    try std.testing.expectError(error.Corrupt, decodeFromSource(
        allocator,
        .{ .ctx = &corrupt_source, .read_fn = TestSource.read },
        limits,
    ));
}

test "checkpoint round-trips image blocks (tag 5, issue #10)" {
    // 图像语义(MIME + base64 载荷 + 块顺序)在 export/restore 后原样保留。
    const allocator = std.testing.allocator;
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();
    const blocks = try allocator.alloc(message.Block, 3);
    blocks[0] = .{ .text = try allocator.dupe(u8, "看这张截图") };
    blocks[1] = .{ .image = .{
        .media_type = try allocator.dupe(u8, "image/png"),
        .data = try allocator.dupe(u8, "UE5HREFUQQ=="),
    } };
    blocks[2] = .{ .image = .{
        .media_type = try allocator.dupe(u8, "image/jpeg"),
        .data = try allocator.dupe(u8, "SlBFRw=="),
    } };
    try conversation.append(.{ .role = .user, .blocks = blocks });

    const id = core.session_id.gen();
    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();
    const limits = Limits{ .hard_bytes = 1024 * 1024 };
    _ = try exportToSink(.{
        .session_id = id,
        .checkpoint_generation = 1,
        .last_run_id = 1,
        .last_compact_id = 0,
        .terminal_kind = .run,
        .terminal_id = 1,
        .model = "claude-sonnet-4",
        .conversation = &conversation,
        .policy_generation = 1,
        .catalog_generation = 1,
        .authority = .{ .skill = "", .permission = "", .mcp = "" },
    }, limits, .{ .ctx = &sink, .write_fn = TestSink.write });

    var source = TestSource{ .bytes = sink.bytes.items, .step = 5 };
    var decoded = try decodeFromSource(
        allocator,
        .{ .ctx = &source, .read_fn = TestSource.read },
        limits,
    );
    defer decoded.deinit();
    const restored = decoded.conversation.messages.items[0].blocks;
    try std.testing.expectEqual(@as(usize, 3), restored.len);
    try std.testing.expectEqualStrings("看这张截图", restored[0].text);
    try std.testing.expectEqualStrings("image/png", restored[1].image.media_type);
    try std.testing.expectEqualStrings("UE5HREFUQQ==", restored[1].image.data);
    try std.testing.expectEqualStrings("image/jpeg", restored[2].image.media_type);
    try std.testing.expectEqualStrings("SlBFRw==", restored[2].image.data);
}

test "checkpoint round-trips reasoning_item blocks (tag 6, issue #23)" {
    // A restored Run must still be able to replay the provider's encrypted
    // reasoning state, so both the owning model and the verbatim item survive.
    const allocator = std.testing.allocator;
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();
    const item_json =
        "{\"type\":\"reasoning\",\"id\":\"rs_ckpt_1\",\"summary\":[],\"encrypted_content\":\"opaque\"}";
    const blocks = try allocator.alloc(message.Block, 2);
    blocks[0] = .{ .reasoning_item = .{
        .model = try allocator.dupe(u8, "gpt-5.2"),
        .json = try allocator.dupe(u8, item_json),
    } };
    blocks[1] = .{ .tool_use = .{
        .id = try allocator.dupe(u8, "call_ckpt_1"),
        .name = try allocator.dupe(u8, "get_time"),
        .input = try allocator.dupe(u8, "{}"),
    } };
    try conversation.append(.{ .role = .assistant, .blocks = blocks });

    const id = core.session_id.gen();
    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();
    const limits = Limits{ .hard_bytes = 1024 * 1024 };
    _ = try exportToSink(.{
        .session_id = id,
        .checkpoint_generation = 1,
        .last_run_id = 1,
        .last_compact_id = 0,
        .terminal_kind = .run,
        .terminal_id = 1,
        .model = "gpt-5.2",
        .conversation = &conversation,
        .policy_generation = 1,
        .catalog_generation = 1,
        .authority = .{ .skill = "", .permission = "", .mcp = "" },
    }, limits, .{ .ctx = &sink, .write_fn = TestSink.write });

    var source = TestSource{ .bytes = sink.bytes.items, .step = 5 };
    var decoded = try decodeFromSource(
        allocator,
        .{ .ctx = &source, .read_fn = TestSource.read },
        limits,
    );
    defer decoded.deinit();
    const restored = decoded.conversation.messages.items[0].blocks;
    try std.testing.expectEqual(@as(usize, 2), restored.len);
    try std.testing.expectEqualStrings("gpt-5.2", restored[0].reasoning_item.model);
    try std.testing.expectEqualStrings(item_json, restored[0].reasoning_item.json);
    try std.testing.expectEqualStrings("call_ckpt_1", restored[1].tool_use.id);
}

test "encodedUserPartsMessageBytes 与真实编码字节精确一致(多模态预留=提交)" {
    const allocator = std.testing.allocator;
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();
    const parts = [_]message.UserContentPart{
        .{ .text = "看这张截图" },
        .{ .image = .{ .media_type = "image/png", .data = "UE5HREFUQQ==" } },
        .{ .text = "以及后记" },
    };
    try conversation.appendUserParts(&parts);
    const limits = Limits{ .hard_bytes = 1024 * 1024 };
    const usage = try measureSnapshot(.{
        .session_id = core.session_id.gen(),
        .checkpoint_generation = 1,
        .last_run_id = 1,
        .last_compact_id = 0,
        .terminal_kind = .run,
        .terminal_id = 1,
        .model = "claude-sonnet-4",
        .conversation = &conversation,
        .policy_generation = 1,
        .catalog_generation = 1,
        .authority = .{ .skill = "", .permission = "", .mcp = "" },
    }, limits);
    try std.testing.expectEqual(
        try encodedUserPartsMessageBytes(&parts),
        usage.message_bytes,
    );
    // 单 text part 与既有 text 根记录公式一致(5+1+8+len == 14+len)。
    const text_only = [_]message.UserContentPart{.{ .text = "hello" }};
    try std.testing.expectEqual(
        try encodedTextMessageBytes("hello"),
        try encodedUserPartsMessageBytes(&text_only),
    );
    try std.testing.expectError(error.Corrupt, encodedUserPartsMessageBytes(&.{}));
}

test "tag 字节损坏成 7 但 digest 不符 → Corrupt(完整性判定先于 schema 判定)" {
    // 同一份改动在 review 之前会得到 UnsupportedSchema:tag 7 一出现就返回,
    // 从未走到 digest 校验,于是"文件坏了"被伪装成"schema 不支持"。
    const allocator = std.testing.allocator;
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();
    const blocks = try allocator.alloc(message.Block, 1);
    blocks[0] = .{ .text = try allocator.dupe(u8, "placeholder") };
    try conversation.append(.{ .role = .user, .blocks = blocks });

    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();
    const limits = Limits{ .hard_bytes = 1024 * 1024 };
    _ = try exportToSink(.{
        .session_id = core.session_id.gen(),
        .checkpoint_generation = 1,
        .last_run_id = 1,
        .last_compact_id = 0,
        .terminal_kind = .run,
        .terminal_id = 1,
        .model = "claude-sonnet-4",
        .conversation = &conversation,
        .policy_generation = 1,
        .catalog_generation = 1,
        .authority = .{ .skill = "", .permission = "", .mcp = "" },
    }, limits, .{ .ctx = &sink, .write_fn = TestSink.write });

    var patched = try allocator.dupe(u8, sink.bytes.items);
    defer allocator.free(patched);
    const needle = "placeholder";
    const at = std.mem.indexOf(u8, patched, needle) orelse return error.SkipZigTest;
    patched[at - 9] = 7; // tag byte 在 8 字节长度前缀之前;digest 未重算

    var source = TestSource{ .bytes = patched, .step = 7 };
    try std.testing.expectError(error.Corrupt, decodeFromSource(
        allocator,
        .{ .ctx = &source, .read_fn = TestSource.read },
        limits,
    ));
}

/// 测试用:导出一份两条消息的 checkpoint,把第一条的 48 字节 text block 原地改写成
/// rev-16 的 tag-7 document 块(media_type "application/pdf" / data "JVBERi0=" /
/// 5 字节 title / pages=2;编码等长 57 字节,头部尺寸照旧成立),再重算尾部 digest。
/// 返回 owned 字节;调用方可继续改动后再决定是否重算 digest。
fn revision16TagSevenFixture(allocator: std.mem.Allocator, title: *const [5]u8) ![]u8 {
    var conversation = Conversation.init(allocator);
    defer conversation.deinit();
    const needle = "p" ** 48;
    try conversation.appendText(.user, needle);
    // 第二条消息紧跟在被撤回块之后:块若少读/多读一个字节,这里会先报 Corrupt。
    try conversation.appendText(.assistant, "after the withdrawn block");

    var sink = TestSink{ .allocator = allocator };
    defer sink.deinit();
    const limits = Limits{ .hard_bytes = 1024 * 1024 };
    _ = try exportToSink(.{
        .session_id = core.session_id.gen(),
        .checkpoint_generation = 1,
        .last_run_id = 1,
        .last_compact_id = 0,
        .terminal_kind = .run,
        .terminal_id = 1,
        .model = "claude-sonnet-4",
        .conversation = &conversation,
        .policy_generation = 1,
        .catalog_generation = 1,
        .authority = .{ .skill = "", .permission = "", .mcp = "" },
    }, limits, .{ .ctx = &sink, .write_fn = TestSink.write });

    const patched = try allocator.dupe(u8, sink.bytes.items);
    errdefer allocator.free(patched);
    const at = std.mem.indexOf(u8, patched, needle) orelse return error.FixtureNeedleMissing;
    var w = at - 9; // tag byte 在 8 字节长度前缀之前
    patched[w] = 7;
    w += 1;
    const fields = [_][]const u8{ "application/pdf", "JVBERi0=", title };
    for (fields) |field| {
        std.mem.writeInt(u64, patched[w..][0..8], @intCast(field.len), .little);
        w += 8;
        @memcpy(patched[w..][0..field.len], field);
        w += field.len;
    }
    std.mem.writeInt(u32, patched[w..][0..4], 2, .little);
    w += 4;
    std.debug.assert(w == at + needle.len); // 等长替换,后续消息未移位
    rehashFixture(patched);
    return patched;
}

/// digest 覆盖尾部 32 字节之前的全部内容(header 起全部 hashed):重算即可让文件在
/// 完整性上无可挑剔。
fn rehashFixture(bytes: []u8) void {
    const body = bytes[0 .. bytes.len - DIGEST_BYTES];
    std.crypto.hash.sha2.Sha256.hash(body, bytes[bytes.len - DIGEST_BYTES ..][0..DIGEST_BYTES], .{});
}

fn decodeFixture(allocator: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    var source = TestSource{ .bytes = bytes, .step = 7 };
    return decodeFromSource(
        allocator,
        .{ .ctx = &source, .read_fn = TestSource.read },
        .{ .hard_bytes = 1024 * 1024 },
    );
}

test "完整的 revision-16 checkpoint(tag 7,digest 正确)→ UnsupportedSchema,跳过后流仍对齐" {
    const allocator = std.testing.allocator;
    const fixture = try revision16TagSevenFixture(allocator, "r.pdf");
    defer allocator.free(fixture);
    try std.testing.expectError(error.UnsupportedSchema, decodeFixture(allocator, fixture));
}

test "结构合法的 tag-7 块之后一个字节损坏且未重算 digest → Corrupt(判定确实晚于 digest 校验)" {
    const allocator = std.testing.allocator;
    const fixture = try revision16TagSevenFixture(allocator, "r.pdf");
    defer allocator.free(fixture);
    // 翻转第二条消息正文的首字节('a'→'b'):仍是合法 UTF-8、结构照旧解析得过,
    // 只有 digest 不再匹配。若判定在 digest 之前就下,这里会错报 UnsupportedSchema。
    const later = std.mem.indexOf(u8, fixture, "after the withdrawn block") orelse return error.SkipZigTest;
    fixture[later] = 'b';
    try std.testing.expectError(error.Corrupt, decodeFixture(allocator, fixture));
}

test "tag-7 块内的非法 UTF-8 → Corrupt(与 rev-16 解码器一致,不冒充完整的不支持文件)" {
    const allocator = std.testing.allocator;
    // title 第二字节 0xff:rev-16 的 readString 会拒绝它,跳过路径也必须拒绝。
    const fixture = try revision16TagSevenFixture(allocator, "r\xff.pd");
    defer allocator.free(fixture);
    try std.testing.expectError(error.Corrupt, decodeFixture(allocator, fixture));
}
