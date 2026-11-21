const std = @import("std");

const MARKERS = [_][]const u8{
    "find-generic-password",
    "find-internet-password",
    "dump-keychain",
    "secret-tool",
};

const SECRET_SUBCOMMANDS = [_][]const u8{
    "find-generic-password",
    "find-internet-password",
    "dump-keychain",
    "export",
};

const SEPARATORS = " \t\r\n;|&()<>[]{},";

pub fn mentions(scratch: std.mem.Allocator, command: []const u8) bool {
    const normalized = scratch.alloc(u8, command.len) catch return true;
    defer scratch.free(normalized);
    var len: usize = 0;
    for (command) |byte| switch (byte) {
        '\'', '"', '\\' => {},
        else => {
            normalized[len] = byte;
            len += 1;
        },
    };
    const text = normalized[0..len];
    for (MARKERS) |marker| {
        if (std.mem.indexOf(u8, text, marker) != null) return true;
    }
    return runsSecretSubcommand(text);
}

fn runsSecretSubcommand(text: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, text, SEPARATORS);
    while (tokens.next()) |token| {
        const base = if (std.mem.lastIndexOfScalar(u8, token, '/')) |slash| token[slash + 1 ..] else token;
        if (!std.mem.eql(u8, base, "security")) continue;
        const next = tokens.peek() orelse continue;
        if (next[0] == '$' or std.mem.indexOfScalar(u8, next, '`') != null) return true;
        for (SECRET_SUBCOMMANDS) |subcommand| {
            if (std.mem.eql(u8, next, subcommand)) return true;
        }
    }
    return false;
}

fn expectMentions(expected: bool, command: []const u8) !void {
    std.testing.expectEqual(expected, mentions(std.testing.allocator, command)) catch |err| {
        std.debug.print("command: {s}\n", .{command});
        return err;
    };
}

test "commands that reach the macOS keychain or the Secret Service are recognized" {
    try expectMentions(true, "security find-generic-password -s \"Metacode MCP Credentials\" -w");
    try expectMentions(true, "security find-internet-password -s github.com -g");
    try expectMentions(true, "security dump-keychain -d login.keychain");
    try expectMentions(true, "/usr/bin/security export -k login.keychain -t identities -f pkcs12 -o id.p12");
    try expectMentions(true, "secret-tool lookup service suno");
    try expectMentions(true,
        \\python3 << 'EOF'
        \\import subprocess
        \\subprocess.run(['security','find-generic-password','-a','suno','-w'])
        \\EOF
    );
}

test "quoting, escaping and expansion that the shell resolves into such a command are recognized" {
    try expectMentions(true, "security find-generic-pass'word' -s example -w");
    try expectMentions(true, "security find-generic-\"pass\"word -w");
    try expectMentions(true, "security find\\-internet-password -g");
    try expectMentions(true, "secret-''tool lookup service suno");
    try expectMentions(true, "security $(printf 'find-generic-%s' password) -w");
    try expectMentions(true, "s=find-generic-pass; security ${s}word -w");
    try expectMentions(true, "security $'\\x66ind-generic-password' -w");
    try expectMentions(true, "security `cat subcommand.txt` -w");
}

test "ordinary commands, and security subcommands that hold no secrets, are not" {
    try expectMentions(false, "ls -la ~/.metacodes");
    try expectMentions(false, "security list-keychains");
    try expectMentions(false, "security verify-cert -c cert.pem");
    try expectMentions(false, "git log --grep password");
    try expectMentions(false, "git commit -m 'security fix for $PATH handling'");
    try expectMentions(false, "npm audit --audit-level=high security");
}

test "a command that cannot be normalized for want of memory is treated as a credential read" {
    var buffer: [4]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    try std.testing.expect(mentions(fixed.allocator(), "ls -la /tmp"));
}
