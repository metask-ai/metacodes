//! A resumed session's conversation, written back into the scrollback the way
//! its turns were committed live (Claude Code shows a resumed session's
//! history; `/resume <id>` and `metacodes --resume <id>` call this).
//!
//! `plan` decides what each stored message becomes, and is pure so the rules
//! are unit-tested. `replay` carries the plan out through the live paths:
//! prompts through `user_echo`, each assistant message as one stream and its
//! tool calls and results as the CoreEvents agent_loop emits, into a
//! `TuiBackend`; the rest of a reply cut at the output limit carries on the
//! stream before it, as live. Nothing here renders a turn a second way.
//!
//! What the live view never showed is not replayed either: messages the
//! runtime wrote itself (`Message.Origin.host`: notices, nudges, continuation
//! requests, a Skill's rendered body), and text blocks riding along with tool
//! results (hook context, reminders). A macro prompt shows as its command
//! (`/init`), a recorded `!cmd` as its echo and output.

const std = @import("std");
const msg = @import("metacodes-internal").core.message;
const Conversation = @import("metacodes-internal").core.conversation.Conversation;
const host_injection_meter = @import("metacodes-internal").core.host_injection_meter;
const agent_loop = @import("metacodes-internal").core.agent_loop;
const SessionId = @import("metacodes-internal").core.session_id.SessionId;
const session_service = @import("../session_service.zig");
const user_echo = @import("user_echo.zig");
const cmd_output = @import("cmd_output.zig");
const RenderRegion = @import("tui/render_region.zig").RenderRegion;
const TuiBackend = @import("tui/tui_backend.zig").TuiBackend;
const Theme = @import("tui/theme.zig").Theme;

/// At most this many stored messages are replayed (Claude Code renders at
/// most 200 without virtualization); Ctrl+X Ctrl+O shows the whole conversation.
pub const MAX_REPLAYED_MESSAGES: usize = 200;

pub const ToolCall = struct { id: []const u8, name: []const u8, input: []const u8 };

pub const ToolOutcome = struct {
    id: []const u8,
    /// Empty when the call is not in the conversation.
    name: []const u8,
    input: []const u8,
    content: []const u8,
    is_error: bool,
};

/// One thing the replay writes. Slices borrow from the conversation.
pub const Step = union(enum) {
    /// This many earlier messages are not replayed.
    elided: usize,
    /// A prompt the user typed: its text and images, echoed as `❯ …`.
    prompt: []const msg.Block,
    /// A macro prompt, shown as the command that produced it.
    command: []const u8,
    /// A recorded `!cmd` run.
    shell: session_service.ShellRecord,
    /// An assistant message's thinking and text, as one stream.
    stream: []const msg.Block,
    tool_start: ToolCall,
    tool_result: ToolOutcome,
    /// A round's results are in (the live turn clears its current tool).
    end_round,
    continuation,
};

/// What replaying `messages` writes, in order (owned slice; the steps borrow
/// from `messages`).
pub fn plan(allocator: std.mem.Allocator, messages: []const msg.Message) error{OutOfMemory}![]Step {
    var calls = std.StringHashMap(msg.ToolUse).init(allocator);
    defer calls.deinit();
    for (messages) |m| for (m.blocks) |b| if (b == .tool_use) try calls.put(b.tool_use.id, b.tool_use);

    var steps: std.ArrayList(Step) = .empty;
    errdefer steps.deinit(allocator);
    const start = windowStart(messages);
    if (start > 0) try steps.append(allocator, .{ .elided = start });
    for (messages[start..], start..) |m, i| {
        if (isContinuationRequest(m)) {
            const after_stream = steps.items.len > 0 and steps.items[steps.items.len - 1] == .stream;
            if (after_stream and continuesWithText(messages[i + 1 ..])) try steps.append(allocator, .continuation);
            continue;
        }
        if (m.origin == .host) continue;
        switch (m.role) {
            .assistant => {
                if (hasBlock(m, .text) or hasBlock(m, .thinking)) try steps.append(allocator, .{ .stream = m.blocks });
                for (m.blocks) |b| if (b == .tool_use) try steps.append(allocator, .{ .tool_start = .{
                    .id = b.tool_use.id,
                    .name = b.tool_use.name,
                    .input = b.tool_use.input,
                } });
            },
            .user => {
                if (hasBlock(m, .tool_result)) {
                    for (m.blocks) |b| if (b == .tool_result) {
                        const call = calls.get(b.tool_result.tool_use_id);
                        try steps.append(allocator, .{ .tool_result = .{
                            .id = b.tool_result.tool_use_id,
                            .name = if (call) |c| c.name else "",
                            .input = if (call) |c| c.input else "{}",
                            .content = b.tool_result.content,
                            .is_error = b.tool_result.is_error,
                        } });
                    };
                    try steps.append(allocator, .end_round);
                    continue;
                }
                if (m.blocks.len == 1 and m.blocks[0] == .text) {
                    const text = m.blocks[0].text;
                    // Gate texts recorded before Message.origin existed.
                    if (host_injection_meter.isHostInjectedText(text)) continue;
                    if (session_service.macroCommand(text)) |command| {
                        try steps.append(allocator, .{ .command = command });
                        continue;
                    }
                    if (session_service.parseShellRecord(text)) |record| {
                        try steps.append(allocator, .{ .shell = record });
                        continue;
                    }
                }
                if (hasBlock(m, .text) or hasBlock(m, .image)) try steps.append(allocator, .{ .prompt = m.blocks });
            },
        }
    }
    return steps.toOwnedSlice(allocator);
}

/// The first message replayed: everything when it fits, else the first
/// typed prompt among the last `MAX_REPLAYED_MESSAGES`, so the replay opens
/// at a turn; failing that, the first assistant message among them, so no
/// result appears without its call.
fn isContinuationRequest(m: msg.Message) bool {
    return m.blocks.len == 1 and m.blocks[0] == .text and std.mem.eql(u8, m.blocks[0].text, agent_loop.CONTINUE_AFTER_TRUNCATION);
}

fn continuesWithText(rest: []const msg.Message) bool {
    for (rest) |m| {
        if (m.origin == .host) continue;
        return m.role == .assistant and (hasBlock(m, .text) or hasBlock(m, .thinking));
    }
    return false;
}

fn windowStart(messages: []const msg.Message) usize {
    if (messages.len <= MAX_REPLAYED_MESSAGES) return 0;
    const earliest = messages.len - MAX_REPLAYED_MESSAGES;
    for (messages[earliest..], earliest..) |m, i| if (isPrompt(m)) return i;
    for (messages[earliest..], earliest..) |m, i| if (m.role == .assistant) return i;
    return messages.len;
}

fn isPrompt(m: msg.Message) bool {
    return m.role == .user and m.origin == .participant and !hasBlock(m, .tool_result) and
        (hasBlock(m, .text) or hasBlock(m, .image));
}

fn hasBlock(m: msg.Message, tag: std.meta.Tag(msg.Block)) bool {
    for (m.blocks) |b| if (b == tag) return true;
    return false;
}

/// Where and how the replay writes.
pub const Target = struct {
    region: *RenderRegion,
    theme: *const Theme,
    /// A verbose session's `[Tool: name]` lines, as its live turns printed them.
    verbose: bool,
};

/// Write `conversation` into the scrollback as its turns were committed live
/// (see the module comment). Call it with nothing drawn on the region (before
/// the first prompt, or after a command's input box was cleared).
pub fn replay(allocator: std.mem.Allocator, target: Target, conversation: *Conversation) error{OutOfMemory}!void {
    conversation.lockSnapshot();
    defer conversation.unlockSnapshot();
    const steps = try plan(allocator, conversation.messages.items);
    defer allocator.free(steps);

    var tb: TuiBackend = .{
        .region = target.region,
        .theme = target.theme,
        .alloc = allocator,
        .colorize = true,
        .verbose = target.verbose,
    };
    const ui = tb.backend();
    const session = SessionId.single;
    // A call whose result is not stored (the session ended mid-tool) must not
    // leave its live card behind for the next frame.
    var open_calls: std.ArrayList([]const u8) = .empty;
    defer open_calls.deinit(allocator);

    for (steps) |step| switch (step) {
        .elided => |count| {
            const line = try std.fmt.allocPrint(allocator, "{s}… {d} earlier messages · ctrl+x ctrl+o shows the whole conversation{s}\n", .{ target.theme.dim, count, target.theme.reset });
            defer allocator.free(line);
            target.region.writeGenText(line);
        },
        .prompt => |blocks| {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(allocator);
            for (blocks) |b| switch (b) {
                .text => |t| {
                    if (text.items.len > 0) try text.append(allocator, '\n');
                    try text.appendSlice(allocator, t);
                },
                .image => {
                    if (text.items.len > 0) try text.append(allocator, ' ');
                    try text.appendSlice(allocator, "[image]");
                },
                else => {},
            };
            try echo(allocator, target, text.items);
        },
        .command => |command| try echo(allocator, target, command),
        .shell => |record| {
            const line = try std.fmt.allocPrint(allocator, "!{s}", .{record.command});
            defer allocator.free(line);
            try echo(allocator, target, line);
            const output = try cmd_output.shellOutputText(allocator, target.theme.dim, target.theme.reset, record.result);
            defer allocator.free(output);
            var shaper = cmd_output.Shaper.init(allocator, target.region.cols, target.theme.dim, target.theme.reset, target.theme.gutter);
            defer shaper.deinit();
            var shaped: std.ArrayList(u8) = .empty;
            defer shaped.deinit(allocator);
            try shaper.feed(&shaped, output);
            try shaper.finish(&shaped);
            target.region.writeGenText(shaped.items);
        },
        .stream => |blocks| {
            ui.emitEvent(session, .stream_begin);
            for (blocks) |b| switch (b) {
                .thinking => target.region.writeThinkingSummary(),
                .text => |t| ui.emitEvent(session, .{ .text_chunk = t }),
                else => {},
            };
            ui.emitEvent(session, .stream_done);
        },
        .tool_start => |call| {
            try open_calls.append(allocator, call.id);
            ui.emitEvent(session, .{ .tool_start = .{ .id = call.id, .name = call.name, .input = call.input } });
        },
        .tool_result => |r| {
            for (open_calls.items, 0..) |id, i| if (std.mem.eql(u8, id, r.id)) {
                _ = open_calls.swapRemove(i);
                break;
            };
            ui.emitEvent(session, .{ .tool_result = .{ .id = r.id, .name = r.name, .input = r.input, .content = r.content, .is_error = r.is_error } });
        },
        .end_round => ui.emitEvent(session, .clear_current_tool),
        .continuation => ui.emitEvent(session, .{ .output_segment_end = .{ .index = 0, .turn = 0, .group = 0, .disposition = .continued, .bytes = 0 } }),
    };
    for (open_calls.items) |id| target.region.clearToolCard(id);
    ui.emitEvent(session, .clear_current_tool);
    target.region.endScrollLine();
}

/// `❯ text`, laid out as a live submission's echo.
fn echo(allocator: std.mem.Allocator, target: Target, text: []const u8) error{OutOfMemory}!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try user_echo.render(&out, allocator, target.theme.accent, target.theme.reset, target.region.cols, text);
    target.region.writeGenText(out.items);
}

// ============================================================================
// Tests (the plan; the screen it produces is covered by tests/tty/cases/test_resume.py)
// ============================================================================

const testing = std.testing;

test "plan: typed prompts, assistant streams and tool rounds in live order; host messages and their kin stay hidden" {
    var prompt = [_]msg.Block{.{ .text = "fix the bug" }};
    var answer = [_]msg.Block{
        .{ .thinking = "look first" },
        .{ .text = "Reading it." },
        .{ .tool_use = .{ .id = "t1", .name = "Read", .input = "{\"file_path\":\"a.zig\"}" } },
        .{ .tool_use = .{ .id = "t2", .name = "Edit", .input = "{}" } },
    };
    var results = [_]msg.Block{
        .{ .tool_result = .{ .tool_use_id = "t1", .content = "1 line" } },
        .{ .tool_result = .{ .tool_use_id = "t2", .content = "boom", .is_error = true } },
        // Rides along with the results: hook context, never echoed.
        .{ .text = "[PostToolUse hook]\nnote" },
    };
    var nudge = [_]msg.Block{.{ .text = "Your previous response was cut off by the token limit." }};
    var skill_body = [_]msg.Block{.{ .text = "# Skill: notes\n\nbody" }};
    var legacy_gate = [_]msg.Block{.{ .text = "[progress update]\nsay where you are" }};
    var done = [_]msg.Block{.{ .text = "Fixed." }};
    const messages = [_]msg.Message{
        .{ .role = .user, .blocks = &prompt },
        .{ .role = .assistant, .blocks = &answer },
        .{ .role = .user, .blocks = &results },
        .{ .role = .user, .blocks = &nudge, .origin = .host },
        .{ .role = .user, .blocks = &skill_body, .origin = .host },
        .{ .role = .user, .blocks = &legacy_gate },
        .{ .role = .assistant, .blocks = &done },
    };
    const steps = try plan(testing.allocator, &messages);
    defer testing.allocator.free(steps);

    const Tag = std.meta.Tag(Step);
    const expected = [_]Tag{ .prompt, .stream, .tool_start, .tool_start, .tool_result, .tool_result, .end_round, .stream };
    try testing.expectEqual(expected.len, steps.len);
    for (expected, steps) |tag, step| try testing.expectEqual(tag, std.meta.activeTag(step));
    try testing.expectEqualStrings("fix the bug", steps[0].prompt[0].text);
    try testing.expectEqual(@as(usize, 4), steps[1].stream.len); // thinking and text stream; tool_use blocks are skipped there
    try testing.expectEqualStrings("Read", steps[4].tool_result.name);
    try testing.expectEqualStrings("{\"file_path\":\"a.zig\"}", steps[4].tool_result.input);
    try testing.expect(steps[5].tool_result.is_error);
    try testing.expectEqualStrings("Fixed.", steps[7].stream[0].text);
}

test "plan: a macro prompt shows as its command, a recorded !cmd as a shell step, a result without its call keeps no name" {
    var init_prompt = [_]msg.Block{.{ .text = session_service.INIT_PROMPT }};
    var shell = [_]msg.Block{.{ .text = session_service.SHELL_RECORD_PREFIX ++ "ls -a\n{\"stdout\":\"x\\n\"}" }};
    var orphan = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = "gone", .content = "c" } }};
    var with_image = [_]msg.Block{ .{ .text = "what is this" }, .{ .image = .{ .media_type = "image/png", .data = "AA==" } } };
    const messages = [_]msg.Message{
        .{ .role = .user, .blocks = &init_prompt },
        .{ .role = .user, .blocks = &shell },
        .{ .role = .user, .blocks = &orphan },
        .{ .role = .user, .blocks = &with_image },
    };
    const steps = try plan(testing.allocator, &messages);
    defer testing.allocator.free(steps);
    try testing.expectEqual(@as(usize, 5), steps.len);
    try testing.expectEqualStrings("/init", steps[0].command);
    try testing.expectEqualStrings("ls -a", steps[1].shell.command);
    try testing.expectEqualStrings("{\"stdout\":\"x\\n\"}", steps[1].shell.result);
    try testing.expectEqualStrings("", steps[2].tool_result.name);
    try testing.expectEqualStrings("{}", steps[2].tool_result.input);
    try testing.expect(steps[3] == .end_round);
    try testing.expectEqual(@as(usize, 2), steps[4].prompt.len);
}

test "plan: a long conversation replays its last turns from a typed prompt and says how many it left out" {
    const total = MAX_REPLAYED_MESSAGES + 7;
    var prompt = [_]msg.Block{.{ .text = "next" }};
    var call = [_]msg.Block{.{ .tool_use = .{ .id = "t", .name = "Bash", .input = "{}" } }};
    var result = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = "t", .content = "ok" } }};
    var messages: [total]msg.Message = undefined;
    // prompt, call, result, prompt, call, result, ...
    for (&messages, 0..) |*m, i| m.* = switch (i % 3) {
        0 => .{ .role = .user, .blocks = &prompt },
        1 => .{ .role = .assistant, .blocks = &call },
        else => .{ .role = .user, .blocks = &result },
    };
    const steps = try plan(testing.allocator, &messages);
    defer testing.allocator.free(steps);
    // The window's first message (index 7) is a call; the first prompt after it is index 9.
    try testing.expectEqual(@as(usize, 9), steps[0].elided);
    try testing.expect(steps[1] == .prompt);

    // No typed prompt in the window: it opens at an assistant message, never at a bare result.
    var only_tools: [total]msg.Message = undefined;
    only_tools[0] = .{ .role = .user, .blocks = &prompt };
    for (only_tools[1..], 1..) |*m, i| m.* = if (i % 2 == 1)
        .{ .role = .assistant, .blocks = &call }
    else
        .{ .role = .user, .blocks = &result };
    const tool_steps = try plan(testing.allocator, &only_tools);
    defer testing.allocator.free(tool_steps);
    try testing.expectEqual(@as(usize, 7), tool_steps[0].elided);
    try testing.expect(tool_steps[1] == .tool_start);

    // Short conversations replay whole, with no elision line.
    const short = try plan(testing.allocator, messages[0..3]);
    defer testing.allocator.free(short);
    try testing.expect(short[0] == .prompt);
}

test "plan: the rest of a reply cut at the output limit carries on its stream; any other host message between two replies does not" {
    var conv = Conversation.init(testing.allocator);
    defer conv.deinit();
    try conv.appendText(.user, "typed");
    try conv.appendText(.assistant, "The word is PELICAN");
    try conv.appendHostText(agent_loop.CONTINUE_AFTER_TRUNCATION);
    try conv.appendText(.assistant, " and that is all.");
    try conv.appendHostText("[job notification] the background job finished");
    try conv.appendText(.assistant, "noted");
    const steps = try plan(testing.allocator, conv.messages.items);
    defer testing.allocator.free(steps);
    try testing.expectEqual(@as(usize, 5), steps.len);
    try testing.expect(steps[0] == .prompt);
    try testing.expect(steps[1] == .stream);
    try testing.expect(steps[2] == .continuation);
    try testing.expectEqualStrings(" and that is all.", steps[3].stream[0].text);
    try testing.expectEqualStrings("noted", steps[4].stream[0].text);

    var first = [_]msg.Block{.{ .text = "first half" }};
    var request = [_]msg.Block{.{ .text = agent_loop.CONTINUE_AFTER_TRUNCATION }};
    var call = [_]msg.Block{.{ .tool_use = .{ .id = "t", .name = "Bash", .input = "{}" } }};
    const tool_only = [_]msg.Message{
        .{ .role = .assistant, .blocks = &first },
        .{ .role = .user, .blocks = &request, .origin = .host },
        .{ .role = .assistant, .blocks = &call },
    };
    const tool_steps = try plan(testing.allocator, &tool_only);
    defer testing.allocator.free(tool_steps);
    for (tool_steps) |step| try testing.expect(step != .continuation);
}

test "plan: a resumed transcript's host messages stay hidden end to end" {
    // The flag survives the transcript round trip (transcript.zig's origin
    // test); here the plan drops a host message and keeps the reply.
    var conv = Conversation.init(testing.allocator);
    defer conv.deinit();
    try conv.appendText(.user, "typed");
    try conv.appendHostText("[job notification] the background job finished");
    try conv.appendText(.assistant, "noted");
    const steps = try plan(testing.allocator, conv.messages.items);
    defer testing.allocator.free(steps);
    try testing.expectEqual(@as(usize, 2), steps.len);
    try testing.expectEqualStrings("typed", steps[0].prompt[0].text);
    try testing.expectEqualStrings("noted", steps[1].stream[0].text);
}
