//! Presets at start (#489): which named selection a start uses, and what it
//! sets in the start's configuration.
//!
//! config.json holds them (`presets`, and `directory_presets` for the
//! directories that remember one; `src/provider/config_doc.zig`);
//! `startup_order.zig` decides whether one applies. This file reads the
//! facts that decision needs and lowers the preset that wins into the fields
//! `--provider`, `--channel`, `--model` (or `--offer`) and
//! `--reasoning-effort` would set, so a preset's route is resolved,
//! authenticated and reported exactly as a route named with flags is:
//! `METACODES_BASE_URL` moves it, a provider without a credential is not
//! replaced by another.
//!
//! - **Where a preset is named.** `--preset`, else `METACODES_PRESET` in the
//!   process environment (level 2); the working directory's entry (level 3);
//!   `METACODES_PRESET` in `<state root>/.env` (level 6, with the file's
//!   other choices).
//! - **The directory's key** is the git worktree root when the working
//!   directory is inside one (the nearest ancestor holding `.git`, a
//!   directory or, in a linked worktree, a file), else the working directory,
//!   as `getcwd` gives it: absolute, symlinks resolved. Nothing is ever
//!   written into the directory.
//! - **A flag wins over the field it sets.** `--model`, `--channel` and
//!   `--reasoning-effort` replace the preset's model, channel and reasoning
//!   effort for this run; `--provider` and `--offer` name a route of their
//!   own (level 1), and the preset is not applied. Nothing is written back.
//!
//! Host-only, like the rest of `src/app/`.

const std = @import("std");
const types = @import("metacodes-internal").types;
const config_doc = @import("metacodes-internal").provider.config_doc;
const registry_mod = @import("metacodes-internal").provider.registry;
const provider_startup = @import("metacodes-internal").provider.startup;
const startup_order = @import("startup_order.zig");
const state_env = @import("state_env.zig");
const pfs = @import("platform").fs;

/// `METACODES_PRESET`.
pub const variable = state_env.preset_variable;
/// Where LOCAL_CONFIG.md explains presets; hints link it.
pub const guide_url = state_env.guide_url ++ "#presets";

/// Where the preset named at start (level 2) came from.
pub const Origin = enum { flag, shell };

/// What a start reads about presets: the three levels' facts for the
/// startup order, and what the start needs to report or apply them.
pub const Facts = struct {
    /// Level 2.
    named: startup_order.Preset = .none,
    named_origin: Origin = .flag,
    /// Level 3: the working directory's key ("" when the working directory
    /// cannot be read), and what it remembers.
    directory: []const u8 = "",
    directory_preset: startup_order.Preset = .none,
    /// Level 6: `METACODES_PRESET` in `.env`.
    local_preset: startup_order.Preset = .none,
    /// config.json, and why it cannot be read when it cannot.
    config_path: []const u8 = "",
    unreadable: ?[]const u8 = null,
    /// The presets config.json defines, in its order.
    defined: []const []const u8 = &.{},
    /// The selections of the presets the three levels found.
    chosen: []const Chosen = &.{},
    global_default: bool = true,

    pub const Chosen = struct {
        name: []const u8,
        selection: config_doc.RuntimeSelection,
    };

    /// The selection of `name`, when one of the levels found it.
    pub fn selection(self: *const Facts, name: []const u8) ?*const config_doc.RuntimeSelection {
        for (self.chosen) |*entry| if (std.mem.eql(u8, entry.name, name)) return &entry.selection;
        return null;
    }

    /// The preset a decision by preset (`Decision.byPreset`) applies.
    pub fn decided(self: *const Facts, decision: startup_order.Decision) ?startup_order.Preset.Found {
        const preset = switch (decision) {
            .preset => self.named,
            .directory_preset => self.directory_preset,
            .local_preset => self.local_preset,
            else => return null,
        };
        return switch (preset) {
            .found => |value| value,
            else => null,
        };
    }
};

/// What config.json says, as the start read it.
pub const Document = union(enum) {
    /// No state root, or no file: no preset is defined.
    absent,
    read: *const config_doc.Document,
    /// It cannot be read or parsed: the name of the error.
    unreadable: []const u8,
};

pub const Inputs = struct {
    /// `--preset`.
    flag: ?[]const u8 = null,
    /// `METACODES_PRESET` in `.env`.
    local: ?[]const u8 = null,
    /// The process's working directory (`getcwd`), when it can be read.
    cwd: ?[]const u8 = null,
    config_path: []const u8 = "",
    document: Document = .absent,
    /// The provider registry a session builds, to name a found preset's
    /// route (`login status`); null leaves the routes unnamed.
    registry: ?*const registry_mod.ProviderRegistry = null,
    unreadable_global_default: ?bool = null,
};

/// The facts of the three preset levels. Everything returned lives in
/// `arena`; the document may go first.
pub fn gather(arena: std.mem.Allocator, inputs: Inputs) error{OutOfMemory}!Facts {
    var facts: Facts = .{ .config_path = inputs.config_path };
    const document: ?*const config_doc.Document = switch (inputs.document) {
        .absent => null,
        .read => |value| value,
        .unreadable => |why| blk: {
            facts.unreadable = why;
            break :blk null;
        },
    };
    if (document) |doc| {
        const names = try arena.alloc([]const u8, doc.presets.items.len);
        for (doc.presets.items, names) |*entry, *name| name.* = try arena.dupe(u8, entry.name.slice());
        facts.defined = names;
    }
    facts.global_default = switch (inputs.document) {
        .absent => true,
        .read => |doc| doc.global_default orelse true,
        .unreadable => inputs.unreadable_global_default orelse true,
    };
    var chosen: std.ArrayList(Facts.Chosen) = .empty;

    const named = shellOrFlag(inputs.flag);
    if (named) |value| facts.named_origin = value.origin;
    facts.named = try judge(arena, document, inputs.registry, if (named) |value| value.name else null, &chosen);

    if (inputs.cwd) |cwd| {
        facts.directory = try directoryKey(arena, cwd);
        if (document) |doc| {
            if (rememberedFor(doc, facts.directory)) |name| {
                facts.directory_preset = try judge(arena, document, inputs.registry, try arena.dupe(u8, name), &chosen);
            }
        }
    }
    facts.local_preset = try judge(arena, document, inputs.registry, inputs.local, &chosen);
    facts.chosen = try chosen.toOwnedSlice(arena);
    return facts;
}

const Named = struct { name: []const u8, origin: Origin };

/// `--preset`, else a non-empty `METACODES_PRESET` in the process
/// environment.
fn shellOrFlag(flag: ?[]const u8) ?Named {
    if (flag) |name| return .{ .name = name, .origin = .flag };
    const raw = std.c.getenv(variable) orelse return null;
    const value = std.mem.span(raw);
    if (value.len == 0) return null;
    return .{ .name = value, .origin = .shell };
}

/// `name` against `document`, recording a found preset's selection in
/// `chosen`.
fn judge(
    arena: std.mem.Allocator,
    document: ?*const config_doc.Document,
    registry: ?*const registry_mod.ProviderRegistry,
    name: ?[]const u8,
    chosen: *std.ArrayList(Facts.Chosen),
) error{OutOfMemory}!startup_order.Preset {
    const wanted = name orelse return .none;
    const doc = document orelse return .{ .unknown = wanted };
    const entry = doc.preset(wanted) orelse return .{ .unknown = wanted };
    try chosen.append(arena, .{ .name = wanted, .selection = entry.selection });
    var found: startup_order.Preset.Found = .{ .name = wanted };
    if (registry) |reg| {
        const outcome = try provider_startup.resolveSelection(arena, reg, entry.selection);
        switch (outcome) {
            .route => |route| {
                const shown = if (reg.findById(route.provider_id)) |profile| profile.display_name else route.provider_id.slice();
                found.label = try std.fmt.allocPrint(arena, "{s} · {s}", .{ shown, route.request_model_id });
                found.provider = try arena.dupe(u8, route.provider_id.slice());
            },
            .failure => {},
        }
    }
    return .{ .found = found };
}

// ── the working directory ───────────────────────────────────────────────────

/// The key the working directory `cwd` remembers its preset under: the git
/// worktree root when `cwd` is inside one, else `cwd` without trailing
/// separators. In `arena`.
pub fn directoryKey(arena: std.mem.Allocator, cwd: []const u8) error{OutOfMemory}![]const u8 {
    const root = @import("metacodes-internal").skills.skill.findRepoRoot(arena, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return arena.dupe(u8, trimSeparators(cwd)),
    };
    return root;
}

/// The preset `document` remembers for the directory `key`, or null. An
/// entry matches when its path, without trailing separators, is `key`; else
/// when it resolves (symlinks followed) to `key`, so `/tmp/x` written by
/// hand still finds the `/private/tmp/x` a start in it reads on macOS.
pub fn rememberedFor(document: *const config_doc.Document, key: []const u8) ?[]const u8 {
    for (document.directory_presets.items) |*entry| {
        if (std.mem.eql(u8, trimSeparators(entry.path), key)) return entry.preset.slice();
    }
    for (document.directory_presets.items) |*entry| {
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{entry.path}) catch continue;
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = pfs.realpath(path_z.ptr, &resolved_buf) orelse continue;
        if (std.mem.eql(u8, trimSeparators(std.mem.span(resolved)), key)) return entry.preset.slice();
    }
    return null;
}

fn trimSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and std.fs.path.isSep(path[end - 1])) end -= 1;
    return path[0..end];
}

// ── applying the one that decides ───────────────────────────────────────────

/// Why a preset cannot be applied; `message` says it in one line.
pub const Refusal = union(enum) {
    /// Its route does not resolve against this install's catalog.
    unresolved: provider_startup.Failure,
    /// Its `reasoning_effort` is not a level metacodes knows.
    reasoning_effort: []const u8,

    /// One line naming the preset and config.json. In `arena`.
    pub fn message(self: Refusal, arena: std.mem.Allocator, name: []const u8, config_path: []const u8) error{OutOfMemory}![]const u8 {
        return switch (self) {
            .reasoning_effort => |value| std.fmt.allocPrint(arena, "the preset {s} in {s} sets reasoning_effort to '{s}'; use none, minimal, low, medium, high, xhigh or max", .{ name, config_path, value }),
            .unresolved => |failure| switch (failure) {
                .unresolved_selection => |target| switch (target) {
                    .pinned_offer => |pin| std.fmt.allocPrint(arena, "the preset {s} in {s} pins offer {s}, which this install does not offer; edit or remove it there, or pass --provider/--model", .{ name, config_path, &pin.offer_id.render() }),
                    .auto_route => |route| std.fmt.allocPrint(arena, "the preset {s} in {s} asks for '{s}', which matches no route this install has; edit it there, or pass --provider/--model", .{ name, config_path, route.selector.slice() }),
                },
                else => std.fmt.allocPrint(arena, "the preset {s} in {s}: {s}", .{ name, config_path, try failure.message(arena) }),
            },
        };
    }
};

/// What applying a preset sets, beside the route fields (`apply`).
pub const Applied = struct {
    /// The provider id its route resolved to.
    provider: []const u8,
};

/// Lower a preset's `selection` into `config`, as the flags that name the
/// same route would: `provider_profile` and `provider_channel` to its
/// route's, `model` to its route's model and, for a pinned offer,
/// `provider_offer` to that offer; `reasoning_effort` from its controls. A
/// field a flag set (`--model`, `--channel`, `--reasoning-effort`) is left as
/// the flag set it, and a pinned offer then gives way to it, as it does when
/// the endpoint moves (see below). Strings are copied into `arena`, which
/// must outlive `config`.
pub fn apply(
    arena: std.mem.Allocator,
    registry: *const registry_mod.ProviderRegistry,
    selection: config_doc.RuntimeSelection,
    config: *types.Config,
) error{OutOfMemory}!union(enum) { applied: Applied, refused: Refusal } {
    const effort: ?types.ReasoningEffort = if (config.reasoning_effort != null) null else if (selection.controls.get("reasoning_effort")) |value| switch (value) {
        .text => |text| types.ReasoningEffort.parse(text.slice()) orelse return .{ .refused = .{ .reasoning_effort = try arena.dupe(u8, text.slice()) } },
        else => return .{ .refused = .{ .reasoning_effort = "a value that is not text" } },
    } else null;

    const outcome = try provider_startup.resolveSelection(arena, registry, selection);
    const route = switch (outcome) {
        .failure => |failure| return .{ .refused = .{ .unresolved = failure } },
        .route => |value| value,
    };
    // The route's strings are `arena`'s, like everything set below.
    const provider = try arena.dupe(u8, route.provider_id.slice());
    // An offer's id covers its endpoint, so one cannot be found once the
    // endpoint moves: by `--base-url` or `METACODES_BASE_URL`, or, for
    // Metask, to the gateway its sign-in names (set after this, as for a
    // stored Metask default). The route is then its provider, channel and
    // model there.
    const endpoint_moves = config.base_url != null or route.provider_id.eqlText("metask");
    const refined = config.model_explicit or config.provider_channel != null or endpoint_moves;
    config.provider_profile = provider;
    if (config.provider_channel == null) config.provider_channel = try arena.dupe(u8, route.channel_id.slice());
    if (!config.model_explicit) {
        config.model = route.request_model_id;
        config.model_explicit = true;
    }
    // A pinned offer is the route exactly (its account included), unless a
    // flag changed one of its fields for this run.
    if (selection.target == .pinned_offer and !refined) {
        const rendered = selection.target.pinned_offer.offer_id.render();
        config.provider_offer = try arena.dupe(u8, &rendered);
    }
    if (effort) |level| config.reasoning_effort = level;
    return .{ .applied = .{ .provider = provider } };
}

pub const LocalRoute = union(enum) {
    preset: LocalPreset,
    provider: LocalProvider,
};

pub const LocalPreset = struct {
    name: []const u8,
    selection: config_doc.RuntimeSelection,
    model: ?[]const u8 = null,
};

pub const LocalProvider = struct {
    name: []const u8,
    model: ?[]const u8 = null,
};

pub fn localRoute(facts: *const Facts, choice: state_env.Choice, model: ?[]const u8) ?LocalRoute {
    if (facts.decided(.local_preset)) |found| if (facts.selection(found.name)) |selection|
        return .{ .preset = .{ .name = found.name, .selection = selection.*, .model = model } };
    return switch (choice) {
        .provider => |chosen| .{ .provider = .{ .name = chosen.name, .model = model } },
        .none, .several => null,
    };
}

pub const LocalResolved = struct {
    route: provider_startup.StartupRoute,
    reasoning_effort: ?types.ReasoningEffort = null,
};

pub fn resolveLocal(
    arena: std.mem.Allocator,
    registry: *const registry_mod.ProviderRegistry,
    local: LocalRoute,
) error{OutOfMemory}!?LocalResolved {
    var lowered: types.Config = .{};
    const request: provider_startup.StartupRequest = switch (local) {
        .provider => |provider| .{ .provider = provider.name, .model = provider.model },
        .preset => |preset| request: {
            if (preset.model) |model| {
                lowered.model = model;
                lowered.model_explicit = true;
            }
            if ((try apply(arena, registry, preset.selection, &lowered)) == .refused) return null;
            break :request .{
                .provider = lowered.provider_profile,
                .channel = lowered.provider_channel,
                .offer_id = lowered.provider_offer,
                .model = lowered.model,
            };
        },
    };
    return switch (try provider_startup.resolve(arena, registry, request)) {
        .failure => null,
        .route => |route| .{ .route = route, .reasoning_effort = lowered.reasoning_effort },
    };
}

// ── what the start says about a preset it cannot find ──────────────────────

/// One line per preset this start must report (`startup_order.Unknown`),
/// each naming where it was named and listing what config.json defines. In
/// `arena`; null when there is nothing to report.
pub fn unknownReport(
    arena: std.mem.Allocator,
    facts: *const Facts,
    unknown: startup_order.Unknown,
    env_path: []const u8,
) error{OutOfMemory}!?[]const u8 {
    if (!unknown.any()) return null;
    var out: std.ArrayList(u8) = .empty;
    const where = try definedWords(arena, facts);
    if (unknown.named) |name| {
        const named_as = switch (facts.named_origin) {
            .flag => try std.fmt.allocPrint(arena, "--preset {s}", .{name}),
            .shell => try std.fmt.allocPrint(arena, "{s}={s} (in the shell)", .{ variable, name }),
        };
        try out.print(arena, "{s}: {s}", .{ named_as, where });
    }
    if (unknown.directory) |name| {
        if (out.items.len > 0) try out.append(arena, '\n');
        try out.print(arena, "The preset {s} remembered for {s}: {s}", .{ name, facts.directory, where });
    }
    if (unknown.local) |name| {
        if (out.items.len > 0) try out.append(arena, '\n');
        try out.print(arena, "{s}={s} in {s}: {s}", .{ variable, name, env_path, where });
    }
    return out.items;
}

/// `<config.json> defines no such preset (presets: a, b).`, or why it could
/// not be looked up.
fn definedWords(arena: std.mem.Allocator, facts: *const Facts) error{OutOfMemory}![]const u8 {
    const path = if (facts.config_path.len > 0) facts.config_path else "config.json";
    if (facts.unreadable) |why| return std.fmt.allocPrint(arena, "{s} cannot be read ({s}), so no preset can be looked up.", .{ path, why });
    if (facts.defined.len == 0) return std.fmt.allocPrint(arena, "{s} defines no presets. How to: {s}", .{ path, guide_url });
    return std.fmt.allocPrint(arena, "{s} defines no such preset (presets: {s}).", .{ path, try std.mem.join(arena, ", ", facts.defined) });
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the directory key is the git worktree root inside a repository, else the directory itself" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "repo/.git");
    try tmp.dir.createDirPath(testing.io, "repo/src/deep");
    try tmp.dir.createDirPath(testing.io, "linked/sub");
    // A linked worktree's `.git` is a file.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "linked/.git", .data = "gitdir: /elsewhere\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    const repo = try std.fs.path.join(arena, &.{ root, "repo" });
    try testing.expectEqualStrings(repo, try directoryKey(arena, try std.fs.path.join(arena, &.{ root, "repo", "src", "deep" })));
    try testing.expectEqualStrings(repo, try directoryKey(arena, repo));
    const linked = try std.fs.path.join(arena, &.{ root, "linked" });
    try testing.expectEqualStrings(linked, try directoryKey(arena, try std.fs.path.join(arena, &.{ root, "linked", "sub" })));
    // Outside any repository: the directory itself. (The scratch directory
    // above sits in a checkout, so this one is a path no repository holds.)
    try testing.expectEqualStrings("/no-such-dir-489/work", try directoryKey(arena, "/no-such-dir-489/work/"));
}

test "a directory entry matches its key, written with a trailing separator or through a symlink" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "real/x");
    try tmp.dir.symLink(testing.io, "real", "alias", .{ .is_directory = true });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    const key = try std.fs.path.join(arena, &.{ root, "real", "x" });

    var document = config_doc.Document.init(testing.allocator);
    defer document.deinit();
    try document.upsertPreset("a", try config_doc.RuntimeSelection.auto("m", .{}, .session));
    try document.setDirectoryPreset(try std.fmt.allocPrint(arena, "{s}/alias/x/", .{root}), "a");
    try testing.expectEqualStrings("a", rememberedFor(&document, key).?);
    try testing.expect(rememberedFor(&document, try std.fs.path.join(arena, &.{ root, "real" })) == null);

    var exact = config_doc.Document.init(testing.allocator);
    defer exact.deinit();
    try exact.upsertPreset("b", try config_doc.RuntimeSelection.auto("m", .{}, .session));
    try exact.setDirectoryPreset(try std.fmt.allocPrint(arena, "{s}/", .{key}), "b");
    try testing.expectEqualStrings("b", rememberedFor(&exact, key).?);
}

test "a preset found at a level carries its selection; an unknown one is named with what is defined" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var document = config_doc.Document.init(testing.allocator);
    defer document.deinit();
    try document.upsertPreset("a", try config_doc.RuntimeSelection.auto("model-a", .{}, .session));
    try document.upsertPreset("b", try config_doc.RuntimeSelection.auto("model-b", .{}, .session));
    try document.setDirectoryPreset("/work/x", "b");

    const facts = try gather(arena, .{
        .flag = "a",
        .local = "typo",
        .cwd = "/work/x",
        .config_path = "/state/config.json",
        .document = .{ .read = &document },
    });
    try testing.expectEqualStrings("a", facts.named.found.name);
    try testing.expectEqual(Origin.flag, facts.named_origin);
    try testing.expectEqualStrings("/work/x", facts.directory);
    try testing.expectEqualStrings("b", facts.directory_preset.found.name);
    try testing.expectEqualStrings("typo", facts.local_preset.unknown);
    try testing.expect(facts.selection("a").?.target.auto_route.selector.eqlText("model-a"));
    try testing.expect(facts.selection("b").?.target.auto_route.selector.eqlText("model-b"));
    try testing.expect(facts.selection("typo") == null);
    try testing.expectEqualStrings("b", facts.decided(.directory_preset).?.name);
    try testing.expect(facts.decided(.stored_default) == null);

    const report = (try unknownReport(arena, &facts, .{ .local = "typo" }, "/state/.env")).?;
    try testing.expectEqualStrings("METACODES_PRESET=typo in /state/.env: /state/config.json defines no such preset (presets: a, b).", report);
    const flagged = (try unknownReport(arena, &facts, .{ .named = "nope", .directory = "gone" }, "/state/.env")).?;
    try testing.expectEqualStrings(
        "--preset nope: /state/config.json defines no such preset (presets: a, b).\n" ++
            "The preset gone remembered for /work/x: /state/config.json defines no such preset (presets: a, b).",
        flagged,
    );
    try testing.expect(try unknownReport(arena, &facts, .{}, "/state/.env") == null);

    // config.json unreadable: every name is unknown, and the report says why.
    const unreadable = try gather(arena, .{ .flag = "a", .config_path = "/state/config.json", .document = .{ .unreadable = "InvalidPreset" } });
    try testing.expectEqualStrings("a", unreadable.named.unknown);
    try testing.expectEqualStrings(
        "--preset a: /state/config.json cannot be read (InvalidPreset), so no preset can be looked up.",
        (try unknownReport(arena, &unreadable, .{ .named = "a" }, "")).?,
    );
    // Nothing defined: the report says so and links the guide.
    const empty = try gather(arena, .{ .flag = "a", .config_path = "/state/config.json" });
    try testing.expectStringStartsWith((try unknownReport(arena, &empty, .{ .named = "a" }, "")).?, "--preset a: /state/config.json defines no presets. How to: https://");
}

test "a preset lowers into the fields the flags would set, and a flag keeps its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const host = try @import("metacodes-internal").provider.host.Host.create(testing.allocator);
    defer host.destroy();
    const registry = &host.registry;

    // An auto_route selector: provider, channel and model, no offer.
    var auto = try config_doc.RuntimeSelection.auto("deepseek-v4-pro", .{}, .session);
    try auto.controls.set("reasoning_effort", try @import("metacodes-internal").provider.controls.Value.fromText("high"));
    var config: types.Config = .{};
    try testing.expect((try apply(arena, registry, auto, &config)) == .applied);
    try testing.expectEqualStrings("deepseek", config.provider_profile.?);
    try testing.expect(config.provider_channel != null);
    try testing.expectEqualStrings("deepseek-v4-pro", config.model);
    try testing.expect(config.model_explicit);
    try testing.expect(config.provider_offer == null);
    try testing.expectEqual(types.ReasoningEffort.high, config.reasoning_effort.?);

    // `--model` and `--reasoning-effort` keep theirs.
    config = .{ .model = "deepseek-flash", .model_explicit = true, .reasoning_effort = .low };
    try testing.expect((try apply(arena, registry, auto, &config)) == .applied);
    try testing.expectEqualStrings("deepseek-flash", config.model);
    try testing.expectEqual(types.ReasoningEffort.low, config.reasoning_effort.?);

    // A pinned offer is that offer, unless a flag or a moved endpoint
    // changes one of its fields.
    var catalog = try registry.buildCatalog(testing.allocator, .{ .only_provider = @import("metacodes-internal").provider.ids.Slug.lit("deepseek") });
    defer catalog.deinit();
    const offer = catalog.items()[0];
    const pinned = config_doc.RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .session);
    config = .{};
    try testing.expect((try apply(arena, registry, pinned, &config)) == .applied);
    try testing.expectEqualStrings(&offer.offer_id.render(), config.provider_offer.?);
    try testing.expectEqualStrings(offer.request_model_id, config.model);
    for ([_]types.Config{
        .{ .model = "deepseek-flash", .model_explicit = true },
        .{ .base_url = "http://127.0.0.1:9" },
    }) |start| {
        config = start;
        try testing.expect((try apply(arena, registry, pinned, &config)) == .applied);
        try testing.expect(config.provider_offer == null);
        try testing.expectEqualStrings("deepseek", config.provider_profile.?);
    }

    // What it cannot apply, it refuses, and says why in one line.
    var bad_effort = auto;
    try bad_effort.controls.set("reasoning_effort", try @import("metacodes-internal").provider.controls.Value.fromText("extreme"));
    config = .{};
    const refused = try apply(arena, registry, bad_effort, &config);
    try testing.expectEqualStrings(
        "the preset k in /s/config.json sets reasoning_effort to 'extreme'; use none, minimal, low, medium, high, xhigh or max",
        try refused.refused.message(arena, "k", "/s/config.json"),
    );
    try testing.expect(config.provider_profile == null);
    const nowhere = try config_doc.RuntimeSelection.auto("no-such-model-489", .{}, .session);
    const unresolved = try apply(arena, registry, nowhere, &config);
    try testing.expectEqualStrings(
        "the preset k in /s/config.json asks for 'no-such-model-489', which matches no route this install has; edit it there, or pass --provider/--model",
        try unresolved.refused.message(arena, "k", "/s/config.json"),
    );
}

test "what .env falls back to: its preset when config.json defines it, else the provider it configures (#489)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var document = config_doc.Document.init(testing.allocator);
    defer document.deinit();
    try document.upsertPreset("fast", try config_doc.RuntimeSelection.auto("deepseek-v4-pro", .{}, .session));
    const named: state_env.Choice = .{ .provider = .{ .name = "kimi", .named = true } };
    const several: state_env.Choice = .{ .several = &.{ "kimi", "deepseek" } };

    const Tag = std.meta.Tag(LocalRoute);
    const defined = try gather(arena, .{ .local = "fast", .document = .{ .read = &document } });
    const chosen = localRoute(&defined, named, "deepseek-flash") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Tag.preset, std.meta.activeTag(chosen));
    try testing.expectEqualStrings("fast", chosen.preset.name);
    try testing.expect(chosen.preset.selection.target.auto_route.selector.eqlText("deepseek-v4-pro"));
    try testing.expectEqualStrings("deepseek-flash", chosen.preset.model orelse "");
    for ([_]state_env.Choice{ several, .none }) |choice| {
        const other = localRoute(&defined, choice, null) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(Tag.preset, std.meta.activeTag(other));
        try testing.expectEqualStrings("fast", other.preset.name);
    }

    const undefined_preset = try gather(arena, .{ .local = "typo", .document = .{ .read = &document } });
    const provider = localRoute(&undefined_preset, named, "k2") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Tag.provider, std.meta.activeTag(provider));
    try testing.expectEqualStrings("kimi", provider.provider.name);
    try testing.expectEqualStrings("k2", provider.provider.model orelse "");
    try testing.expect(localRoute(&undefined_preset, .none, null) == null);

    const unreadable = try gather(arena, .{ .local = "fast", .document = .{ .unreadable = "InvalidPreset" } });
    try testing.expectEqual(Tag.provider, std.meta.activeTag(localRoute(&unreadable, named, null) orelse return error.TestUnexpectedResult));

    const unnamed = try gather(arena, .{ .document = .{ .read = &document } });
    try testing.expectEqual(Tag.provider, std.meta.activeTag(localRoute(&unnamed, named, null) orelse return error.TestUnexpectedResult));
    try testing.expect(localRoute(&unnamed, several, null) == null);
}

test "the preset .env falls back to resolves as level 6 of a start does (#489)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const host = try @import("metacodes-internal").provider.host.Host.create(testing.allocator);
    defer host.destroy();
    const registry = &host.registry;

    var auto = try config_doc.RuntimeSelection.auto("deepseek-v4-pro", .{}, .session);
    try auto.controls.set("reasoning_effort", try @import("metacodes-internal").provider.controls.Value.fromText("high"));
    const plain = (try resolveLocal(arena, registry, .{ .preset = .{ .name = "fast", .selection = auto } })) orelse return error.TestUnexpectedResult;
    try testing.expect(plain.route.provider_id.eqlText("deepseek"));
    try testing.expectEqualStrings("deepseek-v4-pro", plain.route.request_model_id);
    try testing.expectEqual(@as(?types.ReasoningEffort, .high), plain.reasoning_effort);

    const refined = (try resolveLocal(arena, registry, .{ .preset = .{ .name = "fast", .selection = auto, .model = "deepseek-flash" } })) orelse return error.TestUnexpectedResult;
    try testing.expect(refined.route.provider_id.eqlText("deepseek"));
    try testing.expectEqualStrings("deepseek-flash", refined.route.request_model_id);
    try testing.expectEqual(@as(?types.ReasoningEffort, .high), refined.reasoning_effort);

    var catalog = try registry.buildCatalog(testing.allocator, .{ .only_provider = @import("metacodes-internal").provider.ids.Slug.lit("deepseek") });
    defer catalog.deinit();
    const pro = for (catalog.items()) |*offer| {
        if (std.mem.eql(u8, offer.request_model_id, "deepseek-v4-pro")) break offer;
    } else return error.TestUnexpectedResult;
    const pinned = config_doc.RuntimeSelection.pinned(pro.offer_id, pro.offer_revision, .session);
    const exact = (try resolveLocal(arena, registry, .{ .preset = .{ .name = "pinned", .selection = pinned } })) orelse return error.TestUnexpectedResult;
    try testing.expect(exact.route.offer_id.eql(pro.offer_id));
    try testing.expect(exact.reasoning_effort == null);
    const given_way = (try resolveLocal(arena, registry, .{ .preset = .{ .name = "pinned", .selection = pinned, .model = "deepseek-flash" } })) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-flash", given_way.route.request_model_id);
    try testing.expect(!given_way.route.offer_id.eql(pro.offer_id));

    const by_provider = (try resolveLocal(arena, registry, .{ .provider = .{ .name = "deepseek", .model = "deepseek-flash" } })) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("deepseek-flash", by_provider.route.request_model_id);
    try testing.expect(by_provider.reasoning_effort == null);

    try testing.expect((try resolveLocal(arena, registry, .{ .preset = .{ .name = "gone", .selection = try config_doc.RuntimeSelection.auto("no-such-model-489", .{}, .session) } })) == null);
    try testing.expect((try resolveLocal(arena, registry, .{ .provider = .{ .name = "no-such-provider-489" } })) == null);
}

test "gather reads global_default from config.json, and from the lenient read when the document is unreadable (#489)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var document = config_doc.Document.init(testing.allocator);
    defer document.deinit();

    try testing.expect((try gather(arena, .{ .document = .{ .read = &document } })).global_default);
    document.global_default = false;
    try testing.expect(!(try gather(arena, .{ .document = .{ .read = &document }, .unreadable_global_default = true })).global_default);
    document.global_default = true;
    try testing.expect((try gather(arena, .{ .document = .{ .read = &document } })).global_default);

    try testing.expect((try gather(arena, .{})).global_default);
    try testing.expect((try gather(arena, .{ .document = .{ .unreadable = "InvalidPreset" } })).global_default);
    try testing.expect(!(try gather(arena, .{ .document = .{ .unreadable = "InvalidPreset" }, .unreadable_global_default = false })).global_default);
}
