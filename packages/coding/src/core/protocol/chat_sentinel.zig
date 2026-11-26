//! AskUserQuestion 的 "Chat about this" 哨兵值(中立协议)。
//! ask_user 工具检测到该值时返回 user_chose_free_response,不把 label 当答案塞模型。
//! 从 tui/dialog/ask_question.zig 提出,避免工具层依赖具体 TUI 对话框。
pub const CHAT_SENTINEL = "\x00__cc_chat_about_this__";
