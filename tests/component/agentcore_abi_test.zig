const std = @import("std");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;
const harness = @import("harness");
const abi = @import("agentcore-abi");
const sdk = @import("agentcore-sdk");
const core = @import("metacodes-core");
const sync = @import("platform").sync;
const wire = sdk.types;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_3\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const API_ERROR_SSE =
    "data: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"model not found\"}}\n\n";

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Continue?\\\",\\\"header\\\":\\\"Choice\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\",\\\"description\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"No\\\",\\\"description\\\":\\\"Stop\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_host\",\"name\":\"HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_READ_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_host_read\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_host_read\",\"name\":\"Read\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"decoy.txt\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_STREAM_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_stream\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_stream\",\"name\":\"HostStream\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"review\\\",\\\"values\\\":[\\\"src/main.zig\\\"]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const CHILD_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_child_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_child_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"child\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HIDDEN_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_hidden_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_hidden_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"private-deploy\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FORK_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_fork_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_fork_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"forked\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const BLOCKED_MODEL_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_blocked_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_blocked_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"blocked\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const WRITE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_write\",\"name\":\"Write\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"blocked.txt\\\",\\\"content\\\":\\\"must-not-write\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SKILL_THEN_GLOB_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_serial_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_serial_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"root-policy\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_serial_glob\",\"name\":\"Glob\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\\\"**/*\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const OPENAI_SKILL_SSE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_skill\",\"type\":\"function\",\"function\":{\"name\":\"Skill\",\"arguments\":\"\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"name\\\":\\\"re\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"view\\\",\\\"values\\\":[\\\"README.md\\\"]}\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

const OPENAI_FINAL_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"openai skill done\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

// issue #258: the documented Chat Completions shape under
// `stream_options.include_usage` — every ordinary chunk carries `"usage":null`
// and a final chunk with empty `choices` carries the request usage. The control
// removes only the `"usage":null` members.
const OPENAI_USAGE_NULL_FINAL_USAGE =
    "data: {\"id\":\"chatcmpl-258\",\"object\":\"chat.completion.chunk\",\"choices\":[]," ++
    "\"usage\":{\"prompt_tokens\":2006,\"completion_tokens\":10,\"total_tokens\":2016,\"prompt_tokens_details\":{\"cached_tokens\":1920}}}\n\n";

const OPENAI_USAGE_NULL_SSE =
    "data: {\"id\":\"chatcmpl-258\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}],\"usage\":null}\n\n" ++
    "data: {\"id\":\"chatcmpl-258\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}],\"usage\":null}\n\n" ++
    "data: {\"id\":\"chatcmpl-258\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}\n\n" ++
    OPENAI_USAGE_NULL_FINAL_USAGE ++
    "data: [DONE]\n\n";

const OPENAI_USAGE_NULL_CONTROL_SSE =
    "data: {\"id\":\"chatcmpl-258\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-258\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-258\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    OPENAI_USAGE_NULL_FINAL_USAGE ++
    "data: [DONE]\n\n";

const OPENAI_RESPONSES_FINAL_SSE =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_agentcore\"}}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_agentcore\",\"output_index\":0,\"delta\":\"responses done\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_agentcore\",\"status\":\"completed\",\"usage\":{\"input_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";

const OPENAI_RESPONSES_FORK_SKILL_SSE =
    "event: response.output_item.added\n" ++
    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_fork\",\"call_id\":\"call_fork\",\"name\":\"Skill\",\"arguments\":\"\"}}\n\n" ++
    "event: response.function_call_arguments.done\n" ++
    "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_fork\",\"output_index\":0,\"arguments\":\"{\\\"name\\\":\\\"forked\\\"}\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fork\",\"status\":\"completed\",\"usage\":{\"input_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";

const OPENAI_RESPONSES_REVIEW_SKILL_SSE =
    "event: response.output_item.added\n" ++
    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_review\",\"call_id\":\"call_review\",\"name\":\"Skill\",\"arguments\":\"\"}}\n\n" ++
    "event: response.function_call_arguments.done\n" ++
    "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_review\",\"output_index\":0,\"arguments\":\"{\\\"name\\\":\\\"review\\\",\\\"values\\\":[\\\"README.md\\\"]}\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_review\",\"status\":\"completed\",\"usage\":{\"input_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";

const GEMINI_FINAL_SSE =
    "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"gemini done\"}]},\"finishReason\":\"STOP\"}]," ++
    "\"usageMetadata\":{\"promptTokenCount\":2,\"candidatesTokenCount\":3,\"cachedContentTokenCount\":1}}\n\n";

const CONTINUATION_HEAD_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"cont_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"private reasoning\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"head\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const CONTINUATION_TAIL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"cont_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":6,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"tail\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Independent Host-side oracle for the public visible-output segment
/// protocol. It deliberately knows nothing about Conversation or AgentLoop
/// internals.
const ReconstructionProbe = struct {
    current: [128]u8 = undefined,
    current_len: usize = 0,
    group: [256]u8 = undefined,
    group_len: usize = 0,
    group_id: u32 = 0,
    answer: [256]u8 = undefined,
    answer_len: usize = 0,
    /// Visible output of a group that closed as partial: shown, never the answer.
    partial: [256]u8 = undefined,
    partial_len: usize = 0,
    /// The last RunState phase seen: the terminal one once the Run returned.
    last_phase: ?sdk.protocol.RunStatePhase = null,
    thinking: [128]u8 = undefined,
    thinking_len: usize = 0,
    stream_done_count: usize = 0,
    segment_begin_count: usize = 0,
    commentary_count: usize = 0,
    final_count: usize = 0,
    continued_count: usize = 0,
    partial_count: usize = 0,
    discarded_count: usize = 0,
    segment_open: bool = false,
    segment_index: u32 = 0,
    segment_turn: u32 = 0,
    segment_group: u32 = 0,
    usage: sdk.protocol.UsageDelta = .{},

    fn checkedAdd(dst: *u64, value: u64) bool {
        dst.* = std.math.add(u64, dst.*, value) catch return false;
        return true;
    }

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *ReconstructionProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const event_value = switch (parsed.value) {
            .known => |decoded| decoded,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (event_value) {
            .output_segment_begin => |segment| {
                if (self.segment_open or (self.group_len != 0 and self.group_id != segment.group))
                    return wire.EVENT_FATAL;
                self.current_len = 0;
                self.segment_open = true;
                self.segment_index = segment.index;
                self.segment_turn = segment.turn;
                self.segment_group = segment.group;
                self.segment_begin_count += 1;
            },
            .text_chunk => |text| {
                if (!self.segment_open) return wire.EVENT_FATAL;
                if (text.len > self.current.len - self.current_len) return wire.EVENT_FATAL;
                @memcpy(self.current[self.current_len..][0..text.len], text);
                self.current_len += text.len;
            },
            .thinking_chunk => |text| {
                if (text.len > self.thinking.len - self.thinking_len) return wire.EVENT_FATAL;
                @memcpy(self.thinking[self.thinking_len..][0..text.len], text);
                self.thinking_len += text.len;
            },
            .stream_done => {
                self.stream_done_count += 1;
            },
            .output_segment_end => |segment| {
                if (!self.segment_open or
                    self.segment_index != segment.index or
                    self.segment_turn != segment.turn or
                    self.segment_group != segment.group or
                    segment.bytes != @as(u64, @intCast(self.current_len)))
                    return wire.EVENT_FATAL;
                self.segment_open = false;

                switch (segment.disposition) {
                    .continued, .final => {
                        if (self.group_len == 0) self.group_id = segment.group;
                        if (self.group_id != segment.group or self.current_len > self.group.len - self.group_len)
                            return wire.EVENT_FATAL;
                        @memcpy(self.group[self.group_len..][0..self.current_len], self.current[0..self.current_len]);
                        self.group_len += self.current_len;
                        if (segment.disposition == .continued) {
                            self.continued_count += 1;
                        } else {
                            if (self.group_len > self.answer.len) return wire.EVENT_FATAL;
                            @memcpy(self.answer[0..self.group_len], self.group[0..self.group_len]);
                            self.answer_len = self.group_len;
                            self.group_len = 0;
                            self.final_count += 1;
                        }
                    },
                    .commentary => {
                        self.group_len = 0;
                        self.commentary_count += 1;
                    },
                    .partial => {
                        if (self.group_len != 0 and self.group_id != segment.group) return wire.EVENT_FATAL;
                        if (self.current_len > self.partial.len - self.group_len) return wire.EVENT_FATAL;
                        @memcpy(self.partial[0..self.group_len], self.group[0..self.group_len]);
                        @memcpy(self.partial[self.group_len..][0..self.current_len], self.current[0..self.current_len]);
                        self.partial_len = self.group_len + self.current_len;
                        self.group_len = 0;
                        self.partial_count += 1;
                    },
                    .discarded => self.discarded_count += 1,
                }
                self.current_len = 0;
            },
            .run_state => |state| self.last_phase = state.phase,
            .usage => |usage| {
                if (!checkedAdd(&self.usage.input_tokens, usage.input_tokens) or
                    !checkedAdd(&self.usage.output_tokens, usage.output_tokens) or
                    !checkedAdd(&self.usage.cache_read_input_tokens, usage.cache_read_input_tokens) or
                    !checkedAdd(&self.usage.cache_creation_input_tokens, usage.cache_creation_input_tokens))
                    return wire.EVENT_FATAL;
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }
};

test "Host reconstruction oracle follows public output segment dispositions" {
    var probe = ReconstructionProbe{};
    const events = [_][]const u8{
        "{\"output_segment_begin\":{\"index\":1,\"turn\":1,\"group\":1}}",
        "{\"text_chunk\":\"provisional\"}",
        "{\"stream_done\":{}}",
        "{\"output_segment_end\":{\"index\":1,\"turn\":1,\"group\":1,\"disposition\":\"commentary\",\"bytes\":11}}",
        "{\"output_segment_begin\":{\"index\":2,\"turn\":2,\"group\":2}}",
        "{\"text_chunk\":\"head\"}",
        "{\"stream_done\":{}}",
        "{\"output_segment_end\":{\"index\":2,\"turn\":2,\"group\":2,\"disposition\":\"continued\",\"bytes\":4}}",
        "{\"output_segment_begin\":{\"index\":3,\"turn\":2,\"group\":2}}",
        "{\"text_chunk\":\"discarded\"}",
        "{\"stream_done\":{}}",
        "{\"output_segment_end\":{\"index\":3,\"turn\":2,\"group\":2,\"disposition\":\"discarded\",\"bytes\":9}}",
        "{\"output_segment_begin\":{\"index\":4,\"turn\":2,\"group\":2}}",
        "{\"text_chunk\":\"tail\"}",
        "{\"stream_done\":{}}",
        "{\"output_segment_end\":{\"index\":4,\"turn\":2,\"group\":2,\"disposition\":\"final\",\"bytes\":4}}",
    };
    for (events) |encoded| {
        try std.testing.expectEqual(
            wire.EVENT_CONTINUE,
            ReconstructionProbe.event(&probe, null, sdk.bytesView(encoded)),
        );
    }
    try std.testing.expectEqualStrings("headtail", probe.answer[0..probe.answer_len]);
    try std.testing.expectEqual(@as(usize, 4), probe.segment_begin_count);
    try std.testing.expectEqual(@as(usize, 1), probe.commentary_count);
    try std.testing.expectEqual(@as(usize, 1), probe.continued_count);
    try std.testing.expectEqual(@as(usize, 1), probe.discarded_count);
    try std.testing.expectEqual(@as(usize, 1), probe.final_count);
}

/// Test Host registry implementing the consumer-side §4 contract. The binding
/// is keyed by opaque Session handle, deep-copies session_id, and performs the
/// first bind and every comparison under the same per-registry mutex.
const HostIdentityRegistry = struct {
    const Entry = struct {
        session: ?*wire.SessionHandle = null,
        len: u8 = 0,
        bytes: [wire.MAX_SESSION_ID_BYTES_V1]u8 = undefined,
    };

    mutex: sync.Mutex = .{},
    entries: [2]Entry = .{ .{}, .{} },

    fn accept(self: *HostIdentityRegistry, session: *wire.SessionHandle, session_id: []const u8) bool {
        if (session_id.len == 0 or session_id.len > wire.MAX_SESSION_ID_BYTES_V1) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.session == session) {
                return entry.len == session_id.len and std.mem.eql(u8, entry.bytes[0..entry.len], session_id);
            }
        }
        for (&self.entries) |*entry| {
            if (entry.session == null) {
                entry.session = session;
                entry.len = @intCast(session_id.len);
                @memcpy(entry.bytes[0..session_id.len], session_id);
                return true;
            }
        }
        return false;
    }
};

const Probe = struct {
    registry: HostIdentityRegistry = .{},
    expected_session: ?*wire.SessionHandle = null,
    expected_run_id: u64 = 1,
    ui_calls: usize = 0,
    ui_releases: usize = 0,
    host_calls: usize = 0,
    host_releases: usize = 0,
    saw_tool_start: bool = false,
    saw_tool_result: bool = false,
    saw_run_state: bool = false,
    run_state_sequence_valid: bool = true,
    run_state_saw_starting: bool = false,
    run_state_saw_executing_tools: bool = false,
    run_state_saw_waiting_ui: bool = false,
    run_state_saw_completed: bool = false,
    run_state_terminal_empty: bool = false,
    run_state_invariant_valid: bool = true,
    run_state_last_run_id: u64 = 0,
    run_state_last_seq: u64 = 0,

    fn context(self: *Probe, run_ptr: ?*const wire.RunContextV1) ?sdk.RunContext {
        const run = sdk.validateRunContext(run_ptr) catch return null;
        if (run.session != self.expected_session or run.run_id != self.expected_run_id or run.session_id.len != 24)
            return null;
        if (!self.registry.accept(run.session, run.session_id)) return null;
        return run;
    }

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        _ = self.context(run_ptr) orelse return wire.EVENT_FATAL;
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known_event| switch (known_event) {
                .tool_start => self.saw_tool_start = true,
                .tool_result => self.saw_tool_result = true,
                .run_state => |state| {
                    self.saw_run_state = true;
                    if (state.phase == .generating and state.in_flight_tools.len != 0)
                        self.run_state_invariant_valid = false;
                    if (self.run_state_last_run_id != state.run_id) {
                        self.run_state_last_run_id = state.run_id;
                        self.run_state_last_seq = 0;
                    }
                    if (state.transition_seq != self.run_state_last_seq + 1)
                        self.run_state_sequence_valid = false;
                    self.run_state_last_seq = state.transition_seq;
                    switch (state.phase) {
                        .starting => self.run_state_saw_starting = true,
                        .executing_tools => self.run_state_saw_executing_tools = true,
                        .waiting_ui => self.run_state_saw_waiting_ui = true,
                        .completed => {
                            self.run_state_saw_completed = true;
                            self.run_state_terminal_empty = state.in_flight_tools.len == 0;
                        },
                        else => {},
                    }
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, request_json: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        _ = self.context(run_ptr) orelse return wire.UI_FATAL;
        const bytes = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, bytes) catch return wire.UI_FATAL;
        defer parsed.deinit();
        if (parsed.value != .ask_question) return wire.UI_FATAL;
        self.ui_calls += 1;
        const values = [_][]const u8{"Yes"};
        const answers = [_]sdk.protocol.Answer{.{ .values = &values }};
        const response = sdk.encodeUiResponse(std.heap.c_allocator, parsed.value, .{ .answers = &answers }) catch return wire.UI_FATAL;
        (out orelse {
            std.heap.c_allocator.free(response);
            return wire.UI_FATAL;
        }).* = .{ .ptr = response.ptr, .len = response.len };
        return wire.UI_ANSWERED;
    }

    fn uiRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.ui_releases += 1;
        if (out) |value| {
            if (value.ptr) |ptr| std.heap.c_allocator.free(ptr[0..@intCast(value.len)]);
            value.* = .{ .ptr = null, .len = 0 };
        }
    }

    fn host(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, args: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
        _ = self.context(run_ptr) orelse return wire.HOST_FATAL;
        if (std.mem.indexOf(u8, sdk.borrowedBytes(args) catch return wire.HOST_FAILED, "hello") == null) return wire.HOST_FAILED;
        self.host_calls += 1;
        const result = "host-ok";
        (out orelse return wire.HOST_FAILED).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        return wire.HOST_OK;
    }

    fn hostRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.host_releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

const UiFailureMode = enum {
    fatal,
    oversized,
    unavailable,
    cancelled_with_buffer,
    unknown,
    abort_twice,
};

fn acceptEvent(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
    return wire.EVENT_CONTINUE;
}

const PublicFileChangesProbe = struct {
    expected_session: ?*wire.SessionHandle = null,
    expected_run_id: u64 = 0,
    rejected: u32 = 0,
    applied: u32 = 0,
    denied_tool_results: u32 = 0,
    applied_tool_results: u32 = 0,

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        if (run.session != self.expected_session or run.run_id != self.expected_run_id)
            return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const known = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        const value = switch (known) {
            .tool_result => |result| {
                if (!std.mem.eql(u8, result.id, "tu_write") or
                    !std.mem.eql(u8, result.name, "Write"))
                    return wire.EVENT_CONTINUE;
                if (run.run_id == 1) {
                    if (result.file_refs != null) return wire.EVENT_FATAL;
                    self.denied_tool_results += 1;
                    return wire.EVENT_CONTINUE;
                }
                if (run.run_id != 2) return wire.EVENT_FATAL;
                const refs = result.file_refs orelse return wire.EVENT_FATAL;
                if (refs.len != 1) return wire.EVENT_FATAL;
                const file_ref = refs[0];
                const path = switch (file_ref.locator) {
                    .workspace_path => |path| path,
                    else => return wire.EVENT_FATAL,
                };
                if (!std.mem.eql(u8, path, "blocked.txt") or
                    !std.mem.eql(u8, file_ref.title, "blocked.txt") or
                    !std.mem.eql(u8, file_ref.kind, "created") or
                    file_ref.range != null)
                    return wire.EVENT_FATAL;
                self.applied_tool_results += 1;
                return wire.EVENT_CONTINUE;
            },
            .file_changes => |changes| changes,
            else => return wire.EVENT_CONTINUE,
        };
        if (!std.mem.eql(u8, value.id, "tu_write") or
            !std.mem.eql(u8, value.name, "Write") or
            value.changes.len != 1 or value.overflow or value.lost)
            return wire.EVENT_FATAL;
        const change = value.changes[0];
        const path = switch (change.locator) {
            .workspace_path => |path| path,
            else => return wire.EVENT_FATAL,
        };
        if (!std.mem.eql(u8, path, "blocked.txt") or
            !std.mem.eql(u8, change.tool, "Write") or
            !std.mem.eql(u8, change.tool_use_id, "tu_write") or
            change.kind != .created or change.agent_depth != 0)
            return wire.EVENT_FATAL;
        switch (change.status) {
            .rejected => {
                if (change.before_bytes != 0 or change.after_bytes != 0 or
                    change.unified_diff != null or !change.diff_complete)
                    return wire.EVENT_FATAL;
                self.rejected += 1;
            },
            .applied => {
                if (change.before_bytes != 0 or change.after_bytes == 0 or
                    !change.diff_complete or
                    std.mem.indexOf(u8, change.unified_diff orelse return wire.EVENT_FATAL, "+must-not-write") == null)
                    return wire.EVENT_FATAL;
                self.applied += 1;
            },
            else => return wire.EVENT_FATAL,
        }
        return wire.EVENT_CONTINUE;
    }
};

const HostReadRefsProbe = struct {
    expected_session: ?*wire.SessionHandle = null,
    host_calls: u32 = 0,
    host_releases: u32 = 0,
    tool_results: u32 = 0,

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        if (run.session != self.expected_session or run.run_id != 1) return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const known = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        const result = switch (known) {
            .tool_result => |value| value,
            else => return wire.EVENT_CONTINUE,
        };
        if (!std.mem.eql(u8, result.id, "tu_host_read") or
            !std.mem.eql(u8, result.name, "Read"))
            return wire.EVENT_CONTINUE;
        if (result.is_error or result.file_refs != null or
            !std.mem.eql(u8, result.content, "host-read-ok"))
            return wire.EVENT_FATAL;
        self.tool_results += 1;
        return wire.EVENT_CONTINUE;
    }

    fn host(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        _: wire.BytesViewV1,
        out: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.HOST_FATAL;
        if (run.session != self.expected_session or run.run_id != 1) return wire.HOST_FATAL;
        const result = "host-read-ok";
        (out orelse return wire.HOST_FATAL).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        self.host_calls += 1;
        return wire.HOST_OK;
    }

    fn releaseHost(raw: ?*anyopaque, result: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        if (result) |out| {
            if (out.ptr != null) self.host_releases += 1;
            out.* = .{ .ptr = null, .len = 0 };
        }
    }
};

const UiFailureProbe = struct {
    mode: UiFailureMode,
    api: ?sdk.Api = null,
    calls: usize = 0,
    releases: usize = 0,
    byte: u8 = 0,
    nested_run_status: u32 = std.math.maxInt(u32),
    nested_destroy_status: u32 = std.math.maxInt(u32),
    first_abort_status: u32 = std.math.maxInt(u32),
    second_abort_status: u32 = std.math.maxInt(u32),

    fn ui(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *UiFailureProbe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        self.calls += 1;
        return switch (self.mode) {
            .fatal => wire.UI_FATAL,
            .oversized => blk: {
                (out orelse return wire.UI_FATAL).* = .{
                    .ptr = @ptrCast(&self.byte),
                    .len = wire.MAX_UI_RESPONSE_BYTES_V1 + 1,
                };
                break :blk wire.UI_ANSWERED;
            },
            .unavailable => wire.UI_UNAVAILABLE,
            .cancelled_with_buffer => blk: {
                (out orelse return wire.UI_FATAL).* = .{
                    .ptr = @ptrCast(&self.byte),
                    .len = 1,
                };
                break :blk wire.UI_CANCELLED;
            },
            .unknown => std.math.maxInt(u32),
            .abort_twice => blk: {
                const api = self.api orelse return wire.UI_FATAL;
                const run = sdk.validateRunContext(run_ptr) catch return wire.UI_FATAL;
                var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
                defer api.bufferRelease()(&diagnostic);
                self.nested_run_status = api.session().runText(
                    run.session,
                    run.run_id + 1,
                    sdk.bytesView("nested callback run"),
                    null,
                    null,
                    &diagnostic,
                );
                api.bufferRelease()(&diagnostic);
                self.nested_destroy_status = api.session().destroy()(run.session, &diagnostic);
                api.bufferRelease()(&diagnostic);
                self.first_abort_status = api.session().abort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
                api.bufferRelease()(&diagnostic);
                self.second_abort_status = api.session().abort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
                break :blk wire.UI_UNAVAILABLE;
            },
        };
    }

    fn release(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *UiFailureProbe = @ptrCast(@alignCast(raw orelse return));
        self.releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

const FatalEventProbe = struct {
    calls: usize = 0,

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
        const self: *FatalEventProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        self.calls += 1;
        return wire.EVENT_FATAL;
    }
};

const NestedSkillFatalProbe = struct {
    calls: usize = 0,
    failed: bool = false,

    fn event(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *NestedSkillFatalProbe = @ptrCast(@alignCast(
            raw orelse return wire.EVENT_FATAL,
        ));
        self.calls += 1;
        const bytes = sdk.borrowedBytes(event_json) catch
            return wire.EVENT_FATAL;
        if (std.mem.indexOf(u8, bytes, "\"text_chunk\":\"done\"") != null) {
            self.failed = true;
            return wire.EVENT_FATAL;
        }
        return wire.EVENT_CONTINUE;
    }
};

const AbortEventProbe = struct {
    api: sdk.Api,
    calls: usize = 0,
    stale_abort_status: u32 = std.math.maxInt(u32),
    abort_status: u32 = std.math.maxInt(u32),

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
        const self: *AbortEventProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        self.calls += 1;
        if (self.calls == 1) {
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const wrong_run_id: u64 = 2;
            self.stale_abort_status = self.api.session().abort()(run.session, wrong_run_id, wire.ABORT_USER_REQUEST, &diagnostic);
            self.api.bufferRelease()(&diagnostic);
            self.abort_status = self.api.session().abort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
            self.api.bufferRelease()(&diagnostic);
        }
        return wire.EVENT_CONTINUE;
    }
};

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

fn skillPolicy(grants: []const wire.BytesViewV1) wire.SkillPolicyV1 {
    var policy = std.mem.zeroes(wire.SkillPolicyV1);
    policy.struct_size = @sizeOf(wire.SkillPolicyV1);
    policy.granted_skill_ids = if (grants.len == 0) null else grants.ptr;
    policy.granted_skill_id_count = grants.len;
    return policy;
}

const DecodedSkillPolicy = struct {
    allocator: std.mem.Allocator,
    catalog: sdk.ParsedSkillCatalog,
    grants: []wire.BytesViewV1,
    policy: wire.SkillPolicyV1,

    fn init(allocator: std.mem.Allocator, descriptor: []const u8) !DecodedSkillPolicy {
        var catalog = try sdk.decodeSkillCatalog(allocator, descriptor);
        errdefer catalog.deinit();
        const grants = try allocator.alloc(wire.BytesViewV1, catalog.value.skills.len);
        for (catalog.value.skills, grants) |skill, *grant| grant.* = sdk.bytesView(skill.skill_id);
        return .{
            .allocator = allocator,
            .catalog = catalog,
            .grants = grants,
            .policy = skillPolicy(grants),
        };
    }

    fn deinit(self: *DecodedSkillPolicy) void {
        self.allocator.free(self.grants);
        self.catalog.deinit();
        self.* = undefined;
    }
};

const PublicSessionFixture = struct {
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle = null,
    session: ?*wire.SessionHandle = null,
    diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },

    fn init(root: []const u8, base_url: []const u8, model: []const u8) !PublicSessionFixture {
        return initConfigured(
            root,
            base_url,
            model,
            null,
            wire.RUN_JOURNAL_EPHEMERAL,
        );
    }

    fn initWithBudget(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        budget: ?*const wire.DurableBudgetProfileV1,
    ) !PublicSessionFixture {
        return initConfigured(
            root,
            base_url,
            model,
            budget,
            wire.RUN_JOURNAL_EPHEMERAL,
        );
    }

    fn initWithRunJournal(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        run_journal_mode_code: u32,
    ) !PublicSessionFixture {
        return initConfigured(
            root,
            base_url,
            model,
            null,
            run_journal_mode_code,
        );
    }

    fn initProvider(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        provider_kind_code: u32,
        protocol_kind_code: u32,
    ) !PublicSessionFixture {
        return initProviderConfigured(
            root,
            base_url,
            model,
            null,
            wire.RUN_JOURNAL_EPHEMERAL,
            provider_kind_code,
            protocol_kind_code,
            &.{},
        );
    }

    /// Revision 21: a Session whose Host declares `capabilities`.
    fn initCapabilities(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        provider_kind_code: u32,
        protocol_kind_code: u32,
        capabilities: []const wire.ModelCapabilityV1,
    ) !PublicSessionFixture {
        return initProviderConfigured(
            root,
            base_url,
            model,
            null,
            wire.RUN_JOURNAL_EPHEMERAL,
            provider_kind_code,
            protocol_kind_code,
            capabilities,
        );
    }

    fn initConfigured(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        budget: ?*const wire.DurableBudgetProfileV1,
        run_journal_mode_code: u32,
    ) !PublicSessionFixture {
        return initProviderConfigured(
            root,
            base_url,
            model,
            budget,
            run_journal_mode_code,
            wire.PROVIDER_ANTHROPIC,
            wire.PROTOCOL_DEFAULT,
            &.{},
        );
    }

    fn initProviderConfigured(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        budget: ?*const wire.DurableBudgetProfileV1,
        run_journal_mode_code: u32,
        provider_kind_code: u32,
        protocol_kind_code: u32,
        capabilities: []const wire.ModelCapabilityV1,
    ) !PublicSessionFixture {
        return initObservedProviderConfigured(
            root,
            base_url,
            model,
            budget,
            run_journal_mode_code,
            provider_kind_code,
            protocol_kind_code,
            capabilities,
            null,
            acceptEvent,
        );
    }

    /// A Session whose events go to `on_event` with `ctx`.
    fn initObserved(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        budget: ?*const wire.DurableBudgetProfileV1,
        ctx: *anyopaque,
        on_event: wire.OnEventFnV1,
    ) !PublicSessionFixture {
        return initObservedProviderConfigured(
            root,
            base_url,
            model,
            budget,
            wire.RUN_JOURNAL_EPHEMERAL,
            wire.PROVIDER_ANTHROPIC,
            wire.PROTOCOL_DEFAULT,
            &.{},
            ctx,
            on_event,
        );
    }

    fn initObservedProviderConfigured(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        budget: ?*const wire.DurableBudgetProfileV1,
        run_journal_mode_code: u32,
        provider_kind_code: u32,
        protocol_kind_code: u32,
        capabilities: []const wire.ModelCapabilityV1,
        event_ctx: ?*anyopaque,
        on_event: wire.OnEventFnV1,
    ) !PublicSessionFixture {
        const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
            return error.MissingApi;
        var self = PublicSessionFixture{
            .api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api))),
        };
        errdefer self.deinit();

        var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
        runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            self.api.runtime().create()(&runtime_config, null, &self.runtime, &self.diagnostic),
        );

        var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
        host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
        host_config.provider_kind_code = provider_kind_code;
        host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
        host_config.shell_policy_code = wire.SHELL_DISABLED;
        host_config.api_key = sdk.bytesView("test-key");
        host_config.base_url = sdk.bytesView(base_url);
        host_config.workspace_root = sdk.bytesView(root);
        host_config.workspace_home = sdk.bytesView(root);
        host_config.durable_budget = budget;
        host_config.run_journal_mode_code = run_journal_mode_code;
        host_config.protocol_kind_code = protocol_kind_code;
        if (capabilities.len != 0) {
            host_config.model_capabilities = capabilities.ptr;
            host_config.model_capability_count = capabilities.len;
        }
        var session_config = sessionCreateConfig(&host_config, model);
        var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        callbacks.ctx = event_ctx;
        callbacks.on_event = on_event;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            self.api.session().create()(
                self.runtime,
                &session_config,
                &callbacks,
                &self.session,
                &self.diagnostic,
            ),
        );
        return self;
    }

    fn deinit(self: *PublicSessionFixture) void {
        if (self.session) |handle| {
            _ = self.api.session().destroy()(handle, &self.diagnostic);
            self.session = null;
            self.releaseDiagnostic();
        }
        if (self.runtime) |handle| {
            _ = self.api.runtime().destroy()(handle, &self.diagnostic);
            self.runtime = null;
            self.releaseDiagnostic();
        }
        self.releaseDiagnostic();
    }

    fn releaseDiagnostic(self: *PublicSessionFixture) void {
        self.api.bufferRelease()(&self.diagnostic);
    }

    fn runText(self: *PublicSessionFixture, run_id: u64, prompt: []const u8) !wire.RunResultV1 {
        return self.runTextTurns(run_id, prompt, 1);
    }

    fn runTextTurns(self: *PublicSessionFixture, run_id: u64, prompt: []const u8, max_turns: u32) !wire.RunResultV1 {
        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = max_turns;
        var result = std.mem.zeroes(wire.RunResultV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            self.api.session().runText(
                self.session,
                run_id,
                sdk.bytesView(prompt),
                &options,
                &result,
                &self.diagnostic,
            ),
        );
        return result;
    }
};

test "L2 public AgentCore durable Run journal records the physical provider effect" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var fixture = try PublicSessionFixture.initWithRunJournal(
        root,
        url,
        "test-model",
        wire.RUN_JOURNAL_DURABLE_WORKSPACE,
    );
    defer fixture.deinit();

    const result = try fixture.runText(1, "durably execute one provider request");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().describe()(
            fixture.session,
            &description,
            &fixture.diagnostic,
        ),
    );
    defer fixture.api.bufferRelease()(&description);
    const encoded = try sdk.borrowedBytes(.{
        .ptr = description.ptr,
        .len = description.len,
    });
    const decoded = try sdk.decodeSessionDescription(a, encoded);
    defer decoded.deinit();
    const session_id = core.session_id.SessionId.fromSlice(decoded.value.session_id) orelse
        return error.InvalidSessionId;
    const journal_root = try std.fmt.allocPrint(
        a,
        "{s}/.metacodes/agentcore/sessions/{s}",
        .{ root, decoded.value.session_id },
    );
    defer a.free(journal_root);

    const summary = try core.tool_observation_journal.validate(journal_root, session_id);
    try std.testing.expect(summary.complete);
    try std.testing.expectEqual(@as(u64, 4), summary.records);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "Revision 15 public Session rejects unknown Run journal and provider protocol codes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView("http://127.0.0.1:1");
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.run_journal_mode_code = std.math.maxInt(u32);
    var create = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.session().create()(runtime, &create, &callbacks, &session, &diagnostic),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);

    host.run_journal_mode_code = wire.RUN_JOURNAL_EPHEMERAL;
    host.protocol_kind_code = wire.OPENAI_PROTOCOL_RESPONSES;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.session().create()(runtime, &create, &callbacks, &session, &diagnostic),
    );
    try std.testing.expect(session == null);

    api.bufferRelease()(&diagnostic);
    host.provider_kind_code = wire.PROVIDER_OPENAI;
    host.protocol_kind_code = std.math.maxInt(u32);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.session().create()(runtime, &create, &callbacks, &session, &diagnostic),
    );
    try std.testing.expect(session == null);
}

test "L2 public AgentCore selects OpenAI Responses and preserves it across set_model" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(
        &.{ OPENAI_RESPONSES_FINAL_SSE, OPENAI_RESPONSES_FINAL_SSE },
        0,
    );
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var fixture = try PublicSessionFixture.initProvider(
        root,
        url,
        "responses-model",
        wire.PROVIDER_OPENAI,
        wire.OPENAI_PROTOCOL_RESPONSES,
    );
    defer fixture.deinit();

    var result = try fixture.runText(1, "use the Responses protocol");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    const first_body = (server.requestAt(0) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, first_body, "\"input\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_body, "\"messages\":") == null);

    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().setModel()(
            fixture.session,
            sdk.bytesView("replacement-responses-model"),
            &fixture.diagnostic,
        ),
    );
    result = try fixture.runText(2, "keep using the Responses protocol");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    const second = server.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings(
        "\"replacement-responses-model\"",
        second.jsonField("model").?,
    );
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"input\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"messages\":") == null);
}

test "L2 durable budget profile crosses the public wire and rejects before Run admission" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const budget = wire.DurableBudgetProfileV1{
        .struct_size = @sizeOf(wire.DurableBudgetProfileV1),
        .reserved0 = 0,
        .hard_bytes = 4 * 1024 * 1024,
        .soft_bytes = 3 * 1024 * 1024,
        .input_cap_bytes = 512,
        .provider_request_cap_bytes = 512 * 1024,
        .provider_result_cap_bytes = 64 * 1024,
        .tool_result_cap_bytes = 64 * 1024,
        .mcp_result_cap_bytes = 64 * 1024,
        .audit_reserve_bytes = 64 * 1024,
        .terminal_reserve_bytes = 64 * 1024,
        .reserved = [_]u64{0} ** 4,
    };
    var fixture = try PublicSessionFixture.initWithBudget(
        root,
        url,
        "test-model",
        &budget,
    );
    defer fixture.deinit();

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().describe()(
            fixture.session,
            &description,
            &fixture.diagnostic,
        ),
    );
    {
        defer fixture.api.bufferRelease()(&description);
        const encoded = try sdk.borrowedBytes(.{
            .ptr = description.ptr,
            .len = description.len,
        });
        const decoded = try sdk.decodeSessionDescription(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(
            budget.hard_bytes,
            decoded.value.budget.hard_bytes,
        );
        try std.testing.expectEqual(
            budget.soft_bytes,
            decoded.value.budget.soft_bytes,
        );
    }

    var oversized: [513]u8 = undefined;
    @memset(&oversized, 'x');
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
        fixture.api.session().runText(
            fixture.session,
            1,
            sdk.bytesView(&oversized),
            &options,
            &result,
            &fixture.diagnostic,
        ),
    );
    fixture.releaseDiagnostic();
    result = try fixture.runText(1, "short input reuses the unconsumed run id");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

fn appendCompactablePublicHistory(fixture: *PublicSessionFixture) !void {
    const old_context = [_]u8{'A'} ** 8192;
    var result = try fixture.runText(1, &old_context);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    for (2..7) |run_id| {
        result = try fixture.runText(run_id, "recent context");
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    }
}

fn writeSkillFixture(
    allocator: std.mem.Allocator,
    root: []const u8,
    invocation_name: []const u8,
    contents: []const u8,
) !void {
    try writeSkillFixtureInSource(
        allocator,
        root,
        ".agents",
        invocation_name,
        contents,
    );
}

fn writeSkillFixtureInSource(
    allocator: std.mem.Allocator,
    root: []const u8,
    source_dir: []const u8,
    invocation_name: []const u8,
    contents: []const u8,
) !void {
    const skill_dir = try std.fs.path.join(
        allocator,
        &.{ root, source_dir, "skills", invocation_name },
    );
    defer allocator.free(skill_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, skill_dir);
    const skill_path = try std.fs.path.join(
        allocator,
        &.{ skill_dir, "SKILL.md" },
    );
    defer allocator.free(skill_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = skill_path,
        .data = contents,
    });
}

const CatalogIdentities = struct {
    revision: []u8,
    skill_id: []u8,
};

fn extractCatalogIdentities(
    allocator: std.mem.Allocator,
    descriptor_json: []const u8,
    invocation_name: []const u8,
) !CatalogIdentities {
    const parsed = try sdk.decodeSkillCatalog(allocator, descriptor_json);
    defer parsed.deinit();
    for (parsed.value.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, invocation_name)) {
            const revision = try allocator.dupe(u8, parsed.value.catalog_revision);
            errdefer allocator.free(revision);
            return .{
                .revision = revision,
                .skill_id = try allocator.dupe(u8, skill.skill_id),
            };
        }
    }
    return error.SkillMissingFromCatalog;
}

fn expectInvalidSessionConfig(
    api: sdk.Api,
    runtime: *wire.RuntimeHandle,
    config: *const wire.SessionCreateConfigV1,
    callbacks: *const wire.SessionCallbacksV1,
    diagnostic: *wire.OwnedBytesV1,
) !void {
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.session().create()(runtime, config, callbacks, &session, diagnostic),
    );
    try std.testing.expect(session == null);
    try std.testing.expect(diagnostic.ptr != null and diagnostic.len != 0);
    const diagnostic_bytes = try sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len });
    const api_key = try sdk.borrowedBytes(config.host.?.api_key);
    if (api_key.len != 0) try std.testing.expect(std.mem.indexOf(u8, diagnostic_bytes, api_key) == null);
    api.bufferRelease()(diagnostic);
    try std.testing.expect(diagnostic.ptr == null and diagnostic.len == 0);
}

fn sessionCreateConfig(
    host: *const wire.SessionHostConfigV1,
    model: []const u8,
) wire.SessionCreateConfigV1 {
    var config = std.mem.zeroes(wire.SessionCreateConfigV1);
    config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    config.host = host;
    config.model = sdk.bytesView(model);
    return config;
}

const PublicMcpProbe = struct {
    const Connection = struct {
        owner: ?*anyopaque = null,
        purpose_code: u32 = 0,
        era_code: u32 = 0,
        closed: bool = false,
    };

    server_era_code: u32 = wire.MCP_ERA_2026_07_28,
    advertise_tools: bool = true,
    required_task: bool = false,
    dialect_matrix: bool = false,
    business_error: bool = false,
    successful_call_padding_bytes: usize = 0,
    tool_count: u8 = 1,
    probe_open_status: u32 = wire.MCP_OPEN_OK,
    probe_exchange_status: ?u32 = null,
    probe_response_body: ?[]const u8 = null,
    probe_http_status: u32 = 0,
    actual_http_status: u32 = 0,
    notify_status: u32 = wire.MCP_NOTIFY_OK,
    connections: [8]Connection = [_]Connection{.{}} ** 8,
    connection_count: usize = 0,
    open_attempts: u32 = 0,
    probe_open_attempts: u32 = 0,
    actual_open_attempts: u32 = 0,
    opens: u32 = 0,
    probe_opens: u32 = 0,
    actual_opens: u32 = 0,
    actual_2025_11_opens: u32 = 0,
    actual_2025_06_opens: u32 = 0,
    request_attempts: u32 = 0,
    requests: u32 = 0,
    list_requests: u32 = 0,
    list_requests_by_era: [4]u32 = [_]u32{0} ** 4,
    call_requests: u32 = 0,
    saw_schema_mismatch_arguments: bool = false,
    notifications: u32 = 0,
    notifications_by_era: [4]u32 = [_]u32{0} ** 4,
    closes: u32 = 0,
    double_closes: u32 = 0,
    releases: u32 = 0,
    connector_retains: u32 = 0,
    connector_releases: u32 = 0,

    fn connector(self: *@This()) wire.McpConnectorV1 {
        var result = std.mem.zeroes(wire.McpConnectorV1);
        result.struct_size = @sizeOf(wire.McpConnectorV1);
        result.ctx = self;
        result.open = open;
        result.request = request;
        result.request_tool_stream = requestToolStream;
        result.notify = notify;
        result.close = close;
        result.release_response = releaseResponse;
        result.retain_connector = retainConnector;
        result.release_connector = releaseConnector;
        return result;
    }

    fn retainConnector(raw: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        self.connector_retains += 1;
    }

    fn releaseConnector(raw: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        self.connector_releases += 1;
    }

    fn open(
        raw: ?*anyopaque,
        purpose_code: u32,
        requested_era_code: u32,
        _: u32,
        out_connection_ctx: ?*?*anyopaque,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_OPEN_FATAL));
        const out = out_connection_ctx orelse return wire.MCP_OPEN_FATAL;
        out.* = null;
        self.open_attempts += 1;
        switch (purpose_code) {
            wire.MCP_CONNECTION_DISPOSABLE_PROBE => {
                self.probe_open_attempts += 1;
                if (requested_era_code != wire.MCP_ERA_2026_07_28)
                    return wire.MCP_OPEN_FATAL;
                if (self.probe_open_status != wire.MCP_OPEN_OK)
                    return self.probe_open_status;
                self.probe_opens += 1;
            },
            wire.MCP_CONNECTION_ACTUAL => {
                self.actual_open_attempts += 1;
                if (self.server_era_code == wire.MCP_ERA_2026_07_28 and
                    requested_era_code != wire.MCP_ERA_2026_07_28)
                    return wire.MCP_OPEN_NETWORK_ERROR;
                if (self.server_era_code == wire.MCP_ERA_2025_11_25 and
                    requested_era_code != wire.MCP_ERA_2025_11_25)
                    return wire.MCP_OPEN_NETWORK_ERROR;
                if (self.server_era_code == wire.MCP_ERA_2025_06_18 and
                    requested_era_code != wire.MCP_ERA_2025_11_25 and
                    requested_era_code != wire.MCP_ERA_2025_06_18)
                    return wire.MCP_OPEN_NETWORK_ERROR;
                self.actual_opens += 1;
                if (requested_era_code == wire.MCP_ERA_2025_11_25)
                    self.actual_2025_11_opens += 1;
                if (requested_era_code == wire.MCP_ERA_2025_06_18)
                    self.actual_2025_06_opens += 1;
            },
            else => return wire.MCP_OPEN_FATAL,
        }
        if (self.connection_count == self.connections.len)
            return wire.MCP_OPEN_FATAL;
        const connection = &self.connections[self.connection_count];
        self.connection_count += 1;
        connection.* = .{
            .owner = raw,
            .purpose_code = purpose_code,
            .era_code = requested_era_code,
        };
        self.opens += 1;
        out.* = connection;
        return wire.MCP_OPEN_OK;
    }

    fn request(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        request_json: wire.BytesViewV1,
        _: u32,
        _: ?*const wire.McpCancellationV1,
        out_response: ?*wire.McpResponseV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_EXCHANGE_FATAL));
        const connection = liveConnection(raw, connection_ctx) orelse
            return wire.MCP_EXCHANGE_FATAL;
        const out = out_response orelse return wire.MCP_EXCHANGE_FATAL;
        out.* = .{
            .struct_size = @sizeOf(wire.McpResponseV1),
            .http_status = 0,
            .body = .{ .ptr = null, .len = 0 },
            .reserved = [_]u64{0} ** 2,
        };
        self.request_attempts += 1;
        if (connection.purpose_code == wire.MCP_CONNECTION_DISPOSABLE_PROBE)
            if (self.probe_exchange_status) |status| return status;
        const encoded = sdk.borrowedBytes(request_json) catch return wire.MCP_EXCHANGE_FATAL;
        const id = requestId(encoded) orelse return wire.MCP_EXCHANGE_FATAL;
        const response = if (std.mem.indexOf(u8, encoded, "server/discover") != null) blk: {
            if (connection.era_code != wire.MCP_ERA_2026_07_28)
                return wire.MCP_EXCHANGE_FATAL;
            if (connection.purpose_code == wire.MCP_CONNECTION_DISPOSABLE_PROBE and
                self.probe_response_body != null)
                break :blk std.heap.c_allocator.dupe(u8, self.probe_response_body.?);
            break :blk if (self.server_era_code == wire.MCP_ERA_2026_07_28) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{}},\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}",
                .{id},
            );
        } else if (std.mem.indexOf(u8, encoded, "initialize") != null) blk: {
            if (connection.purpose_code != wire.MCP_CONNECTION_ACTUAL or
                connection.era_code == wire.MCP_ERA_2026_07_28)
                return wire.MCP_EXCHANGE_FATAL;
            break :blk std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{s},\"serverInfo\":{{\"name\":\"public-test\",\"version\":\"1\"}}}}}}",
                .{
                    id,
                    mcpVersion(self.server_era_code) orelse return wire.MCP_EXCHANGE_FATAL,
                    if (self.advertise_tools) "{\"tools\":{}}" else "{}",
                },
            );
        } else if (std.mem.indexOf(u8, encoded, "tools/list") != null) blk: {
            if (connection.purpose_code != wire.MCP_CONNECTION_ACTUAL or
                connection.era_code != self.server_era_code)
                return wire.MCP_EXCHANGE_FATAL;
            self.list_requests += 1;
            self.list_requests_by_era[
                eraIndex(connection.era_code) orelse
                    return wire.MCP_EXCHANGE_FATAL
            ] += 1;
            if (!self.dialect_matrix and (self.tool_count == 0 or self.tool_count > 2))
                return wire.MCP_EXCHANGE_FATAL;
            break :blk if (self.required_task) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"tasked\",\"inputSchema\":{{\"type\":\"object\"}},\"execution\":{{\"taskSupport\":\"required\"}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else if (self.dialect_matrix) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[" ++
                    "{{\"name\":\"implicit\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"implicit_arg\":{{\"type\":\"string\"}}}},\"required\":[\"implicit_arg\"]}}}}," ++
                    "{{\"name\":\"modern\",\"inputSchema\":{{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{{\"modern_arg\":{{\"type\":\"string\"}}}},\"required\":[\"modern_arg\"]}}}}," ++
                    "{{\"name\":\"draft7\",\"inputSchema\":{{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\",\"properties\":{{\"draft7_arg\":{{\"type\":\"string\",\"minLength\":1}}}},\"required\":[\"draft7_arg\"],\"additionalProperties\":false}},\"outputSchema\":{{\"$schema\":\"http://json-schema.org/draft-07/schema#\",\"type\":\"object\"}}}}," ++
                    "{{\"name\":\"custom\",\"inputSchema\":{{\"$schema\":\"https://example.invalid/custom-dialect\",\"type\":\"object\",\"properties\":{{\"custom_arg\":{{\"type\":\"string\"}}}},\"required\":[\"custom_arg\"]}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else if (self.server_era_code == wire.MCP_ERA_2026_07_28 and self.tool_count == 2) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"properties\":{{\"ok\":{{\"type\":\"boolean\"}}}},\"required\":[\"ok\"]}}}},{{\"name\":\"alerts\",\"inputSchema\":{{\"type\":\"object\"}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else if (self.server_era_code == wire.MCP_ERA_2026_07_28) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"properties\":{{\"ok\":{{\"type\":\"boolean\"}}}},\"required\":[\"ok\"]}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else if (self.tool_count == 2) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"properties\":{{\"ok\":{{\"type\":\"boolean\"}}}},\"required\":[\"ok\"]}}}},{{\"name\":\"alerts\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}",
                .{id},
            ) else std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"properties\":{{\"ok\":{{\"type\":\"boolean\"}}}},\"required\":[\"ok\"]}}}}]}}}}",
                .{id},
            );
        } else if (std.mem.indexOf(u8, encoded, "tools/call") != null) blk: {
            self.call_requests += 1;
            if (!self.business_error) return wire.MCP_EXCHANGE_FATAL;
            self.saw_schema_mismatch_arguments =
                std.mem.indexOf(u8, encoded, "\"city\":7") != null;
            break :blk std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"city must be string\"}}],\"isError\":true}}}}",
                .{id},
            );
        } else return wire.MCP_EXCHANGE_FATAL;
        const owned = response catch return wire.MCP_EXCHANGE_FATAL;
        self.requests += 1;
        out.http_status = if (connection.purpose_code == wire.MCP_CONNECTION_DISPOSABLE_PROBE)
            self.probe_http_status
        else
            self.actual_http_status;
        out.body = .{ .ptr = owned.ptr, .len = owned.len };
        return wire.MCP_EXCHANGE_RESPONSE;
    }

    fn requestToolStream(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        request_json: wire.BytesViewV1,
        timeout_ms: u32,
        cancellation: ?*const wire.McpCancellationV1,
        sink: ?*const wire.HostResultSinkV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_EXCHANGE_FATAL));
        const encoded = sdk.borrowedBytes(request_json) catch return wire.MCP_EXCHANGE_FATAL;
        if (self.successful_call_padding_bytes != 0 and
            std.mem.indexOf(u8, encoded, "tools/call") != null)
        {
            _ = liveConnection(raw, connection_ctx) orelse
                return wire.MCP_EXCHANGE_FATAL;
            const destination = sink orelse return wire.MCP_EXCHANGE_FATAL;
            if (destination.struct_size != @sizeOf(wire.HostResultSinkV1) or
                destination.write == null)
                return wire.MCP_EXCHANGE_FATAL;
            const id = requestId(encoded) orelse return wire.MCP_EXCHANGE_FATAL;
            var header_buffer: [256]u8 = undefined;
            const header = std.fmt.bufPrint(
                &header_buffer,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[],\"structuredContent\":{{\"ok\":true,\"payload\":\"",
                .{id},
            ) catch return wire.MCP_EXCHANGE_FATAL;
            if (destination.write.?(destination.ctx, sdk.bytesView(header)) != wire.HOST_SINK_OK)
                return wire.MCP_EXCHANGE_FATAL;
            var block: [4096]u8 = undefined;
            @memset(&block, 'm');
            var remaining = self.successful_call_padding_bytes;
            while (remaining != 0) {
                const count = @min(remaining, block.len);
                const write_status = destination.write.?(
                    destination.ctx,
                    sdk.bytesView(block[0..count]),
                );
                if (write_status != wire.HOST_SINK_OK)
                    return if (write_status == wire.HOST_SINK_ABORTED)
                        wire.MCP_EXCHANGE_CANCELLED
                    else
                        wire.MCP_EXCHANGE_FATAL;
                remaining -= count;
            }
            if (destination.write.?(destination.ctx, sdk.bytesView("\"}}}")) != wire.HOST_SINK_OK)
                return wire.MCP_EXCHANGE_FATAL;
            self.request_attempts += 1;
            self.requests += 1;
            self.call_requests += 1;
            return wire.MCP_EXCHANGE_RESPONSE;
        }
        var response = wire.McpResponseV1{
            .struct_size = @sizeOf(wire.McpResponseV1),
            .http_status = 0,
            .body = .{ .ptr = null, .len = 0 },
            .reserved = [_]u64{0} ** 2,
        };
        const status = request(
            raw,
            connection_ctx,
            request_json,
            timeout_ms,
            cancellation,
            &response,
        );
        defer releaseResponse(raw, connection_ctx, &response.body);
        if (status != wire.MCP_EXCHANGE_RESPONSE) return status;
        const destination = sink orelse return wire.MCP_EXCHANGE_FATAL;
        if (destination.struct_size != @sizeOf(wire.HostResultSinkV1) or
            destination.write == null or response.body.ptr == null)
            return wire.MCP_EXCHANGE_FATAL;
        const bytes = response.body.ptr.?[0..@intCast(response.body.len)];
        var offset: usize = 0;
        while (offset != bytes.len) {
            const count = @min(bytes.len - offset, 4096);
            const write_status = destination.write.?(
                destination.ctx,
                sdk.bytesView(bytes[offset .. offset + count]),
            );
            if (write_status != wire.HOST_SINK_OK)
                return if (write_status == wire.HOST_SINK_ABORTED)
                    wire.MCP_EXCHANGE_CANCELLED
                else
                    wire.MCP_EXCHANGE_FATAL;
            offset += count;
        }
        return wire.MCP_EXCHANGE_RESPONSE;
    }

    fn notify(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        notification_json: wire.BytesViewV1,
        _: u32,
        _: ?*const wire.McpCancellationV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_NOTIFY_FAILED));
        const connection = liveConnection(raw, connection_ctx) orelse
            return wire.MCP_NOTIFY_FAILED;
        if (connection.purpose_code != wire.MCP_CONNECTION_ACTUAL or
            connection.era_code == wire.MCP_ERA_2026_07_28)
            return wire.MCP_NOTIFY_FAILED;
        const encoded = sdk.borrowedBytes(notification_json) catch
            return wire.MCP_NOTIFY_FAILED;
        if (std.mem.indexOf(u8, encoded, "notifications/initialized") == null)
            return wire.MCP_NOTIFY_FAILED;
        if (self.notify_status != wire.MCP_NOTIFY_OK) return self.notify_status;
        self.notifications += 1;
        self.notifications_by_era[
            eraIndex(connection.era_code) orelse
                return wire.MCP_NOTIFY_FAILED
        ] += 1;
        return wire.MCP_NOTIFY_OK;
    }

    fn close(raw: ?*anyopaque, connection_ctx: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const connection: *Connection = @ptrCast(@alignCast(connection_ctx orelse return));
        if (connection.owner != raw) return;
        if (connection.closed) {
            self.double_closes += 1;
            return;
        }
        connection.closed = true;
        self.closes += 1;
    }

    fn expectClosedExactlyOnce(self: *const @This()) !void {
        try std.testing.expectEqual(self.opens, self.closes);
        try std.testing.expectEqual(@as(u32, 0), self.double_closes);
        for (self.connections[0..self.connection_count]) |connection|
            try std.testing.expect(connection.closed);
    }

    fn releaseResponse(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        response: ?*wire.OwnedBytesV1,
    ) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        _ = liveConnection(raw, connection_ctx) orelse return;
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }

    fn liveConnection(raw: ?*anyopaque, connection_ctx: ?*anyopaque) ?*Connection {
        const connection: *Connection = @ptrCast(@alignCast(connection_ctx orelse return null));
        if (connection.owner != raw or connection.closed) return null;
        return connection;
    }

    fn eraIndex(era_code: u32) ?usize {
        if (era_code < wire.MCP_ERA_2026_07_28 or
            era_code > wire.MCP_ERA_2025_06_18)
            return null;
        return @intCast(era_code);
    }

    fn requestId(encoded: []const u8) ?u64 {
        const marker = "\"id\":";
        const start = (std.mem.indexOf(u8, encoded, marker) orelse return null) + marker.len;
        var end = start;
        while (end < encoded.len and std.ascii.isDigit(encoded[end])) : (end += 1) {}
        return std.fmt.parseInt(u64, encoded[start..end], 10) catch null;
    }

    fn mcpVersion(era_code: u32) ?[]const u8 {
        return switch (era_code) {
            wire.MCP_ERA_2026_07_28 => "2026-07-28",
            wire.MCP_ERA_2025_11_25 => "2025-11-25",
            wire.MCP_ERA_2025_06_18 => "2025-06-18",
            else => null,
        };
    }
};

const PublicHttpMcpConnector = struct {
    url: []const u8,
    releases: u32 = 0,
    closes: u32 = 0,

    const Connection = struct {
        owner: *PublicHttpMcpConnector,
        era_code: u32,
    };

    const HttpResult = struct {
        status: u32,
        body: []u8,
    };

    fn connector(self: *@This()) wire.McpConnectorV1 {
        var result = std.mem.zeroes(wire.McpConnectorV1);
        result.struct_size = @sizeOf(wire.McpConnectorV1);
        result.ctx = self;
        result.open = open;
        result.request = request;
        result.request_tool_stream = requestToolStream;
        result.notify = notify;
        result.close = close;
        result.release_response = releaseResponse;
        result.retain_connector = retainConnector;
        result.release_connector = releaseConnector;
        return result;
    }

    fn retainConnector(_: ?*anyopaque) callconv(.c) void {}
    fn releaseConnector(_: ?*anyopaque) callconv(.c) void {}

    fn open(
        raw: ?*anyopaque,
        _: u32,
        era_code: u32,
        _: u32,
        out_connection_ctx: ?*?*anyopaque,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_OPEN_FATAL));
        const out = out_connection_ctx orelse return wire.MCP_OPEN_FATAL;
        out.* = null;
        _ = PublicMcpProbe.mcpVersion(era_code) orelse return wire.MCP_OPEN_FATAL;
        const connection = std.heap.c_allocator.create(Connection) catch
            return wire.MCP_OPEN_FATAL;
        connection.* = .{ .owner = self, .era_code = era_code };
        out.* = connection;
        return wire.MCP_OPEN_OK;
    }

    fn request(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        request_json: wire.BytesViewV1,
        _: u32,
        _: ?*const wire.McpCancellationV1,
        out_response: ?*wire.McpResponseV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_EXCHANGE_FATAL));
        const connection: *Connection = @ptrCast(@alignCast(connection_ctx orelse
            return wire.MCP_EXCHANGE_FATAL));
        if (connection.owner != self) return wire.MCP_EXCHANGE_FATAL;
        const out = out_response orelse return wire.MCP_EXCHANGE_FATAL;
        out.* = .{
            .struct_size = @sizeOf(wire.McpResponseV1),
            .http_status = 0,
            .body = .{ .ptr = null, .len = 0 },
            .reserved = [_]u64{0} ** 2,
        };
        const body = sdk.borrowedBytes(request_json) catch return wire.MCP_EXCHANGE_FATAL;
        const result = self.post(connection.era_code, body) catch
            return wire.MCP_EXCHANGE_NETWORK_ERROR;
        out.http_status = result.status;
        if (result.body.len == 0) {
            std.heap.c_allocator.free(result.body);
        } else {
            out.body = .{ .ptr = result.body.ptr, .len = result.body.len };
        }
        return wire.MCP_EXCHANGE_RESPONSE;
    }

    fn requestToolStream(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        request_json: wire.BytesViewV1,
        timeout_ms: u32,
        cancellation: ?*const wire.McpCancellationV1,
        sink: ?*const wire.HostResultSinkV1,
    ) callconv(.c) u32 {
        var response = wire.McpResponseV1{
            .struct_size = @sizeOf(wire.McpResponseV1),
            .http_status = 0,
            .body = .{ .ptr = null, .len = 0 },
            .reserved = [_]u64{0} ** 2,
        };
        const status = request(
            raw,
            connection_ctx,
            request_json,
            timeout_ms,
            cancellation,
            &response,
        );
        defer releaseResponse(raw, connection_ctx, &response.body);
        if (status != wire.MCP_EXCHANGE_RESPONSE) return status;
        if (response.http_status == 401 or response.http_status == 403)
            return wire.MCP_EXCHANGE_AUTH_ERROR;
        if (response.http_status < 200 or response.http_status >= 300)
            return wire.MCP_EXCHANGE_SERVER_ERROR;
        const destination = sink orelse return wire.MCP_EXCHANGE_FATAL;
        if (destination.struct_size != @sizeOf(wire.HostResultSinkV1) or
            destination.write == null or response.body.ptr == null)
            return wire.MCP_EXCHANGE_FATAL;
        const bytes = response.body.ptr.?[0..@intCast(response.body.len)];
        return if (destination.write.?(destination.ctx, sdk.bytesView(bytes)) == wire.HOST_SINK_OK)
            wire.MCP_EXCHANGE_RESPONSE
        else
            wire.MCP_EXCHANGE_FATAL;
    }

    fn notify(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        notification_json: wire.BytesViewV1,
        _: u32,
        _: ?*const wire.McpCancellationV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_NOTIFY_FAILED));
        const connection: *Connection = @ptrCast(@alignCast(connection_ctx orelse
            return wire.MCP_NOTIFY_FAILED));
        if (connection.owner != self) return wire.MCP_NOTIFY_FAILED;
        const body = sdk.borrowedBytes(notification_json) catch return wire.MCP_NOTIFY_FAILED;
        const result = self.post(connection.era_code, body) catch
            return wire.MCP_NOTIFY_FAILED;
        defer std.heap.c_allocator.free(result.body);
        return if (result.status >= 200 and result.status < 300)
            wire.MCP_NOTIFY_OK
        else
            wire.MCP_NOTIFY_FAILED;
    }

    fn post(self: *@This(), era_code: u32, body: []const u8) !HttpResult {
        var io_runtime = @import("platform").signal.threadedIo(std.heap.c_allocator, .{});
        defer io_runtime.deinit();
        var client = std.http.Client{
            .allocator = std.heap.c_allocator,
            .io = io_runtime.io(),
        };
        defer client.deinit();
        const uri = try std.Uri.parse(self.url);
        var request_value = try client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "application/json, text/event-stream" },
                .{
                    .name = "MCP-Protocol-Version",
                    .value = PublicMcpProbe.mcpVersion(era_code) orelse return error.InvalidEra,
                },
            },
        });
        defer request_value.deinit();
        try request_value.sendBodyComplete(@constCast(body));
        var redirect_buf: [4096]u8 = undefined;
        const response = try request_value.receiveHead(&redirect_buf);
        var transfer_buf: [8192]u8 = undefined;
        const reader = request_value.reader.bodyReader(
            &transfer_buf,
            response.head.transfer_encoding,
            response.head.content_length,
        );
        return .{
            .status = core.api_http_status.ResponseStatus.capture(&response).code,
            .body = try reader.allocRemaining(
                std.heap.c_allocator,
                std.Io.Limit.limited(1024 * 1024),
            ),
        };
    }

    fn close(raw: ?*anyopaque, connection_ctx: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const connection: *Connection = @ptrCast(@alignCast(connection_ctx orelse return));
        if (connection.owner != self) return;
        self.closes += 1;
        std.heap.c_allocator.destroy(connection);
    }

    fn releaseResponse(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        response: ?*wire.OwnedBytesV1,
    ) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const connection: *Connection = @ptrCast(@alignCast(connection_ctx orelse return));
        if (connection.owner != self) return;
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }
};

const PublicMcpToolErrorProbe = struct {
    saw_error: bool = false,
    preserved_content: bool = false,

    fn event(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch
            return wire.EVENT_FATAL;
        defer parsed.deinit();
        const event_value = switch (parsed.value) {
            .known => |known| known,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (event_value) {
            .tool_result => |result| {
                self.saw_error = result.is_error;
                self.preserved_content = std.mem.indexOf(
                    u8,
                    result.content,
                    "city must be string",
                ) != null;
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }
};

const PublicCheckpointBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    read_offset: usize = 0,
    writes: u32 = 0,
    reads: u32 = 0,
    fail_write: bool = false,
    fail_read: bool = false,

    fn deinit(self: *@This()) void {
        self.bytes.deinit(std.heap.c_allocator);
    }

    fn resetRead(self: *@This()) void {
        self.read_offset = 0;
        self.reads = 0;
    }

    fn sink(self: *@This()) wire.CheckpointSinkV1 {
        var result = std.mem.zeroes(wire.CheckpointSinkV1);
        result.struct_size = @sizeOf(wire.CheckpointSinkV1);
        result.ctx = self;
        result.write = write;
        return result;
    }

    fn source(self: *@This()) wire.CheckpointSourceV1 {
        self.resetRead();
        var result = std.mem.zeroes(wire.CheckpointSourceV1);
        result.struct_size = @sizeOf(wire.CheckpointSourceV1);
        result.ctx = self;
        result.read = read;
        return result;
    }

    fn write(raw: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.CHECKPOINT_IO_FATAL));
        if (self.fail_write) return wire.CHECKPOINT_IO_FAILED;
        const part = sdk.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL;
        self.bytes.appendSlice(std.heap.c_allocator, part) catch return wire.CHECKPOINT_IO_FATAL;
        self.writes += 1;
        return wire.CHECKPOINT_IO_OK;
    }

    fn read(
        raw: ?*anyopaque,
        destination: ?[*]u8,
        capacity_raw: u64,
        out_len: ?*u64,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.CHECKPOINT_IO_FATAL));
        const written = out_len orelse return wire.CHECKPOINT_IO_FATAL;
        written.* = 0;
        if (self.fail_read) return wire.CHECKPOINT_IO_FAILED;
        const capacity = std.math.cast(usize, capacity_raw) orelse return wire.CHECKPOINT_IO_FATAL;
        if (self.read_offset == self.bytes.items.len) return wire.CHECKPOINT_IO_OK;
        if (capacity == 0) return wire.CHECKPOINT_IO_FATAL;
        const out = destination orelse return wire.CHECKPOINT_IO_FATAL;
        const count = @min(capacity, self.bytes.items.len - self.read_offset);
        @memcpy(out[0..count], self.bytes.items[self.read_offset..][0..count]);
        self.read_offset += count;
        self.reads += 1;
        written.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

test "L2 Revision 9 hard-cut real HTTP Connector AUTO downgrades a bare 400 probe" {
    const bodies = [_][]const u8{
        "",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"http-test\",\"version\":\"1\"}}}",
        "",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"weather\",\"inputSchema\":{\"type\":\"object\"}}]}}",
    };
    const statuses = [_][]const u8{
        "HTTP/1.1 400 Bad Request",
        "HTTP/1.1 200 OK",
        "HTTP/1.1 202 Accepted",
        "HTTP/1.1 200 OK",
    };
    var http_server = try harness.MockServer.startHttpCassette(&bodies, &statuses);
    defer http_server.stop();
    const url = try http_server.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var connector = PublicHttpMcpConnector{ .url = url };

    var server = std.mem.zeroes(wire.McpServerV1);
    server.struct_size = @sizeOf(wire.McpServerV1);
    server.transport_code = wire.MCP_TRANSPORT_STREAMABLE_HTTP;
    server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
    server.server_binding_identity = [_]u8{0x71} ** 32;
    server.configuration_fingerprint = [_]u8{0x72} ** 32;
    server.namespace = sdk.bytesView("http_auto");
    server.client_name = sdk.bytesView("agentcore-hardcut-test");
    server.client_version = sdk.bytesView("9");
    server.timeout_ms = 5000;
    server.connector = connector.connector();
    const servers = [_]wire.McpServerV1{server};
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.mcp_servers = &servers;
    config.mcp_server_count = servers.len;

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    const create_status = api.runtime().create()(&config, null, &runtime, &diagnostic);
    if (create_status != wire.STATUS_OK) {
        const message = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "";
        std.debug.print("real HTTP MCP runtime_create failed: {s}\n", .{message});
    }
    try std.testing.expectEqual(wire.STATUS_OK, create_status);
    var generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().refresh()(runtime, &generation, &diagnostic),
    );
    try std.testing.expectEqual(@as(u64, 1), generation);

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().describe()(runtime, &description, &diagnostic),
    );
    const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();
    if (decoded.value.servers.len == 0)
        std.debug.print("real HTTP MCP catalog: {s}\n", .{encoded});
    try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
    try std.testing.expectEqualStrings(
        "2025-11-25",
        decoded.value.servers[0].negotiated_protocol,
    );
    try std.testing.expectEqual(@as(usize, 1), decoded.value.tools.len);
    api.bufferRelease()(&description);
    try std.testing.expectEqual(@as(usize, 4), http_server.requestCount());
    try std.testing.expectEqual(@as(u32, 2), connector.releases);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().destroy()(runtime, &diagnostic),
    );
    runtime = null;
    try std.testing.expectEqual(@as(u32, 2), connector.closes);
}

test "L2 Revision 9 hard-cut real HTTP Connector AUTO preserves a Modern server" {
    const discover =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"ttlMs\":1000,\"cacheScope\":\"private\"}}";
    const bodies = [_][]const u8{
        discover,
        discover,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"tools\":[{\"name\":\"weather\",\"inputSchema\":{\"type\":\"object\"}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}",
    };
    const statuses = [_][]const u8{
        "HTTP/1.1 200 OK",
        "HTTP/1.1 200 OK",
        "HTTP/1.1 200 OK",
    };
    var http_server = try harness.MockServer.startHttpCassette(&bodies, &statuses);
    defer http_server.stop();
    const url = try http_server.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var connector = PublicHttpMcpConnector{ .url = url };

    var server = std.mem.zeroes(wire.McpServerV1);
    server.struct_size = @sizeOf(wire.McpServerV1);
    server.transport_code = wire.MCP_TRANSPORT_STREAMABLE_HTTP;
    server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
    server.server_binding_identity = [_]u8{0x73} ** 32;
    server.configuration_fingerprint = [_]u8{0x74} ** 32;
    server.namespace = sdk.bytesView("http_modern");
    server.client_name = sdk.bytesView("agentcore-hardcut-test");
    server.client_version = sdk.bytesView("9");
    server.timeout_ms = 5000;
    server.connector = connector.connector();
    const servers = [_]wire.McpServerV1{server};
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.mcp_servers = &servers;
    config.mcp_server_count = servers.len;

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&config, null, &runtime, &diagnostic),
    );
    var generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().refresh()(runtime, &generation, &diagnostic),
    );

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().describe()(runtime, &description, &diagnostic),
    );
    const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
    try std.testing.expectEqualStrings(
        "2026-07-28",
        decoded.value.servers[0].negotiated_protocol,
    );
    try std.testing.expectEqual(@as(usize, 1), decoded.value.tools.len);
    api.bufferRelease()(&description);
    try std.testing.expectEqual(@as(usize, 3), http_server.requestCount());
    try std.testing.expectEqual(@as(u32, 3), connector.releases);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().destroy()(runtime, &diagnostic),
    );
    try std.testing.expectEqual(@as(u32, 2), connector.closes);
}

test "L2 Revision 7 public MCP exact 2025-06 and AUTO reopen reach one canonical catalog" {
    const cases = [_]struct {
        policy: u32,
        probe_opens: u32,
        actual_11_opens: u32,
        actual_06_opens: u32,
        closes_before_destroy: u32,
    }{
        .{
            .policy = wire.MCP_NEGOTIATION_LEGACY_2025_06_ONLY,
            .probe_opens = 0,
            .actual_11_opens = 0,
            .actual_06_opens = 1,
            .closes_before_destroy = 0,
        },
        .{
            .policy = wire.MCP_NEGOTIATION_AUTO,
            .probe_opens = 1,
            .actual_11_opens = 1,
            .actual_06_opens = 1,
            .closes_before_destroy = 2,
        },
    };
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));

    for (cases, 0..) |case, index| {
        var probe = PublicMcpProbe{ .server_era_code = wire.MCP_ERA_2025_06_18 };
        var server = std.mem.zeroes(wire.McpServerV1);
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = wire.MCP_TRANSPORT_STDIO;
        server.negotiation_policy_code = case.policy;
        server.server_binding_identity = [_]u8{@intCast(0x60 + index)} ** 32;
        server.configuration_fingerprint = server.server_binding_identity;
        server.namespace = sdk.bytesView(if (index == 0) "exact06" else "auto06");
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = probe.connector();
        const servers = [_]wire.McpServerV1{server};
        var config = std.mem.zeroes(wire.RuntimeConfigV1);
        config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        config.mcp_servers = &servers;
        config.mcp_server_count = servers.len;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        var runtime: ?*wire.RuntimeHandle = null;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtime().create()(&config, null, &runtime, &diagnostic),
        );
        defer api.bufferRelease()(&diagnostic);
        var generation: u64 = 0;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.mcp().refresh()(runtime, &generation, &diagnostic),
        );
        try std.testing.expectEqual(@as(u64, 1), generation);
        var description = std.mem.zeroes(wire.OwnedBytesV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.mcp().describe()(runtime, &description, &diagnostic),
        );
        const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
        const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.tools.len);
        try std.testing.expectEqualStrings(
            "2025-06-18",
            decoded.value.servers[0].negotiated_protocol,
        );
        api.bufferRelease()(&description);
        try std.testing.expectEqual(case.probe_opens, probe.probe_opens);
        try std.testing.expectEqual(case.actual_11_opens, probe.actual_2025_11_opens);
        try std.testing.expectEqual(case.actual_06_opens, probe.actual_2025_06_opens);
        try std.testing.expectEqual(
            @as(usize, @intCast(case.probe_opens + case.actual_11_opens + case.actual_06_opens)),
            probe.connection_count,
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            probe.notifications_by_era[wire.MCP_ERA_2025_11_25],
        );
        try std.testing.expectEqual(
            @as(u32, 1),
            probe.notifications_by_era[wire.MCP_ERA_2025_06_18],
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            probe.list_requests_by_era[wire.MCP_ERA_2025_11_25],
        );
        try std.testing.expectEqual(
            @as(u32, 1),
            probe.list_requests_by_era[wire.MCP_ERA_2025_06_18],
        );
        if (case.policy == wire.MCP_NEGOTIATION_AUTO) {
            try std.testing.expect(probe.connections[0].closed);
            try std.testing.expect(probe.connections[1].closed);
            try std.testing.expect(!probe.connections[2].closed);
            try std.testing.expectEqual(
                wire.MCP_CONNECTION_DISPOSABLE_PROBE,
                probe.connections[0].purpose_code,
            );
            try std.testing.expectEqual(
                wire.MCP_ERA_2025_11_25,
                probe.connections[1].era_code,
            );
            try std.testing.expectEqual(
                wire.MCP_ERA_2025_06_18,
                probe.connections[2].era_code,
            );
        }
        try std.testing.expectEqual(case.closes_before_destroy, probe.closes);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtime().destroy()(runtime, &diagnostic),
        );
        runtime = null;
        try probe.expectClosedExactlyOnce();
    }
}

test "L2 Revision 7 public MCP Apply publishes complete sets and replaces changed instances" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var first_probe = PublicMcpProbe{};
    var rejected_probe = PublicMcpProbe{ .server_era_code = wire.MCP_ERA_2025_11_25 };
    var second_probe = PublicMcpProbe{};
    var server = std.mem.zeroes(wire.McpServerV1);
    server.struct_size = @sizeOf(wire.McpServerV1);
    server.transport_code = wire.MCP_TRANSPORT_STDIO;
    server.negotiation_policy_code = wire.MCP_NEGOTIATION_MODERN_ONLY;
    server.server_binding_identity = [_]u8{0xd1} ** 32;
    server.configuration_fingerprint = [_]u8{0xa1} ** 32;
    server.namespace = sdk.bytesView("live");
    server.client_name = sdk.bytesView("agentcore-r7-test");
    server.client_version = sdk.bytesView("7");
    server.timeout_ms = 1000;
    server.connector = first_probe.connector();
    var servers = [_]wire.McpServerV1{server};

    var configuration = std.mem.zeroes(wire.McpConfigurationV1);
    configuration.struct_size = @sizeOf(wire.McpConfigurationV1);
    configuration.desired_revision = 1;
    configuration.servers = &servers;
    configuration.server_count = servers.len;
    var report = std.mem.zeroes(wire.McpApplyReportV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().applyConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(@as(u32, @sizeOf(wire.McpApplyReportV1)), report.struct_size);
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 1), report.desired_revision);
    try std.testing.expectEqual(@as(u64, 1), report.active_revision);
    try std.testing.expectEqual(@as(u64, 1), report.catalog_generation);
    try std.testing.expectEqual(@as(u32, 1), first_probe.actual_opens);

    configuration.desired_revision = 2;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().applyConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 1), report.catalog_generation);
    try std.testing.expectEqual(@as(u32, 1), first_probe.actual_opens);

    servers[0].configuration_fingerprint = [_]u8{0xaf} ** 32;
    servers[0].connector = rejected_probe.connector();
    configuration.desired_revision = 3;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().applyConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_REJECTED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 3), report.desired_revision);
    try std.testing.expectEqual(@as(u64, 2), report.active_revision);
    try std.testing.expectEqual(@as(u64, 1), report.catalog_generation);
    try std.testing.expectEqual(@as(u32, 0), first_probe.closes);
    try std.testing.expectEqual(@as(u32, 1), rejected_probe.actual_open_attempts);

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().describe()(runtime, &description, &diagnostic),
    );
    const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();
    api.bufferRelease()(&description);
    try std.testing.expectEqual(@as(u64, 1), decoded.value.catalog_generation);
    try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
    try std.testing.expectEqualStrings("live", decoded.value.servers[0].namespace);

    // A rejected revision remains retryable. Reusing revision 3 with a healthy
    // connector must replace the last-known-good generation atomically.
    servers[0].configuration_fingerprint = [_]u8{0xa2} ** 32;
    servers[0].connector = second_probe.connector();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().applyConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 2), report.catalog_generation);
    try std.testing.expectEqual(@as(u32, 1), second_probe.actual_opens);
    try first_probe.expectClosedExactlyOnce();

    configuration.desired_revision = 4;
    configuration.servers = null;
    configuration.server_count = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().applyConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 3), report.catalog_generation);
    try second_probe.expectClosedExactlyOnce();

    configuration.desired_revision = 3;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().applyConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_SUPERSEDED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 4), report.desired_revision);
    try std.testing.expectEqual(@as(u64, 4), report.active_revision);
    try std.testing.expectEqual(@as(u64, 3), report.catalog_generation);

    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
    try std.testing.expectEqual(first_probe.connector_retains, first_probe.connector_releases);
    try std.testing.expectEqual(rejected_probe.connector_retains, rejected_probe.connector_releases);
    try std.testing.expectEqual(second_probe.connector_retains, second_probe.connector_releases);
}

test "L2 Revision 7 public MCP Apply requires explicit instance identity and lifetime" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const invalid_contracts = [_]enum { zero_fingerprint, retain, release, tool_stream }{
        .zero_fingerprint,
        .retain,
        .release,
        .tool_stream,
    };
    for (invalid_contracts) |invalid| {
        var probe = PublicMcpProbe{};
        var server = std.mem.zeroes(wire.McpServerV1);
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = wire.MCP_TRANSPORT_STDIO;
        server.negotiation_policy_code = wire.MCP_NEGOTIATION_MODERN_ONLY;
        server.server_binding_identity = [_]u8{0xd2} ** 32;
        server.configuration_fingerprint = [_]u8{0xb1} ** 32;
        server.namespace = sdk.bytesView("lifetime");
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = probe.connector();
        switch (invalid) {
            .zero_fingerprint => server.configuration_fingerprint = [_]u8{0} ** 32,
            .retain => server.connector.retain_connector = null,
            .release => server.connector.release_connector = null,
            .tool_stream => server.connector.request_tool_stream = null,
        }
        var servers = [_]wire.McpServerV1{server};
        var configuration = std.mem.zeroes(wire.McpConfigurationV1);
        configuration.struct_size = @sizeOf(wire.McpConfigurationV1);
        configuration.desired_revision = 1;
        configuration.servers = &servers;
        configuration.server_count = servers.len;
        var report = std.mem.zeroes(wire.McpApplyReportV1);

        try std.testing.expectEqual(
            wire.STATUS_INVALID_ARGUMENT,
            api.mcp().applyConfiguration()(runtime, &configuration, &report, &diagnostic),
        );
        try std.testing.expectEqual(@as(u32, 0), probe.connector_retains);
        try std.testing.expectEqual(@as(u32, 0), probe.connector_releases);
        try std.testing.expectEqual(@as(u32, 0), probe.open_attempts);
        api.bufferRelease()(&diagnostic);
    }
}

test "L2 public MCP wire failures preserve downgrade and no-replay semantics" {
    const cases = [_]struct {
        transport: u32,
        probe_open_status: u32 = wire.MCP_OPEN_OK,
        probe_exchange_status: ?u32 = null,
        notify_status: u32 = wire.MCP_NOTIFY_OK,
        expected_servers: usize,
        expected_issue: ?[]const u8,
        expected_actual_attempts: u32,
        expected_request_attempts: u32,
        expected_tools: usize = 0,
        expected_protocol: ?[]const u8 = null,
    }{
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_open_status = wire.MCP_OPEN_TIMEOUT,
            .expected_servers = 1,
            .expected_issue = null,
            .expected_actual_attempts = 1,
            .expected_request_attempts = 2,
            .expected_tools = 1,
            .expected_protocol = "2025-11-25",
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_open_status = wire.MCP_OPEN_CHILD_EXIT,
            .expected_servers = 1,
            .expected_issue = null,
            .expected_actual_attempts = 1,
            .expected_request_attempts = 2,
            .expected_tools = 1,
            .expected_protocol = "2025-11-25",
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_open_status = wire.MCP_OPEN_NETWORK_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 0,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_open_status = wire.MCP_OPEN_AUTH_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 0,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_open_status = wire.MCP_OPEN_SERVER_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 0,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_exchange_status = wire.MCP_EXCHANGE_TIMEOUT,
            .expected_servers = 1,
            .expected_issue = null,
            .expected_actual_attempts = 1,
            .expected_request_attempts = 3,
            .expected_tools = 1,
            .expected_protocol = "2025-11-25",
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_exchange_status = wire.MCP_EXCHANGE_CHILD_EXIT,
            .expected_servers = 1,
            .expected_issue = null,
            .expected_actual_attempts = 1,
            .expected_request_attempts = 3,
            .expected_tools = 1,
            .expected_protocol = "2025-11-25",
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .notify_status = wire.MCP_NOTIFY_FAILED,
            .expected_servers = 0,
            .expected_issue = "connection_failed",
            .expected_actual_attempts = 1,
            .expected_request_attempts = 2,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_exchange_status = wire.MCP_EXCHANGE_NETWORK_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_exchange_status = wire.MCP_EXCHANGE_AUTH_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_exchange_status = wire.MCP_EXCHANGE_SERVER_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_exchange_status = wire.MCP_EXCHANGE_CANCELLED,
            .expected_servers = 0,
            .expected_issue = "probe_failed",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_exchange_status = wire.MCP_EXCHANGE_INDETERMINATE,
            .expected_servers = 0,
            .expected_issue = "probe_failed",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
    };
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));

    for (cases, 0..) |case, index| {
        var probe = PublicMcpProbe{
            .server_era_code = wire.MCP_ERA_2025_11_25,
            .probe_open_status = case.probe_open_status,
            .probe_exchange_status = case.probe_exchange_status,
            .notify_status = case.notify_status,
        };
        var server = std.mem.zeroes(wire.McpServerV1);
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = case.transport;
        server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
        server.server_binding_identity = [_]u8{@intCast(0x79 + index)} ** 32;
        server.configuration_fingerprint = server.server_binding_identity;
        server.namespace = sdk.bytesView("failure");
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = probe.connector();
        const servers = [_]wire.McpServerV1{server};
        var config = std.mem.zeroes(wire.RuntimeConfigV1);
        config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        config.mcp_servers = &servers;
        config.mcp_server_count = servers.len;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        defer api.bufferRelease()(&diagnostic);
        var runtime: ?*wire.RuntimeHandle = null;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtime().create()(&config, null, &runtime, &diagnostic),
        );
        var generation: u64 = 0;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.mcp().refresh()(runtime, &generation, &diagnostic),
        );
        var description = std.mem.zeroes(wire.OwnedBytesV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.mcp().describe()(runtime, &description, &diagnostic),
        );
        const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
        const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(case.expected_servers, decoded.value.servers.len);
        try std.testing.expectEqual(case.expected_tools, decoded.value.tools.len);
        if (case.expected_protocol) |expected| try std.testing.expectEqualStrings(
            expected,
            decoded.value.servers[0].negotiated_protocol,
        );
        if (case.expected_issue) |expected| {
            try std.testing.expectEqual(@as(usize, 1), decoded.value.issues.len);
            try std.testing.expectEqualStrings(expected, decoded.value.issues[0].kind);
        } else {
            try std.testing.expectEqual(@as(usize, 0), decoded.value.issues.len);
        }
        api.bufferRelease()(&description);
        try std.testing.expectEqual(@as(u32, 1), probe.probe_open_attempts);
        try std.testing.expectEqual(case.expected_actual_attempts, probe.actual_open_attempts);
        try std.testing.expectEqual(case.expected_request_attempts, probe.request_attempts);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtime().destroy()(runtime, &diagnostic),
        );
        runtime = null;
        try probe.expectClosedExactlyOnce();
    }
}

test "L2 MCP admits primary and other string dialects and projects all Tools" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var provider = try harness.MockServer.start(FINAL_SSE, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var probe = PublicMcpProbe{ .dialect_matrix = true };
    var server = std.mem.zeroes(wire.McpServerV1);
    server.struct_size = @sizeOf(wire.McpServerV1);
    server.transport_code = wire.MCP_TRANSPORT_STDIO;
    server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
    server.server_binding_identity = [_]u8{0x6d} ** 32;
    server.configuration_fingerprint = server.server_binding_identity;
    server.namespace = sdk.bytesView("dialects");
    server.client_name = sdk.bytesView("agentcore-component-test");
    server.client_version = sdk.bytesView("9");
    server.timeout_ms = 1000;
    server.connector = probe.connector();
    const servers = [_]wire.McpServerV1{server};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.mcp_servers = &servers;
    runtime_config.mcp_server_count = servers.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var session: ?*wire.SessionHandle = null;
    defer {
        if (session) |handle| {
            _ = api.session().destroy()(handle, &diagnostic);
            session = null;
            api.bufferRelease()(&diagnostic);
        }
        if (runtime) |handle| {
            _ = api.runtime().destroy()(handle, &diagnostic);
            runtime = null;
            api.bufferRelease()(&diagnostic);
        }
    }
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    var generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().refresh()(runtime, &generation, &diagnostic),
    );

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&description);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().describe()(runtime, &description, &diagnostic),
    );
    const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    const decoded = try sdk.decodeMcpCatalog(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 4), decoded.value.tools.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.value.issues.len);
    var saw_implicit = false;
    var saw_modern = false;
    var saw_draft7 = false;
    var saw_custom = false;
    for (decoded.value.tools) |tool| {
        if (std.mem.eql(u8, tool.canonical_name, "implicit")) saw_implicit = true;
        if (std.mem.eql(u8, tool.canonical_name, "modern")) saw_modern = true;
        if (std.mem.eql(u8, tool.canonical_name, "draft7")) saw_draft7 = true;
        if (std.mem.eql(u8, tool.canonical_name, "custom")) saw_custom = true;
    }
    try std.testing.expect(saw_implicit and saw_modern and saw_draft7 and saw_custom);

    var selectors = [_]wire.McpSelectorV1{
        std.mem.zeroes(wire.McpSelectorV1),
        std.mem.zeroes(wire.McpSelectorV1),
        std.mem.zeroes(wire.McpSelectorV1),
        std.mem.zeroes(wire.McpSelectorV1),
    };
    const names = [_][]const u8{ "implicit", "modern", "draft7", "custom" };
    for (&selectors, names) |*selector, name| {
        selector.struct_size = @sizeOf(wire.McpSelectorV1);
        selector.server_binding_identity = server.server_binding_identity;
        selector.tool_name = sdk.bytesView(name);
    }
    var selection = std.mem.zeroes(wire.McpSelectionV1);
    selection.struct_size = @sizeOf(wire.McpSelectionV1);
    selection.selectors = &selectors;
    selection.selector_count = selectors.len;
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.mcp_selection = &selection;
    var create_config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("inspect available MCP Tools"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    const request = provider.requestAt(0) orelse return error.NoRequestCaptured;
    for ([_][]const u8{ "implicit_arg", "modern_arg", "draft7_arg", "custom_arg" }) |property|
        try std.testing.expect(std.mem.indexOf(u8, request.body(), property) != null);
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "\"$schema\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "draft-07") == null);
}

test "L2 MCP server schema Tool error crosses Session and ABI intact" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var provider_bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var provider = try harness.MockServer.startCassette(&provider_bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var mcp_probe = PublicMcpProbe{ .business_error = true };
    var mcp_server = std.mem.zeroes(wire.McpServerV1);
    mcp_server.struct_size = @sizeOf(wire.McpServerV1);
    mcp_server.transport_code = wire.MCP_TRANSPORT_STDIO;
    mcp_server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
    mcp_server.server_binding_identity = [_]u8{0x73} ** 32;
    mcp_server.configuration_fingerprint = mcp_server.server_binding_identity;
    mcp_server.namespace = sdk.bytesView("schemaerror");
    mcp_server.client_name = sdk.bytesView("agentcore-component-test");
    mcp_server.client_version = sdk.bytesView("9");
    mcp_server.timeout_ms = 1000;
    mcp_server.connector = mcp_probe.connector();
    const servers = [_]wire.McpServerV1{mcp_server};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.mcp_servers = &servers;
    runtime_config.mcp_server_count = servers.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var session: ?*wire.SessionHandle = null;
    defer {
        if (session) |handle| {
            _ = api.session().destroy()(handle, &diagnostic);
            session = null;
            api.bufferRelease()(&diagnostic);
        }
        if (runtime) |handle| {
            _ = api.runtime().destroy()(handle, &diagnostic);
            runtime = null;
            api.bufferRelease()(&diagnostic);
        }
    }
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    var generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().refresh()(runtime, &generation, &diagnostic),
    );

    var selector = std.mem.zeroes(wire.McpSelectorV1);
    selector.struct_size = @sizeOf(wire.McpSelectorV1);
    selector.server_binding_identity = mcp_server.server_binding_identity;
    selector.tool_name = sdk.bytesView("weather");
    const selectors = [_]wire.McpSelectorV1{selector};
    var selection = std.mem.zeroes(wire.McpSelectionV1);
    selection.struct_size = @sizeOf(wire.McpSelectionV1);
    selection.selectors = &selectors;
    selection.selector_count = selectors.len;
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.mcp_selection = &selection;
    var create_config = sessionCreateConfig(&host, "test-model");
    var event_probe = PublicMcpToolErrorProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &event_probe;
    callbacks.on_event = PublicMcpToolErrorProbe.event;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );

    var session_description = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&session_description);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().describe()(session, &session_description, &diagnostic),
    );
    const encoded_description = try sdk.borrowedBytes(.{
        .ptr = session_description.ptr,
        .len = session_description.len,
    });
    const decoded_description = try sdk.decodeSessionDescription(a, encoded_description);
    defer decoded_description.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded_description.value.mcp.tools.len);
    const model_name = decoded_description.value.mcp.tools[0].model_name;
    const tool_sse = try std.fmt.allocPrint(
        a,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_mcp_error\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_mcp_error\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"city\\\":7}}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{model_name},
    );
    defer a.free(tool_sse);
    provider_bodies[0] = tool_sse;

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 2;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("call the MCP weather Tool"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    try std.testing.expectEqual(@as(u32, 1), mcp_probe.call_requests);
    try std.testing.expect(mcp_probe.saw_schema_mismatch_arguments);
    try std.testing.expect(event_probe.saw_error);
    try std.testing.expect(event_probe.preserved_content);
}

test "L2 Revision 12 public MCP connector streams 17MiB response into recoverable artifact" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var provider_bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var provider = try harness.MockServer.startCassette(&provider_bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var mcp_probe = PublicMcpProbe{ .successful_call_padding_bytes = 17 * 1024 * 1024 + 31 };
    var mcp_server = std.mem.zeroes(wire.McpServerV1);
    mcp_server.struct_size = @sizeOf(wire.McpServerV1);
    mcp_server.transport_code = wire.MCP_TRANSPORT_STDIO;
    mcp_server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
    mcp_server.server_binding_identity = [_]u8{0x74} ** 32;
    mcp_server.configuration_fingerprint = mcp_server.server_binding_identity;
    mcp_server.namespace = sdk.bytesView("streammcp");
    mcp_server.client_name = sdk.bytesView("agentcore-component-test");
    mcp_server.client_version = sdk.bytesView("12");
    mcp_server.timeout_ms = 1000;
    mcp_server.connector = mcp_probe.connector();
    const servers = [_]wire.McpServerV1{mcp_server};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.mcp_servers = &servers;
    runtime_config.mcp_server_count = servers.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var session: ?*wire.SessionHandle = null;
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    var generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().refresh()(runtime, &generation, &diagnostic),
    );

    var selector = std.mem.zeroes(wire.McpSelectorV1);
    selector.struct_size = @sizeOf(wire.McpSelectorV1);
    selector.server_binding_identity = mcp_server.server_binding_identity;
    selector.tool_name = sdk.bytesView("weather");
    const selectors = [_]wire.McpSelectorV1{selector};
    var selection = std.mem.zeroes(wire.McpSelectionV1);
    selection.struct_size = @sizeOf(wire.McpSelectionV1);
    selection.selectors = &selectors;
    selection.selector_count = selectors.len;
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.mcp_selection = &selection;
    var create_config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&description);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().describe()(session, &description, &diagnostic),
    );
    const decoded = try sdk.decodeSessionDescription(a, try sdk.borrowedBytes(.{
        .ptr = description.ptr,
        .len = description.len,
    }));
    defer decoded.deinit();
    const model_name = decoded.value.mcp.tools[0].model_name;
    const tool_sse = try std.fmt.allocPrint(
        a,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_mcp_stream\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_mcp_stream\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"city\\\":\\\"Paris\\\"}}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{model_name},
    );
    defer a.free(tool_sse);
    provider_bodies[0] = tool_sse;
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 2;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(
        session,
        1,
        sdk.bytesView("call the streamed MCP weather Tool"),
        &options,
        &result,
        &diagnostic,
    ));
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    try std.testing.expectEqual(@as(u32, 1), mcp_probe.call_requests);
    const request = provider.lastRequest() orelse return error.NoRequestCaptured;
    const body = request.body();
    try std.testing.expect(body.len < 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, body, core.tool_result.PROJECTION_SCHEMA) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ReadArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jsonrpc") == null);
}

test "L2 public MCP catalog preserves heterogeneous multi-server tool windows" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));

    var first_probe = PublicMcpProbe{ .tool_count = 2 };
    var second_probe = PublicMcpProbe{ .tool_count = 1 };
    const bindings = [_][32]u8{
        [_]u8{0x83} ** 32,
        [_]u8{0x84} ** 32,
    };
    const namespaces = [_][]const u8{ "single", "double" };
    var servers = [_]wire.McpServerV1{
        std.mem.zeroes(wire.McpServerV1),
        std.mem.zeroes(wire.McpServerV1),
    };
    const connectors = [_]wire.McpConnectorV1{
        first_probe.connector(),
        second_probe.connector(),
    };
    for (&servers, 0..) |*server, index| {
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = wire.MCP_TRANSPORT_STDIO;
        server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
        server.server_binding_identity = bindings[index];
        server.configuration_fingerprint = server.server_binding_identity;
        server.namespace = sdk.bytesView(namespaces[index]);
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = connectors[index];
    }
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.mcp_servers = &servers;
    config.mcp_server_count = servers.len;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&config, null, &runtime, &diagnostic),
    );
    var generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().refresh()(runtime, &generation, &diagnostic),
    );
    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().describe()(runtime, &description, &diagnostic),
    );
    const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();
    api.bufferRelease()(&description);

    try std.testing.expectEqual(@as(usize, 2), decoded.value.servers.len);
    try std.testing.expectEqual(@as(usize, 3), decoded.value.tools.len);
    const expected_counts = [_]u32{ 2, 1 };
    var next_tool_offset: u32 = 0;
    for (decoded.value.servers, expected_counts, 0..) |server, expected_count, index| {
        try std.testing.expectEqual(next_tool_offset, server.tool_offset);
        try std.testing.expectEqual(expected_count, server.tool_count);
        try std.testing.expectEqualStrings(namespaces[index], server.namespace);
        try std.testing.expectEqual(@as(usize, 64), server.server_binding_identity.len);
        const start: usize = @intCast(server.tool_offset);
        const end: usize = @intCast(server.tool_offset + server.tool_count);
        for (decoded.value.tools[start..end]) |tool| try std.testing.expectEqualSlices(
            u8,
            server.server_binding_identity,
            tool.server_binding_identity,
        );
        next_tool_offset += server.tool_count;
    }
    try std.testing.expectEqual(@as(u32, 3), next_tool_offset);

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().destroy()(runtime, &diagnostic),
    );
    runtime = null;
    try first_probe.expectClosedExactlyOnce();
    try second_probe.expectClosedExactlyOnce();
}

test "L2 Revision 7 MCP no-tools and required-task peers expose zero executable tools" {
    const cases = [_]struct {
        era: u32,
        policy: u32,
        advertise_tools: bool,
        required_task: bool,
        expected_list_requests: u32,
        expected_issues: usize,
        expected_protocol: []const u8,
    }{
        .{
            .era = wire.MCP_ERA_2025_11_25,
            .policy = wire.MCP_NEGOTIATION_LEGACY_ONLY,
            .advertise_tools = false,
            .required_task = false,
            .expected_list_requests = 0,
            .expected_issues = 0,
            .expected_protocol = "2025-11-25",
        },
        .{
            .era = wire.MCP_ERA_2026_07_28,
            .policy = wire.MCP_NEGOTIATION_AUTO,
            .advertise_tools = true,
            .required_task = true,
            .expected_list_requests = 1,
            .expected_issues = 1,
            .expected_protocol = "2026-07-28",
        },
    };
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    for (cases, 0..) |case, index| {
        var probe = PublicMcpProbe{
            .server_era_code = case.era,
            .advertise_tools = case.advertise_tools,
            .required_task = case.required_task,
        };
        var server = std.mem.zeroes(wire.McpServerV1);
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = wire.MCP_TRANSPORT_STDIO;
        server.negotiation_policy_code = case.policy;
        server.server_binding_identity = [_]u8{@intCast(0x70 + index)} ** 32;
        server.configuration_fingerprint = server.server_binding_identity;
        server.namespace = sdk.bytesView(if (index == 0) "notools" else "required");
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = probe.connector();
        const servers = [_]wire.McpServerV1{server};
        var config = std.mem.zeroes(wire.RuntimeConfigV1);
        config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        config.mcp_servers = &servers;
        config.mcp_server_count = servers.len;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        defer api.bufferRelease()(&diagnostic);
        var runtime: ?*wire.RuntimeHandle = null;
        try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&config, null, &runtime, &diagnostic));
        var generation: u64 = 0;
        try std.testing.expectEqual(wire.STATUS_OK, api.mcp().refresh()(runtime, &generation, &diagnostic));
        var description = std.mem.zeroes(wire.OwnedBytesV1);
        try std.testing.expectEqual(wire.STATUS_OK, api.mcp().describe()(runtime, &description, &diagnostic));
        const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
        const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
        try std.testing.expectEqualStrings(
            case.expected_protocol,
            decoded.value.servers[0].negotiated_protocol,
        );
        try std.testing.expectEqual(@as(usize, 0), decoded.value.tools.len);
        try std.testing.expectEqual(case.expected_issues, decoded.value.issues.len);
        if (case.required_task) try std.testing.expectEqualStrings(
            "task_required_unsupported",
            decoded.value.issues[0].kind,
        );
        try std.testing.expectEqual(case.expected_list_requests, probe.list_requests);
        try std.testing.expectEqual(@as(u32, 0), probe.call_requests);
        api.bufferRelease()(&description);
        try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
        runtime = null;
        try probe.expectClosedExactlyOnce();
    }
}

const PublicPermissionProbe = struct {
    expected_session: ?*wire.SessionHandle = null,
    expected_run_id: u64 = 1,
    fatal_on_permission: bool = false,
    ui_calls: u32 = 0,
    ui_releases: u32 = 0,
    host_calls: u32 = 0,
    host_releases: u32 = 0,
    callback_provenance: u32 = 0,
    raw_arguments_leaked: bool = false,

    fn validRun(self: *@This(), run_ptr: ?*const wire.RunContextV1) bool {
        const run = sdk.validateRunContext(run_ptr) catch return false;
        return run.session == self.expected_session and
            run.run_id == self.expected_run_id and
            run.session_id.len == 24;
    }

    fn event(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        if (!self.validRun(run_ptr)) return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const event_value = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (event_value) {
            .permission_provenance => |provenance| {
                if (self.fatal_on_permission) return wire.EVENT_FATAL;
                if (std.mem.indexOf(u8, encoded, "hello") != null) {
                    self.raw_arguments_leaked = true;
                    return wire.EVENT_FATAL;
                }
                if (provenance.source == .callback) {
                    if (provenance.decision != .allow or
                        provenance.callback_outcome != .answered or
                        provenance.response != .allow_once or
                        provenance.request_id == null or
                        provenance.tool.namespace != .host or
                        !std.mem.eql(u8, provenance.tool.name, "HostEcho") or
                        provenance.used_session_rule)
                        return wire.EVENT_FATAL;
                    self.callback_provenance += 1;
                }
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        if (!self.validRun(run_ptr)) return wire.UI_FATAL;
        const encoded = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const request = switch (parsed.value) {
            .permission => |value| value,
            else => return wire.UI_FATAL,
        };
        if (!std.mem.eql(u8, request.type, "permission") or
            request.run_id != 1 or
            request.policy_generation != 1 or
            request.tool.namespace != .host or
            !std.mem.eql(u8, request.tool.name, "HostEcho") or
            std.mem.indexOf(u8, request.arguments_json, "hello") == null or
            request.candidate != null)
            return wire.UI_FATAL;
        var permits_once = false;
        for (request.responses) |choice| {
            if (choice == .allow_once) permits_once = true;
            if (choice == .allow_session or choice == .deny_session)
                return wire.UI_FATAL;
        }
        if (!permits_once) return wire.UI_FATAL;
        const response = sdk.protocol.PermissionResponse{
            .permission = .allow_once,
            .request_id = request.request_id,
            .policy_generation = request.policy_generation,
        };
        const response_json = sdk.encodeUiResponse(
            std.heap.c_allocator,
            parsed.value,
            .{ .permission = response },
        ) catch return wire.UI_FATAL;
        const out = out_response orelse {
            std.heap.c_allocator.free(response_json);
            return wire.UI_FATAL;
        };
        out.* = .{ .ptr = response_json.ptr, .len = response_json.len };
        self.ui_calls += 1;
        return wire.UI_ANSWERED;
    }

    fn releaseUi(raw: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.ui_releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }

    fn host(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        arguments_json: wire.BytesViewV1,
        out_result: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
        if (!self.validRun(run_ptr)) return wire.HOST_FATAL;
        const arguments = sdk.borrowedBytes(arguments_json) catch return wire.HOST_FATAL;
        if (std.mem.indexOf(u8, arguments, "hello") == null) return wire.HOST_FAILED;
        const result = "host-ok";
        (out_result orelse return wire.HOST_FATAL).* = .{
            .ptr = @constCast(result.ptr),
            .len = result.len,
        };
        self.host_calls += 1;
        return wire.HOST_OK;
    }

    fn releaseHost(raw: ?*anyopaque, result: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        if (result) |out| {
            if (out.ptr != null) self.host_releases += 1;
            out.* = .{ .ptr = null, .len = 0 };
        }
    }
};

fn publicCheckpointLimits() wire.CheckpointLimitsV1 {
    var limits = std.mem.zeroes(wire.CheckpointLimitsV1);
    limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    limits.hard_bytes = 16 * 1024 * 1024;
    limits.max_section_bytes = 8 * 1024 * 1024;
    limits.max_string_bytes = 1024 * 1024;
    limits.max_messages = 1024;
    limits.max_blocks_per_message = 64;
    limits.chunk_bytes = 4096;
    return limits;
}

test "L2 SDK rejects API tables that violate rigid v1 discovery" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const actual: *const wire.ApiV1 = @ptrCast(@alignCast(raw_api));
    _ = try sdk.Api.validate(actual);

    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(null));

    const misaligned_root: *const anyopaque = @ptrFromInt(@intFromPtr(actual) + 1);
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(misaligned_root));

    var wrong_size = actual.*;
    wrong_size.struct_size -= 8;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&wrong_size));

    var wrong_version = actual.*;
    wrong_version.abi_version += 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&wrong_version));

    var wrong_revision = actual.*;
    wrong_revision.abi_revision = wire.ABI_REVISION - 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&wrong_revision));

    var nonzero_header_reserved = actual.*;
    nonzero_header_reserved.reserved0 = 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&nonzero_header_reserved));

    var missing_release = actual.*;
    missing_release.buffer_release = null;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&missing_release));

    inline for (.{ "runtime", "session", "session_control", "skill", "mcp" }) |field_name| {
        var missing_subtable = actual.*;
        @field(missing_subtable, field_name) = null;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&missing_subtable));
    }

    inline for (std.meta.fields(wire.RuntimeApiV1)[2..]) |field| {
        var child = actual.runtime.?.*;
        @field(child, field.name) = null;
        var root = actual.*;
        root.runtime = &child;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&root));
    }
    inline for (std.meta.fields(wire.SessionApiV1)[2..]) |field| {
        var child = actual.session.?.*;
        @field(child, field.name) = null;
        var root = actual.*;
        root.session = &child;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&root));
    }
    inline for (std.meta.fields(wire.SessionControlApiV1)[2..]) |field| {
        var child = actual.session_control.?.*;
        @field(child, field.name) = null;
        var root = actual.*;
        root.session_control = &child;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&root));
    }
    inline for (std.meta.fields(wire.SkillApiV1)[2..]) |field| {
        var child = actual.skill.?.*;
        @field(child, field.name) = null;
        var root = actual.*;
        root.skill = &child;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&root));
    }
    inline for (std.meta.fields(wire.McpApiV1)[2..]) |field| {
        var child = actual.mcp.?.*;
        @field(child, field.name) = null;
        var root = actual.*;
        root.mcp = &child;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&root));
    }

    inline for (.{
        .{ "runtime", wire.RuntimeApiV1 },
        .{ "session", wire.SessionApiV1 },
        .{ "session_control", wire.SessionControlApiV1 },
        .{ "skill", wire.SkillApiV1 },
        .{ "mcp", wire.McpApiV1 },
    }) |entry| {
        const field_name = entry[0];
        const Child = entry[1];
        var child: Child = @field(actual, field_name).?.*;
        child.struct_size -= 8;
        var root = actual.*;
        @field(root, field_name) = &child;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&root));

        child = @field(actual, field_name).?.*;
        child.reserved0 = 1;
        @field(root, field_name) = &child;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&root));

        var encoded_root: [@sizeOf(wire.ApiV1)]u8 align(@alignOf(wire.ApiV1)) =
            std.mem.toBytes(actual.*);
        const invalid_address = @intFromPtr(@field(actual.*, field_name).?) + 1;
        const pointer_offset = @offsetOf(wire.ApiV1, field_name);
        @memcpy(
            encoded_root[pointer_offset..][0..@sizeOf(usize)],
            std.mem.asBytes(&invalid_address),
        );
        const misaligned_child_root: *const wire.ApiV1 = @ptrCast(&encoded_root);
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(misaligned_child_root));
    }

    const api = try sdk.Api.validate(actual);
    try std.testing.expect(api.bufferRelease() == actual.buffer_release.?);
    try std.testing.expect(api.runtime().create() == actual.runtime.?.create.?);
    try std.testing.expect(api.runtime().destroy() == actual.runtime.?.destroy.?);
    try std.testing.expect(api.session().create() == actual.session.?.create.?);
    try std.testing.expect(api.session().destroy() == actual.session.?.destroy.?);
    try std.testing.expect(api.session().runInput() == actual.session.?.run_input.?);
    try std.testing.expect(api.session().abort() == actual.session.?.abort.?);
    try std.testing.expect(api.sessionControl().restore() == actual.session_control.?.restore.?);
    try std.testing.expect(api.sessionControl().describe() == actual.session_control.?.describe.?);
    try std.testing.expect(api.sessionControl().setModel() == actual.session_control.?.set_model.?);
    try std.testing.expect(api.sessionControl().updatePermissionRules() == actual.session_control.?.update_permission_rules.?);
    try std.testing.expect(api.sessionControl().compact() == actual.session_control.?.compact.?);
    try std.testing.expect(api.sessionControl().abortCompact() == actual.session_control.?.abort_compact.?);
    try std.testing.expect(api.sessionControl().exportCheckpoint() == actual.session_control.?.export_checkpoint.?);
    try std.testing.expect(api.skill().resolveCatalog() == actual.skill.?.resolve_catalog.?);
    try std.testing.expect(api.skill().releaseCatalog() == actual.skill.?.release_catalog.?);
    try std.testing.expect(api.skill().bindPolicy() == actual.skill.?.bind_policy.?);
    try std.testing.expect(api.mcp().applyConfiguration() == actual.mcp.?.apply_configuration.?);
    try std.testing.expect(api.mcp().refresh() == actual.mcp.?.refresh.?);
    try std.testing.expect(api.mcp().describe() == actual.mcp.?.describe.?);
    try std.testing.expect(api.mcp().updateSelection() == actual.mcp.?.update_selection.?);
}

test "L2 Revision 7 public mutations and compact use the exact hard-cut table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const initial_allow = [_]wire.BytesViewV1{sdk.bytesView("Read(*)")};
    var initial_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    initial_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    initial_rules.allow = &initial_allow;
    initial_rules.allow_count = initial_allow.len;
    var selection = skillPolicy(&.{});
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.skill_policy = &selection;
    host_config.permission_rules = &initial_rules;
    var config = sessionCreateConfig(&host_config, "old-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.session().create()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);

    host_config.skill_policy = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionControl().setModel()(session, sdk.bytesView(""), &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().setModel()(session, sdk.bytesView("new-model"), &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_INVALID_STATE,
        api.skill().bindPolicy()(session, null, &selection, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.skill().bindPolicy()(session, null, null, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var empty_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    empty_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().updatePermissionRules()(session, &empty_rules, &diagnostic),
    );
    const malformed_rule = [_]wire.BytesViewV1{sdk.bytesView("Bash(")};
    var malformed_rules = empty_rules;
    malformed_rules.allow = &malformed_rule;
    malformed_rules.allow_count = malformed_rule.len;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionControl().updatePermissionRules()(session, &malformed_rules, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionControl().compact()(session, 0, &compact_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().compact()(session, 1, &compact_result, &diagnostic),
    );
    try std.testing.expectEqual(
        @as(u32, @sizeOf(wire.CompactResultV1)),
        compact_result.struct_size,
    );
    try std.testing.expectEqual(wire.COMPACT_NO_CHANGE, compact_result.outcome_code);
    try std.testing.expectEqual(
        wire.STATUS_STALE_COMPACT,
        api.sessionControl().compact()(session, 1, &compact_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_TOO_LATE,
        api.sessionControl().abortCompact()(session, 1, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionControl().abortCompact()(session, 0, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionControl().abortCompact()(session, 2, &diagnostic),
    );
}

test "L2 public MCP checkpoint restore facade preserves Conversation under narrower current authority" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    const provider_bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var provider = try harness.MockServer.startCassette(&provider_bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var mcp_probe = PublicMcpProbe{};
    var mcp_server = std.mem.zeroes(wire.McpServerV1);
    mcp_server.struct_size = @sizeOf(wire.McpServerV1);
    mcp_server.transport_code = wire.MCP_TRANSPORT_STDIO;
    mcp_server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
    mcp_server.server_binding_identity = [_]u8{0x42} ** 32;
    mcp_server.configuration_fingerprint = mcp_server.server_binding_identity;
    mcp_server.namespace = sdk.bytesView("weather");
    mcp_server.client_name = sdk.bytesView("agentcore-component-test");
    mcp_server.client_version = sdk.bytesView("6");
    mcp_server.timeout_ms = 1000;
    mcp_server.connector = mcp_probe.connector();
    const mcp_servers = [_]wire.McpServerV1{mcp_server};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.mcp_servers = &mcp_servers;
    runtime_config.mcp_server_count = mcp_servers.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var session: ?*wire.SessionHandle = null;
    defer {
        if (session) |handle| {
            _ = api.session().destroy()(handle, &diagnostic);
            session = null;
            api.bufferRelease()(&diagnostic);
        }
        if (runtime) |handle| {
            _ = api.runtime().destroy()(handle, &diagnostic);
            runtime = null;
            api.bufferRelease()(&diagnostic);
        }
    }
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );

    var mcp_description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_MCP_NOT_REFRESHED,
        api.mcp().describe()(runtime, &mcp_description, &diagnostic),
    );
    try std.testing.expect(mcp_description.ptr == null and mcp_description.len == 0);
    api.bufferRelease()(&diagnostic);

    var catalog_generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().refresh()(runtime, &catalog_generation, &diagnostic),
    );
    try std.testing.expectEqual(@as(u64, 1), catalog_generation);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().describe()(runtime, &mcp_description, &diagnostic),
    );
    var catalog_binding: [64]u8 = undefined;
    var catalog_binding_len: usize = 0;
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = mcp_description.ptr,
            .len = mcp_description.len,
        });
        const decoded = try sdk.decodeMcpCatalog(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(u64, 1), decoded.value.catalog_generation);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.tools.len);
        try std.testing.expectEqualStrings("2026-07-28", decoded.value.servers[0].negotiated_protocol);
        try std.testing.expectEqualStrings("private", decoded.value.servers[0].cache_scope);
        try std.testing.expect(decoded.value.servers[0].fresh);
        try std.testing.expect(decoded.value.servers[0].ttl_remaining_ms <= 1000);
        try std.testing.expectEqualStrings("weather", decoded.value.tools[0].canonical_name);
        try std.testing.expectEqualStrings(
            decoded.value.servers[0].server_binding_identity,
            decoded.value.tools[0].server_binding_identity,
        );
        catalog_binding_len = decoded.value.servers[0].server_binding_identity.len;
        try std.testing.expect(catalog_binding_len <= catalog_binding.len);
        @memcpy(
            catalog_binding[0..catalog_binding_len],
            decoded.value.servers[0].server_binding_identity,
        );
    }
    api.bufferRelease()(&mcp_description);

    var selector = std.mem.zeroes(wire.McpSelectorV1);
    selector.struct_size = @sizeOf(wire.McpSelectorV1);
    selector.server_binding_identity = [_]u8{0x42} ** 32;
    selector.tool_name = sdk.bytesView("weather");
    const selectors = [_]wire.McpSelectorV1{selector};
    var selected_mcp = std.mem.zeroes(wire.McpSelectionV1);
    selected_mcp.struct_size = @sizeOf(wire.McpSelectionV1);
    selected_mcp.selectors = &selectors;
    selected_mcp.selector_count = selectors.len;
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.mcp_selection = &selected_mcp;
    var create_config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );

    var session_id: [wire.MAX_SESSION_ID_BYTES_V1]u8 = undefined;
    var session_id_len: usize = 0;
    var session_description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().describe()(session, &session_description, &diagnostic),
    );
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = session_description.ptr,
            .len = session_description.len,
        });
        const decoded = try sdk.decodeSessionDescription(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.protocol.LogicalSessionOrigin.fresh, decoded.value.origin);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.mcp.tools.len);
        try std.testing.expectEqualStrings("weather", decoded.value.mcp.tools[0].canonical_name);
        session_id_len = decoded.value.session_id.len;
        @memcpy(session_id[0..session_id_len], decoded.value.session_id);
    }
    api.bufferRelease()(&session_description);

    var bad_selector = selector;
    bad_selector.tool_name = sdk.bytesView("missing");
    const bad_selectors = [_]wire.McpSelectorV1{bad_selector};
    var bad_selection = selected_mcp;
    bad_selection.selectors = &bad_selectors;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_MCP_SELECTION,
        api.mcp().updateSelection()(session, &bad_selection, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var empty_selection = std.mem.zeroes(wire.McpSelectionV1);
    empty_selection.struct_size = @sizeOf(wire.McpSelectionV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().updateSelection()(session, &empty_selection, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().describe()(session, &session_description, &diagnostic),
    );
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = session_description.ptr,
            .len = session_description.len,
        });
        const decoded = try sdk.decodeSessionDescription(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(usize, 0), decoded.value.mcp.tools.len);
    }
    api.bufferRelease()(&session_description);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().updateSelection()(session, &selected_mcp, &diagnostic),
    );

    var run_options = std.mem.zeroes(wire.RunOptionsV1);
    run_options.struct_size = @sizeOf(wire.RunOptionsV1);
    run_options.max_turns = 1;
    var run_result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("remember this before restore"),
            &run_options,
            &run_result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, run_result.stop_reason_code);

    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    checkpoint.fail_write = true;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_IO,
        api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 0), checkpoint.bytes.items.len);
    api.bufferRelease()(&diagnostic);
    checkpoint.fail_write = false;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic),
    );
    try std.testing.expectEqual(@as(u64, 1), export_result.checkpoint_generation);
    try std.testing.expectEqual(@as(u64, checkpoint.bytes.items.len), export_result.total_bytes);
    try std.testing.expect(export_result.chunk_count != 0 and checkpoint.writes != 0);

    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    var restore_host = host;
    restore_host.mcp_selection = null;
    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &restore_host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);

    const original_magic = checkpoint.bytes.items[0];
    checkpoint.bytes.items[0] = 'X';
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_CORRUPT,
        api.sessionControl().restore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);
    checkpoint.bytes.items[0] = original_magic;

    var schema_revision_bytes: [4]u8 = undefined;
    @memcpy(&schema_revision_bytes, checkpoint.bytes.items[16..20]);
    std.mem.writeInt(u32, checkpoint.bytes.items[16..20], 2, .little);
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_UNSUPPORTED,
        api.sessionControl().restore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);
    @memcpy(checkpoint.bytes.items[16..20], &schema_revision_bytes);

    var abi_revision_bytes: [4]u8 = undefined;
    @memcpy(&abi_revision_bytes, checkpoint.bytes.items[20..24]);
    try std.testing.expectEqual(@as(u32, 26), wire.ABI_REVISION);
    // A Session without a prompt profile keeps the marker-8 envelope across
    // ABI revisions; the marker is independent of the table revision.
    try std.testing.expectEqual(
        @as(u32, 8),
        std.mem.readInt(u32, &abi_revision_bytes, .little),
    );
    std.mem.writeInt(u32, checkpoint.bytes.items[20..24], 6, .little);
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_INCOMPATIBLE,
        api.sessionControl().restore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);
    @memcpy(checkpoint.bytes.items[20..24], &abi_revision_bytes);

    var undersized_limits = limits;
    undersized_limits.hard_bytes = checkpoint.bytes.items.len - 1;
    restore_config.limits = &undersized_limits;
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionControl().restore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);
    restore_config.limits = &limits;

    checkpoint.fail_read = true;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_IO,
        api.sessionControl().restore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    try std.testing.expect(restore_report.ptr == null and restore_report.len == 0);
    api.bufferRelease()(&diagnostic);

    checkpoint.fail_read = false;
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().restore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(checkpoint.reads != 0);
    var restored_policy_generation: u64 = 0;
    var restored_catalog_generation: u64 = 0;
    var restored_issue_id: [64]u8 = undefined;
    var restored_issue_id_len: usize = 0;
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = restore_report.ptr,
            .len = restore_report.len,
        });
        const decoded = try sdk.decodeRestoreReport(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.degraded, decoded.value.health);
        try std.testing.expectEqualStrings(session_id[0..session_id_len], decoded.value.session_id);
        try std.testing.expectEqual(
            export_result.checkpoint_generation,
            decoded.value.checkpoint_generation,
        );
        restored_policy_generation = decoded.value.policy_generation;
        restored_catalog_generation = decoded.value.catalog_generation;
        try std.testing.expectEqual(catalog_generation, restored_catalog_generation);
        try std.testing.expectEqual(@as(u32, 0), decoded.value.mcp.restored_bindings);
        try std.testing.expectEqual(@as(u32, 1), decoded.value.mcp.invalidated_bindings);
        try std.testing.expect(decoded.value.issues.len != 0);
        const issue = decoded.value.issues[0];
        try std.testing.expectEqual(sdk.protocol.AuthoritySubsystem.mcp, issue.subsystem);
        try std.testing.expectEqualStrings(
            catalog_binding[0..catalog_binding_len],
            issue.server_binding_identity.?,
        );
        restored_issue_id_len = issue.issue_id.len;
        try std.testing.expect(restored_issue_id_len <= restored_issue_id.len);
        @memcpy(restored_issue_id[0..restored_issue_id_len], issue.issue_id);
    }
    api.bufferRelease()(&restore_report);

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().describe()(session, &session_description, &diagnostic),
    );
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = session_description.ptr,
            .len = session_description.len,
        });
        const decoded = try sdk.decodeSessionDescription(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.protocol.LogicalSessionOrigin.restored, decoded.value.origin);
        try std.testing.expectEqualStrings(session_id[0..session_id_len], decoded.value.session_id);
        try std.testing.expectEqual(@as(u64, 1), decoded.value.last_run_id);
        try std.testing.expectEqual(
            export_result.checkpoint_generation,
            decoded.value.checkpoint_generation,
        );
        try std.testing.expectEqual(restored_policy_generation, decoded.value.policy_generation);
        try std.testing.expectEqual(restored_catalog_generation, decoded.value.catalog_generation);
        try std.testing.expect(decoded.value.conversation.message_count != 0);
        try std.testing.expectEqual(@as(usize, 0), decoded.value.mcp.tools.len);
        try std.testing.expectEqual(@as(u32, 1), decoded.value.restore.invalidated_mcp_bindings);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.restore.issues.len);
        try std.testing.expectEqualStrings(
            restored_issue_id[0..restored_issue_id_len],
            decoded.value.restore.issues[0].issue_id,
        );
        try std.testing.expectEqualStrings(
            catalog_binding[0..catalog_binding_len],
            decoded.value.restore.issues[0].server_binding_identity.?,
        );
    }
    api.bufferRelease()(&session_description);

    run_result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            2,
            sdk.bytesView("continue after restore"),
            &run_options,
            &run_result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, run_result.stop_reason_code);

    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
    try std.testing.expectEqual(@as(u32, 2), mcp_probe.opens);
    try std.testing.expectEqual(@as(u32, 1), mcp_probe.probe_opens);
    try std.testing.expectEqual(@as(u32, 1), mcp_probe.actual_opens);
    try mcp_probe.expectClosedExactlyOnce();
    try std.testing.expectEqual(mcp_probe.requests, mcp_probe.releases);
}

test "L2 Revision 7 public Permission callback and provenance bind the exact Host invocation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE, HOST_SSE };
    var provider = try harness.MockServer.startCassette(&bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var probe = PublicPermissionProbe{};
    var host_tool = std.mem.zeroes(wire.HostToolV1);
    host_tool.struct_size = @sizeOf(wire.HostToolV1);
    host_tool.ctx = &probe;
    host_tool.name = sdk.bytesView("HostEcho");
    host_tool.description = sdk.bytesView("Echo a value through the Host");
    host_tool.input_schema_json = sdk.bytesView(
        "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
    );
    host_tool.execute = PublicPermissionProbe.host;
    host_tool.release_result = PublicPermissionProbe.releaseHost;
    const host_tools = [_]wire.HostToolV1{host_tool};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = &host_tools;
    runtime_config.host_tool_count = host_tools.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const allowed_tools = [_]wire.BytesViewV1{sdk.bytesView("HostEcho")};
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.allowed_tools = &allowed_tools;
    host.allowed_tool_count = allowed_tools.len;
    var create_config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = PublicPermissionProbe.event;
    callbacks.on_ui_request = PublicPermissionProbe.ui;
    callbacks.release_response = PublicPermissionProbe.releaseUi;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );
    probe.expected_session = session;
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("invoke the Host echo"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), probe.ui_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.ui_releases);
    try std.testing.expectEqual(@as(u32, 1), probe.host_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.host_releases);
    try std.testing.expectEqual(@as(u32, 1), probe.callback_provenance);
    try std.testing.expect(!probe.raw_arguments_leaked);

    // Permission provenance uses the same fatal-aware Run event lifecycle as
    // every other public event. A Host rejection aborts before dispatch and
    // cannot be converted into an ordinary model-visible deny.
    probe.expected_run_id = 2;
    probe.fatal_on_permission = true;
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        api.session().runText(
            session,
            2,
            sdk.bytesView("invoke the Host echo again"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), probe.host_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.host_releases);
}

test "L2 Revision 7 imported permission rules control the next Run" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ WRITE_SSE, FINAL_SSE, WRITE_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    const builtins = [_]wire.BytesViewV1{sdk.bytesView("Write")};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const deny_write = [_]wire.BytesViewV1{sdk.bytesView("Write")};
    var initial_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    initial_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    initial_rules.deny = &deny_write;
    initial_rules.deny_count = deny_write.len;
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_DEFAULT;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &builtins;
    host_config.allowed_tool_count = builtins.len;
    host_config.permission_rules = &initial_rules;
    var config = sessionCreateConfig(&host_config, "test-model");
    var probe = PublicFileChangesProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = PublicFileChangesProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    probe.expected_session = session;
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    probe.expected_run_id = 1;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("attempt denied write"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    const written_path = try std.fs.path.join(a, &.{ root, "blocked.txt" });
    defer a.free(written_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, written_path, .{}),
    );
    try std.testing.expectEqual(@as(u32, 0), probe.applied);
    try std.testing.expectEqual(@as(u32, 1), probe.rejected);
    try std.testing.expectEqual(@as(u32, 1), probe.denied_tool_results);
    try std.testing.expectEqual(@as(u32, 0), probe.applied_tool_results);

    const allow_write = [_]wire.BytesViewV1{sdk.bytesView("Write")};
    var replacement_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    replacement_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    replacement_rules.allow = &allow_write;
    replacement_rules.allow_count = allow_write.len;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().updatePermissionRules()(session, &replacement_rules, &diagnostic),
    );
    probe.expected_run_id = 2;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            2,
            sdk.bytesView("attempt allowed write"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), probe.applied);
    try std.testing.expectEqual(@as(u32, 1), probe.applied_tool_results);
    try std.Io.Dir.cwd().access(std.testing.io, written_path, .{});
}

test "L2 Host tool named Read cannot acquire builtin file references" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_READ_SSE, FINAL_SSE };
    var provider = try harness.MockServer.startCassette(&bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var probe = HostReadRefsProbe{};
    var host_tool = std.mem.zeroes(wire.HostToolV1);
    host_tool.struct_size = @sizeOf(wire.HostToolV1);
    host_tool.ctx = &probe;
    host_tool.name = sdk.bytesView("Read");
    host_tool.description = sdk.bytesView("Host-owned Read name collision fixture");
    host_tool.input_schema_json = sdk.bytesView(
        "{\"type\":\"object\",\"properties\":{\"file_path\":{\"type\":\"string\"}},\"required\":[\"file_path\"]}",
    );
    host_tool.execute = HostReadRefsProbe.host;
    host_tool.release_result = HostReadRefsProbe.releaseHost;
    const host_tools = [_]wire.HostToolV1{host_tool};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = &host_tools;
    runtime_config.host_tool_count = host_tools.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const allowed_tools = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    const allow_read = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    var rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    rules.allow = &allow_read;
    rules.allow_count = allow_read.len;
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.allowed_tools = &allowed_tools;
    host.allowed_tool_count = allowed_tools.len;
    host.permission_rules = &rules;
    var config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = HostReadRefsProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    probe.expected_session = session;
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("invoke Host Read"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), probe.host_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.host_releases);
    try std.testing.expectEqual(@as(u32, 1), probe.tool_results);

    const decoy_path = try std.fs.path.join(a, &.{ root, "decoy.txt" });
    defer a.free(decoy_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, decoy_path, .{}),
    );
}

test "L2 invalid Session configuration publishes no handle and diagnostics never leak credentials" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    const builtins = [_]wire.BytesViewV1{ sdk.bytesView("Read"), sdk.bytesView("Bash") };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;

    var excessive_runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    excessive_runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    excessive_runtime_config.builtin_tool_count = wire.MAX_TOOL_COUNT_V1 + 1;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.runtime().create()(&excessive_runtime_config, null, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = Probe.event;
    const read_only = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &read_only;
    host_config.allowed_tool_count = read_only.len;
    var config = sessionCreateConfig(&host_config, "test-model");

    var missing_event_callbacks = callbacks;
    missing_event_callbacks.on_event = null;
    try expectInvalidSessionConfig(api, runtime.?, &config, &missing_event_callbacks, &diagnostic);

    var metadata_byte: u8 = 'x';
    const valid_model = config.model;
    config.model = .{ .ptr = @ptrCast(&metadata_byte), .len = wire.MAX_METADATA_STRING_BYTES_V1 + 1 };
    var metadata_limited_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.session().create()(runtime, &config, &callbacks, &metadata_limited_session, &diagnostic),
    );
    try std.testing.expect(metadata_limited_session == null);
    api.bufferRelease()(&diagnostic);
    config.model = valid_model;

    host_config.workspace_root = sdk.bytesView(".");
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);
    host_config.workspace_root = sdk.bytesView(root);

    host_config.workspace_home = sdk.bytesView(".");
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);
    host_config.workspace_home = sdk.bytesView(root);

    const missing = [_]wire.BytesViewV1{sdk.bytesView("Grep")};
    host_config.allowed_tools = &missing;
    host_config.allowed_tool_count = missing.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    const duplicate = [_]wire.BytesViewV1{ sdk.bytesView("Read"), sdk.bytesView("Read") };
    host_config.allowed_tools = &duplicate;
    host_config.allowed_tool_count = duplicate.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    const disabled_shell = [_]wire.BytesViewV1{sdk.bytesView("Bash")};
    host_config.allowed_tools = &disabled_shell;
    host_config.allowed_tool_count = disabled_shell.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    host_config.allowed_tools = null;
    host_config.allowed_tool_count = wire.MAX_TOOL_COUNT_V1 + 1;
    var limited_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.session().create()(runtime, &config, &callbacks, &limited_session, &diagnostic),
    );
    try std.testing.expect(limited_session == null);
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 sandbox admission is eager while unrestricted skips the probe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    const builtins = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const read_only = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &read_only;
    host_config.allowed_tool_count = read_only.len;
    var config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = Probe.event;

    host_config.shell_policy_code = wire.SHELL_UNRESTRICTED;
    var unrestricted: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &config, &callbacks, &unrestricted, &diagnostic),
    );
    try std.testing.expect(unrestricted != null);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(unrestricted, &diagnostic));

    host_config.shell_policy_code = wire.SHELL_SANDBOXED;
    var sandboxed: ?*wire.SessionHandle = null;
    const status = api.session().create()(runtime, &config, &callbacks, &sandboxed, &diagnostic);
    if (@import("builtin").os.tag == .macos) {
        try std.testing.expectEqual(wire.STATUS_OK, status);
        try std.testing.expect(sandboxed != null);
        try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(sandboxed, &diagnostic));
    } else {
        try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, status);
        try std.testing.expect(sandboxed == null);
    }
}

test "L2 public events reconstruct continuation output and observable run usage" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ CONTINUATION_HEAD_SSE, CONTINUATION_TAIL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "test-model");

    var probe = ReconstructionProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = ReconstructionProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 4;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 1, sdk.bytesView("continue fixture"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqualStrings("headtail", probe.answer[0..probe.answer_len]);
    try std.testing.expectEqualStrings("private reasoning", probe.thinking[0..probe.thinking_len]);
    try std.testing.expectEqual(@as(usize, 2), probe.stream_done_count);
    try std.testing.expectEqual(@as(usize, 2), probe.segment_begin_count);
    try std.testing.expectEqual(@as(usize, 1), probe.continued_count);
    try std.testing.expectEqual(@as(usize, 1), probe.final_count);
    try std.testing.expectEqual(@as(usize, 0), probe.commentary_count);
    try std.testing.expectEqual(@as(usize, 0), probe.partial_count);
    try std.testing.expectEqual(@as(usize, 0), probe.discarded_count);
    try std.testing.expectEqual(@as(u64, 11), probe.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), probe.usage.output_tokens);
}

/// One Anthropic response cut at the output-token limit, carrying `text`
/// (none when empty).
fn maxTokensCutSse(comptime text: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"cut\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n" ++
        (if (text.len == 0) "" else "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n\n" ++
            "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n") ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

fn expectExhaustionThroughAbi(comptime text: []const u8) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    // The initial request and its three continuations are all cut; the
    // fifth response answers the next Run.
    const cut = comptime maxTokensCutSse(text);
    const bodies = [_][]const u8{ cut, cut, cut, cut, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ReconstructionProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ReconstructionProbe.event);
    defer fixture.deinit();

    var result = try fixture.runTextTurns(1, "write the report", 8);
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 4), result.turns);
    try std.testing.expectEqual(@as(usize, 4), server.requestCount());
    // A Run outcome, not a facade failure: no diagnostic.
    try std.testing.expectEqual(@as(u64, 0), fixture.diagnostic.len);
    // The Host got every visible byte, closed as partial and never as the
    // answer, and a failed (not poisoned) terminal RunState.
    try std.testing.expectEqual(@as(usize, 3), probe.continued_count);
    try std.testing.expectEqual(@as(usize, 1), probe.partial_count);
    try std.testing.expectEqual(@as(usize, 0), probe.final_count);
    try std.testing.expectEqualStrings(text ** 4, probe.partial[0..probe.partial_len]);
    try std.testing.expectEqual(@as(?sdk.protocol.RunStatePhase, .failed), probe.last_phase);

    // The same Session takes the next Run.
    result = try fixture.runTextTurns(2, "try again", 8);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 5), server.requestCount());
    try std.testing.expectEqualStrings("done", probe.answer[0..probe.answer_len]);
    try std.testing.expectEqual(@as(?sdk.protocol.RunStatePhase, .completed), probe.last_phase);
}

test "L2 issue #394: max-token exhaustion with visible text crosses AgentCore as api_error and leaves the Session usable" {
    try expectExhaustionThroughAbi("cut ");
}

test "L2 issue #394: max-token exhaustion without text crosses AgentCore as api_error and leaves the Session usable" {
    // Before #394 this poisoned the facade (INTERNAL_ERROR, then INVALID_STATE).
    try expectExhaustionThroughAbi("");
}

test "L2 issue #394 control: a truncation that recovers on the last continuation is still END_TURN through AgentCore" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const cut = comptime maxTokensCutSse("cut ");
    const bodies = [_][]const u8{ cut, cut, cut, CONTINUATION_TAIL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ReconstructionProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ReconstructionProbe.event);
    defer fixture.deinit();

    const result = try fixture.runTextTurns(1, "write the report", 8);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 4), server.requestCount());
    try std.testing.expectEqual(@as(usize, 3), probe.continued_count);
    try std.testing.expectEqual(@as(usize, 1), probe.final_count);
    try std.testing.expectEqual(@as(usize, 0), probe.partial_count);
    try std.testing.expectEqualStrings("cut cut cut tail", probe.answer[0..probe.answer_len]);
    try std.testing.expectEqual(@as(?sdk.protocol.RunStatePhase, .completed), probe.last_phase);
}

test "L2 public AgentCore OpenAI chat delivers text from usage:null chunks to the Host (issue #258)" {
    const a = std.testing.allocator;
    for ([_][]const u8{ OPENAI_USAGE_NULL_SSE, OPENAI_USAGE_NULL_CONTROL_SSE }) |sse| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try rootPath(&tmp, &root_buf);
        var server = try harness.MockServer.startCassette(&.{sse}, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);

        const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
        const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        defer api.bufferRelease()(&diagnostic);

        var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
        runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        var runtime: ?*wire.RuntimeHandle = null;
        try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
        defer if (runtime) |handle| {
            _ = api.runtime().destroy()(handle, &diagnostic);
        };

        var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
        host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
        host_config.provider_kind_code = wire.PROVIDER_OPENAI;
        host_config.protocol_kind_code = wire.PROTOCOL_DEFAULT; // Chat Completions
        host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
        host_config.shell_policy_code = wire.SHELL_DISABLED;
        host_config.api_key = sdk.bytesView("test-key");
        host_config.base_url = sdk.bytesView(url);
        host_config.workspace_root = sdk.bytesView(root);
        host_config.workspace_home = sdk.bytesView(root);
        var session_config = sessionCreateConfig(&host_config, "gpt-4o");

        // The Host-side oracle decodes every event through the official SDK.
        var probe = ReconstructionProbe{};
        var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        callbacks.ctx = &probe;
        callbacks.on_event = ReconstructionProbe.event;
        var session: ?*wire.SessionHandle = null;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic),
        );
        defer if (session) |handle| {
            _ = api.session().destroy()(handle, &diagnostic);
        };

        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 2;
        var result = std.mem.zeroes(wire.RunResultV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.session().runText(session, 1, sdk.bytesView("say hello"), &options, &result, &diagnostic),
        );
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
        try std.testing.expectEqual(@as(usize, 1), server.requestCount());
        try std.testing.expect(std.mem.indexOf(
            u8,
            (server.lastRequest() orelse return error.NoRequestCaptured).body(),
            "\"include_usage\":true",
        ) != null);

        // The text reached the Host as one final output segment.
        try std.testing.expectEqualStrings("Hello", probe.answer[0..probe.answer_len]);
        try std.testing.expectEqual(@as(usize, 1), probe.segment_begin_count);
        try std.testing.expectEqual(@as(usize, 1), probe.final_count);
        try std.testing.expectEqual(@as(usize, 0), probe.discarded_count);
        try std.testing.expectEqual(@as(usize, 1), probe.stream_done_count);
        // Usage comes only from the final usage object; prompt_tokens includes
        // the cached tokens, so input = 2006 - 1920.
        try std.testing.expectEqual(@as(u64, 86), probe.usage.input_tokens);
        try std.testing.expectEqual(@as(u64, 10), probe.usage.output_tokens);
        try std.testing.expectEqual(@as(u64, 1920), probe.usage.cache_read_input_tokens);
        try std.testing.expectEqual(@as(u64, 0), probe.usage.cache_creation_input_tokens);
    }
}

test "L2 session_set_model preserves Conversation and changes the next Run request" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var config = sessionCreateConfig(&host_config, "old-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("first prompt"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().setModel()(session, sdk.bytesView("new-model"), &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            2,
            sdk.bytesView("second prompt"),
            &options,
            &result,
            &diagnostic,
        ),
    );

    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const first = server.requestAt(0) orelse return error.NoRequestCaptured;
    const second = server.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "\"model\":\"old-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"model\":\"new-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "first prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"text\":\"done\"") != null);
}

test "L2 invalid model is a recoverable provider outcome through the public facade" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ API_ERROR_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "old-model");
    defer fixture.deinit();

    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().setModel()(
            fixture.session,
            sdk.bytesView("invalid-model"),
            &fixture.diagnostic,
        ),
    );
    var result = try fixture.runText(1, "provider validates this model");
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);

    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().setModel()(
            fixture.session,
            sdk.bytesView("recovered-model"),
            &fixture.diagnostic,
        ),
    );
    result = try fixture.runText(2, "continue after recovery");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const failed = server.requestAt(0) orelse return error.NoRequestCaptured;
    const recovered = server.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, failed.body(), "\"model\":\"invalid-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered.body(), "\"model\":\"recovered-model\"") != null);
}

test "L2 unnamed Provider HTTP 529 crosses AgentCore ABI without killing the Host" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"overloaded_error\",\"message\":\"provider overloaded\"}}",
        0,
        "HTTP/1.1 529 Site Overloaded",
    );
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.session().runText(
            fixture.session,
            1,
            sdk.bytesView("exercise unnamed provider status"),
            &options,
            &result,
            &fixture.diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);

    const diagnostic = try sdk.borrowedBytes(.{
        .ptr = fixture.diagnostic.ptr,
        .len = fixture.diagnostic.len,
    });
    // Provider failures are Run outcomes, not facade failures, so the ABI
    // diagnostic is a valid empty buffer and the error is carried by stop_reason.
    try std.testing.expectEqual(@as(usize, 0), diagnostic.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(diagnostic));
    fixture.releaseDiagnostic();

    // The Host remains in control and can safely destroy the same Session.
    const session = fixture.session orelse return error.MissingSession;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.session().destroy()(session, &fixture.diagnostic),
    );
    fixture.session = null;
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

// --- issue #408: why a Run stopped with STOP_API_ERROR -----------------------

/// Records a Run's `model_error` events as the Host received them, after full
/// typed decoding, and where they fell relative to the terminal `run_state`.
const ModelErrorProbe = struct {
    count: usize = 0,
    after_terminal: bool = false,
    terminal: bool = false,
    wrong_run: bool = false,
    json_buf: [8 * 1024]u8 = undefined,
    json_len: usize = 0,

    fn reset(self: *ModelErrorProbe) void {
        self.* = .{};
    }

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *ModelErrorProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const known = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (known) {
            .model_error => |detail| {
                if (detail.run_id != run.run_id) self.wrong_run = true;
                if (self.terminal) self.after_terminal = true;
                self.count += 1;
                if (encoded.len > self.json_buf.len) return wire.EVENT_FATAL;
                @memcpy(self.json_buf[0..encoded.len], encoded);
                self.json_len = encoded.len;
            },
            .run_state => |state| switch (state.phase) {
                .completed, .failed, .aborted, .poisoned => self.terminal = true,
                else => {},
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }

    const Expected = struct {
        category: sdk.protocol.ModelErrorCategory,
        code: ?[]const u8 = null,
        type: ?[]const u8 = null,
        message: []const u8,
        http_status: ?u16 = null,
        request_id: ?[]const u8 = null,
        retry: sdk.protocol.ModelErrorRetry,
        retry_after_ms: ?u64 = null,
        attempts: u32 = 1,
    };

    /// Exactly one, before the terminal run_state, and it says this.
    fn expect(self: *const ModelErrorProbe, run_id: u64, want: Expected) !void {
        try std.testing.expectEqual(@as(usize, 1), self.count);
        try std.testing.expect(!self.after_terminal);
        try std.testing.expect(!self.wrong_run);
        const parsed = try sdk.decodeCoreEvent(std.testing.allocator, self.json_buf[0..self.json_len]);
        defer parsed.deinit();
        const got = parsed.value.known.model_error;
        try std.testing.expectEqual(run_id, got.run_id);
        try std.testing.expectEqual(want.category, got.category);
        try expectOptionalString(want.code, got.code);
        try expectOptionalString(want.type, got.type);
        try std.testing.expectEqualStrings(want.message, got.message);
        try std.testing.expectEqual(want.http_status, got.http_status);
        try expectOptionalString(want.request_id, got.request_id);
        try std.testing.expectEqual(want.retry, got.retry);
        try std.testing.expectEqual(want.retry_after_ms, got.retry_after_ms);
        try std.testing.expectEqual(want.attempts, got.attempts);
    }
};

fn expectOptionalString(want: ?[]const u8, got: ?[]const u8) !void {
    if (want) |value| {
        try std.testing.expectEqualStrings(value, got orelse return error.MissingField);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), got);
    }
}

const ModelFailureCase = struct {
    provider: u32 = wire.PROVIDER_ANTHROPIC,
    expected: ModelErrorProbe.Expected,
};

/// One Run against `server` over the public ABI: STATUS_OK, STOP_API_ERROR and
/// an empty diagnostic, exactly as before #408, plus the detail.
fn expectModelFailure(server: *harness.MockServer, case: ModelFailureCase) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ModelErrorProbe{};
    var fixture = try PublicSessionFixture.initObservedProviderConfigured(
        root,
        url,
        "test-model",
        null,
        wire.RUN_JOURNAL_EPHEMERAL,
        case.provider,
        wire.PROTOCOL_DEFAULT,
        &.{},
        &probe,
        ModelErrorProbe.event,
    );
    defer fixture.deinit();
    const result = try fixture.runTextTurns(1, "exercise the failure", 2);
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try std.testing.expectEqual(@as(u64, 0), fixture.diagnostic.len);
    try probe.expect(1, case.expected);
}

test "L2 #408 authentication failure: status, code, message and request id reach the Host" {
    var server = try harness.MockServer.startRepeatingStatus(
        "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key value\"}}",
        "HTTP/1.1 401 Unauthorized",
        "x-request-id: req-auth-1\r\n",
    );
    defer server.stop();
    try expectModelFailure(server, .{ .expected = .{
        .category = .authentication,
        .code = "authentication_error",
        .type = "authentication_error",
        .message = "invalid x-api-key value",
        .http_status = 401,
        .request_id = "req-auth-1",
        .retry = .not_retryable,
    } });
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "L2 #408 rate limit: retry-after and the attempts spent reach the Host" {
    var server = try harness.MockServer.startRepeatingStatus(
        "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}",
        "HTTP/1.1 429 Too Many Requests",
        "retry-after: 0\r\nrequest-id: req-rate-1\r\n",
    );
    defer server.stop();
    var attempts = try EnvOverride.set("CLAUDE_CODE_MAX_RETRIES", "3");
    defer attempts.restore();
    try expectModelFailure(server, .{ .expected = .{
        .category = .rate_limited,
        .code = "rate_limit_error",
        .type = "rate_limit_error",
        .message = "slow down",
        .http_status = 429,
        .request_id = "req-rate-1",
        .retry = .retryable,
        .retry_after_ms = 0,
        .attempts = 3,
    } });
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
}

test "L2 #408 service overload: an unnamed status keeps its meaning" {
    var server = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"overloaded_error\",\"message\":\"provider overloaded\"}}",
        0,
        "HTTP/1.1 529 Site Overloaded",
    );
    defer server.stop();
    try expectModelFailure(server, .{ .expected = .{
        .category = .overloaded,
        .code = "overloaded_error",
        .type = "overloaded_error",
        .message = "provider overloaded",
        .http_status = 529,
        .retry = .retryable,
    } });
}

/// Set for one test and restored; the Session reads these when it is created.
const EnvOverride = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: [*:0]const u8) !EnvOverride {
        const previous = if (std.c.getenv(name)) |raw| try std.testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvOverride) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
    }
};

test "L2 #408 timeout waiting for the response head names the timeout" {
    var head_limit = try EnvOverride.set("METACODES_STREAM_IDLE_TIMEOUT_MS", "150");
    defer head_limit.restore();
    var attempts = try EnvOverride.set("CLAUDE_CODE_MAX_RETRIES", "1");
    defer attempts.restore();
    var server = try harness.MockServer.startCassetteSilent(&[_][]const u8{FINAL_SSE}, 0, 0);
    defer server.stop();

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ModelErrorProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
    defer fixture.deinit();
    const result = try fixture.runTextTurns(1, "wait forever", 2);
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    const parsed = try sdk.decodeCoreEvent(a, probe.json_buf[0..probe.json_len]);
    defer parsed.deinit();
    const got = parsed.value.known.model_error;
    try std.testing.expectEqual(sdk.protocol.ModelErrorCategory.timeout, got.category);
    try std.testing.expectEqual(sdk.protocol.ModelErrorRetry.retryable, got.retry);
    try std.testing.expectEqual(@as(?u16, null), got.http_status);
    try std.testing.expect(std.mem.startsWith(u8, got.message, "No response head within "));
}

test "L2 #408 timeout in the body of an accepted stream carries that response's status and id" {
    var body_limit = try EnvOverride.set("METACODES_STREAM_BODY_IDLE_TIMEOUT_MS", "150");
    defer body_limit.restore();
    const first = std.mem.indexOf(u8, FINAL_SSE, "\n\n").? + 2;
    const second = std.mem.indexOfPos(u8, FINAL_SSE, first, "\n\n").? + 2;
    const with_text = std.mem.indexOfPos(u8, FINAL_SSE, second, "\n\n").? + 2;
    var server = try harness.MockServer.startCassetteSilent(&[_][]const u8{FINAL_SSE}, 0, with_text);
    defer server.stop();
    server.extra_response_headers = "x-request-id: req-stall-1\r\n";

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ModelErrorProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
    defer fixture.deinit();
    const result = try fixture.runTextTurns(1, "stall after some text", 2);
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    const parsed = try sdk.decodeCoreEvent(a, probe.json_buf[0..probe.json_len]);
    defer parsed.deinit();
    const got = parsed.value.known.model_error;
    try std.testing.expectEqual(sdk.protocol.ModelErrorCategory.timeout, got.category);
    try std.testing.expectEqual(@as(?u16, 200), got.http_status);
    try std.testing.expectEqualStrings("req-stall-1", got.request_id.?);
    try std.testing.expect(std.mem.startsWith(u8, got.message, "No model output for "));
}

/// Text reaches the Host in the half that is sent, so the loop does not resend.
const CUT_AFTER_TEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"cut\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n" ++
    ("data: {\"type\":\"ping\"}\n\n" ** 40);

/// No visible output in the half that is sent, so the loop resends once.
const CUT_BEFORE_TEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"cut\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    ("data: {\"type\":\"ping\"}\n\n" ** 40);

test "L2 #408 stream interruption reaches the Host as such, with the stream's request id" {
    var server = try harness.MockServer.startCassetteMidStreamCut(&[_][]const u8{CUT_AFTER_TEXT_SSE}, 0);
    defer server.stop();
    server.extra_response_headers = "x-request-id: req-cut-1\r\n";
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ModelErrorProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
    defer fixture.deinit();
    const result = try fixture.runTextTurns(1, "cut me off", 2);
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    const parsed = try sdk.decodeCoreEvent(a, probe.json_buf[0..probe.json_len]);
    defer parsed.deinit();
    const got = parsed.value.known.model_error;
    try std.testing.expectEqual(sdk.protocol.ModelErrorCategory.stream_interrupted, got.category);
    try std.testing.expectEqual(sdk.protocol.ModelErrorRetry.retryable, got.retry);
    try std.testing.expectEqual(@as(?u16, 200), got.http_status);
    try std.testing.expectEqualStrings("req-cut-1", got.request_id.?);
}

test "L2 #408 insufficient balance: the upstream code and message pass through uninterpreted" {
    var server = try harness.MockServer.startRepeatingStatus(
        "{\"error\":{\"code\":\"insufficient_balance\",\"message\":\"Account balance is below the minimum, please top up\"}}",
        "HTTP/1.1 402 Payment Required",
        "x-metask-request-id: req-bal-1\r\nx-request-id: req-vendor-1\r\n",
    );
    defer server.stop();
    try expectModelFailure(server, .{ .expected = .{
        .category = .payment_required,
        .code = "insufficient_balance",
        .message = "Account balance is below the minimum, please top up",
        .http_status = 402,
        .request_id = "req-bal-1",
        .retry = .not_retryable,
    } });
}

test "L2 #408 quota exhaustion on OpenAI's 429 keeps its code and leaves retry guidance unknown" {
    var server = try harness.MockServer.startRepeatingStatus(
        "{\"error\":{\"message\":\"You exceeded your current quota\",\"type\":\"insufficient_quota\",\"param\":null,\"code\":\"insufficient_quota\"}}",
        "HTTP/1.1 429 Too Many Requests",
        "x-request-id: req-quota-1\r\n",
    );
    defer server.stop();
    try expectModelFailure(server, .{ .provider = wire.PROVIDER_OPENAI, .expected = .{
        .category = .rate_limited,
        .code = "insufficient_quota",
        .type = "insufficient_quota",
        .message = "You exceeded your current quota",
        .http_status = 429,
        .request_id = "req-quota-1",
        .retry = .unknown,
    } });
}

test "L2 #408 quota exhaustion on Gemini: its body is read and its canonical status is the code" {
    var server = try harness.MockServer.startRepeatingStatus(
        "[{\"error\":{\"code\":429,\"message\":\"Quota exceeded for metric\",\"status\":\"RESOURCE_EXHAUSTED\"}}]",
        "HTTP/1.1 429 Too Many Requests",
        "",
    );
    defer server.stop();
    try expectModelFailure(server, .{ .provider = wire.PROVIDER_GEMINI, .expected = .{
        .category = .rate_limited,
        .code = "RESOURCE_EXHAUSTED",
        .message = "Quota exceeded for metric",
        .http_status = 429,
        .retry = .unknown,
    } });
}

test "L2 #408 an unknown business code passes through, over HTTP and inside a stream" {
    {
        var server = try harness.MockServer.startRepeatingStatus(
            "{\"code\":90210,\"msg\":\"合约未生效\"}",
            "HTTP/1.1 400 Bad Request",
            "",
        );
        defer server.stop();
        try expectModelFailure(server, .{ .expected = .{
            .category = .invalid_request,
            .code = "90210",
            .message = "合约未生效",
            .http_status = 400,
            .retry = .not_retryable,
        } });
    }
    {
        const frame = "data: {\"type\":\"error\",\"error\":{\"type\":\"acme_contract_error\",\"code\":\"ACME_42\",\"message\":\"contract lapsed\"},\"request_id\":\"req-frame-1\"}\n\n";
        var server = try harness.MockServer.startCassette(&[_][]const u8{frame}, 0);
        defer server.stop();
        try expectModelFailure(server, .{ .expected = .{
            .category = .unknown,
            .code = "ACME_42",
            .type = "acme_contract_error",
            .message = "contract lapsed",
            .http_status = 200,
            .request_id = "req-frame-1",
            .retry = .unknown,
        } });
    }
}

test "L2 #408 the credential and secret shapes never reach the Host, and fields are bounded" {
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.appendSlice(a, "{\"error\":{\"code\":\"bad_key\",\"message\":\"Key test-key rejected; also sk-live-abcdef1234 and api_key=hunter2hunter2 ");
    try body.appendNTimes(a, 'x', 1500);
    try body.appendSlice(a, "\"}}");
    var server = try harness.MockServer.startRepeatingStatus(body.items, "HTTP/1.1 401 Unauthorized", "");
    defer server.stop();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ModelErrorProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
    defer fixture.deinit();
    _ = try fixture.runTextTurns(1, "leak the key", 2);
    const json = probe.json_buf[0..probe.json_len];
    for ([_][]const u8{ "test-key", "sk-live-abcdef1234", "hunter2hunter2" }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, json, secret) == null);
    }
    const parsed = try sdk.decodeCoreEvent(a, json);
    defer parsed.deinit();
    const got = parsed.value.known.model_error;
    try std.testing.expectEqualStrings("bad_key", got.code.?);
    try std.testing.expect(std.mem.indexOf(u8, got.message, "[REDACTED]") != null);
    try std.testing.expect(got.message.len <= 1024);
    try std.testing.expect(got.truncated);
}

test "L2 #408 a stream frame that echoes the credential does not carry it to the Host" {
    const frame = "data: {\"type\":\"error\",\"error\":{\"code\":\"bad_key\",\"message\":\"key test-key refused\"}}\n\n";
    var server = try harness.MockServer.startCassette(&[_][]const u8{frame}, 0);
    defer server.stop();
    try expectModelFailure(server, .{ .expected = .{
        .category = .unknown,
        .code = "bad_key",
        .message = "key [REDACTED] refused",
        .http_status = 200,
        .retry = .unknown,
    } });
}

test "L2 #408 a redirect's Location does not carry the credential to the Host, on any provider" {
    // "test-key" has no secret prefix, and neither a path segment nor the query
    // name `k` is a pattern the masking knows: only the credential's print
    // can catch it.
    for ([_]u32{ wire.PROVIDER_ANTHROPIC, wire.PROVIDER_OPENAI, wire.PROVIDER_GEMINI }) |provider| {
        var server = try harness.MockServer.startRepeatingStatus(
            "",
            "HTTP/1.1 302 Found",
            "location: http://gateway.example/v1/test-key/x?k=test-key\r\n",
        );
        defer server.stop();
        try expectModelFailure(server, .{ .provider = provider, .expected = .{
            .category = .invalid_request,
            .message = "The endpoint redirected (HTTP 302) to http://gateway.example/v1/[REDACTED]/x?k=[REDACTED]; requests that carry a key do not follow redirects, so use that URL as the endpoint.",
            .http_status = 302,
            .retry = .not_retryable,
        } });
    }
}

test "L2 #408 a Location too long to report whole cannot leak a cut credential" {
    // The clients keep 256 bytes of Location. Placed across that bound, the
    // credential arrives cut, and a cut credential no longer matches its print.
    const location = "location: http://gateway.example/" ++ ("p" ** (256 - "http://gateway.example/".len - 4)) ++ "/test-key/x\r\n";
    for ([_]u32{ wire.PROVIDER_ANTHROPIC, wire.PROVIDER_OPENAI, wire.PROVIDER_GEMINI }) |provider| {
        var server = try harness.MockServer.startRepeatingStatus("", "HTTP/1.1 302 Found", location);
        defer server.stop();
        try expectModelFailure(server, .{ .provider = provider, .expected = .{
            .category = .invalid_request,
            .message = "The endpoint redirected (HTTP 302) to a URL too long to report; requests that carry a key do not follow redirects, so use that URL as the endpoint.",
            .http_status = 302,
            .retry = .not_retryable,
        } });
    }
}

test "L2 #408 a request-id header that echoes the credential does not carry it to the Host" {
    {
        var server = try harness.MockServer.startRepeatingStatus(
            "{\"error\":{\"code\":\"nope\",\"message\":\"refused\"}}",
            "HTTP/1.1 400 Bad Request",
            "x-request-id: rid-test-key-1\r\n",
        );
        defer server.stop();
        try expectModelFailure(server, .{ .expected = .{
            .category = .invalid_request,
            .code = "nope",
            .message = "refused",
            .http_status = 400,
            .request_id = "rid-[REDACTED]-1",
            .retry = .not_retryable,
        } });
    }
    {
        // The same header on an accepted stream that then fails.
        var server = try harness.MockServer.startCassetteMidStreamCut(&[_][]const u8{CUT_AFTER_TEXT_SSE}, 0);
        defer server.stop();
        server.extra_response_headers = "x-request-id: rid-test-key-2\r\n";
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try rootPath(&tmp, &root_buf);
        const url = try server.urlOwned(a);
        defer a.free(url);
        var probe = ModelErrorProbe{};
        var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
        defer fixture.deinit();
        _ = try fixture.runTextTurns(1, "cut me off", 2);
        try std.testing.expectEqual(@as(usize, 1), probe.count);
        const parsed = try sdk.decodeCoreEvent(a, probe.json_buf[0..probe.json_len]);
        defer parsed.deinit();
        try std.testing.expectEqualStrings("rid-[REDACTED]-2", parsed.value.known.model_error.request_id.?);
    }
}

test "L2 #408 a retry that succeeds leaves no error: HTTP failure, then stream cut" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    {
        var server = try harness.MockServer.startHttpCassette(
            &.{ "{\"error\":{\"type\":\"overloaded_error\",\"message\":\"stale overload\"}}", FINAL_SSE },
            &.{ "HTTP/1.1 503 Service Unavailable", "HTTP/1.1 200 OK" },
        );
        defer server.stop();
        server.extra_response_headers = "retry-after: 0\r\n";
        const url = try server.urlOwned(a);
        defer a.free(url);
        var probe = ModelErrorProbe{};
        var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
        defer fixture.deinit();
        const result = try fixture.runTextTurns(1, "recover", 2);
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
        try std.testing.expectEqual(@as(usize, 2), server.requestCount());
        try std.testing.expectEqual(@as(usize, 0), probe.count);
    }
    {
        var server = try harness.MockServer.startCassetteMidStreamCut(&[_][]const u8{ CUT_BEFORE_TEXT_SSE, FINAL_SSE }, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var probe = ModelErrorProbe{};
        var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
        defer fixture.deinit();
        const result = try fixture.runTextTurns(1, "recover", 2);
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
        try std.testing.expectEqual(@as(usize, 2), server.requestCount());
        try std.testing.expectEqual(@as(usize, 0), probe.count);
    }
}

test "L2 #408 each Run on a Session reports its own failure and a success in between none" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.startHttpCassette(
        &.{
            "{\"error\":{\"code\":\"first_failure\",\"message\":\"first\"}}",
            FINAL_SSE,
            "{\"error\":{\"code\":\"second_failure\",\"message\":\"second\"}}",
        },
        &.{ "HTTP/1.1 402 Payment Required", "HTTP/1.1 200 OK", "HTTP/1.1 403 Forbidden" },
    );
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ModelErrorProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
    defer fixture.deinit();

    var result = try fixture.runTextTurns(1, "one", 2);
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try probe.expect(1, .{ .category = .payment_required, .code = "first_failure", .message = "first", .http_status = 402, .retry = .not_retryable });

    probe.reset();
    result = try fixture.runTextTurns(2, "two", 2);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 0), probe.count);

    probe.reset();
    result = try fixture.runTextTurns(3, "three", 2);
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try probe.expect(3, .{ .category = .permission, .code = "second_failure", .message = "second", .http_status = 403, .retry = .not_retryable });
}

const ConcurrentRun = struct {
    fixture: *PublicSessionFixture,
    stop_code: u32 = 0,
    failed: bool = false,

    fn main(self: *ConcurrentRun) void {
        const result = self.fixture.runTextTurns(1, "concurrent", 2) catch {
            self.failed = true;
            return;
        };
        self.stop_code = result.stop_reason_code;
    }
};

test "L2 #408 concurrent Runs do not overwrite or mix error details" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    var failing_a = try harness.MockServer.startHttpCassette(
        &.{"{\"error\":{\"code\":\"tenant_a_code\",\"message\":\"tenant a message\"}}"},
        &.{"HTTP/1.1 402 Payment Required"},
    );
    defer failing_a.stop();
    failing_a.extra_response_headers = "x-request-id: req-tenant-a\r\n";
    var failing_b = try harness.MockServer.startHttpCassette(
        &.{"{\"error\":{\"code\":\"tenant_b_code\",\"message\":\"tenant b message\"}}"},
        &.{"HTTP/1.1 403 Forbidden"},
    );
    defer failing_b.stop();
    failing_b.extra_response_headers = "x-request-id: req-tenant-b\r\n";
    var succeeding = try harness.MockServer.startCassette(&[_][]const u8{FINAL_SSE}, 0);
    defer succeeding.stop();

    // All three requests are in flight together before any answer is released.
    const servers = [_]*harness.MockServer{ failing_a, failing_b, succeeding };
    for (servers) |server| server.gateResponseAt(0);

    var probes = [_]ModelErrorProbe{.{}} ** 3;
    var urls: [3][]u8 = undefined;
    var url_count: usize = 0;
    defer for (urls[0..url_count]) |url| a.free(url);
    var fixtures: [3]PublicSessionFixture = undefined;
    var fixture_count: usize = 0;
    defer for (fixtures[0..fixture_count]) |*fixture| fixture.deinit();
    for (servers, 0..) |server, index| {
        urls[index] = try server.urlOwned(a);
        url_count += 1;
        fixtures[index] = try PublicSessionFixture.initObserved(root, urls[index], "test-model", null, &probes[index], ModelErrorProbe.event);
        fixture_count += 1;
    }

    var runs: [3]ConcurrentRun = undefined;
    var threads: [3]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        for (servers) |server| server.releaseGatedResponse();
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&runs, &fixtures, 0..) |*run, *fixture, index| {
        run.* = .{ .fixture = fixture };
        threads[index] = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, ConcurrentRun.main, .{run});
        spawned += 1;
    }
    for (servers) |server| try server.waitUntilResponseGated();
    for (servers) |server| server.releaseGatedResponse();
    for (threads) |thread| thread.join();
    spawned = 0;

    for (runs) |run| try std.testing.expect(!run.failed);
    try std.testing.expectEqual(wire.STOP_API_ERROR, runs[0].stop_code);
    try std.testing.expectEqual(wire.STOP_API_ERROR, runs[1].stop_code);
    try std.testing.expectEqual(wire.STOP_END_TURN, runs[2].stop_code);
    try probes[0].expect(1, .{ .category = .payment_required, .code = "tenant_a_code", .message = "tenant a message", .http_status = 402, .request_id = "req-tenant-a", .retry = .not_retryable });
    try probes[1].expect(1, .{ .category = .permission, .code = "tenant_b_code", .message = "tenant b message", .http_status = 403, .request_id = "req-tenant-b", .retry = .not_retryable });
    try std.testing.expectEqual(@as(usize, 0), probes[2].count);
}

test "L2 #408 output-limit exhaustion is STOP_API_ERROR too, so it says what it was" {
    const cut = comptime maxTokensCutSse("cut ");
    var server = try harness.MockServer.startCassette(&[_][]const u8{ cut, cut, cut, cut }, 0);
    defer server.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ModelErrorProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
    defer fixture.deinit();
    const result = try fixture.runTextTurns(1, "write the report", 8);
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try probe.expect(1, .{
        .category = .output_limit,
        .message = "The model kept reaching its output token limit without completing an answer.",
        .retry = .not_retryable,
    });
}

test "L2 #408 a Skill invocation Run in its own context reports its child's failure" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "forked",
        "---\nname: Forked\ndescription: Runs in a fresh child Conversation\ncontext: fork\n---\nFORKED_SKILL_SENTINEL",
    );
    var server = try harness.MockServer.startRepeatingStatus(
        "{\"error\":{\"code\":\"fork_code\",\"message\":\"fork failed\"}}",
        "HTTP/1.1 402 Payment Required",
        "",
    );
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = ModelErrorProbe{};
    var fixture = try PublicSessionFixture.initObserved(root, url, "test-model", null, &probe, ModelErrorProbe.event);
    defer fixture.deinit();

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("model-error-fork-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer fixture.api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.skill().resolveCatalog()(fixture.runtime, &query, &catalog, &descriptor, &fixture.diagnostic));
    defer if (catalog) |handle| {
        _ = fixture.api.skill().releaseCatalog()(handle, &fixture.diagnostic);
    };
    const descriptor_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    var policy = try DecodedSkillPolicy.init(a, descriptor_bytes);
    defer policy.deinit();
    const ids = try extractCatalogIdentities(a, descriptor_bytes, "forked");
    defer a.free(ids.revision);
    defer a.free(ids.skill_id);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.skill().bindPolicy()(fixture.session, catalog, &policy.policy, &fixture.diagnostic));
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 2;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runSkill(
        fixture.session,
        1,
        sdk.bytesView(ids.skill_id),
        sdk.bytesView(ids.revision),
        sdk.bytesView(""),
        &options,
        &result,
        &fixture.diagnostic,
    ));
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try probe.expect(1, .{ .category = .payment_required, .code = "fork_code", .message = "fork failed", .http_status = 402, .retry = .not_retryable });
}

test "L2 public compact commits a summary and reports COMPACT_COMPACTED" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "compact-model");
    defer fixture.deinit();
    try appendCompactablePublicHistory(&fixture);

    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().compact()(
            fixture.session,
            1,
            &compact_result,
            &fixture.diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.COMPACT_COMPACTED, compact_result.outcome_code);
    try std.testing.expect(compact_result.after_context_tokens < compact_result.before_context_tokens);
    try std.testing.expect(compact_result.input_tokens > 0);
    try std.testing.expect(compact_result.output_tokens > 0);

    const result = try fixture.runText(7, "continue after compact");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 8), server.requestCount());
    const summary_request = server.requestAt(6) orelse return error.NoRequestCaptured;
    const post_compact = server.requestAt(7) orelse return error.NoRequestCaptured;
    const old_context_needle = [_]u8{'A'} ** 128;
    try std.testing.expect(std.mem.indexOf(u8, summary_request.body(), &old_context_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, post_compact.body(), &old_context_needle) == null);
    try std.testing.expect(std.mem.indexOf(u8, post_compact.body(), "Another language model started") != null);
    try std.testing.expect(std.mem.indexOf(u8, post_compact.body(), "done") != null);
}

test "L2 public compact abort is concurrent bounded and leaves the facade reusable" {
    const CompactWorker = struct {
        api: sdk.Api,
        session: *wire.SessionHandle,
        status: u32 = std.math.maxInt(u32),
        result: wire.CompactResultV1 = std.mem.zeroes(wire.CompactResultV1),
        diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },

        fn run(self: *@This()) void {
            self.status = self.api.sessionControl().compact()(
                self.session,
                2,
                &self.result,
                &self.diagnostic,
            );
        }
    };

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "compact-model");
    defer fixture.deinit();
    try appendCompactablePublicHistory(&fixture);

    server.gateNextResponse();
    var worker = CompactWorker{ .api = fixture.api, .session = fixture.session.? };
    const compact_thread = try std.Thread.spawn(.{}, CompactWorker.run, .{&worker});
    var joined = false;
    defer if (!joined) {
        server.releaseGatedResponse();
        compact_thread.join();
    };
    try server.waitUntilResponseGated();

    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        fixture.api.sessionControl().setModel()(
            fixture.session,
            sdk.bytesView("must-not-race-compact"),
            &fixture.diagnostic,
        ),
    );
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().abortCompact()(
            fixture.session,
            2,
            &fixture.diagnostic,
        ),
    );
    server.releaseGatedResponse();
    compact_thread.join();
    joined = true;
    defer fixture.api.bufferRelease()(&worker.diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, worker.status);
    try std.testing.expectEqual(wire.COMPACT_ABORTED, worker.result.outcome_code);
    try std.testing.expectEqual(
        wire.STATUS_TOO_LATE,
        fixture.api.sessionControl().abortCompact()(
            fixture.session,
            2,
            &fixture.diagnostic,
        ),
    );
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().setModel()(
            fixture.session,
            sdk.bytesView("model-after-abort"),
            &fixture.diagnostic,
        ),
    );
}

test "L2 Revision 7 catalog and explicit selection bind before Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "review",
        "---\nname: Review \"quoted\"\ndescription: Public \\ typed invocation fixture\narguments: [target]\n---\nREVIEW_SKILL_SENTINEL $target",
    );
    try writeSkillFixture(
        a,
        root,
        "workctl",
        "---\nname: Workctl\ndescription: Second public typed invocation fixture\narguments: [target]\n---\nWORKCTL_SKILL_SENTINEL $target",
    );
    try writeSkillFixture(
        a,
        root,
        "broken",
        "---\nname: Broken\ncontext: surprise\n---\nBROKEN_SKILL_SENTINEL",
    );
    try writeSkillFixtureInSource(
        a,
        root,
        ".metacodes",
        "metacodes-only",
        "---\nname: Product Legacy\n---\nMUST_NOT_ENTER_AGENTCORE_CATALOG",
    );
    try writeSkillFixtureInSource(
        a,
        root,
        ".claude",
        "claude-only",
        "---\nname: Claude Legacy\n---\nMUST_NOT_ENTER_AGENTCORE_CATALOG",
    );

    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("epoch-1"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    const descriptor_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "\"invocation_name\":\"review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "\"invocation_name\":\"workctl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "metacodes-only") == null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "claude-only") == null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "\"body\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "source_path") == null);
    var decoded = try sdk.decodeSkillCatalog(a, descriptor_bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(sdk.SkillCatalogHealth.degraded, decoded.value.health);
    try std.testing.expectEqual(@as(usize, 1), decoded.value.issues.len);
    try std.testing.expectEqual(
        sdk.SkillCatalogIssueCode.invalid_definition,
        decoded.value.issues[0].code,
    );
    try std.testing.expectEqualStrings(
        "broken",
        decoded.value.issues[0].skill_policy_key.?,
    );
    var found_escaped_review = false;
    for (decoded.value.skills) |skill| {
        if (!std.mem.eql(u8, skill.invocation_name, "review")) continue;
        found_escaped_review = true;
        try std.testing.expectEqualStrings("review", skill.skill_policy_key);
        try std.testing.expectEqualStrings("agents.directory", skill.source.provider_id);
        try std.testing.expectEqual(sdk.SkillSourceScope.workspace, skill.source.source_scope);
        try std.testing.expectEqualStrings("agents.workspace.default", skill.source.source_instance_id);
        try std.testing.expectEqual(@as(usize, 64), skill.source.contribution_id.len);
        try std.testing.expectEqual(@as(usize, 64), skill.content_revision.len);
        try std.testing.expectEqual(@as(usize, 64), skill.skill_id.len);
        try std.testing.expectEqualStrings("Review \"quoted\"", skill.display_name);
        try std.testing.expectEqualStrings(
            "Public \\ typed invocation fixture",
            skill.description,
        );
    }
    try std.testing.expect(found_escaped_review);
    const grant_views = try a.alloc(wire.BytesViewV1, decoded.value.skills.len);
    defer a.free(grant_views);
    for (decoded.value.skills, grant_views) |skill, *grant| grant.* = sdk.bytesView(skill.skill_id);
    var skill_policy = skillPolicy(grant_views);
    const ids = try extractCatalogIdentities(a, descriptor_bytes, "review");
    defer a.free(ids.revision);
    defer a.free(ids.skill_id);
    const workctl_ids = try extractCatalogIdentities(a, descriptor_bytes, "workctl");
    defer a.free(workctl_ids.revision);
    defer a.free(workctl_ids.skill_id);
    try std.testing.expectEqualStrings(ids.revision, workctl_ids.revision);
    try std.testing.expect(!std.mem.eql(u8, ids.skill_id, workctl_ids.skill_id));
    api.bufferRelease()(&descriptor);

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.skill_catalog = catalog;
    host_config.skill_policy = &skill_policy;
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var probe = ReconstructionProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = ReconstructionProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.skill().releaseCatalog()(catalog, &diagnostic));
    catalog = null;
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().bindPolicy()(session, catalog, &skill_policy, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.skill().releaseCatalog()(catalog, &diagnostic));
    catalog = null;
    api.bufferRelease()(&descriptor);

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    const encoded_arguments = try sdk.encodeSkillArguments(
        a,
        &.{"src/main.zig"},
    );
    defer a.free(encoded_arguments);
    const workctl_only = [_]wire.BytesViewV1{sdk.bytesView(workctl_ids.skill_id)};
    var disabled_selection = skillPolicy(&workctl_only);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().bindPolicy()(session, null, &disabled_selection, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_SKILL_POLICY_VIOLATION,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView(encoded_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    var stale_while_denied: [64]u8 = undefined;
    @memcpy(&stale_while_denied, ids.revision);
    stale_while_denied[0] = if (stale_while_denied[0] == '0') '1' else '0';
    try std.testing.expectEqual(
        wire.STATUS_STALE_CATALOG,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(&stale_while_denied),
            sdk.bytesView(encoded_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().bindPolicy()(session, null, &skill_policy, &diagnostic),
    );
    var stale: [64]u8 = undefined;
    @memcpy(&stale, ids.revision);
    stale[0] = if (stale[0] == '0') '1' else '0';
    try std.testing.expectEqual(
        wire.STATUS_STALE_CATALOG,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(&stale),
            sdk.bytesView(""),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_SKILL_ARGUMENTS,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView("{}"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    var noncanonical_empty: u8 = 0;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_SKILL_ARGUMENTS,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            .{ .ptr = @ptrCast(&noncanonical_empty), .len = 0 },
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    const missing_id = [_]u8{'f'} ** 64;
    try std.testing.expectEqual(
        wire.STATUS_SKILL_NOT_FOUND,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(&missing_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView(""),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView(encoded_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runSkill(
            session,
            2,
            sdk.bytesView(workctl_ids.skill_id),
            sdk.bytesView(workctl_ids.revision),
            sdk.bytesView(encoded_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const review_request = server.requestAt(0) orelse return error.NoRequestCaptured;
    const workctl_request = server.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(
        std.mem.indexOf(u8, review_request.body(), "REVIEW_SKILL_SENTINEL") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, review_request.body(), "WORKCTL_SKILL_SENTINEL") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, workctl_request.body(), "WORKCTL_SKILL_SENTINEL") != null,
    );
    try std.testing.expect(!server.captureOverflowed());
}

test "L2 Revision 10 catalog resolves one Workspace authority and rejects reserved query modes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try rootPath(&tmp, &base_buf);
    const home = try std.fs.path.join(a, &.{ base, "home" });
    defer a.free(home);
    const project = try std.fs.path.join(a, &.{ base, "project" });
    defer a.free(project);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, project);
    try writeSkillFixture(
        a,
        home,
        "personal-only",
        "---\nname: Personal Only\n---\nPERSONAL_ONLY_SENTINEL",
    );
    try writeSkillFixture(
        a,
        home,
        "shared",
        "---\nname: Personal Shared\n---\nPERSONAL_SHARED_SENTINEL",
    );
    try writeSkillFixture(
        a,
        project,
        "project-only",
        "---\nname: Project Only\n---\nPROJECT_ONLY_SENTINEL",
    );
    try writeSkillFixture(
        a,
        project,
        "shared",
        "---\nname: Project Shared\n---\nPROJECT_SHARED_SENTINEL",
    );
    try writeSkillFixtureInSource(
        a,
        project,
        ".claude",
        "claude-explicit",
        "---\nname: Explicit Claude-format-compatible Skill\n---\nCLAUDE_EXPLICIT_SENTINEL",
    );
    try writeSkillFixtureInSource(
        a,
        project,
        ".codex",
        "shared",
        "---\nname: Explicit competing Skill\n---\nCODEX_CONFLICT_SENTINEL",
    );

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 1,
        .workspace_root = sdk.bytesView(project),
        .workspace_home = sdk.bytesView(home),
        .workspace_epoch = sdk.bytesView("scope-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    query.reserved0 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    defer if (catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    const effective_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    try std.testing.expect(std.mem.indexOf(u8, effective_bytes, "\"invocation_name\":\"personal-only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, effective_bytes, "\"invocation_name\":\"project-only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, effective_bytes, "Project Shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, effective_bytes, "Personal Shared") == null);
    try std.testing.expect(std.mem.indexOf(u8, effective_bytes, "claude-explicit") == null);

    try std.testing.expectEqual(wire.STATUS_OK, api.skill().releaseCatalog()(catalog, &diagnostic));
    catalog = null;
    api.bufferRelease()(&descriptor);
    const explicit_root = try std.fs.path.join(a, &.{ project, ".claude", "skills" });
    defer a.free(explicit_root);
    var explicit_source = wire.SkillSourceV1{
        .struct_size = @sizeOf(wire.SkillSourceV1),
        .scope_code = wire.SKILL_SOURCE_WORKSPACE,
        .root = sdk.bytesView(explicit_root),
        .source_instance_id = sdk.bytesView("consumer.claude.compatible"),
        .priority = 0,
        .reserved0 = 0,
        .reserved = [_]u64{0} ** 2,
    };
    query.additional_sources = @ptrCast(&explicit_source);
    query.additional_source_count = 1;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    const explicit_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    var explicit_decoded = try sdk.decodeSkillCatalog(a, explicit_bytes);
    defer explicit_decoded.deinit();
    var found_explicit = false;
    for (explicit_decoded.value.skills) |skill| {
        if (!std.mem.eql(u8, skill.invocation_name, "claude-explicit")) continue;
        found_explicit = true;
        try std.testing.expectEqualStrings("agents.directory", skill.source.provider_id);
        try std.testing.expectEqual(sdk.SkillSourceScope.workspace, skill.source.source_scope);
        try std.testing.expectEqualStrings(
            "consumer.claude.compatible",
            skill.source.source_instance_id,
        );
    }
    try std.testing.expect(found_explicit);

    try std.testing.expectEqual(wire.STATUS_OK, api.skill().releaseCatalog()(catalog, &diagnostic));
    catalog = null;
    api.bufferRelease()(&descriptor);
    const conflict_root = try std.fs.path.join(a, &.{ project, ".codex", "skills" });
    defer a.free(conflict_root);
    const conflict_source = wire.SkillSourceV1{
        .struct_size = @sizeOf(wire.SkillSourceV1),
        .scope_code = wire.SKILL_SOURCE_WORKSPACE,
        .root = sdk.bytesView(conflict_root),
        .source_instance_id = sdk.bytesView("consumer.codex.compatible"),
        .priority = 0,
        .reserved0 = 0,
        .reserved = [_]u64{0} ** 2,
    };
    const explicit_sources = [_]wire.SkillSourceV1{ explicit_source, conflict_source };
    query.additional_sources = &explicit_sources;
    query.additional_source_count = explicit_sources.len;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    const conflict_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    var conflict_decoded = try sdk.decodeSkillCatalog(a, conflict_bytes);
    defer conflict_decoded.deinit();
    for (conflict_decoded.value.skills) |skill|
        try std.testing.expect(!std.mem.eql(u8, skill.invocation_name, "shared"));
    var found_conflict = false;
    for (conflict_decoded.value.issues) |issue| {
        if (issue.code != .source_conflict) continue;
        found_conflict = true;
        try std.testing.expectEqual(sdk.SkillCatalogIssueKind.conflict, issue.kind);
        try std.testing.expectEqualStrings("shared", issue.skill_policy_key.?);
    }
    try std.testing.expect(found_conflict);
}

test "L2 Revision 26 Skill source priorities pick the Host's winner through the public ABI (#390)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try rootPath(&tmp, &base_buf);
    const project = try std.fs.path.join(a, &.{ base, "project" });
    defer a.free(project);
    const home = try std.fs.path.join(a, &.{ base, "home" });
    defer a.free(home);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, project);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, home);
    // The issue's layout: `.codex/skills` and `.claude/skills` both define
    // `review`; `zig` and `release` exist in one source each.
    try writeSkillFixtureInSource(a, project, ".codex", "review", "---\nname: Codex Review\n---\nCODEX_REVIEW_SENTINEL");
    try writeSkillFixtureInSource(a, project, ".codex", "zig", "---\nname: Codex Zig\n---\nCODEX_ZIG_SENTINEL");
    try writeSkillFixtureInSource(a, project, ".claude", "review", "---\nname: Claude Review\n---\nCLAUDE_REVIEW_SENTINEL");
    try writeSkillFixtureInSource(a, project, ".claude", "release", "---\nname: Claude Release\n---\nCLAUDE_RELEASE_SENTINEL");
    // The default Workspace source defines `review` too. User sources ranked
    // above every other source still lose to Workspace.
    try writeSkillFixture(a, project, "review", "---\nname: Workspace Default Review\n---\nWORKSPACE_DEFAULT_REVIEW_SENTINEL");
    try writeSkillFixture(a, home, "review", "---\nname: User Default Review\n---\nUSER_DEFAULT_REVIEW_SENTINEL");
    try writeSkillFixtureInSource(a, home, ".claude", "review", "---\nname: User Review\n---\nUSER_REVIEW_SENTINEL");
    const codex_root = try std.fs.path.join(a, &.{ project, ".codex", "skills" });
    defer a.free(codex_root);
    const claude_root = try std.fs.path.join(a, &.{ project, ".claude", "skills" });
    defer a.free(claude_root);
    const user_root = try std.fs.path.join(a, &.{ home, ".claude", "skills" });
    defer a.free(user_root);

    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var sources = [_]wire.SkillSourceV1{
        .{
            .struct_size = @sizeOf(wire.SkillSourceV1),
            .scope_code = wire.SKILL_SOURCE_WORKSPACE,
            .root = sdk.bytesView(codex_root),
            .source_instance_id = sdk.bytesView("consumer.codex"),
            .priority = 0,
            .reserved0 = 0,
            .reserved = [_]u64{0} ** 2,
        },
        .{
            .struct_size = @sizeOf(wire.SkillSourceV1),
            .scope_code = wire.SKILL_SOURCE_WORKSPACE,
            .root = sdk.bytesView(claude_root),
            .source_instance_id = sdk.bytesView("consumer.claude"),
            .priority = 0,
            .reserved0 = 0,
            .reserved = [_]u64{0} ** 2,
        },
        .{
            .struct_size = @sizeOf(wire.SkillSourceV1),
            .scope_code = wire.SKILL_SOURCE_USER,
            .root = sdk.bytesView(user_root),
            .source_instance_id = sdk.bytesView("consumer.user.claude"),
            .priority = std.math.maxInt(i32),
            .reserved0 = 0,
            .reserved = [_]u64{0} ** 2,
        },
    };
    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(project),
        .workspace_home = sdk.bytesView(home),
        .workspace_epoch = sdk.bytesView("priority-epoch"),
        .additional_sources = &sources,
        .additional_source_count = sources.len,
        .default_user_source_priority = std.math.maxInt(i32),
        .default_workspace_source_priority = 0,
    };

    // Without Workspace priorities the three Workspace `review` candidates
    // conflict, as in Revision 25; names unique to one source stay available.
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    {
        const bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
        var decoded = try sdk.decodeSkillCatalog(a, bytes);
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.SkillCatalogHealth.degraded, decoded.value.health);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.issues.len);
        try std.testing.expectEqual(sdk.SkillCatalogIssueCode.source_conflict, decoded.value.issues[0].code);
        try std.testing.expectEqualStrings("review", decoded.value.issues[0].skill_policy_key.?);
        try std.testing.expectEqual(@as(usize, 2), decoded.value.skills.len);
        for (decoded.value.skills) |skill| {
            try std.testing.expect(!std.mem.eql(u8, skill.invocation_name, "review"));
        }
    }
    try std.testing.expectEqual(wire.STATUS_OK, api.skill().releaseCatalog()(catalog, &diagnostic));
    catalog = null;
    api.bufferRelease()(&descriptor);

    // `.claude` ranked above `.codex` and the default Workspace source, which
    // stay tied at 0: its `review` wins, nothing conflicts.
    sources[1].priority = 10;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    const ranked_bytes = try a.dupe(u8, try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len }));
    defer a.free(ranked_bytes);
    var ranked = try DecodedSkillPolicy.init(a, ranked_bytes);
    defer ranked.deinit();
    try std.testing.expectEqual(sdk.SkillCatalogHealth.healthy, ranked.catalog.value.health);
    try std.testing.expectEqual(@as(usize, 0), ranked.catalog.value.issues.len);
    try std.testing.expectEqual(@as(usize, 3), ranked.catalog.value.skills.len);
    const Expected = struct { name: []const u8, source: []const u8, display: []const u8 };
    for ([_]Expected{
        .{ .name = "review", .source = "consumer.claude", .display = "Claude Review" },
        .{ .name = "zig", .source = "consumer.codex", .display = "Codex Zig" },
        .{ .name = "release", .source = "consumer.claude", .display = "Claude Release" },
    }) |expected| {
        var found = false;
        for (ranked.catalog.value.skills) |skill| {
            if (!std.mem.eql(u8, skill.invocation_name, expected.name)) continue;
            found = true;
            try std.testing.expectEqual(sdk.SkillSourceScope.workspace, skill.source.source_scope);
            try std.testing.expectEqualStrings(expected.source, skill.source.source_instance_id);
            try std.testing.expectEqualStrings(expected.display, skill.display_name);
        }
        try std.testing.expect(found);
    }
    api.bufferRelease()(&descriptor);

    // Registration order does not matter: the reversed list resolves to the
    // same descriptor bytes.
    {
        const reversed = [_]wire.SkillSourceV1{ sources[2], sources[1], sources[0] };
        var reversed_query = query;
        reversed_query.additional_sources = &reversed;
        var reversed_catalog: ?*wire.SkillCatalogHandle = null;
        var reversed_descriptor = std.mem.zeroes(wire.OwnedBytesV1);
        defer api.bufferRelease()(&reversed_descriptor);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.skill().resolveCatalog()(runtime, &reversed_query, &reversed_catalog, &reversed_descriptor, &diagnostic),
        );
        defer _ = api.skill().releaseCatalog()(reversed_catalog, &diagnostic);
        try std.testing.expectEqualStrings(
            ranked_bytes,
            try sdk.borrowedBytes(.{ .ptr = reversed_descriptor.ptr, .len = reversed_descriptor.len }),
        );
    }

    // The default Workspace source takes its own priority from the query.
    {
        var default_query = query;
        default_query.default_workspace_source_priority = 11;
        var default_catalog: ?*wire.SkillCatalogHandle = null;
        var default_descriptor = std.mem.zeroes(wire.OwnedBytesV1);
        defer api.bufferRelease()(&default_descriptor);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.skill().resolveCatalog()(runtime, &default_query, &default_catalog, &default_descriptor, &diagnostic),
        );
        defer _ = api.skill().releaseCatalog()(default_catalog, &diagnostic);
        const bytes = try sdk.borrowedBytes(.{ .ptr = default_descriptor.ptr, .len = default_descriptor.len });
        var decoded = try sdk.decodeSkillCatalog(a, bytes);
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.SkillCatalogHealth.healthy, decoded.value.health);
        var found_default = false;
        for (decoded.value.skills) |skill| {
            if (!std.mem.eql(u8, skill.invocation_name, "review")) continue;
            found_default = true;
            try std.testing.expectEqualStrings("agents.workspace.default", skill.source.source_instance_id);
            try std.testing.expectEqualStrings("Workspace Default Review", skill.display_name);
        }
        try std.testing.expect(found_default);
    }

    // The words beside `priority` stay reserved.
    for ([_]u8{ 0, 1 }) |field| {
        if (field == 0) sources[0].reserved0 = 1 else sources[0].reserved[1] = 1;
        var rejected: ?*wire.SkillCatalogHandle = null;
        var rejected_descriptor = std.mem.zeroes(wire.OwnedBytesV1);
        try std.testing.expectEqual(
            wire.STATUS_INVALID_ARGUMENT,
            api.skill().resolveCatalog()(runtime, &query, &rejected, &rejected_descriptor, &diagnostic),
        );
        try std.testing.expectEqual(@as(?*wire.SkillCatalogHandle, null), rejected);
        try std.testing.expectEqual(@as(u64, 0), rejected_descriptor.len);
        api.bufferRelease()(&diagnostic);
        sources[0].reserved0 = 0;
        sources[0].reserved[1] = 0;
    }

    // Authorization and execution use the same winner the descriptor names.
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(project);
    host_config.workspace_home = sdk.bytesView(home);
    host_config.skill_catalog = catalog;
    host_config.skill_policy = &ranked.policy;
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    try std.testing.expectEqual(wire.STATUS_OK, api.skill().releaseCatalog()(catalog, &diagnostic));
    catalog = null;

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    const empty_arguments = try sdk.encodeSkillArguments(a, &.{});
    defer a.free(empty_arguments);
    for ([_][]const u8{ "review", "zig" }, 1..) |name, run_id| {
        const ids = try extractCatalogIdentities(a, ranked_bytes, name);
        defer a.free(ids.revision);
        defer a.free(ids.skill_id);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.session().runSkill(
                session,
                run_id,
                sdk.bytesView(ids.skill_id),
                sdk.bytesView(ids.revision),
                sdk.bytesView(empty_arguments),
                &options,
                &result,
                &diagnostic,
            ),
        );
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    }
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const review_request = (server.requestAt(0) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, review_request, "CLAUDE_REVIEW_SENTINEL") != null);
    try std.testing.expect(std.mem.indexOf(u8, review_request, "CODEX_REVIEW_SENTINEL") == null);
    try std.testing.expect(std.mem.indexOf(u8, review_request, "USER_REVIEW_SENTINEL") == null);
    try std.testing.expect(std.mem.indexOf(u8, review_request, "WORKSPACE_DEFAULT_REVIEW_SENTINEL") == null);
    try std.testing.expect(std.mem.indexOf(u8, review_request, "USER_DEFAULT_REVIEW_SENTINEL") == null);
    const zig_request = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, zig_request, "CODEX_ZIG_SENTINEL") != null);
    try std.testing.expect(!server.captureOverflowed());
}

test "L2 Revision 10 Skill execution pins content and incomplete observation preserves last good binding" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "pinned",
        "---\nname: Pinned\n---\nPINNED_OLD_CONTENT",
    );

    var server = try harness.MockServer.start(FINAL_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("pinned-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var original_catalog: ?*wire.SkillCatalogHandle = null;
    var original_descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&original_descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(
            runtime,
            &query,
            &original_catalog,
            &original_descriptor,
            &diagnostic,
        ),
    );
    const original_bytes = try sdk.borrowedBytes(.{
        .ptr = original_descriptor.ptr,
        .len = original_descriptor.len,
    });
    const original_ids = try extractCatalogIdentities(a, original_bytes, "pinned");
    defer a.free(original_ids.revision);
    defer a.free(original_ids.skill_id);
    var original_policy = try DecodedSkillPolicy.init(a, original_bytes);
    defer original_policy.deinit();
    const original_content_revision = try a.dupe(
        u8,
        original_policy.catalog.value.skills[0].content_revision,
    );
    defer a.free(original_content_revision);

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.skill_catalog = original_catalog;
    host_config.skill_policy = &original_policy.policy;
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().releaseCatalog()(original_catalog, &diagnostic),
    );
    original_catalog = null;
    api.bufferRelease()(&original_descriptor);

    try writeSkillFixture(
        a,
        root,
        "pinned",
        "---\nname: Pinned\n---\nPINNED_NEW_CONTENT",
    );
    var changed_catalog: ?*wire.SkillCatalogHandle = null;
    defer if (changed_catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    var changed_descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&changed_descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(
            runtime,
            &query,
            &changed_catalog,
            &changed_descriptor,
            &diagnostic,
        ),
    );
    const changed_bytes = try sdk.borrowedBytes(.{
        .ptr = changed_descriptor.ptr,
        .len = changed_descriptor.len,
    });
    const changed_ids = try extractCatalogIdentities(a, changed_bytes, "pinned");
    defer a.free(changed_ids.revision);
    defer a.free(changed_ids.skill_id);
    var changed_decoded = try sdk.decodeSkillCatalog(a, changed_bytes);
    defer changed_decoded.deinit();
    try std.testing.expect(!std.mem.eql(u8, original_ids.revision, changed_ids.revision));
    try std.testing.expect(!std.mem.eql(u8, original_ids.skill_id, changed_ids.skill_id));
    try std.testing.expect(!std.mem.eql(
        u8,
        original_content_revision,
        changed_decoded.value.skills[0].content_revision,
    ));
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.skill().bindPolicy()(
            session,
            changed_catalog,
            &original_policy.policy,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);

    const unavailable_source_path = try std.fs.path.join(a, &.{ root, "not-a-directory" });
    defer a.free(unavailable_source_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = unavailable_source_path,
        .data = "provider temporarily unavailable",
    });
    var unavailable_source = wire.SkillSourceV1{
        .struct_size = @sizeOf(wire.SkillSourceV1),
        .scope_code = wire.SKILL_SOURCE_WORKSPACE,
        .root = sdk.bytesView(unavailable_source_path),
        .source_instance_id = sdk.bytesView("temporary.unavailable"),
        .priority = 0,
        .reserved0 = 0,
        .reserved = [_]u64{0} ** 2,
    };
    query.additional_sources = @ptrCast(&unavailable_source);
    query.additional_source_count = 1;
    var incomplete_catalog: ?*wire.SkillCatalogHandle = null;
    var incomplete_descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&incomplete_descriptor);
    try std.testing.expectEqual(
        wire.STATUS_SKILL_CATALOG_INCOMPLETE,
        api.skill().resolveCatalog()(
            runtime,
            &query,
            &incomplete_catalog,
            &incomplete_descriptor,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(?*wire.SkillCatalogHandle, null), incomplete_catalog);
    try std.testing.expectEqual(@as(u64, 0), incomplete_descriptor.len);
    api.bufferRelease()(&diagnostic);

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    const empty_arguments = try sdk.encodeSkillArguments(a, &.{});
    defer a.free(empty_arguments);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(original_ids.skill_id),
            sdk.bytesView(original_ids.revision),
            sdk.bytesView(empty_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    const request = server.requestAt(0) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "PINNED_OLD_CONTENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "PINNED_NEW_CONTENT") == null);
}

test "L2 AgentCore Skill forks cannot override the Session model" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "blocked",
        "---\n" ++
            "name: Blocked\n" ++
            "description: Attempt a forbidden model override\n" ++
            "context: fork\n" ++
            "model: arbitrary-model-id\n" ++
            "---\n" ++
            "BLOCKED_CHILD_MODEL_SENTINEL",
    );

    const bodies = [_][]const u8{
        BLOCKED_MODEL_SKILL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("model-binding-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(
            runtime,
            &query,
            &catalog,
            &descriptor,
            &diagnostic,
        ),
    );
    const descriptor_bytes = try sdk.borrowedBytes(.{
        .ptr = descriptor.ptr,
        .len = descriptor.len,
    });
    const blocked = try extractCatalogIdentities(
        a,
        descriptor_bytes,
        "blocked",
    );
    defer a.free(blocked.revision);
    defer a.free(blocked.skill_id);
    var decoded_policy = try DecodedSkillPolicy.init(a, descriptor_bytes);
    defer decoded_policy.deinit();

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.skill_catalog = catalog;
    host_config.skill_policy = &decoded_policy.policy;
    var session_config = sessionCreateConfig(&host_config, "session-locked-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(
            runtime,
            &session_config,
            &callbacks,
            &session,
            &diagnostic,
        ),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);

    const blocked_status = api.session().runSkill(
        session,
        1,
        sdk.bytesView(blocked.skill_id),
        sdk.bytesView(blocked.revision),
        sdk.bytesView(""),
        &options,
        &result,
        &diagnostic,
    );
    try std.testing.expectEqual(wire.STATUS_SKILL_UNAVAILABLE, blocked_status);
    const rejected_diagnostic = try sdk.borrowedBytes(.{
        .ptr = diagnostic.ptr,
        .len = diagnostic.len,
    });
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            rejected_diagnostic,
            "ModelOverrideUnavailable",
        ) != null,
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("Invoke the blocked Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    for (0..server.requestCount()) |index| {
        const request = server.requestAt(index) orelse
            return error.NoRequestCaptured;
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                request.body(),
                "BLOCKED_CHILD_MODEL_SENTINEL",
            ) == null,
        );
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                request.body(),
                "arbitrary-model-id",
            ) == null,
        );
        try std.testing.expectEqualStrings(
            "\"session-locked-model\"",
            request.jsonField("model").?,
        );
    }
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            server.requestAt(1).?.body(),
            "ModelOverrideUnavailable",
        ) != null,
    );

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            2,
            sdk.bytesView("Continue after the rejected Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try std.testing.expect(!server.captureOverflowed());
}

test "L2 bound catalog executes model Skill and preserves nested policy lineage" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const review_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "review" },
    );
    defer a.free(review_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, review_dir);
    const review_path = try std.fs.path.join(
        a,
        &.{ review_dir, "SKILL.md" },
    );
    defer a.free(review_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = review_path,
        .data = "---\n" ++
            "name: Review\n" ++
            "description: Review a target selected by the model\n" ++
            "model-activation: required-first\n" ++
            "arguments: [target]\n" ++
            "---\n" ++
            "Review $target using the bound snapshot.",
    });

    const hidden_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "private-deploy" },
    );
    defer a.free(hidden_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, hidden_dir);
    const hidden_path = try std.fs.path.join(
        a,
        &.{ hidden_dir, "SKILL.md" },
    );
    defer a.free(hidden_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = hidden_path,
        .data = "---\n" ++
            "name: Hidden Deploy\n" ++
            "description: hidden-deploy-secret\n" ++
            "disable-model-invocation: true\n" ++
            "---\n" ++
            "Never advertise this body.",
    });

    const root_skill_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "root-policy" },
    );
    defer a.free(root_skill_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root_skill_dir);
    const root_skill_path = try std.fs.path.join(
        a,
        &.{ root_skill_dir, "SKILL.md" },
    );
    defer a.free(root_skill_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root_skill_path,
        .data = "---\n" ++
            "name: Root Policy\n" ++
            "description: Narrow the external invocation to Read\n" ++
            "allowed-tools: Read\n" ++
            "---\n" ++
            "Invoke the child Skill, then continue.",
    });

    const child_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "child" },
    );
    defer a.free(child_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, child_dir);
    const child_path = try std.fs.path.join(
        a,
        &.{ child_dir, "SKILL.md" },
    );
    defer a.free(child_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = child_path,
        .data = "---\n" ++
            "name: Child\n" ++
            "description: Nested child with no additional grant\n" ++
            "---\n" ++
            "Child activation body.",
    });

    const fork_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "forked" },
    );
    defer a.free(fork_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fork_dir);
    const fork_path = try std.fs.path.join(
        a,
        &.{ fork_dir, "SKILL.md" },
    );
    defer a.free(fork_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = fork_path,
        .data = "---\n" ++
            "name: Forked\n" ++
            "description: Run a fresh child that may invoke another Skill\n" ++
            "context: fork\n" ++
            "---\n" ++
            "AGENTCORE_FORK_CHILD_SENTINEL Invoke the child Skill and return its result.",
    });

    const bodies = [_][]const u8{
        SKILL_SSE,
        FINAL_SSE,
        SKILL_THEN_GLOB_SSE,
        FINAL_SSE,
        CHILD_SKILL_SSE,
        WRITE_SSE,
        FINAL_SSE,
        HIDDEN_SKILL_SSE,
        FINAL_SSE,
        FORK_SKILL_SSE,
        CHILD_SKILL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    const builtins = [_]wire.BytesViewV1{
        sdk.bytesView("Read"),
        sdk.bytesView("Write"),
        sdk.bytesView("Glob"),
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("model-tool-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(
            runtime,
            &query,
            &catalog,
            &descriptor,
            &diagnostic,
        ),
    );
    const descriptor_bytes = try sdk.borrowedBytes(.{
        .ptr = descriptor.ptr,
        .len = descriptor.len,
    });
    const root_identity = try extractCatalogIdentities(
        a,
        descriptor_bytes,
        "root-policy",
    );
    defer a.free(root_identity.revision);
    defer a.free(root_identity.skill_id);
    var decoded_policy = try DecodedSkillPolicy.init(a, descriptor_bytes);
    defer decoded_policy.deinit();

    const allowed = [_]wire.BytesViewV1{
        sdk.bytesView("Read"),
        sdk.bytesView("Write"),
        sdk.bytesView("Glob"),
    };
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &allowed;
    host_config.allowed_tool_count = allowed.len;
    host_config.skill_catalog = catalog;
    host_config.skill_policy = &decoded_policy.policy;
    var session_config = sessionCreateConfig(&host_config, "glm-5.2");

    var probe = Probe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = Probe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(
            runtime,
            &session_config,
            &callbacks,
            &session,
            &diagnostic,
        ),
    );
    probe.expected_session = session;
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("Use the review Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    try std.testing.expect(probe.saw_tool_start and probe.saw_tool_result and probe.saw_run_state);
    try std.testing.expect(probe.run_state_sequence_valid);
    try std.testing.expect(probe.run_state_invariant_valid);
    try std.testing.expect(probe.run_state_saw_starting and
        probe.run_state_saw_executing_tools and
        probe.run_state_saw_completed and
        probe.run_state_terminal_empty);

    const first_request = server.requestAt(0) orelse
        return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(
        u8,
        first_request.body(),
        "\"tool_choice\":{\"type\":\"tool\",\"name\":\"Skill\"}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        first_request.body(),
        "`review`",
    ) != null);

    const body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, body, "\"name\":\"Skill\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, body, "# Skill: Review") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, body, "Review src/main.zig using the bound snapshot.") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, body, "hidden-deploy-secret") == null,
    );

    probe.expected_run_id = 2;
    options.max_turns = 3;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            2,
            sdk.bytesView("Activate root-policy, then Glob in the same response."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);
    const serial_body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    const serial_result = std.mem.indexOf(u8, serial_body, "tu_serial_glob") orelse
        return error.MissingSerializedToolResult;
    try std.testing.expect(
        std.mem.indexOfPos(
            u8,
            serial_body,
            serial_result,
            "outside the current execution policy",
        ) != null,
    );

    probe.expected_run_id = 3;
    options.max_turns = 5;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runSkill(
            session,
            3,
            sdk.bytesView(root_identity.skill_id),
            sdk.bytesView(root_identity.revision),
            sdk.bytesView(""),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);
    const nested_body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, nested_body, "# Skill: Child") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, nested_body, "outside the current execution policy") != null,
    );
    const blocked_path = try std.fs.path.join(a, &.{ root, "blocked.txt" });
    defer a.free(blocked_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, blocked_path, .{}),
    );

    probe.expected_run_id = 4;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            4,
            sdk.bytesView("Try the hidden Skill name."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    const hidden_body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, hidden_body, "Never advertise this body.") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, hidden_body, "PolicyViolation") != null or
            std.mem.indexOf(u8, hidden_body, "policy_violation") != null,
    );

    probe.expected_run_id = 5;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            5,
            sdk.bytesView("Use the forked Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    const fork_body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, fork_body, "# Skill: Forked (forked)") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, fork_body, "done") != null,
    );
    var found_fork_child = false;
    for (0..server.requestCount()) |index| {
        const request = server.requestAt(index) orelse continue;
        if (std.mem.indexOf(
            u8,
            request.body(),
            "AGENTCORE_FORK_CHILD_SENTINEL",
        ) == null) continue;
        found_fork_child = true;
        try std.testing.expectEqualStrings(
            "\"glm-5.2\"",
            request.jsonField("model").?,
        );
    }
    try std.testing.expect(found_fork_child);
    try std.testing.expect(!server.captureOverflowed());

    const openai_bodies = [_][]const u8{
        OPENAI_SKILL_SSE,
        OPENAI_FINAL_SSE,
    };
    var openai_server = try harness.MockServer.startCassette(
        &openai_bodies,
        0,
    );
    defer openai_server.stop();
    const openai_url = try openai_server.urlOwned(a);
    defer a.free(openai_url);

    host_config.provider_kind_code = wire.PROVIDER_OPENAI;
    host_config.base_url = sdk.bytesView(openai_url);
    var openai_probe = Probe{};
    callbacks.ctx = &openai_probe;
    var openai_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(
            runtime,
            &session_config,
            &callbacks,
            &openai_session,
            &diagnostic,
        ),
    );
    openai_probe.expected_session = openai_session;
    defer if (openai_session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    options.max_turns = 3;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            openai_session,
            1,
            sdk.bytesView("Use review through the OpenAI interface."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    const openai_body = (openai_server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, openai_body, "\"name\":\"Skill\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, openai_body, "# Skill: Review") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            openai_body,
            "Review README.md using the bound snapshot.",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, openai_body, "\"tool_call_id\":\"call_skill\"") != null,
    );

    const responses_fork_bodies = [_][]const u8{
        OPENAI_RESPONSES_REVIEW_SKILL_SSE,
        OPENAI_RESPONSES_FINAL_SSE,
        OPENAI_RESPONSES_FORK_SKILL_SSE,
        OPENAI_RESPONSES_REVIEW_SKILL_SSE,
        OPENAI_RESPONSES_FINAL_SSE,
        OPENAI_RESPONSES_FINAL_SSE,
    };
    var responses_fork_server = try harness.MockServer.startCassette(
        &responses_fork_bodies,
        0,
    );
    defer responses_fork_server.stop();
    const responses_fork_url = try responses_fork_server.urlOwned(a);
    defer a.free(responses_fork_url);

    host_config.protocol_kind_code = wire.OPENAI_PROTOCOL_RESPONSES;
    host_config.base_url = sdk.bytesView(responses_fork_url);
    var responses_fork_probe = Probe{};
    callbacks.ctx = &responses_fork_probe;
    var responses_fork_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(
            runtime,
            &session_config,
            &callbacks,
            &responses_fork_session,
            &diagnostic,
        ),
    );
    responses_fork_probe.expected_session = responses_fork_session;
    defer if (responses_fork_session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    options.max_turns = 5;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            responses_fork_session,
            1,
            sdk.bytesView("Satisfy the required-first review Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    responses_fork_probe.expected_run_id = 2;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            responses_fork_session,
            2,
            sdk.bytesView("Use the forked Skill through Responses."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 6), responses_fork_server.requestCount());
    var found_responses_fork_child = false;
    for (0..responses_fork_server.requestCount()) |index| {
        const request = responses_fork_server.requestAt(index) orelse continue;
        if (std.mem.indexOf(
            u8,
            request.body(),
            "AGENTCORE_FORK_CHILD_SENTINEL",
        ) == null) continue;
        found_responses_fork_child = true;
        try std.testing.expect(std.mem.indexOf(u8, request.body(), "\"input\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, request.body(), "\"messages\":") == null);
        try std.testing.expectEqualStrings(
            "\"glm-5.2\"",
            request.jsonField("model").?,
        );
    }
    try std.testing.expect(found_responses_fork_child);
    try std.testing.expect(!responses_fork_server.captureOverflowed());

    const fatal_bodies = [_][]const u8{
        FORK_SKILL_SSE,
        FINAL_SSE,
    };
    var fatal_server = try harness.MockServer.startCassette(
        &fatal_bodies,
        0,
    );
    defer fatal_server.stop();
    const fatal_url = try fatal_server.urlOwned(a);
    defer a.free(fatal_url);

    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.protocol_kind_code = wire.PROTOCOL_DEFAULT;
    host_config.base_url = sdk.bytesView(fatal_url);
    var fatal_probe = NestedSkillFatalProbe{};
    var fatal_callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    fatal_callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    fatal_callbacks.ctx = &fatal_probe;
    fatal_callbacks.on_event = NestedSkillFatalProbe.event;
    var fatal_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(
            runtime,
            &session_config,
            &fatal_callbacks,
            &fatal_session,
            &diagnostic,
        ),
    );
    defer if (fatal_session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        api.session().runText(
            fatal_session,
            1,
            sdk.bytesView("Run the forked Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expect(fatal_probe.failed);
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_STATE,
        api.session().runText(
            fatal_session,
            2,
            sdk.bytesView("A callback-failed Session stays poisoned."),
            &options,
            &result,
            &diagnostic,
        ),
    );
}

test "L2 opaque ABI routes Host callbacks and enforces Run admission identifiers" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ ASK_SSE, HOST_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var probe = Probe{};
    const builtins = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var host = wire.HostToolV1{
        .struct_size = @sizeOf(wire.HostToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostEcho"),
        .description = sdk.bytesView("Host echo"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
        .execute = Probe.host,
        .release_result = Probe.hostRelease,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = wire.RuntimeConfigV1{
        .struct_size = @sizeOf(wire.RuntimeConfigV1),
        .reserved0 = 0,
        .builtin_tools = &builtins,
        .builtin_tool_count = builtins.len,
        .host_tools = @ptrCast(&host),
        .host_tool_count = 1,
        .mcp_servers = null,
        .mcp_server_count = 0,
        .mcp_catalog_limits = null,
        .enable_teams = 0,
        .reserved = [_]u64{0} ** 3,
    };
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("HostEcho") };
    var host_config = wire.SessionHostConfigV1{
        .struct_size = @sizeOf(wire.SessionHostConfigV1),
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_FULL_ACCESS,
        .shell_policy_code = wire.SHELL_DISABLED,
        .api_key = sdk.bytesView("test-key"),
        .base_url = sdk.bytesView(url),
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .allowed_tools = &allowed,
        .allowed_tool_count = allowed.len,
        .skill_catalog = null,
        .skill_policy = null,
        .permission_rules = null,
        .mcp_selection = null,
        .durable_budget = null,
        .run_journal_mode_code = wire.RUN_JOURNAL_EPHEMERAL,
        .protocol_kind_code = wire.PROTOCOL_DEFAULT,
        .model_capabilities = null,
        .model_capability_count = 0,
        .team = null,
    };
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = wire.SessionCallbacksV1{
        .struct_size = @sizeOf(wire.SessionCallbacksV1),
        .reserved0 = 0,
        .ctx = &probe,
        .on_event = Probe.event,
        .on_ui_request = Probe.ui,
        .release_response = Probe.uiRelease,
        .reserved = [_]u64{0} ** 4,
    };
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic));
    probe.expected_session = session;
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
    }
    try std.testing.expectEqual(wire.STATUS_BUSY, api.runtime().destroy()(runtime, &diagnostic));
    api.bufferRelease()(&diagnostic);

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 5, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.session().abort()(session, 0, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.session().runText(session, 0, sdk.bytesView("zero is not a Run identifier"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    var invalid_utf8: u8 = 0xff;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.session().runText(
            session,
            1,
            .{ .ptr = @ptrCast(&invalid_utf8), .len = wire.MAX_PROMPT_BYTES_V1 + 1 },
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 1, sdk.bytesView("exercise ABI"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.ui_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.ui_releases);
    try std.testing.expectEqual(@as(usize, 1), probe.host_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.host_releases);
    try std.testing.expect(probe.saw_tool_start and probe.saw_tool_result and probe.saw_run_state);
    try std.testing.expect(probe.run_state_saw_waiting_ui);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "Yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "host-ok") != null);
    options.max_turns = wire.MAX_TURNS_V1 + 1;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.session().runText(session, 2, sdk.bytesView("must not start"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    options.max_turns = 5;
    probe.expected_run_id = 2;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 2, sdk.bytesView("run after pre-admission rejection"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.session().abort()(session, 2, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, api.session().abort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.session().runText(session, 2, sdk.bytesView("accepted identifiers cannot be reused"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.session().runText(session, 1, sdk.bytesView("accepted identifiers cannot move backwards"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    probe.expected_run_id = 20;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 20, sdk.bytesView("Run identifiers may skip"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    const max_run_id = std.math.maxInt(u64);
    probe.expected_run_id = max_run_id;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, max_run_id, sdk.bytesView("consume the final Run identifier"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.session().runText(session, max_run_id, sdk.bytesView("UINT64_MAX cannot repeat"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.session().runText(session, 1, sdk.bytesView("UINT64_MAX cannot wrap to a low identifier"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var second_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &session_config, &callbacks, &second_session, &diagnostic));
    defer if (second_session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    probe.expected_session = second_session;
    probe.expected_run_id = max_run_id;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(second_session, max_run_id, sdk.bytesView("Run identifiers are scoped to a Session"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(second_session, &diagnostic));
    second_session = null;

    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 facade gate covers the core-idle epilogue until sessionRun returns" {
    const Barrier = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        seen_run_id: std.atomic.Value(u64) = .init(0),

        fn hook(raw: *anyopaque, run_id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.seen_run_id.store(run_id, .release);
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
        }

        fn wait(self: *@This()) !void {
            // Wall-clock bound (10 s of 1 ms sleeps), not a yield count: a million
            // yields elapse in well under a second when nothing else is runnable,
            // which turns a loaded runner into a spurious EpilogueHookTimeout.
            for (0..10_000) |_| {
                if (self.entered.load(.acquire)) return;
                sync.sleepMs(1);
            }
            return error.EpilogueHookTimeout;
        }
    };
    const RunWorker = struct {
        api: sdk.Api,
        session: *wire.SessionHandle,
        status: u32 = std.math.maxInt(u32),
        result: wire.RunResultV1 = undefined,
        diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },

        fn run(self: *@This()) void {
            var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 1, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
            self.status = self.api.session().runText(self.session, 1, sdk.bytesView("pause in facade epilogue"), &options, &self.result, &self.diagnostic);
        }
    };

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.start(FINAL_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var barrier = Barrier{};
    abi.setTestEpilogueHook(.{ .ctx = &barrier, .runFn = Barrier.hook });
    defer abi.setTestEpilogueHook(null);
    var worker = RunWorker{ .api = api, .session = session.? };
    const run_thread = try std.Thread.spawn(.{}, RunWorker.run, .{&worker});
    var joined = false;
    defer if (!joined) {
        barrier.release.store(true, .release);
        run_thread.join();
    };
    try barrier.wait();
    try std.testing.expectEqual(@as(u64, 1), barrier.seen_run_id.load(.acquire));

    var competing_result: wire.RunResultV1 = undefined;
    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 1, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.session().runText(session, 2, sdk.bytesView("must not enter during epilogue"), &options, &competing_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_BUSY, api.session().destroy()(session, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionControl().setModel()(session, sdk.bytesView(""), &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.skill().bindPolicy()(session, null, null, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionControl().updatePermissionRules()(session, null, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionControl().compact()(session, 0, &compact_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.session().abort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);

    barrier.release.store(true, .release);
    run_thread.join();
    joined = true;
    defer api.bufferRelease()(&worker.diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, worker.status);
    try std.testing.expectEqual(wire.STOP_END_TURN, worker.result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

test "Host registry first identity binding is atomic under concurrent callbacks" {
    const Worker = struct {
        registry: *HostIdentityRegistry,
        session: *wire.SessionHandle,
        session_id: []const u8,
        ready: *std.atomic.Value(u32),
        start: *std.atomic.Value(bool),
        accepted: bool = false,

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .acq_rel);
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            self.accepted = self.registry.accept(self.session, self.session_id);
        }
    };
    const Race = struct {
        fn run(first_id: []const u8, second_id: []const u8) ![2]bool {
            var session_storage: u8 = 0;
            const session: *wire.SessionHandle = @ptrCast(&session_storage);
            var registry = HostIdentityRegistry{};
            var ready = std.atomic.Value(u32).init(0);
            var start = std.atomic.Value(bool).init(false);
            var first = Worker{ .registry = &registry, .session = session, .session_id = first_id, .ready = &ready, .start = &start };
            var second = Worker{ .registry = &registry, .session = session, .session_id = second_id, .ready = &ready, .start = &start };
            const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
            errdefer {
                start.store(true, .release);
                first_thread.join();
            }
            const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
            while (ready.load(.acquire) != 2) std.Thread.yield() catch {};
            start.store(true, .release);
            first_thread.join();
            second_thread.join();
            return .{ first.accepted, second.accepted };
        }
    };

    const id_a = "000000000000000000000001";
    const id_b = "000000000000000000000002";
    for (0..64) |_| {
        const same = try Race.run(id_a, id_a);
        try std.testing.expect(same[0] and same[1]);
        const competing = try Race.run(id_a, id_b);
        try std.testing.expect(competing[0] != competing[1]);
    }
}

test "L2 invalid UTF-8 Host tool result is released and does not poison Session" {
    const FailureProbe = struct {
        calls: usize = 0,
        releases: usize = 0,
        invalid_utf8: [1]u8 = .{0xff},

        fn host(raw: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
            self.calls += 1;
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = &self.invalid_utf8, .len = self.invalid_utf8.len };
            return wire.HOST_OK;
        }

        fn release(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            self.releases += 1;
            if (out) |value| value.* = .{ .ptr = null, .len = 0 };
        }
    };

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var probe = FailureProbe{};
    var host = wire.HostToolV1{
        .struct_size = @sizeOf(wire.HostToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostEcho"),
        .description = sdk.bytesView("Always fail"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
        .execute = FailureProbe.host,
        .release_result = FailureProbe.release,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = @ptrCast(&host);
    runtime_config.host_tool_count = 1;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("HostEcho")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("failure-test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &allowed;
    host_config.allowed_tool_count = allowed.len;
    var session_config = sessionCreateConfig(&host_config, "failure-test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 4, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 1, sdk.bytesView("invoke failing host"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);

    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 2, sdk.bytesView("run again"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Revision 12 public Host stream callback spools byte zero and returns a bounded recoverable envelope" {
    const StreamProbe = struct {
        calls: usize = 0,
        writes: usize = 0,
        max_chunk_bytes: usize = 0,
        releases: usize = 0,

        fn execute(
            raw: ?*anyopaque,
            _: ?*const wire.RunContextV1,
            _: wire.BytesViewV1,
            sink_ptr: ?*const wire.HostResultSinkV1,
            out_media_code: ?*u32,
            out_detail: ?*wire.OwnedBytesV1,
        ) callconv(.c) u32 {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
            const sink = sink_ptr orelse return wire.HOST_FATAL;
            if (sink.struct_size != @sizeOf(wire.HostResultSinkV1) or
                sink.reserved0 != 0 or sink.write == null or
                sink.max_bytes != wire.MAX_HOST_STREAM_ARTIFACT_BYTES_V1)
                return wire.HOST_FATAL;
            const detail = out_detail orelse return wire.HOST_FATAL;
            detail.* = .{ .ptr = null, .len = 0 };
            self.calls += 1;
            var chunk: [64 * 1024]u8 = undefined;
            @memset(&chunk, 'a');
            var remaining: usize = 17 * 1024 * 1024 + 19;
            while (remaining != 0) {
                const count = @min(remaining, chunk.len);
                const status = sink.write.?(sink.ctx, sdk.bytesView(chunk[0..count]));
                if (status != wire.HOST_SINK_OK) return wire.HOST_FAILED;
                self.writes += 1;
                self.max_chunk_bytes = @max(self.max_chunk_bytes, count);
                remaining -= count;
            }
            (out_media_code orelse return wire.HOST_FATAL).* = wire.HOST_STREAM_MEDIA_TEXT_UTF8;
            return wire.HOST_OK;
        }

        fn release(raw: ?*anyopaque, detail: ?*wire.OwnedBytesV1) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            if (detail) |value| {
                if (value.ptr != null or value.len != 0) self.releases += 1;
                value.* = .{ .ptr = null, .len = 0 };
            }
        }
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_STREAM_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var probe = StreamProbe{};
    var stream_tool = wire.HostStreamToolV1{
        .struct_size = @sizeOf(wire.HostStreamToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostStream"),
        .description = sdk.bytesView("Stream without constructing one Host result buffer"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{},\"required\":[]}"),
        .execute_stream = StreamProbe.execute,
        .release_detail = StreamProbe.release,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var plugin_config = std.mem.zeroes(wire.RuntimePluginConfigV1);
    plugin_config.struct_size = @sizeOf(wire.RuntimePluginConfigV1);
    plugin_config.host_stream_tools = @ptrCast(&stream_tool);
    plugin_config.host_stream_tool_count = 1;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(
        &runtime_config,
        &plugin_config,
        &runtime,
        &diagnostic,
    ));
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("HostStream")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("stream-test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &allowed;
    host_config.allowed_tool_count = allowed.len;
    var session_config = sessionCreateConfig(&host_config, "stream-test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(
        runtime,
        &session_config,
        &callbacks,
        &session,
        &diagnostic,
    ));
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = wire.RunOptionsV1{
        .struct_size = @sizeOf(wire.RunOptionsV1),
        .max_turns = 4,
        .context_blocks = null,
        .context_block_count = 0,
        .time_context_code = wire.TIME_CONTEXT_SYSTEM,
        .utc_offset_minutes = 0,
        .reserved = [_]u64{0} ** 1,
    };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(
        session,
        1,
        sdk.bytesView("stream a large result"),
        &options,
        &result,
        &diagnostic,
    ));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.writes > 1);
    try std.testing.expectEqual(@as(usize, 64 * 1024), probe.max_chunk_bytes);
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    const request = server.lastRequest() orelse return error.NoRequestCaptured;
    const body = request.body();
    try std.testing.expect(body.len < 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, body, core.tool_result.PROJECTION_SCHEMA) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ReadArtifact") != null);

    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Revision 12 Host stream failure rolls back partial bytes and releases detail exactly once" {
    const FailureProbe = struct {
        calls: usize = 0,
        releases: usize = 0,

        fn execute(
            raw: ?*anyopaque,
            _: ?*const wire.RunContextV1,
            _: wire.BytesViewV1,
            sink_ptr: ?*const wire.HostResultSinkV1,
            out_media_code: ?*u32,
            out_detail: ?*wire.OwnedBytesV1,
        ) callconv(.c) u32 {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
            const sink = sink_ptr orelse return wire.HOST_FATAL;
            const detail = out_detail orelse return wire.HOST_FATAL;
            const media = out_media_code orelse return wire.HOST_FATAL;
            self.calls += 1;
            media.* = 0;
            if (sink.write.?(sink.ctx, sdk.bytesView("partial-public-abi")) != wire.HOST_SINK_OK)
                return wire.HOST_FATAL;
            const message = "public stream failure";
            detail.* = .{ .ptr = @constCast(message.ptr), .len = message.len };
            return wire.HOST_FAILED;
        }

        fn release(raw: ?*anyopaque, detail: ?*wire.OwnedBytesV1) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            const value = detail orelse return;
            if (value.ptr != null or value.len != 0) self.releases += 1;
            value.* = .{ .ptr = null, .len = 0 };
        }
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_STREAM_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var probe = FailureProbe{};
    var stream_tool = wire.HostStreamToolV1{
        .struct_size = @sizeOf(wire.HostStreamToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostStream"),
        .description = sdk.bytesView("Fail after streaming partial bytes"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{},\"required\":[]}"),
        .execute_stream = FailureProbe.execute,
        .release_detail = FailureProbe.release,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var plugin_config = std.mem.zeroes(wire.RuntimePluginConfigV1);
    plugin_config.struct_size = @sizeOf(wire.RuntimePluginConfigV1);
    plugin_config.host_stream_tools = @ptrCast(&stream_tool);
    plugin_config.host_stream_tool_count = 1;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(
        &runtime_config,
        &plugin_config,
        &runtime,
        &diagnostic,
    ));
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("HostStream")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("stream-failure-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &allowed;
    host_config.allowed_tool_count = allowed.len;
    var session_config = sessionCreateConfig(&host_config, "stream-failure-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(
        runtime,
        &session_config,
        &callbacks,
        &session,
        &diagnostic,
    ));
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = wire.RunOptionsV1{
        .struct_size = @sizeOf(wire.RunOptionsV1),
        .max_turns = 4,
        .context_blocks = null,
        .context_block_count = 0,
        .time_context_code = wire.TIME_CONTEXT_SYSTEM,
        .utc_offset_minutes = 0,
        .reserved = [_]u64{0} ** 1,
    };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(
        session,
        1,
        sdk.bytesView("fail the stream"),
        &options,
        &result,
        &diagnostic,
    ));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    const request = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "public stream failure") != null);
    const digest = core.tool_result_artifact.sha256Hex("partial-public-abi");
    try std.testing.expect(std.mem.indexOf(u8, request.body(), digest[0..]) == null);

    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

test "Revision 12 Host stream descriptors reject missing callbacks and reserved fields" {
    const Stub = struct {
        fn execute(
            _: ?*anyopaque,
            _: ?*const wire.RunContextV1,
            _: wire.BytesViewV1,
            _: ?*const wire.HostResultSinkV1,
            media: ?*u32,
            detail: ?*wire.OwnedBytesV1,
        ) callconv(.c) u32 {
            (media orelse return wire.HOST_FATAL).* = wire.HOST_STREAM_MEDIA_TEXT_UTF8;
            (detail orelse return wire.HOST_FATAL).* = .{ .ptr = null, .len = 0 };
            return wire.HOST_OK;
        }

        fn release(_: ?*anyopaque, detail: ?*wire.OwnedBytesV1) callconv(.c) void {
            if (detail) |value| value.* = .{ .ptr = null, .len = 0 };
        }
    };

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var descriptor = wire.HostStreamToolV1{
        .struct_size = @sizeOf(wire.HostStreamToolV1),
        .reserved0 = 0,
        .ctx = null,
        .name = sdk.bytesView("HostStream"),
        .description = sdk.bytesView("descriptor validation"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{},\"required\":[]}"),
        .execute_stream = Stub.execute,
        .release_detail = Stub.release,
        .reserved = [_]u64{0} ** 2,
    };
    var plugins = std.mem.zeroes(wire.RuntimePluginConfigV1);
    plugins.struct_size = @sizeOf(wire.RuntimePluginConfigV1);
    plugins.host_stream_tools = @ptrCast(&descriptor);
    plugins.host_stream_tool_count = 1;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;

    descriptor.execute_stream = null;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.runtime().create()(
        &runtime_config,
        &plugins,
        &runtime,
        &diagnostic,
    ));
    try std.testing.expect(runtime == null);
    api.bufferRelease()(&diagnostic);

    descriptor.execute_stream = Stub.execute;
    descriptor.release_detail = null;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.runtime().create()(
        &runtime_config,
        &plugins,
        &runtime,
        &diagnostic,
    ));
    try std.testing.expect(runtime == null);
    api.bufferRelease()(&diagnostic);

    descriptor.release_detail = Stub.release;
    descriptor.reserved[0] = 1;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.runtime().create()(
        &runtime_config,
        &plugins,
        &runtime,
        &diagnostic,
    ));
    try std.testing.expect(runtime == null);
}

test "L2 Event callback fatal aborts the Run and poisons the ABI Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("event-fatal-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "event-fatal-model");
    var probe = FatalEventProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = FatalEventProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        api.session().runText(session, 1, sdk.bytesView("fail event delivery"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, api.session().abort()(session, 0, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_STATE,
        api.session().runText(session, 2, sdk.bytesView("must stay poisoned"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Event callback may cooperatively abort without poisoning the ABI Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("event-abort-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "event-abort-model");
    var probe = AbortEventProbe{ .api = api };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = AbortEventProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 1, sdk.bytesView("abort from callback"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, probe.stale_abort_status);
    try std.testing.expectEqual(wire.STATUS_OK, probe.abort_status);
    try std.testing.expectEqual(wire.STOP_ABORTED, result.stop_reason_code);

    probe.calls = 1;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 2, sdk.bytesView("run after abort"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, api.session().abort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.session().abort()(session, 2, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

fn expectUiOutcome(mode: UiFailureMode, expected_releases: usize, expected_status: u32, expected_stop: u32) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ ASK_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    const builtins = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &allowed;
    host_config.allowed_tool_count = allowed.len;
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var probe = UiFailureProbe{ .mode = mode, .api = api };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = acceptEvent;
    callbacks.on_ui_request = UiFailureProbe.ui;
    callbacks.release_response = UiFailureProbe.release;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(expected_status, api.session().runText(session, 1, sdk.bytesView("ask through Host UI"), &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(expected_releases, probe.releases);
    api.bufferRelease()(&diagnostic);
    if (expected_status == wire.STATUS_CALLBACK_FAILED) {
        try std.testing.expectEqual(wire.STATUS_INVALID_STATE, api.session().runText(session, 2, sdk.bytesView("must stay poisoned"), &options, &result, &diagnostic));
        api.bufferRelease()(&diagnostic);
    } else {
        try std.testing.expectEqual(expected_stop, result.stop_reason_code);
        if (mode == .abort_twice) {
            try std.testing.expectEqual(wire.STATUS_BUSY, probe.nested_run_status);
            try std.testing.expectEqual(wire.STATUS_BUSY, probe.nested_destroy_status);
            try std.testing.expectEqual(wire.STATUS_OK, probe.first_abort_status);
            try std.testing.expectEqual(wire.STATUS_OK, probe.second_abort_status);
        }
        try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 2, sdk.bytesView("Session remains reusable"), &options, &result, &diagnostic));
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    }
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Host UI fatal aborts the Run and poisons the ABI Session" {
    try expectUiOutcome(.fatal, 0, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 oversized Host UI response is released and poisons the ABI Session" {
    try expectUiOutcome(.oversized, 1, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 unknown Host UI status poisons the ABI Session" {
    try expectUiOutcome(.unknown, 0, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 unavailable Host UI is a reusable business outcome" {
    try expectUiOutcome(.unavailable, 0, wire.STATUS_OK, wire.STOP_END_TURN);
}

test "L2 cancelled AskQuestion releases Host bytes and leaves the Session reusable" {
    try expectUiOutcome(.cancelled_with_buffer, 1, wire.STATUS_OK, wire.STOP_END_TURN);
}

test "L2 Host UI callback may repeat abort while nested run and destroy stay busy" {
    try expectUiOutcome(.abort_twice, 0, wire.STATUS_OK, wire.STOP_ABORTED);
}

fn expectMappedEventEquals(event: core.protocol.ui_event.CoreEvent, expected: sdk.CoreEvent) !void {
    const mapped = (try abi.protocol_v1.event(std.testing.allocator, event)) orelse return error.UnexpectedInternalOnlyEvent;
    try std.testing.expectEqualDeep(expected, mapped);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, mapped, .{});
    defer std.testing.allocator.free(encoded);
    const parsed = try sdk.decodeCoreEvent(std.testing.allocator, encoded);
    defer parsed.deinit();
    switch (parsed.value) {
        .known => |actual| try std.testing.expectEqualDeep(expected, actual),
        .unknown => return error.UnexpectedUnknownEvent,
    }
}

fn expectOutputSegmentEndMapping(
    disposition: core.output_semantics.Disposition,
    expected_disposition: sdk.OutputSegmentDisposition,
) !void {
    try expectMappedEventEquals(
        .{ .output_segment_end = .{
            .index = 17,
            .turn = 18,
            .group = 19,
            .disposition = disposition,
            .bytes = 20,
        } },
        .{ .output_segment_end = .{
            .index = 17,
            .turn = 18,
            .group = 19,
            .disposition = expected_disposition,
            .bytes = 20,
        } },
    );
}

test "L2 every public AgentCoreEventV1 mapping preserves its complete payload" {
    try expectMappedEventEquals(.{ .text_chunk = "text-sentinel" }, .{ .text_chunk = "text-sentinel" });
    try expectMappedEventEquals(.{ .thinking_chunk = "thinking-sentinel" }, .{ .thinking_chunk = "thinking-sentinel" });
    try expectMappedEventEquals(
        .{ .output_segment_begin = .{ .index = 7, .turn = 8, .group = 9 } },
        .{ .output_segment_begin = .{ .index = 7, .turn = 8, .group = 9 } },
    );
    try expectOutputSegmentEndMapping(.commentary, .commentary);
    try expectOutputSegmentEndMapping(.final, .final);
    try expectOutputSegmentEndMapping(.continued, .continued);
    try expectOutputSegmentEndMapping(.partial, .partial);
    try expectOutputSegmentEndMapping(.discarded, .discarded);
    try expectMappedEventEquals(
        .{ .tool_start = .{ .id = "tool-id", .name = "ToolName", .input = "input-json" } },
        .{ .tool_start = .{ .id = "tool-id", .name = "ToolName", .input = "input-json" } },
    );
    try expectMappedEventEquals(
        .{ .tool_progress = .{ .id = "progress-id", .text = "progress-text" } },
        .{ .tool_progress = .{ .id = "progress-id", .text = "progress-text" } },
    );
    try expectMappedEventEquals(
        .{ .progress = .{ .turn = 11, .tool_name = "ProgressTool", .tool_input = "progress-input", .tool_calls = 22 } },
        .{ .progress = .{ .turn = 11, .tool_name = "ProgressTool", .tool_input = "progress-input", .tool_calls = 22 } },
    );
    try expectMappedEventEquals(
        .{ .tool_result = .{
            .id = "result-id",
            .name = "ResultTool",
            .input = "result-input",
            .content = "result-content",
            .is_error = true,
            .elapsed_ms = 33,
        } },
        .{ .tool_result = .{
            .id = "result-id",
            .name = "ResultTool",
            .input = "result-input",
            .content = "result-content",
            .is_error = true,
            .elapsed_ms = 33,
        } },
    );
    const internal_changes = [_]core.file_change.Record{.{
        .locator = .{ .workspace_path = "src/new.zig" },
        .from_locator = .{ .workspace_path = "src/old.zig" },
        .kind = .moved,
        .status = .partial,
        .tool = "ApplyPatch",
        .tool_use_id = "change-id",
        .agent_depth = 2,
        .before_bytes = 11,
        .after_bytes = 22,
        .unified_diff = "-old\n+new\n",
        .diff_complete = false,
    }};
    const public_changes = [_]sdk.FileChangeRecord{.{
        .locator = .{ .workspace_path = "src/new.zig" },
        .from_locator = .{ .workspace_path = "src/old.zig" },
        .kind = .moved,
        .status = .partial,
        .tool = "ApplyPatch",
        .tool_use_id = "change-id",
        .agent_depth = 2,
        .before_bytes = 11,
        .after_bytes = 22,
        .unified_diff = "-old\n+new\n",
        .diff_complete = false,
    }};
    try expectMappedEventEquals(
        .{ .file_changes = .{
            .id = "change-id",
            .name = "ApplyPatch",
            .changes = &internal_changes,
            .overflow = true,
            .lost = true,
        } },
        .{ .file_changes = .{
            .id = "change-id",
            .name = "ApplyPatch",
            .changes = &public_changes,
            .overflow = true,
            .lost = true,
        } },
    );
    try expectMappedEventEquals(
        .{ .usage = .{
            .input_tokens = 101,
            .output_tokens = 202,
            .cache_read_input_tokens = 303,
            .cache_creation_input_tokens = 404,
        } },
        .{ .usage = .{
            .input_tokens = 101,
            .output_tokens = 202,
            .cache_read_input_tokens = 303,
            .cache_creation_input_tokens = 404,
        } },
    );
    try expectMappedEventEquals(
        .{ .context_warning = .{
            .current_tokens = 1001,
            .warning_threshold = 2002,
            .auto_compact_threshold = 3003,
            .blocking_limit = 4004,
            .level = "warning-level",
        } },
        .{ .context_warning = .{
            .current_tokens = 1001,
            .warning_threshold = 2002,
            .auto_compact_threshold = 3003,
            .blocking_limit = 4004,
            .level = "warning-level",
        } },
    );
    try expectMappedEventEquals(
        .{ .auto_compact = .{
            .dropped = 12,
            .kept = 23,
            .before_tokens = 3400,
            .after_tokens = 4500,
            .cause = "compact-cause",
        } },
        .{ .auto_compact = .{
            .dropped = 12,
            .kept = 23,
            .before_tokens = 3400,
            .after_tokens = 4500,
            .cause = "compact-cause",
        } },
    );
    try expectMappedEventEquals(
        .{ .retry_notice = .{ .attempt = 13, .max = 24, .delay_ms = 3500 } },
        .{ .retry_notice = .{ .attempt = 13, .max = 24, .delay_ms = 3500 } },
    );
    try expectMappedEventEquals(.stream_done, .stream_done);
}

fn expectMappedUiRequestEquals(request: *const core.protocol.ui_request.UiRequest, expected: sdk.UiRequest) !void {
    const encoded = try abi.protocol_v1.encodeUiRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(encoded);
    const parsed = try sdk.decodeUiRequest(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(expected, parsed.value);
}

test "L2 AskUserQuestion mapping is complete and canonical Permission bypasses presentation wire" {
    const options = [_]core.tool_context.AskOption{
        .{ .label = "Yes", .description = "Proceed", .preview = "preview" },
        .{ .label = "No", .description = "Stop" },
    };
    const questions = [_]core.tool_context.AskQuestion{.{
        .question = "Continue?",
        .header = "Choice",
        .multi = false,
        .options = &options,
    }};
    const ask = core.protocol.ui_request.UiRequest{ .ask_question = &questions };
    const permission = core.protocol.ui_request.UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    const custom = core.protocol.ui_request.UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{\"clips\":[]}" } };
    const public_options = [_]sdk.protocol.AskOption{
        .{ .label = "Yes", .description = "Proceed", .preview = "preview" },
        .{ .label = "No", .description = "Stop", .preview = "" },
    };
    const public_questions = [_]sdk.protocol.AskQuestion{.{
        .question = "Continue?",
        .header = "Choice",
        .multi = false,
        .options = &public_options,
    }};
    try expectMappedUiRequestEquals(&ask, .{ .ask_question = &public_questions });
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &permission),
    );
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &custom),
    );
}

const AGENTCORE_PROCESS_TOOL_NAME = "acme_dreview__Echo";

const AGENTCORE_PROCESS_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_process\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_process\",\"name\":\"" ++ AGENTCORE_PROCESS_TOOL_NAME ++ "\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const AGENTCORE_PROCESS_HANDSHAKE =
    "{\"schema\":\"metacodes.plugin-process/v1\",\"operation\":\"handshake\",\"protocol_major\":1," ++
    "\"plugin_id\":\"acme.review\",\"plugin_version\":\"1.0.0\",\"capabilities\":[\"host_tool\"]," ++
    "\"limits\":{\"max_request_frame_bytes\":2048,\"max_response_bytes\":65536},\"cancellation\":\"terminate_process_group\"," ++
    "\"tools\":[{\"name\":\"Echo\",\"description\":\"Echo through the public AgentCore ABI\"," ++
    "\"input_schema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}]}";

const AGENTCORE_PROCESS_RESULT =
    "{\"schema\":\"metacodes.plugin-process/v1\",\"operation\":\"call_result\",\"protocol_major\":1," ++
    "\"plugin_id\":\"acme.review\",\"plugin_version\":\"1.0.0\",\"tool\":\"Echo\"," ++
    "\"status\":\"ok\",\"content\":\"agentcore-process-plugin-ok\"}";

const ProcessPermissionProbe = struct {
    expected_session: ?*wire.SessionHandle = null,
    binding: [64]u8 = undefined,
    binding_len: usize = 0,
    ui_calls: u32 = 0,
    ui_releases: u32 = 0,
    provenance_events: u32 = 0,

    fn validRun(self: *@This(), run_ptr: ?*const wire.RunContextV1) bool {
        const run = sdk.validateRunContext(run_ptr) catch return false;
        return run.session == self.expected_session and run.run_id == 1;
    }

    fn validTool(self: *@This(), tool: sdk.protocol.PermissionTool) bool {
        if (tool.namespace != .host or
            !std.mem.eql(u8, tool.name, AGENTCORE_PROCESS_TOOL_NAME) or
            tool.binding.len != self.binding.len or self.binding_len == 0)
            return false;
        return std.mem.eql(u8, tool.binding, self.binding[0..self.binding_len]);
    }

    fn event(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        if (!self.validRun(run_ptr)) return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const event_value = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (event_value) {
            .permission_provenance => |provenance| {
                if (!self.validTool(provenance.tool) or
                    provenance.source != .callback or
                    provenance.decision != .allow or
                    provenance.response != .allow_once or
                    provenance.used_session_rule)
                    return wire.EVENT_FATAL;
                self.provenance_events += 1;
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        if (!self.validRun(run_ptr)) return wire.UI_FATAL;
        const encoded = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const request = switch (parsed.value) {
            .permission => |value| value,
            else => return wire.UI_FATAL,
        };
        if (request.tool.binding.len != 64 or
            std.mem.allEqual(u8, request.tool.binding, '0') or
            request.candidate != null)
            return wire.UI_FATAL;
        self.binding_len = request.tool.binding.len;
        @memcpy(self.binding[0..self.binding_len], request.tool.binding);
        if (!self.validTool(request.tool)) return wire.UI_FATAL;
        const response_json = sdk.encodeUiResponse(
            std.heap.c_allocator,
            parsed.value,
            .{ .permission = .{
                .permission = .allow_once,
                .request_id = request.request_id,
                .policy_generation = request.policy_generation,
            } },
        ) catch return wire.UI_FATAL;
        const out = out_response orelse {
            std.heap.c_allocator.free(response_json);
            return wire.UI_FATAL;
        };
        out.* = .{ .ptr = response_json.ptr, .len = response_json.len };
        self.ui_calls += 1;
        return wire.UI_ANSWERED;
    }

    fn releaseUi(raw: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.ui_releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }
};

fn createAgentCoreProcessPackage(root: []const u8) !void {
    const allocator = std.testing.allocator;
    const metadata_root = try std.fmt.allocPrint(allocator, "{s}/.metacodes-plugin", .{root});
    defer allocator.free(metadata_root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, metadata_root);

    const script = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\if [ "$1" = "handshake" ]; then
        \\  body='{s}'
        \\else
        \\  : > call.marker
        \\  body='{s}'
        \\fi
        \\printf 'Content-Length: %s\r\n\r\n%s' "${{#body}}" "$body"
        \\
    , .{ AGENTCORE_PROCESS_HANDSHAKE, AGENTCORE_PROCESS_RESULT });
    defer allocator.free(script);
    const entrypoint = try std.fmt.allocPrint(allocator, "{s}/plugin.sh", .{root});
    defer allocator.free(entrypoint);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = entrypoint, .data = script });
    const entrypoint_z = try allocator.dupeZ(u8, entrypoint);
    defer allocator.free(entrypoint_z);
    if (pfs.chmod(entrypoint_z.ptr, 0o700) != 0) return error.SkipZigTest;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/plugin.json", .{metadata_root});
    defer allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = "{\"schema_version\":1,\"id\":\"acme.review\",\"version\":\"1.0.0\",\"capabilities\":[\"host_tool\"]}",
    });
    const process_path = try std.fmt.allocPrint(allocator, "{s}/process.json", .{metadata_root});
    defer allocator.free(process_path);
    const process_json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"protocol_major\":1,\"entrypoint\":\"plugin.sh\",\"sha256\":\"{s}\",\"handshake_timeout_ms\":10000,\"call_timeout_ms\":1000,\"max_response_bytes\":65536}}",
        .{hash},
    );
    defer allocator.free(process_json);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = process_path, .data = process_json });
}

test "L2 Revision 10 independent Host loads a pinned process tool through AgentCore" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    try createAgentCoreProcessPackage(root);

    const bodies = [_][]const u8{ AGENTCORE_PROCESS_TOOL_SSE, FINAL_SSE };
    var provider = try harness.MockServer.startCassette(&bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(allocator);
    defer allocator.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    const process_sources = [_]wire.ProcessPluginSourceV1{.{
        .struct_size = @sizeOf(wire.ProcessPluginSourceV1),
        .layer_code = wire.PLUGIN_LAYER_SESSION,
        .root = sdk.bytesView(root),
        .reserved = [_]u64{0} ** 3,
    }};
    var plugin_config = wire.RuntimePluginConfigV1{
        .struct_size = @sizeOf(wire.RuntimePluginConfigV1),
        .reserved0 = 0,
        .process_plugins = &process_sources,
        .process_plugin_count = process_sources.len,
        .host_stream_tools = null,
        .host_stream_tool_count = 0,
        .reserved = [_]u64{0} ** 4,
    };
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(
            &runtime_config,
            &plugin_config,
            &runtime,
            &diagnostic,
        ),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var permission_probe = ProcessPermissionProbe{};
    const allowed = [_]wire.BytesViewV1{sdk.bytesView(AGENTCORE_PROCESS_TOOL_NAME)};
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.allowed_tools = &allowed;
    host.allowed_tool_count = allowed.len;
    var session_config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &permission_probe;
    callbacks.on_event = ProcessPermissionProbe.event;
    callbacks.on_ui_request = ProcessPermissionProbe.ui;
    callbacks.release_response = ProcessPermissionProbe.releaseUi;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(
            runtime,
            &session_config,
            &callbacks,
            &session,
            &diagnostic,
        ),
    );
    permission_probe.expected_session = session;
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 4;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            1,
            sdk.bytesView("call the configured process plugin"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), permission_probe.ui_calls);
    try std.testing.expectEqual(@as(u32, 1), permission_probe.ui_releases);
    try std.testing.expectEqual(@as(u32, 1), permission_probe.provenance_events);
    const last_body = (provider.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, last_body, AGENTCORE_PROCESS_TOOL_NAME) != null);
    try std.testing.expect(std.mem.indexOf(u8, last_body, "agentcore-process-plugin-ok") != null);
    const marker = try std.fmt.allocPrint(allocator, "{s}/call.marker", .{root});
    defer allocator.free(marker);
    try std.Io.Dir.cwd().access(std.testing.io, marker, .{});
}

test "Revision 10 process plugin descriptors fail closed before staging" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime != null);
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
    api.bufferRelease()(&diagnostic);

    var empty_plugins = std.mem.zeroes(wire.RuntimePluginConfigV1);
    empty_plugins.struct_size = @sizeOf(wire.RuntimePluginConfigV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, &empty_plugins, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime != null);
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().destroy()(runtime, &diagnostic));
    runtime = null;
    api.bufferRelease()(&diagnostic);

    var source = wire.ProcessPluginSourceV1{
        .struct_size = @sizeOf(wire.ProcessPluginSourceV1),
        .layer_code = wire.PLUGIN_LAYER_SESSION,
        .root = sdk.bytesView("relative/package"),
        .reserved = [_]u64{0} ** 3,
    };
    var plugins = wire.RuntimePluginConfigV1{
        .struct_size = @sizeOf(wire.RuntimePluginConfigV1),
        .reserved0 = 0,
        .process_plugins = @ptrCast(&source),
        .process_plugin_count = 1,
        .host_stream_tools = null,
        .host_stream_tool_count = 0,
        .reserved = [_]u64{0} ** 4,
    };
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.runtime().create()(&runtime_config, &plugins, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    api.bufferRelease()(&diagnostic);

    source.root = sdk.bytesView("/absolute/but/not-observed");
    source.layer_code = 0;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.runtime().create()(&runtime_config, &plugins, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    api.bufferRelease()(&diagnostic);

    source.layer_code = wire.PLUGIN_LAYER_SESSION;
    source.reserved[0] = 1;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.runtime().create()(&runtime_config, &plugins, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    api.bufferRelease()(&diagnostic);

    source.reserved[0] = 0;
    plugins.process_plugin_count = wire.MAX_PROCESS_PLUGIN_SOURCES_V1 + 1;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.runtime().create()(&runtime_config, &plugins, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
}

fn submitMultimodal(
    fixture: *PublicSessionFixture,
    run_id: u64,
    parts: []const wire.RunInputPartV1,
    out_result: *wire.RunResultV1,
) u32 {
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    out_result.* = std.mem.zeroes(wire.RunResultV1);
    return fixture.api.session().runMultimodal(
        fixture.session,
        run_id,
        parts,
        &options,
        out_result,
        &fixture.diagnostic,
    );
}

test "L2 Revision 15 multimodal Run carries ordered image parts into the provider request and survives checkpoint restore" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{ FINAL_SSE, FINAL_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    var create = sessionCreateConfig(&host, "claude-vision-fixture");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    const parts = [_]wire.RunInputPartV1{
        sdk.textPart("leading-part"),
        sdk.imagePart("image/png", "UE5HREFUQQ=="),
        sdk.textPart("trailing-part"),
    };
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runMultimodal(session, 1, &parts, &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    {
        const request = server.lastRequest() orelse return error.MissingRequest;
        const body = request.body();
        const image_wire =
            "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"UE5HREFUQQ==\"}}";
        const leading = std.mem.indexOf(u8, body, "leading-part") orelse return error.MissingTextPart;
        const image = std.mem.indexOf(u8, body, image_wire) orelse return error.MissingImagePart;
        const trailing = std.mem.indexOf(u8, body, "trailing-part") orelse return error.MissingTextPart;
        try std.testing.expect(leading < image and image < trailing);
    }

    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&restore_report);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().restore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );

    var continued = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(
            session,
            2,
            sdk.bytesView("continue after restore"),
            &options,
            &continued,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, continued.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    {
        // The restored Conversation resends the original image bytes: the
        // checkpoint block-tag-5 round trip is observable at the provider wire.
        const request = server.lastRequest() orelse return error.MissingRequest;
        const body = request.body();
        try std.testing.expect(std.mem.indexOf(u8, body, "UE5HREFUQQ==") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
    }
}

test "L2 Revision 15 image capability preflight rejects before any Provider request and keeps the Run id reusable (unknown since Revision 21)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    // Nothing - no Host declaration, catalog, or model family - says
    // "test-model" takes images: refused as unknown, not as unsupported.
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();

    const with_image = [_]wire.RunInputPartV1{
        sdk.textPart("describe this"),
        sdk.imagePart("image/png", "UE5HREFUQQ=="),
    };
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN,
        submitMultimodal(&fixture, 1, &with_image, &result),
    );
    const refusal = try sdk.borrowedBytes(.{ .ptr = fixture.diagnostic.ptr, .len = fixture.diagnostic.len });
    try std.testing.expect(std.mem.indexOf(u8, refusal, "model_capabilities") != null);
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
    try expectImageInputDescription(&fixture, false, .unknown);

    // Text-only multimodal input needs no image capability, and the rejected
    // Run was never admitted, so the same Run id remains usable.
    const text_only = [_]wire.RunInputPartV1{sdk.textPart("plain multimodal text")};
    try std.testing.expectEqual(
        wire.STATUS_OK,
        submitMultimodal(&fixture, 1, &text_only, &result),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "L2 Revision 15 image preflight admits a non-Claude vision model on the Anthropic Messages route (issue #112)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    // provider_kind=anthropic only selects the Anthropic Messages wire format;
    // gpt-5.6-sol is a verified vision family, so the preflight must not reject
    // it for lacking "claude" in its name (issue #112).
    var fixture = try PublicSessionFixture.init(root, url, "gpt-5.6-sol");
    defer fixture.deinit();

    const with_image = [_]wire.RunInputPartV1{
        sdk.textPart("describe this"),
        sdk.imagePart("image/png", "UE5HREFUQQ=="),
    };
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        submitMultimodal(&fixture, 1, &with_image, &result),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());

    // The image reaches the provider in the Anthropic base64 image source form,
    // not dropped, OCR'd, or downgraded to text.
    const request = server.lastRequest() orelse return error.MissingRequest;
    const body = request.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5.6-sol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "UE5HREFUQQ==") != null);
}

fn modelCapability(model: []const u8, image_input_code: u32) wire.ModelCapabilityV1 {
    return .{
        .struct_size = @sizeOf(wire.ModelCapabilityV1),
        .image_input_code = image_input_code,
        .model = sdk.bytesView(model),
        .reserved = [_]u64{0} ** 2,
    };
}

/// The Session description's typed `image_input`, through the SDK decoder.
fn expectImageInputDescription(
    fixture: *PublicSessionFixture,
    supported: bool,
    source: sdk.protocol.ImageInputSource,
) !void {
    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().describe()(fixture.session, &description, &fixture.diagnostic),
    );
    defer fixture.api.bufferRelease()(&description);
    const json = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    var parsed = try sdk.protocol.decodeSessionDescription(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(supported, parsed.value.image_input.supported);
    try std.testing.expectEqual(source, parsed.value.image_input.source);
}

const ISSUE_273_IMAGE = "SVNTVUUtMjczLUlNQUdF";

test "L2 Revision 21 a Host declaration admits a model no family knows, and the provider receives the whole image (issue #273)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    // The name is in no built-in family; only the Host knows its route takes
    // images. AgentCore itself is not changed to admit it.
    const capabilities = [_]wire.ModelCapabilityV1{modelCapability("Vendor-Vision-1", wire.CAPABILITY_SUPPORTED)};
    var fixture = try PublicSessionFixture.initCapabilities(root, url, "vendor-vision-1", wire.PROVIDER_ANTHROPIC, wire.PROTOCOL_DEFAULT, &capabilities);
    defer fixture.deinit();
    try expectImageInputDescription(&fixture, true, .host);

    const with_image = [_]wire.RunInputPartV1{
        sdk.textPart("describe this"),
        sdk.imagePart("image/png", ISSUE_273_IMAGE),
    };
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, submitMultimodal(&fixture, 1, &with_image, &result));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    // The image travels as an image block: not dropped, not text.
    const body = (server.lastRequest() orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ISSUE_273_IMAGE) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "was read successfully but omitted") == null);
}

test "L2 Revision 21 a Host 'unsupported' outranks the model family, and a known text family is unsupported, not unknown (issue #273)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const with_image = [_]wire.RunInputPartV1{
        sdk.textPart("describe this"),
        sdk.imagePart("image/png", ISSUE_273_IMAGE),
    };
    var result = std.mem.zeroes(wire.RunResultV1);

    // The family table says Claude takes images; this Host's route does not.
    const capabilities = [_]wire.ModelCapabilityV1{modelCapability("claude-sonnet-4-6", wire.CAPABILITY_UNSUPPORTED)};
    var declared = try PublicSessionFixture.initCapabilities(root, url, "claude-sonnet-4-6", wire.PROVIDER_ANTHROPIC, wire.PROTOCOL_DEFAULT, &capabilities);
    defer declared.deinit();
    try std.testing.expectEqual(wire.STATUS_IMAGE_INPUT_UNSUPPORTED, submitMultimodal(&declared, 1, &with_image, &result));
    const by_host = try sdk.borrowedBytes(.{ .ptr = declared.diagnostic.ptr, .len = declared.diagnostic.len });
    try std.testing.expect(std.mem.indexOf(u8, by_host, "declared by the Host") != null);
    declared.releaseDiagnostic();
    try expectImageInputDescription(&declared, false, .host);

    // A family the table knows to be text-only answers "unsupported" itself.
    var family = try PublicSessionFixture.init(root, url, "claude-2.1");
    defer family.deinit();
    try std.testing.expectEqual(wire.STATUS_IMAGE_INPUT_UNSUPPORTED, submitMultimodal(&family, 1, &with_image, &result));
    family.releaseDiagnostic();
    try expectImageInputDescription(&family, false, .model_family);

    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
}

test "L2 Revision 21 a remote that rejects a declared image is a provider error after the image was sent (issue #273)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startRepeatingStatus(
        "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"this model does not accept images\"}}",
        "HTTP/1.1 400 Bad Request",
        "",
    );
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    // The Host said yes and was wrong: the refusal is the provider's, carried
    // by the Run's stop reason, never re-labelled as a local capability status.
    const capabilities = [_]wire.ModelCapabilityV1{modelCapability("vendor-vision-1", wire.CAPABILITY_SUPPORTED)};
    var fixture = try PublicSessionFixture.initCapabilities(root, url, "vendor-vision-1", wire.PROVIDER_ANTHROPIC, wire.PROTOCOL_DEFAULT, &capabilities);
    defer fixture.deinit();
    const with_image = [_]wire.RunInputPartV1{
        sdk.textPart("describe this"),
        sdk.imagePart("image/png", ISSUE_273_IMAGE),
    };
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, submitMultimodal(&fixture, 1, &with_image, &result));
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);
    try std.testing.expect(server.requestCount() >= 1);
    const body = (server.lastRequest() orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, body, ISSUE_273_IMAGE) != null);
}

test "L2 Revision 21 MiniMax-M3 takes images over the OpenAI Chat Completions route without a declaration (issue #273)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{OPENAI_FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var fixture = try PublicSessionFixture.initProvider(root, url, "MiniMax-M3", wire.PROVIDER_OPENAI, wire.PROTOCOL_DEFAULT);
    defer fixture.deinit();
    try expectImageInputDescription(&fixture, true, .model_family);
    const with_image = [_]wire.RunInputPartV1{
        sdk.textPart("describe this"),
        sdk.imagePart("image/png", ISSUE_273_IMAGE),
    };
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, submitMultimodal(&fixture, 1, &with_image, &result));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    const body = (server.lastRequest() orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image_url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/png;base64," ++ ISSUE_273_IMAGE) != null);
}

test "L2 Revision 21 set_model keeps the Host's declarations, and an OpenAI route honours them (issue #273)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{OPENAI_FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const capabilities = [_]wire.ModelCapabilityV1{modelCapability("vendor-vision-2", wire.CAPABILITY_SUPPORTED)};
    var fixture = try PublicSessionFixture.initCapabilities(root, url, "vendor-text-1", wire.PROVIDER_OPENAI, wire.PROTOCOL_DEFAULT, &capabilities);
    defer fixture.deinit();
    const with_image = [_]wire.RunInputPartV1{
        sdk.textPart("describe this"),
        sdk.imagePart("image/png", ISSUE_273_IMAGE),
    };
    var result = std.mem.zeroes(wire.RunResultV1);
    // The Session's own model is undeclared and unknown.
    try std.testing.expectEqual(wire.STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN, submitMultimodal(&fixture, 1, &with_image, &result));
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionControl().setModel()(fixture.session, sdk.bytesView("vendor-vision-2"), &fixture.diagnostic),
    );
    try expectImageInputDescription(&fixture, true, .host);
    try std.testing.expectEqual(wire.STATUS_OK, submitMultimodal(&fixture, 1, &with_image, &result));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    const body = (server.lastRequest() orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"vendor-vision-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/png;base64," ++ ISSUE_273_IMAGE) != null);
}

test "Revision 21 Host capability declarations are validated before a Session exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime: ?*wire.RuntimeHandle = null;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer _ = api.runtime().destroy()(runtime, &diagnostic);

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView("http://127.0.0.1:1");
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var config = sessionCreateConfig(&host, "test-model");

    const Case = struct { entries: []const wire.ModelCapabilityV1, pointer: bool = true, count: ?u64 = null, status: u32 };
    const long_name = "m" ** (wire.MAX_MODEL_CAPABILITY_MODEL_BYTES_V1 + 1);
    var with_reserved = modelCapability("m", wire.CAPABILITY_SUPPORTED);
    with_reserved.reserved[1] = 1;
    var short_struct = modelCapability("m", wire.CAPABILITY_SUPPORTED);
    short_struct.struct_size -= 8;
    var many: [wire.MAX_MODEL_CAPABILITIES_V1 + 1]wire.ModelCapabilityV1 = undefined;
    var many_names: [wire.MAX_MODEL_CAPABILITIES_V1 + 1][8]u8 = undefined;
    for (&many, &many_names, 0..) |*entry, *name, i| {
        const printed = try std.fmt.bufPrint(name, "m{d}", .{i});
        entry.* = modelCapability(printed, wire.CAPABILITY_SUPPORTED);
    }
    const one = [_]wire.ModelCapabilityV1{modelCapability("m", wire.CAPABILITY_SUPPORTED)};
    const cases = [_]Case{
        // Same model twice, ignoring case: ambiguous, never resolved by order.
        .{ .entries = &.{ modelCapability("Vendor-M", wire.CAPABILITY_SUPPORTED), modelCapability("vendor-m", wire.CAPABILITY_UNSUPPORTED) }, .status = wire.STATUS_INVALID_ARGUMENT },
        // Zero is not a declaration; unknown codes are refused.
        .{ .entries = &.{modelCapability("m", 0)}, .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .entries = &.{modelCapability("m", 3)}, .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .entries = &.{modelCapability("", wire.CAPABILITY_SUPPORTED)}, .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .entries = &.{with_reserved}, .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .entries = &.{short_struct}, .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .entries = &.{modelCapability(long_name, wire.CAPABILITY_SUPPORTED)}, .status = wire.STATUS_RESOURCE_LIMIT },
        .{ .entries = &many, .status = wire.STATUS_RESOURCE_LIMIT },
        // A pointer with no count, and a count with no pointer.
        .{ .entries = &one, .count = 0, .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .entries = &one, .pointer = false, .status = wire.STATUS_INVALID_ARGUMENT },
    };
    for (cases) |case| {
        host.model_capabilities = if (case.pointer) case.entries.ptr else null;
        host.model_capability_count = case.count orelse case.entries.len;
        var session: ?*wire.SessionHandle = null;
        try std.testing.expectEqual(case.status, api.session().create()(runtime, &config, &callbacks, &session, &diagnostic));
        try std.testing.expect(session == null);
        api.bufferRelease()(&diagnostic);
    }
}

test "Revision 15 multimodal wire validation bounds every length before payload access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var fixture = try PublicSessionFixture.init(root, "http://127.0.0.1:1", "claude-vision-fixture");
    defer fixture.deinit();
    var result = std.mem.zeroes(wire.RunResultV1);

    // TEXT and SKILL kinds must keep parts null with zero count.
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    const stray_part = [_]wire.RunInputPartV1{sdk.textPart("stray")};
    var text_with_parts = std.mem.zeroes(wire.RunInputV1);
    text_with_parts.struct_size = @sizeOf(wire.RunInputV1);
    text_with_parts.kind_code = wire.RUN_INPUT_TEXT;
    text_with_parts.text = sdk.bytesView("prompt");
    text_with_parts.parts = &stray_part;
    text_with_parts.part_count = stray_part.len;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        fixture.api.session().runInput()(
            fixture.session,
            1,
            &text_with_parts,
            &options,
            &result,
            &fixture.diagnostic,
        ),
    );
    fixture.releaseDiagnostic();

    // Empty parts arrays are malformed wire, not an empty prompt.
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        submitMultimodal(&fixture, 1, &.{}, &result),
    );
    fixture.releaseDiagnostic();

    // Part-count and payload caps reject with null payload pointers, proving
    // the declared lengths are bounded before any pointer is dereferenced.
    var too_many: [65]wire.RunInputPartV1 = undefined;
    for (&too_many) |*part| part.* = sdk.textPart("x");
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        submitMultimodal(&fixture, 1, &too_many, &result),
    );
    fixture.releaseDiagnostic();

    var oversized_image = sdk.imagePart("image/png", "");
    oversized_image.data = .{ .ptr = null, .len = wire.MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1 + 4 };
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        submitMultimodal(&fixture, 1, &.{oversized_image}, &result),
    );
    fixture.releaseDiagnostic();

    var oversized_total: [4]wire.RunInputPartV1 = undefined;
    for (&oversized_total) |*part| {
        part.* = sdk.imagePart("image/png", "");
        part.data = .{ .ptr = null, .len = 4_500_000 };
    }
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        submitMultimodal(&fixture, 1, &oversized_total, &result),
    );
    fixture.releaseDiagnostic();

    // Semantic part validation: allowlisted media type, standard base64,
    // non-empty text, exact per-kind canonical-empty fields.
    const cases = [_]wire.RunInputPartV1{
        sdk.imagePart("image/tiff", "UE5HREFUQQ=="),
        sdk.imagePart("image/png", "not base64!!"),
        sdk.imagePart("image/png", "UE5HREFUQQ="),
        sdk.textPart(""),
        blk: {
            var part = sdk.imagePart("image/png", "UE5HREFUQQ==");
            part.text = sdk.bytesView("text on an image part");
            break :blk part;
        },
        blk: {
            var part = sdk.textPart("wrong size");
            part.struct_size = @sizeOf(wire.RunInputPartV1) - 8;
            break :blk part;
        },
        blk: {
            var part = sdk.textPart("reserved");
            part.reserved[1] = 7;
            break :blk part;
        },
        blk: {
            var part = sdk.textPart("unknown kind");
            part.kind_code = 99;
            break :blk part;
        },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            wire.STATUS_INVALID_ARGUMENT,
            submitMultimodal(&fixture, 1, &.{case}, &result),
        );
        fixture.releaseDiagnostic();
    }
}

test "L2 Revision 15 multimodal root input reserves its durable delta before admission" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var fixture = try PublicSessionFixture.init(root, "http://127.0.0.1:1", "claude-vision-fixture");
    defer fixture.deinit();

    // Two well-formed 4.8 MB base64 images pass every wire cap (per image
    // < 5,000,000; total < 16 MiB) but exceed the default 8 MiB durable input
    // cap, so the exact multimodal reservation must reject before admission.
    const image_bytes = try a.alloc(u8, 4_800_000);
    defer a.free(image_bytes);
    @memset(image_bytes, 'A');
    const parts = [_]wire.RunInputPartV1{
        sdk.imagePart("image/png", image_bytes),
        sdk.imagePart("image/jpeg", image_bytes),
    };
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
        submitMultimodal(&fixture, 1, &parts, &result),
    );
    try std.testing.expectEqual(
        wire.RUN_CHECKPOINT_BUDGET_REQUIRED,
        result.checkpoint_outcome_code,
    );
    fixture.releaseDiagnostic();
}

test "L2 Revision 15 multimodal Run reaches OpenAI Responses under a non-Anthropic model name and durable accounting" {
    // Regression: the durable-budget canonical request measurement serializes a
    // provider-neutral Anthropic projection. It must never re-apply per-model
    // image capability, or a vision model whose name lacks "claude" (every
    // OpenAI/Gemini model) fails accounting before the real request is sent.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{OPENAI_RESPONSES_FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.initProviderConfigured(
        root,
        url,
        "gpt-5.2",
        null,
        wire.RUN_JOURNAL_DURABLE_WORKSPACE,
        wire.PROVIDER_OPENAI,
        wire.OPENAI_PROTOCOL_RESPONSES,
        &.{},
    );
    defer fixture.deinit();
    const parts = [_]wire.RunInputPartV1{
        sdk.textPart("describe the attached icon"),
        sdk.imagePart("image/png", "aWNvbi1ieXRlcw=="),
    };
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        submitMultimodal(&fixture, 1, &parts, &result),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    const request = server.lastRequest() orelse return error.MissingRequest;
    const body = request.body();
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,aWNvbi1ieXRlcw==\"}",
    ) != null);
}

/// PR #46 review F2:skill Run 在 activation 期间被 abort 时,以 `SkillExecution.aborted`
/// **成功返回**,循环从未启动、没有 run_done —— facade 必须自己把已经发出 `starting`
/// 的 RunState 关成 `aborted`,否则 Host 观测到的 Run 永远停在 `starting`。
const SkillAbortAtStartingProbe = struct {
    api: sdk.Api,
    expected_run_id: u64,
    abort_status: u32 = std.math.maxInt(u32),
    saw_starting: bool = false,
    saw_terminal_aborted: bool = false,
    saw_other_terminal: bool = false,
    snapshots_after_terminal: usize = 0,
    last_seq: u64 = 0,
    sequence_valid: bool = true,

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *SkillAbortAtStartingProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known| switch (known) {
                .run_state => |state| {
                    if (state.run_id != self.expected_run_id) return wire.EVENT_CONTINUE;
                    if (state.transition_seq != self.last_seq + 1) self.sequence_valid = false;
                    self.last_seq = state.transition_seq;
                    if (self.saw_terminal_aborted or self.saw_other_terminal) self.snapshots_after_terminal += 1;
                    switch (state.phase) {
                        .starting => {
                            if (self.saw_starting) return wire.EVENT_CONTINUE;
                            self.saw_starting = true;
                            // 在 `starting` 快照里就 abort:activation 一结束,skill 路径
                            // 会命中 isAborted() 直接返回 .aborted,不经过 agent loop。
                            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
                            self.abort_status = self.api.session().abort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
                            self.api.bufferRelease()(&diagnostic);
                        },
                        .aborted => self.saw_terminal_aborted = true,
                        .completed, .failed, .poisoned => self.saw_other_terminal = true,
                        else => {},
                    }
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }
};

test "L2 RunState: a Skill aborted during activation still closes run_state as aborted (PR #46 review F2)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "review",
        "---\nname: Review\ndescription: RunState closure fixture\narguments: [target]\n---\nREVIEW_SKILL_SENTINEL $target",
    );

    // 不会有任何 provider 请求:abort 在 activation 阶段命中,循环从未启动。
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("epoch-1"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.skill().resolveCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    const descriptor_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    var decoded = try sdk.decodeSkillCatalog(a, descriptor_bytes);
    defer decoded.deinit();
    const grant_views = try a.alloc(wire.BytesViewV1, decoded.value.skills.len);
    defer a.free(grant_views);
    for (decoded.value.skills, grant_views) |skill, *grant| grant.* = sdk.bytesView(skill.skill_id);
    var skill_policy = skillPolicy(grant_views);
    const ids = try extractCatalogIdentities(a, descriptor_bytes, "review");
    defer a.free(ids.revision);
    defer a.free(ids.skill_id);

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.skill_catalog = catalog;
    host_config.skill_policy = &skill_policy;
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var probe = SkillAbortAtStartingProbe{ .api = api, .expected_run_id = 1 };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = SkillAbortAtStartingProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &session_config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    try std.testing.expectEqual(wire.STATUS_OK, api.skill().bindPolicy()(session, catalog, &skill_policy, &diagnostic));

    const encoded_arguments = try sdk.encodeSkillArguments(a, &.{"src/main.zig"});
    defer a.free(encoded_arguments);
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView(encoded_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STATUS_OK, probe.abort_status);
    try std.testing.expectEqual(wire.STOP_ABORTED, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
    try std.testing.expect(probe.saw_starting);
    // 修复前这里挂:没有任何终态快照,Host 看到的 Run 停在 `starting`。
    try std.testing.expect(probe.saw_terminal_aborted);
    try std.testing.expect(!probe.saw_other_terminal);
    try std.testing.expect(probe.sequence_valid);
    try std.testing.expectEqual(@as(usize, 0), probe.snapshots_after_terminal);
}

/// PR #46 review round 3 (finding 2):Host 在 `finalizing` 快照的回调里 abort,core 会把
/// 结果改写成 aborted;终态快照必须跟着结果走,而不是循环自己的 end_turn。
const AbortAtFinalizingProbe = struct {
    api: sdk.Api,
    abort_status: u32 = std.math.maxInt(u32),
    saw_finalizing: bool = false,
    saw_aborted: bool = false,
    terminal_count: usize = 0,
    snapshots_after_terminal: usize = 0,
    last_seq: u64 = 0,
    sequence_valid: bool = true,

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *AbortAtFinalizingProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known| switch (known) {
                .run_state => |state| {
                    if (state.transition_seq != self.last_seq + 1) self.sequence_valid = false;
                    self.last_seq = state.transition_seq;
                    if (self.terminal_count != 0) self.snapshots_after_terminal += 1;
                    switch (state.phase) {
                        .finalizing => {
                            if (self.saw_finalizing) return wire.EVENT_CONTINUE;
                            self.saw_finalizing = true;
                            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
                            self.abort_status = self.api.session().abort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
                            self.api.bufferRelease()(&diagnostic);
                        },
                        .aborted => {
                            self.saw_aborted = true;
                            self.terminal_count += 1;
                        },
                        .completed, .failed, .poisoned => self.terminal_count += 1,
                        else => {},
                    }
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }
};

/// PR #46 review round 3 (finding 1):Host 拒绝**终态**快照 = 回调失败,Run 必须以
/// CALLBACK_FAILED 失败并毒化 Session,而不是被报成一次成功的 Run。
const FatalOnTerminalProbe = struct {
    saw_terminal: bool = false,

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *FatalOnTerminalProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known| switch (known) {
                .run_state => |state| switch (state.phase) {
                    .completed, .failed, .aborted, .poisoned => {
                        self.saw_terminal = true;
                        return wire.EVENT_FATAL;
                    },
                    else => {},
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }
};

fn createTextRunSession(
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    url: []const u8,
    root: []const u8,
    callbacks: *wire.SessionCallbacksV1,
    diagnostic: *wire.OwnedBytesV1,
) !?*wire.SessionHandle {
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("run-state-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "run-state-model");
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &session_config, callbacks, &session, diagnostic));
    return session;
}

test "L2 RunState: an abort accepted from the finalizing callback yields one terminal snapshot, aborted, matching STOP_ABORTED" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }

    var probe = AbortAtFinalizingProbe{ .api = api };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = AbortAtFinalizingProbe.event;
    const session = try createTextRunSession(api, runtime, url, root, &callbacks, &diagnostic);
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 1, sdk.bytesView("finish normally, then abort late"), &options, &result, &diagnostic),
    );
    try std.testing.expect(probe.saw_finalizing);
    try std.testing.expectEqual(wire.STATUS_OK, probe.abort_status);
    // core 把结果改写成 aborted……
    try std.testing.expectEqual(wire.STOP_ABORTED, result.stop_reason_code);
    // ……终态快照必须与之一致,且四种终态里恰好只出现这一个(修复前:completed + STOP_ABORTED)。
    try std.testing.expect(probe.saw_aborted);
    try std.testing.expectEqual(@as(usize, 1), probe.terminal_count);
    try std.testing.expectEqual(@as(usize, 0), probe.snapshots_after_terminal);
    try std.testing.expect(probe.sequence_valid);
}

test "L2 RunState: a Host rejecting the terminal snapshot fails the Run with CALLBACK_FAILED and poisons the Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }

    var probe = FatalOnTerminalProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = FatalOnTerminalProbe.event;
    const session = try createTextRunSession(api, runtime, url, root, &callbacks, &diagnostic);
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    var result: wire.RunResultV1 = undefined;
    // 修复前:终态快照被拒绝的结果被丢弃,这里返回 STATUS_OK。
    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        api.session().runText(session, 1, sdk.bytesView("reject my terminal"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expect(probe.saw_terminal);
    // 回调失败毒化 Session:后续 Run 一律 INVALID_STATE。
    try std.testing.expectEqual(
        wire.STATUS_INVALID_STATE,
        api.session().runText(session, 2, sdk.bytesView("after poison"), &options, &result, &diagnostic),
    );
}

const SchemaAdvertisementProbe = struct {
    fn event(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
        return wire.EVENT_CONTINUE;
    }
};

// Issue #35 L2 evidence: a Host tool that closes its root argument object
// registers, and the constraint survives all the way into the bytes the
// Provider receives. Registration alone would not prove anything — the
// representation gap this closes was precisely one where a boundary could
// accept a field and then drop it.
test "L2 a Host tool's root additionalProperties reaches the Provider request" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const base_url = try server.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var probe = SchemaAdvertisementProbe{};
    var host_tool = std.mem.zeroes(wire.HostToolV1);
    host_tool.struct_size = @sizeOf(wire.HostToolV1);
    host_tool.ctx = &probe;
    host_tool.name = sdk.bytesView("HostEcho");
    host_tool.description = sdk.bytesView("Echo a value through the Host");
    // The schema from issue #35, verbatim.
    host_tool.input_schema_json = sdk.bytesView(
        "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}," ++
            "\"required\":[\"text\"],\"additionalProperties\":false}",
    );
    host_tool.execute = Probe.host;
    host_tool.release_result = Probe.hostRelease;
    const host_tools = [_]wire.HostToolV1{host_tool};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = &host_tools;
    runtime_config.host_tool_count = host_tools.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const allowed_tools = [_]wire.BytesViewV1{sdk.bytesView("HostEcho")};
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.allowed_tools = &allowed_tools;
    host.allowed_tool_count = allowed_tools.len;
    var create_config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = SchemaAdvertisementProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 1, sdk.bytesView("advertise the tool"), &options, &result, &diagnostic),
    );

    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    const advertised = std.mem.indexOf(u8, body, "HostEcho") orelse return error.ToolNotAdvertised;
    try std.testing.expect(std.mem.indexOf(u8, body[advertised..], "\"additionalProperties\":false") != null);
}

// The schema-valued form has no representation in `InputSchema`, so the ABI
// must keep failing closed rather than accept it and drop it.
test "L2 a schema-valued root additionalProperties is still refused at registration" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var probe = SchemaAdvertisementProbe{};
    var host_tool = std.mem.zeroes(wire.HostToolV1);
    host_tool.struct_size = @sizeOf(wire.HostToolV1);
    host_tool.ctx = &probe;
    host_tool.name = sdk.bytesView("HostEcho");
    host_tool.description = sdk.bytesView("Echo a value through the Host");
    host_tool.input_schema_json = sdk.bytesView(
        "{\"type\":\"object\",\"additionalProperties\":{\"type\":\"string\"}}",
    );
    host_tool.execute = Probe.host;
    host_tool.release_result = Probe.hostRelease;
    const host_tools = [_]wire.HostToolV1{host_tool};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = &host_tools;
    runtime_config.host_tool_count = host_tools.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
}

// Issue #34: with the candidate-response boundary in place, AgentCore no
// longer withholds a Provider response until it completes. This probe is a
// clock, and the assertion is a *relative* one: buffering makes the first
// content event arrive at the same moment as the last, so a gap between them
// cannot be produced by a slow machine.
const IncrementalDeliveryProbe = struct {
    started_ms: i64 = 0,
    first_text_ms: ?i64 = null,
    finished_ms: i64 = 0,

    fn event(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *IncrementalDeliveryProbe = @ptrCast(@alignCast(
            raw orelse return wire.EVENT_FATAL,
        ));
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        if (self.first_text_ms == null and
            std.mem.indexOf(u8, bytes, "\"text_chunk\"") != null)
            self.first_text_ms = core.util_time.nowMs() - self.started_ms;
        return wire.EVENT_CONTINUE;
    }
};

test "L2 AgentCore delivers a content event before the Provider response completes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);

    // The text arrives in the third frame; six further frames keep the
    // response open for most of a second after that. Under the old bounded
    // spool the Host saw nothing until the last of them had been written.
    const DELAYED_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_slow\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"early\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"-1\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"-2\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"-3\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"-4\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const FRAME_DELAY_MS: u32 = 100;
    var server = try harness.MockServer.start(DELAYED_SSE, FRAME_DELAY_MS);
    defer server.stop();
    const base_url = try server.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    var create_config = sessionCreateConfig(&host, "test-model");
    var probe = IncrementalDeliveryProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = IncrementalDeliveryProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    probe.started_ms = core.util_time.nowMs();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 1, sdk.bytesView("stream slowly"), &options, &result, &diagnostic),
    );
    probe.finished_ms = core.util_time.nowMs() - probe.started_ms;
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);

    const first_text_ms = probe.first_text_ms orelse return error.NoTextEventDelivered;
    // Six frames still had to be written after the text. Buffering collapses
    // that gap to nothing, so the margin is what distinguishes the two — not
    // an absolute latency budget the machine could miss.
    try std.testing.expect(probe.finished_ms - first_text_ms > 3 * @as(i64, FRAME_DELAY_MS));
}

// Issue #34: the durable-budget veto, end to end. An over-cap Provider response
// is now delivered incrementally and *then* refused at the Conversation commit,
// rather than withheld until it could be judged. Both halves matter: the Host
// must see the content, and the Session must still refuse to checkpoint it.
const OverCapProbe = struct {
    text_events: usize = 0,
    discarded_segments: usize = 0,
    committed_segments: usize = 0,

    fn event(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *OverCapProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        if (std.mem.indexOf(u8, bytes, "\"text_chunk\"") != null) self.text_events += 1;
        if (std.mem.indexOf(u8, bytes, "\"output_segment_end\"") != null) {
            if (std.mem.indexOf(u8, bytes, "\"disposition\":\"discarded\"") != null) {
                self.discarded_segments += 1;
            } else if (std.mem.indexOf(u8, bytes, "\"disposition\":\"final\"") != null) {
                self.committed_segments += 1;
            }
        }
        return wire.EVENT_CONTINUE;
    }
};

test "L2 an over-cap Provider response is delivered, then refused before Conversation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);

    // Four text deltas of 400 bytes each against a 512-byte result cap: the
    // first is admitted, and the response outgrows the cap partway through.
    const CHUNK = "x" ** 400;
    const OVER_CAP_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_big\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ CHUNK ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ CHUNK ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ CHUNK ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var server = try harness.MockServer.start(OVER_CAP_SSE, 0);
    defer server.stop();
    const base_url = try server.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    const budget = wire.DurableBudgetProfileV1{
        .struct_size = @sizeOf(wire.DurableBudgetProfileV1),
        .reserved0 = 0,
        .hard_bytes = 1024 * 1024,
        .soft_bytes = 768 * 1024,
        .input_cap_bytes = 4096,
        .provider_request_cap_bytes = 512 * 1024,
        .provider_result_cap_bytes = 512,
        .tool_result_cap_bytes = 4096,
        .mcp_result_cap_bytes = 4096,
        .audit_reserve_bytes = 4096,
        .terminal_reserve_bytes = 4096,
        .reserved = [_]u64{0} ** 4,
    };
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.durable_budget = &budget;
    var create_config = sessionCreateConfig(&host, "test-model");
    var probe = OverCapProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = OverCapProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 2;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, 1, sdk.bytesView("answer at length"), &options, &result, &diagnostic),
    );

    // The durable decision is unchanged: the response is refused and the Run
    // reports the checkpoint outcome, not a successful end of turn.
    try std.testing.expectEqual(wire.STOP_CHECKPOINT_RESOURCE_LIMIT, result.stop_reason_code);
    try std.testing.expectEqual(wire.RUN_CHECKPOINT_RESOURCE_LIMIT, result.checkpoint_outcome_code);
    // What changed: the Host saw the admitted prefix while it was arriving,
    // and then saw it withdrawn rather than never hearing about it at all.
    try std.testing.expect(probe.text_events > 0);
    try std.testing.expectEqual(@as(usize, 1), probe.discarded_segments);
    try std.testing.expectEqual(@as(usize, 0), probe.committed_segments);
}

/// Counts the public `prompt_manifest` events of every Session it serves.
const PromptManifestProbe = struct {
    manifests: u32 = 0,
    last_sha256: [64]u8 = [_]u8{0} ** 64,
    last_sections: usize = 0,

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known| switch (known) {
                .prompt_manifest => |manifest| {
                    self.manifests += 1;
                    @memcpy(&self.last_sha256, manifest.sha256[0..64]);
                    self.last_sections = manifest.sections.len;
                },
                else => {},
            },
            .unknown => return wire.EVENT_FATAL,
        }
        return wire.EVENT_CONTINUE;
    }
};

fn promptSection(op_code: u32, id: []const u8, order: i64, text: []const u8) wire.PromptSectionV1 {
    var section = std.mem.zeroes(wire.PromptSectionV1);
    section.struct_size = @sizeOf(wire.PromptSectionV1);
    section.op_code = op_code;
    section.id = sdk.bytesView(id);
    section.order = order;
    section.text = if (text.len == 0) .{ .ptr = null, .len = 0 } else sdk.bytesView(text);
    return section;
}

fn promptProfile(sections: []const wire.PromptSectionV1) wire.PromptProfileV1 {
    var profile = std.mem.zeroes(wire.PromptProfileV1);
    profile.struct_size = @sizeOf(wire.PromptProfileV1);
    profile.sections = sections.ptr;
    profile.section_count = sections.len;
    return profile;
}

fn decodeDescription(api: sdk.Api, session: ?*wire.SessionHandle) !sdk.ParsedSessionDescription {
    var description = std.mem.zeroes(wire.OwnedBytesV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().describe()(session, &description, &diagnostic));
    defer api.bufferRelease()(&description);
    return sdk.decodeSessionDescription(std.testing.allocator, try sdk.borrowedBytes(.{
        .ptr = description.ptr,
        .len = description.len,
    }));
}

test "L2 public prompt profile shapes the system prompt, survives restore, and changes once per set" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{ FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer _ = api.runtime().destroy()(runtime, &diagnostic);

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    const sections = [_]wire.PromptSectionV1{
        promptSection(wire.PROMPT_OP_REPLACE, "metacodes:identity", 0, "You are Shopkeeper, a browser agent for store back offices."),
        promptSection(wire.PROMPT_OP_ADD, "host:browser-rules", 500, "Read the page before acting on it."),
    };
    var profile = promptProfile(&sections);
    var create_config = sessionCreateConfig(&host, "test-model");
    create_config.prompt_profile = &profile;
    var probe = PromptManifestProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = PromptManifestProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic));
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 1, sdk.bytesView("check the orders page"), &options, &result, &diagnostic));
    const first = server.requestAt(0) orelse return error.NoRequestCaptured;
    const first_system = first.jsonField("system") orelse return error.MissingSystemPrompt;
    try std.testing.expect(std.mem.indexOf(u8, first_system, "You are Shopkeeper, a browser agent for store back offices.") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_system, "Read the page before acting on it.") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_system, "MetaCode") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_system, "software engineering") == null);
    // The locked governance sections stay.
    try std.testing.expect(std.mem.indexOf(u8, first_system, "IMPORTANT: Assist with authorized security testing") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_system, "# System") != null);
    try std.testing.expectEqual(@as(u32, 1), probe.manifests);

    // An unchanged prompt is the same cache prefix and announces nothing.
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 2, sdk.bytesView("and the refunds"), &options, &result, &diagnostic));
    const second = server.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings(first_system, second.jsonField("system").?);
    try std.testing.expectEqual(@as(u32, 1), probe.manifests);

    {
        const described = try decodeDescription(api, session);
        defer described.deinit();
        const prompt = described.value.prompt;
        try std.testing.expectEqual(@as(usize, 2), prompt.profile.len);
        try std.testing.expectEqual(sdk.protocol.PromptSectionOp.replace, prompt.profile[0].op);
        try std.testing.expectEqualStrings("metacodes:identity", prompt.profile[0].id);
        try std.testing.expectEqualStrings("host:browser-rules", prompt.profile[1].id);
        try std.testing.expectEqual(@as(i64, 500), prompt.profile[1].order);
        const manifest = prompt.manifest orelse return error.MissingManifest;
        try std.testing.expectEqualStrings(&probe.last_sha256, manifest.sha256);
        try std.testing.expectEqual(probe.last_sections, manifest.sections.len);
        try std.testing.expectEqual(sdk.protocol.PromptSectionOrigin.host, manifest.sections[0].origin);
        try std.testing.expectEqual(sdk.protocol.PromptSectionClass.locked, manifest.sections[1].class);
    }

    // The checkpoint carries the profile (the marker-9 envelope), so the
    // restored Session sends the same system prompt bytes.
    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic));
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, checkpoint.bytes.items[20..24], .little));
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().restore()(runtime, &restore_config, &callbacks, &session, &restore_report, &diagnostic));
    api.bufferRelease()(&restore_report);
    {
        const described = try decodeDescription(api, session);
        defer described.deinit();
        try std.testing.expectEqual(@as(usize, 2), described.value.prompt.profile.len);
        try std.testing.expectEqualStrings("Read the page before acting on it.", described.value.prompt.profile[1].text);
        // No Run of the restored Session has rendered a prompt yet.
        try std.testing.expect(described.value.prompt.manifest == null);
    }
    const announced_before_restore = probe.last_sha256;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 3, sdk.bytesView("resume"), &options, &result, &diagnostic));
    const third = server.requestAt(2) orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings(first_system, third.jsonField("system").?);
    try std.testing.expectEqual(@as(u32, 2), probe.manifests);
    try std.testing.expectEqualSlices(u8, &announced_before_restore, &probe.last_sha256);

    // Clearing the profile is exactly one boundary: the kernel prompt returns.
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().setPromptProfile()(session, null, &diagnostic));
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 4, sdk.bytesView("plain again"), &options, &result, &diagnostic));
    const fourth = server.requestAt(3) orelse return error.NoRequestCaptured;
    const fourth_system = fourth.jsonField("system").?;
    try std.testing.expect(std.mem.indexOf(u8, fourth_system, "You are MetaCode") != null);
    try std.testing.expect(std.mem.indexOf(u8, fourth_system, "Shopkeeper") == null);
    try std.testing.expectEqual(@as(u32, 3), probe.manifests);

    // A refused replacement names the entry and the rule and changes nothing.
    const locked = [_]wire.PromptSectionV1{promptSection(wire.PROMPT_OP_REPLACE, "metacodes:system", 0, "x")};
    var locked_profile = promptProfile(&locked);
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.sessionControl().setPromptProfile()(session, &locked_profile, &diagnostic));
    {
        defer api.bufferRelease()(&diagnostic);
        const message = try sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len });
        try std.testing.expectEqualStrings("prompt profile section 0 (metacodes:system): the section is locked", message);
    }
    const described = try decodeDescription(api, session);
    defer described.deinit();
    try std.testing.expectEqual(@as(usize, 0), described.value.prompt.profile.len);
}

test "L2 public prompt profile refusals name the entry and the rule at create" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var fixture = try PublicSessionFixture.init(root, "http://127.0.0.1:9", "test-model");
    defer fixture.deinit();
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;

    const cases = [_]struct { []const wire.PromptSectionV1, u32, []const u8 }{
        .{ &.{promptSection(wire.PROMPT_OP_REMOVE, "metacodes:safety-policy", 0, "")}, wire.STATUS_INVALID_ARGUMENT, "prompt profile section 0 (metacodes:safety-policy): the section is locked" },
        .{ &.{
            promptSection(wire.PROMPT_OP_ADD, "host:a", 1, "x"),
            promptSection(wire.PROMPT_OP_ADD, "host:a", 2, "y"),
        }, wire.STATUS_INVALID_ARGUMENT, "prompt profile section 1 (host:a): the id appears in more than one profile entry" },
        .{ &.{promptSection(wire.PROMPT_OP_ADD, "host:a", 1, "{{cwd}}")}, wire.STATUS_OK, "" },
        .{ &.{promptSection(wire.PROMPT_OP_ADD, "metacodes:mine", 1, "x")}, wire.STATUS_INVALID_ARGUMENT, "prompt profile section 0 (metacodes:mine): add takes a host: id; metacodes: ids are reserved for kernel sections" },
        .{ &.{promptSection(9, "host:a", 1, "x")}, wire.STATUS_INVALID_ARGUMENT, "invalid argument: InvalidPromptProfile" },
    };
    for (cases) |case| {
        var profile = promptProfile(case[0]);
        var create_config = sessionCreateConfig(&host, "test-model");
        create_config.prompt_profile = &profile;
        var session: ?*wire.SessionHandle = null;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        try std.testing.expectEqual(case[1], fixture.api.session().create()(fixture.runtime, &create_config, &callbacks, &session, &diagnostic));
        defer fixture.api.bufferRelease()(&diagnostic);
        if (case[1] == wire.STATUS_OK) {
            // Without interpolation `{{cwd}}` is plain text.
            try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().destroy()(session, &diagnostic));
            continue;
        }
        try std.testing.expect(session == null);
        const message = try sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len });
        try std.testing.expectEqualStrings(case[2], message);
    }

    var interpolated = [_]wire.PromptSectionV1{promptSection(wire.PROMPT_OP_ADD, "host:a", 1, "at {{cwd}}")};
    interpolated[0].interpolate = 1;
    var bad_variable = promptProfile(&interpolated);
    var create_config = sessionCreateConfig(&host, "test-model");
    create_config.prompt_profile = &bad_variable;
    var session: ?*wire.SessionHandle = null;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, fixture.api.session().create()(fixture.runtime, &create_config, &callbacks, &session, &diagnostic));
    fixture.api.bufferRelease()(&diagnostic);

    var too_many: [65]wire.PromptSectionV1 = undefined;
    for (&too_many) |*section| section.* = promptSection(wire.PROMPT_OP_ADD, "host:a", 0, "x");
    var oversized = promptProfile(&too_many);
    create_config.prompt_profile = &oversized;
    try std.testing.expectEqual(wire.STATUS_RESOURCE_LIMIT, fixture.api.session().create()(fixture.runtime, &create_config, &callbacks, &session, &diagnostic));
    fixture.api.bufferRelease()(&diagnostic);
}

test "L2 public context blocks lead the Run's user record and stay in history" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{ FINAL_SSE, FINAL_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();

    const blocks = [_]wire.ContextBlockV1{
        .{ .struct_size = @sizeOf(wire.ContextBlockV1), .reserved0 = 0, .label = sdk.bytesView("currentDate"), .text = sdk.bytesView("Today's date is 2026/10/02."), .reserved = [_]u64{0} ** 2 },
        .{ .struct_size = @sizeOf(wire.ContextBlockV1), .reserved0 = 0, .label = sdk.bytesView("host:page"), .text = sdk.bytesView("URL: https://shop.example/orders"), .reserved = [_]u64{0} ** 2 },
    };
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    options.context_blocks = &blocks;
    options.context_block_count = blocks.len;
    var result = std.mem.zeroes(wire.RunResultV1);

    // A Skill Run does not take context blocks; nothing is admitted.
    var skill_input = std.mem.zeroes(wire.RunInputV1);
    skill_input.struct_size = @sizeOf(wire.RunInputV1);
    skill_input.kind_code = wire.RUN_INPUT_SKILL;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, fixture.api.session().runInput()(fixture.session, 1, &skill_input, &options, &result, &fixture.diagnostic));
    fixture.releaseDiagnostic();

    var bad_blocks = blocks;
    bad_blocks[1].label = sdk.bytesView("bad\nlabel");
    var bad_options = options;
    bad_options.context_blocks = &bad_blocks;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, fixture.api.session().runText(fixture.session, 1, sdk.bytesView("x"), &bad_options, &result, &fixture.diagnostic));
    {
        const message = try sdk.borrowedBytes(.{ .ptr = fixture.diagnostic.ptr, .len = fixture.diagnostic.len });
        try std.testing.expect(std.mem.startsWith(u8, message, "context block 1: the label is not"));
    }
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runText(fixture.session, 1, sdk.bytesView("summarize the open orders"), &options, &result, &fixture.diagnostic));
    const first = (server.requestAt(0) orelse return error.NoRequestCaptured).body();
    const reminder = "<system-reminder>\\nThe host application provided the following context for this request:\\n# currentDate\\nToday's date is 2026/10/02.\\n# host:page\\nURL: https://shop.example/orders\\n";
    const reminder_at = std.mem.indexOf(u8, first, reminder) orelse return error.MissingContextReminder;
    const prompt_at = std.mem.indexOf(u8, first, "summarize the open orders") orelse return error.MissingPrompt;
    try std.testing.expect(reminder_at < prompt_at);

    // The next Run without blocks still carries the first Run's context in
    // its history: the cached prefix only grows. (Time context off: the
    // runtime would otherwise add this Run's own date, Revision 22.)
    var plain = options;
    plain.context_blocks = null;
    plain.context_block_count = 0;
    plain.time_context_code = wire.TIME_CONTEXT_OFF;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runText(fixture.session, 2, sdk.bytesView("and the refunds"), &plain, &result, &fixture.diagnostic));
    const second = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, second, "<system-reminder>\\nThe host application"));
}

/// `Today's date is YYYY-MM-DD (Weekday).` at `unix_seconds` in a zone
/// `offset_minutes` east of UTC.
fn expectedDate(buf: []u8, unix_seconds: i64, offset_minutes: i32) ![]const u8 {
    const date = core.time_context.localDate(unix_seconds, offset_minutes);
    return std.fmt.bufPrint(buf, "Today's date is {d}-{d:0>2}-{d:0>2} ({s}).", .{ date.year, date.month, date.day, @tagName(date.weekday) });
}

/// The request names the date at one of two instants (a Run straddling a
/// midnight sees either).
fn expectDateIn(body: []const u8, before: i64, after: i64, offset_minutes: i32) !void {
    var a_buf: [64]u8 = undefined;
    var b_buf: [64]u8 = undefined;
    if (std.mem.indexOf(u8, body, try expectedDate(&a_buf, before, offset_minutes)) != null) return;
    if (std.mem.indexOf(u8, body, try expectedDate(&b_buf, after, offset_minutes)) != null) return;
    std.debug.print("request body: {s}\n", .{body});
    return error.MissingTimeContext;
}

test "L2 Revision 22 each Run carries today's date and the process time zone by default, and history keeps each Run's own (issue #276)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{ FINAL_SSE, FINAL_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();

    // No context blocks, no time option: the Host supplies nothing.
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    const before = core.time_context.currentUnixSeconds();
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runText(fixture.session, 1, sdk.bytesView("what day is it"), &options, &result, &fixture.diagnostic));
    const after = core.time_context.currentUnixSeconds();
    const zone = core.time_context.systemZone(before);
    const first = (server.requestAt(0) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, first, "# currentDate\\nToday's date is ") != null);
    try expectDateIn(first, before, after, zone.offset_minutes);
    // The zone is named (or said to be unknown), never left implicit.
    try std.testing.expect(std.mem.indexOf(u8, first, "Time zone: UTC") != null or
        std.mem.indexOf(u8, first, "Time zone: ") != null or
        std.mem.indexOf(u8, first, "the user's time zone is unknown") != null);
    // The date rides the Run's user record, ahead of the prompt, not the system prompt.
    try std.testing.expect(std.mem.indexOf(u8, first, "# currentDate").? < std.mem.indexOf(u8, first, "what day is it").?);

    // The next Run gets its own date; the first Run's stays in history.
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runText(fixture.session, 2, sdk.bytesView("and tomorrow"), &options, &result, &fixture.diagnostic));
    const second = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, second, "# currentDate\\nToday's date is "));
}

test "L2 Revision 22 a Host UTC offset decides the date and names the zone (issue #276)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{ FINAL_SSE, FINAL_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    options.time_context_code = wire.TIME_CONTEXT_UTC_OFFSET;
    var result = std.mem.zeroes(wire.RunResultV1);
    // The two ends of the offset range are a day apart for most of every day.
    for ([_]i32{ wire.MAX_UTC_OFFSET_MINUTES_V1, -12 * 60 }, [_][]const u8{ "Time zone: UTC+14:00.", "Time zone: UTC-12:00." }, 0..) |offset, label, i| {
        options.utc_offset_minutes = offset;
        const before = core.time_context.currentUnixSeconds();
        try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runText(fixture.session, i + 1, sdk.bytesView("what day is it"), &options, &result, &fixture.diagnostic));
        const after = core.time_context.currentUnixSeconds();
        const body = (server.requestAt(i) orelse return error.NoRequestCaptured).body();
        try expectDateIn(body, before, after, offset);
        try std.testing.expect(std.mem.indexOf(u8, body, label) != null);
    }
}

test "L2 Revision 22 OFF adds no date, and a Host currentDate block is the Run's only one (issue #276)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{ FINAL_SSE, FINAL_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    options.time_context_code = wire.TIME_CONTEXT_OFF;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runText(fixture.session, 1, sdk.bytesView("no clock please"), &options, &result, &fixture.diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, (server.requestAt(0) orelse return error.NoRequestCaptured).body(), "currentDate") == null);

    // Under the default, the Host's own block wins and the runtime adds none.
    const blocks = [_]wire.ContextBlockV1{.{ .struct_size = @sizeOf(wire.ContextBlockV1), .reserved0 = 0, .label = sdk.bytesView("currentDate"), .text = sdk.bytesView("It is the user's birthday, 1999-12-31."), .reserved = [_]u64{0} ** 2 }};
    options.time_context_code = wire.TIME_CONTEXT_SYSTEM;
    options.context_blocks = &blocks;
    options.context_block_count = blocks.len;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runText(fixture.session, 2, sdk.bytesView("what day is it"), &options, &result, &fixture.diagnostic));
    const body = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "# currentDate"));
    try std.testing.expect(std.mem.indexOf(u8, body, "It is the user's birthday, 1999-12-31.") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Today's date is ") == null);
}

fn expectTimeContextReason(fixture: *PublicSessionFixture, reason: []const u8) !void {
    defer fixture.releaseDiagnostic();
    const text = try sdk.borrowedBytes(.{ .ptr = fixture.diagnostic.ptr, .len = fixture.diagnostic.len });
    if (std.mem.indexOf(u8, text, reason) == null) {
        std.debug.print("expected {s} in diagnostic: {s}\n", .{ reason, text });
        return error.TestUnexpectedDiagnostic;
    }
}

test "Revision 22 time context is validated before a Run is admitted (issue #276)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();
    var result = std.mem.zeroes(wire.RunResultV1);
    const host_date = [_]wire.ContextBlockV1{.{ .struct_size = @sizeOf(wire.ContextBlockV1), .reserved0 = 0, .label = sdk.bytesView("currentDate"), .text = sdk.bytesView("Today is Host day."), .reserved = [_]u64{0} ** 2 }};

    // Each refusal names the time-context rule it broke, not a later check
    // that happens to refuse the same input.
    const Case = struct { code: u32, offset: i32, host_block: bool = false, reason: []const u8 = "InvalidTimeContext" };
    for ([_]Case{
        .{ .code = 3, .offset = 0 }, // unknown code
        .{ .code = wire.TIME_CONTEXT_SYSTEM, .offset = 60 }, // an offset without UTC_OFFSET
        .{ .code = wire.TIME_CONTEXT_OFF, .offset = -60 },
        .{ .code = wire.TIME_CONTEXT_UTC_OFFSET, .offset = wire.MAX_UTC_OFFSET_MINUTES_V1 + 1 },
        .{ .code = wire.TIME_CONTEXT_UTC_OFFSET, .offset = wire.MIN_UTC_OFFSET_MINUTES_V1 - 1 },
        .{ .code = wire.TIME_CONTEXT_UTC_OFFSET, .offset = 480, .host_block = true, .reason = "ConflictingTimeContext" }, // two answers
    }) |case| {
        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 1;
        options.time_context_code = case.code;
        options.utc_offset_minutes = case.offset;
        if (case.host_block) {
            options.context_blocks = &host_date;
            options.context_block_count = host_date.len;
        }
        try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, fixture.api.session().runText(fixture.session, 1, sdk.bytesView("x"), &options, &result, &fixture.diagnostic));
        try expectTimeContextReason(&fixture, case.reason);
    }
    // A Skill invocation carries no context, so it takes no offset either.
    var skill_input = std.mem.zeroes(wire.RunInputV1);
    skill_input.struct_size = @sizeOf(wire.RunInputV1);
    skill_input.kind_code = wire.RUN_INPUT_SKILL;
    var skill_options = std.mem.zeroes(wire.RunOptionsV1);
    skill_options.struct_size = @sizeOf(wire.RunOptionsV1);
    skill_options.max_turns = 1;
    skill_options.time_context_code = wire.TIME_CONTEXT_UTC_OFFSET;
    skill_options.utc_offset_minutes = 60;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, fixture.api.session().runInput()(fixture.session, 1, &skill_input, &skill_options, &result, &fixture.diagnostic));
    try expectTimeContextReason(&fixture, "InvalidTimeContext");
    // Nothing was sent and Run 1 was never admitted.
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
    var ok_options = std.mem.zeroes(wire.RunOptionsV1);
    ok_options.struct_size = @sizeOf(wire.RunOptionsV1);
    ok_options.max_turns = 1;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runText(fixture.session, 1, sdk.bytesView("x"), &ok_options, &result, &fixture.diagnostic));
}

/// Answers each Permission request with `allow_session` and, while the Run is
/// suspended in that callback, tries to change the permission mode (#236).
const PublicModeUpdateProbe = struct {
    api: sdk.Api,
    session: ?*wire.SessionHandle = null,
    expected_run_id: u64 = 0,
    ui_calls: u32 = 0,
    ui_releases: u32 = 0,
    request_generation: u64 = 0,
    nested_update_status: u32 = wire.STATUS_OK,
    write_decisions: u32 = 0,
    last_decision: ?sdk.protocol.PermissionDecision = null,
    last_used_session_rule: bool = false,
    last_policy_generation: u64 = 0,

    fn validRun(self: *@This(), run_ptr: ?*const wire.RunContextV1) bool {
        const run = sdk.validateRunContext(run_ptr) catch return false;
        return run.session == self.session and run.run_id == self.expected_run_id;
    }

    fn event(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        if (!self.validRun(run_ptr)) return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const known = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (known) {
            .permission_provenance => |provenance| {
                if (!std.mem.eql(u8, provenance.tool.name, "Write")) return wire.EVENT_CONTINUE;
                self.write_decisions += 1;
                self.last_decision = provenance.decision;
                self.last_used_session_rule = provenance.used_session_rule;
                self.last_policy_generation = provenance.policy_generation;
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        if (!self.validRun(run_ptr)) return wire.UI_FATAL;
        const encoded = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const request = switch (parsed.value) {
            .permission => |value| value,
            else => return wire.UI_FATAL,
        };
        const candidate = request.candidate orelse return wire.UI_FATAL;
        if (!std.mem.eql(u8, request.tool.name, "Write")) return wire.UI_FATAL;
        // The Run is suspended here: the facade is busy, so the mode update
        // is refused and must change nothing.
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        self.nested_update_status = self.api.sessionControl().updatePermissionMode()(
            self.session,
            wire.PERMISSION_DONT_ASK,
            &diagnostic,
        );
        self.api.bufferRelease()(&diagnostic);
        self.request_generation = request.policy_generation;
        const response_json = sdk.encodeUiResponse(
            std.heap.c_allocator,
            parsed.value,
            .{ .permission = .{
                .permission = .allow_session,
                .request_id = request.request_id,
                .policy_generation = request.policy_generation,
                .rule_id = candidate.rule_id,
            } },
        ) catch return wire.UI_FATAL;
        const out = out_response orelse {
            std.heap.c_allocator.free(response_json);
            return wire.UI_FATAL;
        };
        out.* = .{ .ptr = response_json.ptr, .len = response_json.len };
        self.ui_calls += 1;
        return wire.UI_ANSWERED;
    }

    fn releaseUi(raw: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.ui_releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }
};

fn expectDescribedPermission(
    api: sdk.Api,
    session: ?*wire.SessionHandle,
    mode: sdk.protocol.PermissionMode,
    generation: u64,
) !void {
    const described = try decodeDescription(api, session);
    defer described.deinit();
    try std.testing.expectEqual(mode, described.value.permission_mode);
    try std.testing.expectEqual(generation, described.value.policy_generation);
}

test "L2 Revision 19 permission mode update governs the next Run in place and revokes Session grants (#236)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ WRITE_SSE, FINAL_SSE } ** 4;
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    const builtins = [_]wire.BytesViewV1{sdk.bytesView("Write")};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &builtins;
    host_config.allowed_tool_count = builtins.len;
    var config = sessionCreateConfig(&host_config, "test-model");
    var probe = PublicModeUpdateProbe{ .api = api };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = PublicModeUpdateProbe.event;
    callbacks.on_ui_request = PublicModeUpdateProbe.ui;
    callbacks.release_response = PublicModeUpdateProbe.releaseUi;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    probe.session = session;
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    const created_handle = session;
    const written_path = try std.fs.path.join(a, &.{ root, "blocked.txt" });
    defer a.free(written_path);
    const cwd = std.Io.Dir.cwd();

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);

    // full_access: the write runs and nobody is asked.
    try expectDescribedPermission(api, session, .full_access, 1);
    probe.expected_run_id = 1;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 1, sdk.bytesView("write it"), &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(u32, 0), probe.ui_calls);
    try cwd.access(std.testing.io, written_path, .{});
    try cwd.deleteFile(std.testing.io, written_path);

    // The same handle and Conversation move to `default`: the next Run asks.
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().updatePermissionMode()(session, wire.PERMISSION_DEFAULT, &diagnostic),
    );
    try expectDescribedPermission(api, session, .default, 2);
    probe.expected_run_id = 2;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 2, sdk.bytesView("write it again"), &options, &result, &diagnostic));
    try std.testing.expect(session == created_handle);
    try std.testing.expectEqual(@as(u32, 1), probe.ui_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.ui_releases);
    try std.testing.expectEqual(@as(u64, 2), probe.request_generation);
    // Asked from inside the suspended Run, the update was refused and
    // changed nothing.
    try std.testing.expectEqual(wire.STATUS_BUSY, probe.nested_update_status);
    try expectDescribedPermission(api, session, .default, 2);
    try cwd.access(std.testing.io, written_path, .{});
    try cwd.deleteFile(std.testing.io, written_path);

    // The allow_session answer covers the next identical write.
    probe.expected_run_id = 3;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 3, sdk.bytesView("and again"), &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(u32, 1), probe.ui_calls);
    try std.testing.expect(probe.last_used_session_rule);
    try std.testing.expectEqual(sdk.protocol.PermissionDecision.allow, probe.last_decision.?);
    try cwd.access(std.testing.io, written_path, .{});
    try cwd.deleteFile(std.testing.io, written_path);

    // Leaving the mode revokes that grant. With it, dont_ask would still
    // allow the write; without it, dont_ask denies without asking.
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().updatePermissionMode()(session, wire.PERMISSION_DONT_ASK, &diagnostic),
    );
    try expectDescribedPermission(api, session, .dont_ask, 3);
    probe.expected_run_id = 4;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 4, sdk.bytesView("one more"), &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(u32, 1), probe.ui_calls);
    try std.testing.expectEqual(sdk.protocol.PermissionDecision.deny, probe.last_decision.?);
    try std.testing.expect(!probe.last_used_session_rule);
    try std.testing.expectEqual(@as(u64, 3), probe.last_policy_generation);
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, written_path, .{}));

    // An unknown code is refused and changes nothing; the current mode is a
    // no-op that keeps the generation.
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionControl().updatePermissionMode()(session, 99, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().updatePermissionMode()(session, wire.PERMISSION_DONT_ASK, &diagnostic),
    );
    try expectDescribedPermission(api, session, .dont_ask, 3);

    // The checkpoint holds the new mode and generation and no grant: a
    // restore under the same mode keeps the generation and restores nothing.
    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic));
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    probe.session = null;

    host_config.permission_mode_code = wire.PERMISSION_DONT_ASK;
    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host_config;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&restore_report);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().restore()(runtime, &restore_config, &callbacks, &session, &restore_report, &diagnostic));
    probe.session = session;
    {
        const decoded = try sdk.decodeRestoreReport(a, try sdk.borrowedBytes(.{
            .ptr = restore_report.ptr,
            .len = restore_report.len,
        }));
        defer decoded.deinit();
        try std.testing.expectEqual(@as(u64, 3), decoded.value.policy_generation);
        try std.testing.expectEqual(@as(u32, 0), decoded.value.permission.restored_rules);
        try std.testing.expectEqual(@as(u32, 0), decoded.value.permission.invalidated_rules);
    }
    try expectDescribedPermission(api, session, .dont_ask, 3);
}

/// Answers Write with `allow_session` (so a checkpoint carries a Session
/// rule) and HostEcho with `allow_once`; counts both and executes HostEcho.
const RestoreToolSetProbe = struct {
    session: ?*wire.SessionHandle = null,
    expected_run_id: u64 = 0,
    write_asks: u32 = 0,
    host_asks: u32 = 0,
    ui_releases: u32 = 0,
    host_calls: u32 = 0,
    host_releases: u32 = 0,
    last_ask_generation: u64 = 0,

    fn validRun(self: *@This(), run_ptr: ?*const wire.RunContextV1) bool {
        const run = sdk.validateRunContext(run_ptr) catch return false;
        return run.session == self.session and run.run_id == self.expected_run_id;
    }

    fn event(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        if (!self.validRun(run_ptr)) return wire.EVENT_FATAL;
        _ = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        return wire.EVENT_CONTINUE;
    }

    fn ui(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        if (!self.validRun(run_ptr)) return wire.UI_FATAL;
        const encoded = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const request = switch (parsed.value) {
            .permission => |value| value,
            else => return wire.UI_FATAL,
        };
        self.last_ask_generation = request.policy_generation;
        const response: sdk.protocol.PermissionResponse = if (std.mem.eql(u8, request.tool.name, "Write")) blk: {
            const candidate = request.candidate orelse return wire.UI_FATAL;
            self.write_asks += 1;
            break :blk .{
                .permission = .allow_session,
                .request_id = request.request_id,
                .policy_generation = request.policy_generation,
                .rule_id = candidate.rule_id,
            };
        } else if (std.mem.eql(u8, request.tool.name, "HostEcho")) blk: {
            self.host_asks += 1;
            break :blk .{
                .permission = .allow_once,
                .request_id = request.request_id,
                .policy_generation = request.policy_generation,
            };
        } else return wire.UI_FATAL;
        const response_json = sdk.encodeUiResponse(
            std.heap.c_allocator,
            parsed.value,
            .{ .permission = response },
        ) catch return wire.UI_FATAL;
        const out = out_response orelse {
            std.heap.c_allocator.free(response_json);
            return wire.UI_FATAL;
        };
        out.* = .{ .ptr = response_json.ptr, .len = response_json.len };
        return wire.UI_ANSWERED;
    }

    fn releaseUi(raw: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.ui_releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }

    fn host(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        arguments_json: wire.BytesViewV1,
        out_result: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
        if (!self.validRun(run_ptr)) return wire.HOST_FATAL;
        _ = sdk.borrowedBytes(arguments_json) catch return wire.HOST_FATAL;
        const result = "host-ok";
        (out_result orelse return wire.HOST_FATAL).* = .{
            .ptr = @constCast(result.ptr),
            .len = result.len,
        };
        self.host_calls += 1;
        return wire.HOST_OK;
    }

    fn releaseHost(raw: ?*anyopaque, result: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        if (result) |out| {
            if (out.ptr != null) self.host_releases += 1;
            out.* = .{ .ptr = null, .len = 0 };
        }
    }
};

fn restoreForToolSet(
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    host: *const wire.SessionHostConfigV1,
    checkpoint: *PublicCheckpointBuffer,
    callbacks: *const wire.SessionCallbacksV1,
    session: *?*wire.SessionHandle,
) !sdk.ParsedRestoreReport {
    var limits = publicCheckpointLimits();
    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var report = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&report);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().restore()(runtime, &restore_config, callbacks, session, &report, &diagnostic),
    );
    // The official SDK decoder validates health against counts and issues.
    return sdk.decodeRestoreReport(std.testing.allocator, try sdk.borrowedBytes(.{
        .ptr = report.ptr,
        .len = report.len,
    }));
}

test "L2 restore under a grown tool set is complete without Session rules and degraded by the rules it loses (#334)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    // Run 1 talks; run 2 writes under an allow_session grant; the run after
    // the first restore calls the newly selected Host Tool.
    const bodies = [_][]const u8{ FINAL_SSE, WRITE_SSE, FINAL_SSE, HOST_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var probe = RestoreToolSetProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = RestoreToolSetProbe.event;
    callbacks.on_ui_request = RestoreToolSetProbe.ui;
    callbacks.release_response = RestoreToolSetProbe.releaseUi;

    const builtins = [_]wire.BytesViewV1{sdk.bytesView("Write")};
    var original_config = std.mem.zeroes(wire.RuntimeConfigV1);
    original_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    original_config.builtin_tools = &builtins;
    original_config.builtin_tool_count = builtins.len;
    var original: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&original_config, null, &original, &diagnostic),
    );
    defer if (original) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var host_tool = std.mem.zeroes(wire.HostToolV1);
    host_tool.struct_size = @sizeOf(wire.HostToolV1);
    host_tool.ctx = &probe;
    host_tool.name = sdk.bytesView("HostEcho");
    host_tool.description = sdk.bytesView("Echo a value through the Host");
    host_tool.input_schema_json = sdk.bytesView(
        "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
    );
    host_tool.execute = RestoreToolSetProbe.host;
    host_tool.release_result = RestoreToolSetProbe.releaseHost;
    const host_tools = [_]wire.HostToolV1{host_tool};
    var grown_config = original_config;
    grown_config.host_tools = &host_tools;
    grown_config.host_tool_count = host_tools.len;
    var grown: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&grown_config, null, &grown, &diagnostic),
    );
    defer if (grown) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.allowed_tools = &builtins;
    host.allowed_tool_count = builtins.len;
    const grown_tools = [_]wire.BytesViewV1{ sdk.bytesView("Write"), sdk.bytesView("HostEcho") };
    var grown_host = host;
    grown_host.allowed_tools = &grown_tools;
    grown_host.allowed_tool_count = grown_tools.len;

    var session: ?*wire.SessionHandle = null;
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    var create_config = sessionCreateConfig(&host, "test-model");
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(original, &create_config, &callbacks, &session, &diagnostic),
    );
    probe.session = session;

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    var limits = publicCheckpointLimits();

    probe.expected_run_id = 1;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 1, sdk.bytesView("hello"), &options, &result, &diagnostic));
    var without_rules = PublicCheckpointBuffer{};
    defer without_rules.deinit();
    {
        var sink = without_rules.sink();
        var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
        export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
        export_config.limits = &limits;
        export_config.sink = &sink;
        var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
        try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic));
    }

    probe.expected_run_id = 2;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 2, sdk.bytesView("write it"), &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(u32, 1), probe.write_asks);
    var with_rule = PublicCheckpointBuffer{};
    defer with_rule.deinit();
    {
        var sink = with_rule.sink();
        var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
        export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
        export_config.limits = &limits;
        export_config.sink = &sink;
        var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
        try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic));
    }
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    // No Session rule and a newly selected Host Tool: the policy generation
    // moves, nothing is lost, and the SDK accepts both report and
    // description as complete.
    {
        const report = try restoreForToolSet(api, grown, &grown_host, &without_rules, &callbacks, &session);
        defer report.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.complete, report.value.health);
        try std.testing.expectEqual(@as(u64, 2), report.value.policy_generation);
        try std.testing.expectEqual(@as(u32, 0), report.value.permission.restored_rules);
        try std.testing.expectEqual(@as(u32, 0), report.value.permission.invalidated_rules);
        try std.testing.expectEqual(@as(usize, 0), report.value.issues.len);
    }
    probe.session = session;
    {
        const described = try decodeDescription(api, session);
        defer described.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.complete, described.value.restore.health);
        try std.testing.expectEqual(@as(u64, 2), described.value.policy_generation);
    }
    // The Conversation stays usable, and the new tool still needs approval
    // under `default`: there is no rule that would allow it.
    probe.expected_run_id = 2;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 2, sdk.bytesView("invoke the Host echo"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), probe.host_asks);
    try std.testing.expectEqual(@as(u64, 2), probe.last_ask_generation);
    try std.testing.expectEqual(@as(u32, 1), probe.host_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.host_releases);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    // The same growth with an allow_session rule: the rule is lost, and the
    // report says so consistently, in counts and in one issue.
    {
        const report = try restoreForToolSet(api, grown, &grown_host, &with_rule, &callbacks, &session);
        defer report.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.degraded, report.value.health);
        try std.testing.expectEqual(@as(u64, 2), report.value.policy_generation);
        try std.testing.expectEqual(@as(u32, 0), report.value.permission.restored_rules);
        try std.testing.expectEqual(@as(u32, 1), report.value.permission.invalidated_rules);
        try std.testing.expectEqual(@as(usize, 1), report.value.issues.len);
        const issue = report.value.issues[0];
        try std.testing.expectEqual(sdk.protocol.AuthoritySubsystem.permission, issue.subsystem);
        try std.testing.expectEqual(sdk.protocol.AuthorityIssueReason.policy_changed, issue.reason);
        try std.testing.expect(issue.permission_rule_id != null);
        try std.testing.expectEqualStrings("Write", issue.canonical_name.?);
    }
    probe.session = session;
    {
        const described = try decodeDescription(api, session);
        defer described.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.degraded, described.value.restore.health);
        try std.testing.expectEqual(@as(u32, 1), described.value.restore.invalidated_permission_rules);
        try std.testing.expectEqual(@as(usize, 1), described.value.restore.issues.len);
    }
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    // An unchanged tool set keeps the rule and the generation, as before.
    {
        const report = try restoreForToolSet(api, original, &host, &with_rule, &callbacks, &session);
        defer report.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.complete, report.value.health);
        try std.testing.expectEqual(@as(u64, 1), report.value.policy_generation);
        try std.testing.expectEqual(@as(u32, 1), report.value.permission.restored_rules);
        try std.testing.expectEqual(@as(u32, 0), report.value.permission.invalidated_rules);
        try std.testing.expectEqual(@as(usize, 0), report.value.issues.len);
    }
}

// ── Revision 20: Host input submitted to an active Run (#270) ───────────────

const RunInputSubmission = struct {
    input_id: u64,
    text: []const u8,
    /// Run to submit under; null means the callback's own Run.
    run_id: ?u64 = null,
    expect: u32 = wire.STATUS_OK,
    /// Checked when non-zero.
    expect_sequence: u32 = 0,
};

const RunInputAdoption = struct {
    input_id: u64,
    sequence: u32,
    turn: u32,
};

/// Callbacks for the Revision 20 tests. `on_stream` is submitted from inside
/// the first turn-1 `output_segment_begin` (the request is out, its response
/// stream is open); `on_ui` from inside the first Host UI request, before it
/// is answered; `hook` runs at the same stream point for custom checks.
/// Wrong outcomes are counted in `mismatches` rather than returned as
/// callback failures, so they fail the test instead of poisoning the Session.
const RunInputProbe = struct {
    api: sdk.Api,
    session: ?*wire.SessionHandle = null,
    on_stream: []const RunInputSubmission = &.{},
    on_ui: []const RunInputSubmission = &.{},
    hook: ?*const fn (*RunInputProbe, u64) void = null,
    /// Sees every known event, for tests that submit at a specific edge.
    event_hook: ?*const fn (*RunInputProbe, u64, sdk.CoreEvent) void = null,
    stage: u32 = 0,
    fatal_on_adoption: bool = false,
    streamed: bool = false,
    ui_submitted: bool = false,
    mismatches: u32 = 0,
    adopted: [80]RunInputAdoption = undefined,
    adopted_len: usize = 0,
    ui_calls: u32 = 0,
    host_calls: u32 = 0,

    fn mismatch(self: *RunInputProbe, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("run input probe: " ++ fmt ++ "\n", args);
        self.mismatches += 1;
    }

    fn submit(self: *RunInputProbe, run_id: u64, submission: RunInputSubmission) void {
        var receipt = std.mem.zeroes(wire.InputReceiptV1);
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        const status = self.api.session().submitInput(
            self.session,
            submission.run_id orelse run_id,
            submission.input_id,
            sdk.bytesView(submission.text),
            &receipt,
            &diagnostic,
        );
        self.api.bufferRelease()(&diagnostic);
        if (status != submission.expect)
            self.mismatch("input {d}: status {d}, expected {d}", .{ submission.input_id, status, submission.expect });
        if (status == wire.STATUS_OK and receipt.struct_size != @sizeOf(wire.InputReceiptV1))
            self.mismatch("input {d}: receipt not written", .{submission.input_id});
        if (status != wire.STATUS_OK and receipt.sequence != 0)
            self.mismatch("input {d}: receipt written on failure", .{submission.input_id});
        if (submission.expect_sequence != 0 and receipt.sequence != submission.expect_sequence)
            self.mismatch("input {d}: sequence {d}, expected {d}", .{ submission.input_id, receipt.sequence, submission.expect_sequence });
    }

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *RunInputProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const value = switch (parsed.value) {
            .known => |known| known,
            .unknown => return wire.EVENT_CONTINUE,
        };
        if (self.event_hook) |hook| hook(self, run.run_id, value);
        switch (value) {
            .output_segment_begin => |segment| if (segment.turn == 1 and !self.streamed) {
                self.streamed = true;
                for (self.on_stream) |submission| self.submit(run.run_id, submission);
                if (self.hook) |hook| hook(self, run.run_id);
            },
            .input_adopted => |adopted| {
                if (self.adopted_len == self.adopted.len) return wire.EVENT_FATAL;
                self.adopted[self.adopted_len] = .{ .input_id = adopted.input_id, .sequence = adopted.sequence, .turn = adopted.turn };
                self.adopted_len += 1;
                if (self.fatal_on_adoption) return wire.EVENT_FATAL;
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, request_json: wire.BytesViewV1, out_response: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *RunInputProbe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.UI_FATAL;
        const encoded = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const request = switch (parsed.value) {
            .permission => |value| value,
            else => return wire.UI_FATAL,
        };
        // Input submitted while the approval waits is queued; it never stands
        // in for the answer, which this callback still gives.
        if (!self.ui_submitted) {
            self.ui_submitted = true;
            for (self.on_ui) |submission| self.submit(run.run_id, submission);
        }
        const response_json = sdk.encodeUiResponse(std.heap.c_allocator, parsed.value, .{ .permission = .{
            .permission = .allow_once,
            .request_id = request.request_id,
            .policy_generation = request.policy_generation,
        } }) catch return wire.UI_FATAL;
        const out = out_response orelse {
            std.heap.c_allocator.free(response_json);
            return wire.UI_FATAL;
        };
        out.* = .{ .ptr = response_json.ptr, .len = response_json.len };
        self.ui_calls += 1;
        return wire.UI_ANSWERED;
    }

    fn releaseUi(_: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
        }
        out.* = .{ .ptr = null, .len = 0 };
    }

    fn host(raw: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out_result: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *RunInputProbe = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
        const result = "host-ok";
        (out_result orelse return wire.HOST_FATAL).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        self.host_calls += 1;
        return wire.HOST_OK;
    }

    fn releaseHost(_: ?*anyopaque, result: ?*wire.OwnedBytesV1) callconv(.c) void {
        if (result) |out| out.* = .{ .ptr = null, .len = 0 };
    }

    fn adoptedSlice(self: *const RunInputProbe) []const RunInputAdoption {
        return self.adopted[0..self.adopted_len];
    }
};

/// One AgentCore Session whose model may call the Host tool `HostEcho`, which
/// asks for permission (PERMISSION_DEFAULT): a HOST_SSE turn is a tool turn
/// with an approval wait, followed by a turn boundary.
const RunInputFixture = struct {
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle = null,
    session: ?*wire.SessionHandle = null,
    diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },
    host_tools: [1]wire.HostToolV1 = undefined,
    allowed: [1]wire.BytesViewV1 = undefined,
    host: wire.SessionHostConfigV1 = undefined,
    callbacks: wire.SessionCallbacksV1 = undefined,

    fn init(self: *RunInputFixture, root: []const u8, url: []const u8, probe: *RunInputProbe, budget: ?*const wire.DurableBudgetProfileV1) !void {
        self.* = .{ .api = probe.api };
        errdefer self.deinit();
        var tool = std.mem.zeroes(wire.HostToolV1);
        tool.struct_size = @sizeOf(wire.HostToolV1);
        tool.ctx = probe;
        tool.name = sdk.bytesView("HostEcho");
        tool.description = sdk.bytesView("Echo a value through the Host");
        tool.input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}");
        tool.execute = RunInputProbe.host;
        tool.release_result = RunInputProbe.releaseHost;
        self.host_tools = .{tool};
        var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
        runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        runtime_config.host_tools = &self.host_tools;
        runtime_config.host_tool_count = self.host_tools.len;
        try std.testing.expectEqual(wire.STATUS_OK, self.api.runtime().create()(&runtime_config, null, &self.runtime, &self.diagnostic));

        self.allowed = .{sdk.bytesView("HostEcho")};
        self.host = std.mem.zeroes(wire.SessionHostConfigV1);
        self.host.struct_size = @sizeOf(wire.SessionHostConfigV1);
        self.host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
        self.host.permission_mode_code = wire.PERMISSION_DEFAULT;
        self.host.shell_policy_code = wire.SHELL_DISABLED;
        self.host.api_key = sdk.bytesView("test-key");
        self.host.base_url = sdk.bytesView(url);
        self.host.workspace_root = sdk.bytesView(root);
        self.host.workspace_home = sdk.bytesView(root);
        self.host.allowed_tools = &self.allowed;
        self.host.allowed_tool_count = self.allowed.len;
        self.host.durable_budget = budget;
        var create_config = sessionCreateConfig(&self.host, "test-model");
        self.callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        self.callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        self.callbacks.ctx = probe;
        self.callbacks.on_event = RunInputProbe.event;
        self.callbacks.on_ui_request = RunInputProbe.ui;
        self.callbacks.release_response = RunInputProbe.releaseUi;
        try std.testing.expectEqual(wire.STATUS_OK, self.api.session().create()(self.runtime, &create_config, &self.callbacks, &self.session, &self.diagnostic));
        probe.session = self.session;
    }

    fn run(self: *RunInputFixture, run_id: u64, prompt: []const u8, result: *wire.RunResultV1) u32 {
        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 4;
        // These tests size budgets and requests to the byte; the Revision 22
        // date block would move their arithmetic, not what they test.
        options.time_context_code = wire.TIME_CONTEXT_OFF;
        result.* = std.mem.zeroes(wire.RunResultV1);
        self.api.bufferRelease()(&self.diagnostic);
        return self.api.session().runText(self.session, run_id, sdk.bytesView(prompt), &options, result, &self.diagnostic);
    }

    fn submit(self: *RunInputFixture, run_id: u64, input_id: u64, text: []const u8) u32 {
        var receipt = std.mem.zeroes(wire.InputReceiptV1);
        self.api.bufferRelease()(&self.diagnostic);
        return self.api.session().submitInput(self.session, run_id, input_id, sdk.bytesView(text), &receipt, &self.diagnostic);
    }

    fn deinit(self: *RunInputFixture) void {
        if (self.session) |handle| _ = self.api.session().destroy()(handle, &self.diagnostic);
        self.session = null;
        self.api.bufferRelease()(&self.diagnostic);
        if (self.runtime) |handle| _ = self.api.runtime().destroy()(handle, &self.diagnostic);
        self.runtime = null;
        self.api.bufferRelease()(&self.diagnostic);
    }
};

fn runInputApi() !sdk.Api {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    return sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
}

fn requestBody(server: *harness.MockServer, index: usize) ![]const u8 {
    const captured = server.requestAt(index) orelse return error.MissingProviderRequest;
    return captured.body();
}

test "L2 Revision 20 input submitted during the stream and during a Permission wait joins the next request in order (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{
        .api = try runInputApi(),
        .on_stream = &.{
            .{ .input_id = 10, .text = "STREAMED_STEERING", .expect_sequence = 1 },
            // Another Run's id and the zero id are refused without effect.
            .{ .input_id = 99, .text = "wrong run", .run_id = 2, .expect = wire.STATUS_STALE_RUN },
            .{ .input_id = 98, .text = "zero run", .run_id = 0, .expect = wire.STATUS_INVALID_ARGUMENT },
        },
        .on_ui = &.{
            .{ .input_id = 11, .text = "APPROVAL_STEERING", .expect_sequence = 2 },
            // A duplicate id is refused for the rest of the Run.
            .{ .input_id = 10, .text = "duplicate", .expect = wire.STATUS_INVALID_ARGUMENT },
            .{ .input_id = 12, .text = "SECOND_APPROVAL_STEERING", .expect_sequence = 3 },
        },
    };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "invoke the Host echo", &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    // The approval was answered and the tool ran: input never answers it.
    try std.testing.expectEqual(@as(u32, 1), probe.ui_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.host_calls);

    // Adopted at the boundary before turn 2, in acceptance order.
    try std.testing.expectEqualSlices(RunInputAdoption, &.{
        .{ .input_id = 10, .sequence = 1, .turn = 2 },
        .{ .input_id = 11, .sequence = 2, .turn = 2 },
        .{ .input_id = 12, .sequence = 3, .turn = 2 },
    }, probe.adoptedSlice());
    try std.testing.expectEqual(@as(u32, 3), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 3), result.input_adopted_count);

    // The request already sent when the input arrived is not changed; the next
    // one carries every input as a user record after the tool result.
    const first = try requestBody(server, 0);
    try std.testing.expect(std.mem.indexOf(u8, first, "STREAMED_STEERING") == null);
    const second = try requestBody(server, 1);
    const tool_result = std.mem.indexOf(u8, second, "host-ok") orelse return error.MissingToolResult;
    const streamed = std.mem.indexOf(u8, second, "STREAMED_STEERING") orelse return error.MissingAdoptedInput;
    const approval = std.mem.indexOf(u8, second, "\"APPROVAL_STEERING") orelse return error.MissingAdoptedInput;
    const later = std.mem.indexOf(u8, second, "SECOND_APPROVAL_STEERING") orelse return error.MissingAdoptedInput;
    try std.testing.expect(tool_result < streamed and streamed < approval and approval < later);
    try std.testing.expect(std.mem.indexOf(u8, second, "duplicate") == null);

    // The Run is over: its id is too late, an unknown id stale.
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, fixture.submit(1, 50, "after the Run"));
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, fixture.submit(7, 50, "never admitted"));

    // Adopted input is ordinary Conversation state: a checkpoint carries it to
    // a restored Session, whose next request still holds it.
    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.sessionControl().exportCheckpoint()(fixture.session, &export_config, &export_result, &fixture.diagnostic));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().destroy()(fixture.session, &fixture.diagnostic));
    fixture.session = null;
    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &fixture.host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    defer fixture.api.bufferRelease()(&restore_report);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.sessionControl().restore()(fixture.runtime, &restore_config, &fixture.callbacks, &fixture.session, &restore_report, &fixture.diagnostic));
    probe.session = fixture.session;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(2, "continue after restore", &result));
    try std.testing.expectEqual(@as(u32, 0), result.input_accepted_count);
    const restored = try requestBody(server, 2);
    const restored_streamed = std.mem.indexOf(u8, restored, "STREAMED_STEERING") orelse return error.AdoptedInputLostByCheckpoint;
    const restored_later = std.mem.indexOf(u8, restored, "SECOND_APPROVAL_STEERING") orelse return error.AdoptedInputLostByCheckpoint;
    try std.testing.expect(restored_streamed < restored_later);
}

test "L2 Revision 20 input accepted by a Run that ends first reconciles as not adopted (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{
        .api = try runInputApi(),
        .on_stream = &.{.{ .input_id = 20, .text = "NEVER_ADOPTED", .expect_sequence = 1 }},
    };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "single turn", &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    // Accepted, but the Run ended at end_turn before another boundary.
    try std.testing.expectEqual(@as(u32, 1), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 0), result.input_adopted_count);
    try std.testing.expectEqual(@as(usize, 0), probe.adopted_len);
    // A later call that reuses the id is refused before admission and admits
    // nothing: it reports zero, not Run 1's counts.
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, fixture.run(1, "same id again", &result));
    try std.testing.expectEqual(@as(u32, 0), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 0), result.input_adopted_count);
    // It never entered the Conversation, so the next Run does not see it.
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(2, "next Run", &result));
    try std.testing.expect(std.mem.indexOf(u8, try requestBody(server, 1), "NEVER_ADOPTED") == null);
}

test "L2 Revision 20 a max_tokens continuation boundary does not adopt input (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ CONTINUATION_HEAD_SSE, CONTINUATION_TAIL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{
        .api = try runInputApi(),
        .on_stream = &.{.{ .input_id = 30, .text = "BETWEEN_THE_HALVES" }},
    };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "a long answer", &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    // The continuation request keeps the truncated answer one answer: the
    // input is not spliced between its halves, and the tail ended the Run.
    try std.testing.expect(std.mem.indexOf(u8, try requestBody(server, 1), "BETWEEN_THE_HALVES") == null);
    try std.testing.expectEqual(@as(u32, 1), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 0), result.input_adopted_count);
}

fn submitLimitsHook(probe: *RunInputProbe, run_id: u64) void {
    const session = probe.api.session();
    var receipt = std.mem.zeroes(wire.InputReceiptV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer probe.api.bufferRelease()(&diagnostic);
    const expectStatus = struct {
        fn check(p: *RunInputProbe, status: u32, expected: u32, what: []const u8) void {
            if (status != expected) p.mismatch("{s}: status {d}, expected {d}", .{ what, status, expected });
        }
    }.check;

    // Malformed submissions.
    var input = wire.SubmittedInputV1{
        .struct_size = @sizeOf(wire.SubmittedInputV1),
        .reserved0 = 0,
        .input_id = 1,
        .text = sdk.bytesView("ok"),
        .reserved = [_]u64{0} ** 2,
    };
    var bad = input;
    bad.struct_size -= 8;
    expectStatus(probe, session.submitInputFn()(probe.session, run_id, &bad, &receipt, &diagnostic), wire.STATUS_INVALID_ARGUMENT, "struct_size");
    probe.api.bufferRelease()(&diagnostic);
    bad = input;
    bad.reserved[1] = 1;
    expectStatus(probe, session.submitInputFn()(probe.session, run_id, &bad, &receipt, &diagnostic), wire.STATUS_INVALID_ARGUMENT, "reserved");
    probe.api.bufferRelease()(&diagnostic);
    bad = input;
    bad.input_id = 0;
    expectStatus(probe, session.submitInputFn()(probe.session, run_id, &bad, &receipt, &diagnostic), wire.STATUS_INVALID_ARGUMENT, "zero id");
    probe.api.bufferRelease()(&diagnostic);
    expectStatus(probe, session.submitInputFn()(probe.session, run_id, null, &receipt, &diagnostic), wire.STATUS_INVALID_ARGUMENT, "null input");
    probe.api.bufferRelease()(&diagnostic);
    expectStatus(probe, session.submitInputFn()(probe.session, run_id, &input, null, &diagnostic), wire.STATUS_INVALID_ARGUMENT, "null receipt");
    probe.api.bufferRelease()(&diagnostic);
    for ([_][]const u8{ "", " \t\r\n", "\xff\xfe" }) |text| {
        expectStatus(probe, session.submitInput(probe.session, run_id, 2, sdk.bytesView(text), &receipt, &diagnostic), wire.STATUS_INVALID_ARGUMENT, "blank or invalid UTF-8");
        probe.api.bufferRelease()(&diagnostic);
    }
    // A text above the published per-Run byte limit is a resource limit.
    const oversized = std.heap.page_allocator.alloc(u8, wire.MAX_SUBMITTED_INPUT_BYTES_V1 + 1) catch {
        probe.mismatch("oversized buffer allocation failed", .{});
        return;
    };
    defer std.heap.page_allocator.free(oversized);
    @memset(oversized, 'x');
    expectStatus(probe, session.submitInput(probe.session, run_id, 3, sdk.bytesView(oversized), &receipt, &diagnostic), wire.STATUS_RESOURCE_LIMIT, "oversized");
    probe.api.bufferRelease()(&diagnostic);

    // Exactly MAX_SUBMITTED_INPUTS_V1 inputs fit; the next is a resource limit.
    var id: u64 = 100;
    while (id < 100 + wire.MAX_SUBMITTED_INPUTS_V1) : (id += 1) {
        expectStatus(probe, session.submitInput(probe.session, run_id, id, sdk.bytesView("n"), &receipt, &diagnostic), wire.STATUS_OK, "within count");
        probe.api.bufferRelease()(&diagnostic);
    }
    expectStatus(probe, session.submitInput(probe.session, run_id, id, sdk.bytesView("n"), &receipt, &diagnostic), wire.STATUS_RESOURCE_LIMIT, "over count");
    if (receipt.sequence != 0) probe.mismatch("receipt written on a refused input", .{});
}

test "L2 Revision 20 submit_input validates arguments and per-Run limits without disturbing the Run (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{ .api = try runInputApi(), .hook = submitLimitsHook };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "invoke the Host echo", &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    // Only the accepted inputs count, and every one of them was adopted.
    try std.testing.expectEqual(@as(u32, wire.MAX_SUBMITTED_INPUTS_V1), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, wire.MAX_SUBMITTED_INPUTS_V1), result.input_adopted_count);
    try std.testing.expectEqual(@as(usize, wire.MAX_SUBMITTED_INPUTS_V1), probe.adopted_len);
    for (probe.adoptedSlice(), 0..) |adopted, index| {
        try std.testing.expectEqual(@as(u64, 100 + index), adopted.input_id);
        try std.testing.expectEqual(@as(u32, @intCast(index + 1)), adopted.sequence);
    }
}

test "L2 Revision 20 submitted input counts toward the Run's input cap and is refused, not fatal, past it (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    // Root prompt (300 bytes) plus each input are one Run's host input,
    // bounded together by input_cap_bytes: a 150-byte input still fits under
    // 512, a further 50 bytes does not.
    const budget = wire.DurableBudgetProfileV1{
        .struct_size = @sizeOf(wire.DurableBudgetProfileV1),
        .reserved0 = 0,
        .hard_bytes = 4 * 1024 * 1024,
        .soft_bytes = 3 * 1024 * 1024,
        .input_cap_bytes = 512,
        .provider_request_cap_bytes = 512 * 1024,
        .provider_result_cap_bytes = 64 * 1024,
        .tool_result_cap_bytes = 64 * 1024,
        .mcp_result_cap_bytes = 64 * 1024,
        .audit_reserve_bytes = 64 * 1024,
        .terminal_reserve_bytes = 64 * 1024,
        .reserved = [_]u64{0} ** 4,
    };
    const fits = "F" ** 150;
    const over = "O" ** 50;
    var probe = RunInputProbe{
        .api = try runInputApi(),
        .on_ui = &.{
            .{ .input_id = 1, .text = fits, .expect_sequence = 1 },
            .{ .input_id = 2, .text = over, .expect = wire.STATUS_CHECKPOINT_BUDGET_REQUIRED },
        },
    };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, &budget);
    defer fixture.deinit();

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "P" ** 300, &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    // The refusal refused one submission; the Run went on and finished.
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 1), result.input_adopted_count);
    const second = try requestBody(server, 1);
    try std.testing.expect(std.mem.indexOf(u8, second, fits) != null);
    try std.testing.expect(std.mem.indexOf(u8, second, over) == null);
}

test "L2 Revision 20 a failed adoption callback poisons the Session but the counts still report the adoption (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{
        .api = try runInputApi(),
        .on_ui = &.{
            .{ .input_id = 40, .text = "ADOPTED_THEN_FAILED" },
            .{ .input_id = 41, .text = "NEVER_AFTER_FAILURE" },
        },
        .fatal_on_adoption = true,
    };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_CALLBACK_FAILED, fixture.run(1, "invoke the Host echo", &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    // The Host rejected the acknowledgement, yet the input was appended before
    // it: the counts, defined on every status, say so. The rejection aborted
    // the Run: the second input is not adopted and no further request is sent.
    try std.testing.expectEqual(@as(usize, 1), probe.adopted_len);
    try std.testing.expectEqual(@as(u32, 2), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 1), result.input_adopted_count);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, fixture.submit(1, 42, "poisoned"));
}

const RunInputRacer = struct {
    api: sdk.Api,
    session: ?*wire.SessionHandle,
    /// Set by the test once `session_run_input` returned: from then on every
    /// submission must be too late, which ends the loop deterministically.
    run_returned: std.atomic.Value(bool) = .init(false),
    accepted: u32 = 0,
    unexpected: u32 = 0,
    first_unexpected: u32 = 0,
    finished: bool = false,

    fn race(self: *RunInputRacer) void {
        var id: u64 = 1;
        // Until the Run is over: stale before admission, then accepted (or the
        // count limit), then too late. Nothing else, and nothing after too late.
        while (true) {
            const returned = self.run_returned.load(.acquire);
            var receipt = std.mem.zeroes(wire.InputReceiptV1);
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const status = self.api.session().submitInput(self.session, 1, id, sdk.bytesView("RACED_INPUT"), &receipt, &diagnostic);
            self.api.bufferRelease()(&diagnostic);
            switch (status) {
                wire.STATUS_OK => {
                    self.accepted += 1;
                    id += 1;
                },
                wire.STATUS_STALE_RUN, wire.STATUS_RESOURCE_LIMIT => {},
                wire.STATUS_TOO_LATE => {
                    self.finished = true;
                    return;
                },
                else => {
                    if (self.unexpected == 0) self.first_unexpected = status;
                    self.unexpected += 1;
                },
            }
            // The Run had returned before this submission, yet it was not too
            // late: record it (finished stays false) and stop.
            if (returned) return;
            std.Thread.yield() catch {};
        }
    }
};

test "L2 Revision 20 submit_input racing Run completion is either counted or too late (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{ .api = try runInputApi() };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var racer = RunInputRacer{ .api = probe.api, .session = fixture.session };
    const thread = try std.Thread.spawn(.{}, RunInputRacer.race, .{&racer});
    var result: wire.RunResultV1 = undefined;
    const status = fixture.run(1, "invoke the Host echo", &result);
    racer.run_returned.store(true, .release);
    // The Host contract: no later call on the handle until submit returns.
    thread.join();
    try std.testing.expectEqual(wire.STATUS_OK, status);
    try std.testing.expect(racer.finished);
    try std.testing.expectEqual(@as(u32, 0), racer.first_unexpected);
    try std.testing.expectEqual(@as(u32, 0), racer.unexpected);
    // Every OK is in the count; adoption is a prefix of acceptance.
    try std.testing.expectEqual(racer.accepted, result.input_accepted_count);
    try std.testing.expect(result.input_adopted_count <= result.input_accepted_count);
    try std.testing.expectEqual(@as(usize, result.input_adopted_count), probe.adopted_len);
    for (probe.adoptedSlice(), 0..) |adopted, index|
        try std.testing.expectEqual(@as(u32, @intCast(index + 1)), adopted.sequence);
}

fn forkRefusalHook(probe: *RunInputProbe, run_id: u64, event: sdk.CoreEvent) void {
    switch (event) {
        // Admitted, not yet claimed by the fork: the window is still open.
        .run_state => |state| if (state.phase == .starting and probe.stage == 0) {
            probe.stage = 1;
            probe.submit(run_id, .{ .input_id = 1, .text = "BEFORE_FORK_CLAIM", .expect_sequence = 1 });
        },
        // The fork announces its child prompt after claiming the Run: from
        // here no boundary of this Run can adopt Host input.
        .prompt_manifest => if (probe.stage == 1) {
            probe.stage = 2;
            probe.submit(run_id, .{ .input_id = 2, .text = "DURING_FORK", .expect = wire.STATUS_INVALID_STATE });
        },
        else => {},
    }
}

test "L2 Revision 20 a forked Skill Run refuses input it could never adopt (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "forked",
        "---\nname: Forked\ndescription: Runs in a fresh child Conversation\ncontext: fork\n---\nFORKED_SKILL_SENTINEL",
    );
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{ .api = try runInputApi(), .event_hook = forkRefusalHook };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("run-input-fork-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer fixture.api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.skill().resolveCatalog()(fixture.runtime, &query, &catalog, &descriptor, &fixture.diagnostic));
    defer if (catalog) |handle| {
        _ = fixture.api.skill().releaseCatalog()(handle, &fixture.diagnostic);
    };
    const descriptor_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    var policy = try DecodedSkillPolicy.init(a, descriptor_bytes);
    defer policy.deinit();
    const ids = try extractCatalogIdentities(a, descriptor_bytes, "forked");
    defer a.free(ids.revision);
    defer a.free(ids.skill_id);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.skill().bindPolicy()(fixture.session, catalog, &policy.policy, &fixture.diagnostic));

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 2;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runSkill(
        fixture.session,
        1,
        sdk.bytesView(ids.skill_id),
        sdk.bytesView(ids.revision),
        sdk.bytesView(""),
        &options,
        &result,
        &fixture.diagnostic,
    ));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    try std.testing.expectEqual(@as(u32, 2), probe.stage);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    // The input accepted before the fork claimed the Run never reached a
    // Conversation; the one after was refused outright.
    try std.testing.expectEqual(@as(u32, 1), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 0), result.input_adopted_count);
    try std.testing.expectEqual(@as(usize, 0), probe.adopted_len);
    try std.testing.expect(std.mem.indexOf(u8, try requestBody(server, 0), "BEFORE_FORK_CLAIM") == null);
}

fn abortThenSubmitHook(probe: *RunInputProbe, run_id: u64) void {
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    const abort_status = probe.api.session().abort()(probe.session, run_id, wire.ABORT_USER_REQUEST, &diagnostic);
    probe.api.bufferRelease()(&diagnostic);
    if (abort_status != wire.STATUS_OK) probe.mismatch("abort status {d}", .{abort_status});
    // The loop checks abort before the input boundary: nothing submitted now
    // could ever be adopted, so it is refused as too late.
    probe.submit(run_id, .{ .input_id = 60, .text = "after abort", .expect = wire.STATUS_TOO_LATE });
}

test "L2 Revision 20 input submitted after the Run's abort was requested is too late (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{ .api = try runInputApi(), .hook = abortThenSubmitHook };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "invoke the Host echo", &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    try std.testing.expectEqual(wire.STOP_ABORTED, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 0), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 0), result.input_adopted_count);
}

fn submitAtStartHook(probe: *RunInputProbe, run_id: u64, event: sdk.CoreEvent) void {
    switch (event) {
        .run_state => |state| if (state.phase == .starting and probe.stage == 0) {
            probe.stage = 1;
            probe.submit(run_id, .{ .input_id = 70, .text = "BEFORE_FIRST_REQUEST", .expect_sequence = 1 });
        },
        else => {},
    }
}

test "L2 Revision 20 input accepted before the first request rides that request (#270)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = RunInputProbe{ .api = try runInputApi(), .event_hook = submitAtStartHook };
    var fixture: RunInputFixture = undefined;
    try fixture.init(root, url, &probe, null);
    defer fixture.deinit();

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "ROOT_PROMPT", &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches);
    try std.testing.expectEqual(@as(u32, 1), probe.stage);
    try std.testing.expectEqualSlices(RunInputAdoption, &.{.{ .input_id = 70, .sequence = 1, .turn = 1 }}, probe.adoptedSlice());
    try std.testing.expectEqual(@as(u32, 1), result.input_accepted_count);
    try std.testing.expectEqual(@as(u32, 1), result.input_adopted_count);
    const first = try requestBody(server, 0);
    const prompt = std.mem.indexOf(u8, first, "ROOT_PROMPT") orelse return error.MissingRootPrompt;
    const input = std.mem.indexOf(u8, first, "BEFORE_FIRST_REQUEST") orelse return error.MissingAdoptedInput;
    try std.testing.expect(prompt < input);
}

// ── Revision 23: goals (#277) ───────────────────────────────────────────

/// A turn that calls a tool the Session does not have (an error result, so
/// the Run takes another turn) and bills 50 tokens.
const GOAL_TOOL_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_goal\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":40,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_goal\",\"name\":\"NoSuchTool\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Records `goal_updated` events and the usage the provider reported.
const GoalEventProbe = struct {
    updates: u32 = 0,
    last_status: ?sdk.protocol.GoalStatus = null,
    last_tokens: u64 = 0,
    usage_tokens: u64 = 0,

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known| switch (known) {
                .goal_updated => |goal| {
                    self.updates += 1;
                    self.last_status = goal.status;
                    self.last_tokens = goal.tokens_used;
                },
                .usage => |usage| self.usage_tokens += usage.input_tokens + usage.output_tokens,
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }
};

const GoalReading = struct {
    arena: std.heap.ArenaAllocator,
    goal: ?sdk.protocol.Goal,

    fn deinit(self: *GoalReading) void {
        self.arena.deinit();
    }
};

fn readGoal(api: sdk.Api, session: ?*wire.SessionHandle) !GoalReading {
    var json = std.mem.zeroes(wire.OwnedBytesV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().get()(session, &json, &diagnostic));
    defer api.bufferRelease()(&json);
    var reading = GoalReading{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .goal = null };
    errdefer reading.arena.deinit();
    const encoded = try sdk.borrowedBytes(.{ .ptr = json.ptr, .len = json.len });
    reading.goal = (try sdk.protocol.decodeGoalDocument(reading.arena.allocator(), encoded)).goal;
    return reading;
}

fn goalSet(objective: []const u8, token_budget: u64) wire.GoalSetV1 {
    var request = std.mem.zeroes(wire.GoalSetV1);
    request.struct_size = @sizeOf(wire.GoalSetV1);
    request.objective = sdk.bytesView(objective);
    request.token_budget = token_budget;
    return request;
}

fn goalUpdate(fields: u32) wire.GoalUpdateV1 {
    var update = std.mem.zeroes(wire.GoalUpdateV1);
    update.struct_size = @sizeOf(wire.GoalUpdateV1);
    update.fields = fields;
    return update;
}

fn goalContinuationInput() wire.RunInputV1 {
    var input = std.mem.zeroes(wire.RunInputV1);
    input.struct_size = @sizeOf(wire.RunInputV1);
    input.kind_code = wire.RUN_INPUT_GOAL_CONTINUATION;
    return input;
}

fn expectDiagnosticNames(api: sdk.Api, diagnostic: *wire.OwnedBytesV1, reason: []const u8) !void {
    defer api.bufferRelease()(diagnostic);
    const text = try sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len });
    if (std.mem.indexOf(u8, text, reason) == null) {
        std.debug.print("expected {s} in diagnostic: {s}\n", .{ reason, text });
        return error.TestUnexpectedDiagnostic;
    }
}

test "L2 Revision 23 a goal-continuation Run works toward the Host's goal, charges it, reports the budget running out, and a checkpoint carries it (issue #277)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{ GOAL_TOOL_TURN_SSE, FINAL_SSE, FINAL_SSE }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtime().create()(&runtime_config, null, &runtime, &diagnostic));
    defer _ = api.runtime().destroy()(runtime, &diagnostic);

    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    var create_config = sessionCreateConfig(&host, "test-model");
    var probe = GoalEventProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = GoalEventProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic));
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };

    {
        var reading = try readGoal(api, session);
        defer reading.deinit();
        try std.testing.expect(reading.goal == null);
    }
    var set = goalSet("  ship <it> & say so  ", 30);
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().set()(session, &set, &diagnostic));
    const goal_id: [24]u8 = blk: {
        var reading = try readGoal(api, session);
        defer reading.deinit();
        const goal = reading.goal orelse return error.MissingGoal;
        try std.testing.expectEqualStrings("ship <it> & say so", goal.objective);
        try std.testing.expectEqual(sdk.protocol.GoalStatus.active, goal.status);
        try std.testing.expectEqual(@as(?u64, 30), goal.token_budget);
        try std.testing.expectEqual(@as(u64, 0), goal.tokens_used);
        break :blk goal.id[0..24].*;
    };

    // The runtime writes the continuation input from the goal; the budget
    // runs out on the first turn, so the second request asks for a wrap-up.
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 4;
    var result = std.mem.zeroes(wire.RunResultV1);
    var continuation = goalContinuationInput();
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runInput()(session, 1, &continuation, &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const first = (server.requestAt(0) orelse return error.MissingRequest).body();
    const second = (server.requestAt(1) orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, first, "Continue working toward the active goal.") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "ship &lt;it&gt; &amp; say so") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "token budget for the active goal is used up") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, second, "token budget for the active goal is used up"));
    // The events and the goal agree with what the provider billed.
    try std.testing.expect(probe.usage_tokens > 30);
    try std.testing.expect(probe.updates >= 2);
    try std.testing.expectEqual(sdk.protocol.GoalStatus.budget_limited, probe.last_status.?);
    try std.testing.expectEqual(probe.usage_tokens, probe.last_tokens);
    {
        var reading = try readGoal(api, session);
        defer reading.deinit();
        const goal = reading.goal orelse return error.MissingGoal;
        try std.testing.expectEqual(sdk.protocol.GoalStatus.budget_limited, goal.status);
        try std.testing.expectEqual(probe.usage_tokens, goal.tokens_used);
        try std.testing.expectEqualStrings(&goal_id, goal.id);
    }

    // A goal that is not active cannot be continued; nothing is sent.
    try std.testing.expectEqual(wire.STATUS_GOAL_CONFLICT, api.session().runInput()(session, 2, &continuation, &options, &result, &diagnostic));
    try expectDiagnosticNames(api, &diagnostic, "GoalNotActive");
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    // Room in the budget and resume, in one update.
    var resume_update = goalUpdate(wire.GOAL_FIELD_TOKEN_BUDGET | wire.GOAL_FIELD_ACTION);
    resume_update.token_budget = 1000;
    resume_update.action_code = wire.GOAL_ACTION_ACTIVATE;
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().update()(session, &resume_update, &diagnostic));

    // The checkpoint carries the goal (the marker-10 envelope).
    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic));
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, checkpoint.bytes.items[20..24], .little));
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionControl().restore()(runtime, &restore_config, &callbacks, &session, &restore_report, &diagnostic));
    api.bufferRelease()(&restore_report);
    const charged_before_restore = probe.usage_tokens;
    {
        var reading = try readGoal(api, session);
        defer reading.deinit();
        const goal = reading.goal orelse return error.MissingGoal;
        try std.testing.expectEqualStrings(&goal_id, goal.id);
        try std.testing.expectEqual(sdk.protocol.GoalStatus.active, goal.status);
        try std.testing.expectEqual(@as(?u64, 1000), goal.token_budget);
        try std.testing.expectEqual(charged_before_restore, goal.tokens_used);
    }
    // The restored Session keeps charging the same goal.
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runInput()(session, 2, &continuation, &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    var reading = try readGoal(api, session);
    defer reading.deinit();
    const goal = reading.goal orelse return error.MissingGoal;
    try std.testing.expect(probe.usage_tokens > charged_before_restore);
    try std.testing.expectEqual(probe.usage_tokens, goal.tokens_used);
    try std.testing.expectEqual(sdk.protocol.GoalStatus.active, goal.status);
}

test "Revision 23 goal operations are validated, and a refusal changes nothing (issue #277)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();
    const api = fixture.api;
    const session = fixture.session;
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);

    // Without a goal: update and continuation conflict, clear changes nothing.
    var pause = goalUpdate(wire.GOAL_FIELD_ACTION);
    pause.action_code = wire.GOAL_ACTION_PAUSE;
    try std.testing.expectEqual(wire.STATUS_GOAL_CONFLICT, api.goal().update()(session, &pause, &fixture.diagnostic));
    try expectDiagnosticNames(api, &fixture.diagnostic, "NoGoal");
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().clear()(session, &fixture.diagnostic));
    var continuation = goalContinuationInput();
    try std.testing.expectEqual(wire.STATUS_GOAL_CONFLICT, api.session().runInput()(session, 1, &continuation, &options, &result, &fixture.diagnostic));
    try expectDiagnosticNames(api, &fixture.diagnostic, "NoGoal");
    continuation.text = sdk.bytesView("x");
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.session().runInput()(session, 1, &continuation, &options, &result, &fixture.diagnostic));
    fixture.releaseDiagnostic();

    // Malformed set requests.
    const too_many_codepoints = "\u{4e2d}" ** 4001;
    const too_many_bytes = "x" ** (wire.MAX_GOAL_OBJECTIVE_BYTES_V1 + 1);
    for ([_][]const u8{ " \t\n", "bad \xff byte", too_many_codepoints, too_many_bytes }) |objective| {
        var request = goalSet(objective, 0);
        try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.goal().set()(session, &request, &fixture.diagnostic));
        fixture.releaseDiagnostic();
    }
    var wrong_size = goalSet("ship it", 0);
    wrong_size.struct_size -= 8;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.goal().set()(session, &wrong_size, &fixture.diagnostic));
    fixture.releaseDiagnostic();
    var reserved = goalSet("ship it", 0);
    reserved.reserved[2] = 1;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.goal().set()(session, &reserved, &fixture.diagnostic));
    fixture.releaseDiagnostic();
    {
        var reading = try readGoal(api, session);
        defer reading.deinit();
        try std.testing.expect(reading.goal == null);
    }

    // 4000 code points is the limit, not past it.
    var longest = goalSet("\u{4e2d}" ** 4000, 0);
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().set()(session, &longest, &fixture.diagnostic));
    var set = goalSet("ship it", 0);
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().set()(session, &set, &fixture.diagnostic));

    // Malformed updates.
    const Bad = struct { fields: u32, objective: []const u8 = "", token_budget: u64 = 0, action_code: u32 = 0 };
    for ([_]Bad{
        .{ .fields = 0 },
        .{ .fields = 8 },
        .{ .fields = wire.GOAL_FIELD_ACTION, .action_code = 9 },
        .{ .fields = wire.GOAL_FIELD_ACTION, .action_code = wire.GOAL_ACTION_PAUSE, .objective = "stray" },
        .{ .fields = wire.GOAL_FIELD_ACTION, .action_code = wire.GOAL_ACTION_PAUSE, .token_budget = 5 },
        .{ .fields = wire.GOAL_FIELD_TOKEN_BUDGET, .token_budget = 5, .action_code = wire.GOAL_ACTION_PAUSE },
        .{ .fields = wire.GOAL_FIELD_OBJECTIVE, .objective = "  " },
    }) |bad| {
        var update = goalUpdate(bad.fields);
        if (bad.objective.len != 0) update.objective = sdk.bytesView(bad.objective);
        update.token_budget = bad.token_budget;
        update.action_code = bad.action_code;
        try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.goal().update()(session, &update, &fixture.diagnostic));
        fixture.releaseDiagnostic();
    }

    // Refused transitions name the rule, and leave the objective unchanged
    // even when the same update also edits it.
    var complete = goalUpdate(wire.GOAL_FIELD_ACTION);
    complete.action_code = wire.GOAL_ACTION_COMPLETE;
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().update()(session, &complete, &fixture.diagnostic));
    var block = goalUpdate(wire.GOAL_FIELD_ACTION);
    block.action_code = wire.GOAL_ACTION_BLOCK;
    try std.testing.expectEqual(wire.STATUS_GOAL_CONFLICT, api.goal().update()(session, &block, &fixture.diagnostic));
    try expectDiagnosticNames(api, &fixture.diagnostic, "GoalComplete");
    var edit_and_pause = goalUpdate(wire.GOAL_FIELD_OBJECTIVE | wire.GOAL_FIELD_ACTION);
    edit_and_pause.objective = sdk.bytesView("ship more");
    edit_and_pause.action_code = wire.GOAL_ACTION_PAUSE;
    try std.testing.expectEqual(wire.STATUS_GOAL_CONFLICT, api.goal().update()(session, &edit_and_pause, &fixture.diagnostic));
    try expectDiagnosticNames(api, &fixture.diagnostic, "GoalNotActive");
    var complete_continuation = goalContinuationInput();
    try std.testing.expectEqual(wire.STATUS_GOAL_CONFLICT, api.session().runInput()(session, 1, &complete_continuation, &options, &result, &fixture.diagnostic));
    try expectDiagnosticNames(api, &fixture.diagnostic, "GoalNotActive");
    {
        var reading = try readGoal(api, session);
        defer reading.deinit();
        const goal = reading.goal orelse return error.MissingGoal;
        try std.testing.expectEqualStrings("ship it", goal.objective);
        try std.testing.expectEqual(sdk.protocol.GoalStatus.complete, goal.status);
        try std.testing.expect(goal.token_budget == null);
    }
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().clear()(session, &fixture.diagnostic));
    {
        var reading = try readGoal(api, session);
        defer reading.deinit();
        try std.testing.expect(reading.goal == null);
    }
    // Nothing above reached the provider, and Run 1 was never admitted.
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
    try std.testing.expectEqual(wire.STATUS_OK, api.session().runText(session, 1, sdk.bytesView("x"), &options, &result, &fixture.diagnostic));
}

test "Revision 23 a goal the durable budget cannot hold is refused before anything changes (issue #277)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    const budget = wire.DurableBudgetProfileV1{
        .struct_size = @sizeOf(wire.DurableBudgetProfileV1),
        .reserved0 = 0,
        .hard_bytes = 8 * 1024,
        .soft_bytes = 7 * 1024,
        .input_cap_bytes = 512,
        .provider_request_cap_bytes = 4096,
        .provider_result_cap_bytes = 2048,
        .tool_result_cap_bytes = 2048,
        .mcp_result_cap_bytes = 2048,
        .audit_reserve_bytes = 512,
        .terminal_reserve_bytes = 512,
        .reserved = [_]u64{0} ** 4,
    };
    var fixture = try PublicSessionFixture.initWithBudget(root, url, "test-model", &budget);
    defer fixture.deinit();
    const api = fixture.api;
    const session = fixture.session;

    var small = goalSet("ship it", 0);
    try std.testing.expectEqual(wire.STATUS_OK, api.goal().set()(session, &small, &fixture.diagnostic));
    // 12,000 bytes of objective do not fit in 8 KiB with the Run reserve.
    var large = goalSet("\u{4e2d}" ** 4000, 0);
    try std.testing.expectEqual(wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, api.goal().set()(session, &large, &fixture.diagnostic));
    fixture.releaseDiagnostic();
    var edit = goalUpdate(wire.GOAL_FIELD_OBJECTIVE);
    edit.objective = sdk.bytesView("\u{4e2d}" ** 4000);
    try std.testing.expectEqual(wire.STATUS_CHECKPOINT_BUDGET_REQUIRED, api.goal().update()(session, &edit, &fixture.diagnostic));
    fixture.releaseDiagnostic();
    var reading = try readGoal(api, session);
    defer reading.deinit();
    try std.testing.expectEqualStrings("ship it", (reading.goal orelse return error.MissingGoal).objective);
}

test "L2 Revision 23 a Skill invocation Run in its own context is charged to the Session's goal (issue #277)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "forked",
        "---\nname: Forked\ndescription: Runs in a fresh child Conversation\ncontext: fork\n---\nFORKED_SKILL_SENTINEL",
    );
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("goal-fork-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer fixture.api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.skill().resolveCatalog()(fixture.runtime, &query, &catalog, &descriptor, &fixture.diagnostic));
    defer if (catalog) |handle| {
        _ = fixture.api.skill().releaseCatalog()(handle, &fixture.diagnostic);
    };
    const descriptor_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    var policy = try DecodedSkillPolicy.init(a, descriptor_bytes);
    defer policy.deinit();
    const ids = try extractCatalogIdentities(a, descriptor_bytes, "forked");
    defer a.free(ids.revision);
    defer a.free(ids.skill_id);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.skill().bindPolicy()(fixture.session, catalog, &policy.policy, &fixture.diagnostic));

    var set = goalSet("ship it", 0);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.goal().set()(fixture.session, &set, &fixture.diagnostic));
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 2;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runSkill(
        fixture.session,
        1,
        sdk.bytesView(ids.skill_id),
        sdk.bytesView(ids.revision),
        sdk.bytesView(""),
        &options,
        &result,
        &fixture.diagnostic,
    ));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, try requestBody(server, 0), "FORKED_SKILL_SENTINEL") != null);
    var reading = try readGoal(fixture.api, fixture.session);
    defer reading.deinit();
    const goal = reading.goal orelse return error.MissingGoal;
    try std.testing.expect(goal.tokens_used > 0);
}

// ── Revision 24: host-scheduled teams (issue #277) ──────────────────────────

fn teamTextSse(comptime text: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

fn teamToolSse(comptime id: []const u8, comptime name: []const u8, comptime input_json: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" ++ input_json ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

test "L2 Revision 24 a host-scheduled lead delegates through the public ABI, describe shows the pending spawn, and poll takes a member's reply (issue #277)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));

    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);

    // A Runtime that admits the team tools.
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.enable_teams = 1;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    defer if (runtime) |h| {
        _ = api.runtime().destroy()(h, &diagnostic);
    };

    // Lead: TeamCreate crew, SpawnTeammate solver, then end.
    const lead_bodies = [_][]const u8{
        teamToolSse("t1", "TeamCreate", "{\\\"name\\\":\\\"crew\\\"}"),
        teamToolSse("t2", "SpawnTeammate", "{\\\"name\\\":\\\"solver\\\",\\\"prompt\\\":\\\"fix the parser\\\"}"),
        teamTextSse("delegated"),
    };
    var lead_srv = try harness.MockServer.startCassette(&lead_bodies, 0);
    defer lead_srv.stop();
    const lead_url = try lead_srv.urlOwned(a);
    defer a.free(lead_url);

    var lead_team = std.mem.zeroes(wire.TeamConfigV1);
    lead_team.struct_size = @sizeOf(wire.TeamConfigV1);
    lead_team.role_code = wire.TEAM_ROLE_LEAD;
    lead_team.team_name = sdk.bytesView("");

    const lead_allowed = [_]wire.BytesViewV1{ sdk.bytesView("TeamCreate"), sdk.bytesView("SpawnTeammate"), sdk.bytesView("SendMessage") };
    var lead_host = std.mem.zeroes(wire.SessionHostConfigV1);
    lead_host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    lead_host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    lead_host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    lead_host.shell_policy_code = wire.SHELL_DISABLED;
    lead_host.api_key = sdk.bytesView("test-key");
    lead_host.base_url = sdk.bytesView(lead_url);
    lead_host.workspace_root = sdk.bytesView(root);
    lead_host.workspace_home = sdk.bytesView(root);
    lead_host.allowed_tools = &lead_allowed;
    lead_host.allowed_tool_count = lead_allowed.len;
    lead_host.run_journal_mode_code = wire.RUN_JOURNAL_EPHEMERAL;
    lead_host.team = &lead_team;

    var lead_create = sessionCreateConfig(&lead_host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var lead_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &lead_create, &callbacks, &lead_session, &diagnostic),
    );
    defer if (lead_session) |h| {
        _ = api.session().destroy()(h, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 4;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(lead_session, 1, sdk.bytesView("form a team and delegate"), &options, &result, &diagnostic),
    );

    // describe names the lead's team and the recorded spawn, which is pending —
    // the lead keeps no running teammate.
    var team_json = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&team_json);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.team().describe()(lead_session, &team_json, &diagnostic),
    );
    const team_text = try sdk.borrowedBytes(.{ .ptr = team_json.ptr, .len = team_json.len });
    try std.testing.expect(std.mem.indexOf(u8, team_text, "\"role\":\"lead\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, team_text, "\"name\":\"crew\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, team_text, "\"pending_spawns\":[{\"name\":\"solver\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, team_text, "fix the parser") != null);

    // The member joins under the lead's logical session id and a fresh lease.
    var lead_desc = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&lead_desc);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().describe()(lead_session, &lead_desc, &diagnostic),
    );
    const lead_desc_text = try sdk.borrowedBytes(.{ .ptr = lead_desc.ptr, .len = lead_desc.len });
    const decoded_lead = try sdk.decodeSessionDescription(a, lead_desc_text);
    defer decoded_lead.deinit();

    const lease = core.session_id.gen();
    const member_bodies = [_][]const u8{
        teamToolSse("s1", "SendMessage", "{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"done: 42\\\",\\\"summary\\\":\\\"done\\\"}"),
        teamTextSse("idle"),
    };
    var member_srv = try harness.MockServer.startCassette(&member_bodies, 0);
    defer member_srv.stop();
    const member_url = try member_srv.urlOwned(a);
    defer a.free(member_url);

    var member_team = std.mem.zeroes(wire.TeamConfigV1);
    member_team.struct_size = @sizeOf(wire.TeamConfigV1);
    member_team.role_code = wire.TEAM_ROLE_MEMBER;
    member_team.team_name = sdk.bytesView("crew");
    member_team.member_name = sdk.bytesView("solver");
    member_team.lead_session_id = sdk.bytesView(decoded_lead.value.session_id);
    member_team.member_lease = sdk.bytesView(lease.asSlice());

    const member_allowed = [_]wire.BytesViewV1{sdk.bytesView("SendMessage")};
    var member_host = lead_host;
    member_host.base_url = sdk.bytesView(member_url);
    member_host.allowed_tools = &member_allowed;
    member_host.allowed_tool_count = member_allowed.len;
    member_host.team = &member_team;

    var member_create = sessionCreateConfig(&member_host, "test-model");
    var member_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &member_create, &callbacks, &member_session, &diagnostic),
    );
    defer if (member_session) |h| {
        _ = api.session().destroy()(h, &diagnostic);
    };

    var member_options = std.mem.zeroes(wire.RunOptionsV1);
    member_options.struct_size = @sizeOf(wire.RunOptionsV1);
    member_options.max_turns = 3;
    var member_result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(member_session, 1, sdk.bytesView("work and report"), &member_options, &member_result, &diagnostic),
    );

    // The lead's poll takes the member's reply as its next model input, read.
    var poll_json = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&poll_json);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.team().poll()(lead_session, &poll_json, &diagnostic),
    );
    const poll_text = try sdk.borrowedBytes(.{ .ptr = poll_json.ptr, .len = poll_json.len });
    try std.testing.expect(std.mem.indexOf(u8, poll_text, "done: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, poll_text, "teammate_id=\\\"solver\\\"") != null);

    // A second poll is empty: the first drained the inbox.
    var poll_again = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&poll_again);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.team().poll()(lead_session, &poll_again, &diagnostic),
    );
    const poll_again_text = try sdk.borrowedBytes(.{ .ptr = poll_again.ptr, .len = poll_again.len });
    try std.testing.expectEqualStrings("{\"input\":null}", poll_again_text);
}

// ── Revision 25: in-place provider credential update (#336) ─────────────────

const CREDENTIAL_A = "credential-a-336";
const CREDENTIAL_B = "credential-b-336";
const CREDENTIAL_C = "credential-c-336";

const HOST_ROTATE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_rotate\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_rotate\",\"name\":\"HostRotate\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const WEB_SEARCH_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_search\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_search\",\"name\":\"WebSearch\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"credential rotation\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const WEB_SEARCH_SUMMARY_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_summary\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Rotation keeps the Session.\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SERVICE_UNAVAILABLE_BODY = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"try again\"}}";
const STATUS_200 = "HTTP/1.1 200 OK";
const STATUS_503 = "HTTP/1.1 503 Service Unavailable";

/// The authorization header value the provider received in request `index`.
fn requestAuthorization(server: *harness.MockServer, index: usize) ![]const u8 {
    const captured = server.requestAt(index) orelse return error.MissingProviderRequest;
    const head_end = std.mem.indexOf(u8, captured.raw, "\r\n\r\n") orelse return error.MalformedProviderRequest;
    var lines = std.mem.splitSequence(u8, captured.raw[0..head_end], "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "authorization"))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return error.MissingAuthorization;
}

fn expectBearer(server: *harness.MockServer, index: usize, credential: []const u8) !void {
    const value = try requestAuthorization(server, index);
    if (!std.mem.startsWith(u8, value, "Bearer ") or !std.mem.eql(u8, value["Bearer ".len..], credential)) {
        std.debug.print("request {d} authorization [{s}], expected Bearer {s}\n", .{ index, value, credential });
        return error.UnexpectedAuthorization;
    }
}

/// Callbacks for the Revision 25 tests. `HostRotate`'s callback first offers
/// `refuse_first` (which must be refused) and then publishes `rotate_to`;
/// `on_retry` is published from inside the first `retry_notice` event. With
/// `block_tool`, `HostRotate` waits for `tool_release` after signalling
/// `tool_entered`. Wrong outcomes count as mismatches instead of failing the
/// callback, so they fail the test without poisoning the Session.
const CredentialProbe = struct {
    api: sdk.Api,
    session: ?*wire.SessionHandle = null,
    refuse_first: ?[]const u8 = null,
    rotate_to: ?[]const u8 = null,
    on_retry: ?[]const u8 = null,
    fatal_events: bool = false,
    block_tool: bool = false,
    tool_entered: std.atomic.Value(bool) = .init(false),
    tool_release: std.atomic.Value(bool) = .init(false),
    retries: u32 = 0,
    host_calls: u32 = 0,
    mismatches: std.atomic.Value(u32) = .init(0),

    fn mismatch(self: *CredentialProbe, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("credential probe: " ++ fmt ++ "\n", args);
        _ = self.mismatches.fetchAdd(1, .acq_rel);
    }

    /// One update through the public table, checked for `expect` and for a
    /// diagnostic that never names the candidate.
    fn update(self: *CredentialProbe, credential: []const u8, expect: u32) void {
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        defer self.api.bufferRelease()(&diagnostic);
        const status = self.api.session().updateCredential()(self.session, sdk.bytesView(credential), &diagnostic);
        if (status != expect) self.mismatch("update status {d}, expected {d}", .{ status, expect });
        if (diagnostic.ptr) |ptr| {
            const len = std.math.cast(usize, diagnostic.len) orelse return;
            if (credential.len >= 8 and std.mem.indexOf(u8, ptr[0..len], credential) != null)
                self.mismatch("diagnostic names the candidate", .{});
        }
    }

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *CredentialProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        _ = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        if (self.fatal_events) return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known| switch (known) {
                .retry_notice => {
                    self.retries += 1;
                    if (self.on_retry) |next| {
                        self.on_retry = null;
                        self.update(next, wire.STATUS_OK);
                    }
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn host(raw: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out_result: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *CredentialProbe = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
        self.host_calls += 1;
        if (self.refuse_first) |candidate| {
            self.refuse_first = null;
            self.update(candidate, wire.STATUS_INVALID_ARGUMENT);
        }
        if (self.rotate_to) |next| {
            self.rotate_to = null;
            self.update(next, wire.STATUS_OK);
        }
        if (self.block_tool) {
            self.tool_entered.store(true, .release);
            while (!self.tool_release.load(.acquire)) std.Thread.yield() catch {};
        }
        const result = "rotated";
        (out_result orelse return wire.HOST_FATAL).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        return wire.HOST_OK;
    }

    fn releaseHost(_: ?*anyopaque, result: ?*wire.OwnedBytesV1) callconv(.c) void {
        if (result) |out| out.* = .{ .ptr = null, .len = 0 };
    }
};

/// One full-access AgentCore Session created with CREDENTIAL_A whose model
/// may call the Host tool `HostRotate` and, with `web_search`, the built-in
/// WebSearch tool, which builds its own per-call provider client.
const CredentialFixture = struct {
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle = null,
    session: ?*wire.SessionHandle = null,
    diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },
    host_tools: [1]wire.HostToolV1 = undefined,
    builtins: [1]wire.BytesViewV1 = undefined,
    allowed: [2]wire.BytesViewV1 = undefined,
    host: wire.SessionHostConfigV1 = undefined,
    callbacks: wire.SessionCallbacksV1 = undefined,

    fn init(self: *CredentialFixture, root: []const u8, url: []const u8, probe: *CredentialProbe, web_search: bool) !void {
        self.* = .{ .api = probe.api };
        errdefer self.deinit();
        var tool = std.mem.zeroes(wire.HostToolV1);
        tool.struct_size = @sizeOf(wire.HostToolV1);
        tool.ctx = probe;
        tool.name = sdk.bytesView("HostRotate");
        tool.description = sdk.bytesView("Rotate the provider credential");
        tool.input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{},\"required\":[]}");
        tool.execute = CredentialProbe.host;
        tool.release_result = CredentialProbe.releaseHost;
        self.host_tools = .{tool};
        self.builtins = .{sdk.bytesView("WebSearch")};
        var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
        runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        runtime_config.host_tools = &self.host_tools;
        runtime_config.host_tool_count = self.host_tools.len;
        if (web_search) {
            runtime_config.builtin_tools = &self.builtins;
            runtime_config.builtin_tool_count = self.builtins.len;
        }
        try std.testing.expectEqual(wire.STATUS_OK, self.api.runtime().create()(&runtime_config, null, &self.runtime, &self.diagnostic));

        self.allowed = .{ sdk.bytesView("HostRotate"), sdk.bytesView("WebSearch") };
        self.host = std.mem.zeroes(wire.SessionHostConfigV1);
        self.host.struct_size = @sizeOf(wire.SessionHostConfigV1);
        self.host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
        self.host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
        self.host.shell_policy_code = wire.SHELL_DISABLED;
        self.host.api_key = sdk.bytesView(CREDENTIAL_A);
        self.host.base_url = sdk.bytesView(url);
        self.host.workspace_root = sdk.bytesView(root);
        self.host.workspace_home = sdk.bytesView(root);
        self.host.allowed_tools = &self.allowed;
        self.host.allowed_tool_count = if (web_search) 2 else 1;
        var create_config = sessionCreateConfig(&self.host, "credential-model");
        self.callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        self.callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        self.callbacks.ctx = probe;
        self.callbacks.on_event = CredentialProbe.event;
        try std.testing.expectEqual(wire.STATUS_OK, self.api.session().create()(self.runtime, &create_config, &self.callbacks, &self.session, &self.diagnostic));
        probe.session = self.session;
    }

    fn run(self: *CredentialFixture, run_id: u64, prompt: []const u8, result: *wire.RunResultV1) u32 {
        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 4;
        result.* = std.mem.zeroes(wire.RunResultV1);
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        defer self.api.bufferRelease()(&diagnostic);
        return self.api.session().runText(self.session, run_id, sdk.bytesView(prompt), &options, result, &diagnostic);
    }

    fn update(self: *CredentialFixture, credential: wire.BytesViewV1) u32 {
        self.api.bufferRelease()(&self.diagnostic);
        return self.api.session().updateCredential()(self.session, credential, &self.diagnostic);
    }

    fn deinit(self: *CredentialFixture) void {
        if (self.session) |handle| _ = self.api.session().destroy()(handle, &self.diagnostic);
        self.session = null;
        self.api.bufferRelease()(&self.diagnostic);
        if (self.runtime) |handle| _ = self.api.runtime().destroy()(handle, &self.diagnostic);
        self.runtime = null;
        self.api.bufferRelease()(&self.diagnostic);
    }
};

fn credentialProbe() !CredentialProbe {
    return .{ .api = try runInputApi() };
}

test "L2 Revision 25 update_credential while idle reaches the next request, refusals keep it, and no copy leaves the Session (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, false);
    defer fixture.deinit();
    var result: wire.RunResultV1 = undefined;

    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "first", &result));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.update(sdk.bytesView(CREDENTIAL_B)));

    // Each refusal names its rule, never the bytes, and keeps CREDENTIAL_B.
    const too_long = try a.alloc(u8, @as(usize, @intCast(wire.MAX_CREDENTIAL_BYTES_V1)) + 1);
    defer a.free(too_long);
    @memset(too_long, 'k');
    const Refusal = struct { candidate: wire.BytesViewV1, status: u32 };
    const refusals = [_]Refusal{
        .{ .candidate = sdk.bytesView(""), .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .candidate = sdk.bytesView("credential b 336"), .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .candidate = sdk.bytesView("credential-b-336\r\nx-injected: 1"), .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .candidate = sdk.bytesView("credential-\x00-336"), .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .candidate = sdk.bytesView("credential-\xc3\xa9-336"), .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .candidate = sdk.bytesView(too_long), .status = wire.STATUS_RESOURCE_LIMIT },
        .{ .candidate = .{ .ptr = null, .len = 4 }, .status = wire.STATUS_INVALID_ARGUMENT },
    };
    for (refusals) |refusal| {
        try std.testing.expectEqual(refusal.status, fixture.update(refusal.candidate));
        const message = try sdk.borrowedBytes(.{ .ptr = fixture.diagnostic.ptr, .len = fixture.diagnostic.len });
        try std.testing.expect(message.len != 0);
        if (refusal.candidate.ptr) |ptr| if (refusal.candidate.len != 0) {
            const candidate = ptr[0..@intCast(refusal.candidate.len)];
            try std.testing.expect(std.mem.indexOf(u8, message, candidate[0..@min(candidate.len, 12)]) == null);
        };
    }
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, fixture.api.session().updateCredential()(null, sdk.bytesView(CREDENTIAL_C), &fixture.diagnostic));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(2, "second", &result));

    // The longest credential the limit admits is accepted whole.
    const longest = too_long[0..@as(usize, @intCast(wire.MAX_CREDENTIAL_BYTES_V1))];
    try std.testing.expectEqual(wire.STATUS_OK, fixture.update(sdk.bytesView(longest)));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(3, "third", &result));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.update(sdk.bytesView(CREDENTIAL_C)));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(4, "fourth", &result));

    try expectBearer(server, 0, CREDENTIAL_A);
    try expectBearer(server, 1, CREDENTIAL_B);
    try expectBearer(server, 2, longest);
    try expectBearer(server, 3, CREDENTIAL_C);

    // No credential reaches describe or the checkpoint.
    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.sessionControl().describe()(fixture.session, &description, &fixture.diagnostic));
    const described = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.sessionControl().exportCheckpoint()(fixture.session, &export_config, &export_result, &fixture.diagnostic));
    for ([_][]const u8{ CREDENTIAL_A, CREDENTIAL_B, CREDENTIAL_C, longest[0..64] }) |credential| {
        try std.testing.expect(std.mem.indexOf(u8, described, credential) == null);
        try std.testing.expect(std.mem.indexOf(u8, checkpoint.bytes.items, credential) == null);
    }
    fixture.api.bufferRelease()(&description);

    // Restore is unchanged: the restored Session uses the credential the
    // restore configuration supplies, not the one last published.
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().destroy()(fixture.session, &fixture.diagnostic));
    fixture.session = null;
    fixture.host.api_key = sdk.bytesView("credential-restore-336");
    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &fixture.host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.sessionControl().restore()(fixture.runtime, &restore_config, &fixture.callbacks, &fixture.session, &restore_report, &fixture.diagnostic));
    fixture.api.bufferRelease()(&restore_report);
    probe.session = fixture.session;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(5, "after restore", &result));
    try expectBearer(server, 4, "credential-restore-336");
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches.load(.acquire));
}

test "L2 Revision 25 a Host tool callback rotates the credential mid-Run and the next turn carries it (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_ROTATE_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    // A refused candidate inside the callback changes nothing and the Run goes on.
    probe.refuse_first = "credential b\n336";
    probe.rotate_to = CREDENTIAL_B;
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, false);
    defer fixture.deinit();
    var result: wire.RunResultV1 = undefined;

    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "rotate", &result));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 2), result.turns);
    try std.testing.expectEqual(@as(u32, 1), probe.host_calls);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(2, "again", &result));
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches.load(.acquire));
    try expectBearer(server, 0, CREDENTIAL_A);
    try expectBearer(server, 1, CREDENTIAL_B);
    try expectBearer(server, 2, CREDENTIAL_B);
}

const CredentialRun = struct {
    fixture: *CredentialFixture,
    run_id: u64,
    prompt: []const u8,
    status: u32 = 0,
    result: wire.RunResultV1 = undefined,

    fn go(self: *CredentialRun) void {
        self.status = self.fixture.run(self.run_id, self.prompt, &self.result);
    }
};

test "L2 Revision 25 an update leaves an in-flight request and stream undisturbed and reaches the next request (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, false);
    defer fixture.deinit();

    // Run 1: the response head has arrived and the stream is being read.
    server.gateNextResponse();
    var first = CredentialRun{ .fixture = &fixture, .run_id = 1, .prompt = "stream" };
    const first_thread = try std.Thread.spawn(.{}, CredentialRun.go, .{&first});
    try server.waitUntilResponseGated();
    probe.update(CREDENTIAL_B, wire.STATUS_OK);
    server.releaseGatedResponse();
    first_thread.join();
    try std.testing.expectEqual(wire.STATUS_OK, first.status);
    try std.testing.expectEqual(wire.STOP_END_TURN, first.result.stop_reason_code);

    // Run 2: the request is sent and the head has not arrived yet.
    server.gateResponseAt(1);
    var second = CredentialRun{ .fixture = &fixture, .run_id = 2, .prompt = "head" };
    const second_thread = try std.Thread.spawn(.{}, CredentialRun.go, .{&second});
    try server.waitUntilResponseGated();
    probe.update(CREDENTIAL_C, wire.STATUS_OK);
    server.releaseGatedResponse();
    second_thread.join();
    try std.testing.expectEqual(wire.STATUS_OK, second.status);
    try std.testing.expectEqual(wire.STOP_END_TURN, second.result.stop_reason_code);

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(3, "next", &result));
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try expectBearer(server, 0, CREDENTIAL_A);
    try expectBearer(server, 1, CREDENTIAL_B);
    try expectBearer(server, 2, CREDENTIAL_C);
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches.load(.acquire));
}

test "L2 Revision 25 a retry of the Run's request after an update from the retry_notice callback carries the new credential (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ SERVICE_UNAVAILABLE_BODY, FINAL_SSE, FINAL_SSE };
    const statuses = [_][]const u8{ STATUS_503, STATUS_200, STATUS_200 };
    var server = try harness.MockServer.startHttpCassette(&bodies, &statuses);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    probe.on_retry = CREDENTIAL_B;
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, false);
    defer fixture.deinit();
    var result: wire.RunResultV1 = undefined;

    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "retry", &result));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), probe.retries);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(2, "after", &result));
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try expectBearer(server, 0, CREDENTIAL_A);
    try expectBearer(server, 1, CREDENTIAL_B);
    try expectBearer(server, 2, CREDENTIAL_B);
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches.load(.acquire));
}

test "L2 Revision 25 a WebSearch client built before the update retries with the new credential (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    // 0: the Run's tool turn; 1: WebSearch's own request, refused 503 after
    // it is held; 2: WebSearch's retry; 3: the Run's next turn.
    const bodies = [_][]const u8{ WEB_SEARCH_TOOL_SSE, SERVICE_UNAVAILABLE_BODY, WEB_SEARCH_SUMMARY_SSE, FINAL_SSE };
    const statuses = [_][]const u8{ STATUS_200, STATUS_503, STATUS_200, STATUS_200 };
    var server = try harness.MockServer.startHttpCassette(&bodies, &statuses);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, true);
    defer fixture.deinit();

    server.gateResponseAt(1);
    var run = CredentialRun{ .fixture = &fixture, .run_id = 1, .prompt = "search" };
    const thread = try std.Thread.spawn(.{}, CredentialRun.go, .{&run});
    try server.waitUntilResponseGated();
    // WebSearch's per-call client exists: its first request is out.
    probe.update(CREDENTIAL_B, wire.STATUS_OK);
    server.releaseGatedResponse();
    thread.join();
    try std.testing.expectEqual(wire.STATUS_OK, run.status);
    try std.testing.expectEqual(wire.STOP_END_TURN, run.result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 4), server.requestCount());
    for ([_]usize{ 1, 2 }) |index| {
        const request = server.requestAt(index) orelse return error.MissingProviderRequest;
        try std.testing.expect(std.mem.indexOf(u8, request.body(), "web_search_20250305") != null);
    }
    try expectBearer(server, 0, CREDENTIAL_A);
    try expectBearer(server, 1, CREDENTIAL_A);
    try expectBearer(server, 2, CREDENTIAL_B);
    try expectBearer(server, 3, CREDENTIAL_B);
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches.load(.acquire));
}

test "L2 Revision 25 compaction summary and forked Skill requests carry the updated credential (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "forked",
        "---\nname: Forked\ndescription: Runs in a fresh child Conversation\ncontext: fork\n---\nFORKED_SKILL_SENTINEL",
    );
    const bodies = [_][]const u8{FINAL_SSE} ** 10;
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, false);
    defer fixture.deinit();
    var result: wire.RunResultV1 = undefined;

    const old_context = [_]u8{'A'} ** 8192;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, &old_context, &result));
    for (2..7) |run_id| try std.testing.expectEqual(wire.STATUS_OK, fixture.run(run_id, "recent context", &result));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.update(sdk.bytesView(CREDENTIAL_B)));
    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.sessionControl().compact()(fixture.session, 1, &compact_result, &fixture.diagnostic));
    try std.testing.expectEqual(wire.COMPACT_COMPACTED, compact_result.outcome_code);
    for (0..6) |index| try expectBearer(server, index, CREDENTIAL_A);
    const summary = server.requestAt(6) orelse return error.MissingProviderRequest;
    try std.testing.expect(std.mem.indexOf(u8, summary.body(), &([_]u8{'A'} ** 128)) != null);
    try expectBearer(server, 6, CREDENTIAL_B);

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("credential-fork-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer fixture.api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.skill().resolveCatalog()(fixture.runtime, &query, &catalog, &descriptor, &fixture.diagnostic));
    defer if (catalog) |handle| {
        _ = fixture.api.skill().releaseCatalog()(handle, &fixture.diagnostic);
    };
    const descriptor_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    var policy = try DecodedSkillPolicy.init(a, descriptor_bytes);
    defer policy.deinit();
    const ids = try extractCatalogIdentities(a, descriptor_bytes, "forked");
    defer a.free(ids.revision);
    defer a.free(ids.skill_id);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.skill().bindPolicy()(fixture.session, catalog, &policy.policy, &fixture.diagnostic));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.update(sdk.bytesView(CREDENTIAL_C)));
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 2;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().runSkill(
        fixture.session,
        7,
        sdk.bytesView(ids.skill_id),
        sdk.bytesView(ids.revision),
        sdk.bytesView(""),
        &options,
        &result,
        &fixture.diagnostic,
    ));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    const forked = server.requestAt(7) orelse return error.MissingProviderRequest;
    try std.testing.expect(std.mem.indexOf(u8, forked.body(), "FORKED_SKILL_SENTINEL") != null);
    try expectBearer(server, 7, CREDENTIAL_C);
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches.load(.acquire));
}

test "L2 Revision 25 a poisoned Session refuses update_credential (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    probe.fatal_events = true;
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, false);
    defer fixture.deinit();
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_CALLBACK_FAILED, fixture.run(1, "poison", &result));
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, fixture.update(sdk.bytesView(CREDENTIAL_B)));
    // Checked before the candidate: an invalid one is refused for the state too.
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, fixture.update(sdk.bytesView("")));
}

const CredentialUpdater = struct {
    probe: *CredentialProbe,
    id: u8,
    rounds: usize,
    last: [32]u8 = undefined,
    last_len: usize = 0,

    fn go(self: *CredentialUpdater) void {
        for (0..self.rounds) |round| {
            const candidate = std.fmt.bufPrint(&self.last, "credential-t{d}-r{d}", .{ self.id, round }) catch unreachable;
            self.last_len = candidate.len;
            self.probe.update(candidate, wire.STATUS_OK);
        }
    }

    fn lastValue(self: *const CredentialUpdater) []const u8 {
        return self.last[0..self.last_len];
    }
};

const CredentialSubmitter = struct {
    probe: *CredentialProbe,
    run_id: u64,
    accepted: u32 = 0,

    fn go(self: *CredentialSubmitter) void {
        for (1..9) |input_id| {
            var receipt = std.mem.zeroes(wire.InputReceiptV1);
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const status = self.probe.api.session().submitInput(self.probe.session, self.run_id, input_id, sdk.bytesView("more context"), &receipt, &diagnostic);
            self.probe.api.bufferRelease()(&diagnostic);
            if (status == wire.STATUS_OK) self.accepted += 1 else self.probe.mismatch("submit status {d}", .{status});
        }
    }
};

const CredentialAborter = struct {
    probe: *CredentialProbe,
    run_id: u64,
    status: u32 = 0,

    fn go(self: *CredentialAborter) void {
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        self.status = self.probe.api.session().abort()(self.probe.session, self.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
        self.probe.api.bufferRelease()(&diagnostic);
    }
};

fn expectBearerAmong(server: *harness.MockServer, index: usize, updaters: []const CredentialUpdater) !void {
    const value = try requestAuthorization(server, index);
    if (std.mem.startsWith(u8, value, "Bearer ")) {
        for (updaters) |updater| {
            if (std.mem.eql(u8, value["Bearer ".len..], updater.lastValue())) return;
        }
    }
    std.debug.print("request {d} authorization [{s}] is no updater's last credential\n", .{ index, value });
    return error.UnexpectedAuthorization;
}

test "L2 Revision 25 concurrent updates, submit_input and abort during Runs neither deadlock nor lose the last update (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_ROTATE_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    probe.block_tool = true;
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, false);
    defer fixture.deinit();

    // Run 1, held inside its Host tool callback: four threads update while a
    // fifth submits input to the same Run.
    var first = CredentialRun{ .fixture = &fixture, .run_id = 1, .prompt = "hold" };
    const first_thread = try std.Thread.spawn(.{}, CredentialRun.go, .{&first});
    while (!probe.tool_entered.load(.acquire)) std.Thread.yield() catch {};
    var updaters: [4]CredentialUpdater = undefined;
    for (&updaters, 0..) |*updater, i| updater.* = .{ .probe = &probe, .id = @intCast(i), .rounds = 32 };
    var submitter = CredentialSubmitter{ .probe = &probe, .run_id = 1 };
    var threads: [5]std.Thread = undefined;
    for (updaters[0..], threads[0..4]) |*updater, *thread| thread.* = try std.Thread.spawn(.{}, CredentialUpdater.go, .{updater});
    threads[4] = try std.Thread.spawn(.{}, CredentialSubmitter.go, .{&submitter});
    for (threads) |thread| thread.join();
    probe.tool_release.store(true, .release);
    first_thread.join();
    try std.testing.expectEqual(wire.STATUS_OK, first.status);
    try std.testing.expectEqual(wire.STOP_END_TURN, first.result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 8), submitter.accepted);
    try std.testing.expectEqual(@as(u32, 8), first.result.input_adopted_count);
    // Every update returned before the next turn: its request carries the
    // last update some thread made, never an earlier or a torn one.
    try expectBearerAmong(server, 1, &updaters);

    // Run 2, its stream held: four threads update while a fifth aborts it.
    probe.block_tool = false;
    server.gateNextResponse();
    var second = CredentialRun{ .fixture = &fixture, .run_id = 2, .prompt = "abort me" };
    const second_thread = try std.Thread.spawn(.{}, CredentialRun.go, .{&second});
    try server.waitUntilResponseGated();
    for (&updaters, 0..) |*updater, i| updater.* = .{ .probe = &probe, .id = @intCast(4 + i), .rounds = 32 };
    var aborter = CredentialAborter{ .probe = &probe, .run_id = 2 };
    for (updaters[0..], threads[0..4]) |*updater, *thread| thread.* = try std.Thread.spawn(.{}, CredentialUpdater.go, .{updater});
    threads[4] = try std.Thread.spawn(.{}, CredentialAborter.go, .{&aborter});
    for (threads) |thread| thread.join();
    server.releaseGatedResponse();
    second_thread.join();
    try std.testing.expectEqual(wire.STATUS_OK, aborter.status);
    try std.testing.expectEqual(wire.STATUS_OK, second.status);
    try std.testing.expectEqual(wire.STOP_ABORTED, second.result.stop_reason_code);

    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(3, "after the storm", &result));
    try expectBearerAmong(server, 3, &updaters);
    try expectBearer(server, 0, CREDENTIAL_A);
    try std.testing.expectEqual(@as(u32, 0), probe.mismatches.load(.acquire));
}

test "L2 Revision 25 create and restore refuse a credential a header cannot carry, and diagnostics never name it (#336)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var probe = try credentialProbe();
    var fixture: CredentialFixture = undefined;
    try fixture.init(root, url, &probe, false);
    defer fixture.deinit();
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(1, "first", &result));

    const too_long = try a.alloc(u8, @as(usize, @intCast(wire.MAX_CREDENTIAL_BYTES_V1)) + 1);
    defer a.free(too_long);
    @memset(too_long, 'k');
    const Refusal = struct { key: []const u8, status: u32 };
    const refusals = [_]Refusal{
        .{ .key = "credential-a-336\r\nx-injected: 1", .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .key = "credential a 336", .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .key = "credential-\xc3\xa9-336", .status = wire.STATUS_INVALID_ARGUMENT },
        .{ .key = too_long, .status = wire.STATUS_RESOURCE_LIMIT },
    };
    const valid_key = fixture.host.api_key;
    var create_config = sessionCreateConfig(&fixture.host, "credential-model");
    for (refusals) |refusal| {
        fixture.host.api_key = sdk.bytesView(refusal.key);
        var session: ?*wire.SessionHandle = null;
        try std.testing.expectEqual(refusal.status, fixture.api.session().create()(fixture.runtime, &create_config, &fixture.callbacks, &session, &fixture.diagnostic));
        try std.testing.expect(session == null);
        const message = try sdk.borrowedBytes(.{ .ptr = fixture.diagnostic.ptr, .len = fixture.diagnostic.len });
        try std.testing.expect(message.len != 0);
        try std.testing.expect(std.mem.indexOf(u8, message, refusal.key[0..12]) == null);
        fixture.api.bufferRelease()(&fixture.diagnostic);
    }
    fixture.host.api_key = valid_key;

    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.sessionControl().exportCheckpoint()(fixture.session, &export_config, &export_result, &fixture.diagnostic));
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.session().destroy()(fixture.session, &fixture.diagnostic));
    fixture.session = null;

    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &fixture.host;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    for (refusals) |refusal| {
        fixture.host.api_key = sdk.bytesView(refusal.key);
        var source = checkpoint.source();
        restore_config.source = &source;
        var session: ?*wire.SessionHandle = null;
        try std.testing.expectEqual(refusal.status, fixture.api.sessionControl().restore()(fixture.runtime, &restore_config, &fixture.callbacks, &session, &restore_report, &fixture.diagnostic));
        try std.testing.expect(session == null);
        fixture.api.bufferRelease()(&restore_report);
        const message = try sdk.borrowedBytes(.{ .ptr = fixture.diagnostic.ptr, .len = fixture.diagnostic.len });
        try std.testing.expect(std.mem.indexOf(u8, message, refusal.key[0..12]) == null);
        fixture.api.bufferRelease()(&fixture.diagnostic);
    }

    // A valid key restores as before and is the one the next request carries.
    fixture.host.api_key = sdk.bytesView(CREDENTIAL_B);
    var source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.api.sessionControl().restore()(fixture.runtime, &restore_config, &fixture.callbacks, &fixture.session, &restore_report, &fixture.diagnostic));
    fixture.api.bufferRelease()(&restore_report);
    probe.session = fixture.session;
    try std.testing.expectEqual(wire.STATUS_OK, fixture.run(2, "after restore", &result));
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    try expectBearer(server, 0, CREDENTIAL_A);
    try expectBearer(server, 1, CREDENTIAL_B);
}

// #389: one MCP server binding S moves from endpoint A to endpoint B while
// its server_binding_identity, tool name and schema stay the same. Both ends
// are real Streamable HTTP endpoints (`PublicHttpMcpConnector` against a
// local cassette server). A Modern AUTO connection sends a disposable
// `server/discover` probe, then `server/discover` and `tools/list` on the
// actual connection, whose JSON-RPC ids then count up per `tools/call`.
const SWAP_MCP_DISCOVER =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"ttlMs\":60000,\"cacheScope\":\"private\"}}";
const SWAP_MCP_LIST =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"tools\":[{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}}],\"ttlMs\":60000,\"cacheScope\":\"private\"}}";
const SWAP_MCP_OK = "HTTP/1.1 200 OK";

fn swapMcpCall(comptime id: u8, comptime endpoint: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"from-{s}\"}}]}}}}",
        .{ id, endpoint },
    );
}

const SWAP_BINDING = [_]u8{0x89} ** 32;
const SWAP_FINGERPRINT_A = [_]u8{0xa0} ** 32;
const SWAP_FINGERPRINT_B = [_]u8{0xb0} ** 32;

fn swapMcpServer(
    connector: *PublicHttpMcpConnector,
    fingerprint: [32]u8,
    timeout_ms: u32,
) wire.McpServerV1 {
    var server = std.mem.zeroes(wire.McpServerV1);
    server.struct_size = @sizeOf(wire.McpServerV1);
    server.transport_code = wire.MCP_TRANSPORT_STREAMABLE_HTTP;
    server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
    server.server_binding_identity = SWAP_BINDING;
    server.configuration_fingerprint = fingerprint;
    server.namespace = sdk.bytesView("swap");
    server.client_name = sdk.bytesView("agentcore-endpoint-swap-test");
    server.client_version = sdk.bytesView("1");
    server.timeout_ms = timeout_ms;
    server.connector = connector.connector();
    return server;
}

fn swapToolSse(allocator: std.mem.Allocator, model_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_swap\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_swap\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"text\\\":\\\"hello\\\"}}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{model_name},
    );
}

/// Answers each MCP Permission request with the next scripted choice and
/// records what reached the model and the final decision of the last call.
const McpEndpointSwapProbe = struct {
    answers: []const sdk.protocol.PermissionChoice,
    asks: u32 = 0,
    ui_releases: u32 = 0,
    bindings: [8][64]u8 = undefined,
    results_from_a: u32 = 0,
    results_from_b: u32 = 0,
    denied_results: u32 = 0,
    last_source: ?sdk.protocol.PermissionDecisionSource = null,
    last_decision: ?sdk.protocol.PermissionDecision = null,
    last_used_session_rule: bool = false,

    fn event(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const known = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (known) {
            .permission_provenance => |provenance| {
                if (provenance.tool.namespace != .mcp or
                    !std.mem.eql(u8, provenance.tool.name, "echo"))
                    return wire.EVENT_FATAL;
                self.last_source = provenance.source;
                self.last_decision = provenance.decision;
                self.last_used_session_rule = provenance.used_session_rule;
            },
            .tool_result => |result| {
                if (std.mem.indexOf(u8, result.content, "from-A") != null) {
                    self.results_from_a += 1;
                } else if (std.mem.indexOf(u8, result.content, "from-B") != null) {
                    self.results_from_b += 1;
                } else if (result.is_error) {
                    self.denied_results += 1;
                }
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        const encoded = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const request = switch (parsed.value) {
            .permission => |value| value,
            else => return wire.UI_FATAL,
        };
        if (request.tool.namespace != .mcp or
            !std.mem.eql(u8, request.tool.name, "echo") or
            request.tool.binding.len != 64 or
            self.asks == self.answers.len or
            self.asks == self.bindings.len)
            return wire.UI_FATAL;
        @memcpy(&self.bindings[self.asks], request.tool.binding);
        const choice = self.answers[self.asks];
        const session_choice = choice == .allow_session or choice == .deny_session;
        const candidate = request.candidate orelse return wire.UI_FATAL;
        const response_json = sdk.encodeUiResponse(
            std.heap.c_allocator,
            parsed.value,
            .{ .permission = .{
                .permission = choice,
                .request_id = request.request_id,
                .policy_generation = request.policy_generation,
                .rule_id = if (session_choice) candidate.rule_id else null,
            } },
        ) catch return wire.UI_FATAL;
        const out = out_response orelse {
            std.heap.c_allocator.free(response_json);
            return wire.UI_FATAL;
        };
        out.* = .{ .ptr = response_json.ptr, .len = response_json.len };
        self.asks += 1;
        return wire.UI_ANSWERED;
    }

    fn releaseUi(raw: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.ui_releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }

    fn callbacks(self: *@This()) wire.SessionCallbacksV1 {
        var result = std.mem.zeroes(wire.SessionCallbacksV1);
        result.struct_size = @sizeOf(wire.SessionCallbacksV1);
        result.ctx = self;
        result.on_event = event;
        result.on_ui_request = ui;
        result.release_response = releaseUi;
        return result;
    }

    fn expectLastCall(
        self: *const @This(),
        decision: sdk.protocol.PermissionDecision,
        source: sdk.protocol.PermissionDecisionSource,
    ) !void {
        try std.testing.expectEqual(decision, self.last_decision.?);
        try std.testing.expectEqual(source, self.last_source.?);
        try std.testing.expectEqual(source == .session_allow, self.last_used_session_rule);
    }
};

fn applySwapConfiguration(
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    revision: u64,
    server: *const wire.McpServerV1,
    expected_generation: u64,
) !void {
    var configuration = std.mem.zeroes(wire.McpConfigurationV1);
    configuration.struct_size = @sizeOf(wire.McpConfigurationV1);
    configuration.desired_revision = revision;
    configuration.servers = @ptrCast(server);
    configuration.server_count = 1;
    var report = std.mem.zeroes(wire.McpApplyReportV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.mcp().applyConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(expected_generation, report.catalog_generation);
}

fn swapHostConfig(
    base_url: []const u8,
    root: []const u8,
    selection: *const wire.McpSelectionV1,
) wire.SessionHostConfigV1 {
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.mcp_selection = selection;
    return host;
}

fn swapSelector() wire.McpSelectorV1 {
    var selector = std.mem.zeroes(wire.McpSelectorV1);
    selector.struct_size = @sizeOf(wire.McpSelectorV1);
    selector.server_binding_identity = SWAP_BINDING;
    selector.tool_name = sdk.bytesView("echo");
    return selector;
}

fn swapRun(api: sdk.Api, session: ?*wire.SessionHandle, run_id: u64) !void {
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 2;
    var result = std.mem.zeroes(wire.RunResultV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().runText(session, run_id, sdk.bytesView("echo hello"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
}

/// Counts the `tools/call` requests one cassette endpoint received.
fn toolCallsReceived(server: *harness.MockServer) usize {
    var calls: usize = 0;
    var index: usize = 0;
    while (server.requestAt(index)) |captured| : (index += 1) {
        if (std.mem.indexOf(u8, captured.raw, "\"tools/call\"") != null) calls += 1;
    }
    return calls;
}

test "L2 MCP endpoint swap asks again instead of reusing an allow_session grant (#389)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var provider_bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE } ** 5;
    var provider = try harness.MockServer.startCassette(&provider_bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const a_bodies = [_][]const u8{
        SWAP_MCP_DISCOVER,
        SWAP_MCP_DISCOVER,
        SWAP_MCP_LIST,
        swapMcpCall(3, "A"),
        swapMcpCall(4, "A"),
    };
    const a_statuses = [_][]const u8{SWAP_MCP_OK} ** a_bodies.len;
    var endpoint_a = try harness.MockServer.startHttpCassette(&a_bodies, &a_statuses);
    defer endpoint_a.stop();
    const a_url = try endpoint_a.urlOwned(a);
    defer a.free(a_url);
    var connector_a = PublicHttpMcpConnector{ .url = a_url };
    // B serves one connection, then a second after the timeout-only change.
    const b_bodies = [_][]const u8{
        SWAP_MCP_DISCOVER, SWAP_MCP_DISCOVER, SWAP_MCP_LIST, swapMcpCall(3, "B"),
        SWAP_MCP_DISCOVER, SWAP_MCP_DISCOVER, SWAP_MCP_LIST, swapMcpCall(3, "B"),
    };
    const b_statuses = [_][]const u8{SWAP_MCP_OK} ** b_bodies.len;
    var endpoint_b = try harness.MockServer.startHttpCassette(&b_bodies, &b_statuses);
    defer endpoint_b.stop();
    const b_url = try endpoint_b.urlOwned(a);
    defer a.free(b_url);
    var connector_b = PublicHttpMcpConnector{ .url = b_url };

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    var session: ?*wire.SessionHandle = null;
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    const server_a = swapMcpServer(&connector_a, SWAP_FINGERPRINT_A, 5000);
    try applySwapConfiguration(api, runtime, 1, &server_a, 1);

    const selectors = [_]wire.McpSelectorV1{swapSelector()};
    var selection = std.mem.zeroes(wire.McpSelectionV1);
    selection.struct_size = @sizeOf(wire.McpSelectionV1);
    selection.selectors = &selectors;
    selection.selector_count = selectors.len;
    var host = swapHostConfig(base_url, root, &selection);
    var create_config = sessionCreateConfig(&host, "test-model");
    var probe = McpEndpointSwapProbe{
        .answers = &.{ .allow_session, .deny_once, .allow_session },
    };
    var callbacks = probe.callbacks();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );
    const tool_sse = blk: {
        const described = try decodeDescription(api, session);
        defer described.deinit();
        try std.testing.expectEqual(@as(usize, 1), described.value.mcp.tools.len);
        break :blk try swapToolSse(a, described.value.mcp.tools[0].model_name);
    };
    defer a.free(tool_sse);
    for (0..5) |run| provider_bodies[run * 2] = tool_sse;

    // A: the first call asks, and its allow_session answer covers the next.
    try swapRun(api, session, 1);
    try std.testing.expectEqual(@as(u32, 1), probe.asks);
    try probe.expectLastCall(.allow, .callback);
    try swapRun(api, session, 2);
    try std.testing.expectEqual(@as(u32, 1), probe.asks);
    try probe.expectLastCall(.allow, .session_allow);
    try std.testing.expectEqual(@as(u32, 2), probe.results_from_a);
    try std.testing.expectEqual(@as(usize, 2), toolCallsReceived(endpoint_a));

    // S now points at B under a new configuration fingerprint. The grant A
    // earned does not reach B: the same call asks again, and the deny_once
    // answer keeps the arguments away from B.
    const server_b = swapMcpServer(&connector_b, SWAP_FINGERPRINT_B, 5000);
    try applySwapConfiguration(api, runtime, 2, &server_b, 2);
    try swapRun(api, session, 3);
    try std.testing.expectEqual(@as(u32, 2), probe.asks);
    try probe.expectLastCall(.deny, .callback);
    try std.testing.expectEqual(@as(u32, 1), probe.denied_results);
    try std.testing.expectEqual(@as(usize, 0), toolCallsReceived(endpoint_b));
    // The request names B's identity, not the one A's grant is bound to.
    try std.testing.expect(!std.mem.eql(u8, &probe.bindings[0], &probe.bindings[1]));
    // The Run that first saw B dropped A's grant, which can never decide
    // again, and the Session says so.
    {
        const described = try decodeDescription(api, session);
        defer described.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.degraded, described.value.restore.health);
        try std.testing.expectEqual(@as(u32, 1), described.value.restore.invalidated_mcp_bindings);
        try std.testing.expectEqualStrings(
            &probe.bindings[1],
            described.value.mcp.tools[0].permission_binding,
        );
    }

    // A fresh allow_session answer authorizes B.
    try swapRun(api, session, 4);
    try std.testing.expectEqual(@as(u32, 3), probe.asks);
    try probe.expectLastCall(.allow, .callback);
    try std.testing.expectEqualSlices(u8, &probe.bindings[1], &probe.bindings[2]);
    try std.testing.expectEqual(@as(u32, 1), probe.results_from_b);
    try std.testing.expectEqual(@as(usize, 1), toolCallsReceived(endpoint_b));

    // A configuration change that keeps the fingerprint (here only the
    // timeout) is the same connection identity: the Runtime reconnects to B
    // and the grant still applies.
    const server_b_slow = swapMcpServer(&connector_b, SWAP_FINGERPRINT_B, 7000);
    try applySwapConfiguration(api, runtime, 3, &server_b_slow, 3);
    try swapRun(api, session, 5);
    try std.testing.expectEqual(@as(u32, 3), probe.asks);
    try probe.expectLastCall(.allow, .session_allow);
    try std.testing.expectEqual(@as(u32, 2), probe.results_from_b);
    try std.testing.expectEqual(@as(usize, 2), toolCallsReceived(endpoint_b));
    try std.testing.expectEqual(@as(usize, 2), toolCallsReceived(endpoint_a));
    try std.testing.expectEqual(probe.asks, probe.ui_releases);

    // Nothing stale is left to export: restored at B, the checkpoint brings
    // back B's grant and loses nothing.
    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;
    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&restore_report);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().restore()(runtime, &restore_config, &callbacks, &session, &restore_report, &diagnostic),
    );
    const decoded = try sdk.decodeRestoreReport(a, try sdk.borrowedBytes(.{
        .ptr = restore_report.ptr,
        .len = restore_report.len,
    }));
    defer decoded.deinit();
    try std.testing.expectEqual(sdk.protocol.RestoreHealth.complete, decoded.value.health);
    try std.testing.expectEqual(@as(u32, 1), decoded.value.permission.restored_rules);
    try std.testing.expectEqual(@as(u32, 0), decoded.value.permission.invalidated_rules);
    try std.testing.expectEqual(@as(usize, 0), decoded.value.issues.len);
}

test "L2 MCP checkpoint restore binds an allow_session grant to its endpoint (#389)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var provider_bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE } ** 3;
    var provider = try harness.MockServer.startCassette(&provider_bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const a_bodies = [_][]const u8{
        SWAP_MCP_DISCOVER,
        SWAP_MCP_DISCOVER,
        SWAP_MCP_LIST,
        swapMcpCall(3, "A"),
        swapMcpCall(4, "A"),
    };
    const a_statuses = [_][]const u8{SWAP_MCP_OK} ** a_bodies.len;
    var endpoint_a = try harness.MockServer.startHttpCassette(&a_bodies, &a_statuses);
    defer endpoint_a.stop();
    const a_url = try endpoint_a.urlOwned(a);
    defer a.free(a_url);
    var connector_a = PublicHttpMcpConnector{ .url = a_url };
    const b_bodies = [_][]const u8{
        SWAP_MCP_DISCOVER, SWAP_MCP_DISCOVER, SWAP_MCP_LIST, swapMcpCall(3, "B"),
    };
    const b_statuses = [_][]const u8{SWAP_MCP_OK} ** b_bodies.len;
    var endpoint_b = try harness.MockServer.startHttpCassette(&b_bodies, &b_statuses);
    defer endpoint_b.stop();
    const b_url = try endpoint_b.urlOwned(a);
    defer a.free(b_url);
    var connector_b = PublicHttpMcpConnector{ .url = b_url };

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    var session: ?*wire.SessionHandle = null;
    defer {
        if (session) |handle| _ = api.session().destroy()(handle, &diagnostic);
        if (runtime) |handle| _ = api.runtime().destroy()(handle, &diagnostic);
    }
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtime().create()(&runtime_config, null, &runtime, &diagnostic),
    );
    const server_a = swapMcpServer(&connector_a, SWAP_FINGERPRINT_A, 5000);
    try applySwapConfiguration(api, runtime, 1, &server_a, 1);

    const selectors = [_]wire.McpSelectorV1{swapSelector()};
    var selection = std.mem.zeroes(wire.McpSelectionV1);
    selection.struct_size = @sizeOf(wire.McpSelectionV1);
    selection.selectors = &selectors;
    selection.selector_count = selectors.len;
    var host = swapHostConfig(base_url, root, &selection);
    var create_config = sessionCreateConfig(&host, "test-model");
    var probe = McpEndpointSwapProbe{
        .answers = &.{ .allow_session, .allow_once },
    };
    var callbacks = probe.callbacks();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.session().create()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );
    const tool_sse = blk: {
        const described = try decodeDescription(api, session);
        defer described.deinit();
        break :blk try swapToolSse(a, described.value.mcp.tools[0].model_name);
    };
    defer a.free(tool_sse);
    for (0..3) |run| provider_bodies[run * 2] = tool_sse;

    try swapRun(api, session, 1);
    try std.testing.expectEqual(@as(u32, 1), probe.asks);
    try probe.expectLastCall(.allow, .callback);

    // The checkpoint carries the allow_session grant A earned.
    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().exportCheckpoint()(session, &export_config, &export_result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &host;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&restore_report);

    // Restored while S still points at A, the grant comes back and covers
    // the same call without a prompt.
    var source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().restore()(runtime, &restore_config, &callbacks, &session, &restore_report, &diagnostic),
    );
    {
        const decoded = try sdk.decodeRestoreReport(a, try sdk.borrowedBytes(.{
            .ptr = restore_report.ptr,
            .len = restore_report.len,
        }));
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.complete, decoded.value.health);
        try std.testing.expectEqual(@as(u32, 1), decoded.value.permission.restored_rules);
        try std.testing.expectEqual(@as(u32, 0), decoded.value.permission.invalidated_rules);
        try std.testing.expectEqual(@as(u32, 1), decoded.value.mcp.restored_bindings);
    }
    api.bufferRelease()(&restore_report);
    try swapRun(api, session, 2);
    try std.testing.expectEqual(@as(u32, 1), probe.asks);
    try probe.expectLastCall(.allow, .session_allow);
    try std.testing.expectEqual(@as(u32, 2), probe.results_from_a);
    try std.testing.expectEqual(wire.STATUS_OK, api.session().destroy()(session, &diagnostic));
    session = null;

    // Restored after S moved to B, the Tool is still selected but the grant
    // is invalidated and reported, so the same call asks again.
    const server_b = swapMcpServer(&connector_b, SWAP_FINGERPRINT_B, 5000);
    try applySwapConfiguration(api, runtime, 2, &server_b, 2);
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionControl().restore()(runtime, &restore_config, &callbacks, &session, &restore_report, &diagnostic),
    );
    {
        const decoded = try sdk.decodeRestoreReport(a, try sdk.borrowedBytes(.{
            .ptr = restore_report.ptr,
            .len = restore_report.len,
        }));
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.degraded, decoded.value.health);
        try std.testing.expectEqual(@as(u32, 0), decoded.value.permission.restored_rules);
        try std.testing.expectEqual(@as(u32, 1), decoded.value.permission.invalidated_rules);
        try std.testing.expectEqual(@as(u32, 1), decoded.value.mcp.restored_bindings);
        try std.testing.expectEqual(@as(u32, 0), decoded.value.mcp.invalidated_bindings);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.issues.len);
        try std.testing.expectEqual(
            sdk.protocol.AuthoritySubsystem.permission,
            decoded.value.issues[0].subsystem,
        );
    }
    try swapRun(api, session, 3);
    try std.testing.expectEqual(@as(u32, 2), probe.asks);
    try probe.expectLastCall(.allow, .callback);
    try std.testing.expect(!std.mem.eql(u8, &probe.bindings[0], &probe.bindings[1]));
    try std.testing.expectEqual(@as(u32, 1), probe.results_from_b);
    try std.testing.expectEqual(@as(usize, 1), toolCallsReceived(endpoint_b));
    try std.testing.expectEqual(@as(usize, 2), toolCallsReceived(endpoint_a));
    try std.testing.expectEqual(probe.asks, probe.ui_releases);
}
