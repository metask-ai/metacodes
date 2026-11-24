//! `metacodes sealed …`: the operator surface of doc/SEALED_SKILL_PROTOCOL.md.
//!
//! - `install <gateway-url> <skill_id> [--token-env NAME] [--yes]` fetches the
//!   Entry, shows what the user consents to (§6.1) and pins it;
//! - `list` prints the pins under the state root, with the binding state of
//!   every credential reference each one declares;
//! - `bind <name> <ref> [--from-env VAR]` / `unbind <name> <ref>` bind a
//!   declared credential reference to a local secret (§6.4), read from stdin
//!   or an environment variable, never from the command line;
//! - `ledger` prints the sealed usage ledger (§6.6);
//! - `serve --skills <dir> [--listen PORT] [--token T]` runs the reference
//!   gateway on loopback until Ctrl+C; it has no provider credentials of its
//!   own and calls the model over each client's route (§8.1).

const std = @import("std");
const pfs = @import("platform").fs;
const paths = @import("platform").paths;
const platform_signal = @import("platform").signal;
const util_time = @import("metacodes-internal").util.time;
const shutdown = @import("metacodes-internal").core.shutdown;
const protocol = @import("metacodes-internal").skills.sealed.protocol;
const transport = @import("metacodes-internal").skills.sealed.transport;
const pin_mod = @import("metacodes-internal").skills.sealed.pin;
const ledger = @import("metacodes-internal").skills.sealed.ledger;
const credentials = @import("metacodes-internal").skills.sealed.credentials;
const gateway_mod = @import("metacodes-internal").skills.sealed.gateway;

const USAGE =
    \\usage: metacodes sealed install <gateway-url> <skill_id> [--token-env NAME] [--yes]
    \\       metacodes sealed list
    \\       metacodes sealed bind <name> <ref> [--from-env VAR]   (secret from stdin unless --from-env)
    \\       metacodes sealed unbind <name> <ref>
    \\       metacodes sealed ledger
    \\       metacodes sealed serve --skills <dir> [--listen PORT] [--token T]
    \\                              [--workers N] [--queue-depth N] [--max-model-calls N]
    \\                              [--keepalive-ms MS] [--provider-cache-ms MS]
    \\
;

pub fn run(args: *std.process.Args.Iterator, allocator: std.mem.Allocator, io: std.Io, state_root: []const u8) u8 {
    const sub = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        stdoutWrite(USAGE);
        return 0;
    }
    if (std.mem.eql(u8, sub, "install")) return install(args, allocator, io, state_root);
    if (std.mem.eql(u8, sub, "list")) return list(allocator, state_root);
    if (std.mem.eql(u8, sub, "bind")) return bind(args, allocator, state_root);
    if (std.mem.eql(u8, sub, "unbind")) return unbind(args, allocator, state_root);
    if (std.mem.eql(u8, sub, "ledger")) return printLedger(allocator, state_root);
    if (std.mem.eql(u8, sub, "serve")) return serve(args, allocator);
    std.debug.print("error: unknown sealed subcommand '{s}'\n{s}", .{ sub, USAGE });
    return 2;
}

fn envValue(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const z = allocator.dupeZ(u8, name) catch return null;
    defer allocator.free(z);
    const raw = std.c.getenv(z.ptr) orelse return null;
    return std.mem.span(raw);
}

fn stdoutWrite(bytes: []const u8) void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pfs.write(1, bytes[pos..][0 .. bytes.len - pos]);
        if (n <= 0) break;
        pos += @as(usize, @intCast(n));
    }
}

fn install(args: *std.process.Args.Iterator, allocator: std.mem.Allocator, io: std.Io, state_root: []const u8) u8 {
    const url = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    const skill_id = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    var token_env: []const u8 = pin_mod.DEFAULT_TOKEN_ENV;
    var yes = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            yes = true;
        } else if (std.mem.eql(u8, arg, "--token-env")) {
            token_env = args.next() orelse {
                std.debug.print("error: --token-env needs a name\n", .{});
                return 2;
            };
        } else {
            std.debug.print("error: unknown install argument '{s}'\n", .{arg});
            return 2;
        }
    }
    if (state_root.len == 0) {
        std.debug.print("error: no state root; pass --state-dir or set METACODES_HOME\n", .{});
        return 1;
    }
    const token = envValue(allocator, token_env) orelse "";
    var client = transport.Client.init(allocator, io, url, token) catch |err| {
        std.debug.print("error: gateway URL rejected ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer client.deinit();
    var params: std.Io.Writer.Allocating = .init(allocator);
    defer params.deinit();
    protocol.writeSkillsGetParams(&params.writer, skill_id) catch return 1;
    var response = client.call(.skills_get, params.written(), null) catch |err| {
        std.debug.print("error: gateway call failed ({s}, http {d})\n", .{ @errorName(err), client.last_http_status });
        return 1;
    };
    defer response.deinit();
    const entry_json = switch (response.response) {
        .result => |result| result,
        .err => |rpc| {
            std.debug.print("error: gateway refused ({s}): {s}\n", .{ if (rpc.known) |k| k.name() else "error", rpc.message });
            return 1;
        },
    };
    var parsed = protocol.parseEntry(allocator, entry_json) catch |err| {
        std.debug.print("error: the gateway's Entry does not verify ({s}); nothing pinned\n", .{@errorName(err)});
        return 1;
    };
    defer parsed.deinit();
    const entry = &parsed.entry;
    if (!entry.manifest.executionSupported()) {
        std.debug.print("error: this Skill needs execution classes this client does not run\n", .{});
        return 1;
    }
    printConsent(entry, url, token_env);
    if (!yes) {
        std.debug.print("Pin this manifest? [y/N] ", .{});
        if (!readYes()) {
            std.debug.print("Not installed.\n", .{});
            return 1;
        }
    }
    pin_mod.write(allocator, state_root, url, token_env, entry_json, entry) catch |err| {
        std.debug.print("error: could not write the pin ({s})\n", .{@errorName(err)});
        return 1;
    };
    // Public assets (scripts, data) are installed where the Skill's brain
    // believes they are; sealed files never come down.
    for (entry.assets) |asset| {
        installAsset(allocator, &client, state_root, entry, asset) catch |err| {
            std.debug.print("error: asset {s} could not be installed ({s}); the pin is incomplete\n", .{ asset.path, @errorName(err) });
            return 1;
        };
    }
    std.debug.print("Installed /{s} (sealed, {s}, {d} public asset(s)). Run it with /{s} <arguments>.\n", .{ entry.manifest.name, entry.manifest_digest, entry.assets.len, entry.manifest.name });
    return 0;
}

/// Fetch one asset (`skills.asset`), verify its digest against the Entry
/// and write it under the pin directory.
pub fn installAsset(allocator: std.mem.Allocator, client: *transport.Client, state_root: []const u8, entry: *const protocol.Entry, asset: protocol.Asset) !void {
    var params: std.Io.Writer.Allocating = .init(allocator);
    defer params.deinit();
    try protocol.writeSkillsAssetParams(&params.writer, entry.skill_id, asset.path);
    var response = try client.call(.skills_asset, params.written(), null);
    defer response.deinit();
    const result = switch (response.response) {
        .result => |result| result,
        .err => return error.AssetRefused,
    };
    var parsed = try protocol.parseAsset(allocator, result);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.path, asset.path) or !std.mem.eql(u8, parsed.sha256, asset.sha256)) return error.AssetMismatch;
    try pin_mod.writeAsset(allocator, state_root, entry.manifest.name, asset.path, parsed.content);
}

/// What the user consents to when pinning (§6.1): identity, allowlist,
/// egress, credentials and price. Printed in full; never summarized away.
fn printConsent(entry: *const protocol.Entry, url: []const u8, token_env: []const u8) void {
    const m = &entry.manifest;
    std.debug.print("\nSealed Skill /{s} v{s}\n", .{ m.name, m.version });
    std.debug.print("  gateway:     {s} (token from ${s})\n", .{ url, token_env });
    std.debug.print("  skill id:    {s}\n", .{entry.skill_id});
    std.debug.print("  manifest:    {s}\n", .{entry.manifest_digest});
    std.debug.print("  creator:     {s}{s}{s}\n", .{ m.creator_display_name, if (m.creator_id.len != 0) " / " else "", m.creator_id });
    std.debug.print("  description: {s}\n", .{m.description});
    std.debug.print("  tools allowed:", .{});
    for (m.tools_allow) |rule| std.debug.print(" {s}", .{rule});
    std.debug.print("\n", .{});
    if (m.tools_deny.len != 0) {
        std.debug.print("  tools denied: ", .{});
        for (m.tools_deny) |rule| std.debug.print(" {s}", .{rule});
        std.debug.print("\n", .{});
    }
    if (m.confirmation_required_for.len != 0) {
        std.debug.print("  always confirms:", .{});
        for (m.confirmation_required_for) |rule| std.debug.print(" {s}", .{rule});
        std.debug.print("\n", .{});
    }
    std.debug.print("  data leaving this machine as tool results:", .{});
    if (m.egress_classes.len == 0) std.debug.print(" (none declared)", .{});
    for (m.egress_classes) |class| std.debug.print(" {s}", .{class});
    std.debug.print(" (up to {d} bytes per result, retention: {s})\n", .{ m.egress_max_result_bytes, m.egress_retention });
    std.debug.print("  disclosure screen: instructions {s}, references {s}\n", .{ m.egress_disclosure, m.egress_disclosure_references });
    if (protocol.manifestDeclaresEgress(m, protocol.EGRESS_CODEBASE_CONTEXT_CLASS)) {
        std.debug.print("  context sent with each run: this project's CLAUDE.md chain and git status ({s})\n", .{protocol.EGRESS_CODEBASE_CONTEXT_CLASS});
    } else {
        std.debug.print("  context sent with each run: your request only, no CLAUDE.md or git status ({s} not declared)\n", .{protocol.EGRESS_CODEBASE_CONTEXT_CLASS});
    }
    if (m.credentials.len != 0) {
        std.debug.print("  credentials it will ask for:", .{});
        for (m.credentials) |credential| std.debug.print(" {s} ({s})", .{ credential.ref, credential.purpose });
        std.debug.print("\n", .{});
    }
    if (m.pricing_estimate_micros != 0 or m.pricing_model.len != 0) {
        std.debug.print("  pricing:     {s}, about {d}.{d:0>6} {s} per run\n", .{
            m.pricing_model,
            @divTrunc(m.pricing_estimate_micros, 1_000_000),
            @as(u64, @intCast(@mod(m.pricing_estimate_micros, 1_000_000))),
            m.pricing_currency,
        });
    }
    std.debug.print("  Skill content stays on the gateway; every tool call is approved here.\n\n", .{});
}

fn readYes() bool {
    var buf: [16]u8 = undefined;
    const n = pfs.read(0, &buf);
    if (n <= 0) return false;
    const line = std.mem.trim(u8, buf[0..@intCast(n)], " \r\n\t");
    return line.len != 0 and (line[0] == 'y' or line[0] == 'Y');
}

fn list(allocator: std.mem.Allocator, state_root: []const u8) u8 {
    var listing = pin_mod.list(allocator, state_root) catch |err| {
        std.debug.print("error: could not read pins ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer listing.deinit();
    if (listing.pins.len == 0) {
        std.debug.print("No sealed Skills pinned.\n", .{});
        return 0;
    }
    var store = credentials.load(allocator, state_root) catch |err| {
        std.debug.print("error: could not read {s} ({s})\n", .{ credentials.FILE_NAME, @errorName(err) });
        return 1;
    };
    defer store.deinit();
    for (listing.pins) |pin| {
        if (pin.broken) |err| {
            std.debug.print("/{s}  BROKEN ({s})\n", .{ pin.name, @errorName(err) });
            continue;
        }
        std.debug.print("/{s}  v{s}  {s}  {s}  {s}\n", .{ pin.name, pin.version, pin.gateway_url, pin.creator, pin.manifest_digest });
        var parsed = readPin(allocator, state_root, pin.name) catch continue;
        defer parsed.deinit();
        for (parsed.pin.entry.manifest.credentials) |credential| {
            if (store.isBound(parsed.pin.entry.skill_id, credential.ref)) {
                std.debug.print("    credential {s}: bound\n", .{credential.ref});
            } else {
                std.debug.print("    credential {s}: NOT BOUND ({s}) — metacodes sealed bind {s} {s}\n", .{ credential.ref, credential.purpose, pin.name, credential.ref });
            }
        }
    }
    return 0;
}

/// The verified pin of `/name` under the state root.
fn readPin(allocator: std.mem.Allocator, state_root: []const u8, name: []const u8) !pin_mod.ParsedPin {
    const pin_root = try pin_mod.pinRoot(allocator, state_root);
    defer allocator.free(pin_root);
    const dir = try std.fs.path.join(allocator, &.{ pin_root, name });
    defer allocator.free(dir);
    return pin_mod.read(allocator, dir);
}

/// `bind <name> <ref> [--from-env VAR]`: the secret comes from stdin (one
/// line; pipe it or type it) or from an environment variable, never from
/// argv, which every process on the machine can read.
fn bind(args: *std.process.Args.Iterator, allocator: std.mem.Allocator, state_root: []const u8) u8 {
    const name = args.next() orelse return usageError("bind needs <name> <ref>");
    const ref = args.next() orelse return usageError("bind needs <name> <ref>");
    var from_env: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--from-env")) {
            from_env = args.next() orelse return usageError("--from-env needs a variable name");
        } else {
            std.debug.print("error: unknown bind argument '{s}'\n", .{arg});
            return 2;
        }
    }
    if (state_root.len == 0) {
        std.debug.print("error: no state root; pass --state-dir or set METACODES_HOME\n", .{});
        return 1;
    }
    var parsed = readPin(allocator, state_root, name) catch |err| {
        std.debug.print("error: no verified pin for /{s} ({s}); install it first\n", .{ name, @errorName(err) });
        return 1;
    };
    defer parsed.deinit();
    const manifest = &parsed.pin.entry.manifest;
    const declared = for (manifest.credentials) |credential| {
        if (std.mem.eql(u8, credential.ref, ref)) break true;
    } else false;
    if (!declared) {
        std.debug.print("error: /{s} does not declare a credential reference '{s}'; it declares:", .{ name, ref });
        for (manifest.credentials) |credential| std.debug.print(" {s}", .{credential.ref});
        std.debug.print("\n", .{});
        return 1;
    }
    var secret_buf: [credentials.MAX_SECRET_BYTES]u8 = undefined;
    defer @memset(&secret_buf, 0);
    const secret: []const u8 = if (from_env) |variable|
        envValue(allocator, variable) orelse {
            std.debug.print("error: ${s} is not set\n", .{variable});
            return 1;
        }
    else blk: {
        if (@import("platform").terminal.isatty(0)) std.debug.print("Secret for {s} ({s}), then Enter: ", .{ ref, manifest.name });
        const n = pfs.read(0, &secret_buf);
        if (n <= 0) {
            std.debug.print("error: no secret on stdin\n", .{});
            return 1;
        }
        break :blk secret_buf[0..@intCast(n)];
    };
    const trimmed = std.mem.trim(u8, secret, "\r\n");
    credentials.bind(allocator, state_root, parsed.pin.entry.skill_id, ref, trimmed) catch |err| {
        std.debug.print("error: could not bind ({s})\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("Bound {s} for /{s} ({s}) in {s}/{s}.\n", .{ ref, name, parsed.pin.entry.skill_id, state_root, credentials.FILE_NAME });
    return 0;
}

fn unbind(args: *std.process.Args.Iterator, allocator: std.mem.Allocator, state_root: []const u8) u8 {
    const name = args.next() orelse return usageError("unbind needs <name> <ref>");
    const ref = args.next() orelse return usageError("unbind needs <name> <ref>");
    if (state_root.len == 0) {
        std.debug.print("error: no state root; pass --state-dir or set METACODES_HOME\n", .{});
        return 1;
    }
    var parsed = readPin(allocator, state_root, name) catch |err| {
        std.debug.print("error: no verified pin for /{s} ({s})\n", .{ name, @errorName(err) });
        return 1;
    };
    defer parsed.deinit();
    const removed = credentials.unbind(allocator, state_root, parsed.pin.entry.skill_id, ref) catch |err| {
        std.debug.print("error: could not unbind ({s})\n", .{@errorName(err)});
        return 1;
    };
    if (!removed) {
        std.debug.print("{s} was not bound for /{s}.\n", .{ ref, name });
        return 1;
    }
    std.debug.print("Unbound {s} for /{s}.\n", .{ ref, name });
    return 0;
}

fn printLedger(allocator: std.mem.Allocator, state_root: []const u8) u8 {
    const bytes = ledger.read(allocator, state_root) catch |err| {
        if (err == error.NotFound) return 0;
        std.debug.print("error: could not read the sealed ledger ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(bytes);
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pfs.write(1, bytes[pos..]);
        if (n <= 0) break;
        pos += @intCast(n);
    }
    return 0;
}

fn serve(args: *std.process.Args.Iterator, allocator: std.mem.Allocator) u8 {
    var skills_dir: ?[]const u8 = null;
    var port: u16 = 8787;
    var token: []const u8 = "";
    var server_options: gateway_mod.ServerOptions = .{};
    var provider_cache_ms: u64 = (gateway_mod.Options{}).provider_cache_ms;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--skills")) {
            skills_dir = args.next() orelse return usageError("--skills needs a directory");
        } else if (std.mem.eql(u8, arg, "--listen")) {
            const raw = args.next() orelse return usageError("--listen needs a port");
            port = std.fmt.parseInt(u16, raw, 10) catch return usageError("--listen takes a loopback port number");
        } else if (std.mem.eql(u8, arg, "--token")) {
            token = args.next() orelse return usageError("--token needs a value");
        } else if (std.mem.eql(u8, arg, "--workers")) {
            server_options.workers = parseCount(args.next()) orelse return usageError("--workers takes a positive number");
        } else if (std.mem.eql(u8, arg, "--queue-depth")) {
            server_options.queue_depth = parseCount(args.next()) orelse return usageError("--queue-depth takes a positive number");
        } else if (std.mem.eql(u8, arg, "--max-model-calls")) {
            server_options.max_model_calls = parseCount(args.next()) orelse return usageError("--max-model-calls takes a positive number");
        } else if (std.mem.eql(u8, arg, "--keepalive-ms")) {
            server_options.keepalive_ms = parseMs(args.next()) orelse return usageError("--keepalive-ms takes a number of milliseconds (0 disables)");
        } else if (std.mem.eql(u8, arg, "--provider-cache-ms")) {
            provider_cache_ms = parseMs(args.next()) orelse return usageError("--provider-cache-ms takes a number of milliseconds (0 disables)");
        } else {
            std.debug.print("error: unknown serve argument '{s}'\n", .{arg});
            return 2;
        }
    }
    const dir = skills_dir orelse return usageError("--skills <dir> is required");
    // Ctrl+C, SIGTERM/SIGHUP and (on Windows) the console closing only raise
    // the process-wide shutdown flag (core/shutdown.zig); this thread polls it
    // and stops the server itself. Installed before any other thread exists,
    // so no signal meets the console's default handler, which on Windows ends
    // the process from its own thread while the accept loop still runs.
    platform_signal.installInterrupt(onShutdownSignal);
    platform_signal.installTerminate(onShutdownSignal);
    // The gateway has no model provider of its own: every run calls the
    // model over the client's route and credential (§8.1).
    const gateway = gateway_mod.Gateway.init(allocator, dir, .{ .token = token, .provider_cache_ms = provider_cache_ms }) catch |err| {
        std.debug.print("error: could not load Skill packages from {s} ({s})\n", .{ dir, @errorName(err) });
        return 1;
    };
    defer gateway.deinit();
    // A port another process holds fails here with BindFailed: the listener
    // binds exclusively (platform/net.zig), so two gateways never share one
    // port and a client never reaches a stale instance by chance.
    server_options.port = port;
    const server = gateway_mod.Server.startWith(allocator, gateway, server_options) catch |err| {
        std.debug.print("error: could not listen on 127.0.0.1:{d} ({s})\n", .{ port, @errorName(err) });
        return 1;
    };
    std.debug.print("sealed gateway: {d} Skill package(s) from {s}\n", .{ gateway.packages.len, dir });
    for (gateway.packages) |package| std.debug.print("  {s}  {s}  {s}  ({d} public asset(s), {d} sealed file(s))\n", .{ package.entry.skill_id, package.name, package.entry.manifest_digest, package.assets.len, package.sealed_files.len });
    const resolved = server.stats();
    std.debug.print("listening on http://127.0.0.1:{d}/ssp (model calls use each client's own provider{s})\n", .{ server.port, if (token.len == 0) "; no token: open to every local caller" else "" });
    std.debug.print("capacity: {d} workers, queue {d}, {d} model calls in flight, provider cache {d} ms\n", .{ resolved.workers, resolved.queue_depth, resolved.max_model_calls, provider_cache_ms });
    while (!shutdown.requested()) util_time.sleepMs(50);
    // Join the accept loop and close the listener before the Gateway it
    // serves goes away (the defer above); a request in flight finishes first.
    server.stop();
    std.debug.print("\nsealed gateway closed.\n", .{});
    return 0;
}

/// Signal callback: async-signal-safe, an atomic store and nothing else.
fn onShutdownSignal() void {
    shutdown.request();
}

fn parseCount(raw: ?[]const u8) ?usize {
    const text = raw orelse return null;
    const value = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (value == 0) null else value;
}

fn parseMs(raw: ?[]const u8) ?u64 {
    const text = raw orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn usageError(message: []const u8) u8 {
    std.debug.print("error: {s}\n{s}", .{ message, USAGE });
    return 2;
}
