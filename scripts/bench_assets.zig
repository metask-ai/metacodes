//! Files carried by `metacodes bench`, independent of a source checkout.
pub const File = struct { path: []const u8, bytes: []const u8 };
pub const files = [_]File{
    .{ .path = "scripts/__init__.py", .bytes = "" },
    .{ .path = "scripts/eval/__init__.py", .bytes = @embedFile("eval/__init__.py") },
    .{ .path = "scripts/eval/model.py", .bytes = @embedFile("eval/model.py") },
    .{ .path = "scripts/eval/workbuddy/__init__.py", .bytes = @embedFile("eval/workbuddy/__init__.py") },
    .{ .path = "scripts/eval/workbuddy/trace.py", .bytes = @embedFile("eval/workbuddy/trace.py") },
    .{ .path = "scripts/eval/harbor/__init__.py", .bytes = @embedFile("eval/harbor/__init__.py") },
    .{ .path = "scripts/eval/harbor/cli.py", .bytes = @embedFile("eval/harbor/cli.py") },
    .{ .path = "scripts/eval/harbor/command.py", .bytes = @embedFile("eval/harbor/command.py") },
    .{ .path = "scripts/eval/harbor/profiling.py", .bytes = @embedFile("eval/harbor/profiling.py") },
    .{ .path = "scripts/eval/harbor/metacodes_agent.py", .bytes = @embedFile("eval/harbor/metacodes_agent.py") },
    .{ .path = "scripts/eval/harbor/viewer/__init__.py", .bytes = @embedFile("eval/harbor/viewer/__init__.py") },
    .{ .path = "scripts/eval/harbor/viewer/account.py", .bytes = @embedFile("eval/harbor/viewer/account.py") },
    .{ .path = "scripts/eval/harbor/viewer/data.py", .bytes = @embedFile("eval/harbor/viewer/data.py") },
    .{ .path = "scripts/eval/harbor/viewer/server.py", .bytes = @embedFile("eval/harbor/viewer/server.py") },
    .{ .path = "scripts/eval/harbor/viewer/runner.py", .bytes = @embedFile("eval/harbor/viewer/runner.py") },
    .{ .path = "scripts/eval/harbor/viewer/worker.py", .bytes = @embedFile("eval/harbor/viewer/worker.py") },
    .{ .path = "scripts/eval/harbor/viewer/static/index.html", .bytes = @embedFile("eval/harbor/viewer/static/index.html") },
    .{ .path = "scripts/eval/harbor/viewer/static/viewer.css", .bytes = @embedFile("eval/harbor/viewer/static/viewer.css") },
    .{ .path = "scripts/eval/harbor/viewer/static/viewer.js", .bytes = @embedFile("eval/harbor/viewer/static/viewer.js") },
};
