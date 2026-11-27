const std = @import("std");
const bash_parser = @import("metacodes-internal").permission.bash_parser;

const deleting = [_][]const u8{ "rm", "rmdir", "unlink", "shred", "truncate" };
const networking = [_][]const u8{ "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp" };
const escalating = [_][]const u8{ "sudo", "doas" };

const Publish = struct { tool: []const u8, subcommand: []const u8 };
const publishing = [_]Publish{
    .{ .tool = "npm", .subcommand = "publish" },
    .{ .tool = "pnpm", .subcommand = "publish" },
    .{ .tool = "yarn", .subcommand = "publish" },
    .{ .tool = "cargo", .subcommand = "publish" },
    .{ .tool = "twine", .subcommand = "upload" },
    .{ .tool = "gem", .subcommand = "push" },
    .{ .tool = "docker", .subcommand = "push" },
};

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
    const segments = bash_parser.splitCompound(scratch, command) catch return true;
    defer scratch.free(segments);
    for (segments) |segment| {
        if (segmentIsHardToUndo(segment)) return true;
    }
    return false;
}

fn segmentIsHardToUndo(segment: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, bash_parser.stripWrappers(segment), " \t");
    const name = programName(words.next() orelse return false);
    if (named(name, &escalating) or named(name, &deleting) or named(name, &networking)) return true;
    if (std.mem.eql(u8, name, "mkfs") or std.mem.startsWith(u8, name, "mkfs.")) return true;
    if (std.mem.eql(u8, name, "dd")) return hasPrefixedWord(words, "of=");
    if (std.mem.eql(u8, name, "find")) return findDeletes(words);
    if (std.mem.eql(u8, name, "git")) return gitIsHardToUndo(words);
    const subcommand = words.next() orelse return false;
    for (publishing) |p| {
        if (std.mem.eql(u8, name, p.tool) and std.mem.eql(u8, subcommand, p.subcommand)) return true;
    }
    return false;
}

fn programName(word: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, word, '/') orelse return word;
    return word[slash + 1 ..];
}

fn named(name: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn findDeletes(words: std.mem.TokenIterator(u8, .any)) bool {
    var rest = words;
    while (rest.next()) |word| {
        if (std.mem.eql(u8, word, "-delete")) return true;
        if (std.mem.eql(u8, word, "-exec") or std.mem.eql(u8, word, "-execdir") or std.mem.eql(u8, word, "-ok")) {
            const program = rest.next() orelse return false;
            if (named(programName(program), &deleting)) return true;
        }
    }
    return false;
}

fn gitIsHardToUndo(words: std.mem.TokenIterator(u8, .any)) bool {
    var rest = words;
    const subcommand = while (rest.next()) |word| {
        if (std.mem.eql(u8, word, "-C") or std.mem.eql(u8, word, "-c")) {
            _ = rest.next();
            continue;
        }
        if (!std.mem.startsWith(u8, word, "-")) break word;
    } else return false;
    if (named(subcommand, &.{ "push", "clean", "rm", "restore" })) return true;
    if (std.mem.eql(u8, subcommand, "reset")) return hasWord(rest, "--hard");
    if (std.mem.eql(u8, subcommand, "checkout")) return hasWord(rest, "--") or hasWord(rest, ".");
    if (std.mem.eql(u8, subcommand, "stash")) {
        const action = rest.next() orelse return false;
        return std.mem.eql(u8, action, "drop") or std.mem.eql(u8, action, "clear");
    }
    if (std.mem.eql(u8, subcommand, "branch")) return hasWord(rest, "-D");
    return false;
}

fn hasPrefixedWord(words: std.mem.TokenIterator(u8, .any), prefix: []const u8) bool {
    var rest = words;
    while (rest.next()) |word| {
        if (std.mem.startsWith(u8, word, prefix)) return true;
    }
    return false;
}

fn hasWord(words: std.mem.TokenIterator(u8, .any), wanted: []const u8) bool {
    var rest = words;
    while (rest.next()) |word| {
        if (std.mem.eql(u8, word, wanted)) return true;
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

test "hard to undo is judged on Bash calls only, from their command" {
    try testing.expect(isHardToUndo(testing.allocator, "Bash", "{\"command\":\"rm -rf build\"}"));
    try testing.expect(!isHardToUndo(testing.allocator, "Bash", "{\"command\":\"zig build\"}"));
    try testing.expect(!isHardToUndo(testing.allocator, "Write", "{\"file_path\":\"/x\",\"content\":\"rm -rf\"}"));
    try testing.expect(!isHardToUndo(testing.allocator, "Bash", "not json"));
    try testing.expect(!isHardToUndo(testing.allocator, "Bash", "{\"command\":42}"));
}
