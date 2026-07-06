//! 统一的"后端调用 UI"请求/响应抽象。
//!
//! 背景:cc-zig 曾有 3 套各自为政的同步阻塞 UI 回调——AskUserQuestion(ask_question_fn)、
//! ExitPlanMode 审批(exit_plan_fn)、权限确认(permission/prompt.zig 的 g_dialog_runner)。
//! 三者本质相同:**agent_loop/工具(主线程)同步阻塞地问 UI 一个问题 → UI 返回一个选择**,
//! 终端接管骨架逐字节相同。本模块把它们统一成一组 UiRequest/UiResponse + 单一回调。
//!
//! 分离架构:UiRequest/UiResponse 是**纯数据 union**(slice/enum,无函数指针),符合
//! CoreEvent 同款约束——agent_loop 经 ctx 回调发请求,backend 是唯一表达层(渲染对话框)。
//! 进程外 backend(未来 WsBackend)可序列化传输。

const std = @import("std");
const context = @import("../../tools/context.zig");

pub const AskQuestion = context.AskQuestion;
pub const PermissionChoice = @import("permission_choice.zig").PermissionChoice;
pub const PlanApproval = context.ToolContext.PlanApproval;

/// UI 请求(backend → 渲染对应对话框,同步阻塞拿用户选择)。
pub const UiRequest = union(enum) {
    /// AskUserQuestion:一组多选问答。
    ask_question: []const AskQuestion,
    /// 权限确认:工具名 + 参数预览。
    permission: struct { tool: []const u8, args: []const u8 },
    /// ExitPlanMode 计划审批:展示计划 markdown,三选项。
    /// kg_step_count>0 时对话框显示"批准后将存为 N 步持久任务图"(PM P0-1:让用户
    /// 看见计划将入图;0 = KG 不可用或无结构,不显示。批准前 parse,与实际落图同源)。
    plan_approval: struct { plan_md: []const u8, kg_step_count: usize = 0 },
    /// L2:可扩展信封(动态 UI 北极星)。core 不理解 kind 的语义,只把它**转发**给 backend;
    /// backend(可能是临时起的 web 服务/GUI/客户端)据 kind 渲染对应界面、收集结构化结果。
    /// 例:kind="video_timeline",payload_json=时间线规格(HTML/参数 schema),响应是用户编辑后的
    /// 剪辑参数 JSON。三个具名变体(ask_question/permission/plan_approval)保留——它们高频且语义
    /// 稳定,具名比 custom 更类型安全;custom 是 escape hatch,不是替代。
    /// 同步终端 backend(TuiBackend)无法渲染任意界面 → 返 error.CustomUiUnsupported(工具兜底)。
    ///
    /// **schema 责任**:kind 的 payload_json 与响应 result JSON 的 schema **由发起 tool 与 renderer
    /// 双方约定**——core 不校验(它不懂任何 kind,这是 opaque passthrough 的代价与本分)。两端
    /// 跨进程时尤其要**版本化**(kind 内嵌版本号 / 共享 schema 声明),否则 JSON 在 tool↔renderer
    /// 间裸奔会 schema drift。当前(L2)仅协议合约就位,首个真实生产负载待 L3 挂起路径接入。
    custom: struct { kind: []const u8, payload_json: []const u8 },
};

/// UI 响应(用户的选择)。tag 与对应 UiRequest 一一对应。
pub const UiResponse = union(enum) {
    /// ask_question 每问选中的 label(s)(多选用 ", " 拼接)。owned by allocator(caller free)。
    answers: []const []const u8,
    /// 权限选择。
    permission: PermissionChoice,
    /// 计划审批选择。
    plan_approval: PlanApproval,
    /// L2:custom 请求的结构化结果 JSON(backend 收集、序列化)。owned by allocator(caller free)。
    /// core/工具不解析其语义,原样回传给发起的工具(工具自己懂 kind 对应的 schema)。
    custom: []const u8,
};

/// 统一回调签名(挂 ToolContext)。state 指向 *TuiBackend(经 trampoline)。
/// out 由调用方栈上提供,回调写入;ask_question 的 answers slice owned by allocator。
///
/// **多 Session 路由**:session 标识该请求归属哪个会话——GUI backend 据它把对话框渲染到
/// 对应 session 的视图(TUI N=1 忽略)。与 emit/poll 同款 envelope-on-signature(M4 D1)。
/// **保持同步**:工具调它本就须阻塞自己 session 的线程等用户答(它要答案才能继续);
/// 并发隔离归 M6 per-session 线程,不在协议层做异步 request_id(避死循环/响应丢失)。
pub const SessionId = @import("../session_id.zig").SessionId;

/// UI 请求结果(可挂起路径预留):
/// - answered:同步前端(TUI/GUI)已写 out,工具读 out 继续。
/// - pending:异步前端(Slack/邮件/工作流)未阻塞——已 stash 请求 out-of-band 投递,
///   工具据此返 error.UiPending,agent_loop 挂起(stop_reason=.suspended),响应到达后
///   经 resumeWithResponse 注入 tool_result 续跑。**out 未写,工具不得读。**
/// - unavailable:无 requester(headless/单测/子 agent)→ 工具按语义兜底(ask→NotATty 等)。
pub const RequestOutcome = enum { answered, pending, unavailable };

pub const UiRequestFn = *const fn (
    state: *anyopaque,
    session: SessionId,
    allocator: std.mem.Allocator,
    req: *const UiRequest,
    out: *UiResponse,
) anyerror!RequestOutcome;

/// UI 请求接口:把裸 ui_request_state+fn 对收成类型安全的接口值(仿 UsageSink)。
/// 被 ToolContext / agent_loop.Options / PermissionContext 共用。
pub const UiRequester = struct {
    ctx: *anyopaque,
    requestFn: UiRequestFn,
    pub fn request(self: UiRequester, session: SessionId, allocator: std.mem.Allocator, req: *const UiRequest, out: *UiResponse) anyerror!RequestOutcome {
        return self.requestFn(self.ctx, session, allocator, req, out);
    }
};

/// 把 UiRequest 序列化成 JSON(给异步前端渲染/投递用)。caller free。
/// 纯数据 union → 可序列化(无指针/闭包)。
pub fn serializeUiRequest(allocator: std.mem.Allocator, req: *const UiRequest) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, req.*, .{});
}

// ============================================================================
// Tests:纯数据守卫(对齐 ui_event.zig CoreEvent 测试)
// ============================================================================

const testing = std.testing;

test "UiRequest/UiResponse 是纯数据(可 @sizeOf,无 comptime-only)" {
    try testing.expect(@sizeOf(UiRequest) > 0);
    try testing.expect(@sizeOf(UiResponse) > 0);
}

test "UiRequest tag 与 UiResponse 对应" {
    const req = UiRequest{ .plan_approval = .{ .plan_md = "do x" } };
    try testing.expect(req == .plan_approval);
    const resp = UiResponse{ .plan_approval = .reject };
    try testing.expect(resp == .plan_approval);
}

test "UiRequest.permission 携带工具名+参数" {
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{\"command\":\"ls\"}" } };
    try testing.expectEqualStrings("Bash", req.permission.tool);
}

test "UiRequester.request 经接口触达回调" {
    const S = struct {
        var hits: u32 = 0;
        fn cb(_: *anyopaque, _: SessionId, _: std.mem.Allocator, _: *const UiRequest, out: *UiResponse) anyerror!RequestOutcome {
            hits += 1;
            out.* = .{ .plan_approval = .reject };
            return .answered;
        }
    };
    S.hits = 0;
    var dummy: u8 = 0;
    const r = UiRequester{ .ctx = @ptrCast(&dummy), .requestFn = &S.cb };
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var resp: UiResponse = undefined;
    const outcome = try r.request(SessionId.single, testing.allocator, &req, &resp);
    try testing.expectEqual(@as(u32, 1), S.hits);
    try testing.expectEqual(RequestOutcome.answered, outcome);
}

test "L2(仅协议层): custom 信封经 UiRequester 双向往返(无生产渲染路径,真实端到端见 L3)" {
    // 诚实范围:本测试用 mock backend 证明协议层往返正确(kind 进、result JSON 出)。
    // 生产渲染路径当前不存在(TuiBackend.custom 返 CustomUiUnsupported);首个真实负载待 L3。
    const S = struct {
        var got_kind: []const u8 = "";
        // 模拟一个能渲染 custom UI 的 backend:据 kind 回一个结构化结果 JSON。
        fn cb(_: *anyopaque, _: SessionId, _: std.mem.Allocator, req: *const UiRequest, out: *UiResponse) anyerror!RequestOutcome {
            switch (req.*) {
                .custom => |c| {
                    got_kind = c.kind;
                    out.* = .{ .custom = "{\"in\":3,\"out\":42}" }; // 用户编辑后的剪辑参数
                    return .answered;
                },
                else => return .unavailable,
            }
        }
    };
    S.got_kind = "";
    var dummy: u8 = 0;
    const r = UiRequester{ .ctx = @ptrCast(&dummy), .requestFn = &S.cb };
    const req = UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{\"clips\":[]}" } };
    var resp: UiResponse = undefined;
    const outcome = try r.request(SessionId.single, testing.allocator, &req, &resp);
    try testing.expectEqual(RequestOutcome.answered, outcome);
    try testing.expectEqualStrings("video_timeline", S.got_kind); // backend 收到 kind
    try testing.expect(resp == .custom);
    try testing.expectEqualStrings("{\"in\":3,\"out\":42}", resp.custom); // 工具拿到结构化结果
}

test "RequestOutcome 三态可表达 + serializeUiRequest 往返" {
    // pending 是控制信号(异步前端用),与 answered/unavailable 区分。
    try testing.expect(RequestOutcome.pending != RequestOutcome.answered);
    // UiRequest 纯数据可序列化(给异步前端投递)。
    const req = UiRequest{ .permission = .{ .tool = "Bash", .args = "{\"command\":\"ls\"}" } };
    const json = try serializeUiRequest(testing.allocator, &req);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "Bash") != null);
}

test "L2: custom 信封可序列化 + 响应 tag 对应" {
    // 动态 UI:任意 kind + payload,core 不解析,序列化转发给异步前端。
    const req = UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{\"clips\":[]}" } };
    try testing.expect(req == .custom);
    const json = try serializeUiRequest(testing.allocator, &req);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "video_timeline") != null);
    try testing.expect(std.mem.indexOf(u8, json, "clips") != null);
    // 响应 custom = 结构化结果 JSON。
    const resp = UiResponse{ .custom = "{\"in\":3,\"out\":42}" };
    try testing.expect(resp == .custom);
}
