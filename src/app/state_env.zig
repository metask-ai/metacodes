//! `<state root>/.env`: an install's local configuration (#486).
//!
//! A user who does not sign in configures metacodes in one file of the
//! install's state root, the directory `auth.json` lives in: which provider,
//! which key, which model. Side-by-side installs keep separate files
//! (`~/.local/opt/metacodes/state/.env`, `~/.local/opt/metacodes-dev/state/.env`).
//! `doc/LOCAL_CONFIG.md` is the user's guide to it.
//!
//! - **Only this file.** Never a `.env` in the working directory or in a
//!   repository: any cloned repository can ship one, and reading it would let
//!   that repository choose where a session's key and requests go.
//! - **An allowlist, and no request addresses.** The file may set the names a
//!   provider reads its key from (every registered profile's environment
//!   aliases, built-in and `custom_providers`), the variables `config.json`
//!   declares (`providers.<id>.credentials[].env`,
//!   `provider_catalogs.<id>.credential_env`), `METACODES_PROVIDER` and
//!   `METACODES_MODEL`. A name that moves a request (`METACODES_BASE_URL`,
//!   `METASK_GATEWAY_URL`, `METASK_SITE_URL`, `METACODES_KEY_CHECK_URL`,
//!   `METACODES_KG_URL`, any `*_URL`) is refused even when an alias names it:
//!   a custom endpoint belongs in `custom_providers`, where the endpoint
//!   policy and `--check-providers` apply. Anything else is ignored; the host
//!   warns once with the names, never the values.
//! - **No setenv.** Mutating libc's environment after startup is unsafe
//!   (`core/auth.zig`), so the accepted names are a lookup layer behind the
//!   process environment (`credential.ResolveInput.env_fallback`, and
//!   `METASK_API_KEY` through `auth.resolveRuntimeCredential`). A name the
//!   process environment sets wins.
//! - **The file's choice of provider ranks last.** `METACODES_PROVIDER` and
//!   `METACODES_MODEL` here apply only when no flag or environment variable
//!   names a provider, no `/model` default is stored, and no Metask sign-in
//!   exists (`src/main.zig`). Without `METACODES_PROVIDER`, a file holding one
//!   provider's key uses that provider (`Loaded.choice`); keys that merely
//!   exist in the shell environment never select one.
//! - **Host-only.** `src/main.zig` loads it once at startup and hands the
//!   layer down (`types.Config.credential_env_fallback`), so an edit applies
//!   on the next start. `src/app/` is outside metacodes-core
//!   (`zig build subsystem:boundary`), so the library and AgentCore cannot
//!   read it.
//!
//! The format is the common subset of dotenv files:
//!
//! - one `NAME=value` per line; blank lines and lines starting with `#` are
//!   skipped; an `export ` prefix is allowed; whitespace around the name and
//!   the `=` is dropped;
//! - a value in single quotes is literal; in double quotes `\"`, `\\` and
//!   `\n` are the only escapes; `$NAME` is never expanded;
//! - an unquoted value ends at a `#` that follows whitespace (an inline
//!   comment), and loses its trailing whitespace;
//! - CRLF line ends and a leading UTF-8 byte-order mark are accepted;
//! - an empty value is the same as no assignment;
//! - a name set twice keeps its last value;
//! - any other line is skipped as malformed and reported by its number only:
//!   it may hold a secret. So is an assignment the file may not make whose
//!   name is not written like a variable name (capitals, digits, `_`): a
//!   base64 line of a pasted key can end in `=` and look like `NAME=`.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const pfs = @import("platform").fs;
const credential = @import("../provider/credential.zig");
const profile_mod = @import("../provider/profile.zig");
const registry_mod = @import("../provider/registry.zig");
const config_doc = @import("../provider/config_doc.zig");

pub const file_name = ".env";
pub const example_file_name = ".env.example";
pub const provider_variable = "METACODES_PROVIDER";
pub const model_variable = "METACODES_MODEL";
/// The how-to page every hint about the file links.
pub const guide_url = "https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md";
/// A configuration file of a few dozen lines; anything near this is not one.
pub const max_file_bytes: usize = 64 * 1024;

// ── parser ──────────────────────────────────────────────────────────────────

pub const Assignment = struct {
    name: []const u8,
    /// Owned by the parse's arena. Empty when the file assigns nothing.
    value: []u8,
    /// 1-based line of the assignment that holds the value.
    line: u32,
};

pub const Parsed = struct {
    /// One per name, in order of first appearance, each with its last value.
    assignments: []Assignment,
    /// 1-based numbers of the lines that are neither blank, a comment, nor an
    /// assignment.
    malformed: []u32,
};

/// Parse `text`, copying every name and value into `arena`, so the caller can
/// wipe `text` as soon as this returns.
pub fn parse(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Parsed {
    var assignments: std.ArrayList(Assignment) = .empty;
    var malformed: std.ArrayList(u32) = .empty;
    const bom = "\xEF\xBB\xBF";
    const body = if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var number: u32 = 0;
    while (lines.next()) |raw| {
        number +|= 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const outcome = parseLine(arena, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => {
                try malformed.append(arena, number);
                continue;
            },
        };
        const parsed = outcome orelse continue;
        for (assignments.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, parsed.name)) continue;
            std.crypto.secureZero(u8, existing.value);
            existing.value = parsed.value;
            existing.line = number;
            break;
        } else try assignments.append(arena, .{ .name = parsed.name, .value = parsed.value, .line = number });
    }
    return .{
        .assignments = try assignments.toOwnedSlice(arena),
        .malformed = try malformed.toOwnedSlice(arena),
    };
}

const Line = struct { name: []const u8, value: []u8 };

/// One line: null for a blank line or a comment.
fn parseLine(arena: std.mem.Allocator, line: []const u8) error{ OutOfMemory, Malformed }!?Line {
    var rest = std.mem.trim(u8, line, " \t");
    if (rest.len == 0 or rest[0] == '#') return null;
    if (std.mem.startsWith(u8, rest, "export") and rest.len > "export".len and isBlank(rest["export".len])) {
        rest = std.mem.trimStart(u8, rest["export".len..], " \t");
    }
    const equals = std.mem.indexOfScalar(u8, rest, '=') orelse return error.Malformed;
    const name = std.mem.trimEnd(u8, rest[0..equals], " \t");
    if (!isName(name)) return error.Malformed;
    const after = rest[equals + 1 ..];
    const value_start = std.mem.trimStart(u8, after, " \t");
    const lead = after.len - value_start.len;
    const value = if (value_start.len > 0 and value_start[0] == '"')
        try doubleQuoted(arena, value_start)
    else if (value_start.len > 0 and value_start[0] == '\'')
        try singleQuoted(arena, value_start)
    else
        try arena.dupe(u8, unquoted(value_start, lead > 0));
    return .{ .name = try arena.dupe(u8, name), .value = value };
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isName(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// An unquoted value up to an inline comment (a `#` after whitespace).
/// `after_blank` says whether whitespace preceded `text` on its line.
fn unquoted(text: []const u8, after_blank: bool) []const u8 {
    for (text, 0..) |c, index| {
        if (c != '#') continue;
        const blank_before = if (index == 0) after_blank else isBlank(text[index - 1]);
        if (blank_before) return std.mem.trimEnd(u8, text[0..index], " \t");
    }
    return std.mem.trimEnd(u8, text, " \t");
}

/// `'…'`: literal up to the next `'`; only whitespace or a comment may follow.
fn singleQuoted(arena: std.mem.Allocator, text: []const u8) error{ OutOfMemory, Malformed }![]u8 {
    const close = std.mem.indexOfScalarPos(u8, text, 1, '\'') orelse return error.Malformed;
    try expectTrailer(text[close + 1 ..]);
    return arena.dupe(u8, text[1..close]);
}

/// `"…"` with `\"`, `\\` and `\n`; any other backslash stays as written.
fn doubleQuoted(arena: std.mem.Allocator, text: []const u8) error{ OutOfMemory, Malformed }![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer {
        std.crypto.secureZero(u8, out.items);
        out.deinit(arena);
    }
    var index: usize = 1;
    while (index < text.len) {
        const c = text[index];
        if (c == '"') {
            try expectTrailer(text[index + 1 ..]);
            return out.toOwnedSlice(arena);
        }
        if (c == '\\' and index + 1 < text.len) {
            const escaped: ?u8 = switch (text[index + 1]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                else => null,
            };
            if (escaped) |byte| {
                try out.append(arena, byte);
                index += 2;
                continue;
            }
        }
        try out.append(arena, c);
        index += 1;
    }
    // No closing quote: a value never continues on the next line.
    return error.Malformed;
}

fn expectTrailer(text: []const u8) error{Malformed}!void {
    const trailer = std.mem.trimStart(u8, text, " \t");
    if (trailer.len > 0 and trailer[0] != '#') return error.Malformed;
}

// ── which names the file may set ────────────────────────────────────────────

/// Names that would move a request: refused even when a provider alias or
/// `config.json` names one. The file must never decide where a key is sent.
pub const request_address_variables = [_][]const u8{
    "METACODES_BASE_URL",
    "METASK_GATEWAY_URL",
    "METASK_SITE_URL",
    "METACODES_KEY_CHECK_URL",
    "METACODES_KG_URL",
};

pub fn isRequestAddress(name: []const u8) bool {
    for (request_address_variables) |refused| {
        if (std.ascii.eqlIgnoreCase(name, refused)) return true;
    }
    return std.ascii.endsWithIgnoreCase(name, "_URL");
}

/// The names the file may set besides the two selection variables.
pub const Allowlist = struct {
    /// Names a provider profile reads its key from (its environment
    /// aliases), each with that provider's id: a key here can select that
    /// provider. A name two providers read is listed once for each.
    keys: []const Key = &.{},
    /// Other names the file may set, which select no provider: a credential
    /// pool's variable (start-up resolution reads a profile's aliases, never
    /// a pool) and a catalog's `credential_env` (a key that fetches a model
    /// list).
    others: []const []const u8 = &.{},

    pub const Key = struct { name: []const u8, provider: []const u8 };

    pub fn accepts(self: Allowlist, name: []const u8) bool {
        if (isRequestAddress(name)) return false;
        if (std.mem.eql(u8, name, provider_variable) or std.mem.eql(u8, name, model_variable)) return true;
        for (self.keys) |key| if (std.mem.eql(u8, key.name, name)) return true;
        for (self.others) |other| if (std.mem.eql(u8, other, name)) return true;
        return false;
    }
};

/// The allowlist of the provider runtime a session builds: every registered
/// profile's aliases (built-in, `custom_providers`, ingested catalogs), every
/// configured pool credential's variable, and every catalog's
/// `credential_env`. Strings are copied into `arena`, so the registry and
/// document may go first.
pub fn allowlistFrom(
    arena: std.mem.Allocator,
    profiles: []const profile_mod.ProviderProfile,
    document: ?*const config_doc.Document,
    config_text: ?[]const u8,
) error{OutOfMemory}!Allowlist {
    var keys: std.ArrayList(Allowlist.Key) = .empty;
    for (profiles) |profile| {
        const provider = try arena.dupe(u8, profile.id.slice());
        for (profile.env_aliases) |alias| {
            try keys.append(arena, .{ .name = try arena.dupe(u8, alias.name), .provider = provider });
        }
    }
    var others: std.ArrayList([]const u8) = .empty;
    // A pool credential's variable is accepted but selects no provider: the
    // start-up credential resolution reads a profile's aliases, never a pool,
    // so a file holding only a pool variable would choose a provider and then
    // fail for want of its key.
    if (document) |doc| for (doc.providers.items) |*entry| {
        for (entry.credentials.items()) |*pooled| {
            try others.append(arena, try arena.dupe(u8, pooled.env.slice()));
        }
    };
    if (config_text) |text| catalogs: {
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch break :catalogs;
        if (root != .object) break :catalogs;
        const section = root.object.get("provider_catalogs") orelse break :catalogs;
        if (section != .object) break :catalogs;
        var it = section.object.iterator();
        while (it.next()) |pair| {
            if (pair.value_ptr.* != .object) continue;
            const value = pair.value_ptr.object.get("credential_env") orelse continue;
            if (value != .string or value.string.len == 0) continue;
            // The parsed string may borrow `text`, which the caller frees.
            try others.append(arena, try arena.dupe(u8, value.string));
        }
    }
    return .{ .keys = try keys.toOwnedSlice(arena), .others = try others.toOwnedSlice(arena) };
}

// ── the loaded file ─────────────────────────────────────────────────────────

pub const Status = enum {
    /// The host has no state root, so there is no file.
    no_state_root,
    absent,
    read,
    /// It exists but could not be opened or read.
    unreadable,
    /// A directory, a FIFO, a socket: never opened for reading.
    not_a_file,
    /// Larger than `max_file_bytes`.
    too_large,
};

pub const Ignored = struct {
    name: []const u8,
    reason: Reason,

    pub const Reason = enum {
        /// A request address (`isRequestAddress`).
        request_address,
        /// Not a name metacodes reads from this file.
        unknown,
    };
};

/// What the file says once the host's rules are applied. Values only of
/// accepted names are kept, owned here and wiped by `deinit`.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    /// Absolute; empty when there is no state root.
    path: []const u8 = "",
    status: Status = .absent,
    /// Accepted assignments with a value, in file order.
    accepted: []const Assignment = &.{},
    /// Names set but not read, in file order. Never their values.
    ignored: []const Ignored = &.{},
    /// Line numbers of malformed lines.
    malformed: []const u32 = &.{},
    /// The provider ids whose keys the file holds, sorted, each once.
    key_providers: []const []const u8 = &.{},
    /// POSIX permission bits of the file; null on Windows or when not read.
    permissions: ?u32 = null,

    pub fn deinit(self: *Loaded) void {
        for (self.accepted) |entry| std.crypto.secureZero(u8, entry.value);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The file's value for `name`, when it accepted one. Never the process
    /// environment's: callers consult that first.
    pub fn get(self: *const Loaded, name: []const u8) ?[]const u8 {
        for (self.accepted) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }

    /// The file as the layer below the process environment
    /// (`credential.ResolveInput.env_fallback`). Borrows `self`.
    pub fn lookup(self: *const Loaded) credential.EnvLookup {
        const Impl = struct {
            fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
                const loaded: *const Loaded = @ptrCast(@alignCast(ctx));
                return loaded.get(name);
            }
        };
        return .{ .ctx = @ptrCast(@constCast(self)), .getFn = Impl.get };
    }

    /// Which provider the file configures. The caller decides whether the
    /// file's choice applies at all (it ranks last).
    pub fn choice(self: *const Loaded) Choice {
        if (self.get(provider_variable)) |name| return .{ .provider = .{ .name = name, .named = true } };
        return switch (self.key_providers.len) {
            0 => .none,
            1 => .{ .provider = .{ .name = self.key_providers[0], .named = false } },
            else => .{ .several = self.key_providers },
        };
    }

    /// Other users may read or change the file (POSIX mode bits beyond 0700).
    pub fn sharedWithOthers(self: *const Loaded) bool {
        const mode = self.permissions orelse return false;
        return mode & 0o077 != 0;
    }

    /// One line naming what the file sets that is not read, or null when
    /// everything was. Names and line numbers only, never a value.
    pub fn ignoredSummary(self: *const Loaded, scratch: std.mem.Allocator) error{OutOfMemory}!?[]u8 {
        if (self.ignored.len == 0 and self.malformed.len == 0) return null;
        var out: std.Io.Writer.Allocating = .init(scratch);
        errdefer out.deinit();
        self.writeIgnored(&out.writer) catch return error.OutOfMemory;
        return try out.toOwnedSlice();
    }

    fn writeIgnored(self: *const Loaded, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}: ignored ", .{self.path});
        var parts: usize = 0;
        for ([_]Ignored.Reason{ .request_address, .unknown }) |reason| {
            var names: usize = 0;
            for (self.ignored) |entry| {
                if (entry.reason != reason) continue;
                try w.writeAll(if (names > 0) ", " else if (parts > 0) "; " else "");
                try w.writeAll(entry.name);
                names += 1;
            }
            if (names == 0) continue;
            parts += 1;
            try w.writeAll(switch (reason) {
                .request_address => " (a request address is never read from it: a custom endpoint goes in config.json custom_providers)",
                .unknown => " (not a name it sets)",
            });
        }
        if (self.malformed.len > 0) {
            try w.writeAll(if (parts > 0) "; " else "");
            try w.writeAll(if (self.malformed.len == 1) "line " else "lines ");
            for (self.malformed, 0..) |line, index| {
                if (index > 0) try w.writeAll(", ");
                try w.print("{d}", .{line});
            }
            try w.writeAll(" (not NAME=value)");
        }
        try w.print(". The names it reads: {s}", .{guide_url});
    }
};

pub const Choice = union(enum) {
    /// Neither `METACODES_PROVIDER` nor any provider's key.
    none,
    /// `METACODES_PROVIDER` (`named`), or the one provider whose key the file
    /// holds. `name` is a provider id or alias, as `--provider` takes.
    provider: struct { name: []const u8, named: bool },
    /// Keys of several providers and no `METACODES_PROVIDER`: their ids.
    several: []const []const u8,
};

/// Whether `<state_root>/.env` exists in any form, without opening it: a
/// host builds the allowlist only when there is a file to apply it to.
pub fn exists(state_root: []const u8) bool {
    if (state_root.len == 0) return false;
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}{c}{s}", .{ state_root, std.fs.path.sep, file_name }) catch return false;
    return pfs.exists(path.ptr);
}

/// Read `<state_root>/.env` and apply `allowlist`. Never fails on the file:
/// a missing, unreadable or malformed one is reported in the result.
pub fn load(gpa: std.mem.Allocator, state_root: []const u8, allowlist: Allowlist) error{OutOfMemory}!Loaded {
    var loaded: Loaded = .{ .arena = .init(gpa) };
    errdefer loaded.arena.deinit();
    if (state_root.len == 0) {
        loaded.status = .no_state_root;
        return loaded;
    }
    const arena = loaded.arena.allocator();
    loaded.path = try std.fs.path.join(arena, &.{ state_root, file_name });

    var read = readBounded(gpa, loaded.path);
    defer read.deinit(gpa);
    loaded.status = read.status;
    loaded.permissions = read.permissions;
    const bytes = read.bytes orelse return loaded;

    const parsed = try parse(arena, bytes);
    var malformed: std.ArrayList(u32) = .empty;
    try malformed.appendSlice(arena, parsed.malformed);
    var accepted: std.ArrayList(Assignment) = .empty;
    var ignored: std.ArrayList(Ignored) = .empty;
    var providers: std.ArrayList([]const u8) = .empty;
    for (parsed.assignments) |entry| {
        if (entry.value.len == 0) continue;
        const reason: ?Ignored.Reason = if (isRequestAddress(entry.name))
            .request_address
        else if (!allowlist.accepts(entry.name))
            .unknown
        else
            null;
        if (reason) |why| {
            // The value is never read again: do not keep it around.
            std.crypto.secureZero(u8, entry.value);
            if (!reportableName(entry.name)) {
                // Not written like a variable name: it may be part of a
                // secret (a base64 line ending in `=`), so the line is
                // reported by its number only and the name wiped too.
                std.crypto.secureZero(u8, @constCast(entry.name));
                try malformed.append(arena, entry.line);
                continue;
            }
            try ignored.append(arena, .{ .name = entry.name, .reason = why });
            continue;
        }
        try accepted.append(arena, entry);
        for (allowlist.keys) |key| {
            if (!std.mem.eql(u8, key.name, entry.name)) continue;
            for (providers.items) |known| {
                if (std.mem.eql(u8, known, key.provider)) break;
            } else try providers.append(arena, try arena.dupe(u8, key.provider));
        }
    }
    std.mem.sort([]const u8, providers.items, {}, lessThan);
    std.mem.sort(u32, malformed.items, {}, std.sort.asc(u32));
    loaded.malformed = try malformed.toOwnedSlice(arena);
    loaded.accepted = try accepted.toOwnedSlice(arena);
    loaded.ignored = try ignored.toOwnedSlice(arena);
    loaded.key_providers = try providers.toOwnedSlice(arena);
    return loaded;
}

/// Whether an ignored name may be printed: capitals, digits and `_`, at most
/// 64 bytes, as environment variable names are written. Anything else may be
/// a fragment of a secret and is reported by its line number only.
fn reportableName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const ReadResult = struct {
    status: Status,
    /// The file's bytes: a prefix of `storage`.
    bytes: ?[]const u8 = null,
    /// Owned by the caller's allocator; wiped by `deinit`.
    storage: ?[]u8 = null,
    permissions: ?u32 = null,

    fn deinit(self: *ReadResult, gpa: std.mem.Allocator) void {
        if (self.storage) |storage| {
            std.crypto.secureZero(u8, storage);
            gpa.free(storage);
        }
        self.* = .{ .status = self.status };
    }
};

const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;

fn readBounded(gpa: std.mem.Allocator, path: []const u8) ReadResult {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return .{ .status = .unreadable };
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    // Opening a FIFO for reading blocks until a writer comes: look first.
    if (pfs.statMode(path_z, true)) |mode| {
        if (mode & S_IFMT != S_IFREG) return .{ .status = .not_a_file };
    }
    const fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return .{ .status = if (pfs.lastErrnoIs(.NOENT)) .absent else .unreadable };
    defer pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return .{ .status = .unreadable };
    if (!info.is_regular) return .{ .status = .not_a_file };
    const permissions: ?u32 = if (is_windows) null else info.mode & 0o777;
    if (info.size > max_file_bytes) return .{ .status = .too_large, .permissions = permissions };
    // One byte over the limit tells a file that grew past it since `fileInfo`.
    const storage = gpa.alloc(u8, max_file_bytes + 1) catch return .{ .status = .unreadable, .permissions = permissions };
    var result: ReadResult = .{ .status = .read, .storage = storage, .permissions = permissions };
    var len: usize = 0;
    while (len < storage.len) {
        const n = pfs.read(fd, storage[len..]);
        if (n < 0) {
            result.deinit(gpa);
            return .{ .status = .unreadable, .permissions = permissions };
        }
        if (n == 0) break;
        len += @intCast(n);
    }
    if (len > max_file_bytes) {
        result.deinit(gpa);
        return .{ .status = .too_large, .permissions = permissions };
    }
    result.bytes = storage[0..len];
    return result;
}

// ── the template `metacodes install` writes ─────────────────────────────────

/// `<state root>/.env.example`: every provider in `profiles` with its
/// canonical variable, plus the selection variables. No value in it.
pub fn renderExample(arena: std.mem.Allocator, profiles: []const profile_mod.ProviderProfile) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    writeExample(&out.writer, profiles) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn writeExample(w: *std.Io.Writer, profiles: []const profile_mod.ProviderProfile) std.Io.Writer.Error!void {
    try w.writeAll(example_header);
    for (profiles) |profile| {
        const name = canonicalVariable(profile) orelse continue;
        try w.print("# {s}=", .{name});
        var pad = name.len;
        while (pad < 28) : (pad += 1) try w.writeByte(' ');
        try w.print("# {s} (--provider {s})", .{ profile.display_name, profile.id.slice() });
        if (profile.id.eqlText("metask")) try w.writeAll("; `metacodes login` signs in without a key");
        try w.writeByte('\n');
    }
}

const example_header =
    \\# metacodes local configuration: a template.
    \\#
    \\# Copy this file to `.env` in this directory (the install's state root) and
    \\# fill in what you use. metacodes reads `.env` when it starts, so start it
    \\# again after an edit. `metacodes install` and `metacodes update` rewrite
    \\# this template and never touch `.env`.
    \\#
    \\# One NAME=value per line; `#` starts a comment. Only the names below, the
    \\# variables config.json declares and METACODES_PROVIDER / METACODES_MODEL
    \\# are read; any other name is ignored with a warning. Request addresses
    \\# (METACODES_BASE_URL and every other *_URL) are never read from here: a
    \\# custom endpoint goes in config.json `custom_providers`. The shell
    \\# environment wins over this file, and a Metask sign-in or a default
    \\# chosen in /model comes before the provider it names.
    \\#
    \\# Guide: https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md
    \\
    \\# Which provider, and which of its models. Without METACODES_PROVIDER, a
    \\# file that holds one provider's key uses that provider.
    \\# METACODES_PROVIDER=deepseek
    \\# METACODES_MODEL=deepseek-v4-pro
    \\
    \\# One key per provider:
    \\
;

/// The variable a profile documents first: its canonical alias, else its
/// first.
fn canonicalVariable(profile: profile_mod.ProviderProfile) ?[]const u8 {
    for (profile.env_aliases) |alias| if (alias.canonical) return alias.name;
    if (profile.env_aliases.len > 0) return profile.env_aliases[0].name;
    return null;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseForTest(arena: std.mem.Allocator, text: []const u8) !Parsed {
    return parse(arena, text);
}

fn valueOf(parsed: Parsed, name: []const u8) ?[]const u8 {
    for (parsed.assignments) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

test "parse: comments, blank lines, export, whitespace around the equals sign" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseForTest(arena_state.allocator(), "# a comment\n" ++
        "\n" ++
        "   # an indented comment\n" ++
        "DEEPSEEK_API_KEY=sk-one\n" ++
        "export OPENAI_API_KEY=sk-two\n" ++
        "export\tTAB_KEY=tab\n" ++
        "  SPACED_KEY \t=   spaced value\t\n" ++
        "exported=not-a-prefix\n");
    try testing.expectEqual(@as(usize, 5), parsed.assignments.len);
    try testing.expectEqualStrings("sk-one", valueOf(parsed, "DEEPSEEK_API_KEY").?);
    try testing.expectEqualStrings("sk-two", valueOf(parsed, "OPENAI_API_KEY").?);
    try testing.expectEqualStrings("tab", valueOf(parsed, "TAB_KEY").?);
    try testing.expectEqualStrings("spaced value", valueOf(parsed, "SPACED_KEY").?);
    try testing.expectEqualStrings("not-a-prefix", valueOf(parsed, "exported").?);
    try testing.expectEqual(@as(usize, 0), parsed.malformed.len);
}

test "parse: single quotes are literal, double quotes know three escapes, nothing expands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseForTest(arena_state.allocator(),
        \\SINGLE='a "b" \n $HOME # kept'
        \\DOUBLE="say \"hi\" \\ then\nnext"
        \\OTHER_ESCAPE="a\tb"
        \\DOLLAR=$HOME/x
        \\DOLLAR_QUOTED="${HOME}"
        \\QUOTED_COMMENT="value" # trailing comment
        \\INNER_QUOTE=ab"c'd
    );
    try testing.expectEqualStrings("a \"b\" \\n $HOME # kept", valueOf(parsed, "SINGLE").?);
    try testing.expectEqualStrings("say \"hi\" \\ then\nnext", valueOf(parsed, "DOUBLE").?);
    try testing.expectEqualStrings("a\\tb", valueOf(parsed, "OTHER_ESCAPE").?);
    try testing.expectEqualStrings("$HOME/x", valueOf(parsed, "DOLLAR").?);
    try testing.expectEqualStrings("${HOME}", valueOf(parsed, "DOLLAR_QUOTED").?);
    try testing.expectEqualStrings("value", valueOf(parsed, "QUOTED_COMMENT").?);
    try testing.expectEqualStrings("ab\"c'd", valueOf(parsed, "INNER_QUOTE").?);
    try testing.expectEqual(@as(usize, 0), parsed.malformed.len);
}

test "parse: inline comments end unquoted values only after whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseForTest(arena_state.allocator(),
        \\WITH_COMMENT=value # comment
        \\HASH_INSIDE=abc#def
        \\HASH_FIRST=#abc
        \\ONLY_COMMENT=   # nothing here
    );
    try testing.expectEqualStrings("value", valueOf(parsed, "WITH_COMMENT").?);
    try testing.expectEqualStrings("abc#def", valueOf(parsed, "HASH_INSIDE").?);
    try testing.expectEqualStrings("#abc", valueOf(parsed, "HASH_FIRST").?);
    try testing.expectEqualStrings("", valueOf(parsed, "ONLY_COMMENT").?);
}

test "parse: CRLF, a byte-order mark, empty values, and a name set twice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseForTest(arena_state.allocator(), "\xEF\xBB\xBFFIRST=one\r\nEMPTY=\r\nQUOTED_EMPTY=\"\"\r\nTWICE=old\r\nTWICE=new\r\nUNSET_LATER=x\r\nUNSET_LATER=\r\n");
    try testing.expectEqualStrings("one", valueOf(parsed, "FIRST").?);
    try testing.expectEqualStrings("", valueOf(parsed, "EMPTY").?);
    try testing.expectEqualStrings("", valueOf(parsed, "QUOTED_EMPTY").?);
    try testing.expectEqualStrings("new", valueOf(parsed, "TWICE").?);
    try testing.expectEqualStrings("", valueOf(parsed, "UNSET_LATER").?);
    // One entry per name, at the line of its last assignment.
    var twice: usize = 0;
    for (parsed.assignments) |entry| if (std.mem.eql(u8, entry.name, "TWICE")) {
        twice += 1;
        try testing.expectEqual(@as(u32, 5), entry.line);
    };
    try testing.expectEqual(@as(usize, 1), twice);
}

test "parse: malformed lines are skipped and reported by number" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseForTest(arena_state.allocator(),
        \\GOOD=1
        \\no equals sign here
        \\1BAD_NAME=x
        \\BAD NAME=x
        \\UNCLOSED="sk-secret
        \\UNCLOSED_SINGLE='sk-secret
        \\JUNK_AFTER="a" b
        \\=no-name
        \\export
        \\ALSO_GOOD=2
    );
    try testing.expectEqual(@as(usize, 2), parsed.assignments.len);
    try testing.expectEqualStrings("1", valueOf(parsed, "GOOD").?);
    try testing.expectEqualStrings("2", valueOf(parsed, "ALSO_GOOD").?);
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5, 6, 7, 8, 9 }, parsed.malformed);
}

test "request addresses are refused whatever names them" {
    for (request_address_variables) |name| try testing.expect(isRequestAddress(name));
    try testing.expect(isRequestAddress("OPENAI_BASE_URL"));
    try testing.expect(isRequestAddress("my_relay_url"));
    try testing.expect(!isRequestAddress("DEEPSEEK_API_KEY"));
    try testing.expect(!isRequestAddress("URL_TOKEN"));

    // Even an alias that a provider declares.
    const allowlist: Allowlist = .{ .keys = &.{.{ .name = "RELAY_URL", .provider = "relay" }} };
    try testing.expect(!allowlist.accepts("RELAY_URL"));
    try testing.expect(allowlist.accepts(provider_variable));
    try testing.expect(allowlist.accepts(model_variable));
    try testing.expect(!allowlist.accepts("METACODES_PRESET"));
}

const TestRoot = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",

    fn init(self: *TestRoot) !void {
        self.tmp = testing.tmpDir(.{});
        self.path = self.buf[0..try self.tmp.dir.realPath(testing.io, &self.buf)];
    }

    fn write(self: *TestRoot, text: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = text });
    }
};

const test_allowlist: Allowlist = .{
    .keys = &.{
        .{ .name = "DEEPSEEK_API_KEY", .provider = "deepseek" },
        .{ .name = "OPENAI_API_KEY", .provider = "openai" },
        .{ .name = "ZAI_API_KEY", .provider = "zai-coding-plan" },
        .{ .name = "GLM_API_KEY", .provider = "zai-coding-plan" },
        .{ .name = "METASK_API_KEY", .provider = "metask" },
    },
    .others = &.{"CATALOG_TOKEN"},
};

test "load: accepted names, ignored names without their values, and the choice" {
    var root: TestRoot = .{ .tmp = undefined };
    try root.init();
    defer root.tmp.cleanup();
    try root.write(
        \\DEEPSEEK_API_KEY=sk-deepseek
        \\METACODES_BASE_URL=http://127.0.0.1:9/v1/messages
        \\METASK_GATEWAY_URL=http://127.0.0.1:9
        \\FOO=bar
        \\CATALOG_TOKEN=cat
        \\EMPTY_UNKNOWN=
        \\this line is broken
        \\METACODES_PRESET=fast
    );
    var loaded = try load(testing.allocator, root.path, test_allowlist);
    defer loaded.deinit();
    try testing.expectEqual(Status.read, loaded.status);
    try testing.expectEqualStrings("sk-deepseek", loaded.get("DEEPSEEK_API_KEY").?);
    try testing.expectEqualStrings("cat", loaded.get("CATALOG_TOKEN").?);
    try testing.expect(loaded.get("METACODES_BASE_URL") == null);
    try testing.expect(loaded.get("FOO") == null);
    try testing.expectEqual(@as(usize, 4), loaded.ignored.len);
    try testing.expectEqualStrings("METACODES_BASE_URL", loaded.ignored[0].name);
    try testing.expectEqual(Ignored.Reason.request_address, loaded.ignored[0].reason);
    try testing.expectEqual(Ignored.Reason.request_address, loaded.ignored[1].reason);
    try testing.expectEqualStrings("FOO", loaded.ignored[2].name);
    try testing.expectEqual(Ignored.Reason.unknown, loaded.ignored[2].reason);
    try testing.expectEqualStrings("METACODES_PRESET", loaded.ignored[3].name);
    try testing.expectEqualSlices(u32, &.{7}, loaded.malformed);

    const summary = (try loaded.ignoredSummary(testing.allocator)).?;
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.indexOf(u8, summary, "METACODES_BASE_URL") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "FOO") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "line 7") != null);
    for ([_][]const u8{ "127.0.0.1", "bar", "fast", "broken" }) |value| {
        try testing.expect(std.mem.indexOf(u8, summary, value) == null);
    }

    switch (loaded.choice()) {
        .provider => |chosen| {
            try testing.expectEqualStrings("deepseek", chosen.name);
            try testing.expect(!chosen.named);
        },
        else => return error.TestUnexpectedResult,
    }
    const layer = loaded.lookup();
    try testing.expectEqualStrings("sk-deepseek", layer.get("DEEPSEEK_API_KEY").?);
    try testing.expect(layer.get("FOO") == null);
}

test "load: the choice is METACODES_PROVIDER, else one provider's keys, else none of several" {
    var root: TestRoot = .{ .tmp = undefined };
    try root.init();
    defer root.tmp.cleanup();

    // Two aliases of one provider are one provider.
    try root.write("ZAI_API_KEY=a\nGLM_API_KEY=b\n");
    var one = try load(testing.allocator, root.path, test_allowlist);
    try testing.expectEqualStrings("zai-coding-plan", one.choice().provider.name);
    one.deinit();

    try root.write("DEEPSEEK_API_KEY=a\nOPENAI_API_KEY=b\n");
    var several = try load(testing.allocator, root.path, test_allowlist);
    const listed = several.choice().several;
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("deepseek", listed[0]);
    try testing.expectEqualStrings("openai", listed[1]);
    several.deinit();

    try root.write("DEEPSEEK_API_KEY=a\nOPENAI_API_KEY=b\nMETACODES_PROVIDER=openai\nMETACODES_MODEL=gpt-x\n");
    var named = try load(testing.allocator, root.path, test_allowlist);
    const chosen = named.choice().provider;
    try testing.expectEqualStrings("openai", chosen.name);
    try testing.expect(chosen.named);
    try testing.expectEqualStrings("gpt-x", named.get(model_variable).?);
    named.deinit();

    // A catalog's token selects nothing; an empty provider name is unset.
    try root.write("CATALOG_TOKEN=a\nMETACODES_PROVIDER=\n");
    var none = try load(testing.allocator, root.path, test_allowlist);
    try testing.expect(none.choice() == .none);
    none.deinit();
}

test "load: absent, not a file, too large, no state root" {
    var root: TestRoot = .{ .tmp = undefined };
    try root.init();
    defer root.tmp.cleanup();

    var absent = try load(testing.allocator, root.path, test_allowlist);
    try testing.expectEqual(Status.absent, absent.status);
    try testing.expect(absent.choice() == .none);
    absent.deinit();

    var no_root = try load(testing.allocator, "", test_allowlist);
    try testing.expectEqual(Status.no_state_root, no_root.status);
    no_root.deinit();

    try root.tmp.dir.createDirPath(testing.io, file_name);
    var directory = try load(testing.allocator, root.path, test_allowlist);
    try testing.expectEqual(Status.not_a_file, directory.status);
    directory.deinit();
    try root.tmp.dir.deleteDir(testing.io, file_name);

    const big = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, '#');
    try root.write(big);
    var too_large = try load(testing.allocator, root.path, test_allowlist);
    try testing.expectEqual(Status.too_large, too_large.status);
    too_large.deinit();
}

test "load: other users' access to the file is reported" {
    if (is_windows) return error.SkipZigTest;
    var root: TestRoot = .{ .tmp = undefined };
    try root.init();
    defer root.tmp.cleanup();
    try root.write("DEEPSEEK_API_KEY=a\n");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ root.path, file_name });

    _ = pfs.chmod(path_z.ptr, 0o644);
    var shared = try load(testing.allocator, root.path, test_allowlist);
    try testing.expectEqual(@as(?u32, 0o644), shared.permissions);
    try testing.expect(shared.sharedWithOthers());
    shared.deinit();

    _ = pfs.chmod(path_z.ptr, 0o600);
    var private = try load(testing.allocator, root.path, test_allowlist);
    try testing.expect(!private.sharedWithOthers());
    private.deinit();
}

test "load: an ignored line not written like a variable name is reported by number only" {
    var root: TestRoot = .{ .tmp = undefined };
    try root.init();
    defer root.tmp.cleanup();
    // A key pasted in PEM form: its base64 lines can end in `=` and so parse
    // as `NAME=`. They must never be printed as an ignored name.
    try root.write(
        \\-----BEGIN PRIVATE KEY-----
        \\MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7b8==
        \\-----END PRIVATE KEY-----
        \\FOO=bar
        \\lower_case_name=value
        \\
    );
    var loaded = try load(testing.allocator, root.path, test_allowlist);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.ignored.len);
    try testing.expectEqualStrings("FOO", loaded.ignored[0].name);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 5 }, loaded.malformed);
    const summary = (try loaded.ignoredSummary(testing.allocator)).?;
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.indexOf(u8, summary, "MIIE") == null);
    try testing.expect(std.mem.indexOf(u8, summary, "lower_case_name") == null);
    try testing.expect(std.mem.indexOf(u8, summary, "lines 1, 2, 3, 5") != null);
}

test "allowlistFrom: every registered alias, every pool variable, every catalog token" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var document = try config_doc.parse(testing.allocator,
        \\{"providers": {"openai": {"credentials": [
        \\  {"id": "work", "env": "OPENAI_WORK_KEY", "kind": "api_key"}]}}}
    );
    defer document.deinit();
    const allowlist = try allowlistFrom(
        arena,
        &registry_mod.BUILTIN_PROFILES,
        &document,
        \\{"provider_catalogs": {"openrouter": {"models_url": "https://x.test/models", "credential_env": "OR_TOKEN"}}}
        ,
    );
    for (registry_mod.BUILTIN_PROFILES) |profile| for (profile.env_aliases) |alias| {
        try testing.expect(allowlist.accepts(alias.name));
    };
    try testing.expect(allowlist.accepts("OPENAI_WORK_KEY"));
    try testing.expect(allowlist.accepts("OR_TOKEN"));
    try testing.expect(!allowlist.accepts("HOME"));
    // A pool variable is accepted but selects no provider: start-up resolution
    // never reads a pool, so it must not make the file choose openai.
    for (allowlist.keys) |key| try testing.expect(!std.mem.eql(u8, key.name, "OPENAI_WORK_KEY"));
    var in_others = false;
    for (allowlist.others) |other| {
        if (std.mem.eql(u8, other, "OPENAI_WORK_KEY")) in_others = true;
    }
    try testing.expect(in_others);
}

test "the template lists every built-in provider's canonical variable, without a value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try renderExample(arena_state.allocator(), &registry_mod.BUILTIN_PROFILES);
    for (registry_mod.BUILTIN_PROFILES) |profile| {
        const name = canonicalVariable(profile) orelse continue;
        var buf: [96]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&buf, "\n# {s}=", .{name})) != null);
        try testing.expect(std.mem.indexOf(u8, text, profile.display_name) != null);
    }
    try testing.expect(std.mem.indexOf(u8, text, "KIMI_CODE_API_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, text, guide_url) != null);

    // As a file, it sets nothing: every assignment is commented out.
    const parsed = try parse(arena_state.allocator(), text);
    try testing.expectEqual(@as(usize, 0), parsed.assignments.len);
    try testing.expectEqual(@as(usize, 0), parsed.malformed.len);

    // Uncommented, a line without a key still sets nothing.
    const line = "DEEPSEEK_API_KEY=                # DeepSeek (--provider deepseek)";
    const uncommented = try parse(arena_state.allocator(), line);
    try testing.expectEqualStrings("", uncommented.assignments[0].value);
}
