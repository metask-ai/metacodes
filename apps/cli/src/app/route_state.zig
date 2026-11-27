//! What a session's model route rests on (#484): a credential from a place
//! the banner names, or none yet.
//!
//! A session with no usable model is **unbound**: the TUI opens, slash
//! commands work, and nothing is sent. It is its own state, not an empty key:
//! an empty key would let a turn assemble a request and fail on the
//! credential (or, before #336, on the provider's 401), and the user would
//! read a transport error instead of what to do. An unbound App builds no
//! request at all: the REPL refuses a submission before the conversation sees
//! it, and App.init neither probes `/v1/models` nor opens a session directory
//! (`App.route_state`). Choosing a route that has a credential (`/model`) or
//! signing in binds it.
//!
//! The words a user reads in that state live here: the banner's model line
//! and the red reminder a refused submission prints. Both are plain text; the
//! REPL colours them.

const std = @import("std");
const credential = @import("metacodes-internal").provider.credential;
const profile_mod = @import("metacodes-internal").provider.profile;
const ids = @import("metacodes-internal").provider.ids;

/// Where the credential of the route a session runs on came from: who bills
/// the session (第十节第 2 条 of the login/logout design, #484). The banner
/// says it after the model: `deepseek-v4-pro · from .env`, `glm-5 · Metask`.
pub const CredentialOrigin = enum {
    /// The host did not say (an embedder, a test, a route picked in a way
    /// that cannot tell): the banner names none.
    unknown,
    /// A Metask sign-in or key: `auth.json`, `METASK_API_KEY`, the Metask
    /// device-code session. Metask bills the session.
    metask,
    /// `<state root>/.env` (#486).
    local_config,
    /// The process environment: a variable exported in the shell.
    environment,
    /// A key stored by `/login <provider>` or `login --provider` in
    /// `<state root>/keys/<provider>.json`.
    saved_key,
    /// A provider's own OAuth sign-in (`<state root>/oauth/<provider>.json`).
    sign_in,
    /// `--api-key`, or a key handed over a runtime descriptor.
    flag,

    /// The banner's words for it, or null when it names none.
    pub fn label(self: CredentialOrigin) ?[]const u8 {
        return switch (self) {
            .unknown => null,
            .metask => "Metask",
            .local_config => "from .env",
            .environment => "from shell",
            .saved_key => "saved key",
            .sign_in => "signed in",
            .flag => "--api-key",
        };
    }
};

/// Why a session has no model. Each says, in the reminder, what is missing.
pub const Unbound = union(enum) {
    /// No flag or environment variable names a provider, no default is
    /// stored, there is no Metask sign-in, and `.env` configures none.
    nothing_configured,
    /// `auth.json` holds a Metask sign-in whose key, model and reasoning
    /// effort were never chosen ("Metask login is incomplete").
    metask_login_incomplete,
    /// The provider the user named (`--provider`, `--offer`,
    /// `METACODES_PROVIDER`, or `.env`'s) has no credential (#485, 第十节第
    /// 3 条): the session stays on nothing rather than quietly using another.
    missing_credential: ids.Slug,
    /// `/logout` (#485) left nothing to fall back to: no `.env` provider.
    signed_out,
    directory_unchosen: DirectoryUnchosen,
};

pub const DirectoryUnchosen = struct {
    directory: []const u8 = "",
    config_path: []const u8 = "",
    presets: []const []const u8 = &.{},
    unreadable: ?[]const u8 = null,
};

pub const RouteState = union(enum) {
    /// Requests go out; the credential came from here.
    bound: CredentialOrigin,
    /// Nothing is sent (see the file comment).
    unbound: Unbound,
};

/// The banner's model line in the unbound state.
pub const not_set_line = "not set — /login, or configure .env";

/// The banner's model line: `not set — …`, `<model> · <origin>`, or the model
/// alone when the origin names nothing. Borrows `model`; may write `buffer`.
pub fn modelLine(buffer: []u8, state: RouteState, model: []const u8) []const u8 {
    return switch (state) {
        .unbound => not_set_line,
        .bound => |origin| {
            const label = origin.label() orelse return model;
            return std.fmt.bufPrint(buffer, "{s} · {s}", .{ model, label }) catch model;
        },
    };
}

/// The provider a `missing_credential` reminder is about, in words.
pub const MissingProvider = struct {
    display_name: []const u8,
    /// The variables its key is read from (canonical first); may be empty
    /// for a provider that signs in instead.
    variables: []const []const u8 = &.{},
    /// `/login <id>` stores a credential for it (a key page or a sign-in).
    login_id: ?[]const u8 = null,
    /// Metask: what it lacks is a sign-in, the device-code one `/login
    /// metask` makes.
    metask: bool = false,
};

/// What the unbound reminder says, beyond the reason.
pub const Reminder = struct {
    reason: Unbound,
    /// Set for `missing_credential`: the provider, by name.
    missing: ?MissingProvider = null,
    /// This install's `<state root>/.env`; "" when it has no state root.
    env_path: []const u8,
    /// Whether `.env.example` sits beside it (an install wrote it).
    template: bool,
    /// The how-to page for `.env`.
    guide_url: []const u8,
    /// Provider key variables the process environment sets, by name. They
    /// are never used on their own (#484 item 6); the reminder points to
    /// `/model`, where choosing one is the explicit choice.
    environment_keys: []const []const u8 = &.{},
    /// Providers `.env` holds keys for while naming none of them (#486), by
    /// display name: the file does not choose, so the reminder points to
    /// `/model`, where choosing one is the choice.
    unchosen_local: []const []const u8 = &.{},
    command: []const u8 = "metacodes",
};

/// The red reminder a submission in the unbound state gets, one line per
/// `\n`, in words (the colour is only emphasis). Never a value: names only.
///
///     No model is set up.
///       Sign in to Metask:            /login
///       Or use your own provider key: edit <state root>/.env (template: .env.example), then restart
///       How to: https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md
pub fn writeReminder(w: *std.Io.Writer, r: Reminder) std.Io.Writer.Error!void {
    switch (r.reason) {
        .nothing_configured => try w.writeAll("No model is set up.\n"),
        .metask_login_incomplete => try w.writeAll("No model is set up: the Metask sign-in has no API key and model chosen yet.\n"),
        .signed_out => try w.writeAll("No model is set up: you signed out of Metask.\n"),
        .missing_credential => return writeMissingReminder(w, r),
        .directory_unchosen => |unchosen| return writeDirectoryReminder(w, r, unchosen),
    }
    try w.writeAll("  Sign in to Metask:            /login\n");
    if (r.unchosen_local.len > 0 and r.env_path.len > 0) {
        // The keys are in `.env` already: what is left is choosing one.
        try w.writeAll("  Or use a key in .env:         /model (");
        try writeList(w, r.unchosen_local);
        try w.writeAll(")\n");
    } else if (r.env_path.len > 0) {
        try w.print("  Or use your own provider key: edit {s}{s}, then restart\n", .{
            r.env_path,
            if (r.template) " (template: .env.example)" else "",
        });
    }
    // A key only in the shell is never used on its own: choosing its
    // provider in /model is what makes it the session's.
    if (r.environment_keys.len > 0) {
        try w.writeAll("  Or use a key in your shell:   /model (");
        try writeList(w, r.environment_keys);
        try w.writeAll(")\n");
    }
    try w.print("  How to: {s}\n", .{r.guide_url});
}

pub fn writeFirstStart(w: *std.Io.Writer, env_path: []const u8, guide_url: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("To start: /login signs in to Metask");
    if (env_path.len > 0) try w.print(", or put your own provider key in {s} and restart", .{env_path});
    try w.print(".\nHow to: {s}\n", .{guide_url});
}

/// The provider the user named has no credential: say which, and where its
/// key goes, rather than offering another provider first.
///
///     No model is set up: DeepSeek has no key.
///       Put DEEPSEEK_API_KEY in your shell, or in <state root>/.env, then restart
///       Or store a key for it:        /login deepseek
///       Or choose another model:      /model
///       How to: https://…/doc/LOCAL_CONFIG.md
fn writeMissingReminder(w: *std.Io.Writer, r: Reminder) std.Io.Writer.Error!void {
    const missing = r.missing orelse MissingProvider{ .display_name = "The provider you named" };
    if (missing.metask or missing.variables.len == 0) {
        try w.print("No model is set up: {s} has no sign-in.\n", .{missing.display_name});
        // A named Metask route reads the device-code sign-in, which `/login
        // metask` makes; the browser sign-in `/login` makes does not serve it.
        if (missing.metask) try w.writeAll("  Sign in to Metask:            /login metask\n");
    } else {
        try w.print("No model is set up: {s} has no key.\n", .{missing.display_name});
        try w.writeAll("  Put ");
        for (missing.variables, 0..) |name, index| {
            if (index > 0) try w.writeAll(" or ");
            try w.writeAll(name);
        }
        if (r.env_path.len > 0) {
            try w.print(" in your shell, or in {s}{s}, then restart\n", .{ r.env_path, if (r.template) " (template: .env.example)" else "" });
        } else {
            try w.writeAll(" in your shell, then restart\n");
        }
    }
    if (missing.login_id) |id| try w.print("  Or store a key for it:        /login {s}\n", .{id});
    try w.writeAll("  Or choose another model:      /model\n");
    try w.print("  How to: {s}\n", .{r.guide_url});
}

fn writeDirectoryReminder(w: *std.Io.Writer, r: Reminder, unchosen: DirectoryUnchosen) std.Io.Writer.Error!void {
    const config_path = if (unchosen.config_path.len > 0) unchosen.config_path else "config.json";
    if (unchosen.unreadable) |why| {
        try w.print("No model is chosen for this directory: {s} cannot be read ({s}), so no preset can be looked up, and global_default is off.\n", .{ config_path, why });
        try w.writeAll("  Choose one for this session:  /model\n");
        try w.print("  How to: {s}\n", .{r.guide_url});
        return;
    }
    try w.writeAll("No model is chosen for this directory: it remembers no preset, and global_default is off.\n");
    try w.writeAll("  Choose one for this session:  /model\n");
    try w.print("  Or start with a preset:       {s} --preset <name>", .{r.command});
    if (unchosen.presets.len > 0) {
        try w.writeAll(" (presets: ");
        try writeList(w, unchosen.presets);
        try w.writeAll(")");
    }
    try w.writeAll("\n");
    if (unchosen.directory.len > 0) {
        try w.writeAll("  Or remember one here:         ");
        try std.json.Stringify.encodeJsonString(unchosen.directory, .{}, w);
        try w.print(": \"<name>\" under directory_presets in {s}\n", .{config_path});
    }
    try w.print("  How to: {s}\n", .{r.guide_url});
}

fn writeList(w: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    for (items, 0..) |item, index| {
        if (index > 0) try w.writeAll(", ");
        try w.writeAll(item);
    }
}

/// Said once under the banner when `.env` holds keys of several providers
/// and names none (#486), so the TUI opened without a model: which ones, by
/// display name, and where choosing one is done. Tab in `/model` is what
/// makes the choice the default of later starts (level 4 of the startup
/// order), which no longer stop here.
///
///     .env has keys for DeepSeek and OpenAI. Choose one with /model; Tab there applies it to every future session.
pub fn writeUnchosenLocalNotice(w: *std.Io.Writer, providers: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll(".env has keys for ");
    for (providers, 0..) |name, index| {
        if (index > 0) try w.writeAll(if (index + 1 == providers.len) " and " else ", ");
        try w.writeAll(name);
    }
    try w.writeAll(". Choose one with /model; Tab there applies it to every future session.");
}

/// The provider key variables `env` sets among `profiles`' declared aliases,
/// by name, each once, in profile order. Metask's are left out: a Metask key
/// in the environment is a sign-in and binds the session (level 5), so it is
/// never one the reminder has to point out. The names live in `arena`.
pub fn environmentKeys(
    arena: std.mem.Allocator,
    profiles: []const profile_mod.ProviderProfile,
    env: credential.EnvLookup,
) error{OutOfMemory}![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (profiles) |*profile| {
        if (profile.id.eqlText("metask")) continue;
        for (profile.env_aliases) |alias| {
            if (env.get(alias.name) == null) continue;
            const seen = for (names.items) |name| {
                if (std.mem.eql(u8, name, alias.name)) break true;
            } else false;
            if (!seen) try names.append(arena, try arena.dupe(u8, alias.name));
        }
    }
    return names.items;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn reminderText(r: Reminder) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try writeReminder(&out.writer, r);
    return out.toOwnedSlice();
}

test "a first start names the sign-in, this install's .env and the guide" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeFirstStart(&w, "/home/u/.local/opt/metacodes/state/.env", "https://example.test/guide");
    try testing.expectEqualStrings(
        "To start: /login signs in to Metask, or put your own provider key in /home/u/.local/opt/metacodes/state/.env and restart.\nHow to: https://example.test/guide\n",
        w.buffered(),
    );
}

test "the banner names the origin after the model, and says not set when unbound" {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("not set — /login, or configure .env", modelLine(&buffer, .{ .unbound = .nothing_configured }, "claude-sonnet-4-20250514"));
    try testing.expectEqualStrings("not set — /login, or configure .env", modelLine(&buffer, .{ .unbound = .metask_login_incomplete }, "x"));
    try testing.expectEqualStrings("deepseek-v4-pro · from .env", modelLine(&buffer, .{ .bound = .local_config }, "deepseek-v4-pro"));
    try testing.expectEqualStrings("glm-5 · Metask", modelLine(&buffer, .{ .bound = .metask }, "glm-5"));
    try testing.expectEqualStrings("gpt-5 · from shell", modelLine(&buffer, .{ .bound = .environment }, "gpt-5"));
    try testing.expectEqualStrings("kimi-k3", modelLine(&buffer, .{ .bound = .unknown }, "kimi-k3"));
    // A line that does not fit keeps the model rather than a cut label.
    var small: [8]u8 = undefined;
    try testing.expectEqualStrings("deepseek-v4-pro", modelLine(&small, .{ .bound = .local_config }, "deepseek-v4-pro"));
}

test "the reminder names this install's .env, the template only when it is there, and the guide" {
    const path = "/home/u/.local/opt/metacodes/state/.env";
    const guide = "https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md";
    const with_template = try reminderText(.{ .reason = .nothing_configured, .env_path = path, .template = true, .guide_url = guide });
    defer testing.allocator.free(with_template);
    try testing.expectEqualStrings(
        \\No model is set up.
        \\  Sign in to Metask:            /login
        \\  Or use your own provider key: edit /home/u/.local/opt/metacodes/state/.env (template: .env.example), then restart
        \\  How to: https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md
        \\
    , with_template);

    const without = try reminderText(.{ .reason = .nothing_configured, .env_path = path, .template = false, .guide_url = guide });
    defer testing.allocator.free(without);
    try testing.expect(std.mem.indexOf(u8, without, "edit /home/u/.local/opt/metacodes/state/.env, then restart\n") != null);
    try testing.expect(std.mem.indexOf(u8, without, "template") == null);
}

test "the reminder lists shell keys and unchosen .env providers by name, and says why it is unbound" {
    const text = try reminderText(.{
        .reason = .metask_login_incomplete,
        .env_path = "/s/.env",
        .template = false,
        .guide_url = "https://guide",
        .environment_keys = &.{ "DEEPSEEK_API_KEY", "KIMI_API_KEY" },
        .unchosen_local = &.{ "DeepSeek", "OpenAI" },
    });
    defer testing.allocator.free(text);
    // The file's keys are there already: the way on is choosing one in
    // /model, not editing the file and restarting.
    try testing.expectEqualStrings(
        \\No model is set up: the Metask sign-in has no API key and model chosen yet.
        \\  Sign in to Metask:            /login
        \\  Or use a key in .env:         /model (DeepSeek, OpenAI)
        \\  Or use a key in your shell:   /model (DEEPSEEK_API_KEY, KIMI_API_KEY)
        \\  How to: https://guide
        \\
    , text);
}

test "the banner notice for .env keys of several providers names them and where to choose" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeUnchosenLocalNotice(&w, &.{ "DeepSeek", "OpenAI" });
    try testing.expectEqualStrings(".env has keys for DeepSeek and OpenAI. Choose one with /model; Tab there applies it to every future session.", w.buffered());
    w = .fixed(&buffer);
    try writeUnchosenLocalNotice(&w, &.{ "DeepSeek", "OpenAI", "Moonshot Kimi" });
    try testing.expect(std.mem.startsWith(u8, w.buffered(), ".env has keys for DeepSeek, OpenAI and Moonshot Kimi. "));
}

test "the reminder for a named provider without a key names its variables, not another provider" {
    const text = try reminderText(.{
        .reason = .{ .missing_credential = ids.Slug.lit("deepseek") },
        .missing = .{ .display_name = "DeepSeek", .variables = &.{"DEEPSEEK_API_KEY"}, .login_id = "deepseek" },
        .env_path = "/s/.env",
        .template = true,
        .guide_url = "https://guide",
    });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\No model is set up: DeepSeek has no key.
        \\  Put DEEPSEEK_API_KEY in your shell, or in /s/.env (template: .env.example), then restart
        \\  Or store a key for it:        /login deepseek
        \\  Or choose another model:      /model
        \\  How to: https://guide
        \\
    , text);
    // Signed out: the usual ways in, with the reason.
    const out = try reminderText(.{ .reason = .signed_out, .env_path = "/s/.env", .template = false, .guide_url = "https://guide" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "No model is set up: you signed out of Metask.\n  Sign in to Metask:            /login\n"));
}

test "the reminder for a named Metask without a sign-in points at the device-code sign-in" {
    const text = try reminderText(.{
        .reason = .{ .missing_credential = ids.Slug.lit("metask") },
        .missing = .{ .display_name = "Metask", .metask = true },
        .env_path = "/s/.env",
        .template = false,
        .guide_url = "https://guide",
    });
    defer testing.allocator.free(text);
    // `--provider metask` reads the device-code session: the browser
    // sign-in plain `/login` makes would not serve it.
    try testing.expectEqualStrings(
        \\No model is set up: Metask has no sign-in.
        \\  Sign in to Metask:            /login metask
        \\  Or choose another model:      /model
        \\  How to: https://guide
        \\
    , text);
}

test "the reminder without a state root has no .env line" {
    const text = try reminderText(.{ .reason = .nothing_configured, .env_path = "", .template = true, .guide_url = "https://guide", .unchosen_local = &.{"deepseek"} });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".env") == null);
    try testing.expect(std.mem.indexOf(u8, text, "/login") != null);
}

test "environment keys: declared aliases the environment sets, once each, Metask's left out" {
    const Env = struct {
        var anchor: u8 = 0;
        fn get(_: *anyopaque, name: []const u8) ?[]const u8 {
            for ([_][]const u8{ "DEEPSEEK_API_KEY", "METASK_API_KEY", "ZAI_API_KEY", "GLM_API_KEY" }) |set| {
                if (std.mem.eql(u8, name, set)) return "value-never-printed";
            }
            return null;
        }
    };
    const env: credential.EnvLookup = .{ .ctx = @ptrCast(&Env.anchor), .getFn = Env.get };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const registry = @import("metacodes-internal").provider.registry;
    const names = try environmentKeys(arena.allocator(), &registry.BUILTIN_PROFILES, env);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (names) |name| {
        try joined.appendSlice(testing.allocator, name);
        try joined.append(testing.allocator, ' ');
        try testing.expect(std.mem.indexOf(u8, name, "value") == null);
    }
    try testing.expect(std.mem.indexOf(u8, joined.items, "DEEPSEEK_API_KEY ") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "METASK_API_KEY") == null);
    // Each name once, however many profiles declare it.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, joined.items, "DEEPSEEK_API_KEY "));
}

test "the reminder for a directory global_default leaves unchosen names /model, the presets and where to remember one (#489)" {
    const text = try reminderText(.{
        .reason = .{ .directory_unchosen = .{
            .directory = "/Users/you/src/z",
            .config_path = "/Users/you/.metacodes/config.json",
            .presets = &.{ "a", "b" },
        } },
        .env_path = "/Users/you/.metacodes/.env",
        .template = true,
        .guide_url = "https://guide#presets",
        .environment_keys = &.{"DEEPSEEK_API_KEY"},
        .unchosen_local = &.{"DeepSeek"},
        .command = "metacodes-dev",
    });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\No model is chosen for this directory: it remembers no preset, and global_default is off.
        \\  Choose one for this session:  /model
        \\  Or start with a preset:       metacodes-dev --preset <name> (presets: a, b)
        \\  Or remember one here:         "/Users/you/src/z": "<name>" under directory_presets in /Users/you/.metacodes/config.json
        \\  How to: https://guide#presets
        \\
    , text);
    var line_buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(not_set_line, modelLine(&line_buffer, .{ .unbound = .{ .directory_unchosen = .{} } }, "m"));

    const bare = try reminderText(.{
        .reason = .{ .directory_unchosen = .{ .directory = "C:\\work\\z \"q\"" } },
        .env_path = "",
        .template = false,
        .guide_url = "https://guide#presets",
    });
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings(
        \\No model is chosen for this directory: it remembers no preset, and global_default is off.
        \\  Choose one for this session:  /model
        \\  Or start with a preset:       metacodes --preset <name>
        \\  Or remember one here:         "C:\\work\\z \"q\"": "<name>" under directory_presets in config.json
        \\  How to: https://guide#presets
        \\
    , bare);

    const nowhere = try reminderText(.{ .reason = .{ .directory_unchosen = .{} }, .env_path = "", .template = false, .guide_url = "g" });
    defer testing.allocator.free(nowhere);
    try testing.expect(std.mem.indexOf(u8, nowhere, "Or remember one here") == null);
    try testing.expect(std.mem.indexOf(u8, nowhere, "/login") == null);

    const unreadable = try reminderText(.{
        .reason = .{ .directory_unchosen = .{ .directory = "/w/z", .config_path = "/s/config.json", .presets = &.{"a"}, .unreadable = "InvalidPreset" } },
        .env_path = "/s/.env",
        .template = false,
        .guide_url = "https://guide#presets",
    });
    defer testing.allocator.free(unreadable);
    try testing.expectEqualStrings(
        \\No model is chosen for this directory: /s/config.json cannot be read (InvalidPreset), so no preset can be looked up, and global_default is off.
        \\  Choose one for this session:  /model
        \\  How to: https://guide#presets
        \\
    , unreadable);
}
