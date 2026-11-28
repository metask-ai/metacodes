const std = @import("std");
const bash_parser = @import("metacodes-internal").permission.bash_parser;

const deleting = [_][]const u8{ "rm", "rmdir", "unlink", "shred", "truncate", "rimraf", "remove-item", "ri", "del", "erase", "rd", "clear-content" };
const networking = [_][]const u8{ "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp", "invoke-webrequest", "iwr", "invoke-restmethod", "irm" };
const escalating = [_][]const u8{ "sudo", "doas", "su", "pkexec", "runas" };
const formatting = [_][]const u8{ "mkfs", "format", "format-volume", "clear-disk", "diskpart" };
const wrappers = [_][]const u8{ "timeout", "time", "nice", "ionice", "nohup", "stdbuf", "env", "xargs", "command", "exec", "builtin", "coproc", "npx", "pnpx", "bunx", "uvx", "pipx", "start-process", "saps", "start" };
const posix_shells = [_][]const u8{ "bash", "sh", "zsh", "dash", "ksh", "fish" };
const powershells = [_][]const u8{ "pwsh", "powershell" };
const keywords = [_][]const u8{ "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "for", "esac", "select", "!", "{", "}", "(", ")" };
const executable_suffixes = [_][]const u8{ ".exe", ".cmd", ".bat", ".com" };
const max_depth = 8;

const Publish = struct { tool: []const u8, subcommand: []const u8 };
const publishing = [_]Publish{
    .{ .tool = "npm", .subcommand = "publish" },
    .{ .tool = "pnpm", .subcommand = "publish" },
    .{ .tool = "yarn", .subcommand = "publish" },
    .{ .tool = "bun", .subcommand = "publish" },
    .{ .tool = "cargo", .subcommand = "publish" },
    .{ .tool = "twine", .subcommand = "upload" },
    .{ .tool = "poetry", .subcommand = "publish" },
    .{ .tool = "uv", .subcommand = "publish" },
    .{ .tool = "gem", .subcommand = "push" },
    .{ .tool = "docker", .subcommand = "push" },
    .{ .tool = "podman", .subcommand = "push" },
};

const Dialect = enum { posix, windows };

pub fn isHardToUndo(scratch: std.mem.Allocator, tool_name: []const u8, args_json: []const u8) bool {
    if (!std.mem.eql(u8, tool_name, "Bash")) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, args_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const command = parsed.value.object.get("command") orelse return false;
    if (command != .string) return false;
    return commandIsHardToUndo(scratch, command.string);
}

pub fn commandIsHardToUndo(scratch: std.mem.Allocator, command: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(scratch);
    defer arena.deinit();
    return textIsHardToUndo(arena.allocator(), command, 0);
}

fn textIsHardToUndo(arena: std.mem.Allocator, text: []const u8, depth: usize) bool {
    if (depth > max_depth) return true;
    if (substitutionIsHardToUndo(arena, text, depth)) return true;
    const segments = bash_parser.splitCompound(arena, text) catch return true;
    for (segments) |segment| {
        for ([_]Dialect{ .posix, .windows }) |dialect| {
            const words = shellWords(arena, segment, dialect) catch return true;
            if (wordsAreHardToUndo(arena, words, depth)) return true;
        }
    }
    return false;
}

fn substitutionIsHardToUndo(arena: std.mem.Allocator, text: []const u8, depth: usize) bool {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\' and !in_single) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (in_single) continue;
        if (c == '`') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse text.len;
            if (textIsHardToUndo(arena, text[i + 1 .. end], depth + 1)) return true;
            i = end;
            continue;
        }
        if ((c == '$' or c == '<' or c == '>') and i + 1 < text.len and text[i + 1] == '(') {
            var level: usize = 1;
            var end = i + 2;
            while (end < text.len) : (end += 1) {
                if (text[end] == '(') level += 1;
                if (text[end] == ')') level -= 1;
                if (level == 0) break;
            }
            if (textIsHardToUndo(arena, text[i + 2 .. end], depth + 1)) return true;
            i = end;
        }
    }
    return false;
}

fn shellWords(arena: std.mem.Allocator, text: []const u8, dialect: Dialect) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        const escape = switch (dialect) {
            .posix => c == '\\',
            .windows => c == '`' or c == '^',
        };
        if (escape) {
            in_word = true;
            i += 1;
            if (i < text.len and text[i] != '\n') try word.append(arena, text[i]);
            continue;
        }
        switch (c) {
            ' ', '\t', '\n', '\r', '(', ')' => {
                if (in_word) try words.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
                if (c == '(' or c == ')') try words.append(arena, text[i .. i + 1]);
            },
            '\'' => {
                in_word = true;
                const end = std.mem.indexOfScalarPos(u8, text, i + 1, '\'') orelse text.len;
                try word.appendSlice(arena, text[i + 1 .. end]);
                i = end;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) {
                    const quoted_escape = switch (dialect) {
                        .posix => text[i] == '\\' and i + 1 < text.len and std.mem.indexOfScalar(u8, "\"\\$`", text[i + 1]) != null,
                        .windows => text[i] == '`' and i + 1 < text.len,
                    };
                    if (quoted_escape) i += 1;
                    try word.append(arena, text[i]);
                }
            },
            '$' => {
                in_word = true;
                const quote_follows = dialect == .posix and i + 1 < text.len and (text[i + 1] == '\'' or text[i + 1] == '"');
                if (!quote_follows) try word.append(arena, c);
            },
            else => {
                in_word = true;
                try word.append(arena, c);
            },
        }
    }
    if (in_word) try words.append(arena, try word.toOwnedSlice(arena));
    return try words.toOwnedSlice(arena);
}

fn wordsAreHardToUndo(arena: std.mem.Allocator, words: []const []const u8, depth: usize) bool {
    const start = commandStart(words) orelse return false;
    const name = programName(arena, words[start]);
    const rest = words[start + 1 ..];
    if (named(name, &wrappers)) return wrappedIsHardToUndo(arena, rest, depth);
    return programIsHardToUndo(arena, name, rest, depth);
}

fn commandStart(words: []const []const u8) ?usize {
    var i: usize = 0;
    while (i < words.len) {
        const word = words[i];
        if (std.mem.eql(u8, word, "case")) {
            i = for (words[i..], i..) |later, at| {
                if (std.mem.eql(u8, later, ")")) break at + 1;
            } else words.len;
        } else if (std.mem.eql(u8, word, "function")) {
            i += 2;
        } else if (named(word, &keywords) or isAssignment(word)) {
            i += 1;
        } else if (i + 1 < words.len and std.mem.eql(u8, words[i + 1], ")")) {
            i += 2;
        } else if (i + 2 < words.len and std.mem.eql(u8, words[i + 1], "(") and std.mem.eql(u8, words[i + 2], ")")) {
            i += 3;
        } else switch (redirection(word)) {
            .none => return i,
            .attached => i += 1,
            .operator_only => i += 2,
        }
    }
    return null;
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    const name = if (eq > 0 and word[eq - 1] == '+') word[0 .. eq - 1] else word[0..eq];
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

const Redirection = enum { none, attached, operator_only };

fn redirection(word: []const u8) Redirection {
    var i: usize = 0;
    while (i < word.len and std.ascii.isDigit(word[i])) : (i += 1) {}
    if (i >= word.len or (word[i] != '<' and word[i] != '>')) return .none;
    while (i < word.len and std.mem.indexOfScalar(u8, "<>&|", word[i]) != null) : (i += 1) {}
    return if (i == word.len) .operator_only else .attached;
}

fn programName(arena: std.mem.Allocator, word: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfAny(u8, word, "/\\")) |sep| word[sep + 1 ..] else word;
    const lower = std.ascii.allocLowerString(arena, base) catch return base;
    for (executable_suffixes) |suffix| {
        if (lower.len > suffix.len and std.mem.endsWith(u8, lower, suffix)) return lower[0 .. lower.len - suffix.len];
    }
    return lower;
}

fn wrappedIsHardToUndo(arena: std.mem.Allocator, rest: []const []const u8, depth: usize) bool {
    for (rest, 0..) |word, i| {
        const name = programName(arena, word);
        if (named(name, &wrappers)) continue;
        if (programIsHardToUndo(arena, name, rest[i + 1 ..], depth)) return true;
    }
    return false;
}

fn programIsHardToUndo(arena: std.mem.Allocator, name: []const u8, rest: []const []const u8, depth: usize) bool {
    if (named(name, &escalating) or named(name, &deleting) or named(name, &networking) or named(name, &formatting)) return true;
    if (std.mem.startsWith(u8, name, "mkfs.")) return true;
    if (std.mem.eql(u8, name, "dd")) return anyStartsWith(rest, "of=");
    if (std.mem.eql(u8, name, "find")) return findIsHardToUndo(arena, rest, depth);
    if (std.mem.eql(u8, name, "git")) return gitIsHardToUndo(rest);
    if (std.mem.eql(u8, name, "eval")) return joinedIsHardToUndo(arena, rest, depth);
    if (named(name, &posix_shells)) return posixShellIsHardToUndo(arena, rest, depth);
    if (named(name, &powershells)) return powershellIsHardToUndo(arena, rest, depth);
    if (std.mem.eql(u8, name, "cmd")) return cmdIsHardToUndo(arena, rest, depth);
    if (std.mem.startsWith(u8, name, "python") or std.mem.eql(u8, name, "py")) return moduleIsHardToUndo(arena, rest, depth);
    for (publishing) |p| {
        if (std.mem.eql(u8, name, p.tool) and hasWord(rest, p.subcommand)) return true;
    }
    return false;
}

fn joinedIsHardToUndo(arena: std.mem.Allocator, words: []const []const u8, depth: usize) bool {
    const text = std.mem.join(arena, " ", words) catch return true;
    return textIsHardToUndo(arena, text, depth + 1);
}

fn posixShellIsHardToUndo(arena: std.mem.Allocator, rest: []const []const u8, depth: usize) bool {
    var command_follows = false;
    for (rest) |word| {
        if (command_follows and !std.mem.startsWith(u8, word, "-") and !std.mem.startsWith(u8, word, "+")) return textIsHardToUndo(arena, word, depth + 1);
        if (std.mem.eql(u8, word, "--command") or (isShortCluster(word) and std.mem.indexOfScalar(u8, word, 'c') != null)) command_follows = true;
    }
    return false;
}

fn powershellIsHardToUndo(arena: std.mem.Allocator, rest: []const []const u8, depth: usize) bool {
    for (rest, 0..) |word, i| {
        const option = std.ascii.allocLowerString(arena, word) catch return true;
        if (!std.mem.startsWith(u8, option, "-")) continue;
        if (std.mem.eql(u8, option, "-e") or std.mem.eql(u8, option, "-ec") or abbreviates(option, "-encodedcommand", 3)) return true;
        if (abbreviates(option, "-command", 2)) return joinedIsHardToUndo(arena, rest[i + 1 ..], depth);
        if (abbreviates(option, "-file", 2)) return false;
    }
    return wrappedIsHardToUndo(arena, rest, depth);
}

fn cmdIsHardToUndo(arena: std.mem.Allocator, rest: []const []const u8, depth: usize) bool {
    for (rest, 0..) |word, i| {
        if (std.ascii.eqlIgnoreCase(word, "/c") or std.ascii.eqlIgnoreCase(word, "/k")) return joinedIsHardToUndo(arena, rest[i + 1 ..], depth);
    }
    return false;
}

fn moduleIsHardToUndo(arena: std.mem.Allocator, rest: []const []const u8, depth: usize) bool {
    for (rest, 0..) |word, i| {
        if (std.mem.eql(u8, word, "-m") and i + 1 < rest.len) return programIsHardToUndo(arena, programName(arena, rest[i + 1]), rest[i + 2 ..], depth);
    }
    return false;
}

fn findIsHardToUndo(arena: std.mem.Allocator, rest: []const []const u8, depth: usize) bool {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "-delete")) return true;
        if (named(rest[i], &.{ "-exec", "-execdir", "-ok", "-okdir" })) {
            var end = i + 1;
            while (end < rest.len and !std.mem.eql(u8, rest[end], ";") and !std.mem.eql(u8, rest[end], "+")) : (end += 1) {}
            if (wordsAreHardToUndo(arena, rest[i + 1 .. end], depth)) return true;
            i = end;
        }
    }
    return false;
}

fn gitIsHardToUndo(words: []const []const u8) bool {
    var i: usize = 0;
    while (i < words.len and std.mem.startsWith(u8, words[i], "-")) : (i += 1) {
        if (named(words[i], &.{ "-C", "-c", "--git-dir", "--work-tree", "--namespace" })) i += 1;
    }
    if (i >= words.len) return false;
    const subcommand = words[i];
    const rest = words[i + 1 ..];
    if (named(subcommand, &.{ "push", "clean", "rm", "restore", "filter-branch", "filter-repo" })) return true;
    if (std.mem.eql(u8, subcommand, "reset")) return hasWord(rest, "--hard");
    if (std.mem.eql(u8, subcommand, "checkout")) return checkoutDiscards(rest);
    if (std.mem.eql(u8, subcommand, "switch")) return hasWord(rest, "--discard-changes") or hasWord(rest, "--force") or hasShortFlag(rest, 'f');
    if (std.mem.eql(u8, subcommand, "stash")) return rest.len > 0 and named(rest[0], &.{ "drop", "clear" });
    if (std.mem.eql(u8, subcommand, "branch")) return branchDeletesUnmerged(rest);
    if (std.mem.eql(u8, subcommand, "worktree")) return rest.len > 0 and std.mem.eql(u8, rest[0], "remove") and (hasWord(rest, "--force") or hasShortFlag(rest, 'f'));
    if (std.mem.eql(u8, subcommand, "reflog")) return rest.len > 0 and named(rest[0], &.{ "expire", "delete" });
    if (std.mem.eql(u8, subcommand, "update-ref")) return hasWord(rest, "-d");
    if (std.mem.eql(u8, subcommand, "tag")) return hasWord(rest, "--delete") or hasShortFlag(rest, 'd');
    if (std.mem.eql(u8, subcommand, "gc")) return anyStartsWith(rest, "--prune");
    return false;
}

fn checkoutDiscards(rest: []const []const u8) bool {
    var operands: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const word = rest[i];
        if (std.mem.eql(u8, word, "--") or std.mem.eql(u8, word, ".")) return true;
        if (named(word, &.{ "-b", "-B", "--orphan" })) {
            i += 1;
        } else if (std.mem.startsWith(u8, word, "--")) {
            if (named(word, &.{ "--force", "--patch", "--ours", "--theirs", "--merge" }) or std.mem.startsWith(u8, word, "--pathspec-from-file")) return true;
        } else if (std.mem.startsWith(u8, word, "-")) {
            if (std.mem.indexOfAny(u8, word[1..], "fpm") != null) return true;
        } else {
            operands += 1;
        }
    }
    return operands >= 2;
}

fn branchDeletesUnmerged(rest: []const []const u8) bool {
    var deletes = false;
    var forces = false;
    for (rest) |word| {
        if (std.mem.eql(u8, word, "--delete")) deletes = true;
        if (std.mem.eql(u8, word, "--force")) forces = true;
        if (!isShortCluster(word)) continue;
        if (std.mem.indexOfScalar(u8, word, 'D') != null) return true;
        if (std.mem.indexOfScalar(u8, word, 'd') != null) deletes = true;
        if (std.mem.indexOfScalar(u8, word, 'f') != null) forces = true;
    }
    return deletes and forces;
}

fn isShortCluster(word: []const u8) bool {
    return word.len > 1 and word[0] == '-' and word[1] != '-';
}

fn hasShortFlag(words: []const []const u8, flag: u8) bool {
    for (words) |word| {
        if (isShortCluster(word) and std.mem.indexOfScalar(u8, word[1..], flag) != null) return true;
    }
    return false;
}

fn abbreviates(word: []const u8, full: []const u8, shortest: usize) bool {
    return word.len >= shortest and std.mem.startsWith(u8, full, word);
}

fn named(name: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn hasWord(words: []const []const u8, wanted: []const u8) bool {
    return named(wanted, words);
}

fn anyStartsWith(words: []const []const u8, prefix: []const u8) bool {
    for (words) |word| {
        if (std.mem.startsWith(u8, word, prefix)) return true;
    }
    return false;
}

const testing = std.testing;

test "hard to undo: deleting files, discarding work, pushing and publishing, the network and sudo" {
    for ([_][]const u8{
        "rm -rf build",
        "/bin/rm notes.txt",
        "rmdir old",
        "unlink link",
        "shred -u secret",
        "truncate -s 0 app.log",
        "dd if=/dev/zero of=disk.img bs=1M count=1",
        "mkfs /dev/sdb1",
        "mkfs.ext4 /dev/sdb1",
        "find . -name '*.o' -delete",
        "find . -type f -exec rm {} +",
        "git clean -fdx",
        "git rm src/old.zig",
        "git reset --hard HEAD~1",
        "git checkout -- src/main.zig",
        "git checkout .",
        "git restore src/main.zig",
        "git stash drop",
        "git stash clear",
        "git branch -D topic",
        "git push origin main",
        "git -C ../other push",
        "npm publish",
        "cargo publish --dry-run",
        "twine upload dist/*",
        "docker push image:tag",
        "curl https://example.com",
        "wget -q https://example.com/file",
        "ssh host ls",
        "scp a host:b",
        "rsync -a src/ host:dst/",
        "sudo make install",
        "make && rm -rf out",
        "timeout 30 git push",
        "ls | xargs rm",
    }) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try testing.expect(commandIsHardToUndo(testing.allocator, command));
    }
}

test "hard to undo: reading, building, editing in place and fetching are not" {
    for ([_][]const u8{
        "ls -la",
        "git status",
        "git log --oneline",
        "git diff",
        "git fetch origin",
        "git pull",
        "git checkout -b topic",
        "git checkout main",
        "git reset HEAD file",
        "git stash",
        "git stash pop",
        "git branch -d merged",
        "zig build test",
        "npm install",
        "npm test",
        "mv a b",
        "chmod +x run.sh",
        "dd if=disk.img bs=512 count=1",
        "find . -name '*.zig'",
        "echo rm -rf is dangerous",
        "grep -r curl src",
    }) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try testing.expect(!commandIsHardToUndo(testing.allocator, command));
    }
}

test "hard to undo is seen through shell syntax, quoting, wrappers, other shells and Windows names" {
    for ([_][]const u8{
        "for f in *.o; do rm \"$f\"; done",
        "if true; then rm -rf out; fi",
        "( rm -rf out )",
        "(rm -rf out)",
        "{ rm -rf out; }",
        "f() { rm -rf out; }; f",
        "case $x in a) rm -rf out;; esac",
        "FOO=1 rm -rf out",
        "2>/dev/null rm -rf out",
        "\\rm -rf out",
        "\"rm\" -rf out",
        "'rm' -rf out",
        "$'rm' -rf out",
        "echo $(rm -rf out)",
        "echo \"$(git push)\"",
        "echo `rm -rf out`",
        "eval \"rm -rf out\"",
        "xargs -I {} rm {}",
        "timeout -s KILL 5 rm -rf out",
        "env -u HOME rm -rf out",
        "/usr/bin/env rm -rf out",
        "npx rimraf dist",
        "find . -exec git rm {} \\;",
        "bash -c 'rm -rf out'",
        "sh -lc \"git push\"",
        "git -C \"a b\" push",
        "npm --workspace a publish",
        "pnpm -r publish",
        "cargo +nightly publish",
        "docker image push registry/app:1",
        "python -m twine upload dist/*",
        "python3 -m twine upload dist/*",
        "git checkout -f",
        "git checkout --force main",
        "git checkout HEAD~1 src/main.zig",
        "git switch --discard-changes main",
        "git switch -f main",
        "git branch -df topic",
        "git branch --delete --force topic",
        "git worktree remove --force ../wt",
        "git reflog expire --expire=now --all",
        "Remove-Item -Recurse -Force build",
        "REMOVE-ITEM build",
        "del /f /q build\\out.txt",
        "rd /s /q build",
        "iwr https://example.com -OutFile x",
        "Invoke-WebRequest https://example.com",
        "curl.exe https://example.com",
        "C:\\Windows\\System32\\curl.exe https://example.com",
        "git.exe push",
        "npm.cmd publish",
        "cmd /c rd /s /q build",
        "powershell -NoProfile -ExecutionPolicy Bypass -Command \"Remove-Item build\"",
        "pwsh -EncodedCommand ZQBjAGgAbwA=",
        "Start-Process cmd -Verb RunAs",
    }) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try testing.expect(commandIsHardToUndo(testing.allocator, command));
    }
    for ([_][]const u8{
        "git checkout -b topic origin/main",
        "git switch main",
        "git switch -c topic",
        "git branch -f topic main",
        "git tag v1.0",
        "git stash list",
        "env FOO=bar zig build",
        "timeout 60 zig build test",
        "python -m pytest",
        "npm run build",
        "docker build -t app .",
        "cargo build --release",
        "for f in *.zig; do echo $f; done",
        "if [ -f x ]; then cat x; fi",
        "bash -c 'zig build'",
        "echo $(date)",
        "echo $((1 + 2))",
        "Get-ChildItem -Recurse",
        "powershell -Command \"Get-ChildItem\"",
    }) |command| {
        errdefer std.debug.print("command: {s}\n", .{command});
        try testing.expect(!commandIsHardToUndo(testing.allocator, command));
    }
}

test "hard to undo is judged on Bash calls only, from their command" {
    try testing.expect(isHardToUndo(testing.allocator, "Bash", "{\"command\":\"rm -rf build\"}"));
    try testing.expect(!isHardToUndo(testing.allocator, "Bash", "{\"command\":\"zig build\"}"));
    try testing.expect(!isHardToUndo(testing.allocator, "Write", "{\"file_path\":\"/x\",\"content\":\"rm -rf\"}"));
    try testing.expect(!isHardToUndo(testing.allocator, "Bash", "not json"));
    try testing.expect(!isHardToUndo(testing.allocator, "Bash", "{\"command\":42}"));
}
