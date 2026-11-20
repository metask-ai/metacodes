//! The REPL's command dialogs — `/help`, `/skills`, `/login` — drawn as
//! Claude Code's bottom pane (`tui/dialog/pane.zig`).
//!
//! Each dialog is a small state machine: `draw` projects it onto a `Pane`,
//! `key` and `tick` move it and say whether to redraw or close. None of them
//! touches the terminal; `pane.run` owns that. When a dialog closes it leaves
//! an `outcome` for the command to print under its echo (`⎿  Login
//! interrupted`), the way Claude Code reports a dismissed dialog.

const std = @import("std");
const input = @import("input.zig");
const complete = @import("complete.zig");
const pane_mod = @import("tui/dialog/pane.zig");
const ui = @import("tui/ui.zig");
const term = @import("tui/term.zig");
const ansi = @import("tui/ansi.zig");
const Theme = @import("tui/theme.zig").Theme;
const catalog_mod = @import("../skills/runtime/catalog.zig");
const overrides_mod = @import("../skills/overrides.zig");
const provider_login = @import("../api/provider_login.zig");
const login_worker_mod = @import("../api/login_worker.zig");
const openrouter_login = @import("../api/openrouter_login.zig");
const metask_sign_in = @import("../api/metask_sign_in.zig");
const model_catalog = @import("../api/catalog.zig");
const types = @import("../types.zig");
const provider_profile = @import("../provider/profile.zig");

const Pane = pane_mod.Pane;
const Step = pane_mod.Step;

/// Rows a scrolling list may take, leaving the pane's chrome on screen.
pub fn listRows(term_rows: usize, chrome: usize) usize {
    return @max(3, term_rows -| chrome);
}

fn emphasis(th: Theme) []const u8 {
    return if (th.reset.len != 0) ansi.sgr.bold else "";
}

// ── /help ───────────────────────────────────────────────────────────────────

pub const HelpDialog = struct {
    pub const Tab = enum { general, commands, custom };

    catalog: complete.SlashCatalog,
    term_rows: usize,
    tab: Tab = .general,
    /// First visible entry of the current list.
    top: usize = 0,

    pub fn draw(self: *HelpDialog, p: *Pane) !void {
        try p.rule();
        try self.drawTabs(p);
        try p.blank();
        switch (self.tab) {
            .general => {
                try p.paragraph("", "metacodes understands your codebase, makes edits with your permission, and runs commands, right from your terminal.");
                try p.blank();
                try p.title("Shortcuts");
                var lines: std.ArrayList(u8) = .empty;
                defer lines.deinit(p.allocator);
                var sink: CrlfSink = .{ .out = &lines, .allocator = p.allocator };
                // The pane keeps the last column free; lay the grid out for that.
                _ = try ui.renderHelpLines(&sink, @import("tui/theme.zig").monochrome, @intCast(@min(p.cols -| 1, std.math.maxInt(u16))));
                var it = std.mem.splitSequence(u8, lines.items, "\r\n");
                while (it.next()) |line| {
                    if (line.len == 0) continue;
                    // renderHelpLines indents by two; the pane indents again.
                    try p.text(std.mem.trimStart(u8, line, " "));
                }
            },
            .commands => try self.drawList(p, .builtin, "Browse default commands", ""),
            .custom => try self.drawList(p, .skill, "Browse custom commands", "No custom commands. Add a Skill at .claude/skills/<name>/SKILL.md."),
        }
        try p.blank();
        try p.footer("←/→ or tab to switch · ↑/↓ to scroll · Esc to close");
    }

    fn drawTabs(self: *const HelpDialog, p: *Pane) !void {
        const th = p.th;
        const styled = th.reset.len != 0;
        const active = if (styled) ansi.sgr.reverse else "";
        const names = [_][]const u8{ "General", "Commands", "Custom commands" };
        var parts: [8]Pane.Span = undefined;
        var n: usize = 0;
        parts[n] = .{ .style = emphasis(th), .text = "Help" };
        n += 1;
        for (names, 0..) |name, i| {
            const on = @intFromEnum(self.tab) == i;
            parts[n] = .{ .text = "  " };
            n += 1;
            parts[n] = .{
                .style = if (on) active else th.dim,
                .text = if (on and !styled) bracketed(name) else name,
            };
            n += 1;
        }
        try p.spans(parts[0..n]);
    }

    fn bracketed(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, "General")) return "[General]";
        if (std.mem.eql(u8, name, "Commands")) return "[Commands]";
        return "[Custom commands]";
    }

    fn count(self: *const HelpDialog, kind: complete.SlashKind) usize {
        var n: usize = 0;
        for (self.catalog.entries) |cmd| n += @intFromBool(listed(cmd, kind));
        return n;
    }

    /// A command of `kind` as help lists it: once, by its own name, not again
    /// for each argument the `/` menu spells out (`/login openrouter`).
    fn listed(cmd: complete.SlashCmd, kind: complete.SlashKind) bool {
        return cmd.kind == kind and cmd.arg_of.len == 0;
    }

    /// Each entry takes two rows (name, description).
    fn visibleEntries(self: *const HelpDialog) usize {
        return @max(2, listRows(self.term_rows, 12) / 2);
    }

    fn drawList(self: *HelpDialog, p: *Pane, kind: complete.SlashKind, heading: []const u8, empty: []const u8) !void {
        const total = self.count(kind);
        if (total == 0) {
            try p.dim(empty);
            return;
        }
        try p.text(heading);
        try p.blank();
        const visible = self.visibleEntries();
        self.top = @min(self.top, total -| visible);
        var index: usize = 0;
        var shown: usize = 0;
        for (self.catalog.entries) |cmd| {
            if (!listed(cmd, kind)) continue;
            defer index += 1;
            if (index < self.top or shown >= visible) continue;
            shown += 1;
            const more_below = shown == visible and self.top + visible < total;
            const more_above = shown == 1 and self.top > 0;
            const marker = if (more_below) "↓ " else if (more_above) "↑ " else "  ";
            var name_buf: [96]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}{s}{s}{s}", .{
                marker,
                cmd.name,
                if (cmd.hint.len != 0) " " else "",
                cmd.hint,
            }) catch cmd.name;
            try p.text(name);
            var desc_buf: [256]u8 = undefined;
            const desc = if (cmd.source.len != 0)
                std.fmt.bufPrint(&desc_buf, "    {s} ({s})", .{ cmd.desc, cmd.source }) catch cmd.desc
            else
                std.fmt.bufPrint(&desc_buf, "    {s}", .{cmd.desc}) catch cmd.desc;
            try p.dim(desc);
        }
    }

    pub fn key(self: *HelpDialog, k: input.Key) Step {
        switch (k) {
            .esc, .ctrl_c => return .done,
            .tab, .right => {
                self.tab = switch (self.tab) {
                    .general => .commands,
                    .commands => .custom,
                    .custom => .general,
                };
                self.top = 0;
                return .redraw;
            },
            .shift_tab, .left => {
                self.tab = switch (self.tab) {
                    .general => .custom,
                    .commands => .general,
                    .custom => .commands,
                };
                self.top = 0;
                return .redraw;
            },
            .down => {
                const kind: complete.SlashKind = switch (self.tab) {
                    .general => return .none,
                    .commands => .builtin,
                    .custom => .skill,
                };
                const total = self.count(kind);
                if (self.top + self.visibleEntries() >= total) return .none;
                self.top += 1;
                return .redraw;
            },
            .up => {
                if (self.tab == .general or self.top == 0) return .none;
                self.top -= 1;
                return .redraw;
            },
            else => return .none,
        }
    }

    pub fn tick(_: *HelpDialog) Step {
        return .none;
    }
};

/// Collects `ui.renderHelpLines` output.
const CrlfSink = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pub fn writeAll(self: *CrlfSink, bytes: []const u8) !void {
        try self.out.appendSlice(self.allocator, bytes);
    }
};

// ── /skills ─────────────────────────────────────────────────────────────────

/// Claude Code's `/skills`: every Skill with its `skillOverrides` state.
/// Enter or Space cycles the selected one through on → name-only →
/// user-invocable-only → off; typing (or `/`) searches. Closing reports the
/// Skills whose state changed (`changes`), which the command saves.
pub const SkillsDialog = struct {
    pub const State = overrides_mod.State;

    /// A Skill whose state the dialog cannot change.
    pub const Lock = enum {
        none,
        /// `disable-model-invocation: true`: the model never sees it.
        author,
    };

    pub const Mode = enum { list, search };

    allocator: std.mem.Allocator,
    snapshot: ?*const catalog_mod.Snapshot,
    term_rows: usize,
    /// State per snapshot record when the dialog opened, and now.
    initial: []State = &.{},
    current: []State = &.{},
    mode: Mode = .list,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    sel: usize = 0,
    top: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        snapshot: ?*const catalog_mod.Snapshot,
        overrides: ?*overrides_mod.Overrides,
        term_rows: usize,
    ) !SkillsDialog {
        var self = SkillsDialog{ .allocator = allocator, .snapshot = snapshot, .term_rows = term_rows };
        const listed = self.records();
        self.initial = try allocator.alloc(State, listed.len);
        errdefer allocator.free(self.initial);
        self.current = try allocator.alloc(State, listed.len);
        errdefer allocator.free(self.current);
        @memset(self.initial, .on);
        if (overrides) |o| {
            const names = try allocator.alloc([]const u8, listed.len);
            defer allocator.free(names);
            for (listed, names) |record, *name| name.* = record.invocation_name;
            o.statesOf(names, self.initial);
        }
        @memcpy(self.current, self.initial);
        return self;
    }

    pub fn deinit(self: *SkillsDialog) void {
        self.allocator.free(self.initial);
        self.allocator.free(self.current);
        self.* = undefined;
    }

    /// The Skills whose state the user changed (names borrowed from the
    /// snapshot), in catalog order.
    pub fn changes(self: *const SkillsDialog, allocator: std.mem.Allocator) ![]overrides_mod.Change {
        var out: std.ArrayList(overrides_mod.Change) = .empty;
        errdefer out.deinit(allocator);
        for (self.records(), self.initial, self.current) |record, before, after| {
            if (before != after) try out.append(allocator, .{ .name = record.invocation_name, .state = after });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn lockOf(record: *const catalog_mod.SkillRecord) Lock {
        return if (record.definition.disable_model_invocation) .author else .none;
    }

    fn queryText(self: *const SkillsDialog) []const u8 {
        return self.query[0..self.query_len];
    }

    fn records(self: *const SkillsDialog) []const catalog_mod.SkillRecord {
        return if (self.snapshot) |snap| snap.skills else &.{};
    }

    fn matches(self: *const SkillsDialog, record: *const catalog_mod.SkillRecord) bool {
        const q = self.queryText();
        if (q.len == 0) return true;
        return containsFold(record.invocation_name, q) or containsFold(record.definition.description, q);
    }

    fn matchCount(self: *const SkillsDialog) usize {
        var n: usize = 0;
        for (self.records()) |*record| n += @intFromBool(self.matches(record));
        return n;
    }

    /// Index in the snapshot of the `nth` Skill that matches the query.
    fn nthMatch(self: *const SkillsDialog, nth: usize) ?usize {
        var n: usize = 0;
        for (self.records(), 0..) |*record, index| {
            if (!self.matches(record)) continue;
            if (n == nth) return index;
            n += 1;
        }
        return null;
    }

    fn visibleRows(self: *const SkillsDialog) usize {
        return listRows(self.term_rows, 12);
    }

    pub fn draw(self: *SkillsDialog, p: *Pane) !void {
        const th = p.th;
        try p.rule();
        try p.title("Skills");
        const total = self.records().len;
        const matches_n = self.matchCount();
        var count_buf: [48]u8 = undefined;
        const count = (if (self.query_len == 0)
            std.fmt.bufPrint(&count_buf, "{d} skill{s}", .{ total, if (total == 1) "" else "s" })
        else
            std.fmt.bufPrint(&count_buf, "{d}/{d} skills", .{ matches_n, total })) catch "";
        var head_buf: [160]u8 = undefined;
        try p.dim(std.fmt.bufPrint(&head_buf, "{s} · {s}", .{ count, switch (self.mode) {
            .list => "enter/space to cycle, / to search, Esc to close",
            .search => "type to filter · ↓/enter to select · esc to clear",
        } }) catch count);
        try p.blank();
        try p.search(self.queryText(), "Search skills…");
        // The cursor rests in the box only while it has the focus.
        if (self.mode == .list) p.cursor = null;

        if (self.snapshot == null) {
            try p.text("The skill catalog did not load; run with METACODES_LOG=warn to see why.");
            return;
        }
        if (total == 0) {
            try p.text("No skills installed. Add one at .claude/skills/<name>/SKILL.md");
            try p.dim("(also read: ~/.claude/skills, .agents/skills, .codex/skills, .metacodes/skills)");
        } else if (matches_n == 0) {
            var none_buf: [96]u8 = undefined;
            try p.dim(std.fmt.bufPrint(&none_buf, "No skills match \"{s}\"", .{self.queryText()}) catch "No skills match");
        } else {
            const visible = self.visibleRows();
            self.sel = @min(self.sel, matches_n - 1);
            if (self.sel < self.top) self.top = self.sel;
            if (self.sel >= self.top + visible) self.top = self.sel + 1 - visible;
            var i = self.top;
            while (i < matches_n and i < self.top + visible) : (i += 1) {
                const index = self.nthMatch(i).?;
                try self.drawRow(p, index, self.mode == .list and i == self.sel);
            }
            if (self.top + visible < matches_n) {
                var more_buf: [32]u8 = undefined;
                try p.dim(std.fmt.bufPrint(&more_buf, "  ↓ {d} more", .{matches_n - self.top - visible}) catch "  ↓ more");
            }
        }
        if (self.snapshot.?.issues.len != 0) {
            const issues = self.snapshot.?.issues.len;
            try p.blank();
            var issue_buf: [96]u8 = undefined;
            try p.line(th.warn, std.fmt.bufPrint(&issue_buf, "{d} skill{s} did not load · /doctor", .{
                issues,
                if (issues == 1) "" else "s",
            }) catch "Some skills did not load");
        }
    }

    /// `❯ ✔ on         name · user · < 20 tok` (Claude Code's row).
    fn drawRow(self: *const SkillsDialog, p: *Pane, index: usize, selected: bool) !void {
        const th = p.th;
        const record = &self.records()[index];
        const lock = lockOf(record);
        const state: State = switch (lock) {
            .none => self.current[index],
            .author => if (self.current[index] == .off) .off else .user_invocable_only,
        };
        const ascii = std.mem.eql(u8, th.box_h, "-");
        const glyph: []const u8 = if (lock != .none)
            (if (ascii) "#" else "🔒")
        else switch (state) {
            .on => if (ascii) "+" else "✔",
            .name_only => if (ascii) "*" else "●",
            .user_invocable_only => if (ascii) "o" else "◯",
            .off => if (ascii) "x" else "✘",
        };
        const color: []const u8 = if (lock != .none) "" else switch (state) {
            .on => th.success,
            .name_only => "",
            .user_invocable_only => th.warn,
            .off => th.danger,
        };
        var label_buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s: <11}", .{stateLabel(state)}) catch stateLabel(state);
        var tokens_buf: [24]u8 = undefined;
        var detail_buf: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, " · {s} · {s}{s}", .{
            scopeName(record.source_scope),
            tokenEstimate(record, &tokens_buf),
            if (lock == .author) " · locked by author" else "",
        }) catch "";
        const pointer: []const u8 = if (!selected) "  " else if (ascii) "> " else "❯ ";
        try p.spans(&.{
            .{ .style = if (selected) th.accent else "", .text = pointer },
            .{ .style = color, .text = glyph },
            .{ .text = " " },
            .{ .style = if (selected) emphasis(th) else "", .text = label },
            .{ .style = if (selected) emphasis(th) else "", .text = record.invocation_name },
            .{ .style = th.dim, .text = detail },
        });
    }

    pub fn key(self: *SkillsDialog, k: input.Key) Step {
        return switch (self.mode) {
            .list => self.listKey(k),
            .search => self.searchKey(k),
        };
    }

    fn listKey(self: *SkillsDialog, k: input.Key) Step {
        switch (k) {
            .esc, .ctrl_c => return .done,
            .up => {
                if (self.sel == 0) return .none;
                self.sel -= 1;
                return .redraw;
            },
            .down => {
                if (self.sel + 1 >= self.matchCount()) return .none;
                self.sel += 1;
                return .redraw;
            },
            .enter => return self.cycleSelected(),
            .char => |c| {
                if (c == ' ') return self.cycleSelected();
                self.mode = .search;
                if (c == '/') return .redraw;
                return self.typeChar(c);
            },
            .backspace => {
                self.mode = .search;
                _ = self.deleteChar();
                return .redraw;
            },
            else => return .none,
        }
    }

    fn searchKey(self: *SkillsDialog, k: input.Key) Step {
        switch (k) {
            .ctrl_c => return .done,
            .esc => {
                // A query clears first; an empty one leaves the search.
                if (self.query_len != 0) {
                    self.query_len = 0;
                    self.sel = 0;
                    self.top = 0;
                } else {
                    self.mode = .list;
                }
                return .redraw;
            },
            .down, .enter => {
                self.mode = .list;
                return .redraw;
            },
            .backspace => return self.deleteChar(),
            .char => |c| return self.typeChar(c),
            else => return .none,
        }
    }

    fn typeChar(self: *SkillsDialog, c: u8) Step {
        if (c < 0x20 or self.query_len >= self.query.len) return .none;
        self.query[self.query_len] = c;
        self.query_len += 1;
        self.sel = 0;
        self.top = 0;
        return .redraw;
    }

    fn deleteChar(self: *SkillsDialog) Step {
        if (self.query_len == 0) return .none;
        var end = self.query_len - 1;
        while (end > 0 and (self.query[end] & 0xc0) == 0x80) end -= 1;
        self.query_len = end;
        self.sel = 0;
        self.top = 0;
        return .redraw;
    }

    fn cycleSelected(self: *SkillsDialog) Step {
        const index = self.nthMatch(self.sel) orelse return .none;
        if (lockOf(&self.records()[index]) != .none) return .none;
        self.current[index] = self.current[index].next();
        return .redraw;
    }

    pub fn tick(_: *SkillsDialog) Step {
        return .none;
    }
};

/// The state column of `/skills` (Claude Code shortens the third one).
fn stateLabel(state: SkillsDialog.State) []const u8 {
    return switch (state) {
        .on => "on",
        .name_only => "name-only",
        .user_invocable_only => "user-only",
        .off => "off",
    };
}

/// What the Skill's listing line costs the model, roughly (4 bytes a token):
/// `< 20 tok` or `~N tok`.
fn tokenEstimate(record: *const catalog_mod.SkillRecord, buf: []u8) []const u8 {
    const bytes = record.invocation_name.len + 4 + record.definition.description.len + record.definition.when_to_use.len;
    const tokens = (bytes + 3) / 4;
    if (tokens < 20) return "< 20 tok";
    return std.fmt.bufPrint(buf, "~{d} tok", .{tokens}) catch "";
}

pub fn scopeName(scope: catalog_mod.SourceScope) []const u8 {
    return switch (scope) {
        .enterprise => "enterprise",
        .personal => "user",
        .project => "project",
        .plugin => "plugin",
    };
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── /login ──────────────────────────────────────────────────────────────────

/// What to do about a key that was not stored, by the flow's error name.
fn failureAdvice(buffer: []u8, name: []const u8, provider_id: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "KeyRefused"))
        return "The provider refused this key. Check that it was copied whole and that it is a key for the plan you chose.";
    if (std.mem.startsWith(u8, name, "KeyCheckFailed"))
        return std.fmt.bufPrint(buffer, "The key could not be checked (network or provider error); nothing was stored. Retry, or store it unchecked with `metacodes login --provider {s} --api-key-stdin --no-check`.", .{provider_id}) catch "The key could not be checked; nothing was stored.";
    return "Nothing was stored.";
}

/// What a key grant's failure means, by the flow's error name (the worker
/// keeps names, and a cause in parentheses after one).
fn keyGrantFailure(buffer: []u8, name: []const u8, provider_label: []const u8, retry: []const u8) []const u8 {
    const own = [_]anyerror{ error.KeyGrantDeclined, error.KeyGrantCodeExpired, error.KeyGrantCodeRefused, error.KeyGrantExchangeFailed };
    for (own) |err| {
        if (std.mem.startsWith(u8, name, @errorName(err))) return openrouter_login.failureLine(buffer, err, provider_label, retry);
    }
    return std.fmt.bufPrint(buffer, "Could not reach {s} ({s}). Nothing was stored.", .{ provider_label, name }) catch "The sign-in failed. Nothing was stored.";
}

/// `count` bullets for a secret being typed, at most as many as fit `buffer`
/// (each is three bytes).
fn maskFor(buffer: []u8, count: usize) []const u8 {
    var len: usize = 0;
    for (0..@min(count, 24)) |_| {
        if (len + 3 > buffer.len) break;
        @memcpy(buffer[len..][0..3], "\u{2022}");
        len += 3;
    }
    return buffer[0..len];
}

pub const LoginDialog = struct {
    /// Providers the list shows. The pane neither scrolls nor filters yet, so
    /// the ones past it are named under the list instead (`unlistedCount`),
    /// and `/login <id>` starts any of them.
    pub const MAX_PROVIDERS = 12;
    /// Providers a dialog holds: the listed ones, and the ones past them that
    /// `/login <id>` starts directly.
    pub const CAPACITY = 64;

    pub const Choice = struct {
        profile: *const provider_profile.ProviderProfile,
        method: Method,
    };

    /// How a provider is signed in to: a grant ready to run, or a key the user
    /// creates on the provider's key page and pastes here
    /// (`ProviderProfile.api_key_setup`).
    pub const Method = union(enum) {
        flow: provider_login.Flow,
        api_key,
    };

    /// `how` and `code_entry` are a key grant's (OpenRouter): which way to
    /// sign in, and the code pasted back from another device.
    pub const Stage = enum { choose, how, code_entry, key_page, key_entry, signing_in, failed };

    /// Where a key grant starts: asking which way, or straight on another
    /// device (`/login <provider> --device-code`).
    pub const HowStart = enum { ask, other_device };

    pub const Outcome = union(enum) {
        interrupted,
        signed_in: []const u8,
        /// A pasted key was checked and stored for this provider.
        key_stored: []const u8,
        /// The sign-in could not start (no worker thread, out of memory).
        failed: []const u8,
    };

    /// Longest key accepted from a paste.
    pub const MAX_KEY_LEN = provider_login.MAX_KEY_LEN;

    allocator: std.mem.Allocator,
    io: std.Io,
    choices: [CAPACITY]Choice = undefined,
    choices_len: usize = 0,
    /// Providers offered past `CAPACITY`: not held, only counted, so the list
    /// still says how many it leaves out.
    dropped: usize = 0,
    sel: usize = 0,
    stage: Stage = .choose,
    worker: ?*login_worker_mod.LoginWorker = null,
    /// A cancelled sign-in whose thread is still in a request; the host
    /// takes it (`takeDetached`) so closing the dialog never waits on it.
    detached: ?*login_worker_mod.LoginWorker = null,
    failure: [96]u8 = undefined,
    failure_len: usize = 0,
    transcript: [login_worker_mod.TRANSCRIPT_CAPACITY]u8 = undefined,
    transcript_len: usize = 0,
    outcome: Outcome = .interrupted,
    /// What a key flow is started with: where it is stored, whether a key
    /// page may be opened in the browser.
    key_options: provider_login.Options = .{ .state_root = "" },
    key_page: usize = 0,
    key_buffer: [MAX_KEY_LEN]u8 = undefined,
    key_len: usize = 0,
    /// A key grant: the way chosen on `how`, whether that list starts on the
    /// other device (an SSH session), and where it starts.
    how_sel: usize = 0,
    how_ssh: bool = false,
    how_start: HowStart = .ask,
    /// The key grant's third way was taken: a key the user already has is
    /// pasted, as for a provider without a sign-in (`key_page`, `key_entry`).
    pasting: bool = false,
    /// The other-device way between showing its page and the pasted code:
    /// the verifier stays here (zeroed on release), the page goes to the user.
    pending: ?openrouter_login.Pending = null,

    /// Offer `choice`; past `CAPACITY` it is only counted (`dropped`).
    pub fn add(self: *LoginDialog, choice: Choice) void {
        if (self.choices_len >= CAPACITY) {
            self.dropped += 1;
            return;
        }
        self.choices[self.choices_len] = choice;
        self.choices_len += 1;
    }

    /// Offer the provider `/login <id>` named, and return its index for
    /// `startAt`. It is held even past `CAPACITY`: it takes the last place,
    /// whose provider is then only counted.
    pub fn addNamed(self: *LoginDialog, choice: Choice) usize {
        if (self.choices_len < CAPACITY) {
            self.add(choice);
            return self.choices_len - 1;
        }
        self.dropped += 1;
        self.choices[CAPACITY - 1] = choice;
        return CAPACITY - 1;
    }

    /// How many the list shows (`MAX_PROVIDERS` at most).
    pub fn listedLen(self: *const LoginDialog) usize {
        return @min(self.choices_len, MAX_PROVIDERS);
    }

    /// How many offered providers the list leaves out.
    pub fn unlistedCount(self: *const LoginDialog) usize {
        return self.choices_len - self.listedLen() + self.dropped;
    }

    /// The provider the dialog last signed in to or stored a key for.
    pub fn chosenProfile(self: *const LoginDialog) *const provider_profile.ProviderProfile {
        return self.current().profile;
    }

    /// Jump straight to signing in (`/login <provider>`), listed or not.
    pub fn startAt(self: *LoginDialog, index: usize) void {
        if (index >= self.choices_len) return;
        self.sel = index;
        self.begin();
    }

    /// Back to the list. A provider started past it (`/login <id>`) has no
    /// row to point at, so the pointer goes to the first.
    fn backToList(self: *LoginDialog) void {
        if (self.sel >= self.listedLen()) self.sel = 0;
        self.stage = .choose;
    }

    /// `3 more not shown: /login <provider> (my-relay, local-vllm, …)`: the
    /// ids `/login` takes for the providers past the list, as many as fit.
    fn unlistedLine(self: *const LoginDialog, buffer: []u8, count: usize) []const u8 {
        var w: std.Io.Writer = .fixed(buffer);
        w.print("{d} more not shown: /login <provider> (", .{count}) catch return "More providers: /login <provider>";
        const reserve = ", …)".len;
        var written: usize = 0;
        for (self.choices[self.listedLen()..self.choices_len]) |*choice| {
            const id = choice.profile.id.slice();
            if (w.end + id.len + 2 + reserve > buffer.len) break;
            if (written > 0) w.writeAll(", ") catch break;
            w.writeAll(id) catch break;
            written += 1;
        }
        if (written < count) w.writeAll(if (written == 0) "…" else ", …") catch {};
        w.writeAll(")") catch {};
        return w.buffered();
    }

    /// Ends any sign-in still owned here, waiting for its thread.
    pub fn deinit(self: *LoginDialog) void {
        self.clearKey();
        self.releasePending();
        if (self.detached) |worker| join(self.allocator, worker);
        self.detached = null;
        if (self.worker) |worker| {
            worker.cancel();
            join(self.allocator, worker);
        }
        self.worker = null;
    }

    /// The cancelled sign-in left running, for the host to reap.
    pub fn takeDetached(self: *LoginDialog) ?*login_worker_mod.LoginWorker {
        defer self.detached = null;
        return self.detached;
    }

    fn join(allocator: std.mem.Allocator, worker: *login_worker_mod.LoginWorker) void {
        worker.join();
        allocator.destroy(worker);
    }

    /// Cancel the sign-in. A settled thread is joined now; one still inside
    /// a request is handed off (`detached`) instead of blocking the dialog.
    fn stopWorker(self: *LoginDialog) void {
        const worker = self.worker orelse return;
        self.worker = null;
        if (worker.isSettled()) return join(self.allocator, worker);
        worker.cancel();
        if (self.detached) |older| join(self.allocator, older);
        self.detached = worker;
    }

    fn current(self: *const LoginDialog) *const Choice {
        return &self.choices[self.sel];
    }

    fn begin(self: *LoginDialog) void {
        switch (self.current().method) {
            .flow => |flow| switch (flow) {
                .key_grant => self.enterHow(),
                else => self.startFlow(flow),
            },
            .api_key => {
                // The key page for the region the user is most likely on.
                const profile = self.current().profile;
                const default = profile.defaultKeyPage(profile.default_channel);
                self.key_page = 0;
                if (profile.api_key_setup) |setup| {
                    for (setup.pages, 0..) |page, i| {
                        if (default != null and page.id.eql(default.?.id)) self.key_page = i;
                    }
                }
                self.clearKey();
                self.failure_len = 0;
                // A provider the user configured has no page to choose or
                // open: its key comes from whoever runs it.
                self.stage = if (self.pageless()) .key_entry else .key_page;
            },
        }
    }

    fn keyPages(self: *const LoginDialog) []const provider_profile.KeyPage {
        const setup = self.current().profile.api_key_setup orelse return &.{};
        return setup.pages;
    }

    /// The key is only pasted: one page, and nowhere to create the key on
    /// (`KeyPage.url`, a configured provider's).
    fn pageless(self: *const LoginDialog) bool {
        const pages = self.keyPages();
        return pages.len == 1 and pages[0].url == null;
    }

    fn clearKey(self: *LoginDialog) void {
        std.crypto.secureZero(u8, self.key_buffer[0..self.key_len]);
        self.key_len = 0;
    }

    /// The key grant the current choice runs, if it is one.
    fn keyGrant(self: *const LoginDialog) ?provider_login.KeyGrantPrepared {
        return switch (self.current().method) {
            .flow => |flow| switch (flow) {
                .key_grant => |prepared| prepared,
                else => null,
            },
            .api_key => null,
        };
    }

    /// The ways a key grant offers, in the order `how` lists them. A key
    /// grant always has a key setup (`validateProfile`), so pasting a key is
    /// always the last.
    const HowWay = enum { browser, other_device, paste_key };
    const HOW_WAYS = [_]HowWay{ .browser, .other_device, .paste_key };

    fn howLabel(way: HowWay) []const u8 {
        return switch (way) {
            .browser => "Sign in with the browser on this computer",
            .other_device => "Sign in on another device (SSH, no browser here)",
            .paste_key => "Paste an API key you already have",
        };
    }

    /// A key grant's first step: which way, or the other device at once.
    fn enterHow(self: *LoginDialog) void {
        self.releasePending();
        self.clearKey();
        self.failure_len = 0;
        self.pasting = false;
        if (self.how_start == .other_device) {
            // Only the first start: a retry asks.
            self.how_start = .ask;
            return self.chooseHow(.other_device);
        }
        // In an SSH session the browser that would follow a loopback redirect
        // is on another machine: the other device is the way that works.
        self.how_sel = if (self.how_ssh) 1 else 0;
        self.stage = .how;
    }

    fn chooseHow(self: *LoginDialog, way: HowWay) void {
        const prepared = self.keyGrant() orelse return;
        switch (way) {
            .browser => self.startFlow(.{ .key_grant = prepared }),
            .other_device => {
                self.releasePending();
                self.pending = openrouter_login.Pending.begin(self.allocator, prepared.origin, prepared.grant) catch |err| {
                    self.setFailure(@errorName(err));
                    return;
                };
                self.clearKey();
                self.stage = .code_entry;
            },
            .paste_key => {
                self.pasting = true;
                self.key_page = 0;
                self.clearKey();
                // One page (OpenRouter's keys page): no plan to pick, so
                // straight to the paste, which shows the page.
                self.stage = if (self.keyPages().len > 1) .key_page else .key_entry;
            },
        }
    }

    /// Trade the pasted code on the worker. The worker copies the code and the
    /// verifier when it starts, so both are wiped here right after.
    fn submitCode(self: *LoginDialog) void {
        var prepared = self.keyGrant() orelse return;
        const pending = &(self.pending orelse return);
        prepared.pasted = .{
            .code = std.mem.trim(u8, self.key_buffer[0..self.key_len], " \t"),
            .verifier = pending.verifier(),
        };
        self.startFlow(.{ .key_grant = prepared });
        self.clearKey();
        self.releasePending();
    }

    fn releasePending(self: *LoginDialog) void {
        if (self.pending) |*pending| pending.deinit();
        self.pending = null;
    }

    /// Check and store the pasted key on the worker thread. The worker copies
    /// it, so the field is wiped as soon as the flow is handed over.
    fn submitKey(self: *LoginDialog) void {
        const pages = self.keyPages();
        if (pages.len == 0) return;
        const prepared = provider_login.prepareApiKey(
            self.current().profile,
            pages[self.key_page].id.slice(),
            null,
            self.key_buffer[0..self.key_len],
            self.key_options,
        ) catch |err| {
            self.setFailure(@errorName(err));
            return;
        };
        self.startFlow(.{ .api_key = prepared });
        self.clearKey();
    }

    fn startFlow(self: *LoginDialog, flow: provider_login.Flow) void {
        self.stopWorker();
        self.transcript_len = 0;
        self.failure_len = 0;
        const worker = self.allocator.create(login_worker_mod.LoginWorker) catch {
            self.setFailure("out of memory");
            return;
        };
        worker.* = login_worker_mod.LoginWorker.initFlow(self.allocator, self.io, flow);
        worker.start() catch |err| {
            self.allocator.destroy(worker);
            self.setFailure(@errorName(err));
            return;
        };
        self.worker = worker;
        self.stage = .signing_in;
    }

    fn setFailure(self: *LoginDialog, why: []const u8) void {
        const n = @min(why.len, self.failure.len);
        @memcpy(self.failure[0..n], why[0..n]);
        self.failure_len = n;
        self.stage = .failed;
    }

    fn label(choice: *const Choice) []const u8 {
        return choice.profile.display_name;
    }

    fn method(choice: *const Choice) []const u8 {
        return switch (choice.method) {
            .api_key => "API key",
            .flow => |flow| switch (flow) {
                .metask => "device code",
                .api_key => "API key",
                .key_grant => "browser sign-in",
                .oauth => |prepared| switch (prepared.options.method) {
                    .loopback => "browser sign-in",
                    .device_code => "device code",
                },
            },
        };
    }

    pub fn draw(self: *LoginDialog, p: *Pane) !void {
        try p.rule();
        try p.title("Login");
        try p.blank();
        switch (self.stage) {
            .choose => {
                if (self.choices_len == 0) {
                    try p.paragraph("", "No configured provider supports signing in here. Providers that use an API key read it from the environment or from <state root>/config.json.");
                    try p.blank();
                    try p.footer("Esc to close");
                    return;
                }
                try p.paragraph("", "Sign in to a provider; the login is stored on this machine and used by new sessions.");
                try p.blank();
                try p.text("Select a provider:");
                try p.blank();
                for (self.choices[0..self.listedLen()], 0..) |*choice, i| {
                    try p.option(i + 1, i == self.sel, label(choice), method(choice));
                }
                // The pane cannot scroll the rest into view: they are named,
                // never silently left out.
                const unlisted = self.unlistedCount();
                if (unlisted > 0) {
                    var more_buf: [512]u8 = undefined;
                    try p.blank();
                    try p.paragraph(p.th.dim, self.unlistedLine(&more_buf, unlisted));
                }
                try p.blank();
                try p.footer("↑/↓ to select · Enter to sign in · Esc to cancel");
            },
            .how => {
                const profile = self.current().profile;
                var head_buf: [160]u8 = undefined;
                try p.text(std.fmt.bufPrint(&head_buf, "Sign in to {s}", .{profile.display_name}) catch "Sign in");
                try p.blank();
                var about_buf: [256]u8 = undefined;
                try p.paragraph("", std.fmt.bufPrint(&about_buf, "{s} creates an API key on your account; what you use is billed to your {s} credits.", .{ profile.display_name, profile.display_name }) catch "");
                try p.blank();
                for (HOW_WAYS, 0..) |way, i| {
                    try p.option(i + 1, i == self.how_sel, howLabel(way), "");
                }
                if (self.how_ssh) {
                    try p.blank();
                    try p.paragraph(p.th.dim, "This looks like an SSH session: sign in on another device instead.");
                }
                try p.blank();
                try p.footer("↑/↓ to select · Enter to continue · Esc to go back");
            },
            .code_entry => {
                const profile = self.current().profile;
                var head_buf: [160]u8 = undefined;
                try p.text(std.fmt.bufPrint(&head_buf, "Sign in to {s} on another device", .{profile.display_name}) catch "Sign in on another device");
                try p.blank();
                try p.text("1. Open this URL on any device:");
                if (self.pending) |*pending| try p.raw(pending.url);
                var approve_buf: [160]u8 = undefined;
                try p.text(std.fmt.bufPrint(&approve_buf, "2. Approve the new API key. {s} then shows a code.", .{profile.display_name}) catch "2. Approve the new API key.");
                try p.text("3. Paste the code here (it works once, for 10 minutes):");
                try p.blank();
                var mask_buf: [64]u8 = undefined;
                var code_line: [160]u8 = undefined;
                try p.text(if (self.key_len == 0)
                    "Code: (paste it; it is not shown)"
                else
                    std.fmt.bufPrint(&code_line, "Code: {s}  ({d} characters)", .{ maskFor(&mask_buf, self.key_len), self.key_len }) catch "Code: (entered)");
                try p.blank();
                try p.footer("Enter to finish · Esc to go back");
            },
            .key_page => {
                const profile = self.current().profile;
                var head_buf: [160]u8 = undefined;
                try p.text(std.fmt.bufPrint(&head_buf, "Create an API key for {s}", .{profile.display_name}) catch "Create an API key");
                try p.blank();
                if (profile.api_key_setup) |setup| if (setup.note) |note| {
                    try p.paragraph(p.th.warn, note);
                    try p.blank();
                };
                try p.text("Which plan is the key for?");
                try p.blank();
                for (self.keyPages(), 0..) |page, i| {
                    try p.option(i + 1, i == self.key_page, page.label, "");
                }
                try p.blank();
                try p.footer(if (self.key_options.open_browser)
                    "↑/↓ to select · Enter opens the page · Esc to go back"
                else
                    "↑/↓ to select · Enter to continue · Esc to go back");
            },
            .key_entry => {
                const page = self.keyPages()[self.key_page];
                if (page.url) |url| {
                    try p.text("Create a key on this page, then paste it here:");
                    try p.blank();
                    try p.raw(url);
                } else {
                    var head_buf: [160]u8 = undefined;
                    try p.text(std.fmt.bufPrint(&head_buf, "Paste the API key for {s}:", .{self.current().profile.display_name}) catch "Paste the API key:");
                }
                try p.blank();
                var mask_buf: [64]u8 = undefined;
                const shown = @min(self.key_len, 24);
                var mask_len: usize = 0;
                for (0..shown) |_| {
                    // "•" is three bytes; the buffer holds 21 of them.
                    if (mask_len + 3 > mask_buf.len) break;
                    @memcpy(mask_buf[mask_len..][0..3], "\u{2022}");
                    mask_len += 3;
                }
                var key_line: [160]u8 = undefined;
                try p.text(if (self.key_len == 0)
                    "Key: (paste it; it is not shown)"
                else
                    std.fmt.bufPrint(&key_line, "Key: {s}  ({d} characters)", .{ mask_buf[0..mask_len], self.key_len }) catch "Key: (entered)");
                try p.blank();
                try p.footer("Enter to check and store · Esc to go back");
            },
            .signing_in => {
                var head_buf: [128]u8 = undefined;
                try p.text(std.fmt.bufPrint(&head_buf, "Signing in to {s}…", .{label(self.current())}) catch "Signing in…");
                try p.blank();
                try self.drawTranscript(p);
                try p.blank();
                try p.footer("Esc to cancel");
            },
            .failed => {
                const th = p.th;
                if (!self.pasting) if (self.keyGrant()) |prepared| {
                    var line_buf: [256]u8 = undefined;
                    var retry_buf: [96]u8 = undefined;
                    const retry = std.fmt.bufPrint(&retry_buf, "/login {s}", .{prepared.provider_id.slice()}) catch "/login";
                    try p.line(th.danger, keyGrantFailure(&line_buf, self.failure[0..self.failure_len], prepared.provider_label, retry));
                    try p.blank();
                    try p.footer("Enter to retry · Esc to cancel");
                    return;
                };
                var head_buf: [192]u8 = undefined;
                const keyed = self.current().method == .api_key or self.pasting;
                const head_args = .{ label(self.current()), self.failure[0..self.failure_len] };
                try p.line(th.danger, (if (keyed)
                    std.fmt.bufPrint(&head_buf, "The key for {s} was not stored: {s}", head_args)
                else
                    std.fmt.bufPrint(&head_buf, "Sign-in to {s} failed: {s}", head_args)) catch "Sign-in failed");
                if (keyed) {
                    var advice_buf: [256]u8 = undefined;
                    try p.blank();
                    try p.paragraph("", failureAdvice(&advice_buf, self.failure[0..self.failure_len], self.current().profile.id.slice()));
                }
                try p.blank();
                try p.footer("Enter to retry · Esc to cancel");
            },
        }
    }

    /// What the flow asked the user to do. URLs are written whole at column
    /// 0 so they can be copied; the rest is indented prose.
    fn drawTranscript(self: *LoginDialog, p: *Pane) !void {
        const text = self.transcript[0..self.transcript_len];
        if (std.mem.trim(u8, text, " \r\n").len == 0) {
            try p.dim("Waiting for the provider…");
            return;
        }
        var lines = std.mem.splitScalar(u8, text, '\n');
        var blank_pending = false;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r");
            if (line.len == 0) {
                blank_pending = true;
                continue;
            }
            if (blank_pending) try p.blank();
            blank_pending = false;
            if (std.mem.startsWith(u8, line, "http://") or std.mem.startsWith(u8, line, "https://")) {
                try p.raw(line);
            } else {
                try p.paragraph("", line);
            }
        }
    }

    pub fn key(self: *LoginDialog, k: input.Key) Step {
        switch (self.stage) {
            .choose => switch (k) {
                .esc, .ctrl_c => return .done,
                .up => {
                    const n = self.listedLen();
                    if (n == 0) return .none;
                    self.sel = if (self.sel == 0) n - 1 else self.sel - 1;
                    return .redraw;
                },
                .down => {
                    const n = self.listedLen();
                    if (n == 0) return .none;
                    self.sel = (self.sel + 1) % n;
                    return .redraw;
                },
                .enter => {
                    if (self.choices_len == 0) return .done;
                    self.begin();
                    return .redraw;
                },
                .char => |c| {
                    // Number keys pick a provider, as in Claude Code's selects.
                    if (c < '1' or c > '9') return .none;
                    const index: usize = c - '1';
                    if (index >= self.listedLen()) return .none;
                    self.sel = index;
                    self.begin();
                    return .redraw;
                },
                else => return .none,
            },
            .how => switch (k) {
                .esc => {
                    self.backToList();
                    return .redraw;
                },
                .ctrl_c => {
                    self.outcome = .interrupted;
                    return .done;
                },
                .up => {
                    self.how_sel = if (self.how_sel == 0) HOW_WAYS.len - 1 else self.how_sel - 1;
                    return .redraw;
                },
                .down => {
                    self.how_sel = (self.how_sel + 1) % HOW_WAYS.len;
                    return .redraw;
                },
                .enter => {
                    self.chooseHow(HOW_WAYS[self.how_sel]);
                    return .redraw;
                },
                .char => |c| {
                    if (c < '1' or c > '9') return .none;
                    const index: usize = c - '1';
                    if (index >= HOW_WAYS.len) return .none;
                    self.how_sel = index;
                    self.chooseHow(HOW_WAYS[index]);
                    return .redraw;
                },
                else => return .none,
            },
            .code_entry => switch (k) {
                .esc => {
                    self.clearKey();
                    self.releasePending();
                    self.stage = .how;
                    return .redraw;
                },
                .ctrl_c => {
                    self.clearKey();
                    self.releasePending();
                    self.outcome = .interrupted;
                    return .done;
                },
                .backspace => {
                    if (self.key_len == 0) return .none;
                    self.key_len -= 1;
                    self.key_buffer[self.key_len] = 0;
                    return .redraw;
                },
                .ctrl_u => {
                    self.clearKey();
                    return .redraw;
                },
                .enter => {
                    if (std.mem.trim(u8, self.key_buffer[0..self.key_len], " \t").len == 0) return .none;
                    self.submitCode();
                    return .redraw;
                },
                .char => |c| {
                    if (c <= ' ' or c == 0x7f) return .none;
                    if (self.key_len == self.key_buffer.len) return .none;
                    self.key_buffer[self.key_len] = c;
                    self.key_len += 1;
                    return .redraw;
                },
                else => return .none,
            },
            .key_page => switch (k) {
                .esc => {
                    if (self.pasting) {
                        self.pasting = false;
                        self.stage = .how;
                    } else {
                        self.backToList();
                    }
                    return .redraw;
                },
                .ctrl_c => {
                    self.outcome = .interrupted;
                    return .done;
                },
                .up => {
                    const n = self.keyPages().len;
                    if (n == 0) return .none;
                    self.key_page = if (self.key_page == 0) n - 1 else self.key_page - 1;
                    return .redraw;
                },
                .down => {
                    const n = self.keyPages().len;
                    if (n == 0) return .none;
                    self.key_page = (self.key_page + 1) % n;
                    return .redraw;
                },
                .enter => {
                    if (self.keyPages().len == 0) return .none;
                    if (self.key_options.open_browser) if (self.keyPages()[self.key_page].url) |url| {
                        // Best effort: the page is also printed whole to copy.
                        @import("../core/auth.zig").openBrowser(self.allocator, url) catch {};
                    };
                    self.stage = .key_entry;
                    return .redraw;
                },
                .char => |c| {
                    if (c < '1' or c > '9') return .none;
                    const index: usize = c - '1';
                    if (index >= self.keyPages().len) return .none;
                    self.key_page = index;
                    return .redraw;
                },
                else => return .none,
            },
            .key_entry => switch (k) {
                .esc => {
                    self.clearKey();
                    // Back the way it came: a key grant's ways for a key
                    // pasted from there with no plan to pick, the provider
                    // list for a pasted key with no page, else the page list.
                    if (self.pasting and self.keyPages().len <= 1) {
                        self.pasting = false;
                        self.stage = .how;
                    } else if (self.pageless()) {
                        self.backToList();
                    } else {
                        self.stage = .key_page;
                    }
                    return .redraw;
                },
                .ctrl_c => {
                    self.clearKey();
                    self.outcome = .interrupted;
                    return .done;
                },
                .backspace => {
                    if (self.key_len == 0) return .none;
                    self.key_len -= 1;
                    self.key_buffer[self.key_len] = 0;
                    return .redraw;
                },
                .ctrl_u => {
                    self.clearKey();
                    return .redraw;
                },
                .enter => {
                    if (std.mem.trim(u8, self.key_buffer[0..self.key_len], " \t").len == 0) return .none;
                    self.submitKey();
                    return .redraw;
                },
                .char => |c| {
                    // A paste arrives as characters; whitespace and controls a
                    // terminal adds around it are not part of a key.
                    if (c <= ' ' or c == 0x7f) return .none;
                    if (self.key_len == self.key_buffer.len) return .none;
                    self.key_buffer[self.key_len] = c;
                    self.key_len += 1;
                    return .redraw;
                },
                else => return .none,
            },
            .signing_in => switch (k) {
                .esc, .ctrl_c => {
                    self.stopWorker();
                    self.outcome = .interrupted;
                    return .done;
                },
                else => return .none,
            },
            .failed => switch (k) {
                .esc, .ctrl_c => {
                    self.outcome = .interrupted;
                    return .done;
                },
                .enter => {
                    // A key grant asks again which way; a refused key is
                    // re-pasted on the same page.
                    if (self.pasting) {
                        self.clearKey();
                        self.stage = .key_entry;
                    } else if (self.keyGrant() != null) {
                        self.enterHow();
                    } else if (self.current().method == .api_key) {
                        self.clearKey();
                        self.stage = .key_entry;
                    } else {
                        self.begin();
                    }
                    return .redraw;
                },
                else => return .none,
            },
        }
    }

    /// Follow the worker: new instructions redraw; a settled flow finishes
    /// (success) or shows its failure with a retry.
    pub fn tick(self: *LoginDialog) Step {
        if (self.stage != .signing_in) return .none;
        const worker = self.worker orelse return .none;
        var buf: [login_worker_mod.TRANSCRIPT_CAPACITY]u8 = undefined;
        const text = worker.copyTranscript(&buf);
        const changed = !std.mem.eql(u8, text, self.transcript[0..self.transcript_len]);
        if (changed) {
            @memcpy(self.transcript[0..text.len], text);
            self.transcript_len = text.len;
        }
        switch (worker.currentState()) {
            .idle, .running => return if (changed) .redraw else .none,
            .succeeded => {
                self.stopWorker();
                self.outcome = if (self.current().method == .api_key or self.pasting)
                    .{ .key_stored = label(self.current()) }
                else
                    .{ .signed_in = label(self.current()) };
                return .done;
            },
            .cancelled => {
                self.stopWorker();
                self.outcome = .interrupted;
                return .done;
            },
            .failed => {
                var why_buf: [96]u8 = undefined;
                const why = if (worker.failureCause()) |cause|
                    std.fmt.bufPrint(&why_buf, "{s} ({s})", .{ worker.failureName(), cause }) catch worker.failureName()
                else
                    worker.failureName();
                self.setFailure(why);
                self.stopWorker();
                return .redraw;
            },
        }
    }
};

// ── /login: the Metask browser sign-in (#485, #527) ─────────────────────────

/// `/login` with no provider: the Metask browser sign-in, then the model and
/// reasoning level `metacodes login` asks for line by line, as choices in the
/// pane. `/login metask` is the same with the device code (`device_code`).
/// The sign-in is used with its own token at the gateway it names, so there
/// is no API key to choose (#527). The network work runs on a worker
/// (`api/metask_sign_in.zig`); this only draws and moves between stages. Esc
/// at any stage closes it with nothing stored: the caller stores the sign-in
/// only after `outcome` is `chosen`.
pub const MetaskSignInDialog = struct {
    pub const Stage = enum {
        /// Waiting for the browser to come back (or the code to be
        /// confirmed), then listing the models.
        signing_in,
        choose_model,
        choose_effort,
        failed,
    };

    pub const Outcome = enum { cancelled, chosen };

    allocator: std.mem.Allocator,
    worker: ?*metask_sign_in.Worker = null,
    stage: Stage = .signing_in,
    sel: usize = 0,
    term_rows: usize = 24,
    /// `/login metask`: a code confirmed on any device, not the browser
    /// coming back here (`metask_sign_in.Options.device_code`).
    device_code: bool = false,
    /// The providers `/login <provider>` signs in to, comma-separated, for
    /// the line that says so (borrowed); empty leaves it out.
    others: []const u8 = "",
    transcript: [metask_sign_in.TRANSCRIPT_CAPACITY]u8 = undefined,
    transcript_len: usize = 0,
    failure: [96]u8 = undefined,
    failure_len: usize = 0,
    /// The models the sign-in can use on `/v1/messages`, parsed from the
    /// worker's answer.
    models: model_catalog.Catalog,
    model_index: usize = 0,
    efforts: model_catalog.ReasoningOptions = undefined,
    efforts_len: usize = 0,
    effort: ?types.ReasoningEffort = null,
    outcome: Outcome = .cancelled,

    pub fn init(allocator: std.mem.Allocator) MetaskSignInDialog {
        return .{ .allocator = allocator, .models = model_catalog.Catalog.init(allocator) };
    }

    /// Start the sign-in. A worker that cannot start is the dialog's failure.
    pub fn start(self: *MetaskSignInDialog, io: std.Io, options: metask_sign_in.Options) void {
        self.device_code = options.device_code;
        const worker = metask_sign_in.Worker.create(self.allocator, io, options) catch {
            self.setFailure("out of memory");
            return;
        };
        worker.startSignIn() catch |err| {
            worker.release();
            self.setFailure(@errorName(err));
            return;
        };
        self.worker = worker;
        self.stage = .signing_in;
    }

    /// Lets go of the worker (a step still running frees it when it ends).
    pub fn deinit(self: *MetaskSignInDialog) void {
        if (self.worker) |worker| worker.release();
        self.worker = null;
        self.models.deinit();
    }

    /// After `chosen`: the worker, holding the token response
    /// (`takeTokenJson`), the gateway it names and that gateway's
    /// `/v1/models` answer. The caller releases it.
    pub fn takeWorker(self: *MetaskSignInDialog) ?*metask_sign_in.Worker {
        defer self.worker = null;
        return self.worker;
    }

    pub fn chosenModel(self: *const MetaskSignInDialog) ?[]const u8 {
        if (self.model_index >= self.models.entries.items.len) return null;
        return self.models.entries.items[self.model_index].model_id;
    }

    fn setFailure(self: *MetaskSignInDialog, why: []const u8) void {
        const n = @min(why.len, self.failure.len);
        @memcpy(self.failure[0..n], why[0..n]);
        self.failure_len = n;
        self.stage = .failed;
    }

    /// How many choices the current stage lists.
    fn choiceCount(self: *const MetaskSignInDialog) usize {
        return switch (self.stage) {
            .choose_model => self.models.entries.items.len,
            .choose_effort => self.efforts_len,
            else => 0,
        };
    }

    fn chooseModel(self: *MetaskSignInDialog, index: usize) void {
        self.model_index = index;
        const entry = self.models.entries.items[index];
        self.efforts_len = model_catalog.reasoningOptions(entry.reasoning_mask, &self.efforts).len;
        self.stage = .choose_effort;
        // The level a model declares in the middle, as `/models` starts on.
        const preferred = model_catalog.defaultReasoningForMask(entry.reasoning_mask);
        self.sel = 0;
        if (preferred) |level| for (self.efforts[0..self.efforts_len], 0..) |candidate, i| {
            if (candidate == level) self.sel = i;
        };
    }

    fn chooseEffort(self: *MetaskSignInDialog, index: usize) Step {
        self.effort = self.efforts[index];
        self.outcome = .chosen;
        return .done;
    }

    fn pick(self: *MetaskSignInDialog, index: usize) Step {
        if (index >= self.choiceCount()) return .none;
        switch (self.stage) {
            .choose_model => self.chooseModel(index),
            .choose_effort => return self.chooseEffort(index),
            else => return .none,
        }
        return .redraw;
    }

    pub fn draw(self: *MetaskSignInDialog, p: *Pane) !void {
        try p.rule();
        try p.title("Sign in to Metask");
        try p.blank();
        switch (self.stage) {
            .signing_in => {
                try p.paragraph("", if (self.device_code)
                    "Confirm the code below in a browser on any device; then choose a model and a reasoning level here."
                else
                    "Sign in in your browser; you come back here to choose a model and a reasoning level.");
                try p.blank();
                try self.drawTranscript(p);
                try p.blank();
                // A machine with no browser to come back from (#485): the
                // device-code sign-in needs only a code typed elsewhere.
                if (!self.device_code) {
                    try p.paragraph(p.th.dim, "No browser on this machine? /login metask signs in with a short code instead.");
                    try p.blank();
                }
                if (self.others.len > 0) {
                    var others_buf: [512]u8 = undefined;
                    try p.paragraph(p.th.dim, std.fmt.bufPrint(&others_buf, "Another provider instead: /login <provider> ({s})", .{self.others}) catch "Another provider instead: /login <provider>");
                    try p.blank();
                }
                try p.footer("Esc to cancel");
            },
            .choose_model, .choose_effort => try self.drawChoices(p),
            .failed => {
                var head: [160]u8 = undefined;
                try p.line(p.th.danger, std.fmt.bufPrint(&head, "Sign-in failed: {s}", .{self.failure[0..self.failure_len]}) catch "Sign-in failed");
                try p.blank();
                try p.paragraph("", "Nothing was stored.");
                try p.blank();
                try p.footer("Enter to retry · Esc to close");
            },
        }
    }

    fn drawChoices(self: *MetaskSignInDialog, p: *Pane) !void {
        const count = self.choiceCount();
        try p.text(switch (self.stage) {
            .choose_model => "Select a model:",
            else => "Select a reasoning level:",
        });
        try p.blank();
        // A long list scrolls with the selection.
        const rows = listRows(self.term_rows, 10);
        const first = if (self.sel >= rows) self.sel + 1 - rows else 0;
        const last = @min(count, first + rows);
        if (first > 0) try p.dim("  ↑ more");
        var detail_buf: [96]u8 = undefined;
        for (first..last) |i| {
            switch (self.stage) {
                .choose_model => {
                    const entry = self.models.entries.items[i];
                    const detail = if (entry.max_input_tokens) |window|
                        std.fmt.bufPrint(&detail_buf, "context {d}", .{window}) catch ""
                    else
                        "";
                    try p.option(i + 1, i == self.sel, entry.model_id, detail);
                },
                else => {
                    const entry = self.models.entries.items[self.model_index];
                    try p.option(i + 1, i == self.sel, model_catalog.effortLabel(entry.effort_vocabulary, self.efforts[i]), "");
                },
            }
        }
        if (last < count) try p.dim("  ↓ more");
        try p.blank();
        try p.footer("↑/↓ to select · Enter to choose · Esc to cancel");
    }

    /// What the sign-in asked the user to do (the URL to open), whole lines,
    /// URLs at column 0 so they can be copied.
    fn drawTranscript(self: *MetaskSignInDialog, p: *Pane) !void {
        const text = self.transcript[0..self.transcript_len];
        if (std.mem.trim(u8, text, " \r\n").len == 0) {
            try p.dim("Starting the sign-in…");
            return;
        }
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "http://") or std.mem.startsWith(u8, line, "https://")) {
                try p.raw(line);
            } else {
                try p.paragraph("", line);
            }
        }
    }

    pub fn key(self: *MetaskSignInDialog, k: input.Key) Step {
        switch (k) {
            .esc, .ctrl_c => {
                self.outcome = .cancelled;
                return .done;
            },
            else => {},
        }
        switch (self.stage) {
            .choose_model, .choose_effort => {
                const count = self.choiceCount();
                if (count == 0) return .none;
                switch (k) {
                    .up => {
                        self.sel = if (self.sel == 0) count - 1 else self.sel - 1;
                        return .redraw;
                    },
                    .down => {
                        self.sel = (self.sel + 1) % count;
                        return .redraw;
                    },
                    .enter => return self.pick(self.sel),
                    .char => |c| {
                        if (c < '1' or c > '9') return .none;
                        return self.pick(c - '1');
                    },
                    else => return .none,
                }
            },
            .failed => {
                if (k != .enter) return .none;
                // Retry from the browser.
                const worker = self.worker orelse return .none;
                const options: metask_sign_in.Options = .{ .open_browser = worker.open_browser, .port = worker.port, .device_code = worker.device_code };
                const io = worker.io;
                worker.release();
                self.worker = null;
                self.transcript_len = 0;
                self.start(io, options);
                return .redraw;
            },
            .signing_in => return .none,
        }
    }

    /// Follow the worker: a new instruction redraws; a finished step moves on.
    pub fn tick(self: *MetaskSignInDialog) Step {
        const worker = self.worker orelse return .none;
        var buf: [metask_sign_in.TRANSCRIPT_CAPACITY]u8 = undefined;
        const text = worker.copyTranscript(&buf);
        const changed = !std.mem.eql(u8, text, self.transcript[0..self.transcript_len]);
        if (changed) {
            @memcpy(self.transcript[0..text.len], text);
            self.transcript_len = text.len;
        }
        switch (self.stage) {
            .signing_in => switch (worker.currentState()) {
                .models_ready => {
                    self.models.deinit();
                    self.models = model_catalog.Catalog.init(self.allocator);
                    self.models.loadFromModelsListJson(worker.models_json orelse "") catch |err| {
                        self.setFailure(@errorName(err));
                        return .redraw;
                    };
                    // The gateway also lists image and video models: only
                    // the ones it serves on `/v1/messages` can run a session.
                    self.models.dropMessagesUnsupported();
                    if (self.models.entries.items.len == 0) {
                        self.setFailure("no model this account can chat with");
                        return .redraw;
                    }
                    self.sel = 0;
                    self.stage = .choose_model;
                    return .redraw;
                },
                .failed => {
                    self.setFailure(worker.failureName());
                    return .redraw;
                },
                .cancelled => {
                    self.outcome = .cancelled;
                    return .done;
                },
                else => return if (changed) .redraw else .none,
            },
            else => return .none,
        }
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const theme_mod = @import("tui/theme.zig");

fn renderPlain(dialog: anytype, cols: usize) ![]u8 {
    var p = Pane.init(testing.allocator, theme_mod.monochrome, cols);
    defer p.deinit();
    try dialog.draw(&p);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var i: usize = 0;
    const bytes = p.bytes.items;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '[') {
            var j = i + 2;
            while (j < bytes.len and !(bytes[j] >= 0x40 and bytes[j] <= 0x7e)) j += 1;
            i = j + 1;
            continue;
        }
        if (bytes[i] != '\r') try out.append(testing.allocator, bytes[i]);
        i += 1;
    }
    return out.toOwnedSlice(testing.allocator);
}

test "help: tabs cycle both ways and Esc closes" {
    var help = HelpDialog{ .catalog = .builtin, .term_rows = 40 };
    try testing.expectEqual(Step.redraw, help.key(.tab));
    try testing.expectEqual(HelpDialog.Tab.commands, help.tab);
    try testing.expectEqual(Step.redraw, help.key(.right));
    try testing.expectEqual(HelpDialog.Tab.custom, help.tab);
    try testing.expectEqual(Step.redraw, help.key(.right));
    try testing.expectEqual(HelpDialog.Tab.general, help.tab);
    try testing.expectEqual(Step.redraw, help.key(.left));
    try testing.expectEqual(HelpDialog.Tab.custom, help.tab);
    try testing.expectEqual(Step.done, help.key(.esc));
}

test "help: the general tab shows the shortcuts, the commands tab the table" {
    var help = HelpDialog{ .catalog = .builtin, .term_rows = 60 };
    const general = try renderPlain(&help, 100);
    defer testing.allocator.free(general);
    try testing.expect(std.mem.indexOf(u8, general, "[General]") != null);
    try testing.expect(std.mem.indexOf(u8, general, "! for shell mode") != null);
    try testing.expect(std.mem.indexOf(u8, general, "Esc to close") != null);

    _ = help.key(.tab);
    const commands = try renderPlain(&help, 100);
    defer testing.allocator.free(commands);
    try testing.expect(std.mem.indexOf(u8, commands, "/add-dir <path>") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "Add a working directory") != null);

    _ = help.key(.tab);
    const custom = try renderPlain(&help, 100);
    defer testing.allocator.free(custom);
    try testing.expect(std.mem.indexOf(u8, custom, "No custom commands") != null);
}

test "help: the command list scrolls inside its window" {
    var help = HelpDialog{ .catalog = .builtin, .term_rows = 20, .tab = .commands };
    const visible = help.visibleEntries();
    try testing.expect(visible < complete.SLASH_COMMAND_TABLE.len);
    try testing.expectEqual(Step.none, help.key(.up));
    var moved: usize = 0;
    while (help.key(.down) == .redraw) moved += 1;
    try testing.expectEqual(complete.SLASH_COMMAND_TABLE.len - visible, moved);
    const tail = try renderPlain(&help, 100);
    defer testing.allocator.free(tail);
    try testing.expect(std.mem.indexOf(u8, tail, "/vim") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "/add-dir") == null);
}

test "skills: an unloaded catalog says so and Esc closes" {
    var dialog = try SkillsDialog.init(testing.allocator, null, null, 30);
    defer dialog.deinit();
    const plain = try renderPlain(&dialog, 80);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "did not load") != null);
    try testing.expectEqual(Step.done, dialog.key(.esc));
    const changes = try dialog.changes(testing.allocator);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 0), changes.len);
}

test "skills: typing searches, backspace removes whole codepoints" {
    var dialog = try SkillsDialog.init(testing.allocator, null, null, 30);
    defer dialog.deinit();
    for ("ré") |c| _ = dialog.key(.{ .char = c });
    try testing.expectEqual(SkillsDialog.Mode.search, dialog.mode);
    try testing.expectEqualStrings("ré", dialog.queryText());
    try testing.expectEqual(Step.redraw, dialog.key(.backspace));
    try testing.expectEqualStrings("r", dialog.queryText());
    _ = dialog.key(.backspace);
    try testing.expectEqual(Step.none, dialog.key(.backspace));
}

fn testSkill(comptime id: u8, name: []const u8, scope: catalog_mod.SourceScope, author_locked: bool) catalog_mod.SkillRecord {
    return .{
        .skill_id = [_]u8{id} ** 64,
        .invocation_name = name,
        .source_scope = scope,
        .definition = .{
            .name = name,
            .description = "does a thing",
            .body = "body",
            .allowed_tools = &.{},
            .disallowed_tools = &.{},
            .arguments = &.{},
            .disable_model_invocation = author_locked,
            .when_to_use = "",
            .description_source = .frontmatter,
            .warnings = .{},
            .argument_hint = "",
            .user_invocable = true,
            .model_activation = .advisory,
            .context = .inline_ctx,
            .agent = "",
            .model = "",
            .shell = "bash",
            .source_path = "",
        },
        .directories = &.{},
        .files = &.{},
    };
}

const SkillsFixture = struct {
    records: [3]catalog_mod.SkillRecord,
    snapshot: catalog_mod.Snapshot,
    overrides: overrides_mod.Overrides,

    /// `alpha` (on), `beta` (name-only from the project layer), `locked`
    /// (`disable-model-invocation`). Must be initialized in place.
    fn init(self: *SkillsFixture) !void {
        self.records = .{
            testSkill('1', "alpha", .project, false),
            testSkill('2', "beta", .personal, false),
            testSkill('3', "locked", .project, true),
        };
        self.snapshot = .{
            .owner_allocator = testing.allocator,
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .scope_id = [_]u8{'a'} ** 64,
            .revision = [_]u8{'b'} ** 64,
            .health = .healthy,
            .skills = &self.records,
            .issues = &.{},
            .descriptor_json = "",
            .content_bytes = 0,
            .resident_bytes = 0,
        };
        self.overrides = overrides_mod.Overrides.init(testing.allocator);
        try self.overrides.layers[@intFromEnum(overrides_mod.Layer.project)].put(testing.allocator, try testing.allocator.dupe(u8, "beta"), .name_only);
    }

    fn deinit(self: *SkillsFixture) void {
        self.overrides.deinit();
        self.snapshot.arena.deinit();
    }
};

test "skills: rows show each state, the author lock, the scope and the cost" {
    var fx: SkillsFixture = undefined;
    try fx.init();
    defer fx.deinit();
    var dialog = try SkillsDialog.init(testing.allocator, &fx.snapshot, &fx.overrides, 30);
    defer dialog.deinit();
    var p = Pane.init(testing.allocator, theme_mod.no_color, 100);
    defer p.deinit();
    try dialog.draw(&p);
    const out = p.bytes.items;
    try testing.expect(std.mem.indexOf(u8, out, "3 skills · enter/space to cycle, / to search, Esc to close") != null);
    try testing.expect(std.mem.indexOf(u8, out, "❯ ✔ on         alpha · project · < 20 tok") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  ● name-only  beta · user · < 20 tok") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  🔒 user-only  locked · project · < 20 tok · locked by author") != null);
    // The search box has no cursor while the list has the focus.
    try testing.expect(p.cursor == null);
}

test "skills: Enter and Space cycle on, name-only, user-only, off; a lock does not move" {
    var fx: SkillsFixture = undefined;
    try fx.init();
    defer fx.deinit();
    var dialog = try SkillsDialog.init(testing.allocator, &fx.snapshot, &fx.overrides, 30);
    defer dialog.deinit();

    try testing.expectEqual(Step.redraw, dialog.key(.enter));
    try testing.expectEqual(SkillsDialog.State.name_only, dialog.current[0]);
    try testing.expectEqual(Step.redraw, dialog.key(.{ .char = ' ' }));
    try testing.expectEqual(SkillsDialog.State.user_invocable_only, dialog.current[0]);
    _ = dialog.key(.enter);
    try testing.expectEqual(SkillsDialog.State.off, dialog.current[0]);
    _ = dialog.key(.enter);
    try testing.expectEqual(SkillsDialog.State.on, dialog.current[0]);
    {
        // Back where it started: nothing to save (Claude Code: `No changes`).
        const changes = try dialog.changes(testing.allocator);
        defer testing.allocator.free(changes);
        try testing.expectEqual(@as(usize, 0), changes.len);
    }

    _ = dialog.key(.down);
    _ = dialog.key(.down);
    try testing.expectEqual(Step.none, dialog.key(.enter));
    try testing.expectEqual(Step.none, dialog.key(.{ .char = ' ' }));
    try testing.expectEqual(SkillsDialog.State.on, dialog.current[2]);

    // beta starts at its inherited name-only; three presses reach on.
    _ = dialog.key(.up);
    for (0..3) |_| _ = dialog.key(.enter);
    _ = dialog.key(.up);
    _ = dialog.key(.enter);
    const changes = try dialog.changes(testing.allocator);
    defer testing.allocator.free(changes);
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("alpha", changes[0].name);
    try testing.expectEqual(SkillsDialog.State.name_only, changes[0].state);
    try testing.expectEqualStrings("beta", changes[1].name);
    try testing.expectEqual(SkillsDialog.State.on, changes[1].state);
}

test "skills: search takes Space as text; Esc clears, then leaves, then closes" {
    var fx: SkillsFixture = undefined;
    try fx.init();
    defer fx.deinit();
    var dialog = try SkillsDialog.init(testing.allocator, &fx.snapshot, &fx.overrides, 30);
    defer dialog.deinit();

    try testing.expectEqual(Step.redraw, dialog.key(.{ .char = '/' }));
    try testing.expectEqual(SkillsDialog.Mode.search, dialog.mode);
    try testing.expectEqualStrings("", dialog.queryText());
    for ("be") |c| _ = dialog.key(.{ .char = c });
    _ = dialog.key(.{ .char = ' ' });
    try testing.expectEqualStrings("be ", dialog.queryText());
    {
        const plain = try renderPlain(&dialog, 100);
        defer testing.allocator.free(plain);
        try testing.expect(std.mem.indexOf(u8, plain, "0/3 skills · type to filter · ↓/enter to select · esc to clear") != null);
        try testing.expect(std.mem.indexOf(u8, plain, "No skills match \"be \"") != null);
    }
    _ = dialog.key(.backspace);
    // Down hands the focus to the list; the filtered row is the selection.
    try testing.expectEqual(Step.redraw, dialog.key(.down));
    try testing.expectEqual(SkillsDialog.Mode.list, dialog.mode);
    _ = dialog.key(.enter);
    try testing.expectEqual(SkillsDialog.State.user_invocable_only, dialog.current[1]);
    try testing.expectEqual(SkillsDialog.State.on, dialog.current[0]);

    _ = dialog.key(.{ .char = 'x' });
    try testing.expectEqual(SkillsDialog.Mode.search, dialog.mode);
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqualStrings("", dialog.queryText());
    try testing.expectEqual(SkillsDialog.Mode.search, dialog.mode);
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqual(SkillsDialog.Mode.list, dialog.mode);
    try testing.expectEqual(Step.done, dialog.key(.esc));
}

test "metask sign-in: the browser wait names the short-code sign-in for a machine without a browser (#485)" {
    var dialog = MetaskSignInDialog.init(testing.allocator);
    defer dialog.deinit();
    dialog.others = "deepseek, zai-coding-plan";
    const plain = try renderPlain(&dialog, 120);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "No browser on this machine? /login metask signs in with a short code instead.") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "Another provider instead: /login <provider> (deepseek, zai-coding-plan)") != null);
}

test "login: no provider to sign in to says how keys are configured" {
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined };
    defer dialog.deinit();
    const plain = try renderPlain(&dialog, 80);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "No configured provider supports signing in") != null);
    try testing.expectEqual(Step.done, dialog.key(.enter));
    try testing.expect(dialog.outcome == .interrupted);
}

test "login: the list wraps, numbers are shown, Esc interrupts" {
    const kinds = [_]provider_profile.CredentialKind{.openai_oauth};
    const profile = provider_profile.ProviderProfile{
        .id = @import("../provider/ids.zig").Slug.lit("dialog-test"),
        .implementation_id = @import("../provider/ids.zig").Slug.lit("dialog-test"),
        .display_name = "Dialog Test",
        .channels = &.{},
        .accepted_credential_kinds = &kinds,
        .oauth_token_url = "http://127.0.0.1:1/token",
        .oauth_authorize_url = "http://127.0.0.1:1/authorize",
        .oauth_client_id = "dialog-client",
    };
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined };
    defer dialog.deinit();
    const flow = try provider_login.prepareFlow(&profile, .{ .state_root = "", .open_browser = false, .port = 0 }, null);
    dialog.add(.{ .profile = &profile, .method = .{ .flow = flow } });
    dialog.add(.{ .profile = &profile, .method = .{ .flow = flow } });
    const plain = try renderPlain(&dialog, 80);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "> 1. Dialog Test · browser sign-in") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "    2. Dialog Test") != null);
    try testing.expectEqual(Step.redraw, dialog.key(.up));
    try testing.expectEqual(@as(usize, 1), dialog.sel);
    try testing.expectEqual(Step.redraw, dialog.key(.down));
    try testing.expectEqual(@as(usize, 0), dialog.sel);
    try testing.expectEqual(Step.done, dialog.key(.esc));
    try testing.expect(dialog.outcome == .interrupted);
}

/// `count` key providers `p1`…`p<count>` (the GLM Coding Plan's setup).
fn manyKeyProviders(comptime count: usize) [count]provider_profile.ProviderProfile {
    comptime {
        @setEvalBranchQuota(20_000 * count);
        var list: [count]provider_profile.ProviderProfile = undefined;
        for (&list, 0..) |*entry, i| {
            entry.* = @import("../provider/profiles/zai_coding_plan.zig").PROFILE;
            entry.id = @import("../provider/ids.zig").Slug.lit(std.fmt.comptimePrint("p{d}", .{i + 1}));
        }
        return list;
    }
}

test "login: past the rows it shows, the list names the rest, and /login <id> still starts one" {
    const many = comptime manyKeyProviders(14);
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false } };
    defer dialog.deinit();
    for (many[0..13]) |*profile| dialog.add(.{ .profile = profile, .method = .api_key });
    // `/login p14`: the 14th, past the 12 rows.
    const named = dialog.addNamed(.{ .profile = &many[13], .method = .api_key });
    try testing.expectEqual(@as(usize, 13), named);
    try testing.expectEqual(@as(usize, LoginDialog.MAX_PROVIDERS), dialog.listedLen());
    try testing.expectEqual(@as(usize, 2), dialog.unlistedCount());

    const listed = try renderPlain(&dialog, 160);
    defer testing.allocator.free(listed);
    try testing.expect(std.mem.indexOf(u8, listed, "12. Z.AI GLM Coding Plan") != null);
    try testing.expect(std.mem.indexOf(u8, listed, "13. ") == null);
    try testing.expect(std.mem.indexOf(u8, listed, "2 more not shown: /login <provider> (p13, p14)") != null);
    // The keys move over the listed rows only.
    try testing.expectEqual(Step.redraw, dialog.key(.up));
    try testing.expectEqual(@as(usize, LoginDialog.MAX_PROVIDERS - 1), dialog.sel);
    try testing.expectEqual(Step.redraw, dialog.key(.down));
    try testing.expectEqual(@as(usize, 0), dialog.sel);

    // `/login p14` starts it; Esc leaves it for the list, pointing at a row.
    dialog.startAt(named);
    try testing.expectEqual(LoginDialog.Stage.key_page, dialog.stage);
    try testing.expectEqualStrings("p14", dialog.current().profile.id.slice());
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqual(LoginDialog.Stage.choose, dialog.stage);
    try testing.expectEqual(@as(usize, 0), dialog.sel);
}

test "login: past what a dialog holds, the providers are counted and the named one still gets in" {
    const many = comptime manyKeyProviders(LoginDialog.CAPACITY + 3);
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false } };
    defer dialog.deinit();
    for (many[0 .. LoginDialog.CAPACITY + 2]) |*profile| dialog.add(.{ .profile = profile, .method = .api_key });
    const named = dialog.addNamed(.{ .profile = &many[LoginDialog.CAPACITY + 2], .method = .api_key });
    try testing.expectEqual(@as(usize, LoginDialog.CAPACITY - 1), named);
    // Offered: CAPACITY + 3; listed: 12.
    try testing.expectEqual(@as(usize, LoginDialog.CAPACITY + 3 - LoginDialog.MAX_PROVIDERS), dialog.unlistedCount());
    // Wide enough that the line is one row.
    const listed = try renderPlain(&dialog, 400);
    defer testing.allocator.free(listed);
    // The ids it holds, then an ellipsis for the ones it only counted.
    try testing.expect(std.mem.indexOf(u8, listed, "55 more not shown: /login <provider> (p13, p14,") != null);
    try testing.expect(std.mem.indexOf(u8, listed, "p67, …)") != null);
    dialog.startAt(named);
    try testing.expectEqualStrings("p67", dialog.current().profile.id.slice());
}

test "login: a key provider goes plan page → paste, and the key is never drawn" {
    const zai = &@import("../provider/profiles/zai_coding_plan.zig").PROFILE;
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false } };
    defer dialog.deinit();
    dialog.add(.{ .profile = zai, .method = .api_key });
    const listed = try renderPlain(&dialog, 200);
    defer testing.allocator.free(listed);
    try testing.expect(std.mem.indexOf(u8, listed, "Z.AI GLM Coding Plan · API key") != null);

    try testing.expectEqual(Step.redraw, dialog.key(.enter));
    try testing.expectEqual(LoginDialog.Stage.key_page, dialog.stage);
    // The default channel is in China, so its personal plan page leads.
    try testing.expectEqualStrings("cn-personal", dialog.keyPages()[dialog.key_page].id.slice());
    const pages = try renderPlain(&dialog, 200);
    defer testing.allocator.free(pages);
    try testing.expect(std.mem.indexOf(u8, pages, "standard API Key page is billed to your balance") != null);
    try testing.expect(std.mem.indexOf(u8, pages, "Global · Team Coding Plan") != null);
    try testing.expectEqual(Step.redraw, dialog.key(.{ .char = '3' }));
    try testing.expectEqualStrings("global-personal", dialog.keyPages()[dialog.key_page].id.slice());
    try testing.expectEqual(Step.redraw, dialog.key(.up));
    try testing.expectEqual(Step.redraw, dialog.key(.down));
    try testing.expectEqual(Step.redraw, dialog.key(.enter));
    try testing.expectEqual(LoginDialog.Stage.key_entry, dialog.stage);

    // Nothing to submit yet; whitespace around a paste is not part of a key.
    try testing.expectEqual(Step.none, dialog.key(.enter));
    for (" sk-secret-42\n") |c| _ = dialog.key(.{ .char = c });
    try testing.expectEqualStrings("sk-secret-42", dialog.key_buffer[0..dialog.key_len]);
    const entry = try renderPlain(&dialog, 200);
    defer testing.allocator.free(entry);
    // The page is printed whole to copy; the key only as a count.
    try testing.expect(std.mem.indexOf(u8, entry, "https://z.ai/manage-apikey/apikey-list") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "(12 characters)") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "sk-secret") == null);
    try testing.expectEqual(Step.redraw, dialog.key(.backspace));
    try testing.expectEqual(@as(usize, 11), dialog.key_len);
    try testing.expectEqual(Step.redraw, dialog.key(.ctrl_u));
    try testing.expectEqual(@as(usize, 0), dialog.key_len);

    // Esc goes back a step and wipes what was typed; Ctrl-C interrupts.
    for ("sk-again") |c| _ = dialog.key(.{ .char = c });
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqual(LoginDialog.Stage.key_page, dialog.stage);
    try testing.expectEqual(@as(usize, 0), dialog.key_len);
    for (dialog.key_buffer[0..8]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqual(LoginDialog.Stage.choose, dialog.stage);
    try testing.expectEqual(Step.redraw, dialog.key(.enter));
    try testing.expectEqual(Step.done, dialog.key(.ctrl_c));
    try testing.expect(dialog.outcome == .interrupted);
}

test "login: a provider the user configured goes straight to the paste, with no page to open" {
    const kinds = [_]provider_profile.CredentialKind{.api_key};
    const pages = [_]provider_profile.KeyPage{.{
        .id = @import("../provider/ids.zig").Slug.lit("key"),
        .label = "House relay",
        .url = null,
        .check_url = "https://relay.example.com/v1/models",
        .check_wire = .openai_chat,
    }};
    const profile = provider_profile.ProviderProfile{
        .id = @import("../provider/ids.zig").Slug.lit("house-relay"),
        .implementation_id = @import("../provider/ids.zig").Slug.lit("house-relay"),
        .display_name = "House relay",
        .channels = &.{},
        .accepted_credential_kinds = &kinds,
        .api_key_setup = .{ .kind = .api_key, .pages = &pages },
    };
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false } };
    defer dialog.deinit();
    dialog.add(.{ .profile = &profile, .method = .api_key });
    try testing.expectEqual(Step.redraw, dialog.key(.enter));
    try testing.expectEqual(LoginDialog.Stage.key_entry, dialog.stage);
    for ("sk-relay-1") |c| _ = dialog.key(.{ .char = c });
    const entry = try renderPlain(&dialog, 200);
    defer testing.allocator.free(entry);
    try testing.expect(std.mem.indexOf(u8, entry, "Paste the API key for House relay:") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "Create a key on this page") == null);
    try testing.expect(std.mem.indexOf(u8, entry, "(10 characters)") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "sk-relay") == null);
    // Esc goes back to the providers, there being no page list to go back to.
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqual(LoginDialog.Stage.choose, dialog.stage);
    try testing.expectEqual(@as(usize, 0), dialog.key_len);
}

/// OpenRouter's sign-in, prepared the way `/login` prepares it.
fn openrouterChoice(options: provider_login.Options) LoginDialog.Choice {
    const openrouter = &@import("../provider/profiles/openrouter.zig").PROFILE;
    const flow = provider_login.prepareFlow(openrouter, options, null) catch unreachable;
    return .{ .profile = openrouter, .method = .{ .flow = flow } };
}

test "login: a key grant asks which way; the other device shows its page and takes a pasted code it never draws" {
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false } };
    defer dialog.deinit();
    dialog.add(openrouterChoice(.{ .state_root = "", .open_browser = false }));
    const listed = try renderPlain(&dialog, 200);
    defer testing.allocator.free(listed);
    try testing.expect(std.mem.indexOf(u8, listed, "OpenRouter · browser sign-in") != null);

    // Enter asks which way, the browser here first; nothing runs yet.
    try testing.expectEqual(Step.redraw, dialog.key(.enter));
    try testing.expectEqual(LoginDialog.Stage.how, dialog.stage);
    try testing.expectEqual(@as(usize, 0), dialog.how_sel);
    try testing.expect(dialog.worker == null);
    const how = try renderPlain(&dialog, 200);
    defer testing.allocator.free(how);
    try testing.expect(std.mem.indexOf(u8, how, "OpenRouter creates an API key on your account; what you use is billed to your OpenRouter credits.") != null);
    try testing.expect(std.mem.indexOf(u8, how, "1. Sign in with the browser on this computer") != null);
    try testing.expect(std.mem.indexOf(u8, how, "2. Sign in on another device (SSH, no browser here)") != null);
    try testing.expect(std.mem.indexOf(u8, how, "SSH session") == null);

    // The other device: its page carries no callback and no state, and the
    // verifier stays in the dialog.
    try testing.expectEqual(Step.redraw, dialog.key(.{ .char = '2' }));
    try testing.expectEqual(LoginDialog.Stage.code_entry, dialog.stage);
    const pending = dialog.pending orelse return error.NoPendingSignIn;
    try testing.expect(std.mem.startsWith(u8, pending.url, "https://openrouter.ai/auth?code_challenge="));
    try testing.expect(std.mem.indexOf(u8, pending.url, "callback_url") == null);
    try testing.expect(std.mem.indexOf(u8, pending.url, "state=") == null);
    try testing.expect(std.mem.indexOf(u8, pending.url, pending.verifier()) == null);
    try testing.expectEqual(Step.none, dialog.key(.enter));
    for (" code-123 ") |c| _ = dialog.key(.{ .char = c });
    try testing.expectEqualStrings("code-123", dialog.key_buffer[0..dialog.key_len]);
    const entry = try renderPlain(&dialog, 200);
    defer testing.allocator.free(entry);
    try testing.expect(std.mem.indexOf(u8, entry, pending.url) != null);
    try testing.expect(std.mem.indexOf(u8, entry, "2. Approve the new API key. OpenRouter then shows a code.") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "3. Paste the code here (it works once, for 10 minutes):") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "(8 characters)") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "code-123") == null);

    // Esc goes back to the ways, wiping the code and the verifier; Esc again
    // goes back to the list.
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqual(LoginDialog.Stage.how, dialog.stage);
    try testing.expect(dialog.pending == null);
    try testing.expectEqual(@as(usize, 0), dialog.key_len);
    for (dialog.key_buffer[0..8]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqual(LoginDialog.Stage.choose, dialog.stage);
}

test "login: a key grant's third way pastes a key the user already has, on OpenRouter's keys page" {
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false } };
    defer dialog.deinit();
    dialog.add(openrouterChoice(.{ .state_root = "", .open_browser = false }));
    _ = dialog.key(.enter);
    const how = try renderPlain(&dialog, 200);
    defer testing.allocator.free(how);
    try testing.expect(std.mem.indexOf(u8, how, "3. Paste an API key you already have") != null);

    // One page: no plan to pick, straight to the paste, which shows it.
    try testing.expectEqual(Step.redraw, dialog.key(.{ .char = '3' }));
    try testing.expectEqual(LoginDialog.Stage.key_entry, dialog.stage);
    try testing.expect(dialog.pasting);
    const entry = try renderPlain(&dialog, 200);
    defer testing.allocator.free(entry);
    try testing.expect(std.mem.indexOf(u8, entry, "https://openrouter.ai/keys") != null);
    for ("sk-or-v1-pasted") |c| _ = dialog.key(.{ .char = c });
    const typed = try renderPlain(&dialog, 200);
    defer testing.allocator.free(typed);
    try testing.expect(std.mem.indexOf(u8, typed, "sk-or-v1") == null);
    try testing.expect(std.mem.indexOf(u8, typed, "(15 characters)") != null);

    // A refused key is pasted again; the failure is a key's, not a sign-in's.
    dialog.setFailure("KeyRefused");
    const failed = try renderPlain(&dialog, 200);
    defer testing.allocator.free(failed);
    try testing.expect(std.mem.indexOf(u8, failed, "The key for OpenRouter was not stored: KeyRefused") != null);
    try testing.expectEqual(Step.redraw, dialog.key(.enter));
    try testing.expectEqual(LoginDialog.Stage.key_entry, dialog.stage);
    try testing.expectEqual(@as(usize, 0), dialog.key_len);

    // Esc goes back to the ways, not to a plan list it never showed.
    try testing.expectEqual(Step.redraw, dialog.key(.esc));
    try testing.expectEqual(LoginDialog.Stage.how, dialog.stage);
    try testing.expect(!dialog.pasting);
}

test "login: over SSH a key grant offers the other device first, and --device-code starts there" {
    {
        var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false }, .how_ssh = true };
        defer dialog.deinit();
        dialog.add(openrouterChoice(.{ .state_root = "", .open_browser = false }));
        _ = dialog.key(.enter);
        try testing.expectEqual(LoginDialog.Stage.how, dialog.stage);
        try testing.expectEqual(@as(usize, 1), dialog.how_sel);
        const how = try renderPlain(&dialog, 200);
        defer testing.allocator.free(how);
        try testing.expect(std.mem.indexOf(u8, how, "This looks like an SSH session: sign in on another device instead.") != null);
    }
    {
        var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false }, .how_start = .other_device };
        defer dialog.deinit();
        dialog.startAt(dialog.addNamed(openrouterChoice(.{ .state_root = "", .open_browser = false })));
        try testing.expectEqual(LoginDialog.Stage.code_entry, dialog.stage);
        try testing.expect(dialog.pending != null);
        // A retry asks which way.
        dialog.setFailure("KeyGrantCodeExpired");
        const failed = try renderPlain(&dialog, 200);
        defer testing.allocator.free(failed);
        try testing.expect(std.mem.indexOf(u8, failed, "That code expired (codes last 10 minutes). Run /login openrouter again.") != null);
        try testing.expectEqual(Step.redraw, dialog.key(.enter));
        try testing.expectEqual(LoginDialog.Stage.how, dialog.stage);
    }
}

test "login: a key that was not stored says why and what to do, by provider" {
    const zai = &@import("../provider/profiles/zai_coding_plan.zig").PROFILE;
    var dialog = LoginDialog{ .allocator = testing.allocator, .io = undefined, .key_options = .{ .state_root = "", .open_browser = false } };
    defer dialog.deinit();
    dialog.add(.{ .profile = zai, .method = .api_key });
    _ = dialog.key(.enter);
    _ = dialog.key(.enter);
    dialog.setFailure("KeyCheckFailed (HttpError)");
    const failed = try renderPlain(&dialog, 200);
    defer testing.allocator.free(failed);
    try testing.expect(std.mem.indexOf(u8, failed, "The key for Z.AI GLM Coding Plan was not stored: KeyCheckFailed") != null);
    try testing.expect(std.mem.indexOf(u8, failed, "metacodes login --provider zai-coding-plan --api-key-stdin --no-check") != null);
    // Enter re-pastes on the same page rather than starting over.
    try testing.expectEqual(Step.redraw, dialog.key(.enter));
    try testing.expectEqual(LoginDialog.Stage.key_entry, dialog.stage);

    dialog.setFailure("KeyRefused");
    const refused = try renderPlain(&dialog, 200);
    defer testing.allocator.free(refused);
    try testing.expect(std.mem.indexOf(u8, refused, "The provider refused this key") != null);
}
