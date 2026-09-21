//! Delivery-cadence obligation: exploration that never turns into a
//! deliverable.
//!
//! Field evidence (wb-bench-sec vim-tabpanel, 2026-09): 168 tool calls in
//! 1200 s — Read 83 / Bash 54 / Grep 31 — zero Write/Edit, killed by the
//! harness with no report on disk, reward 0. Tool time was 13 s; the rest
//! was inference spent re-opening lines of investigation. The community
//! names this failure class ("analysis paralysis", Cuadron et al. 2025) and
//! converges on one discipline against it: get a first version of the
//! deliverable on disk early and improve it in place (SWE-agent autosubmit,
//! AIxCC "submit as soon as possible", Anthropic's progress-file harness,
//! agenc-core "keep a verified result on disk and improve on a copy").
//!
//! This module is the host-side half of that discipline, shaped like the
//! verification final gate and the requirement ledger — a task-agnostic
//! process obligation, never a verdict:
//!   * sensor (engineering): every executed tool call is classified as
//!     exploration (read-only tools, read-only Bash), neutral (ledger and
//!     memory bookkeeping), or a delivery-capable mutation (file writes,
//!     non-read-only Bash, subagents and, conservatively, any tool this
//!     module does not know). Exploration calls are counted; the first
//!     mutation disarms the gate for the rest of the run.
//!   * policy (proven): at the turn boundary, crossing the first threshold
//!     with no mutation yet earns one bounded nudge, crossing the second
//!     earns a second — never more, never a denial, never once a mutation
//!     was seen. Formal model:
//!     control-plane/lean/MetaCodesControl/DeliveryCadence.lean. Each
//!     theorem names the mirroring test below.
//!   * budget: injections go through the global host-injection meter.
//!
//! What it is not: it does not read the task, does not know any harness
//! deadline, and does not judge the deliverable. The nudge carries only the
//! run's own counter and the anytime instruction. Unknown tools disarm
//! rather than count, so a misclassification can only silence the gate,
//! never fire it wrongly.

const std = @import("std");
const common = @import("../tools/common.zig");
const util_json = @import("../util/json.zig");
const bash_parser = @import("../permission/bash_parser.zig");
const tool_exec = @import("tool_exec.zig");
const verification_progress = @import("verification_progress.zig");

pub const MAX_CADENCE_NUDGES: u8 = 2;

/// Default thresholds in exploration-only tool calls. The vim run above
/// crossed both within its first ten minutes; a run that edits within its
/// first forty calls (the common coding shape) never sees the gate.
pub const DEFAULT_FIRST_THRESHOLD: u32 = 40;
pub const DEFAULT_SECOND_THRESHOLD: u32 = 80;

pub const Thresholds = struct {
    first: u32 = DEFAULT_FIRST_THRESHOLD,
    second: u32 = DEFAULT_SECOND_THRESHOLD,
};

pub const MARKER = "[delivery cadence]";

/// First threshold crossed with no file created or changed. `{d}` = the
/// run's exploration-call count. Task-agnostic: the only variable is the
/// run's own counter; the instruction is the anytime discipline.
pub const FIRST_NUDGE_FMT =
    MARKER ++ "\n" ++
    "You have made {d} tool calls in this run without creating or changing " ++
    "any file. If this task expects a written result (a file, a patch, a " ++
    "report), write its first version now from the evidence you already " ++
    "have, then keep improving it in place: a partial result on disk is " ++
    "worth more than a complete one that is never written. If the task " ++
    "expects only an answer, write your current best answer and its " ++
    "evidence into a notes file or your task ledger before continuing.";

/// Second threshold crossed, still nothing on disk.
pub const SECOND_NUDGE_FMT =
    MARKER ++ "\n" ++
    "{d} tool calls in this run and still no file created or changed. Stop " ++
    "widening the search. Commit to your strongest candidate: write the " ++
    "deliverable now with the evidence you have, mark what remains " ++
    "unverified, and only then continue investigating if anything is left.";

pub const Decision = enum { none, first, second };

/// Sensor classes. `neutral` exists so bookkeeping the host itself asks for
/// (the ledger prompt says TaskCreate) neither counts as exploration nor
/// disarms the gate.
pub const Class = enum { exploration, neutral, mutation };

pub const State = struct {
    /// Exploration-only tool calls observed before the first mutation.
    exploration_calls: u32 = 0,
    /// Sticky: a delivery-capable mutation (or realized file effect) was seen.
    mutation_seen: bool = false,
    /// Thresholds already decided (0..MAX_CADENCE_NUDGES). Observe mode
    /// advances it too, so control arms measure the same crossings.
    level: u8 = 0,
    /// Injections actually made (enforced mode only).
    nudges: u8 = 0,

    /// Pure policy over host-observed counts; mirrors `DeliveryCadence.decide`.
    pub fn decide(self: *const State, thresholds: Thresholds) Decision {
        if (self.mutation_seen) return .none;
        if (self.level == 0 and self.exploration_calls >= thresholds.first) return .first;
        if (self.level == 1 and self.exploration_calls >= thresholds.second) return .second;
        return .none;
    }

    /// Mirrors `DeliveryCadence.step`: a decided threshold is consumed.
    pub fn noteDecided(self: *State) void {
        self.level +|= 1;
    }

    /// Observe one completed tool turn. Denied, deferred and suspended slots
    /// never executed and are skipped.
    pub fn observeSlots(self: *State, allocator: std.mem.Allocator, slots: []const tool_exec.Slot) void {
        for (slots) |slot| {
            if (slot.decision != .run or slot.pending) continue;
            const realized = verification_progress.isRealizedMutation(slot.effect, slot.effect_valid);
            self.observeCall(classify(allocator, slot.name, slot.input), realized);
        }
    }

    pub fn observeCall(self: *State, class: Class, realized_mutation: bool) void {
        if (self.mutation_seen) return;
        if (realized_mutation or class == .mutation) {
            self.mutation_seen = true;
            return;
        }
        if (class == .exploration) self.exploration_calls +|= 1;
    }
};

const EXPLORATION_TOOLS = [_][]const u8{
    "Read",         "Grep",      "Glob",      "CodeMap",             "FindSymbol",
    "ReadArtifact", "WebFetch",  "WebSearch", "ReadMcpResourceTool", "ListMcpResourcesTool",
    "KgRecall",     "KgContext",
};

const NEUTRAL_TOOLS = [_][]const u8{
    "TaskCreate", "TaskUpdate",       "TaskList",        "TaskGet",       "KgRemember",
    "ToolSearch", "BashOutput",       "KillShell",       "TaskOutput",    "TaskStop",
    "Monitor",    "PushNotification", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
    "CronCreate", "CronDelete",       "CronList",        "SendMessage",   "FormalAuditTask",
    "Skill",
};

/// Classify one executed tool call. Unknown names (MCP, plugins) are
/// `mutation` on purpose: the safe failure of this sensor is silence.
pub fn classify(allocator: std.mem.Allocator, name: []const u8, input: []const u8) Class {
    if (std.mem.eql(u8, name, "Bash")) return classifyBash(allocator, input);
    for (EXPLORATION_TOOLS) |tool| if (std.mem.eql(u8, name, tool)) return .exploration;
    for (NEUTRAL_TOOLS) |tool| if (std.mem.eql(u8, name, tool)) return .neutral;
    return .mutation;
}

/// A Bash call counts as exploration only when every compound segment is a
/// read-only command with no file redirect and no in-place flag. The
/// permission layer's read-only roster is a "no prompt needed" list, so the
/// extra guards close the holes that matter here (`sed -i`, `find -delete`,
/// `cat a > b`); anything doubtful disarms.
fn classifyBash(allocator: std.mem.Allocator, input: []const u8) Class {
    const encoded = common.extractJsonArg(input, "command") orelse return .mutation;
    const raw = util_json.unescapeString(encoded, allocator) catch return .mutation;
    defer allocator.free(raw);
    // Command, process and backtick substitutions run whatever they contain
    // and the compound splitter cannot see inside them (`echo "$(touch f)"`
    // is one read-only-looking segment). Fail towards silence.
    if (containsSubstitution(raw)) return .mutation;
    // The permission splitter treats a lone `&` as a separator, so `2>&1`
    // would become the segments `cat f 2>` and `1`. Descriptor dups carry no
    // file effect: drop them before splitting.
    const command = stripDescriptorDups(allocator, raw) catch return .mutation;
    defer allocator.free(command);
    const segments = bash_parser.splitCompound(allocator, command) catch return .mutation;
    defer allocator.free(segments);
    if (segments.len == 0) return .neutral;
    var commands: usize = 0;
    for (segments) |segment| {
        // Loop and conditional keywords are syntax, not commands: `for f in
        // a b; do cat "$f"; done` explores. The header and terminators carry
        // no command; `do`/`then` prefix the real one.
        const body = stripShellKeywords(segment);
        if (body.ptr == CASE_SENTINEL.ptr) return .mutation;
        if (body.len == 0) continue;
        commands += 1;
        const stripped = bash_parser.stripWrappers(body);
        // `git -C dir status` is read-only; the roster keys on the token after
        // `git`, so drop the global options first.
        const target = stripGitGlobalOptions(stripped);
        if (!bash_parser.isReadonlyCommand(target) and !isReadonlyExplorationCommand(target)) return .mutation;
        if (hasFileRedirect(body)) return .mutation;
        if (hasMutatingPayload(target)) return .mutation;
    }
    return if (commands == 0) .neutral else .exploration;
}

/// `$(...)`, backticks and process substitution `<(...)` / `>(...)`.
fn containsSubstitution(command: []const u8) bool {
    if (std.mem.indexOfScalar(u8, command, '`') != null) return true;
    if (std.mem.indexOf(u8, command, "$(") != null) return true;
    if (std.mem.indexOf(u8, command, "<(") != null) return true;
    if (std.mem.indexOf(u8, command, ">(") != null) return true;
    return false;
}

/// `git -C <path> -c <k=v> --no-pager <sub> ...` → `git <sub> ...` so the
/// permission roster sees the subcommand.
fn stripGitGlobalOptions(target: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, target, " \t");
    const head = tokens.next() orelse return target;
    if (!std.mem.eql(u8, head, "git")) return target;
    var rest_start: usize = head.len;
    while (true) {
        const tok = tokens.next() orelse return target;
        const tok_start = @intFromPtr(tok.ptr) - @intFromPtr(target.ptr);
        if (std.mem.eql(u8, tok, "-C")) {
            _ = tokens.next() orelse return target; // the option's argument
            continue;
        }
        if (std.mem.eql(u8, tok, "--no-pager") or std.mem.eql(u8, tok, "--no-optional-locks")) continue;
        // Any other global option (`-c alias.status=!touch x`, `--exec-path`,
        // `--git-dir`, ...) can change what `git <sub>` executes: keep the
        // original text so the roster rejects it.
        if (tok[0] == '-') return target;
        rest_start = tok_start;
        break;
    }
    // Rebuild as `git <rest>` without allocating: the head is already the
    // first token of `target`, so return a view starting at the subcommand
    // prefixed by the literal head is not possible in place — instead check
    // the subcommand roster directly through bash_parser on a synthetic
    // slice. The roster only inspects `git <sub>`, so hand it the tail with
    // the head re-attached via a fixed buffer.
    var buf: [512]u8 = undefined;
    const tail = target[rest_start..];
    if (4 + tail.len > buf.len) return target;
    @memcpy(buf[0..4], "git ");
    @memcpy(buf[4 .. 4 + tail.len], tail);
    // A stack buffer cannot escape; classify through a static scratch instead.
    return gitScratch(buf[0 .. 4 + tail.len]);
}

/// Static scratch for the rebuilt `git <sub>` view (classification is
/// synchronous and single-threaded per call; the view dies with the call).
threadlocal var git_scratch: [512]u8 = undefined;
fn gitScratch(bytes: []const u8) []const u8 {
    @memcpy(git_scratch[0..bytes.len], bytes);
    return git_scratch[0..bytes.len];
}

/// Returned by `stripShellKeywords` for `case`/`select` compounds, whose
/// bodies this sensor cannot see through. Compared by pointer.
const CASE_SENTINEL: []const u8 = "case-compound";

/// Drop leading shell control keywords from one compound segment and return
/// the command that remains (empty when the segment is pure syntax such as a
/// `for` header, `done` or `fi`).
fn stripShellKeywords(segment: []const u8) []const u8 {
    var s = std.mem.trim(u8, segment, " \t");
    while (s.len > 0) {
        const space = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
        const head = s[0..space];
        // `case`/`select` bodies hide commands behind `pattern)` labels the
        // splitter cannot pair with `esac`; fail closed on the whole call.
        if (std.mem.eql(u8, head, "case") or std.mem.eql(u8, head, "select")) return CASE_SENTINEL;
        // Headers and terminators: nothing executable in this segment.
        for ([_][]const u8{ "for", "esac", "done", "fi", "in" }) |kw| {
            if (std.mem.eql(u8, head, kw)) return "";
        }
        // Prefix keywords: the command follows.
        var prefixed = false;
        for ([_][]const u8{ "do", "then", "else", "elif", "if", "while", "until", "!", "{", "}" }) |kw| {
            if (std.mem.eql(u8, head, kw)) prefixed = true;
        }
        if (!prefixed) return s;
        s = std.mem.trim(u8, s[space..], " \t");
    }
    return s;
}

/// Remove `[N]>&M` and `[N]<&M` descriptor duplications (`2>&1`, `>&2`).
fn stripDescriptorDups(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, command.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < command.len) {
        const c = command[i];
        if ((c == '>' or c == '<') and i + 2 < command.len and command[i + 1] == '&' and
            std.ascii.isDigit(command[i + 2]))
        {
            // Drop an optional leading descriptor digit already copied.
            if (out.items.len > 0 and std.ascii.isDigit(out.items[out.items.len - 1]) and
                (out.items.len == 1 or out.items[out.items.len - 2] == ' ' or out.items[out.items.len - 2] == '\t'))
            {
                out.items.len -= 1;
            }
            i += 2;
            while (i < command.len and std.ascii.isDigit(command[i])) : (i += 1) {}
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// `>` or `>>` outside quotes that is not a descriptor dup (`2>&1`) and not
/// a discard to /dev/null.
fn hasFileRedirect(segment: []const u8) bool {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        const c = segment[i];
        if (c == '\\' and i + 1 < segment.len) {
            i += 1;
            continue;
        }
        if (!in_double and c == '\'') {
            in_single = !in_single;
            continue;
        }
        if (!in_single and c == '"') {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double or c != '>') continue;
        var rest = segment[i + 1 ..];
        if (rest.len > 0 and rest[0] == '>') rest = rest[1..];
        if (rest.len > 0 and rest[0] == '|') rest = rest[1..]; // `>|` clobber
        if (rest.len > 0 and rest[0] == '&') {
            // `2>&1` is a descriptor dup; `>&file` sends both streams to a file.
            if (rest.len > 1 and std.ascii.isDigit(rest[1])) continue;
            return true;
        }
        const trimmed = std.mem.trimStart(u8, rest, " \t");
        if (std.mem.startsWith(u8, trimmed, "/dev/null")) continue;
        return true;
    }
    return false;
}

/// Programs and options through which a roster-admitted command can still
/// write: `sed -i` / `sed 's/x/y/w out'`, `awk '{print > "f"}'` /
/// `awk 'BEGIN{system(...)}'`, `find -delete/-exec/-fprint`, `sort -o`,
/// `uniq in out`, `fd -x`. Anything doubtful disarms.
fn hasMutatingPayload(target: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, target, " \t");
    const head = tokens.next() orelse return false;
    if (std.mem.eql(u8, head, "sed")) {
        while (tokens.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-i") or std.mem.startsWith(u8, tok, "--in-place")) return true;
        }
        return hasSedWriteCommand(target[head.len..]);
    }
    if (std.mem.eql(u8, head, "awk") or std.mem.eql(u8, head, "gawk") or std.mem.eql(u8, head, "mawk") or std.mem.eql(u8, head, "nawk")) {
        // The program text is quoted, so the redirect scan above skipped it:
        // `print > "f"`, `print | "cmd"`, `"cmd" | getline`, `system ("cmd")`.
        return std.mem.indexOfScalar(u8, target, '>') != null or
            std.mem.indexOfScalar(u8, target, '|') != null or
            std.mem.indexOf(u8, target, "system") != null;
    }
    if (std.mem.eql(u8, head, "git")) {
        // Read-only subcommands with write-capable options.
        var sub: []const u8 = "";
        var listing = false;
        var positional: usize = 0;
        while (tokens.next()) |tok| {
            if (sub.len == 0) {
                sub = tok;
                continue;
            }
            if (std.mem.startsWith(u8, tok, "--output")) return true;
            if (std.mem.eql(u8, sub, "branch")) {
                if (tok[0] == '-') {
                    for ([_][]const u8{ "-a", "-r", "-v", "-vv", "--all", "--remotes", "--verbose", "--list", "--show-current", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format", "--color", "--no-color" }) |ok| {
                        if (std.mem.eql(u8, tok, ok) or std.mem.startsWith(u8, tok, "--sort=") or std.mem.startsWith(u8, tok, "--format=") or std.mem.startsWith(u8, tok, "--color=")) {
                            listing = true;
                            break;
                        }
                    } else return true; // -d/-D/-m/-M/-c/-C/--set-upstream-to/...
                } else positional += 1;
            }
        }
        // `git branch <name>` creates a branch unless a listing form is present.
        return std.mem.eql(u8, sub, "branch") and positional > 0 and !listing;
    }
    if (std.mem.eql(u8, head, "tree")) return hasFlag(&tokens, &[_][]const u8{ "-o", "--output" });
    if (std.mem.eql(u8, head, "xxd")) return hasFlag(&tokens, &[_][]const u8{ "-r", "-revert" });
    if (std.mem.eql(u8, head, "yq")) return hasFlag(&tokens, &[_][]const u8{ "-i", "--inplace" });
    if (std.mem.eql(u8, head, "rg")) return hasFlag(&tokens, &[_][]const u8{ "--pre", "--pre-glob" });
    if (std.mem.eql(u8, head, "date")) return hasFlag(&tokens, &[_][]const u8{ "-s", "--set" });
    if (std.mem.eql(u8, head, "find")) {
        while (tokens.next()) |tok| {
            for ([_][]const u8{ "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls" }) |flag| {
                if (std.mem.eql(u8, tok, flag)) return true;
            }
        }
        return false;
    }
    if (std.mem.eql(u8, head, "fd") or std.mem.eql(u8, head, "fdfind")) {
        while (tokens.next()) |tok| {
            for ([_][]const u8{ "-x", "--exec", "-X", "--exec-batch" }) |flag| {
                if (std.mem.eql(u8, tok, flag)) return true;
            }
        }
        return false;
    }
    if (std.mem.eql(u8, head, "sort")) {
        while (tokens.next()) |tok| {
            if (std.mem.eql(u8, tok, "-o") or std.mem.startsWith(u8, tok, "--output")) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, head, "uniq")) {
        // `uniq INPUT OUTPUT` writes its second positional argument.
        var positional: usize = 0;
        while (tokens.next()) |tok| {
            if (tok[0] != '-') positional += 1;
        }
        return positional >= 2;
    }
    return false;
}

fn hasFlag(tokens: *std.mem.TokenIterator(u8, .any), flags: []const []const u8) bool {
    while (tokens.next()) |tok| {
        for (flags) |flag| {
            if (std.mem.eql(u8, tok, flag) or (flag.len > 2 and std.mem.startsWith(u8, tok, flag) and tok.len > flag.len and tok[flag.len] == '=')) return true;
        }
    }
    return false;
}

/// A `w`/`W` command in a sed script (`s/a/b/w out`, `/x/w out`, `-e 'w f'`).
fn hasSedWriteCommand(script: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < script.len) : (i += 1) {
        const c = script[i];
        if ((c == 'w' or c == 'W') and script[i + 1] == ' ' and i > 0) {
            const prev = script[i - 1];
            if (prev == '/' or prev == ';' or prev == '{' or prev == ' ' or prev == '\'' or prev == '"') return true;
        }
    }
    return false;
}

/// Read-only commands this sensor accepts beyond the permission roster: the
/// roster is a "no prompt needed" list of external commands, this is a "no
/// file effect" list. `fd`/`find` executors are handled by hasMutatingPayload.
fn isReadonlyExplorationCommand(target: []const u8) bool {
    const space = std.mem.indexOfAny(u8, target, " \t") orelse target.len;
    const head = target[0..space];
    for ([_][]const u8{
        // shell builtins that only inspect or bind values
        "read",     "test",     "[",       "[[",      ":",         "local",    "declare",
        // search / view
        "rg",       "fd",       "fdfind",  "tree",    "less",      "more",     "nl",
        "od",       "xxd",      "hexdump", "strings", "tac",       "rev",      "column",
        "comm",     "paste",    "jq",      "yq",      "date",      "basename", "dirname",
        "realpath", "readlink", "md5sum",  "shasum",  "sha256sum", "sha1sum",  "cksum",
        "printenv", "env",      "true",
    }) |kw| {
        if (std.mem.eql(u8, head, kw)) return true;
    }
    return false;
}

test "mutation disarms the cadence gate" {
    // Lean mirror: DeliveryCadence.mutation_disarms.
    var state = State{ .exploration_calls = 500, .mutation_seen = true };
    try std.testing.expectEqual(Decision.none, state.decide(.{ .first = 1, .second = 2 }));
    // Once seen, later exploration is neither counted nor able to re-arm.
    state.observeCall(.exploration, false);
    try std.testing.expectEqual(@as(u32, 500), state.exploration_calls);
    try std.testing.expectEqual(Decision.none, state.decide(.{ .first = 1, .second = 2 }));
    // A realized file effect disarms even when the name says exploration.
    var effect = State{};
    effect.observeCall(.exploration, true);
    try std.testing.expect(effect.mutation_seen);
}

test "below the first threshold nothing fires" {
    // Lean mirror: DeliveryCadence.pristine_never_nudged.
    var state = State{};
    const thresholds = Thresholds{ .first = 3, .second = 6 };
    try std.testing.expectEqual(Decision.none, state.decide(thresholds));
    state.observeCall(.exploration, false);
    state.observeCall(.neutral, false);
    state.observeCall(.exploration, false);
    try std.testing.expectEqual(@as(u32, 2), state.exploration_calls);
    try std.testing.expectEqual(Decision.none, state.decide(thresholds));
}

test "levels fire in order, at most once each, never past the budget" {
    // Lean mirror: DeliveryCadence.first_requires_threshold /
    // second_requires_first_fired / level_bounded.
    var state = State{};
    const thresholds = Thresholds{ .first = 2, .second = 4 };
    var i: usize = 0;
    while (i < 10) : (i += 1) state.observeCall(.exploration, false);
    // Far past both thresholds: the first level must still come first.
    try std.testing.expectEqual(Decision.first, state.decide(thresholds));
    state.noteDecided();
    try std.testing.expectEqual(Decision.second, state.decide(thresholds));
    state.noteDecided();
    try std.testing.expectEqual(Decision.none, state.decide(thresholds));
    state.noteDecided();
    try std.testing.expectEqual(Decision.none, state.decide(thresholds));
    try std.testing.expect(state.level <= MAX_CADENCE_NUDGES + 1);
    // Between the thresholds the second level waits for the counter.
    var waiting = State{ .level = 1, .exploration_calls = 3 };
    try std.testing.expectEqual(Decision.none, waiting.decide(thresholds));
    waiting.observeCall(.exploration, false);
    try std.testing.expectEqual(Decision.second, waiting.decide(thresholds));
}

test "classifier: read-only tools and read-only bash are exploration, bookkeeping is neutral, everything else disarms" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Class.exploration, classify(a, "Read", "{\"file_path\":\"x\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Grep", "{}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"ls -la && git status\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"timeout 5 grep -rn foo src | head\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"ls 2>/dev/null\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"cat a.txt 2>&1\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"ls >&2\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"grep -rn foo . 2>&1 | head -20\"}"));
    try std.testing.expectEqual(Class.neutral, classify(a, "TaskCreate", "{}"));
    try std.testing.expectEqual(Class.neutral, classify(a, "KgRemember", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Write", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Edit", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Task", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "mcp__srv__search", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"ls && rm -rf build\"}"));
    // `echo` is on the permission layer's read-only roster and mutates
    // nothing; a fresh file is the mutation shape.
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"echo hi\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"touch notes.md\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"mkdir -p out\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{}"));
}

test "bash loops and conditionals are judged by their inner commands" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"for f in a.py b.py; do echo \\\"=== $f ===\\\"; cat \\\"$f\\\"; done\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"if grep -q ack workers/x.py; then echo yes; else echo no; fi\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"while read -r l; do echo $l; done < list.txt\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"for f in *.tmp; do rm \\\"$f\\\"; done\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"for f in a b; do python3 tool.py $f; done\"}"));
    // A bare loop header with nothing executable is neither exploration nor mutation.
    try std.testing.expectEqual(Class.neutral, classify(a, "Bash", "{\"command\":\"for f in a b\"}"));
}

test "substitutions, both-stream redirects and programmable payloads disarm" {
    // Codex review 2026-09-21: nested effects the compound splitter cannot see.
    const a = std.testing.allocator;
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"echo \\\"$(touch report.md)\\\"\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"echo `touch report.md`\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"cat <(touch x)\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"printf x >&report.md\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"cat <> report.md\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"cat a >| b\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"awk 'BEGIN { system(\\\"touch report.md\\\") }' /dev/null\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"awk '{ print > \\\"report.md\\\" }' input\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"sed 's/a/b/w out.txt' f\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"sed --in-place=.bak s/a/b/ f\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"sort -o sorted.txt input\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"uniq input output\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"find . -name x -fprint hits.txt\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"fd -e py -x rm\"}"));
    // Still exploration: descriptor dups, awk/sed that only print, plain sort/uniq.
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"awk '{ print $1 }' input 2>&1\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"sed -n 's/a/b/p' f\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"sort input | uniq -c\"}"));
}

test "read-only search commands and git global options count as exploration" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"rg -n pattern src\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"fd -e py\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"tree -L 2\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"git -C sub status\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"git --no-pager -c color.ui=false log -3\"}")); // -c can inject aliases
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"git -C sub commit -m x\"}"));
    // Unprovable shapes stay mutation: python one-liners, tee, xargs into a writer.
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"python3 -c 'print(1)'\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"ls | tee out.txt\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"find . -name '*.o' | xargs rm\"}"));
}

test "case compounds, git config injection, git write options and roster payloads disarm" {
    // Codex follow-up 2026-09-21.
    const a = std.testing.allocator;
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"ls; case x in x) touch pwned;; esac\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"git -c alias.status='!touch status' status\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"git --exec-path=/tmp/x status\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"git branch -D feature\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"git branch newname\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"git diff --output=out.txt\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"tree -o report.md\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"xxd -r dump.hex out.bin\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"yq -i '.x=1' config.yml\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"rg --pre ./decompress pattern\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"awk 'BEGIN { system (\\\"touch pwned\\\") }'\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"awk 'BEGIN { \\\"touch pwned\\\" | getline }'\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"awk '{ print | \\\"sort\\\" }' f\"}"));
    // Still exploration: listing forms and plain views.
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"git branch -a\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"git --no-pager -C sub log -3\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"tree -L 2\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"xxd dump.bin | head\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"awk '{ print $1 }' f | sort\"}"));
}

test "bash redirects and in-place flags disarm" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"cat a.txt > b.txt\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"ls >> log.txt\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"sed -i 's/a/b/' f.c\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"find . -name '*.o' -delete\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"find . -name x -exec rm {} +\"}"));
    // A quoted `>` is data, not a redirect.
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"grep -n '>' f.c\"}"));
}

test "nudge texts carry only the counter and the anytime instruction" {
    const a = std.testing.allocator;
    const first = try std.fmt.allocPrint(a, FIRST_NUDGE_FMT, .{@as(u32, 40)});
    defer a.free(first);
    const second = try std.fmt.allocPrint(a, SECOND_NUDGE_FMT, .{@as(u32, 80)});
    defer a.free(second);
    for ([_][]const u8{ first, second }) |text| {
        try std.testing.expect(std.mem.startsWith(u8, text, MARKER));
        // No benchmark, verifier or grading vocabulary may ever enter a nudge.
        for ([_][]const u8{ "verifier", "reward", "score", "grade", "benchmark", "deadline", "timeout" }) |banned| {
            try std.testing.expect(std.mem.indexOf(u8, text, banned) == null);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, first, "40 tool calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "80 tool calls") != null);
}
