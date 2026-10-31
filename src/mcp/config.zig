//! MCP server configuration: metacodes' own `<state root>/config.json` plus the
//! configuration Claude Code and Codex already read, resolved into one
//! deduplicated server list.
//!
//! Sources, highest precedence first. A server name defined in several sources
//! takes the whole entry from the highest one; fields never merge across
//! sources (Claude Code's rule).
//!
//! | rank | source                                        | format       |
//! |------|-----------------------------------------------|--------------|
//! | 1    | `<state root>/config.json` `mcpServers`       | Claude Code JSON (+ Codex keys) |
//! | 1    | `<state root>/config.json` `mcp_servers`      | legacy `[{name, command: [argv]}]` |
//! | 2    | `~/.claude.json` `projects[<cwd>].mcpServers` | Claude Code local scope |
//! | 3    | `<project>/.mcp.json`                         | Claude Code project scope (approval required) |
//! | 4    | `~/.claude.json` `mcpServers`                 | Claude Code user scope |
//! | 5    | `<dir>/.codex/config.toml` `[mcp_servers]`    | Codex project layer (trusted projects only) |
//! | 6    | `$CODEX_HOME/config.toml` `[mcp_servers]`     | Codex user layer |
//!
//! `"mcpImport": {"claude": false, "codex": false}` in metacodes' config turns
//! the foreign sources off. A metacodes entry `{"enabled": false}` without a
//! transport disables that name in every lower source.
//!
//! Project-scoped `.mcp.json` servers run commands from a checked-out
//! repository, so each needs approval: `enableAllProjectMcpServers` or
//! `enabledMcpjsonServers` in metacodes' config, Claude Code's settings files
//! or Claude Code's per-project state; `disabledMcpjsonServers` anywhere wins.
//! Codex project layers are read only when Codex marks the project trusted.
//!
//! The child environment follows each source's own rule: Claude Code entries
//! inherit metacodes' environment, Codex entries get Codex's allowlist, and
//! metacodes entries get the allowlist unless they set `inheritEnv`. `${VAR}`
//! and `${VAR:-default}` expand in metacodes and Claude Code entries, as in
//! Claude Code; Codex values are literal, as in Codex.

const std = @import("std");
const toml = @import("../util/toml.zig");

pub const Origin = enum {
    metacodes,
    metacodes_legacy,
    claude_local,
    claude_project,
    claude_user,
    codex_project,
    codex_user,

    pub fn label(self: Origin) []const u8 {
        return switch (self) {
            .metacodes => "metacodes",
            .metacodes_legacy => "metacodes (mcp_servers)",
            .claude_local => "Claude Code local",
            .claude_project => "Claude Code project (.mcp.json)",
            .claude_user => "Claude Code user",
            .codex_project => "Codex project",
            .codex_user => "Codex user",
        };
    }

    fn rank(self: Origin) u8 {
        return switch (self) {
            .metacodes, .metacodes_legacy => 1,
            .claude_local => 2,
            .claude_project => 3,
            .claude_user => 4,
            .codex_project => 5,
            .codex_user => 6,
        };
    }
};

pub const EnvPolicy = enum {
    /// Claude Code: the child gets metacodes' environment, then `env`.
    inherit,
    /// Codex: only `DEFAULT_ENV_VARS` (and CA bundle variables) from
    /// metacodes' environment, then `env_vars`, then `env`.
    allowlist,
};

/// Codex `DEFAULT_ENV_VARS` (codex-rs/rmcp-client/src/utils.rs).
pub const DEFAULT_ENV_VARS = if (@import("builtin").os.tag == .windows) [_][]const u8{
    "PATH",         "PATHEXT",           "SHELL",        "COMSPEC",     "SYSTEMROOT",   "WINDIR",
    "SYSTEMDRIVE",  "USERNAME",          "USERDOMAIN",   "USERPROFILE", "HOMEDRIVE",    "HOMEPATH",
    "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432", "PROGRAMDATA", "LOCALAPPDATA", "APPDATA",
    "TEMP",         "TMP",               "TMPDIR",       "POWERSHELL",  "PWSH",
} else [_][]const u8{
    "HOME", "LOGNAME", "PATH", "SHELL", "USER", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "TERM", "TMPDIR", "TZ",
};

/// CA bundle variables Codex forwards when set (TLS through corporate proxies).
pub const CA_ENV_VARS = [_][]const u8{
    "CODEX_CA_CERTIFICATE", "SSL_CERT_FILE",     "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
    "NODE_EXTRA_CA_CERTS",  "GIT_SSL_CAINFO",    "CARGO_HTTP_CAINFO",  "PIP_CERT",
    "BUNDLE_SSL_CA_CERT",   "npm_config_cafile", "NPM_CONFIG_CAFILE",
};

pub const DEFAULT_STARTUP_TIMEOUT_MS: u32 = 30_000;
/// Codex `tool_timeout_sec` default. Claude Code has no comparable bound
/// (MCP_TOOL_TIMEOUT defaults to ~28 h), so its entries carry none.
pub const CODEX_TOOL_TIMEOUT_MS: u32 = 300_000;

pub const KeyValue = struct {
    name: []const u8,
    value: []const u8,
};

pub const Stdio = struct {
    command: []const u8,
    args: []const []const u8,
    env: []const KeyValue,
    /// Names copied from metacodes' environment (Codex `env_vars`).
    env_vars: []const []const u8,
    cwd: ?[]const u8,
    env_policy: EnvPolicy,
};

pub const Http = struct {
    url: []const u8,
    headers: []const KeyValue,
    /// Codex `bearer_token_env_var`: `Authorization: Bearer $VAR`.
    bearer_token_env_var: ?[]const u8,
    /// Codex `env_http_headers`: header name → environment variable.
    env_headers: []const KeyValue,
    wire: HttpWire,
    /// OAuth client settings (Claude Code `oauth`, Codex `scopes`). Used
    /// by `metacodes mcp login` and the token refresh; an entry without
    /// them still logs in through dynamic client registration.
    oauth: OAuthSettings = .{},
};

/// Which HTTP transport a URL server speaks.
pub const HttpWire = enum {
    /// Streamable HTTP (2025-03-26 and later): one endpoint, a POST per
    /// message, JSON or SSE answers.
    streamable,
    /// Claude Code `type: "sse"`: the 2024-11-05 HTTP+SSE transport — a
    /// long-lived GET event stream that names a POST endpoint and carries
    /// every server message.
    legacy_sse,
};

/// Claude Code's `oauth` object (`clientId`, `callbackPort`,
/// `authServerMetadataUrl`) plus Codex's `scopes`. Every field is optional:
/// the default is discovery (RFC 9728 / RFC 8414) and dynamic client
/// registration (RFC 7591) on a kernel-chosen loopback port.
pub const OAuthSettings = struct {
    /// A pre-registered public client; skips dynamic registration.
    client_id: ?[]const u8 = null,
    /// Fixed loopback port for the redirect (`http://localhost:<port>/callback`),
    /// for a client whose redirect URI is registered in advance.
    callback_port: ?u16 = null,
    /// Space-separated scopes requested when the server's challenge names none.
    scopes: ?[]const u8 = null,
    /// Authorization server metadata URL, overriding discovery.
    auth_server_metadata_url: ?[]const u8 = null,
};

pub const Transport = union(enum) {
    stdio: Stdio,
    http: Http,
};

pub const Server = struct {
    name: []const u8,
    transport: Transport,
    startup_timeout_ms: u32,
    /// null = no per-call bound beyond the user's interrupt.
    tool_timeout_ms: ?u32,
    /// Raw MCP tool names to expose (null = all), then names to hide.
    enabled_tools: ?[]const []const u8,
    disabled_tools: []const []const u8,
    origin: Origin,
    origin_path: []const u8,
};

pub const PendingReason = enum {
    /// A `.mcp.json` server nobody approved yet.
    needs_approval,
    /// A `.mcp.json` server listed in `disabledMcpjsonServers`.
    rejected,
};

pub const Pending = struct {
    name: []const u8,
    origin_path: []const u8,
    reason: PendingReason,
};

pub const Problem = struct {
    origin: Origin,
    origin_path: []const u8,
    /// "" when the problem concerns the whole file.
    server: []const u8,
    message: []const u8,
};

pub const Resolved = struct {
    /// Enabled, approved servers in precedence order (each name once).
    servers: []const Server,
    /// Names turned off by `enabled: false`.
    disabled: []const []const u8,
    /// Project servers that were not started.
    pending: []const Pending,
    problems: []const Problem,
};

/// A snapshot of metacodes' own environment (`KEY=VALUE` entries).
pub const Environment = struct {
    entries: []const [:0]const u8,

    pub fn fromProcess(arena: std.mem.Allocator) error{OutOfMemory}!Environment {
        return .{ .entries = try @import("platform").paths.environment(arena) };
    }

    /// Windows variable names are case-insensitive.
    pub fn get(self: Environment, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            const eq = std.mem.indexOfScalarPos(u8, entry, 1, '=') orelse continue;
            const matches = if (@import("builtin").os.tag == .windows)
                std.ascii.eqlIgnoreCase(entry[0..eq], name)
            else
                std.mem.eql(u8, entry[0..eq], name);
            if (matches) return entry[eq + 1 ..];
        }
        return null;
    }
};

/// The raw bytes of every source, so resolution is a pure function.
pub const Documents = struct {
    metacodes_config: ?Document = null,
    claude_json: ?Document = null,
    project_mcp_json: ?Document = null,
    /// Claude Code settings files consulted for `.mcp.json` approvals.
    claude_settings: []const SettingsDocument = &.{},
    codex_user_config: ?Document = null,
    /// `.codex/config.toml` files from the project root down to cwd.
    codex_project_configs: []const Document = &.{},
};

pub const Document = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const SettingsDocument = struct {
    path: []const u8,
    bytes: []const u8,
    /// Shared `.claude/settings.json` may reject servers but cannot approve
    /// them (Claude Code ignores its enable keys in untrusted folders, and
    /// metacodes has no folder-trust record of its own).
    may_approve: bool,
};

pub const Context = struct {
    cwd: []const u8,
    workspace_root: []const u8,
    /// Directories from the workspace root down to cwd (Codex project layers).
    project_dirs: []const []const u8 = &.{},
    env: Environment,
};

const Candidate = struct {
    server: Server,
    enabled: bool,
};

const Builder = struct {
    arena: std.mem.Allocator,
    context: Context,
    candidates: std.ArrayList(Candidate) = .empty,
    disabled_names: std.ArrayList([]const u8) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    problems: std.ArrayList(Problem) = .empty,

    fn problem(self: *Builder, origin: Origin, path: []const u8, server: []const u8, comptime format: []const u8, args: anytype) error{OutOfMemory}!void {
        try self.problems.append(self.arena, .{
            .origin = origin,
            .origin_path = path,
            .server = server,
            .message = try std.fmt.allocPrint(self.arena, format, args),
        });
    }
};

pub const Error = error{OutOfMemory};

/// Resolve every source into the server list metacodes starts.
pub fn resolve(arena: std.mem.Allocator, documents: Documents, context: Context) Error!Resolved {
    var builder = Builder{ .arena = arena, .context = context };
    var import_claude = true;
    var import_codex = true;
    var approvals = Approvals{};

    if (documents.metacodes_config) |document| {
        if (try parseJson(&builder, .metacodes, document)) |root| {
            if (root.object.get("mcpImport")) |import_value| {
                if (import_value == .object) {
                    if (import_value.object.get("claude")) |value| if (value == .bool) {
                        import_claude = value.bool;
                    };
                    if (import_value.object.get("codex")) |value| if (value == .bool) {
                        import_codex = value.bool;
                    };
                }
            }
            try approvals.absorbJson(arena, root, true);
            if (root.object.get("mcpServers")) |servers| try addJsonServers(&builder, .metacodes, document.path, servers);
            if (root.object.get("mcp_servers")) |servers| try addLegacyServers(&builder, document.path, servers);
        }
    }

    if (import_claude) {
        if (documents.claude_json) |document| {
            if (try parseJson(&builder, .claude_user, document)) |root| {
                if (claudeProject(root, context)) |project| {
                    if (project.get("mcpServers")) |servers| try addJsonServers(&builder, .claude_local, document.path, servers);
                    try approvals.absorbObject(arena, project, true);
                }
                if (root.object.get("mcpServers")) |servers| try addJsonServers(&builder, .claude_user, document.path, servers);
            }
        }
        for (documents.claude_settings) |settings| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, settings.bytes, .{}) catch {
                try builder.problem(.claude_project, settings.path, "", "settings file is not valid JSON; its MCP approvals were ignored", .{});
                continue;
            };
            if (parsed == .object) try approvals.absorbJson(arena, parsed, settings.may_approve);
        }
        if (documents.project_mcp_json) |document| {
            if (try parseJson(&builder, .claude_project, document)) |root| {
                if (root.object.get("mcpServers")) |servers| {
                    try addProjectServers(&builder, document.path, servers, &approvals);
                }
            }
        }
    }

    if (import_codex) {
        var trusted_dirs: []const []const u8 = &.{};
        if (documents.codex_user_config) |document| {
            if (parseToml(&builder, .codex_user, document)) |root| {
                trusted_dirs = try codexTrustedDirs(arena, root);
                if (root.get("mcp_servers")) |servers| try addTomlServers(&builder, .codex_user, document.path, servers);
            }
        }
        // Deeper project layers win (Codex merges root to cwd).
        var index = documents.codex_project_configs.len;
        while (index > 0) {
            index -= 1;
            const document = documents.codex_project_configs[index];
            const project_dir = codexProjectDir(document.path);
            if (!codexTrusts(trusted_dirs, project_dir, context)) {
                try builder.problem(.codex_project, document.path, "", "project is not trusted in Codex; its MCP servers were not loaded", .{});
                continue;
            }
            if (parseToml(&builder, .codex_project, document)) |root| {
                if (root.get("mcp_servers")) |servers| try addTomlServers(&builder, .codex_project, document.path, servers);
            }
        }
    }

    return finish(&builder);
}

fn finish(builder: *Builder) Error!Resolved {
    const arena = builder.arena;
    // Stable precedence: rank, then the order each source listed its servers.
    std.mem.sort(Candidate, builder.candidates.items, {}, struct {
        fn lessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
            return lhs.server.origin.rank() < rhs.server.origin.rank();
        }
    }.lessThan);
    var servers: std.ArrayList(Server) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (builder.disabled_names.items) |name| try seen.put(arena, name, {});
    for (builder.candidates.items) |candidate| {
        const entry = try seen.getOrPut(arena, candidate.server.name);
        if (entry.found_existing) continue;
        if (!candidate.enabled) {
            try builder.disabled_names.append(arena, candidate.server.name);
            continue;
        }
        try servers.append(arena, candidate.server);
    }
    // A pending project server shadowed by an approved higher source is not pending.
    var pending: std.ArrayList(Pending) = .empty;
    for (builder.pending.items) |item| {
        var shadowed = false;
        for (servers.items) |server| {
            if (std.mem.eql(u8, server.name, item.name)) shadowed = true;
        }
        if (!shadowed) try pending.append(arena, item);
    }
    return .{
        .servers = try servers.toOwnedSlice(arena),
        .disabled = try builder.disabled_names.toOwnedSlice(arena),
        .pending = try pending.toOwnedSlice(arena),
        .problems = try builder.problems.toOwnedSlice(arena),
    };
}

// ----------------------------------------------------------------------------
// JSON sources (metacodes, Claude Code)
// ----------------------------------------------------------------------------

fn parseJson(builder: *Builder, origin: Origin, document: Document) Error!?std.json.Value {
    const root = std.json.parseFromSliceLeaky(std.json.Value, builder.arena, document.bytes, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try builder.problem(origin, document.path, "", "not valid JSON ({s})", .{@errorName(err)});
        return null;
    };
    if (root != .object) {
        try builder.problem(origin, document.path, "", "top level is not a JSON object", .{});
        return null;
    }
    return root;
}

/// Claude Code keys local-scope state by the directory it was started in.
fn claudeProject(root: std.json.Value, context: Context) ?std.json.ObjectMap {
    const projects = root.object.get("projects") orelse return null;
    if (projects != .object) return null;
    for ([_][]const u8{ context.cwd, context.workspace_root }) |key| {
        if (key.len == 0) continue;
        if (projects.object.get(key)) |project| {
            if (project == .object) return project.object;
        }
    }
    return null;
}

fn addJsonServers(builder: *Builder, origin: Origin, path: []const u8, servers: std.json.Value) Error!void {
    if (servers != .object) {
        try builder.problem(origin, path, "", "mcpServers is not an object", .{});
        return;
    }
    var iterator = servers.object.iterator();
    while (iterator.next()) |entry| {
        const candidate = try parseJsonServer(builder, origin, path, entry.key_ptr.*, entry.value_ptr.*) orelse continue;
        try builder.candidates.append(builder.arena, candidate);
    }
}

fn addProjectServers(builder: *Builder, path: []const u8, servers: std.json.Value, approvals: *const Approvals) Error!void {
    if (servers != .object) {
        try builder.problem(.claude_project, path, "", "mcpServers is not an object", .{});
        return;
    }
    var iterator = servers.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        switch (approvals.decide(name)) {
            .approved => {},
            .rejected => {
                try builder.pending.append(builder.arena, .{ .name = name, .origin_path = path, .reason = .rejected });
                continue;
            },
            .unknown => {
                try builder.pending.append(builder.arena, .{ .name = name, .origin_path = path, .reason = .needs_approval });
                continue;
            },
        }
        const candidate = try parseJsonServer(builder, .claude_project, path, name, entry.value_ptr.*) orelse continue;
        try builder.candidates.append(builder.arena, candidate);
    }
}

fn parseJsonServer(
    builder: *Builder,
    origin: Origin,
    path: []const u8,
    name: []const u8,
    value: std.json.Value,
) Error!?Candidate {
    if (!validServerName(name)) {
        try builder.problem(origin, path, name, "invalid server name (use letters, digits and _ - . : @ /)", .{});
        return null;
    }
    if (value != .object) {
        try builder.problem(origin, path, name, "server entry is not an object", .{});
        return null;
    }
    const object = value.object;
    const expand = origin != .codex_user and origin != .codex_project;
    const enabled = if (jsonBool(object, &.{"enabled"})) |flag| flag else true;
    if (!enabled and object.get("command") == null and object.get("url") == null) {
        // `{"enabled": false}` alone switches the name off everywhere below.
        try builder.disabled_names.append(builder.arena, name);
        return null;
    }

    const type_name = jsonString(object, &.{"type"}) orelse "";
    const transport: Transport = blk: {
        const is_http = std.mem.eql(u8, type_name, "http") or std.mem.eql(u8, type_name, "streamable-http") or
            std.mem.eql(u8, type_name, "streamable_http");
        const is_sse = std.mem.eql(u8, type_name, "sse");
        if (is_http or is_sse or (type_name.len == 0 and object.get("url") != null and object.get("command") == null)) {
            const raw_url = jsonString(object, &.{"url"}) orelse {
                try builder.problem(origin, path, name, "{s} server has no url", .{if (is_sse) "sse" else "http"});
                return null;
            };
            if (jsonString(object, &.{ "headersHelper", "http_headers_helper" }) != null)
                try builder.problem(origin, path, name, "headersHelper is not supported; static headers are sent", .{});
            break :blk .{ .http = .{
                .url = try expandValue(builder, origin, path, name, raw_url, expand),
                .headers = try jsonPairs(builder, origin, path, name, object, &.{ "headers", "http_headers" }, expand),
                .bearer_token_env_var = jsonString(object, &.{ "bearerTokenEnvVar", "bearer_token_env_var" }),
                .env_headers = try jsonPairs(builder, origin, path, name, object, &.{ "envHttpHeaders", "env_http_headers" }, false),
                .wire = if (is_sse) .legacy_sse else .streamable,
                .oauth = try jsonOAuth(builder, origin, path, name, object, expand),
            } };
        }
        if (type_name.len != 0 and !std.mem.eql(u8, type_name, "stdio")) {
            try builder.problem(origin, path, name, "transport type \"{s}\" is not supported", .{type_name});
            return null;
        }
        const raw_command = jsonString(object, &.{"command"}) orelse {
            try builder.problem(origin, path, name, "stdio server has no command", .{});
            return null;
        };
        const inherit = jsonBool(object, &.{ "inheritEnv", "inherit_env" }) orelse switch (origin) {
            .claude_local, .claude_project, .claude_user => true,
            else => false,
        };
        const raw_cwd = jsonString(object, &.{"cwd"});
        break :blk .{ .stdio = .{
            .command = try expandValue(builder, origin, path, name, raw_command, expand),
            .args = try jsonStrings(builder, origin, path, name, object, &.{"args"}, expand),
            .env = try jsonPairs(builder, origin, path, name, object, &.{"env"}, expand),
            .env_vars = try jsonStrings(builder, origin, path, name, object, &.{ "envVars", "env_vars" }, false),
            .cwd = if (raw_cwd) |cwd| try expandValue(builder, origin, path, name, cwd, expand) else null,
            .env_policy = if (inherit) .inherit else .allowlist,
        } };
    };

    return .{
        .server = .{
            .name = name,
            .transport = transport,
            .startup_timeout_ms = jsonMillis(object, &.{ "startupTimeoutMs", "startup_timeout_ms" }, &.{ "startupTimeoutSec", "startup_timeout_sec" }) orelse
                DEFAULT_STARTUP_TIMEOUT_MS,
            // Claude Code `timeout` is a per-call wall clock in milliseconds.
            .tool_timeout_ms = jsonMillis(object, &.{ "timeout", "toolTimeoutMs", "tool_timeout_ms" }, &.{ "toolTimeoutSec", "tool_timeout_sec" }),
            .enabled_tools = if (object.get("enabledTools") orelse object.get("enabled_tools")) |_|
                try jsonStrings(builder, origin, path, name, object, &.{ "enabledTools", "enabled_tools" }, false)
            else
                null,
            .disabled_tools = try jsonStrings(builder, origin, path, name, object, &.{ "disabledTools", "disabled_tools" }, false),
            .origin = origin,
            .origin_path = path,
        },
        .enabled = enabled,
    };
}

/// Legacy metacodes array: `[{"name": "x", "command": ["/abs/bin", "--flag"]}]`.
fn addLegacyServers(builder: *Builder, path: []const u8, servers: std.json.Value) Error!void {
    if (servers != .array) {
        try builder.problem(.metacodes_legacy, path, "", "mcp_servers is not an array", .{});
        return;
    }
    for (servers.array.items) |item| {
        if (item != .object) continue;
        const name = jsonString(item.object, &.{"name"}) orelse {
            try builder.problem(.metacodes_legacy, path, "", "mcp_servers entry has no name", .{});
            continue;
        };
        if (!validServerName(name)) {
            try builder.problem(.metacodes_legacy, path, name, "invalid server name", .{});
            continue;
        }
        const argv = item.object.get("command") orelse {
            try builder.problem(.metacodes_legacy, path, name, "command must be an array of strings", .{});
            continue;
        };
        if (argv != .array or argv.array.items.len == 0) {
            try builder.problem(.metacodes_legacy, path, name, "command must be a non-empty array of strings", .{});
            continue;
        }
        var parts: std.ArrayList([]const u8) = .empty;
        for (argv.array.items) |part| {
            if (part != .string) {
                try builder.problem(.metacodes_legacy, path, name, "command must be an array of strings", .{});
                parts.clearRetainingCapacity();
                break;
            }
            try parts.append(builder.arena, part.string);
        }
        if (parts.items.len == 0) continue;
        try builder.candidates.append(builder.arena, .{
            .server = .{
                .name = name,
                .transport = .{ .stdio = .{
                    .command = parts.items[0],
                    .args = parts.items[1..],
                    .env = try jsonPairs(builder, .metacodes_legacy, path, name, item.object, &.{"env"}, true),
                    .env_vars = &.{},
                    .cwd = null,
                    .env_policy = .allowlist,
                } },
                .startup_timeout_ms = DEFAULT_STARTUP_TIMEOUT_MS,
                .tool_timeout_ms = null,
                .enabled_tools = null,
                .disabled_tools = &.{},
                .origin = .metacodes_legacy,
                .origin_path = path,
            },
            .enabled = true,
        });
    }
}

fn jsonString(object: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (object.get(key)) |value| if (value == .string) return value.string;
    }
    return null;
}

fn jsonBool(object: std.json.ObjectMap, keys: []const []const u8) ?bool {
    for (keys) |key| {
        if (object.get(key)) |value| if (value == .bool) return value.bool;
    }
    return null;
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

/// Milliseconds from `*_ms` keys or seconds from `*_sec` keys; ms wins when
/// both are present except that Codex documents `_sec` winning — both forms
/// rarely coexist, and values below one second are ignored like Claude Code.
fn jsonMillis(object: std.json.ObjectMap, ms_keys: []const []const u8, sec_keys: []const []const u8) ?u32 {
    for (sec_keys) |key| {
        if (object.get(key)) |value| if (jsonNumber(value)) |seconds| return clampMillis(seconds * 1000);
    }
    for (ms_keys) |key| {
        if (object.get(key)) |value| if (jsonNumber(value)) |millis| return clampMillis(millis);
    }
    return null;
}

fn clampMillis(millis: f64) ?u32 {
    if (!std.math.isFinite(millis) or millis < 1000) return null;
    return @intFromFloat(@min(millis, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
}

/// Claude Code's `oauth` object plus a top-level `scopes` (Codex's key, in
/// JSON too). A malformed field is a problem and is left unset, never
/// guessed.
fn jsonOAuth(
    builder: *Builder,
    origin: Origin,
    path: []const u8,
    name: []const u8,
    object: std.json.ObjectMap,
    expand: bool,
) Error!OAuthSettings {
    var settings: OAuthSettings = .{};
    if (object.get("scopes")) |_|
        settings.scopes = try joinScopes(builder, try jsonStrings(builder, origin, path, name, object, &.{"scopes"}, false));
    const value = object.get("oauth") orelse return settings;
    if (value != .object) {
        try builder.problem(origin, path, name, "oauth must be an object", .{});
        return settings;
    }
    const oauth = value.object;
    if (jsonString(oauth, &.{ "clientId", "client_id" })) |client_id|
        settings.client_id = try expandValue(builder, origin, path, name, client_id, expand);
    if (oauth.get("clientSecret") != null or oauth.get("client_secret") != null)
        try builder.problem(origin, path, name, "oauth.clientSecret is not read from configuration; register a public client (PKCE)", .{});
    if (oauth.get("callbackPort") orelse oauth.get("callback_port")) |port| {
        const number = jsonNumber(port) orelse -1;
        if (number >= 1 and number <= 65535 and @floor(number) == number) {
            settings.callback_port = @intFromFloat(number);
        } else {
            try builder.problem(origin, path, name, "oauth.callbackPort must be a port number (1-65535)", .{});
        }
    }
    if (jsonString(oauth, &.{ "authServerMetadataUrl", "auth_server_metadata_url" })) |url|
        settings.auth_server_metadata_url = try expandValue(builder, origin, path, name, url, expand);
    if (oauth.get("scopes")) |scopes| switch (scopes) {
        .string => |text| settings.scopes = text,
        else => settings.scopes = try joinScopes(builder, try jsonStrings(builder, origin, path, name, oauth, &.{"scopes"}, false)),
    };
    return settings;
}

/// `["a", "b"]` → `"a b"` (the OAuth `scope` parameter); null when empty.
fn joinScopes(builder: *Builder, scopes: []const []const u8) Error!?[]const u8 {
    if (scopes.len == 0) return null;
    return try std.mem.join(builder.arena, " ", scopes);
}

fn jsonStrings(
    builder: *Builder,
    origin: Origin,
    path: []const u8,
    name: []const u8,
    object: std.json.ObjectMap,
    keys: []const []const u8,
    expand: bool,
) Error![]const []const u8 {
    for (keys) |key| {
        const value = object.get(key) orelse continue;
        if (value != .array) {
            try builder.problem(origin, path, name, "{s} must be an array", .{key});
            return &.{};
        }
        var out: std.ArrayList([]const u8) = .empty;
        for (value.array.items) |item| {
            const text = switch (item) {
                .string => |string| string,
                // Codex `env_vars` also accepts `{name = "X", source = "local"}`.
                .object => |entry| jsonString(entry, &.{"name"}) orelse continue,
                else => {
                    try builder.problem(origin, path, name, "{s} must contain strings", .{key});
                    continue;
                },
            };
            try out.append(builder.arena, try expandValue(builder, origin, path, name, text, expand));
        }
        return out.toOwnedSlice(builder.arena);
    }
    return &.{};
}

fn jsonPairs(
    builder: *Builder,
    origin: Origin,
    path: []const u8,
    name: []const u8,
    object: std.json.ObjectMap,
    keys: []const []const u8,
    expand: bool,
) Error![]const KeyValue {
    for (keys) |key| {
        const value = object.get(key) orelse continue;
        if (value != .object) {
            try builder.problem(origin, path, name, "{s} must be an object of strings", .{key});
            return &.{};
        }
        var out: std.ArrayList(KeyValue) = .empty;
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            const text = switch (entry.value_ptr.*) {
                .string => |string| string,
                else => {
                    try builder.problem(origin, path, name, "{s}.{s} must be a string", .{ key, entry.key_ptr.* });
                    continue;
                },
            };
            try out.append(builder.arena, .{
                .name = entry.key_ptr.*,
                .value = try expandValue(builder, origin, path, name, text, expand),
            });
        }
        return out.toOwnedSlice(builder.arena);
    }
    return &.{};
}

/// Claude Code `${VAR}` / `${VAR:-default}`. An unset variable without a
/// default stays literal and is reported, as Claude Code does.
fn expandValue(
    builder: *Builder,
    origin: Origin,
    path: []const u8,
    name: []const u8,
    text: []const u8,
    enabled: bool,
) Error![]const u8 {
    if (!enabled or std.mem.indexOf(u8, text, "${") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (index + 1 < text.len and text[index] == '$' and text[index + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, text, index + 2, '}')) |close| {
                const body = text[index + 2 .. close];
                const split = std.mem.indexOf(u8, body, ":-");
                const variable = if (split) |at| body[0..at] else body;
                if (validEnvName(variable)) {
                    if (builder.context.env.get(variable)) |value| {
                        if (value.len != 0 or split == null) {
                            try out.appendSlice(builder.arena, value);
                            index = close + 1;
                            continue;
                        }
                    }
                    if (split) |at| {
                        try out.appendSlice(builder.arena, body[at + 2 ..]);
                        index = close + 1;
                        continue;
                    }
                    try builder.problem(origin, path, name, "environment variable {s} is not set", .{variable});
                }
            }
        }
        try out.append(builder.arena, text[index]);
        index += 1;
    }
    return out.toOwnedSlice(builder.arena);
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

/// Codex's server-name grammar (`^[a-zA-Z0-9_:@/.-]+$`), which contains
/// Claude Code's letters, digits, `-` and `_`.
pub fn validServerName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "_:@/.-", byte) == null) return false;
    }
    return true;
}

// ----------------------------------------------------------------------------
// Approvals for project `.mcp.json`
// ----------------------------------------------------------------------------

const Approvals = struct {
    enable_all: bool = false,
    enabled: std.ArrayList([]const u8) = .empty,
    disabled: std.ArrayList([]const u8) = .empty,

    const Decision = enum { approved, rejected, unknown };

    fn decide(self: *const Approvals, name: []const u8) Decision {
        for (self.disabled.items) |item| if (std.mem.eql(u8, item, name)) return .rejected;
        if (self.enable_all) return .approved;
        for (self.enabled.items) |item| if (std.mem.eql(u8, item, name)) return .approved;
        return .unknown;
    }

    fn absorbJson(self: *Approvals, arena: std.mem.Allocator, root: std.json.Value, may_approve: bool) Error!void {
        if (root != .object) return;
        try self.absorbObject(arena, root.object, may_approve);
    }

    fn absorbObject(self: *Approvals, arena: std.mem.Allocator, object: std.json.ObjectMap, may_approve: bool) Error!void {
        if (may_approve) {
            if (object.get("enableAllProjectMcpServers")) |value| if (value == .bool and value.bool) {
                self.enable_all = true;
            };
            try appendNames(arena, &self.enabled, object.get("enabledMcpjsonServers"));
        }
        try appendNames(arena, &self.disabled, object.get("disabledMcpjsonServers"));
    }

    fn appendNames(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), value: ?std.json.Value) Error!void {
        const array = value orelse return;
        if (array != .array) return;
        for (array.array.items) |item| {
            if (item == .string) try list.append(arena, item.string);
        }
    }
};

// ----------------------------------------------------------------------------
// TOML sources (Codex)
// ----------------------------------------------------------------------------

fn parseToml(builder: *Builder, origin: Origin, document: Document) ?toml.Value {
    var diagnostic = toml.Diagnostic{};
    const root = toml.parse(builder.arena, document.bytes, .{}, &diagnostic) catch |err| {
        builder.problem(origin, document.path, "", "not valid TOML at line {d} ({s})", .{ diagnostic.line, @errorName(err) }) catch {};
        return null;
    };
    return .{ .table = root };
}

fn codexTrustedDirs(arena: std.mem.Allocator, root: toml.Value) Error![]const []const u8 {
    const projects = root.get("projects") orelse return &.{};
    const table = switch (projects) {
        .table => |value| value,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (table.keys.items, table.values.items) |dir, value| {
        const level = (value.get("trust_level") orelse continue).asString() orelse continue;
        if (std.mem.eql(u8, level, "trusted")) try out.append(arena, dir);
    }
    return out.toOwnedSlice(arena);
}

/// `<dir>/.codex/config.toml` → `<dir>`.
fn codexProjectDir(config_path: []const u8) []const u8 {
    const codex_dir = std.fs.path.dirname(config_path) orelse return config_path;
    return std.fs.path.dirname(codex_dir) orelse codex_dir;
}

/// Codex trusts a project by its root (or any ancestor of the working directory).
fn codexTrusts(trusted: []const []const u8, project_dir: []const u8, context: Context) bool {
    for (trusted) |dir| {
        const clean = std.mem.trimEnd(u8, dir, "/\\");
        if (std.mem.eql(u8, clean, project_dir) or std.mem.eql(u8, clean, context.workspace_root)) return true;
        if (isAncestorOrSelf(clean, project_dir)) return true;
    }
    return false;
}

fn isAncestorOrSelf(ancestor: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, ancestor)) return false;
    return path.len == ancestor.len or path[ancestor.len] == '/' or path[ancestor.len] == '\\';
}

fn addTomlServers(builder: *Builder, origin: Origin, path: []const u8, servers: toml.Value) Error!void {
    const table = switch (servers) {
        .table => |value| value,
        else => {
            try builder.problem(origin, path, "", "mcp_servers is not a table", .{});
            return;
        },
    };
    for (table.keys.items, table.values.items) |name, value| {
        const candidate = try parseTomlServer(builder, origin, path, name, value) orelse continue;
        try builder.candidates.append(builder.arena, candidate);
    }
}

fn parseTomlServer(builder: *Builder, origin: Origin, path: []const u8, name: []const u8, value: toml.Value) Error!?Candidate {
    if (!validServerName(name)) {
        try builder.problem(origin, path, name, "invalid server name", .{});
        return null;
    }
    if (value != .table) {
        try builder.problem(origin, path, name, "server entry is not a table", .{});
        return null;
    }
    const enabled = if (value.get("enabled")) |flag| (if (flag == .boolean) flag.boolean else true) else true;
    const transport: Transport = if (tomlString(value, "command")) |command| .{ .stdio = .{
        .command = command,
        .args = try tomlStrings(builder, origin, path, name, value, "args"),
        .env = try tomlPairs(builder, origin, path, name, value, "env"),
        .env_vars = try tomlStrings(builder, origin, path, name, value, "env_vars"),
        .cwd = tomlString(value, "cwd"),
        .env_policy = .allowlist,
    } } else if (tomlString(value, "url")) |url| .{
        .http = .{
            .url = url,
            .headers = try tomlPairs(builder, origin, path, name, value, "http_headers"),
            .bearer_token_env_var = tomlString(value, "bearer_token_env_var"),
            .env_headers = try tomlPairs(builder, origin, path, name, value, "env_http_headers"),
            .wire = .streamable,
            .oauth = .{
                // Codex `scopes = ["a", "b"]`; its callback port is a global
                // setting (`mcp_oauth_callback_port`), not a server's.
                .scopes = try joinScopes(builder, try tomlStrings(builder, origin, path, name, value, "scopes")),
            },
        },
    } else {
        try builder.problem(origin, path, name, "invalid transport: set command (stdio) or url (streamable HTTP)", .{});
        return null;
    };
    if (value.get("bearer_token") != null)
        try builder.problem(origin, path, name, "bearer_token is not supported (Codex rejects it too); use bearer_token_env_var", .{});
    if (value.get("http_headers_helper") != null)
        try builder.problem(origin, path, name, "http_headers_helper is not supported; static headers are sent", .{});

    return .{
        .server = .{
            .name = name,
            .transport = transport,
            .startup_timeout_ms = tomlMillis(value, "startup_timeout_ms", "startup_timeout_sec") orelse DEFAULT_STARTUP_TIMEOUT_MS,
            .tool_timeout_ms = tomlMillis(value, "tool_timeout_ms", "tool_timeout_sec") orelse CODEX_TOOL_TIMEOUT_MS,
            .enabled_tools = if (value.get("enabled_tools") != null) try tomlStrings(builder, origin, path, name, value, "enabled_tools") else null,
            .disabled_tools = try tomlStrings(builder, origin, path, name, value, "disabled_tools"),
            .origin = origin,
            .origin_path = path,
        },
        .enabled = enabled,
    };
}

fn tomlString(value: toml.Value, key: []const u8) ?[]const u8 {
    return (value.get(key) orelse return null).asString();
}

fn tomlMillis(value: toml.Value, ms_key: []const u8, sec_key: []const u8) ?u32 {
    // Codex: `startup_timeout_sec` wins over `startup_timeout_ms`.
    if (value.get(sec_key)) |seconds| switch (seconds) {
        .integer => |integer| return clampMillis(@as(f64, @floatFromInt(integer)) * 1000),
        .float => |float| return clampMillis(float * 1000),
        else => {},
    };
    if (value.get(ms_key)) |millis| switch (millis) {
        .integer => |integer| return clampMillis(@floatFromInt(integer)),
        .float => |float| return clampMillis(float),
        else => {},
    };
    return null;
}

fn tomlStrings(builder: *Builder, origin: Origin, path: []const u8, name: []const u8, value: toml.Value, key: []const u8) Error![]const []const u8 {
    const array = value.get(key) orelse return &.{};
    const items = switch (array) {
        .array => |items| items,
        else => {
            try builder.problem(origin, path, name, "{s} must be an array", .{key});
            return &.{};
        },
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const text = switch (item) {
            .string => |string| string,
            .table => (item.get("name") orelse continue).asString() orelse continue,
            else => {
                try builder.problem(origin, path, name, "{s} must contain strings", .{key});
                continue;
            },
        };
        try out.append(builder.arena, text);
    }
    return out.toOwnedSlice(builder.arena);
}

fn tomlPairs(builder: *Builder, origin: Origin, path: []const u8, name: []const u8, value: toml.Value, key: []const u8) Error![]const KeyValue {
    const table_value = value.get(key) orelse return &.{};
    const table = switch (table_value) {
        .table => |table| table,
        else => {
            try builder.problem(origin, path, name, "{s} must be a table of strings", .{key});
            return &.{};
        },
    };
    var out: std.ArrayList(KeyValue) = .empty;
    for (table.keys.items, table.values.items) |pair_name, pair_value| {
        const text = pair_value.asString() orelse {
            try builder.problem(origin, path, name, "{s}.{s} must be a string", .{ key, pair_name });
            continue;
        };
        try out.append(builder.arena, .{ .name = pair_name, .value = text });
    }
    return out.toOwnedSlice(builder.arena);
}

// ----------------------------------------------------------------------------
// File loading
// ----------------------------------------------------------------------------

pub const LoadInputs = struct {
    state_root: []const u8,
    home: []const u8,
    cwd: []const u8,
    workspace_root: []const u8,
    /// `$CODEX_HOME`; "" = `<home>/.codex`.
    codex_home: []const u8 = "",
    env: Environment,
    /// Override for tests; defaults to the platform file reader.
    read_file: *const fn (std.mem.Allocator, []const u8) ?[]const u8 = readFileOrNull,
};

/// Read every source from disk and resolve it.
pub fn load(arena: std.mem.Allocator, inputs: LoadInputs) Error!Resolved {
    var documents = Documents{};
    const read = inputs.read_file;
    if (inputs.state_root.len != 0) {
        const path = try std.fs.path.join(arena, &.{ inputs.state_root, "config.json" });
        if (read(arena, path)) |bytes| documents.metacodes_config = .{ .path = path, .bytes = bytes };
    }
    if (inputs.home.len != 0) {
        const claude_json = try std.fs.path.join(arena, &.{ inputs.home, ".claude.json" });
        if (read(arena, claude_json)) |bytes| documents.claude_json = .{ .path = claude_json, .bytes = bytes };
    }
    const project_root = if (inputs.workspace_root.len != 0) inputs.workspace_root else inputs.cwd;
    if (project_root.len != 0) {
        const mcp_json = try std.fs.path.join(arena, &.{ project_root, ".mcp.json" });
        if (read(arena, mcp_json)) |bytes| documents.project_mcp_json = .{ .path = mcp_json, .bytes = bytes };
    }

    var settings: std.ArrayList(SettingsDocument) = .empty;
    const managed = if (@import("builtin").os.tag == .macos)
        "/Library/Application Support/ClaudeCode/managed-settings.json"
    else if (@import("builtin").os.tag == .windows)
        "C:\\Program Files\\ClaudeCode\\managed-settings.json"
    else
        "/etc/claude-code/managed-settings.json";
    const settings_paths = [_]struct { base: []const u8, parts: []const []const u8, may_approve: bool }{
        .{ .base = "", .parts = &.{managed}, .may_approve = true },
        .{ .base = inputs.home, .parts = &.{ ".claude", "settings.json" }, .may_approve = true },
        .{ .base = project_root, .parts = &.{ ".claude", "settings.local.json" }, .may_approve = true },
        .{ .base = project_root, .parts = &.{ ".claude", "settings.json" }, .may_approve = false },
    };
    for (settings_paths) |entry| {
        var parts: std.ArrayList([]const u8) = .empty;
        if (entry.base.len != 0) try parts.append(arena, entry.base) else if (entry.parts.len > 1) continue;
        try parts.appendSlice(arena, entry.parts);
        const path = try std.fs.path.join(arena, parts.items);
        if (read(arena, path)) |bytes| try settings.append(arena, .{ .path = path, .bytes = bytes, .may_approve = entry.may_approve });
    }
    documents.claude_settings = try settings.toOwnedSlice(arena);

    const codex_home = if (inputs.codex_home.len != 0)
        inputs.codex_home
    else if (inputs.home.len != 0)
        try std.fs.path.join(arena, &.{ inputs.home, ".codex" })
    else
        "";
    if (codex_home.len != 0) {
        const path = try std.fs.path.join(arena, &.{ codex_home, "config.toml" });
        if (read(arena, path)) |bytes| documents.codex_user_config = .{ .path = path, .bytes = bytes };
    }
    const project_dirs = try projectDirs(arena, project_root, inputs.cwd);
    var codex_projects: std.ArrayList(Document) = .empty;
    for (project_dirs) |dir| {
        const codex_dir = try std.fs.path.join(arena, &.{ dir, ".codex" });
        // Codex skips a project `.codex` that is CODEX_HOME itself.
        if (std.mem.eql(u8, codex_dir, codex_home)) continue;
        const path = try std.fs.path.join(arena, &.{ codex_dir, "config.toml" });
        if (read(arena, path)) |bytes| try codex_projects.append(arena, .{ .path = path, .bytes = bytes });
    }
    documents.codex_project_configs = try codex_projects.toOwnedSlice(arena);

    return resolve(arena, documents, .{
        .cwd = inputs.cwd,
        .workspace_root = inputs.workspace_root,
        .project_dirs = project_dirs,
        .env = inputs.env,
    });
}

fn projectDirs(arena: std.mem.Allocator, root: []const u8, cwd: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const clean_root = std.mem.trimEnd(u8, root, "/\\");
    const clean_cwd = std.mem.trimEnd(u8, cwd, "/\\");
    if (clean_root.len == 0 or !isAncestorOrSelf(clean_root, clean_cwd)) {
        if (clean_cwd.len != 0) try out.append(arena, clean_cwd);
        return out.toOwnedSlice(arena);
    }
    try out.append(arena, clean_root);
    var cursor = clean_root.len;
    while (cursor < clean_cwd.len and out.items.len < 64) {
        const next = std.mem.indexOfAnyPos(u8, clean_cwd, cursor + 1, "/\\") orelse clean_cwd.len;
        try out.append(arena, clean_cwd[0..next]);
        cursor = next;
    }
    return out.toOwnedSlice(arena);
}

/// Configuration files are small; a file that cannot be read is absent.
fn readFileOrNull(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const pfs = @import("platform").fs;
    const path_z = arena.dupeZ(u8, path) catch return null;
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.read(fd, &buffer);
        if (count < 0) return null;
        if (count == 0) break;
        out.appendSlice(arena, buffer[0..@intCast(count)]) catch return null;
        if (out.items.len > 64 * 1024 * 1024) return null;
    }
    return out.items;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const test_env = Environment{ .entries = &.{ "TOKEN=tok", "EMPTY=", "HOME=/h" } };

fn testContext() Context {
    return .{ .cwd = "/repo/app", .workspace_root = "/repo", .env = test_env };
}

fn findServer(resolved: Resolved, name: []const u8) ?Server {
    for (resolved.servers) |server| if (std.mem.eql(u8, server.name, name)) return server;
    return null;
}

test "metacodes, Claude Code and Codex sources resolve with whole-entry precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolved = try resolve(arena.allocator(), .{
        .metacodes_config = .{ .path = "/state/config.json", .bytes =
        \\{"mcpServers":{"shared":{"command":"meta-bin","args":["--meta"]},
        \\               "off":{"enabled":false}},
        \\ "mcp_servers":[{"name":"legacy","command":["/abs/legacy","--flag"]}]}
        },
        .claude_json = .{ .path = "/home/.claude.json", .bytes =
        \\{"mcpServers":{"shared":{"command":"claude-bin"},"off":{"command":"x"},
        \\   "user":{"type":"stdio","command":"npx","args":["-y","pkg"],"env":{"T":"${TOKEN}","D":"${MISSING:-dflt}","E":"${EMPTY:-was-empty}"}},
        \\   "remote":{"type":"http","url":"https://h/mcp","headers":{"X":"${TOKEN}"}}},
        \\ "projects":{"/repo/app":{"mcpServers":{"local":{"command":"loc"}}}}}
        },
        .codex_user_config = .{ .path = "/home/.codex/config.toml", .bytes =
        \\[mcp_servers.shared]
        \\command = "codex-bin"
        \\[mcp_servers.codexonly]
        \\command = "c"
        \\env = { LIT = "${TOKEN}" }
        \\tool_timeout_sec = 12
        \\enabled_tools = ["a"]
        },
    }, testContext());

    const shared = findServer(resolved, "shared").?;
    try testing.expectEqual(Origin.metacodes, shared.origin);
    try testing.expectEqualStrings("meta-bin", shared.transport.stdio.command);
    try testing.expectEqual(EnvPolicy.allowlist, shared.transport.stdio.env_policy);
    try testing.expect(findServer(resolved, "off") == null);
    try testing.expectEqual(@as(usize, 1), resolved.disabled.len);

    const legacy = findServer(resolved, "legacy").?;
    try testing.expectEqualStrings("/abs/legacy", legacy.transport.stdio.command);
    try testing.expectEqualStrings("--flag", legacy.transport.stdio.args[0]);

    const user = findServer(resolved, "user").?;
    try testing.expectEqual(EnvPolicy.inherit, user.transport.stdio.env_policy);
    try testing.expectEqualStrings("tok", user.transport.stdio.env[0].value);
    try testing.expectEqualStrings("dflt", user.transport.stdio.env[1].value);
    try testing.expectEqualStrings("was-empty", user.transport.stdio.env[2].value);
    try testing.expectEqual(Origin.claude_local, findServer(resolved, "local").?.origin);
    try testing.expectEqualStrings("tok", findServer(resolved, "remote").?.transport.http.headers[0].value);

    const codex = findServer(resolved, "codexonly").?;
    try testing.expectEqualStrings("${TOKEN}", codex.transport.stdio.env[0].value);
    try testing.expectEqual(@as(?u32, 12_000), codex.tool_timeout_ms);
    try testing.expectEqualStrings("a", codex.enabled_tools.?[0]);
    try testing.expectEqual(@as(?u32, null), user.tool_timeout_ms);
    try testing.expectEqual(DEFAULT_STARTUP_TIMEOUT_MS, user.startup_timeout_ms);
}

test "project .mcp.json servers need approval and rejections win" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const project = Document{ .path = "/repo/.mcp.json", .bytes =
        \\{"mcpServers":{"approved":{"command":"a"},"rejected":{"command":"r"},"unknown":{"command":"u"}}}
    };
    const resolved = try resolve(arena.allocator(), .{
        .project_mcp_json = project,
        .claude_settings = &.{
            .{ .path = "/repo/.claude/settings.local.json", .bytes = "{\"enabledMcpjsonServers\":[\"approved\",\"rejected\"]}", .may_approve = true },
            // The shared file cannot approve, but its rejection applies.
            .{ .path = "/repo/.claude/settings.json", .bytes = "{\"enableAllProjectMcpServers\":true,\"disabledMcpjsonServers\":[\"rejected\"]}", .may_approve = false },
        },
    }, testContext());
    try testing.expect(findServer(resolved, "approved") != null);
    try testing.expect(findServer(resolved, "rejected") == null);
    try testing.expect(findServer(resolved, "unknown") == null);
    try testing.expectEqual(@as(usize, 2), resolved.pending.len);

    const all = try resolve(arena.allocator(), .{
        .metacodes_config = .{ .path = "/state/config.json", .bytes = "{\"enableAllProjectMcpServers\":true}" },
        .project_mcp_json = project,
    }, testContext());
    try testing.expectEqual(@as(usize, 3), all.servers.len);
}

test "Codex project layers load only for trusted projects; imports can be turned off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const project_toml = Document{ .path = "/repo/.codex/config.toml", .bytes = "[mcp_servers.proj]\ncommand = \"p\"\n" };
    const untrusted = try resolve(arena.allocator(), .{
        .codex_user_config = .{ .path = "/home/.codex/config.toml", .bytes = "model = \"x\"\n" },
        .codex_project_configs = &.{project_toml},
    }, testContext());
    try testing.expect(findServer(untrusted, "proj") == null);
    try testing.expectEqual(@as(usize, 1), untrusted.problems.len);

    const trusted = try resolve(arena.allocator(), .{
        .codex_user_config = .{ .path = "/home/.codex/config.toml", .bytes = "[projects.\"/repo\"]\ntrust_level = \"trusted\"\n" },
        .codex_project_configs = &.{project_toml},
    }, testContext());
    try testing.expectEqual(Origin.codex_project, findServer(trusted, "proj").?.origin);

    const off = try resolve(arena.allocator(), .{
        .metacodes_config = .{ .path = "/state/config.json", .bytes = "{\"mcpImport\":{\"claude\":false,\"codex\":false}}" },
        .claude_json = .{ .path = "/home/.claude.json", .bytes = "{\"mcpServers\":{\"c\":{\"command\":\"c\"}}}" },
        .codex_user_config = .{ .path = "/home/.codex/config.toml", .bytes = "[mcp_servers.x]\ncommand = \"x\"\n" },
    }, testContext());
    try testing.expectEqual(@as(usize, 0), off.servers.len);
}

test "malformed sources and entries are reported, never silently dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolved = try resolve(arena.allocator(), .{
        .metacodes_config = .{ .path = "/state/config.json", .bytes =
        \\{"mcpServers":{"bad name!":{"command":"x"},"nocmd":{"args":[]},"ws":{"type":"ws","url":"ws://h"},
        \\  "ok":{"command":"o","unknownField":1}}}
        },
        .claude_json = .{ .path = "/home/.claude.json", .bytes = "{not json" },
        .codex_user_config = .{ .path = "/home/.codex/config.toml", .bytes = "[mcp_servers.t]\nurl = \n" },
    }, testContext());
    try testing.expectEqual(@as(usize, 1), resolved.servers.len);
    try testing.expect(resolved.problems.len >= 5);
}

test "type sse selects the HTTP+SSE wire and oauth settings are read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolved = try resolve(arena.allocator(), .{
        .metacodes_config = .{ .path = "/state/config.json", .bytes =
        \\{"mcpServers":{
        \\  "linear":{"type":"sse","url":"https://mcp.example/sse"},
        \\  "docs":{"type":"http","url":"https://docs.example/mcp","scopes":["read","write"],
        \\          "oauth":{"clientId":"${TOKEN}","callbackPort":8123,"authServerMetadataUrl":"https://as.example/.well-known/oauth-authorization-server"}},
        \\  "badport":{"url":"https://b.example/mcp","oauth":{"callbackPort":70000,"clientSecret":"s"}}}}
        },
        .codex_user_config = .{ .path = "/home/.codex/config.toml", .bytes =
        \\[mcp_servers.cx]
        \\url = "https://cx.example/mcp"
        \\scopes = ["a", "b"]
        },
    }, testContext());
    const linear = findServer(resolved, "linear").?.transport.http;
    try testing.expectEqual(HttpWire.legacy_sse, linear.wire);
    try testing.expect(linear.oauth.client_id == null);

    const docs = findServer(resolved, "docs").?.transport.http;
    try testing.expectEqual(HttpWire.streamable, docs.wire);
    try testing.expectEqualStrings("tok", docs.oauth.client_id.?);
    try testing.expectEqual(@as(?u16, 8123), docs.oauth.callback_port);
    try testing.expectEqualStrings("read write", docs.oauth.scopes.?);
    try testing.expectEqualStrings("https://as.example/.well-known/oauth-authorization-server", docs.oauth.auth_server_metadata_url.?);

    // A bad port and a configured secret are reported, not guessed at.
    const badport = findServer(resolved, "badport").?.transport.http;
    try testing.expect(badport.oauth.callback_port == null);
    try testing.expectEqual(@as(usize, 2), resolved.problems.len);

    try testing.expectEqualStrings("a b", findServer(resolved, "cx").?.transport.http.oauth.scopes.?);
}

test "server names follow Codex's grammar" {
    try testing.expect(validServerName("my.server@org/v2:x-y_z"));
    try testing.expect(!validServerName("has space"));
    try testing.expect(!validServerName(""));
}
