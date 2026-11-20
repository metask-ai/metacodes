const std = @import("std");

const MARKERS = [_][]const u8{
    "find-generic-password",
    "find-internet-password",
    "dump-keychain",
    "secret-tool",
};

pub fn mentions(command: []const u8) bool {
    for (MARKERS) |marker| {
        if (std.mem.indexOf(u8, command, marker) != null) return true;
    }
    return false;
}

test "commands that reach the macOS keychain or the Secret Service are recognized" {
    try std.testing.expect(mentions("security find-generic-password -s \"Metacode MCP Credentials\" -w"));
    try std.testing.expect(mentions("security find-internet-password -s github.com -g"));
    try std.testing.expect(mentions("security dump-keychain -d login.keychain"));
    try std.testing.expect(mentions("secret-tool lookup service suno"));
    try std.testing.expect(mentions(
        \\python3 << 'EOF'
        \\import subprocess
        \\subprocess.run(['security','find-generic-password','-a','suno','-w'])
        \\EOF
    ));
}

test "ordinary commands, and security subcommands that hold no secrets, are not" {
    try std.testing.expect(!mentions("ls -la ~/.metacodes"));
    try std.testing.expect(!mentions("security list-keychains"));
    try std.testing.expect(!mentions("security verify-cert -c cert.pem"));
    try std.testing.expect(!mentions("git log --grep password"));
}
