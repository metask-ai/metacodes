//! `metacodes providers …`: model APIs of the user's own — a relay, a company
//! gateway, a server on this machine (Ollama, vLLM) — defined in
//! `<state root>/config.json` under `custom_providers.<id>` without writing
//! the JSON by hand. `provider/custom_provider.zig` owns the schema; this is
//! the command line in front of it.
//!
//! - `add <id> --base-url <url> --protocol <wire> …` writes one definition;
//!   with no arguments at a terminal it asks for each part instead. The
//!   document is checked the way `--check-providers` checks it before a byte
//!   is written, inside the store's lock (`config_store.putCustomProvider`).
//! - `probe <id> | --base-url <url> --protocol <wire>` asks the endpoint which
//!   models it serves (`api/model_probe.zig`) and stores nothing.
//! - `list` shows the definitions and where each one's key comes from.
//! - `remove <id>` removes the definition, its settings (`providers.<id>`),
//!   its stored key and login, and a stored default that was one of its
//!   models.
//!
//! A session reads `custom_providers` once, when it starts (`Host.create`),
//! so every change here applies from the next start, and each command says
//! so. The id is permanent once written — offers, a stored default and
//! session records name it — while `add <id> --replace` changes anything
//! else.

const std = @import("std");
const pfs = @import("platform").fs;
const ids = @import("../provider/ids.zig");
const profile_mod = @import("../provider/profile.zig");
const custom_provider = @import("../provider/custom_provider.zig");
const config_store = @import("../provider/config_store.zig");
const config_doc = @import("../provider/config_doc.zig");
const provider_host = @import("../provider/host.zig");
const credential = @import("../provider/credential.zig");
const api_key_store = @import("../provider/api_key_store.zig");
const provider_oauth = @import("../provider/oauth.zig");
const model_listing = @import("../provider/model_listing.zig");
const selection_mod = @import("../provider/selection.zig");
const registry_mod = @import("../provider/registry.zig");
const Vendor = @import("../provider/vendor.zig").Vendor;
const model_probe = @import("../api/model_probe.zig");
const dialect_registry = @import("../api/dialects/registry.zig");
const state_env = @import("state_env.zig");
const prompt = @import("terminal_prompt.zig");
const time = @import("../util/time.zig");

const Slug = ids.Slug;
const Wire = model_listing.Wire;

const USAGE =
    \\usage: metacodes providers add <id> --base-url <url> --protocol <wire> [--protocol <wire>[=<url>]]...
    \\                           [--model <model>]... [--probe] [--display-name <name>]
    \\                           [--key-env <VAR>] [--auth bearer|header:<name>[:<prefix>]]
    \\                           [--dialect <vendor>] [--subscription-plan] [--replace]
    \\       metacodes providers add                 (at a terminal: asks for each part)
    \\       metacodes providers probe <id>
    \\       metacodes providers probe --base-url <url> --protocol <wire> [--auth ...] [--key-env <VAR> | --api-key-stdin]
    \\       metacodes providers list
    \\       metacodes providers remove <id>
    \\
;

const HELP = USAGE ++
    \\
    \\A provider of your own: a relay, a company gateway, a server on this machine
    \\(Ollama, vLLM). `add` writes it to <state root>/config.json under
    \\custom_providers.<id>, after checking the whole file the way
    \\`metacodes --check-providers` does; it applies from the next start.
    \\
    \\  <id>            Lowercase letters, digits, '-', '_', '.'. Permanent: to rename
    \\                  one, add a new one and remove the old.
    \\  --base-url      Where the API is: https, or plain http to this machine only
    \\                  (127.0.0.1, localhost, ::1). No user name or password in it.
    \\  --protocol      openai_chat, openai_responses, anthropic_messages,
    \\                  gemini_generate_content or bedrock_converse. Repeat it for a
    \\                  relay that serves several: one provider, one channel each.
    \\                  wire=<url> gives that one its own address. Anthropic and Gemini
    \\                  addresses work with or without their /v1 or /v1beta.
    \\  --model         A model to offer; repeat it.
    \\  --probe         Ask the endpoint which models it serves. At a terminal you pick
    \\                  from the list (and paste the key; Enter, for a server on this
    \\                  machine that needs none, stores the placeholder `none`);
    \\                  elsewhere give --model and the probe checks the ids.
    \\  --display-name  What /model calls it (the id otherwise).
    \\  --key-env       The variable its key is read from, in your shell or in
    \\                  <state root>/.env. Or store the key with
    \\                  `metacodes login --provider <id>` (<state root>/keys/<id>.json).
    \\  --auth          How the key is sent: bearer (the default; gemini_generate_content
    \\                  alone defaults to x-goog-api-key), header:<name> such as
    \\                  header:x-api-key, or header:<name>:<prefix>.
    \\  --dialect       Whose models these are when their names do not say: openai,
    \\                  claude, gemini, glm, kimi, deepseek, qwen, minimax, mistral,
    \\                  openrouter.
    \\  --subscription-plan
    \\                  A coding plan licensed for interactive use (Bailian's, Ark's):
    \\                  a -p, serve or CI start on it prints a warning.
    \\  --replace       Change one that exists: only what you give changes, and what was
    \\                  written by hand (prices, limits, controls) stays.
    \\
    \\`probe` lists what the endpoint serves and stores nothing. `list` shows each
    \\definition and where its key comes from. `remove` removes the definition, its
    \\settings, its stored key and login, and a default model that was one of its.
    \\
;

/// Longest key a paste or stdin gives (`provider_login.MAX_KEY_LEN`).
const MAX_KEY_LEN = 512;
/// Longest base URL taken: it is stored and shown everywhere a route is.
const MAX_BASE_URL_LEN = 512;
/// Models a listing prints before it only counts the rest.
const MAX_PRINTED_MODELS = 400;

pub fn run(args: *std.process.Args.Iterator, gpa: std.mem.Allocator, io: std.Io, state_root: []const u8, command: []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rest: std.ArrayList([]const u8) = .empty;
    const sub = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    while (args.next()) |arg| rest.append(arena, arena.dupe(u8, arg) catch return outOfMemory()) catch return outOfMemory();
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "help")) {
        stdoutWrite(HELP);
        return 0;
    }
    for (rest.items) |arg| if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        stdoutWrite(HELP);
        return 0;
    };
    if (state_root.len == 0) {
        std.debug.print("error: no state root; pass --state-dir or set METACODES_HOME\n", .{});
        return 1;
    }
    const cli = Cli{ .gpa = gpa, .arena = arena, .io = io, .state_root = state_root, .command = command };
    if (std.mem.eql(u8, sub, "add")) return cli.add(rest.items);
    if (std.mem.eql(u8, sub, "probe")) return cli.probe(rest.items);
    if (std.mem.eql(u8, sub, "list")) {
        if (rest.items.len > 0) return unknownArgument(rest.items[0]);
        return cli.list();
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (rest.items.len != 1) {
            std.debug.print("usage: metacodes providers remove <id>\n", .{});
            return 2;
        }
        return cli.remove(rest.items[0]);
    }
    std.debug.print("error: unknown providers subcommand '{s}'\n{s}", .{ sub, USAGE });
    return 2;
}

// ── the parts of a definition, from arguments or answers ─────────────────────

const ChannelArg = struct { wire: Wire, base_url: ?[]const u8 = null };

const AddArgs = struct {
    id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    channels: std.ArrayList(ChannelArg) = .empty,
    dialect: ?Vendor = null,
    key_env: ?[]const u8 = null,
    auth: ?profile_mod.AuthScheme = null,
    models: std.ArrayList([]const u8) = .empty,
    probe: bool = false,
    replace: bool = false,
    subscription_plan: bool = false,
    /// A key pasted at a terminal: for the probe, then stored.
    pasted_key: ?[]const u8 = null,
    /// The server needs no key: the step-by-step `add`'s "none", or Enter at
    /// the probe's key prompt. `no_key_placeholder` goes in its place, to the
    /// probe and into the key file.
    no_key: bool = false,
    /// The key question was answered already (the step-by-step `add`): the
    /// probe asks no second time, even when the answer was "none".
    key_answered: bool = false,
};

/// What a provider whose server needs no key (Ollama, vLLM started without
/// `--api-key`) stores as its key. A request is bound only with a credential,
/// so a provider without one does not start and `/model` does not list it;
/// such a server ignores the `Authorization` header this is sent in.
pub const no_key_placeholder = "none";

/// The channel id of the channel speaking `wire`. One per wire, named by it,
/// so adding a second protocol later never renames the first channel (offer
/// ids, and a stored default, are derived from it).
fn channelIdFor(wire: Wire) []const u8 {
    return switch (wire) {
        .openai_chat => "openai",
        .openai_responses => "responses",
        .anthropic_messages => "anthropic",
        .gemini_generate_content => "gemini",
        .bedrock_converse => "bedrock",
    };
}

const WIRE_HELP = [_]struct { wire: Wire, label: []const u8 }{
    .{ .wire = .openai_chat, .label = "OpenAI Chat Completions: most relays, Ollama, vLLM" },
    .{ .wire = .openai_responses, .label = "OpenAI Responses" },
    .{ .wire = .anthropic_messages, .label = "Anthropic Messages" },
    .{ .wire = .gemini_generate_content, .label = "Google Gemini API" },
    .{ .wire = .bedrock_converse, .label = "Amazon Bedrock Converse" },
};

/// `--protocol wire` or `--protocol wire=url`.
fn parseChannelArg(text: []const u8) ?ChannelArg {
    const split = std.mem.indexOfScalar(u8, text, '=');
    const wire = Wire.parse(if (split) |at| text[0..at] else text) orelse return null;
    return .{ .wire = wire, .base_url = if (split) |at| text[at + 1 ..] else null };
}

/// `bearer`, `header:<name>`, or `header:<name>:<prefix>`.
fn parseAuth(text: []const u8) ?profile_mod.AuthScheme {
    if (std.mem.eql(u8, text, "bearer")) return .bearer;
    const rest = if (std.mem.startsWith(u8, text, "header:")) text["header:".len..] else return null;
    const split = std.mem.indexOfScalar(u8, rest, ':');
    const name = if (split) |at| rest[0..at] else rest;
    if (!isHeaderName(name)) return null;
    if (split) |at| return .{ .custom_header = .{ .name = name, .value_prefix = rest[at + 1 ..] } };
    return .{ .api_key_header = name };
}

/// An HTTP field name (RFC 9110 `token`).
fn isHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
        if (!ok) return false;
    }
    return true;
}

fn authText(arena: std.mem.Allocator, auth: profile_mod.AuthScheme) []const u8 {
    return switch (auth) {
        .bearer => "bearer token",
        .api_key_header => |name| std.fmt.allocPrint(arena, "{s} header", .{name}) catch "a header",
        .custom_header => |custom| std.fmt.allocPrint(arena, "{s} header", .{custom.name}) catch "a header",
        .signed_adapter => "a signed request",
    };
}

/// Why `--key-env <name>` is refused, or null.
fn keyEnvProblem(arena: std.mem.Allocator, host: *provider_host.Host, name: []const u8, id: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > 64) return "a variable name of 1 to 64 characters";
    for (name, 0..) |c, i| {
        const ok = c == '_' or std.ascii.isAlphabetic(c) or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return "letters, digits and '_', not starting with a digit";
    }
    // `.env` never sets an address, so a variable named like one is never
    // read from it (`state_env.isRequestAddress`).
    if (state_env.isRequestAddress(name)) return "a name ending in _URL is never read from .env";
    if (std.ascii.startsWithIgnoreCase(name, "METACODES_") or std.ascii.startsWithIgnoreCase(name, "METASK_"))
        return "METACODES_* and METASK_* belong to metacodes itself";
    // A variable two providers read sends one key to both of them.
    for (host.registry.profiles.items) |profile| {
        if (profile.id.eqlText(id)) continue;
        for (profile.env_aliases) |alias| {
            if (!std.mem.eql(u8, alias.name, name)) continue;
            return std.fmt.allocPrint(arena, "{s} already reads it; a key there would go to {s} too. Pick a name of its own, such as {s}", .{
                profile.display_name, id, suggestedKeyEnv(arena, id),
            }) catch "another provider reads it";
        }
    }
    return null;
}

/// `my-relay` → `MY_RELAY_API_KEY`.
fn suggestedKeyEnv(arena: std.mem.Allocator, id: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (id) |c| out.append(arena, if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_') catch return "MY_PROVIDER_API_KEY";
    out.appendSlice(arena, "_API_KEY") catch return "MY_PROVIDER_API_KEY";
    return out.items;
}

/// Why `url` cannot be a channel's base, in the words the user acts on.
fn baseUrlProblem(url: []const u8) ?[]const u8 {
    if (url.len > MAX_BASE_URL_LEN) return "longer than any endpoint address needs";
    const policy: profile_mod.EndpointPolicy = .{};
    policy.validate(url) catch |err| return switch (err) {
        error.InsecureEndpoint => "plain http goes only to this machine (127.0.0.1, localhost, ::1); use https",
        error.CredentialInEndpoint => "it carries a user name or password; give the key with --key-env or `login --provider` instead",
        error.EncodedEndpointComponent => "it carries %-escapes; write the address plainly",
        error.MalformedEndpoint => "not an http(s) address with a host",
        else => @errorName(err),
    };
    return null;
}

// ── the commands ─────────────────────────────────────────────────────────────

const Cli = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    /// What the user ran (`metacodes-dev` for a development install), for
    /// the commands a message tells them to run next.
    command: []const u8,

    fn store(self: Cli) ?config_store.Store {
        return config_store.Store.initHome(self.gpa, self.state_root) catch |err| {
            std.debug.print("error: the configuration cannot be opened ({s})\n", .{@errorName(err)});
            return null;
        };
    }

    // ── add ──────────────────────────────────────────────────────────────

    fn add(self: Cli, argv: []const []const u8) u8 {
        var args: AddArgs = .{};
        if (argv.len == 0) {
            if (!prompt.interactive()) {
                std.debug.print("error: `providers add` needs <id>, --base-url and --protocol when there is no terminal to ask at\n{s}", .{USAGE});
                return 2;
            }
            return self.addInteractive();
        }
        if (parseAddArgs(self.arena, argv, &args)) |code| return code;
        return self.finishAdd(&args);
    }

    fn finishAdd(self: Cli, args: *AddArgs) u8 {
        const arena = self.arena;
        const id_text = args.id orelse {
            std.debug.print("error: name the provider: metacodes providers add <id> …\n", .{});
            return 2;
        };
        const id = Slug.parse(id_text) catch {
            std.debug.print("error: '{s}' cannot be an id: lowercase letters, digits, '-', '_' and '.', starting with a letter or digit, at most 64\n", .{id_text});
            return 2;
        };
        if (builtinNamed(id_text)) |builtin| {
            std.debug.print("error: '{s}' is {s}, a provider metacodes ships; a provider of your own needs another id\n", .{ id_text, builtin });
            return 2;
        }

        var file = self.store() orelse return 1;
        defer file.deinit();
        const text = file.readText() catch |err| {
            std.debug.print("error: {s} cannot be read ({s}); nothing was written\n", .{ file.path, @errorName(err) });
            return 1;
        };
        defer self.gpa.free(text);
        const section = customSection(arena, text) catch {
            std.debug.print("error: {s} is not a JSON object with a custom_providers object; nothing was written. `{s} --check-providers` says more.\n", .{ file.path, self.command });
            return 1;
        };
        const existing: ?[]const u8 = if (section) |object| entryText(arena, object, id_text) else null;
        if (existing != null and !args.replace) {
            std.debug.print("error: {s} already defines '{s}'. Change it with `{s} providers add {s} --replace …` (its id stays), or remove it first.\n", .{ file.path, id_text, self.command, id_text });
            return 2;
        }
        if (existing == null and args.replace) {
            std.debug.print("error: there is no '{s}' in {s} to replace; leave out --replace to add it\n", .{ id_text, file.path });
            return 2;
        }
        if (args.replace and args.display_name == null and args.auth == null and args.key_env == null and args.channels.items.len == 0 and
            args.dialect == null and args.models.items.len == 0 and !args.probe and !args.subscription_plan)
        {
            std.debug.print("error: --replace changes what you give with it (--display-name, --model, --protocol, …); nothing was given\n", .{});
            return 2;
        }

        // Built the way a session builds it, for the checks that need the
        // providers already configured (a key variable another one reads).
        const host = buildHost(self.gpa, &file) orelse {
            std.debug.print("error: the provider registry could not be built\n", .{});
            return 1;
        };
        defer host.destroy();
        if (args.key_env) |name| if (keyEnvProblem(arena, host, name, id_text)) |why| {
            std.debug.print("error: --key-env {s}: {s}\n", .{ name, why });
            return 2;
        };

        // The channels, each base checked as the endpoint policy will.
        var channels: std.ArrayList(custom_provider.DraftChannel) = .empty;
        for (args.channels.items, 0..) |channel, index| {
            for (args.channels.items[0..index]) |earlier| if (earlier.wire == channel.wire) {
                std.debug.print("error: --protocol {s} is given twice\n", .{@tagName(channel.wire)});
                return 2;
            };
            const typed = channel.base_url orelse args.base_url orelse {
                std.debug.print("error: --protocol {s} needs an address: --base-url <url>, or --protocol {s}=<url>\n", .{ @tagName(channel.wire), @tagName(channel.wire) });
                return 2;
            };
            if (baseUrlProblem(typed)) |why| {
                std.debug.print("error: {s} cannot be an endpoint: {s}. Nothing was written.\n", .{ typed, why });
                return 2;
            }
            channels.append(arena, .{
                .id = channelIdFor(channel.wire),
                .base_url = arena.dupe(u8, model_listing.channelBase(typed, channel.wire)) catch return outOfMemory(),
                .wire = channel.wire,
                .dialect = args.dialect,
            }) catch return outOfMemory();
        }
        if (args.base_url != null and args.channels.items.len == 0) {
            std.debug.print("error: --base-url needs --protocol <wire> to say what it speaks: {s}\n", .{wireNames()});
            return 2;
        }
        if (existing == null and channels.items.len == 0) {
            std.debug.print("error: give its address and protocol: --base-url <url> --protocol <wire> ({s})\n", .{wireNames()});
            return 2;
        }
        if (channels.items.len > custom_provider.MAX_CHANNELS) {
            std.debug.print("error: at most {d} channels\n", .{custom_provider.MAX_CHANNELS});
            return 2;
        }

        // What the probe and the key check send the key with: what was
        // given, else what the definition already says, else the protocol's
        // own (a Gemini endpoint reads x-goog-api-key).
        const existing_profile = if (existing != null) host.registry.find(id_text) else null;
        var auth: ?profile_mod.AuthScheme = args.auth;
        if (auth == null and existing == null and channels.items.len > 0) {
            const gemini_only = for (channels.items) |channel| {
                if (channel.wire != .gemini_generate_content) break false;
            } else true;
            if (gemini_only) auth = .{ .custom_header = .{ .name = "x-goog-api-key" } };
        }
        const sent_with: profile_mod.AuthScheme = auth orelse if (existing_profile) |profile| profile.auth else .bearer;

        // A stored key goes with the definition: one that would now be sent
        // to an address it was never stored for is refused here, before the
        // key leaves the machine for a host its owner did not choose. The old
        // addresses are read from the definition as written, not from the
        // loaded profile: a definition that does not load (a hand edit gone
        // wrong) must not let a `--replace` that mends it skip this check.
        if (existing) |current| if (channels.items.len > 0 and self.storedKeyExists(id)) {
            if (newOrigin(storedOrigins(arena, current), channels.items)) |origin| {
                std.debug.print("error: a key is stored for '{s}' ({s}), and it would now go to {s}. Forget it first with `{s} logout --provider {s}`, then replace the address; nothing was written.\n", .{
                    id_text, self.keyPath(id), origin, self.command, id_text,
                });
                return 2;
            }
        };

        // The models: given, probed and picked, or both.
        var listed: ?model_listing.Listing = null;
        if (args.probe) {
            const target = probeTarget(channels.items, existing_profile) orelse {
                std.debug.print("error: no channel here has a model listing to ask (bedrock_converse has none); give the models with --model\n", .{});
                return 2;
            };
            if (args.models.items.len == 0 and !prompt.interactive()) {
                std.debug.print("error: --probe without a terminal cannot ask which models to add; name them with --model (`{s} providers probe` lists them)\n", .{self.command});
                return 2;
            }
            const key = self.probeKey(args, existing_profile) catch |err| return keyReadFailure(err);
            const result = model_probe.probe(arena, self.io, .{
                .base_url = target.base_url,
                .wire = target.wire,
                .secret = if (key) |k| k.secret else null,
                .auth = sent_with,
            }) catch return outOfMemory();
            switch (result.outcome) {
                .listed => |listing| {
                    listed = listing;
                    std.debug.print("{s} lists {d} model(s).\n", .{ result.url.?, listing.models.len + listing.dropped });
                },
                .refused => |status| {
                    if (args.no_key) {
                        std.debug.print("error: {s} answered {d}: it wants a real key (it refused the placeholder `{s}`); nothing was written. Paste its key, or give it with --key-env <VAR>.\n", .{ result.url.?, status, no_key_placeholder });
                    } else if (key != null) {
                        std.debug.print("error: {s} answered {d}: it refused the key; nothing was written. Check the key, and how it is sent ({s}; --auth changes it).\n", .{ result.url.?, status, authText(arena, sent_with) });
                    } else {
                        std.debug.print("error: {s} answered {d}: it wants a key; nothing was written. Give it with --key-env <VAR>, or run this at a terminal to paste it.\n", .{ result.url.?, status });
                    }
                    return 1;
                },
                else => {
                    const why = probeFailure(arena, result);
                    if (args.models.items.len == 0) {
                        std.debug.print("error: {s}; nothing was written. Name the models with --model instead.\n", .{why});
                        return 1;
                    }
                    std.debug.print("warning: {s}; the --model ids are written as given\n", .{why});
                },
            }
        }

        var models: std.ArrayList(custom_provider.DraftModel) = .empty;
        if (args.models.items.len == 0 and listed != null) {
            const picked = pickModels(arena, listed.?) orelse return 130;
            for (picked) |entry| models.append(arena, draftOf(entry)) catch return outOfMemory();
        }
        for (args.models.items) |model_id| {
            const trimmed = std.mem.trim(u8, model_id, " \t");
            if (trimmed.len == 0) continue;
            const seen = for (models.items) |model| {
                if (std.mem.eql(u8, model.request_model_id, trimmed)) break true;
            } else false;
            if (seen) continue;
            const entry = if (listed) |listing| findListed(listing, trimmed) else null;
            if (listed != null and entry == null) std.debug.print("warning: the endpoint does not list {s}; it is written as given\n", .{trimmed});
            models.append(arena, if (entry) |found| draftOf(found) else .{ .request_model_id = trimmed }) catch return outOfMemory();
        }
        if (existing == null and models.items.len == 0) {
            std.debug.print("error: name at least one model with --model, or ask the endpoint with --probe\n", .{});
            return 2;
        }
        if (models.items.len > custom_provider.MAX_MODELS) {
            std.debug.print("error: {d} models; a provider holds at most {d}\n", .{ models.items.len, custom_provider.MAX_MODELS });
            return 2;
        }

        const entry_json = if (existing) |current|
            custom_provider.patchEntry(self.gpa, current, .{
                .display_name = args.display_name,
                .subscription_plan = if (args.subscription_plan) true else null,
                .auth = args.auth,
                .key_env = args.key_env,
                .channels = if (channels.items.len > 0) channels.items else null,
                .dialect = args.dialect,
                .models = if (models.items.len > 0) models.items else null,
            }) catch {
                std.debug.print("error: its definition in {s} cannot be read; nothing was written\n", .{file.path});
                return 1;
            }
        else
            custom_provider.renderDraft(self.gpa, .{
                .display_name = args.display_name,
                .subscription_plan = args.subscription_plan,
                .auth = auth,
                .key_env = args.key_env,
                .channels = channels.items,
                .models = models.items,
            }) catch return outOfMemory();
        defer self.gpa.free(entry_json);

        var check = Check.init(self.gpa, text, id, .must_load);
        _ = config_store.putCustomProvider(&file, id, entry_json, check.validator(), null) catch |err| {
            if (err == error.Rejected) {
                check.report(file.path);
            } else {
                std.debug.print("error: {s} was not written ({s})\n", .{ file.path, @errorName(err) });
            }
            return 1;
        };

        const verb: []const u8 = if (existing != null) "Changed" else "Added";
        std.debug.print("{s} {s} in {s}", .{ verb, id_text, file.path });
        if (existing == null) std.debug.print(": {d} channel(s), {d} model(s)", .{ channels.items.len, models.items.len });
        std.debug.print(".\n", .{});
        for (channels.items) |channel| {
            std.debug.print("  {s}  {s}  {s}\n", .{ channel.id, @tagName(channel.wire), channel.base_url });
        }

        // A key pasted for the probe was checked by it; it is stored only now
        // that the definition it belongs to exists.
        var keyless = false;
        if (args.no_key) {
            // Nothing secret to confirm: the placeholder is stored whether or
            // not a probe ran, or the provider would not start.
            api_key_store.save(self.gpa, self.state_root, id, .api_key, no_key_placeholder, null, time.nowUnix()) catch |err| {
                std.debug.print("warning: the placeholder key was not stored ({s}); store `{s}` with `{s} login --provider {s}`\n", .{ @errorName(err), no_key_placeholder, self.command, id_text });
                return 1;
            };
            std.debug.print("Stored the placeholder `{s}` as its key in {s}: metacodes sends a key with every request, and a server that needs none ignores it.\n", .{ no_key_placeholder, self.keyPath(id) });
        } else if (args.pasted_key) |key| {
            if (listed == null) {
                std.debug.print("The pasted key was not stored: the endpoint did not confirm it. Store it with `{s} login --provider {s}`.\n", .{ self.command, id_text });
            } else {
                api_key_store.save(self.gpa, self.state_root, id, .api_key, key, null, time.nowUnix()) catch |err| {
                    std.debug.print("warning: the key was not stored ({s}); store it with `{s} login --provider {s}`\n", .{ @errorName(err), self.command, id_text });
                    return 1;
                };
                std.debug.print("Stored its key in {s}.\n", .{self.keyPath(id)});
            }
        } else if (args.key_env) |name| {
            std.debug.print("Its key is read from {s}: in your shell, or in {s}.\n", .{ name, self.envPath() });
        } else if (existing == null and !self.storedKeyExists(id)) {
            keyless = true;
            std.debug.print("It has no key yet: `{s} login --provider {s}` stores one (or add --key-env <VAR> with --replace). For a server on this machine that needs none, paste `{s}`.\n", .{ self.command, id_text, no_key_placeholder });
        }
        std.debug.print("This takes effect at the next start{s}: `{s} --provider {s}`, or choose it in /model. `{s} --check-providers` lists its routes without a request.\n", .{ if (keyless) ", once it has a key" else "", self.command, id_text, self.command });
        return 0;
    }

    /// The key the probe sends: a variable `--key-env` names, else the one
    /// the definition already resolves (as a session would), else at a
    /// terminal one the user pastes. Null asks without one.
    fn probeKey(self: Cli, args: *AddArgs, existing: ?*const profile_mod.ProviderProfile) !?ResolvedKey {
        if (args.pasted_key) |key| return .{ .secret = key, .from = "the pasted key" };
        if (args.no_key) return placeholderKey();
        if (args.key_env) |name| {
            if (self.variable(name)) |found| return found;
            std.debug.print("warning: {s} is not set in your shell or in {s}; the probe goes without a key\n", .{ name, self.envPath() });
            return null;
        }
        if (existing) |profile| if (self.resolveKey(profile)) |found| return found;
        if (args.key_answered or !prompt.interactive()) return null;
        var buffer: [MAX_KEY_LEN]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        const len = prompt.readSecretLine("Paste the API key (it is not shown; Enter if it needs none): ", &buffer) catch |err| {
            std.debug.print("\n", .{});
            return err;
        };
        std.debug.print("\n", .{});
        const key = std.mem.trim(u8, buffer[0..len], " \t\r\n");
        if (key.len == 0) {
            args.no_key = true;
            std.debug.print("No key, then: the placeholder `{s}` stands in for one (a server that needs none ignores it).\n", .{no_key_placeholder});
            return placeholderKey();
        }
        const owned = try self.arena.dupe(u8, key);
        args.pasted_key = owned;
        return .{ .secret = owned, .from = "the pasted key" };
    }

    fn placeholderKey() ResolvedKey {
        return .{ .secret = no_key_placeholder, .from = "the placeholder " ++ no_key_placeholder };
    }

    // ── probe ────────────────────────────────────────────────────────────

    fn probe(self: Cli, argv: []const []const u8) u8 {
        const arena = self.arena;
        var id: ?[]const u8 = null;
        var base_url: ?[]const u8 = null;
        var channel_args: std.ArrayList(ChannelArg) = .empty;
        var auth: ?profile_mod.AuthScheme = null;
        var key_env: ?[]const u8 = null;
        var key_from_stdin = false;
        var index: usize = 0;
        while (index < argv.len) : (index += 1) {
            const arg = argv[index];
            if (std.mem.eql(u8, arg, "--base-url")) {
                base_url = valueOf(argv, &index) orelse return missingValue(arg);
            } else if (std.mem.eql(u8, arg, "--protocol")) {
                const value = valueOf(argv, &index) orelse return missingValue(arg);
                channel_args.append(arena, parseChannelArg(value) orelse return unknownWire(value)) catch return outOfMemory();
            } else if (std.mem.eql(u8, arg, "--auth")) {
                const value = valueOf(argv, &index) orelse return missingValue(arg);
                auth = parseAuth(value) orelse return badAuth(value);
            } else if (std.mem.eql(u8, arg, "--key-env")) {
                key_env = valueOf(argv, &index) orelse return missingValue(arg);
            } else if (std.mem.eql(u8, arg, "--api-key-stdin")) {
                key_from_stdin = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                return unknownArgument(arg);
            } else if (id == null) {
                id = arg;
            } else return unknownArgument(arg);
        }
        if (key_env != null and key_from_stdin) {
            std.debug.print("error: give the key with --key-env or --api-key-stdin, not both\n", .{});
            return 2;
        }

        var key: ?ResolvedKey = null;
        if (key_from_stdin) {
            var buffer: [MAX_KEY_LEN]u8 = undefined;
            defer std.crypto.secureZero(u8, &buffer);
            const len = prompt.readLine(&buffer) catch {
                std.debug.print("error: the key could not be read from stdin\n", .{});
                return 1;
            };
            const trimmed = std.mem.trim(u8, buffer[0..len], " \t\r\n");
            if (trimmed.len == 0) {
                std.debug.print("error: stdin held no key\n", .{});
                return 2;
            }
            key = .{ .secret = arena.dupe(u8, trimmed) catch return outOfMemory(), .from = "the key from stdin" };
        } else if (key_env) |name| {
            key = self.variable(name) orelse {
                std.debug.print("error: {s} is not set in your shell or in {s}\n", .{ name, self.envPath() });
                return 2;
            };
        }

        var targets: std.ArrayList(Target) = .empty;
        var sent_with: profile_mod.AuthScheme = auth orelse .bearer;
        if (id) |name| {
            if (base_url != null or channel_args.items.len > 0) {
                std.debug.print("error: probe either a provider by id or an address with --base-url and --protocol, not both\n", .{});
                return 2;
            }
            if (builtinNamed(name)) |builtin| {
                std.debug.print("error: {s} is a provider metacodes ships, and its models come with it (see /model); probe asks the providers you added\n", .{builtin});
                return 2;
            }
            var file = self.store() orelse return 1;
            defer file.deinit();
            const host = buildHost(self.gpa, &file) orelse return 1;
            defer host.destroy();
            const profile = host.registry.find(name) orelse {
                std.debug.print("error: no provider '{s}' is configured. `{s} providers list` shows them; `{s} --check-providers` says why one does not load.\n", .{ name, self.command, self.command });
                return 1;
            };
            // Copied: the host and the strings it holds go before the requests.
            if (auth == null) sent_with = copyAuth(arena, profile.auth) catch return outOfMemory();
            if (key == null) key = self.resolveKey(profile);
            for (profile.channels) |channel| {
                const wire = channel.routes[0].protocol.wire() orelse continue;
                targets.append(arena, .{ .label = std.fmt.allocPrint(arena, "{s}/{s}", .{ name, channel.id.slice() }) catch return outOfMemory(), .base_url = arena.dupe(u8, channel.base_url) catch return outOfMemory(), .wire = wire }) catch return outOfMemory();
            }
            // Copied out: the host goes before the requests.
        } else {
            if (channel_args.items.len == 0 or (base_url == null and channel_args.items[0].base_url == null)) {
                std.debug.print("error: probe <id>, or --base-url <url> --protocol <wire> ({s})\n", .{wireNames()});
                return 2;
            }
            if (auth == null) {
                const gemini_only = for (channel_args.items) |channel| {
                    if (channel.wire != .gemini_generate_content) break false;
                } else true;
                if (gemini_only) sent_with = .{ .custom_header = .{ .name = "x-goog-api-key" } };
            }
            for (channel_args.items) |channel| {
                const typed = channel.base_url orelse base_url orelse {
                    std.debug.print("error: --protocol {s} needs an address\n", .{@tagName(channel.wire)});
                    return 2;
                };
                if (baseUrlProblem(typed)) |why| {
                    std.debug.print("error: {s} cannot be an endpoint: {s}\n", .{ typed, why });
                    return 2;
                }
                targets.append(arena, .{ .label = @tagName(channel.wire), .base_url = typed, .wire = channel.wire }) catch return outOfMemory();
            }
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        var any_listed = false;
        var asked: std.ArrayList([]const u8) = .empty;
        for (targets.items) |target| {
            const url = (model_listing.listingUrl(arena, target.base_url, target.wire) catch return outOfMemory()) orelse {
                out.writer.print("{s}: {s} has no model listing to ask\n", .{ target.label, @tagName(target.wire) }) catch {};
                continue;
            };
            // Two channels at one address list the same models.
            const repeat = for (asked.items) |earlier| {
                if (std.mem.eql(u8, earlier, url)) break true;
            } else false;
            if (repeat) continue;
            asked.append(arena, url) catch return outOfMemory();
            const result = model_probe.probe(arena, self.io, .{
                .base_url = target.base_url,
                .wire = target.wire,
                .secret = if (key) |k| k.secret else null,
                .auth = sent_with,
            }) catch return outOfMemory();
            switch (result.outcome) {
                .listed => |listing| {
                    any_listed = true;
                    out.writer.print("{s}: GET {s} lists {d} model(s)\n", .{ target.label, url, listing.models.len + listing.dropped }) catch {};
                    writeListing(&out.writer, listing);
                },
                .refused => |status| out.writer.print("{s}: GET {s} answered {d}: {s}\n", .{
                    target.label,
                    url,
                    status,
                    if (key != null) "the key was refused" else "it wants a key (--key-env <VAR>, --api-key-stdin, or `login --provider <id>`)",
                }) catch {},
                else => out.writer.print("{s}: {s}\n", .{ target.label, probeFailure(arena, result) }) catch {},
            }
        }
        if (key) |k| out.writer.print("Asked with {s}, sent as a {s}.\n", .{ k.from, authText(arena, sent_with) }) catch {} else out.writer.print("Asked without a key.\n", .{}) catch {};
        out.writer.print("Nothing was stored. A listing is a convenience: a model it leaves out still works when added with --model.\n", .{}) catch {};
        stdoutWrite(out.written());
        return if (any_listed) 0 else 1;
    }

    // ── list ─────────────────────────────────────────────────────────────

    fn list(self: Cli) u8 {
        const arena = self.arena;
        var file = self.store() orelse return 1;
        defer file.deinit();
        const text = file.readText() catch |err| {
            std.debug.print("error: {s} cannot be read ({s})\n", .{ file.path, @errorName(err) });
            return 1;
        };
        defer self.gpa.free(text);
        var definitions = custom_provider.parse(self.gpa, text) catch |err| {
            std.debug.print("custom_providers in {s} does not load ({s}): `{s} --check-providers` says more.\n", .{ file.path, @errorName(err), self.command });
            return 1;
        };
        defer definitions.deinit();
        var document = file.load() catch null;
        defer if (document) |*value| value.deinit();

        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        const profiles = definitions.profiles();
        if (profiles.len == 0) {
            w.print("No providers of your own in {s}. Add one: {s} providers add <id> --base-url <url> --protocol <wire> --model <model>\n", .{ file.path, self.command }) catch {};
            stdoutWrite(out.written());
            return 0;
        }
        for (profiles) |*profile| {
            w.print("{s}", .{profile.id.slice()}) catch {};
            if (!std.mem.eql(u8, profile.display_name, profile.id.slice())) w.print("  {s}", .{profile.display_name}) catch {};
            if (profile.subscription_plan) w.print("  (subscription plan)", .{}) catch {};
            if (document) |*value| if (value.provider(profile.id)) |entry| if (!entry.enabled) w.print("  (disabled: /providers enable {s})", .{profile.id.slice()}) catch {};
            w.print("\n", .{}) catch {};
            for (profile.channels) |channel| {
                w.print("  {s}  {s}  {s}\n", .{ channel.id.slice(), channel.routes[0].protocol.id(), channel.base_url }) catch {};
            }
            w.print("  models:", .{}) catch {};
            for (profile.models, 0..) |model, i| {
                if (i == 12) {
                    w.print(" … ({d} in all)", .{profile.models.len}) catch {};
                    break;
                }
                w.print("{s} {s}", .{ if (i == 0) "" else ",", model.request_model_id }) catch {};
            }
            w.print("\n  key:    {s}\n", .{self.keyDescription(profile)}) catch {};
        }
        w.print("{d} provider(s) of your own in {s}. A change applies at the next start; `{s} --check-providers` lists every route.\n", .{ profiles.len, file.path, self.command }) catch {};
        stdoutWrite(out.written());
        return 0;
    }

    /// Where `profile`'s key comes from, in the order a session reads them
    /// (`credential.resolve`): its variables (the shell, then `.env`), then
    /// the stored key. Names and paths, never a value.
    fn keyDescription(self: Cli, profile: *const profile_mod.ProviderProfile) []const u8 {
        const arena = self.arena;
        var parts: std.ArrayList(u8) = .empty;
        var used = false;
        for (profile.env_aliases) |alias| {
            const where: []const u8 = if (processEnv(arena, alias.name) != null)
                "set in the shell"
            else if (self.fileVariable(alias.name) != null)
                std.fmt.allocPrint(arena, "set in {s}", .{self.envPath()}) catch "set in .env"
            else
                "not set";
            const set = !std.mem.eql(u8, where, "not set");
            parts.print(arena, "{s}{s} ({s}{s})", .{ if (parts.items.len > 0) "; " else "", alias.name, where, if (set and !used) ", used" else "" }) catch {};
            if (set) used = true;
        }
        if (self.storedKeyExists(profile.id)) {
            parts.print(arena, "{s}stored in {s}{s}", .{ if (parts.items.len > 0) "; " else "", self.keyPath(profile.id), if (used) " (not used while a variable is set)" else ", used" }) catch {};
            used = true;
        }
        if (parts.items.len == 0) return std.fmt.allocPrint(arena, "none (`{s} login --provider {s}` stores one; for a server that needs none, paste `{s}`)", .{ self.command, profile.id.slice(), no_key_placeholder }) catch "none";
        return parts.items;
    }

    // ── remove ───────────────────────────────────────────────────────────

    fn remove(self: Cli, id_text: []const u8) u8 {
        const id = Slug.parse(id_text) catch {
            std.debug.print("error: '{s}' is not a provider id\n", .{id_text});
            return 2;
        };
        if (builtinNamed(id_text)) |builtin| {
            std.debug.print("error: {s} is a provider metacodes ships and cannot be removed. `/providers disable {s}` hides it; `{s} logout --provider {s}` forgets its key.\n", .{ builtin, id_text, self.command, id_text });
            return 2;
        }
        const removed = removeProvider(self.gpa, self.state_root, id) catch |err| {
            switch (err) {
                error.NotConfigured => std.debug.print("No provider '{s}' is configured here; nothing to remove.\n", .{id_text}),
                error.Rejected => std.debug.print("error: the configuration was not written: without '{s}' part of it would not load. `{s} --check-providers` shows the file as it is now.\n", .{ id_text, self.command }),
                else => std.debug.print("error: nothing was removed ({s})\n", .{@errorName(err)}),
            }
            return 1;
        };
        const where = if (config_store.Store.initHome(self.arena, self.state_root)) |value| value.path else |_| "config.json";
        if (removed.definition) std.debug.print("Removed {s} from {s}.\n", .{ id_text, where });
        if (removed.settings) std.debug.print("Removed its settings (providers.{s}).\n", .{id_text});
        if (removed.default_forgotten) std.debug.print("Forgot the default model, which was one of its.\n", .{});
        if (removed.key) std.debug.print("Removed its stored key ({s}).\n", .{self.keyPath(id)});
        if (removed.key_left) std.debug.print("warning: its stored key could not be removed: {s}\n", .{self.keyPath(id)});
        if (removed.login) std.debug.print("Removed its stored login (oauth/{s}.json); it was not revoked at the server.\n", .{id_text});
        if (removed.login_left) std.debug.print("warning: its stored login (oauth/{s}.json) could not be removed\n", .{id_text});
        std.debug.print("This takes effect at the next start; a session running now keeps it until then.\n", .{});
        return 0;
    }

    // ── interactive add ──────────────────────────────────────────────────

    fn addInteractive(self: Cli) u8 {
        const arena = self.arena;
        var args: AddArgs = .{};
        std.debug.print("A provider of your own: a relay, a gateway, a server on this machine. Nothing is written until the end; Ctrl+C stops.\n\n", .{});
        while (true) {
            const answer = ask(arena, "Id (lowercase, e.g. my-relay): ") orelse return 130;
            if (answer.len == 0) continue;
            if (Slug.parse(answer)) |_| {} else |_| {
                std.debug.print("  lowercase letters, digits, '-', '_' and '.', starting with a letter or digit\n", .{});
                continue;
            }
            if (builtinNamed(answer)) |builtin| {
                std.debug.print("  that is {s}, which metacodes ships; pick another\n", .{builtin});
                continue;
            }
            args.id = answer;
            break;
        }
        const name = ask(arena, std.fmt.allocPrint(arena, "Display name (Enter: {s}): ", .{args.id.?}) catch return outOfMemory()) orelse return 130;
        if (name.len > 0) args.display_name = name;
        while (true) {
            const answer = ask(arena, "Base URL (https://…, or http://127.0.0.1:<port>/… on this machine): ") orelse return 130;
            if (answer.len == 0) continue;
            if (baseUrlProblem(answer)) |why| {
                std.debug.print("  {s}\n", .{why});
                continue;
            }
            args.base_url = answer;
            break;
        }
        std.debug.print("Protocol:\n", .{});
        for (WIRE_HELP, 1..) |entry, n| std.debug.print("  {d}. {s:<24} {s}\n", .{ n, @tagName(entry.wire), entry.label });
        while (args.channels.items.len == 0) {
            const answer = ask(arena, "Choose (several: 1,3): ") orelse return 130;
            var parts = std.mem.tokenizeAny(u8, answer, ", ");
            var ok = true;
            while (parts.next()) |part| {
                const n = std.fmt.parseInt(usize, part, 10) catch 0;
                if (n < 1 or n > WIRE_HELP.len) {
                    ok = false;
                    break;
                }
                const wire = WIRE_HELP[n - 1].wire;
                const seen = for (args.channels.items) |channel| {
                    if (channel.wire == wire) break true;
                } else false;
                if (!seen) args.channels.append(arena, .{ .wire = wire }) catch return outOfMemory();
            }
            if (!ok) args.channels.clearRetainingCapacity();
        }
        std.debug.print("Key:\n  1. paste it now (stored in {s}/keys/{s}.json)\n  2. read it from a variable (in your shell, or in {s})\n  3. none (a server on this machine that needs none; the placeholder `{s}` is stored in its place)\n", .{ self.state_root, args.id.?, self.envPath(), no_key_placeholder });
        var key_choice: usize = 0;
        while (key_choice == 0) {
            const answer = ask(arena, "Choose [1-3]: ") orelse return 130;
            key_choice = std.fmt.parseInt(usize, answer, 10) catch 0;
            if (key_choice > 3) key_choice = 0;
        }
        const host = self.hostFor() orelse return 1;
        defer host.destroy();
        switch (key_choice) {
            1 => {
                var buffer: [MAX_KEY_LEN]u8 = undefined;
                defer std.crypto.secureZero(u8, &buffer);
                const len = prompt.readSecretLine("Paste the API key (it is not shown) and press Enter: ", &buffer) catch |err| {
                    std.debug.print("\n", .{});
                    return keyReadFailure(err);
                };
                std.debug.print("\n", .{});
                const key = std.mem.trim(u8, buffer[0..len], " \t\r\n");
                if (key.len > 0) args.pasted_key = arena.dupe(u8, key) catch return outOfMemory();
            },
            2 => while (true) {
                const suggested = suggestedKeyEnv(arena, args.id.?);
                const answer = ask(arena, std.fmt.allocPrint(arena, "Variable name (Enter: {s}): ", .{suggested}) catch return outOfMemory()) orelse return 130;
                const chosen = if (answer.len == 0) suggested else answer;
                if (keyEnvProblem(arena, host, chosen, args.id.?)) |why| {
                    std.debug.print("  {s}\n", .{why});
                    continue;
                }
                args.key_env = chosen;
                break;
            },
            else => args.no_key = true,
        }
        args.key_answered = true;
        const probe_answer = ask(arena, "Ask the endpoint which models it serves? [Y/n]: ") orelse return 130;
        args.probe = probe_answer.len == 0 or std.ascii.toLower(probe_answer[0]) == 'y';
        if (!args.probe or args.channels.items[0].wire == .bedrock_converse) {
            args.probe = false;
            while (args.models.items.len == 0) {
                const answer = ask(arena, "Model ids, separated by commas: ") orelse return 130;
                var parts = std.mem.tokenizeAny(u8, answer, ", ");
                while (parts.next()) |part| args.models.append(arena, part) catch return outOfMemory();
            }
            // Whose models: inferred from the names unless the user says.
            const kind = adapterKindOf(args.channels.items[0].wire);
            std.debug.print("Dialect (whose models they are), inferred from the names:", .{});
            for (args.models.items) |model| {
                const vendor = dialect_registry.infer(kind, model);
                std.debug.print(" {s} → {s};", .{ model, if (vendor) |v| v.name() else "the protocol's own" });
            }
            std.debug.print("\n", .{});
            while (true) {
                const answer = ask(arena, "Enter keeps that, or name one for all (openai, claude, gemini, glm, kimi, deepseek, qwen, minimax, mistral, openrouter): ") orelse return 130;
                if (answer.len == 0) break;
                args.dialect = Vendor.parse(answer) orelse {
                    std.debug.print("  not one of those\n", .{});
                    continue;
                };
                break;
            }
        }
        // The probe needs the key the user chose; a pasted one is already
        // in `pasted_key`, a variable is read by `probeKey`.
        return self.finishAdd(&args);
    }

    // ── keys ─────────────────────────────────────────────────────────────

    /// `profile`'s key as a session resolves it: its variables (the shell,
    /// then `.env`), then the stored key.
    fn resolveKey(self: Cli, profile: *const profile_mod.ProviderProfile) ?ResolvedKey {
        for (profile.env_aliases) |alias| {
            if (alias.kind != .api_key) continue;
            if (self.variable(alias.name)) |found| return found;
        }
        var stored = (api_key_store.load(self.gpa, self.state_root, profile.id) catch return null) orelse return null;
        defer stored.deinit();
        const secret = self.arena.dupe(u8, stored.secret) catch return null;
        return .{ .secret = secret, .from = std.fmt.allocPrint(self.arena, "the key stored in {s}", .{self.keyPath(profile.id)}) catch "the stored key" };
    }

    /// `name` from the shell, else from `<state root>/.env`.
    fn variable(self: Cli, name: []const u8) ?ResolvedKey {
        if (processEnv(self.arena, name)) |value| return .{ .secret = value, .from = std.fmt.allocPrint(self.arena, "{s} from the shell", .{name}) catch name };
        if (self.fileVariable(name)) |value| return .{ .secret = value, .from = std.fmt.allocPrint(self.arena, "{s} from {s}", .{ name, self.envPath() }) catch name };
        return null;
    }

    /// `name`'s value in `<state root>/.env`, read as a session reads it.
    fn fileVariable(self: Cli, name: []const u8) ?[]const u8 {
        const keys = [_]state_env.Allowlist.Key{.{ .name = name, .provider = "custom" }};
        var loaded = state_env.load(self.gpa, self.state_root, .{ .keys = &keys }) catch return null;
        defer loaded.deinit();
        const value = loaded.get(name) orelse return null;
        if (value.len == 0) return null;
        return self.arena.dupe(u8, value) catch null;
    }

    fn storedKeyExists(self: Cli, id: Slug) bool {
        const path = api_key_store.pathFor(self.arena, self.state_root, id) catch return false;
        const path_z = self.arena.dupeZ(u8, path) catch return false;
        return pfs.exists(path_z);
    }

    fn keyPath(self: Cli, id: Slug) []const u8 {
        return api_key_store.pathFor(self.arena, self.state_root, id) catch "keys/<id>.json";
    }

    fn envPath(self: Cli) []const u8 {
        return std.fs.path.join(self.arena, &.{ self.state_root, state_env.file_name }) catch ".env";
    }

    fn hostFor(self: Cli) ?*provider_host.Host {
        var file = self.store() orelse return null;
        defer file.deinit();
        return buildHost(self.gpa, &file);
    }
};

/// What `removeProvider` found and removed.
pub const Removal = struct {
    /// `custom_providers.<id>`.
    definition: bool = false,
    /// `providers.<id>`: enable state, credential references.
    settings: bool = false,
    /// The stored `/model` default, which was one of its models.
    default_forgotten: bool = false,
    /// `<state root>/keys/<id>.json`, and one that stayed (the file could
    /// not be removed).
    key: bool = false,
    key_left: bool = false,
    /// `<state root>/oauth/<id>.json`, removed here without a revocation.
    login: bool = false,
    login_left: bool = false,
    /// The configuration revision the write left, when there was one to
    /// write (`Kernel.adoptConfigRevision`).
    revision: ?config_store.ConfigRevision = null,
};

pub const RemoveError = error{
    /// Neither a definition, nor settings, nor a stored key or login:
    /// nothing to do.
    NotConfigured,
    /// Without it the rest of the file would not load (`Check`).
    Rejected,
    /// The configuration cannot be read or written.
    ConfigUnavailable,
    OutOfMemory,
};

/// Remove a provider the user configured, everything about it: its
/// definition, its settings, a stored default on one of its models (one
/// write, `config_store.removeCustomProvider`), then its stored key and
/// login. `metacodes providers remove` and the TUI's `/providers remove`
/// both end here, so neither leaves a definition that comes back at the next
/// start, nor a key that a later provider of the same id would send to its
/// own address.
pub fn removeProvider(gpa: std.mem.Allocator, state_root: []const u8, id: Slug) RemoveError!Removal {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var file = config_store.Store.initHome(gpa, state_root) catch return error.ConfigUnavailable;
    defer file.deinit();
    const text = file.readText() catch return error.ConfigUnavailable;
    defer gpa.free(text);
    const section = customSection(arena, text) catch return error.ConfigUnavailable;
    const defined = if (section) |object| object.get(id.slice()) != null else false;
    var document = file.load() catch return error.ConfigUnavailable;
    defer document.deinit();
    const settings = document.provider(id) != null;
    const key_path = api_key_store.pathFor(arena, state_root, id) catch return error.OutOfMemory;
    const stored_key = pfs.exists(arena.dupeZ(u8, key_path) catch return error.OutOfMemory);
    const stored_login = try storedLoginExists(arena, state_root, id);
    if (!defined and !settings and !stored_key and !stored_login) return error.NotConfigured;

    // A stored default on one of its models would name a route the next
    // start cannot find; resolved now, in the catalog that still has it.
    var forget: ?config_doc.RuntimeSelection = null;
    if (document.global_selection) |chosen| if (buildHost(gpa, &file)) |host| {
        defer host.destroy();
        if (selection_mod.resolve(host.kernel.catalogSnapshot(), chosen)) |resolution| {
            if (resolution.primary().provider_id.eql(id)) forget = chosen;
        } else |_| {}
    };

    var out: Removal = .{ .definition = defined };
    if (defined or settings or forget != null) {
        var check = Check.init(gpa, text, id, .may_go);
        const removed = config_store.removeCustomProvider(&file, id, forget, check.validator(), null) catch |err| return switch (err) {
            error.Rejected => error.Rejected,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConfigUnavailable,
        };
        out.settings = removed.settings;
        out.default_forgotten = removed.default_forgotten;
        out.revision = removed.result.config_revision;
    }
    if (stored_key) {
        if (api_key_store.remove(gpa, state_root, id)) |gone| {
            out.key = gone;
        } else |_| out.key_left = true;
    }
    if (provider_oauth.Session.removeStored(gpa, state_root, id)) |gone| {
        out.login = gone;
    } else |_| out.login_left = true;
    return out;
}

/// Whether a login is stored for `id`, at the path `Session.removeStored`
/// deletes (`oauth/<id>.json`, or under `METACODES_OAUTH_DIR`). The file is
/// looked for, not read: no refresh, no request. A login that outlived the
/// definition, the settings and the key is still there for `remove` to take.
fn storedLoginExists(arena: std.mem.Allocator, state_root: []const u8, id: Slug) error{OutOfMemory}!bool {
    const session = provider_oauth.Session.initHome(arena, state_root, id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return pfs.exists(try arena.dupeZ(u8, session.path));
}

/// Whether `<state root>/config.json` defines `id` under `custom_providers`.
pub fn isDefined(gpa: std.mem.Allocator, state_root: []const u8, id: Slug) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var file = config_store.Store.initHome(gpa, state_root) catch return false;
    defer file.deinit();
    const text = file.readText() catch return false;
    defer gpa.free(text);
    const section = (customSection(arena_state.allocator(), text) catch return false) orelse return false;
    return section.get(id.slice()) != null;
}

const ResolvedKey = struct {
    /// In the command's arena, or `no_key_placeholder`.
    secret: []const u8,
    /// Where it came from, for the line that says what the probe sent.
    from: []const u8,
};

const Target = struct { label: []const u8, base_url: []const u8, wire: Wire };

fn processEnv(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const name_z = arena.dupeZ(u8, name) catch return null;
    const raw = std.c.getenv(name_z) orelse return null;
    const value = std.mem.span(raw);
    if (value.len == 0) return null;
    return value;
}

/// The first channel with a model listing: the new ones when given, else the
/// definition's own.
fn probeTarget(channels: []const custom_provider.DraftChannel, existing: ?*const profile_mod.ProviderProfile) ?Target {
    for (channels) |channel| {
        if (channel.wire == .bedrock_converse) continue;
        return .{ .label = channel.id, .base_url = channel.base_url, .wire = channel.wire };
    }
    if (channels.len > 0) return null;
    const profile = existing orelse return null;
    for (profile.channels) |channel| {
        const wire = channel.routes[0].protocol.wire() orelse continue;
        if (wire == .bedrock_converse) continue;
        return .{ .label = channel.id.slice(), .base_url = channel.base_url, .wire = wire };
    }
    return null;
}

/// An origin among `new` that none of `old` has, rendered: where a stored
/// key would go for the first time.
fn newOrigin(old: []const []const u8, new: []const custom_provider.DraftChannel) ?[]const u8 {
    for (new) |channel| {
        const origin = originOf(channel.base_url);
        const known = for (old) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, origin)) break true;
        } else false;
        if (!known) return origin;
    }
    return null;
}

/// The origins of the channels `entry_json` — one `custom_providers` member,
/// as written — names. Read from the text rather than from the loaded
/// profile, so a definition that does not load still says where its stored
/// key was meant to go. One whose channels cannot be read names none, and
/// every address is then new to it.
fn storedOrigins(arena: std.mem.Allocator, entry_json: []const u8) []const []const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, entry_json, .{}) catch return &.{};
    if (root != .object) return &.{};
    const channels = root.object.get("channels") orelse return &.{};
    if (channels != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (channels.array.items) |channel| {
        if (channel != .object) continue;
        const base = channel.object.get("base_url") orelse continue;
        if (base != .string) continue;
        out.append(arena, originOf(base.string)) catch break;
    }
    return out.items;
}

/// `scheme://host[:port]` of a URL.
fn originOf(url: []const u8) []const u8 {
    const after_scheme = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    const end = std.mem.indexOfScalarPos(u8, url, after_scheme, '/') orelse url.len;
    return url[0..end];
}

fn copyAuth(arena: std.mem.Allocator, auth: profile_mod.AuthScheme) error{OutOfMemory}!profile_mod.AuthScheme {
    return switch (auth) {
        .bearer => .bearer,
        .api_key_header => |name| .{ .api_key_header = try arena.dupe(u8, name) },
        .custom_header => |custom| .{ .custom_header = .{ .name = try arena.dupe(u8, custom.name), .value_prefix = try arena.dupe(u8, custom.value_prefix) } },
        .signed_adapter => |adapter| .{ .signed_adapter = try arena.dupe(u8, adapter) },
    };
}

/// The transport family `wire` reaches, as model-name inference names it.
fn adapterKindOf(wire: Wire) @import("../api/model_adapter.zig").ProviderKind {
    return switch (wire) {
        .anthropic_messages => .anthropic,
        .openai_chat, .openai_responses => .openai,
        .gemini_generate_content => .gemini,
        .bedrock_converse => .bedrock,
    };
}

fn draftOf(entry: model_listing.Listed) custom_provider.DraftModel {
    return .{
        .request_model_id = entry.id,
        .display_name = entry.name,
        .context_window = entry.context_window,
        .max_output_tokens = entry.max_output_tokens,
    };
}

fn findListed(listing: model_listing.Listing, id: []const u8) ?model_listing.Listed {
    for (listing.models) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

/// What a probe that listed nothing found, in a sentence.
fn probeFailure(arena: std.mem.Allocator, result: model_probe.Probe) []const u8 {
    const url = result.url orelse return "this protocol has no model listing to ask";
    return switch (result.outcome) {
        .listed, .no_listing => "",
        .refused => |status| std.fmt.allocPrint(arena, "{s} answered {d}", .{ url, status }) catch "refused",
        .status => |status| if (status >= 300 and status < 400)
            std.fmt.allocPrint(arena, "{s} answered {d}, a redirect, which is not followed with a key", .{ url, status }) catch "redirected"
        else
            std.fmt.allocPrint(arena, "{s} answered {d}", .{ url, status }) catch "failed",
        .unreadable => |err| std.fmt.allocPrint(arena, "{s} answered, but {s}", .{ url, switch (err) {
            error.NotJson => "not with JSON",
            error.NotAListing => "with neither a \"data\" array nor a \"models\" object",
            error.OutOfMemory => "with more than could be read",
        } }) catch "unreadable",
        .failed => |err| std.fmt.allocPrint(arena, "{s} could not be reached ({s})", .{ url, @errorName(err) }) catch "unreachable",
    };
}

fn writeListing(w: *std.Io.Writer, listing: model_listing.Listing) void {
    var widest: usize = 0;
    for (listing.models[0..@min(listing.models.len, MAX_PRINTED_MODELS)]) |entry| widest = @max(widest, entry.id.len);
    for (listing.models, 0..) |entry, i| {
        if (i == MAX_PRINTED_MODELS) {
            w.print("  … and {d} more\n", .{listing.models.len - MAX_PRINTED_MODELS}) catch {};
            break;
        }
        w.print("  {s}", .{entry.id}) catch {};
        for (entry.id.len..widest) |_| w.writeByte(' ') catch {};
        if (entry.name) |name| w.print("  {s}", .{name}) catch {};
        if (entry.context_window) |window| w.print("  ctx {d}", .{window}) catch {};
        if (entry.max_output_tokens) |tokens| w.print("  out {d}", .{tokens}) catch {};
        w.print("\n", .{}) catch {};
    }
    if (listing.dropped > 0) w.print("  … and {d} more past what is read\n", .{listing.dropped}) catch {};
}

/// At a terminal: show `listing`, ask which to add. Null when the user stops.
fn pickModels(arena: std.mem.Allocator, listing: model_listing.Listing) ?[]const model_listing.Listed {
    if (listing.models.len == 0) {
        std.debug.print("The endpoint lists no models.\n", .{});
        return null;
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    for (listing.models, 1..) |entry, n| {
        if (n > MAX_PRINTED_MODELS) break;
        out.writer.print("  {d:>3}. {s}", .{ n, entry.id }) catch {};
        if (entry.name) |name| out.writer.print("  {s}", .{name}) catch {};
        if (entry.context_window) |window| out.writer.print("  ctx {d}", .{window}) catch {};
        out.writer.print("\n", .{}) catch {};
    }
    std.debug.print("{s}", .{out.written()});
    const all_fit = listing.models.len <= custom_provider.MAX_MODELS;
    while (true) {
        const question = if (all_fit)
            std.fmt.allocPrint(arena, "Add which? Numbers and ranges (1,3,5-7), or Enter for all {d}: ", .{listing.models.len}) catch return null
        else
            std.fmt.allocPrint(arena, "Add which? Numbers and ranges (1,3,5-7), at most {d}: ", .{custom_provider.MAX_MODELS}) catch return null;
        const answer = ask(arena, question) orelse return null;
        if (answer.len == 0) {
            if (all_fit) return listing.models;
            continue;
        }
        if (selection(arena, answer, listing.models)) |picked| {
            if (picked.len > 0 and picked.len <= custom_provider.MAX_MODELS) return picked;
        }
        std.debug.print("  numbers from 1 to {d}, such as 1,3,5-7\n", .{listing.models.len});
    }
}

/// `1,3,5-7` over `models`, each once, in the order given; null when any
/// part is not a number or range within them.
fn selection(arena: std.mem.Allocator, text: []const u8, models: []const model_listing.Listed) ?[]const model_listing.Listed {
    var picked: std.ArrayList(model_listing.Listed) = .empty;
    var taken = std.DynamicBitSetUnmanaged.initEmpty(arena, models.len) catch return null;
    var parts = std.mem.tokenizeAny(u8, text, ", ");
    while (parts.next()) |part| {
        const dash = std.mem.indexOfScalar(u8, part, '-');
        const first = std.fmt.parseInt(usize, if (dash) |at| part[0..at] else part, 10) catch return null;
        const last = if (dash) |at| std.fmt.parseInt(usize, part[at + 1 ..], 10) catch return null else first;
        if (first < 1 or last > models.len or first > last) return null;
        for (first..last + 1) |n| {
            if (taken.isSet(n - 1)) continue;
            taken.set(n - 1);
            picked.append(arena, models[n - 1]) catch return null;
        }
    }
    return picked.items;
}

/// One answer at the terminal, trimmed; null at end of input.
fn ask(arena: std.mem.Allocator, question: []const u8) ?[]const u8 {
    std.debug.print("{s}", .{question});
    var buffer: [1024]u8 = undefined;
    const len = prompt.readLine(&buffer) catch return null;
    if (len == 0 and !prompt.interactive()) return null;
    return arena.dupe(u8, std.mem.trim(u8, buffer[0..len], " \t\r\n")) catch null;
}

// ── the document ─────────────────────────────────────────────────────────────

/// `custom_providers` of `text`, null when the file or the key is absent.
fn customSection(arena: std.mem.Allocator, text: []const u8) error{InvalidDocument}!?std.json.ObjectMap {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch return error.InvalidDocument;
    if (root != .object) return error.InvalidDocument;
    const section = root.object.get(config_store.CUSTOM_PROVIDERS_KEY) orelse return null;
    if (section != .object) return error.InvalidDocument;
    return section.object;
}

/// `section.<id>` as JSON text, or null.
fn entryText(arena: std.mem.Allocator, section: std.json.ObjectMap, id: []const u8) ?[]const u8 {
    const value = section.get(id) orelse return null;
    return std.json.Stringify.valueAlloc(arena, value, .{}) catch null;
}

/// The provider runtime as a session builds it from this configuration.
fn buildHost(gpa: std.mem.Allocator, file: *const config_store.Store) ?*provider_host.Host {
    const host = provider_host.Host.create(gpa) catch return null;
    host.adoptDurableState(file);
    return host;
}

/// "Google Gemini (gemini)" when `name` is the id or an alias of a provider
/// metacodes ships, else null.
fn builtinNamed(name: []const u8) ?[]const u8 {
    for (&registry_mod.BUILTIN_PROFILES) |*profile| {
        if (profile.matchesName(name)) return profile.display_name;
    }
    return null;
}

/// The check a write must pass: the document as it would land, judged the
/// way `--check-providers` judges it (`custom_providers`, then
/// `provider_catalogs`, then `providers`). A stage that loaded before may
/// not stop loading; with `.must_load`, the definitions must load after,
/// whatever they did before.
const Check = struct {
    gpa: std.mem.Allocator,
    id: Slug,
    rule: Rule,
    before: Stages,
    failed: ?Failure = null,

    const Rule = enum { must_load, may_go };
    const Failure = struct { stage: []const u8, err: anyerror };

    fn init(gpa: std.mem.Allocator, before_text: []const u8, id: Slug, rule: Rule) Check {
        return .{ .gpa = gpa, .id = id, .rule = rule, .before = stagesOf(gpa, before_text) };
    }

    fn validator(self: *Check) config_store.Validator {
        return .{ .ctx = @ptrCast(self), .validateFn = judge };
    }

    fn judge(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *Check = @ptrCast(@alignCast(ctx));
        const after = stagesOf(self.gpa, text);
        if (after.custom) |err| if (self.rule == .must_load or self.before.custom == null) {
            self.failed = .{ .stage = "custom_providers", .err = err };
            return err;
        };
        if (after.catalogs) |err| if (self.before.catalogs == null) {
            self.failed = .{ .stage = "provider_catalogs", .err = err };
            return err;
        };
        if (after.providers) |err| if (self.before.providers == null) {
            self.failed = .{ .stage = "providers", .err = err };
            return err;
        };
    }

    fn report(self: *const Check, path: []const u8) void {
        const failure = self.failed orelse {
            std.debug.print("error: {s} was not written: the result did not check out\n", .{path});
            return;
        };
        std.debug.print("error: {s} was not written: with this change its {s} would not load ({s}{s}). `metacodes --check-providers` shows the file as it is now.\n", .{
            path,
            failure.stage,
            @errorName(failure.err),
            if (failure.err == error.DuplicateProviderId) ": another provider has that id" else "",
        });
    }
};

const Stages = struct {
    custom: ?anyerror = null,
    catalogs: ?anyerror = null,
    providers: ?anyerror = null,
};

fn stagesOf(gpa: std.mem.Allocator, text: []const u8) Stages {
    const host = provider_host.Host.create(gpa) catch return .{ .custom = error.OutOfMemory };
    defer host.destroy();
    var out: Stages = .{};
    host.adoptCustomProviders(text) catch |err| {
        out.custom = err;
    };
    host.ingestConfiguredCatalogs(text) catch |err| {
        out.catalogs = err;
    };
    var document = config_doc.parse(gpa, text) catch |err| {
        out.providers = err;
        return out;
    };
    defer document.deinit();
    host.applyProviderConfiguration(&document) catch |err| {
        out.providers = err;
    };
    return out;
}

// ── arguments ────────────────────────────────────────────────────────────────

/// Fill `args` from `argv`; an exit code when they do not parse.
fn parseAddArgs(arena: std.mem.Allocator, argv: []const []const u8, args: *AddArgs) ?u8 {
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--base-url")) {
            args.base_url = valueOf(argv, &index) orelse return missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            const value = valueOf(argv, &index) orelse return missingValue(arg);
            const channel = parseChannelArg(value) orelse return unknownWire(value);
            args.channels.append(arena, channel) catch return outOfMemory();
        } else if (std.mem.eql(u8, arg, "--model")) {
            const value = valueOf(argv, &index) orelse return missingValue(arg);
            args.models.append(arena, value) catch return outOfMemory();
        } else if (std.mem.eql(u8, arg, "--display-name")) {
            const value = std.mem.trim(u8, valueOf(argv, &index) orelse return missingValue(arg), " \t");
            if (value.len == 0 or value.len > 128) {
                std.debug.print("error: --display-name takes 1 to 128 characters\n", .{});
                return 2;
            }
            args.display_name = value;
        } else if (std.mem.eql(u8, arg, "--dialect")) {
            const value = valueOf(argv, &index) orelse return missingValue(arg);
            args.dialect = Vendor.parse(value) orelse {
                std.debug.print("error: --dialect {s}: one of openai, claude, gemini, glm, kimi, deepseek, qwen, minimax, mistral, openrouter\n", .{value});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--key-env")) {
            args.key_env = valueOf(argv, &index) orelse return missingValue(arg);
        } else if (std.mem.eql(u8, arg, "--auth")) {
            const value = valueOf(argv, &index) orelse return missingValue(arg);
            args.auth = parseAuth(value) orelse return badAuth(value);
        } else if (std.mem.eql(u8, arg, "--probe")) {
            args.probe = true;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            args.replace = true;
        } else if (std.mem.eql(u8, arg, "--subscription-plan")) {
            args.subscription_plan = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return unknownArgument(arg);
        } else if (args.id == null) {
            args.id = arg;
        } else return unknownArgument(arg);
    }
    return null;
}

fn valueOf(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    index.* += 1;
    return argv[index.*];
}

fn wireNames() []const u8 {
    return "openai_chat, openai_responses, anthropic_messages, gemini_generate_content, bedrock_converse";
}

fn missingValue(flag: []const u8) u8 {
    std.debug.print("error: {s} needs a value\n{s}", .{ flag, USAGE });
    return 2;
}

fn unknownWire(text: []const u8) u8 {
    std.debug.print("error: --protocol {s}: one of {s} (optionally =<url>)\n", .{ text, wireNames() });
    return 2;
}

fn badAuth(text: []const u8) u8 {
    std.debug.print("error: --auth {s}: bearer, header:<name> (such as header:x-api-key), or header:<name>:<prefix>\n", .{text});
    return 2;
}

fn unknownArgument(arg: []const u8) u8 {
    std.debug.print("error: unknown providers argument '{s}'\n{s}", .{ arg, USAGE });
    return 2;
}

fn keyReadFailure(err: anyerror) u8 {
    if (err == error.Interrupted) {
        std.debug.print("Interrupted; nothing was written.\n", .{});
        return 130;
    }
    std.debug.print("error: the key could not be read ({s})\n", .{@errorName(err)});
    return 1;
}

fn outOfMemory() u8 {
    std.debug.print("error: out of memory\n", .{});
    return 1;
}

fn stdoutWrite(bytes: []const u8) void {
    _ = pfs.writeAll(1, bytes);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "protocol, auth and key-variable arguments parse to what the schema stores" {
    try testing.expectEqual(Wire.openai_chat, parseChannelArg("openai_chat").?.wire);
    const own = parseChannelArg("anthropic_messages=https://relay.example.com/apps/anthropic").?;
    try testing.expectEqual(Wire.anthropic_messages, own.wire);
    try testing.expectEqualStrings("https://relay.example.com/apps/anthropic", own.base_url.?);
    try testing.expect(parseChannelArg("grpc") == null);

    try testing.expect(parseAuth("bearer").? == .bearer);
    try testing.expectEqualStrings("x-api-key", parseAuth("header:x-api-key").?.api_key_header);
    const prefixed = parseAuth("header:X-Relay-Token:Token ").?;
    try testing.expectEqualStrings("X-Relay-Token", prefixed.custom_header.name);
    try testing.expectEqualStrings("Token ", prefixed.custom_header.value_prefix);
    try testing.expect(parseAuth("header:") == null);
    try testing.expect(parseAuth("header:bad name") == null);
    try testing.expect(parseAuth("query:key") == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("MY_RELAY_API_KEY", suggestedKeyEnv(arena_state.allocator(), "my-relay"));
}

test "an endpoint is refused in the words the user acts on" {
    try testing.expect(baseUrlProblem("https://relay.example.com/v1") == null);
    try testing.expect(baseUrlProblem("http://127.0.0.1:11434/v1") == null);
    try testing.expect(baseUrlProblem("http://localhost:8000/v1") == null);
    try testing.expect(std.mem.indexOf(u8, baseUrlProblem("http://relay.example.com/v1").?, "only to this machine") != null);
    try testing.expect(std.mem.indexOf(u8, baseUrlProblem("https://user:pw@relay.example.com/v1").?, "user name or password") != null);
    try testing.expect(std.mem.indexOf(u8, baseUrlProblem("https://relay.example.com/a%2fb").?, "%-escapes") != null);
    try testing.expect(baseUrlProblem("relay.example.com/v1") != null);
}

test "a pick reads numbers and ranges, each model once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const models = [_]model_listing.Listed{ .{ .id = "a" }, .{ .id = "b" }, .{ .id = "c" }, .{ .id = "d" } };
    const picked = selection(arena, "3, 1-2,2", &models).?;
    try testing.expectEqual(@as(usize, 3), picked.len);
    try testing.expectEqualStrings("c", picked[0].id);
    try testing.expectEqualStrings("a", picked[1].id);
    try testing.expectEqualStrings("b", picked[2].id);
    try testing.expect(selection(arena, "5", &models) == null);
    try testing.expect(selection(arena, "2-1", &models) == null);
    try testing.expect(selection(arena, "x", &models) == null);
}

test "a stored key never meets an address it was not stored for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Read from the definition as written, a definition that would not load
    // (no models) included.
    const old = storedOrigins(arena,
        \\{"channels":[{"id":"openai","base_url":"https://relay.example.com/v1","protocol":"openai_chat"},
        \\ {"id":"bad"},{"id":"also-bad","base_url":7}]}
    );
    try testing.expectEqual(@as(usize, 1), old.len);
    try testing.expectEqualStrings("https://relay.example.com", old[0]);
    const same = [_]custom_provider.DraftChannel{
        .{ .id = "openai", .base_url = "https://relay.example.com/v2", .wire = .openai_chat },
        .{ .id = "anthropic", .base_url = "https://RELAY.example.com", .wire = .anthropic_messages },
    };
    try testing.expect(newOrigin(old, &same) == null);
    const moved = [_]custom_provider.DraftChannel{.{ .id = "openai", .base_url = "https://other.example.com/v1", .wire = .openai_chat }};
    try testing.expectEqualStrings("https://other.example.com", newOrigin(old, &moved).?);
    try testing.expectEqualStrings("http://127.0.0.1:8000", originOf("http://127.0.0.1:8000/v1"));
    // Channels that cannot be read say nowhere: every address is new.
    for ([_][]const u8{ "{oops", "[1]", "{\"channels\":\"oops\"}", "{}" }) |text| {
        try testing.expectEqual(@as(usize, 0), storedOrigins(arena, text).len);
        try testing.expectEqualStrings("https://relay.example.com", newOrigin(storedOrigins(arena, text), same[0..1]).?);
    }
}

test "the ids and aliases metacodes ships are not a custom provider's" {
    try testing.expect(builtinNamed("openai") != null);
    try testing.expect(builtinNamed("google") != null);
    try testing.expect(builtinNamed("my-relay") == null);
}
