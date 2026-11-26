//! 权限决策枚举(中立协议)。从 tui/dialog/permission.zig 提出,供 protocol/ui_request.zig
//! 与权限系统共用,避免协议依赖具体 TUI 对话框。
pub const PermissionChoice = enum {
    /// 本次允许
    allow_once,
    /// 永久允许该工具(写 settings.local.json)
    allow_always,
    /// 本次拒绝
    deny_once,
    /// 该 session 不再询问该工具(临时 deny 规则)
    deny_tool_session,
};
