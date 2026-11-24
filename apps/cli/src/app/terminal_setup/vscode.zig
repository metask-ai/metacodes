//! VS Code and its forks (Cursor, Windsurf, VSCodium, …): a `keybindings.json`
//! entry that makes Shift+Enter send the newline sequence in the integrated
//! terminal.
//!
//! The file is JSONC. Every edit splices the user's text (`jsonc.blank` keeps
//! offsets), so comments, trailing commas and formatting survive, and a
//! binding that already holds Shift+Enter in the terminal is reported, never
//! replaced.

const std = @import("std");
const jsonc = @import("jsonc.zig");
const files = @import("files.zig");
const setup = @import("setup.zig");

/// The binding this module adds, as VS Code reads it.
pub const binding_key = "shift+enter";
pub const binding_command = "workbench.action.terminal.sendSequence";
pub const binding_when = "terminalFocus";

pub const ParseError = error{ OutOfMemory, InvalidJsonc, NotAnArray };

/// What a `keybindings.json` makes Shift+Enter do in the integrated terminal.
pub const Status = union(enum) {
    /// Nothing binds it: the terminal gets a plain Enter.
    absent,
    /// The binding that takes effect sends the newline sequence. Claude Code's
    /// `/terminal-setup` writes the same binding, so its install counts.
    installed,
    /// Another binding takes effect there (its text in the file).
    conflict: []const u8,
};

const Doc = struct {
    /// The text without comments: where separators, trailing commas included,
    /// are found. Same offsets as the source.
    bare: []const u8,
    /// null: the document holds no value (missing, empty, or only comments).
    arr: ?jsonc.TopArray,
    spans: []const jsonc.Span,
    values: []const std.json.Value,
};

fn parse(arena: std.mem.Allocator, src: []const u8) ParseError!Doc {
    const bare = try jsonc.blank(arena, src);
    if (jsonc.nextSignificant(bare, 0) == null) return .{ .bare = bare, .arr = null, .spans = &.{}, .values = &.{} };
    const plain = try arena.dupe(u8, bare);
    try jsonc.dropTrailingCommas(plain);
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, plain, .{ .duplicate_field_behavior = .use_last }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJsonc,
    };
    if (root != .array) return error.NotAnArray;
    const arr = jsonc.topArray(bare).?;
    const spans = try jsonc.elements(arena, bare, arr);
    if (spans.len != root.array.items.len) return error.InvalidJsonc;
    return .{ .bare = bare, .arr = arr, .spans = spans, .values = root.array.items };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = object.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// Whether VS Code reads `key` as Shift+Enter, by its own parser
/// (`KeybindingParser`, read in the 1.105 bundle): lower-cased and trimmed,
/// then `ctrl`, `shift`, `alt`, `meta`, `win` or `cmd` each followed by `+` or
/// `-` are taken off the front, in any order and repeated; the rest up to a
/// space is the key, and anything after a space is a further chord. So
/// `Shift-Enter` and `shift+[Enter]` (the scan code) are Shift+Enter, while
/// `enter+shift` names no key at all and `ctrl+k shift+enter` is a chord.
fn isShiftEnter(key: []const u8) bool {
    var buf: [64]u8 = undefined;
    const trimmed = std.mem.trim(u8, key, " \t\r\n");
    if (trimmed.len > buf.len) return false;
    var rest = std.ascii.lowerString(&buf, trimmed);
    var shift = false;
    var other_modifier = false;
    outer: while (true) {
        inline for (.{ "ctrl", "shift", "alt", "meta", "win", "cmd" }) |name| {
            if (rest.len > name.len and std.mem.startsWith(u8, rest, name) and (rest[name.len] == '+' or rest[name.len] == '-')) {
                if (comptime std.mem.eql(u8, name, "shift")) shift = true else other_modifier = true;
                rest = rest[name.len + 1 ..];
                continue :outer;
            }
        }
        break;
    }
    if (std.mem.indexOfScalar(u8, rest, ' ') != null) return false;
    return shift and !other_modifier and (std.mem.eql(u8, rest, "enter") or std.mem.eql(u8, rest, "[enter]"));
}

/// Whether a binding with this `when` can take effect while the terminal has
/// focus: no condition at all, or one that names a terminal context key
/// (`terminalFocus`, `terminalProcessSupported`, …) without negating it.
fn inTerminal(when: ?[]const u8) bool {
    const w = std.mem.trim(u8, when orelse return true, " \t");
    if (w.len == 0) return true;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, w, from, "terminal")) |at| : (from = at + 1) {
        var before = at;
        while (before > 0 and (w[before - 1] == ' ' or w[before - 1] == '\t')) before -= 1;
        if (before == 0 or w[before - 1] != '!') return true;
    }
    return false;
}

fn sendsNewline(object: std.json.ObjectMap) bool {
    const args = object.get("args") orelse return false;
    if (args != .object) return false;
    const text = stringField(args.object, "text") orelse return false;
    return std.mem.eql(u8, text, setup.newline_sequence);
}

const Claim = enum { none, ours, other };

/// Whether a `keybindings.json` element binds Shift+Enter in the terminal, and
/// to what.
fn claim(v: std.json.Value) Claim {
    if (v != .object) return .none;
    const key = stringField(v.object, "key") orelse return .none;
    if (!isShiftEnter(key)) return .none;
    // No command does nothing; `-command` removes a default binding.
    const command = stringField(v.object, "command") orelse return .none;
    if (command.len == 0 or command[0] == '-') return .none;
    if (!inTerminal(stringField(v.object, "when"))) return .none;
    if (std.mem.eql(u8, command, binding_command) and sendsNewline(v.object)) return .ours;
    return .other;
}

/// Exactly the binding `withBinding` writes (the one `withoutBinding` takes out).
fn isAdded(v: std.json.Value) bool {
    if (claim(v) != .ours) return false;
    const when = stringField(v.object, "when") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, when, " \t"), binding_when);
}

/// `src` is the file's text, null when there is none. VS Code reads the user's
/// bindings in order and the last one whose condition holds wins, so the last
/// claim on Shift+Enter in the terminal decides. A conflict borrows `src`.
pub fn classify(gpa: std.mem.Allocator, src: ?[]const u8) ParseError!Status {
    const text = src orelse return .absent;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), text);
    var effective: ?usize = null;
    for (doc.values, 0..) |v, i| {
        if (claim(v) != .none) effective = i;
    }
    const i = effective orelse return .absent;
    return switch (claim(doc.values[i])) {
        .ours => .installed,
        else => .{ .conflict = text[doc.spans[i].start..doc.spans[i].end] },
    };
}

fn isBlank(bytes: []const u8) bool {
    for (bytes) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn lineStart(text: []const u8, at: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
}

fn appendBinding(out: *std.ArrayList(u8), gpa: std.mem.Allocator, indent: []const u8, nl: []const u8, trailing_comma: bool) error{OutOfMemory}!void {
    const fields = [_][]const u8{
        "\"key\": \"" ++ binding_key ++ "\",",
        "\"command\": \"" ++ binding_command ++ "\",",
        // ESC CR, spelled as JSON escapes (setup.newline_sequence).
        "\"args\": { \"text\": \"\\u001b\\r\" },",
        "\"when\": \"" ++ binding_when ++ "\"",
    };
    try out.appendSlice(gpa, indent);
    try out.append(gpa, '{');
    for (fields) |field| {
        try out.appendSlice(gpa, nl);
        try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, field);
    }
    try out.appendSlice(gpa, nl);
    try out.appendSlice(gpa, indent);
    try out.append(gpa, '}');
    if (trailing_comma) try out.append(gpa, ',');
}

/// `src` (null: no file yet) with the binding appended to its array, owned by
/// `gpa`. Comments, line endings and the indentation of the existing entries
/// are kept; a file that ends its array with a trailing comma gets one after
/// the new entry too, so `withoutBinding` gives the original back.
pub fn withBinding(gpa: std.mem.Allocator, src: ?[]const u8) ParseError![]u8 {
    const text = src orelse "";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), text);
    const nl: []const u8 = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const arr = doc.arr orelse {
        // No array yet (no file, an empty one, or only comments): keep what is there.
        try out.appendSlice(gpa, text);
        if (text.len > 0 and text[text.len - 1] != '\n') try out.appendSlice(gpa, nl);
        try out.append(gpa, '[');
        try out.appendSlice(gpa, nl);
        try appendBinding(&out, gpa, "    ", nl, false);
        try out.appendSlice(gpa, nl);
        try out.append(gpa, ']');
        try out.appendSlice(gpa, nl);
        return out.toOwnedSlice(gpa);
    };

    // The first entry's indentation, when it starts its own line.
    var indent: []const u8 = "    ";
    if (doc.spans.len > 0) {
        const start = doc.spans[0].start;
        const ls = lineStart(text, start);
        if (ls > arr.open and isBlank(text[ls..start])) indent = text[ls..start];
    }
    const trailing_comma = arr.last != arr.open and doc.bare[arr.last] == ',';
    const needs_comma = arr.last != arr.open and !trailing_comma;
    // On lines of its own before `]`'s line when only blanks precede `]` there;
    // else on a new line right before `]`.
    const close_line = lineStart(text, arr.close);
    const own_line = close_line > arr.last and isBlank(text[close_line..arr.close]);
    const at = if (own_line) close_line else arr.close;

    try out.appendSlice(gpa, text[0 .. arr.last + 1]);
    if (needs_comma) try out.append(gpa, ',');
    try out.appendSlice(gpa, text[arr.last + 1 .. at]);
    if (!own_line) try out.appendSlice(gpa, nl);
    try appendBinding(&out, gpa, indent, nl, trailing_comma);
    try out.appendSlice(gpa, nl);
    try out.appendSlice(gpa, text[at..]);
    return out.toOwnedSlice(gpa);
}

/// `src` without the last binding `withBinding` writes (owned by `gpa`), or
/// null when it holds none. Whole lines it occupies go with it, and so does the
/// comma that separated it.
pub fn withoutBinding(gpa: std.mem.Allocator, src: []const u8) ParseError!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(), src);
    var found: ?usize = null;
    for (doc.values, 0..) |v, i| {
        if (isAdded(v)) found = i;
    }
    const k = found orelse return null;
    const span = doc.spans[k];

    const ls = lineStart(src, span.start);
    const whole_lines = isBlank(src[ls..span.start]);
    const start = if (whole_lines) ls else span.start;
    var end = span.end;
    // The separator: the comma after the entry, or (the last entry without a
    // trailing comma) the one before it.
    var comma_before: ?usize = null;
    const after = jsonc.nextSignificant(doc.bare, span.end).?;
    if (doc.bare[after] == ',') {
        end = after + 1;
    } else if (k > 0) {
        comma_before = jsonc.prevSignificant(doc.bare, span.start).?;
        std.debug.assert(doc.bare[comma_before.?] == ',');
    }
    if (whole_lines) {
        var e = end;
        while (e < src.len and (src[e] == ' ' or src[e] == '\t')) e += 1;
        if (e < src.len and src[e] == '\r') e += 1;
        if (e < src.len and src[e] == '\n') end = e + 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (comma_before) |c| {
        try out.appendSlice(gpa, src[0..c]);
        try out.appendSlice(gpa, src[c + 1 .. start]);
    } else {
        try out.appendSlice(gpa, src[0..start]);
    }
    try out.appendSlice(gpa, src[end..]);
    return try out.toOwnedSlice(gpa);
}

// ── Where the file is ──────────────────────────────────────────────────────

/// A VS Code build: the name of its user-data folder and the one to show.
pub const Product = struct {
    /// `product.json` `nameShort`, which names the user-data folder: "Code",
    /// "Code - Insiders", "Cursor", "Windsurf", "VSCodium", …
    data_folder: []const u8,
    /// `product.json` `nameLong`: "Visual Studio Code", "Cursor", …
    display: []const u8,
};

pub const vscode: Product = .{ .data_folder = "Code", .display = "Visual Studio Code" };
pub const vscode_insiders: Product = .{ .data_folder = "Code - Insiders", .display = "Visual Studio Code - Insiders" };
pub const cursor: Product = .{ .data_folder = "Cursor", .display = "Cursor" };
pub const windsurf: Product = .{ .data_folder = "Windsurf", .display = "Windsurf" };
pub const vscodium: Product = .{ .data_folder = "VSCodium", .display = "VSCodium" };

/// The build running this terminal: its install's `product.json`, found
/// through the git extension's askpass script the integrated terminal points
/// at (`VSCODE_GIT_ASKPASS_MAIN`); else the hints the forks leave.
pub fn product(arena: std.mem.Allocator, env: setup.Env) Product {
    if (env.vscode_askpass_main) |askpass| if (fromInstall(arena, askpass)) |p| return p;
    if (env.cursor_trace_id) return cursor;
    if (env.bundle_id) |id| {
        if (containsIgnoreCase(id, "VSCodeInsiders")) return vscode_insiders;
        if (containsIgnoreCase(id, "windsurf")) return windsurf;
        if (containsIgnoreCase(id, "vscodium")) return vscodium;
        if (containsIgnoreCase(id, "todesktop")) return cursor; // Cursor's bundle id
    }
    if (env.term_program_version) |v| if (std.mem.endsWith(u8, v, "-insider")) return vscode_insiders;
    return vscode;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// The app root of an install, from `<root>/extensions/git/dist/askpass-main.js`.
fn appRoot(askpass: []const u8) ?[]const u8 {
    inline for (.{ "/", "\\" }) |sep| {
        const marker = sep ++ "extensions" ++ sep ++ "git" ++ sep;
        if (std.mem.lastIndexOf(u8, askpass, marker)) |at| return askpass[0..at];
    }
    return null;
}

/// A user-data folder name that stays one path component.
fn plainFolderName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\:\x00") == null;
}

fn fromInstall(arena: std.mem.Allocator, askpass: []const u8) ?Product {
    const root = appRoot(askpass) orelse return null;
    const path = std.fs.path.join(arena, &.{ root, "product.json" }) catch return null;
    const bytes = files.read(arena, path) catch return null;
    const Names = struct { nameShort: ?[]const u8 = null, nameLong: ?[]const u8 = null };
    const names = std.json.parseFromSliceLeaky(Names, arena, bytes, .{ .ignore_unknown_fields = true, .duplicate_field_behavior = .use_last }) catch return null;
    const short = names.nameShort orelse return null;
    if (!plainFolderName(short)) return null;
    return .{ .data_folder = short, .display = names.nameLong orelse short };
}

/// The window runs on another machine (Remote-SSH, WSL, a dev container,
/// Codespaces): its keybindings live on the machine that shows the window.
/// The server installs that serve such windows sit in hidden `.<build>-server`
/// directories (`~/.vscode-server`, `~/.vscode-server-insiders`,
/// `~/.cursor-server`, …) or, in containers, `vscode-server`; local installs
/// never do.
pub fn isRemote(env: setup.Env) bool {
    if (env.remote_session) return true;
    for ([_]?[]const u8{ env.vscode_askpass_main, env.path }) |maybe| {
        const value = maybe orelse continue;
        var it = std.mem.tokenizeAny(u8, value, "/\\:;");
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "vscode-server")) return true;
            if (part.len > 1 and part[0] == '.' and std.mem.indexOf(u8, part, "-server") != null) return true;
        }
    }
    return false;
}

/// `<user data>/User/keybindings.json` for `p` (owned by `arena`), as VS Code
/// resolves its user-data directory: `VSCODE_PORTABLE`, `VSCODE_APPDATA`, then
/// the platform's application-data directory. null without a home directory.
pub fn keybindingsPath(arena: std.mem.Allocator, env: setup.Env, p: Product) error{OutOfMemory}!?[]const u8 {
    if (env.vscode_portable) |dir| return try std.fs.path.join(arena, &.{ dir, "user-data", "User", "keybindings.json" });
    if (env.vscode_appdata) |dir| return try std.fs.path.join(arena, &.{ dir, p.data_folder, "User", "keybindings.json" });
    const home = env.home orelse return null;
    return switch (env.os) {
        .macos => try std.fs.path.join(arena, &.{ home, "Library", "Application Support", p.data_folder, "User", "keybindings.json" }),
        .windows => if (env.appdata) |appdata|
            try std.fs.path.join(arena, &.{ appdata, p.data_folder, "User", "keybindings.json" })
        else
            try std.fs.path.join(arena, &.{ home, "AppData", "Roaming", p.data_folder, "User", "keybindings.json" }),
        .other => if (env.xdg_config_home) |config|
            try std.fs.path.join(arena, &.{ config, p.data_folder, "User", "keybindings.json" })
        else
            try std.fs.path.join(arena, &.{ home, ".config", p.data_folder, "User", "keybindings.json" }),
    };
}

/// A VS Code profile with keyboard shortcuts of its own: a window that uses it
/// reads that profile's `keybindings.json`, not the Default profile's
/// (measured on VS Code 1.105: a window opened with `--profile` kept sending a
/// plain Return with the binding in the Default profile's file).
pub const Profile = struct {
    name: []const u8,
    /// null when the profile lives somewhere this cannot place.
    keybindings: ?[]const u8,
};

pub const Profiles = union(enum) {
    /// Possibly none.
    known: []const Profile,
    /// `storage.json` is there but does not read as VS Code's: which profiles
    /// have their own shortcuts is not known.
    unknown,
};

/// The profiles with their own shortcuts, from `<User>/globalStorage/storage.json`
/// (`userDataProfiles: [{location, name, useDefaultFlags?}]`; the profile's
/// files are in `<User>/profiles/<location>/`). One whose
/// `useDefaultFlags.keybindings` is true reads the Default profile's file and is
/// left out, as VS Code resolves `keybindingsResource`.
pub fn ownShortcutProfiles(arena: std.mem.Allocator, user_dir: []const u8) error{OutOfMemory}!Profiles {
    const path = try std.fs.path.join(arena, &.{ user_dir, "globalStorage", "storage.json" });
    const bytes = files.read(arena, path) catch |err| switch (err) {
        error.NotFound => return .{ .known = &.{} },
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unknown,
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .use_last }) catch return .unknown;
    if (root != .object) return .unknown;
    const list = root.object.get("userDataProfiles") orelse return .{ .known = &.{} };
    if (list != .array) return .unknown;
    var out: std.ArrayList(Profile) = .empty;
    for (list.array.items) |item| {
        if (item != .object) return .unknown;
        if (item.object.get("useDefaultFlags")) |flags| if (flags == .object) if (flags.object.get("keybindings")) |shared| {
            if (shared == .bool and shared.bool) continue;
        };
        const name = stringField(item.object, "name") orelse "(unnamed)";
        const location = stringField(item.object, "location");
        const keybindings: ?[]const u8 = if (location) |loc|
            (if (plainFolderName(loc)) try std.fs.path.join(arena, &.{ user_dir, "profiles", loc, "keybindings.json" }) else null)
        else
            null;
        try out.append(arena, .{ .name = name, .keybindings = keybindings });
    }
    return .{ .known = out.items };
}

/// The binding as a user would paste it into `keybindings.json` by hand.
pub const manual_snippet =
    \\{
    \\    "key": "shift+enter",
    \\    "command": "workbench.action.terminal.sendSequence",
    \\    "args": { "text": "\u001b\r" },
    \\    "when": "terminalFocus"
    \\}
;

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// VS Code's own template for a new `keybindings.json`.
const template = "// Place your key bindings in this file to override the defaults\n[\n]";

test "classify: no file, the template, ours (also Claude Code's), and the claims that conflict" {
    const gpa = testing.allocator;
    try testing.expectEqual(Status.absent, try classify(gpa, null));
    try testing.expectEqual(Status.absent, try classify(gpa, ""));
    try testing.expectEqual(Status.absent, try classify(gpa, template));
    // Shift+Enter elsewhere (the editor) or under a negated terminal condition.
    try testing.expectEqual(Status.absent, try classify(gpa,
        \\[{ "key": "shift+enter", "command": "editor.action.insertLineAfter", "when": "editorTextFocus && !terminalFocus" },
        \\ { "key": "ctrl+k shift+enter", "command": "x", "when": "terminalFocus" },
        \\ { "key": "shift+enter", "command": "-workbench.action.terminal.sendSequence", "when": "terminalFocus" }]
    ));
    // Claude Code writes exactly this; VS Code also takes `-` and any case.
    try testing.expectEqual(Status.installed, try classify(gpa,
        \\[ // claude code
        \\  { "key": "Shift-Enter", "command": "workbench.action.terminal.sendSequence", "args": { "text": "\u001b\r" }, "when": "terminalFocus" },
        \\]
    ));
    // `enter+shift` is no key to VS Code (modifiers come first): not a binding of Shift+Enter.
    try testing.expectEqual(Status.absent, try classify(gpa,
        \\[{ "key": "enter+shift", "command": "workbench.action.terminal.sendSequence", "args": { "text": "\u001b\r" }, "when": "terminalFocus" }]
    ));
    const other =
        \\[
        \\  { "key": "shift+enter", "command": "workbench.action.terminal.sendSequence", "args": { "text": "\u001b\r" }, "when": "terminalFocus" },
        \\  { "key": "shift+enter", "command": "workbench.action.terminal.sendSequence", "args": { "text": "\n" }, "when": "terminalFocus && terminalProcessSupported" }
        \\]
    ;
    // The later claim wins in VS Code, so it is the one reported.
    const st = try classify(gpa, other);
    try testing.expect(st == .conflict);
    try testing.expect(std.mem.indexOf(u8, st.conflict, "\"text\": \"\\n\"") != null);
    // A binding with no condition applies in the terminal too.
    try testing.expect(try classify(gpa, "[{\"key\":\"shift+enter\",\"command\":\"editor.action.insertLineAfter\"}]") == .conflict);
    try testing.expectError(error.NotAnArray, classify(gpa, "{}"));
    try testing.expectError(error.InvalidJsonc, classify(gpa, "[{]"));
}

test "isShiftEnter follows VS Code's keybinding parser" {
    for ([_][]const u8{ "shift+enter", "Shift-Enter", "  SHIFT+ENTER ", "shift+[Enter]", "shift-shift+enter" }) |k| {
        try testing.expect(isShiftEnter(k));
    }
    for ([_][]const u8{ "enter+shift", "enter", "ctrl+shift+enter", "shift+alt+enter", "cmd+shift+enter", "shift+enter shift+enter", "ctrl+k shift+enter", "shift+return", "shift", "shift+" }) |k| {
        try testing.expect(!isShiftEnter(k));
    }
}

fn expectAdded(src: ?[]const u8, want: []const u8) !void {
    const got = try withBinding(testing.allocator, src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(Status.installed, try classify(testing.allocator, got));
}

fn expectRoundTrip(src: []const u8) !void {
    const added = try withBinding(testing.allocator, src);
    defer testing.allocator.free(added);
    const back = (try withoutBinding(testing.allocator, added)).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(src, back);
}

test "withBinding: no file, the template, comments and trailing commas, CRLF, one-line arrays" {
    const ours_4 =
        \\    {
        \\        "key": "shift+enter",
        \\        "command": "workbench.action.terminal.sendSequence",
        \\        "args": { "text": "\u001b\r" },
        \\        "when": "terminalFocus"
        \\    }
    ;
    try expectAdded(null, "[\n" ++ ours_4 ++ "\n]\n");
    try expectAdded(template, "// Place your key bindings in this file to override the defaults\n[\n" ++ ours_4 ++ "\n]");
    // A comment after the last entry stays with it; the trailing-comma style is kept.
    try expectAdded(
        \\// mine
        \\[
        \\    { "key": "ctrl+a", "command": "a" }, // the a key
        \\    /* keep */
        \\]
    ,
        \\// mine
        \\[
        \\    { "key": "ctrl+a", "command": "a" }, // the a key
        \\    /* keep */
        \\
    ++ ours_4 ++ ",\n]");
    // No trailing comma: a separator goes after the last entry, before its comment.
    try expectAdded("[\n\t{ \"key\": \"ctrl+a\", \"command\": \"a\" } // a\n]\n", "[\n\t{ \"key\": \"ctrl+a\", \"command\": \"a\" }, // a\n" ++
        "\t{\n\t\t\"key\": \"shift+enter\",\n\t\t\"command\": \"workbench.action.terminal.sendSequence\",\n\t\t\"args\": { \"text\": \"\\u001b\\r\" },\n\t\t\"when\": \"terminalFocus\"\n\t}\n]\n");
    // CRLF files get CRLF.
    const crlf = try withBinding(testing.allocator, "[\r\n]\r\n");
    defer testing.allocator.free(crlf);
    try testing.expect(std.mem.indexOf(u8, crlf, "\r\n    {\r\n        \"key\"") != null);
    for (crlf, 0..) |c, i| if (c == '\n') try testing.expect(i > 0 and crlf[i - 1] == '\r');
    // `]` sharing a line with an entry, and an empty one-line array.
    try expectAdded("[{\"key\":\"a\",\"command\":\"a\"}]", "[{\"key\":\"a\",\"command\":\"a\"},\n" ++ ours_4 ++ "\n]");
    try expectAdded("[]", "[\n" ++ ours_4 ++ "\n]");
}

test "withoutBinding: gives the file back as it was before withBinding" {
    try expectRoundTrip(template);
    try expectRoundTrip("[\n]\n");
    try expectRoundTrip("// mine\n[\n    { \"key\": \"ctrl+a\", \"command\": \"a\" }, // a\n    /* keep */\n]");
    try expectRoundTrip("[\n\t{ \"key\": \"ctrl+a\", \"command\": \"a\" } // a\n]\n");
    try expectRoundTrip("[\r\n  {\"key\":\"ctrl+a\",\"command\":\"a\"}\r\n]\r\n");
    // Only the exact entry it writes: a user's variant of it stays.
    try testing.expect(try withoutBinding(testing.allocator, "[{\"key\":\"shift+enter\",\"command\":\"workbench.action.terminal.sendSequence\",\"args\":{\"text\":\"\\u001b\\r\"},\"when\":\"terminalFocus && x\"}]") == null);
    try testing.expect(try withoutBinding(testing.allocator, template) == null);
    // An entry in the middle takes its own comma with it.
    const middle =
        \\[
        \\  { "key": "ctrl+a", "command": "a" },
        \\  { "key": "shift+enter", "command": "workbench.action.terminal.sendSequence", "args": { "text": "\u001b\r" }, "when": "terminalFocus" },
        \\  { "key": "ctrl+b", "command": "b" }
        \\]
    ;
    const out = (try withoutBinding(testing.allocator, middle)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[\n  { \"key\": \"ctrl+a\", \"command\": \"a\" },\n  { \"key\": \"ctrl+b\", \"command\": \"b\" }\n]", out);
}

test "product and keybindingsPath: product.json beside the askpass script, fork hints, portable and per-OS folders" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    try tmp.dir.createDirPath(testing.io, "app/extensions/git/dist");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app/product.json", .data = "{\"nameShort\":\"Qoder\",\"nameLong\":\"Qoder IDE\",\"other\":1}" });
    const askpass = try std.fs.path.join(arena, &.{ root, "app", "extensions", "git", "dist", "askpass-main.js" });

    try testing.expectEqualStrings("Qoder", product(arena, .{ .vscode_askpass_main = askpass }).data_folder);
    try testing.expectEqualStrings("Qoder IDE", product(arena, .{ .vscode_askpass_main = askpass }).display);
    // A product.json that would leave the folder is not trusted.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app/product.json", .data = "{\"nameShort\":\"../x\"}" });
    try testing.expectEqualStrings("Code", product(arena, .{ .vscode_askpass_main = askpass }).data_folder);
    try testing.expectEqualStrings("Cursor", product(arena, .{ .cursor_trace_id = true }).data_folder);
    try testing.expectEqualStrings("Code - Insiders", product(arena, .{ .term_program_version = "1.106.0-insider" }).data_folder);
    try testing.expectEqualStrings("Windsurf", product(arena, .{ .bundle_id = "com.exafunction.windsurf" }).data_folder);

    const sep = std.fs.path.sep_str;
    const mac = (try keybindingsPath(arena, .{ .os = .macos, .home = "/Users/a" }, vscode)).?;
    try testing.expect(std.mem.endsWith(u8, mac, "Library" ++ sep ++ "Application Support" ++ sep ++ "Code" ++ sep ++ "User" ++ sep ++ "keybindings.json"));
    const win = (try keybindingsPath(arena, .{ .os = .windows, .home = "C:\\Users\\a", .appdata = "C:\\Users\\a\\AppData\\Roaming" }, cursor)).?;
    try testing.expect(std.mem.endsWith(u8, win, "Roaming" ++ sep ++ "Cursor" ++ sep ++ "User" ++ sep ++ "keybindings.json"));
    const linux = (try keybindingsPath(arena, .{ .os = .other, .home = "/home/a" }, vscode)).?;
    try testing.expect(std.mem.endsWith(u8, linux, ".config" ++ sep ++ "Code" ++ sep ++ "User" ++ sep ++ "keybindings.json"));
    const portable = (try keybindingsPath(arena, .{ .os = .other, .home = "/home/a", .vscode_portable = "/opt/code/data" }, vscode)).?;
    try testing.expect(std.mem.endsWith(u8, portable, "data" ++ sep ++ "user-data" ++ sep ++ "User" ++ sep ++ "keybindings.json"));
    try testing.expect((try keybindingsPath(arena, .{ .os = .other }, vscode)) == null);
}

test "ownShortcutProfiles: VS Code's storage.json, shared and own shortcuts, nothing and garbage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const user = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    // No storage.json, or no profiles in it: none.
    try testing.expectEqual(@as(usize, 0), (try ownShortcutProfiles(arena, user)).known.len);
    try tmp.dir.createDirPath(testing.io, "globalStorage");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "globalStorage/storage.json", .data = "{\"theme\":\"vs-dark\"}" });
    try testing.expectEqual(@as(usize, 0), (try ownShortcutProfiles(arena, user)).known.len);
    // As VS Code 1.105 wrote it for `--profile tsprobe`, plus one sharing the Default's shortcuts.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "globalStorage/storage.json", .data =
        \\{"userDataProfiles":[{"location":"1d77a59e","name":"tsprobe"},
        \\  {"location":"5c2e","name":"shared","useDefaultFlags":{"keybindings":true,"settings":false}},
        \\  {"location":"../x","name":"odd"}]}
    });
    const known = (try ownShortcutProfiles(arena, user)).known;
    try testing.expectEqual(@as(usize, 2), known.len);
    try testing.expectEqualStrings("tsprobe", known[0].name);
    const sep = std.fs.path.sep_str;
    try testing.expect(std.mem.endsWith(u8, known[0].keybindings.?, "profiles" ++ sep ++ "1d77a59e" ++ sep ++ "keybindings.json"));
    try testing.expectEqualStrings("odd", known[1].name);
    try testing.expect(known[1].keybindings == null);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "globalStorage/storage.json", .data = "{not json" });
    try testing.expect(try ownShortcutProfiles(arena, user) == .unknown);
}

test "isRemote: server installs and remote-session variables" {
    try testing.expect(!isRemote(.{ .vscode_askpass_main = "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/git/dist/askpass-main.js" }));
    try testing.expect(!isRemote(.{ .vscode_askpass_main = "D:\\bin\\vscode\\resources\\app\\extensions\\git\\dist\\askpass-main.js", .path = "C:\\Windows;D:\\bin\\vscode\\bin" }));
    try testing.expect(isRemote(.{ .vscode_askpass_main = "/home/a/.vscode-server/bin/abc/extensions/git/dist/askpass-main.js" }));
    try testing.expect(isRemote(.{ .path = "/home/a/.cursor-server/bin/abc/bin/remote-cli:/usr/bin" }));
    try testing.expect(isRemote(.{ .path = "/home/a/.vscode-server-insiders/bin/abc/bin/remote-cli:/usr/bin" }));
    try testing.expect(isRemote(.{ .vscode_askpass_main = "/vscode/vscode-server/bin/linux-x64/abc/extensions/git/dist/askpass-main.js" }));
    try testing.expect(isRemote(.{ .remote_session = true }));
    // An ordinary directory named like a server is not a remote window.
    try testing.expect(!isRemote(.{ .path = "/opt/mysql-server/bin:/usr/local/minio-server:/usr/bin" }));
}
