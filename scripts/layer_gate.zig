const std = @import("std");

const Package = struct {
    name: []const u8,
    paths: []const []const u8,
    allowed_dependencies: []const []const u8,
};

const KernelBudget = struct {
    package: []const u8,
    max_lines: usize,
    max_dependencies: []const []const u8,
};

const Manifest = struct {
    packages: []const Package,
    kernel_budget: KernelBudget,
};

const Baseline = struct {
    upward: []const [2][]const u8 = &.{},
    deep: []const [2][]const u8 = &.{},
    cycles: []const []const []const u8 = &.{},
    wiring: []const [2][]const u8 = &.{},
    wide_roots: []const []const u8 = &.{},
};

const Layers = struct {
    manifest: Manifest,
    allowed: []const []const bool,
    kernel: usize,

    fn count(layers: Layers) usize {
        return layers.manifest.packages.len;
    }

    fn name(layers: Layers, package: usize) []const u8 {
        return layers.manifest.packages[package].name;
    }

    fn index(layers: Layers, package_name: []const u8) ?usize {
        for (layers.manifest.packages, 0..) |package, position| {
            if (std.mem.eql(u8, package.name, package_name)) return position;
        }
        return null;
    }

    fn owner(layers: Layers, path: []const u8) ?usize {
        var best: ?usize = null;
        var best_len: usize = 0;
        for (layers.manifest.packages, 0..) |package, position| {
            for (package.paths) |entry| {
                if (!pathMatches(entry, path) or entry.len < best_len) continue;
                best = position;
                best_len = entry.len;
            }
        }
        return best;
    }

    fn mayDepend(layers: Layers, from: usize, to: usize) bool {
        return from == to or layers.allowed[from][to];
    }
};

fn pathMatches(entry: []const u8, path: []const u8) bool {
    if (std.mem.endsWith(u8, entry, "/")) return std.mem.startsWith(u8, path, entry);
    return std.mem.eql(u8, entry, path);
}

const SourceFile = struct {
    path: []const u8,
    source: [:0]const u8,
};

const Import = struct {
    root: []const u8,
    name: []const u8,
    target: []const u8,
};

const Wiring = struct {
    roots: []const []const u8,
    imports: []const Import,
};

const Violations = std.StringArrayHashMapUnmanaged([]const u8);

const Findings = struct {
    upward: Violations = .empty,
    deep: Violations = .empty,
    cycles: Violations = .empty,
    wiring: Violations = .empty,
    wide_roots: Violations = .empty,
    unowned: Violations = .empty,
    upward_counts: [][]usize,
    deep_counts: [][]usize,
    depends: [][]bool,
    kernel_lines: usize = 0,
};

const Category = enum {
    upward,
    deep,
    cycles,
    wiring,
    wide_roots,

    fn describe(category: Category) []const u8 {
        return switch (category) {
            .upward => "import against allowed_dependencies",
            .deep => "deep import into another package",
            .cycles => "package cycle",
            .wiring => "build.zig module import against allowed_dependencies",
            .wide_roots => "module root whose directory spans packages it may not depend on",
        };
    }
};

fn resolveLayers(arena: std.mem.Allocator, manifest: Manifest) !Layers {
    var problems: usize = 0;
    const total = manifest.packages.len;
    const allowed = try arena.alloc([]bool, total);
    for (manifest.packages, 0..) |package, position| {
        allowed[position] = try arena.alloc(bool, total);
        @memset(allowed[position], false);
        for (manifest.packages[0..position]) |earlier| {
            if (std.mem.eql(u8, earlier.name, package.name)) {
                problems += 1;
                std.debug.print("layers.zon: package `{s}` is declared twice\n", .{package.name});
            }
        }
        for (package.allowed_dependencies) |dependency| {
            const target = indexOf(manifest, dependency) orelse {
                problems += 1;
                std.debug.print("layers.zon: `{s}` allows unknown package `{s}`\n", .{ package.name, dependency });
                continue;
            };
            if (target >= position) {
                problems += 1;
                std.debug.print("layers.zon: `{s}` may only depend on packages declared before it, not `{s}`\n", .{ package.name, dependency });
                continue;
            }
            allowed[position][target] = true;
        }
        for (package.paths) |entry| {
            for (manifest.packages[0 .. position + 1], 0..) |other, other_position| {
                const listed = if (other_position == position) package.paths[0..indexOfPath(package.paths, entry)] else other.paths;
                if (indexOfPath(listed, entry) < listed.len) {
                    problems += 1;
                    std.debug.print("layers.zon: path `{s}` is assigned twice\n", .{entry});
                }
            }
        }
    }
    const kernel = indexOf(manifest, manifest.kernel_budget.package) orelse {
        std.debug.print("layers.zon: kernel_budget names unknown package `{s}`\n", .{manifest.kernel_budget.package});
        return error.InvalidManifest;
    };
    for (manifest.kernel_budget.max_dependencies) |dependency| {
        if (indexOf(manifest, dependency) == null) {
            problems += 1;
            std.debug.print("layers.zon: kernel_budget names unknown package `{s}`\n", .{dependency});
        }
    }
    if (problems != 0) return error.InvalidManifest;
    return .{ .manifest = manifest, .allowed = allowed, .kernel = kernel };
}

fn indexOf(manifest: Manifest, package_name: []const u8) ?usize {
    for (manifest.packages, 0..) |package, position| {
        if (std.mem.eql(u8, package.name, package_name)) return position;
    }
    return null;
}

fn indexOfPath(paths: []const []const u8, entry: []const u8) usize {
    for (paths, 0..) |path, position| {
        if (std.mem.eql(u8, path, entry)) return position;
    }
    return paths.len;
}

fn resolve(arena: std.mem.Allocator, from: []const u8, target: []const u8) !?[]const u8 {
    if (!std.mem.endsWith(u8, target, ".zig")) return null;
    var segments: std.ArrayList([]const u8) = .empty;
    var dir = std.mem.splitScalar(u8, std.fs.path.dirnamePosix(from) orelse "", '/');
    while (dir.next()) |segment| {
        if (segment.len != 0 and !std.mem.eql(u8, segment, ".")) try segments.append(arena, segment);
    }
    var parts = std.mem.splitScalar(u8, target, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (segments.pop() == null) return null;
            continue;
        }
        try segments.append(arena, part);
    }
    return try std.mem.join(arena, "/", segments.items);
}

fn record(arena: std.mem.Allocator, violations: *Violations, key: []const u8, location: []const u8) !bool {
    const entry = try violations.getOrPut(arena, key);
    if (entry.found_existing) return false;
    entry.value_ptr.* = location;
    return true;
}

fn analyze(arena: std.mem.Allocator, layers: Layers, files: []const SourceFile, wiring: Wiring) !Findings {
    const total = layers.count();
    var findings: Findings = .{
        .upward_counts = try matrix(usize, arena, total, 0),
        .deep_counts = try matrix(usize, arena, total, 0),
        .depends = try matrix(bool, arena, total, false),
    };
    for (files) |file| {
        const from = layers.owner(file.path) orelse {
            _ = try record(arena, &findings.unowned, file.path, file.path);
            continue;
        };
        if (from == layers.kernel) findings.kernel_lines += std.mem.count(u8, file.source, "\n");
        var tokenizer = std.zig.Tokenizer.init(file.source);
        var line: usize = 1;
        var scanned: usize = 0;
        var previous: [2]std.zig.Token.Tag = .{ .invalid, .invalid };
        var import_start: usize = 0;
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            defer {
                previous = .{ previous[1], token.tag };
                if (token.tag == .builtin) import_start = token.loc.start;
            }
            if (token.tag != .string_literal or previous[1] != .l_paren or previous[0] != .builtin) continue;
            if (!std.mem.eql(u8, file.source[import_start..][0.."@import".len], "@import")) continue;
            line += std.mem.count(u8, file.source[scanned..token.loc.start], "\n");
            scanned = token.loc.start;
            const literal = file.source[token.loc.start + 1 .. token.loc.end - 1];
            const target = try resolve(arena, file.path, literal) orelse continue;
            const to = layers.owner(target) orelse continue;
            if (to == from) continue;
            findings.depends[from][to] = true;
            const location = try std.fmt.allocPrint(arena, "{s}:{d}", .{ file.path, line });
            if (!layers.mayDepend(from, to)) {
                const key = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ file.path, target });
                if (try record(arena, &findings.upward, key, location)) findings.upward_counts[from][to] += 1;
            } else {
                const key = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ layers.name(from), target });
                if (try record(arena, &findings.deep, key, location)) findings.deep_counts[from][to] += 1;
            }
        }
    }
    for (wiring.imports) |import| {
        const from = layers.owner(import.root) orelse continue;
        const to = layers.owner(import.target) orelse continue;
        if (to == from) continue;
        findings.depends[from][to] = true;
        if (layers.mayDepend(from, to)) continue;
        const key = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ import.root, import.name });
        const location = try std.fmt.allocPrint(arena, "build.zig: module {s} imports `{s}` ({s})", .{ import.root, import.name, import.target });
        _ = try record(arena, &findings.wiring, key, location);
    }
    for (wiring.roots) |root| {
        const package = layers.owner(root) orelse continue;
        const dir = std.fs.path.dirnamePosix(root) orelse "";
        for (files) |file| {
            if (dir.len != 0 and !(std.mem.startsWith(u8, file.path, dir) and file.path.len > dir.len and file.path[dir.len] == '/')) continue;
            const other = layers.owner(file.path) orelse continue;
            if (layers.mayDepend(package, other)) continue;
            const location = try std.fmt.allocPrint(arena, "build.zig: module {s} can reach {s} ({s})", .{ root, file.path, layers.name(other) });
            _ = try record(arena, &findings.wide_roots, root, location);
            break;
        }
    }
    try findCycles(arena, layers, &findings);
    return findings;
}

fn matrix(comptime T: type, arena: std.mem.Allocator, size: usize, value: T) ![][]T {
    const rows = try arena.alloc([]T, size);
    for (rows) |*row| {
        row.* = try arena.alloc(T, size);
        @memset(row.*, value);
    }
    return rows;
}

fn findCycles(arena: std.mem.Allocator, layers: Layers, findings: *Findings) !void {
    const total = layers.count();
    const reach = try matrix(bool, arena, total, false);
    for (findings.depends, reach) |row, reach_row| @memcpy(reach_row, row);
    for (0..total) |via| {
        for (0..total) |from| {
            if (!reach[from][via]) continue;
            for (0..total) |to| {
                if (reach[via][to]) reach[from][to] = true;
            }
        }
    }
    const grouped = try arena.alloc(bool, total);
    @memset(grouped, false);
    for (0..total) |first| {
        if (grouped[first] or !reach[first][first]) continue;
        var members: std.ArrayList([]const u8) = .empty;
        for (first..total) |other| {
            if (other != first and !(reach[first][other] and reach[other][first])) continue;
            grouped[other] = true;
            try members.append(arena, layers.name(other));
        }
        const key = try std.mem.join(arena, ", ", members.items);
        _ = try record(arena, &findings.cycles, key, "layers");
    }
}

fn baselineKeys(arena: std.mem.Allocator, category: Category, baseline: Baseline) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    switch (category) {
        inline .upward, .deep, .wiring => |pair| for (@field(baseline, @tagName(pair))) |entry| {
            try keys.append(arena, try std.fmt.allocPrint(arena, "{s} -> {s}", .{ entry[0], entry[1] }));
        },
        .cycles => for (baseline.cycles) |members| try keys.append(arena, try std.mem.join(arena, ", ", members)),
        .wide_roots => try keys.appendSlice(arena, baseline.wide_roots),
    }
    return keys.items;
}

fn compare(arena: std.mem.Allocator, category: Category, current: Violations, listed: []const []const u8) !usize {
    var problems: usize = 0;
    var known: std.StringHashMapUnmanaged(void) = .empty;
    for (listed) |key| {
        if ((try known.getOrPut(arena, key)).found_existing) {
            problems += 1;
            std.debug.print("layer_baseline.zon: {s} entry `{s}` is listed twice\n", .{ @tagName(category), key });
        }
    }
    for (current.keys(), current.values()) |key, location| {
        if (known.contains(key)) continue;
        problems += 1;
        std.debug.print("{s}: new {s}: {s}\n", .{ location, category.describe(), key });
    }
    for (listed) |key| {
        if (current.contains(key)) continue;
        problems += 1;
        std.debug.print("layer_baseline.zon: stale {s} entry `{s}`; it is gone, so delete the entry\n", .{ @tagName(category), key });
    }
    return problems;
}

fn checkBudget(layers: Layers, findings: Findings) usize {
    const budget = layers.manifest.kernel_budget;
    var problems: usize = 0;
    if (findings.kernel_lines > budget.max_lines) {
        problems += 1;
        std.debug.print("layers.zon: package `{s}` has {d} lines, over its kernel_budget of {d}\n", .{ budget.package, findings.kernel_lines, budget.max_lines });
    }
    for (findings.depends[layers.kernel], 0..) |depends, target| {
        if (!depends) continue;
        if (indexOfPath(budget.max_dependencies, layers.name(target)) < budget.max_dependencies.len) continue;
        problems += 1;
        std.debug.print("layers.zon: package `{s}` now depends on `{s}`, outside its kernel_budget\n", .{ budget.package, layers.name(target) });
    }
    for (budget.max_dependencies) |dependency| {
        if (findings.depends[layers.kernel][layers.index(dependency).?]) continue;
        problems += 1;
        std.debug.print("layers.zon: package `{s}` no longer depends on `{s}`, so remove it from kernel_budget\n", .{ budget.package, dependency });
    }
    return problems;
}

fn check(arena: std.mem.Allocator, layers: Layers, findings: Findings, baseline: Baseline) !usize {
    var problems: usize = 0;
    for (findings.unowned.keys()) |path| {
        problems += 1;
        std.debug.print("{s}: belongs to no package in layers.zon\n", .{path});
    }
    inline for (comptime std.enums.values(Category)) |category| {
        problems += try compare(arena, category, @field(findings, @tagName(category)), try baselineKeys(arena, category, baseline));
    }
    return problems + checkBudget(layers, findings);
}

fn report(writer: *std.Io.Writer, layers: Layers, findings: Findings) !void {
    try writer.print("layer:check progress (upward imports / deep imports)\n", .{});
    for (0..layers.count()) |from| {
        for (0..layers.count()) |to| {
            const upward = findings.upward_counts[from][to];
            const deep = findings.deep_counts[from][to];
            if (upward == 0 and deep == 0) continue;
            try writer.print("  {s} -> {s}: {d} / {d}\n", .{ layers.name(from), layers.name(to), upward, deep });
        }
    }
    try writer.print("  upward imports {d}, deep imports {d}, package cycles {d}, module wiring {d}, wide module roots {d}\n", .{
        findings.upward.count(),
        findings.deep.count(),
        findings.cycles.count(),
        findings.wiring.count(),
        findings.wide_roots.count(),
    });
    for (findings.cycles.keys()) |cycle| try writer.print("  cycle: {s}\n", .{cycle});
    try writer.print("  {s}: {d} of {d} lines\n", .{ layers.manifest.kernel_budget.package, findings.kernel_lines, layers.manifest.kernel_budget.max_lines });
}

fn writeBaseline(writer: *std.Io.Writer, findings: Findings) !void {
    try writer.writeAll(".{\n");
    inline for (comptime std.enums.values(Category)) |category| {
        const current: Violations = @field(findings, @tagName(category));
        const keys = current.keys();
        std.mem.sort([]const u8, keys, {}, lessThan);
        try writer.print("    .{s} = .{{\n", .{@tagName(category)});
        for (keys) |key| {
            if (category == .wide_roots) {
                try writer.print("        \"{s}\",\n", .{key});
                continue;
            }
            try writer.writeAll("        .{ ");
            const separator = if (category == .cycles) ", " else " -> ";
            var parts = std.mem.splitSequence(u8, key, separator);
            var first = true;
            while (parts.next()) |part| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try writer.print("\"{s}\"", .{part});
            }
            try writer.writeAll(" },\n");
        }
        try writer.writeAll("    },\n");
    }
    try writer.writeAll("}\n");
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn parseWiring(arena: std.mem.Allocator, text: []const u8) !Wiring {
    var roots: std.ArrayList([]const u8) = .empty;
    var imports: std.ArrayList(Import) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next().?;
        if (std.mem.eql(u8, kind, "module")) {
            try roots.append(arena, fields.next() orelse return error.InvalidWiring);
        } else if (std.mem.eql(u8, kind, "import")) {
            try imports.append(arena, .{
                .root = fields.next() orelse return error.InvalidWiring,
                .name = fields.next() orelse return error.InvalidWiring,
                .target = fields.next() orelse return error.InvalidWiring,
            });
        } else return error.InvalidWiring;
    }
    return .{ .roots = roots.items, .imports = imports.items };
}

fn parseZon(comptime T: type, arena: std.mem.Allocator, path: []const u8, text: [:0]const u8) !T {
    var diagnostics: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc(T, arena, text, &diagnostics, .{}) catch |err| {
        if (err == error.ParseZon) std.debug.print("{s}: {f}\n", .{ path, diagnostics });
        return err;
    };
}

fn collect(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, prefix: []const u8, files: *std.ArrayList(SourceFile)) !void {
    var dir = root.openDir(io, prefix, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => try collect(arena, io, root, path, files),
            .file => if (std.mem.endsWith(u8, entry.name, ".zig")) try files.append(arena, .{
                .path = path,
                .source = try root.readFileAllocOptions(io, path, arena, .limited(16 * 1024 * 1024), .of(u8), 0),
            }),
            else => {},
        }
    }
}

fn readTree(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]const SourceFile {
    var files: std.ArrayList(SourceFile) = .empty;
    try collect(arena, io, root, "src", &files);
    try collect(arena, io, root, "tests", &files);
    std.mem.sort(SourceFile, files.items, {}, struct {
        fn lessThan(_: void, left: SourceFile, right: SourceFile) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.lessThan);
    return files.items;
}

fn readZ(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![:0]const u8 {
    return dir.readFileAllocOptions(io, path, arena, .limited(16 * 1024 * 1024), .of(u8), 0);
}

const Outcome = struct {
    layers: Layers,
    findings: Findings,
    problems: usize,
};

fn run(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, wiring_text: []const u8) !Outcome {
    const manifest = try parseZon(Manifest, arena, "layers.zon", try readZ(arena, io, root, "layers.zon"));
    const baseline = try parseZon(Baseline, arena, "layer_baseline.zon", try readZ(arena, io, root, "layer_baseline.zon"));
    const layers = try resolveLayers(arena, manifest);
    const findings = try analyze(arena, layers, try readTree(arena, io, root), try parseWiring(arena, wiring_text));
    return .{ .layers = layers, .findings = findings, .problems = try check(arena, layers, findings, baseline) };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, arena) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const root_path = args.next() orelse return error.InvalidArguments;
    const wiring_path = args.next() orelse return error.InvalidArguments;
    const print_baseline = if (args.next()) |flag| std.mem.eql(u8, flag, "--print-baseline") else false;

    var root = try std.Io.Dir.cwd().openDir(init.io, root_path, .{});
    defer root.close(init.io);
    const wiring_text = try std.Io.Dir.cwd().readFileAlloc(init.io, wiring_path, arena, .limited(16 * 1024 * 1024));
    const outcome = try run(arena, init.io, root, wiring_text);

    var buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const stdout = &stdout_writer.interface;
    if (print_baseline) {
        try writeBaseline(stdout, outcome.findings);
    } else {
        try report(stdout, outcome.layers, outcome.findings);
    }
    try stdout.flush();
    if (!print_baseline and outcome.problems != 0) return error.LayerViolation;
}

const test_layers =
    \\.{
    \\    .packages = .{
    \\        .{ .name = "base", .paths = .{ "src/util/", "src/types.zig", "src/util_root.zig" }, .allowed_dependencies = .{} },
    \\        .{ .name = "kernel", .paths = .{"src/core/agent_loop.zig"}, .allowed_dependencies = .{"base"} },
    \\        .{ .name = "coding", .paths = .{ "src/core/", "src/tools/" }, .allowed_dependencies = .{ "base", "kernel" } },
    \\        .{ .name = "cli", .paths = .{ "src/repl/", "src/main.zig" }, .allowed_dependencies = .{ "base", "kernel", "coding" } },
    \\        .{ .name = "tests", .paths = .{"tests/"}, .allowed_dependencies = .{ "base", "kernel", "coding", "cli" } },
    \\    },
    \\    .kernel_budget = .{ .package = "kernel", .max_lines = 3, .max_dependencies = .{ "base", "coding" } },
    \\}
    \\
;

const test_baseline =
    \\.{
    \\    .upward = .{
    \\        .{ "src/core/agent_loop.zig", "src/tools/bash.zig" },
    \\    },
    \\    .deep = .{
    \\        .{ "cli", "src/core/agent_loop.zig" },
    \\        .{ "cli", "src/tools/bash.zig" },
    \\        .{ "coding", "src/core/agent_loop.zig" },
    \\        .{ "coding", "src/util/fs.zig" },
    \\        .{ "kernel", "src/util/fs.zig" },
    \\    },
    \\    .cycles = .{
    \\        .{ "kernel", "coding" },
    \\    },
    \\    .wiring = .{},
    \\    .wide_roots = .{},
    \\}
    \\
;

const test_wiring = "module\tsrc/main.zig\nmodule\tsrc/util/platform.zig\nimport\tsrc/main.zig\tplatform\tsrc/util/platform.zig\n";

const clean_tree = [_][2][]const u8{
    .{ "src/util/fs.zig", "const std = @import(\"std\");\n" },
    .{ "src/util/platform.zig", "" },
    .{ "src/core/agent_loop.zig", "const fs = @import(\"../util/fs.zig\");\nconst bash = @import(\"../tools/bash.zig\");\n" },
    .{ "src/tools/bash.zig", "const loop = @import(\"../core/agent_loop.zig\");\nconst fs = @import(\"../util/fs.zig\");\n" },
    .{ "src/core/compact.zig", "const loop = @import(\"agent_loop.zig\");\n" },
    .{ "src/main.zig", "const loop = @import(\"core/agent_loop.zig\");\nconst bash = @import(\"tools/bash.zig\");\n" },
    .{ "src/repl/view.zig", "const main = @import(\"../main.zig\");\n" },
};

fn checkTree(files: []const [2][]const u8, layers_text: []const u8, baseline_text: []const u8, wiring: []const u8) !usize {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "layers.zon", .data = layers_text });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "layer_baseline.zon", .data = baseline_text });
    for (files) |file| {
        if (std.fs.path.dirnamePosix(file[0])) |dir| try tmp.dir.createDirPath(std.testing.io, dir);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file[0], .data = file[1] });
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try run(arena.allocator(), std.testing.io, tmp.dir, wiring);
    return outcome.problems;
}

fn withFile(comptime path: []const u8, comptime source: []const u8) [clean_tree.len + 1][2][]const u8 {
    return clean_tree ++ [_][2][]const u8{.{ path, source }};
}

test "the baseline describes the clean tree exactly" {
    try std.testing.expectEqual(@as(usize, 0), try checkTree(&clean_tree, test_layers, test_baseline, test_wiring));
}

test "a new upward import fails" {
    const tree = withFile("src/util/log.zig", "const view = @import(\"../repl/view.zig\");\n");
    try std.testing.expectEqual(@as(usize, 3), try checkTree(&tree, test_layers, test_baseline, test_wiring));
}

test "imports in comments and strings are not edges, imports in tests are" {
    const prose = withFile("src/util/log.zig",
        \\// const view = @import("../repl/view.zig");
        \\const text = "@import(\"../repl/view.zig\")";
        \\const sample =
        \\    \\@import("../repl/view.zig")
        \\;
        \\
    );
    try std.testing.expectEqual(@as(usize, 0), try checkTree(&prose, test_layers, test_baseline, test_wiring));
    const in_test = withFile("src/util/log.zig",
        \\test "view" {
        \\    _ = @import("../tools/bash.zig");
        \\}
        \\
    );
    try std.testing.expectEqual(@as(usize, 3), try checkTree(&in_test, test_layers, test_baseline, test_wiring));
}

test "a new package cycle fails" {
    const tree = withFile("src/util/log.zig", "const compact = @import(\"../core/compact.zig\");\n");
    try std.testing.expectEqual(@as(usize, 3), try checkTree(&tree, test_layers, test_baseline, test_wiring));
}

test "a file outside every package fails" {
    const tree = withFile("src/web/server.zig", "const std = @import(\"std\");\n");
    try std.testing.expectEqual(@as(usize, 1), try checkTree(&tree, test_layers, test_baseline, test_wiring));
}

test "a module import outside allowed_dependencies fails" {
    const wiring = test_wiring ++ "module\tsrc/util/fs.zig\nimport\tsrc/util/fs.zig\tapp\tsrc/main.zig\n";
    try std.testing.expectEqual(@as(usize, 3), try checkTree(&clean_tree, test_layers, test_baseline, wiring));
}

test "a module rooted above packages it may not reach fails" {
    const wiring = test_wiring ++ "module\tsrc/util_root.zig\n";
    const tree = withFile("src/util_root.zig", "");
    try std.testing.expectEqual(@as(usize, 1), try checkTree(&tree, test_layers, test_baseline, wiring));
}

test "a removed violation must be removed from the baseline" {
    var tree = clean_tree;
    tree[2][1] = "const fs = @import(\"../util/fs.zig\");\n";
    try std.testing.expectEqual(@as(usize, 3), try checkTree(&tree, test_layers, test_baseline, test_wiring));
}

test "the kernel may not grow past its budget" {
    var tree = clean_tree;
    tree[2][1] = "const fs = @import(\"../util/fs.zig\");\nconst bash = @import(\"../tools/bash.zig\");\n\n\n";
    try std.testing.expectEqual(@as(usize, 1), try checkTree(&tree, test_layers, test_baseline, test_wiring));
}

test "the manifest only allows dependencies on earlier packages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest: Manifest = .{
        .packages = &.{
            .{ .name = "base", .paths = &.{"src/util/"}, .allowed_dependencies = &.{"cli"} },
            .{ .name = "cli", .paths = &.{"src/util/"}, .allowed_dependencies = &.{"base"} },
        },
        .kernel_budget = .{ .package = "base", .max_lines = 0, .max_dependencies = &.{} },
    };
    try std.testing.expectError(error.InvalidManifest, resolveLayers(arena.allocator(), manifest));
}

test "paths resolve the way the compiler reads them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("src/util/model.zig", (try resolve(arena.allocator(), "src/provider/profiles/metask.zig", "../../util/model.zig")).?);
    try std.testing.expectEqualStrings("src/core/agent_loop.zig", (try resolve(arena.allocator(), "src/core/compact.zig", "./agent_loop.zig")).?);
    try std.testing.expect((try resolve(arena.allocator(), "src/provider/ids.zig", "platform")) == null);
}
