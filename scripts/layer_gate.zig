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
    owned_roots: usize = 0,
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

const FileImport = struct {
    literal: []const u8,
    line: usize,
};

fn importsOf(arena: std.mem.Allocator, source: [:0]const u8) ![]const FileImport {
    var imports: std.ArrayList(FileImport) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    var line: usize = 1;
    var scanned: usize = 0;
    var previous: [2]std.zig.Token.Tag = .{ .invalid, .invalid };
    var builtin_is_import = false;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        defer {
            previous = .{ previous[1], token.tag };
            if (token.tag == .builtin) builtin_is_import = std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import");
        }
        if (token.tag != .string_literal or previous[1] != .l_paren or previous[0] != .builtin) continue;
        if (!builtin_is_import) continue;
        line += std.mem.count(u8, source[scanned..token.loc.start], "\n");
        scanned = token.loc.start;
        try imports.append(arena, .{ .literal = source[token.loc.start + 1 .. token.loc.end - 1], .line = line });
    }
    return imports.items;
}

const EdgeKind = enum { relative, named };

fn addEdge(
    arena: std.mem.Allocator,
    layers: Layers,
    findings: *Findings,
    path: []const u8,
    line: usize,
    target: []const u8,
    kind: EdgeKind,
) !void {
    const from = layers.owner(path) orelse return;
    const to = layers.owner(target) orelse return;
    if (to == from) return;
    findings.depends[from][to] = true;
    const key = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ path, target });
    const location = try std.fmt.allocPrint(arena, "{s}:{d}", .{ path, line });
    if (!layers.mayDepend(from, to)) {
        if (try record(arena, &findings.upward, key, location)) findings.upward_counts[from][to] += 1;
    } else if (kind == .relative) {
        if (try record(arena, &findings.deep, key, location)) findings.deep_counts[from][to] += 1;
    }
}

fn analyze(arena: std.mem.Allocator, layers: Layers, files: []const SourceFile, wiring: Wiring) !Findings {
    const total = layers.count();
    var findings: Findings = .{
        .upward_counts = try matrix(usize, arena, total, 0),
        .deep_counts = try matrix(usize, arena, total, 0),
        .depends = try matrix(bool, arena, total, false),
    };
    var imports_by_file: std.StringHashMapUnmanaged([]const FileImport) = .empty;
    for (files) |file| {
        const imports = try importsOf(arena, file.source);
        try imports_by_file.put(arena, file.path, imports);
        const from = layers.owner(file.path) orelse {
            _ = try record(arena, &findings.unowned, file.path, file.path);
            continue;
        };
        if (from == layers.kernel) findings.kernel_lines += std.mem.count(u8, file.source, "\n");
        for (imports) |import| {
            const target = try resolve(arena, file.path, import.literal) orelse continue;
            try addEdge(arena, layers, &findings, file.path, import.line, target, .relative);
        }
    }
    var seen_roots: std.StringHashMapUnmanaged(void) = .empty;
    for (wiring.roots) |root| {
        if ((try seen_roots.getOrPut(arena, root)).found_existing) continue;
        var reached: std.StringHashMapUnmanaged(void) = .empty;
        var pending: std.ArrayList([]const u8) = .empty;
        try reached.put(arena, root, {});
        try pending.append(arena, root);
        while (pending.pop()) |path| {
            const imports = imports_by_file.get(path) orelse continue;
            for (imports) |import| {
                if (try resolve(arena, path, import.literal)) |target| {
                    if (!(try reached.getOrPut(arena, target)).found_existing) try pending.append(arena, target);
                    continue;
                }
                for (wiring.imports) |wired| {
                    if (!std.mem.eql(u8, wired.root, root) or !std.mem.eql(u8, wired.name, import.literal)) continue;
                    try addEdge(arena, layers, &findings, path, import.line, wired.target, .named);
                }
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
        findings.owned_roots += 1;
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
    if (findings.owned_roots == 0) {
        problems += 1;
        std.debug.print("build.zig: the module wiring names no module rooted in a package\n", .{});
    }
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

const Base = struct {
    manifest: Manifest,
    baseline: Baseline,
};

fn growth(arena: std.mem.Allocator, base: Base, manifest: Manifest, baseline: Baseline) !usize {
    var problems: usize = 0;
    const base_layers = try resolveLayers(arena, base.manifest);
    var base_edges: std.StringHashMapUnmanaged(void) = .empty;
    for (try baselineKeys(arena, .upward, base.baseline)) |key| try base_edges.put(arena, key, {});
    for (try baselineKeys(arena, .deep, base.baseline)) |key| try base_edges.put(arena, key, {});
    inline for (.{ Category.upward, Category.deep }) |category| {
        for (@field(baseline, @tagName(category))) |entry| {
            const key = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ entry[0], entry[1] });
            if (base_edges.contains(key)) continue;
            const owner = base_layers.owner(entry[0]);
            if (owner != null and owner == base_layers.owner(entry[1])) continue;
            problems += 1;
            std.debug.print("layer_baseline.zon: {s} entry `{s}` is not in the base's baseline, which only shrinks\n", .{ @tagName(category), key });
        }
    }
    inline for (.{ Category.wiring, Category.wide_roots }) |category| {
        var before: std.StringHashMapUnmanaged(void) = .empty;
        for (try baselineKeys(arena, category, base.baseline)) |key| try before.put(arena, key, {});
        for (try baselineKeys(arena, category, baseline)) |key| {
            if (before.contains(key)) continue;
            problems += 1;
            std.debug.print("layer_baseline.zon: {s} entry `{s}` is not in the base's baseline, which only shrinks\n", .{ @tagName(category), key });
        }
    }
    for (baseline.cycles) |members| {
        if (withinSomeCycle(members, base.baseline.cycles)) continue;
        problems += 1;
        std.debug.print("layer_baseline.zon: cycle `{s}` is not within a cycle of the base's baseline\n", .{try std.mem.join(arena, ", ", members)});
    }
    const budget = manifest.kernel_budget;
    const base_budget = base.manifest.kernel_budget;
    if (budget.max_lines > base_budget.max_lines) {
        problems += 1;
        std.debug.print("layers.zon: kernel_budget.max_lines rises from {d} to {d}; it only goes down\n", .{ base_budget.max_lines, budget.max_lines });
    }
    for (budget.max_dependencies) |dependency| {
        if (indexOfPath(base_budget.max_dependencies, dependency) < base_budget.max_dependencies.len) continue;
        problems += 1;
        std.debug.print("layers.zon: kernel_budget gains `{s}`; it only shrinks\n", .{dependency});
    }
    for (manifest.packages) |package| {
        const before = packageNamed(base.manifest, package.name) orelse continue;
        for (package.allowed_dependencies) |dependency| {
            if (indexOfPath(before.allowed_dependencies, dependency) < before.allowed_dependencies.len) continue;
            if (packageNamed(base.manifest, dependency) == null and reachesNoFurther(manifest, dependency, before)) continue;
            problems += 1;
            std.debug.print("layers.zon: `{s}` newly allows `{s}`; allowed_dependencies do not widen\n", .{ package.name, dependency });
        }
    }
    return problems;
}

fn reachesNoFurther(manifest: Manifest, new_package: []const u8, before: Package) bool {
    const added = packageNamed(manifest, new_package) orelse return false;
    for (added.allowed_dependencies) |dependency| {
        if (indexOfPath(before.allowed_dependencies, dependency) == before.allowed_dependencies.len) return false;
    }
    return true;
}

fn withinSomeCycle(members: []const []const u8, cycles: []const []const []const u8) bool {
    for (cycles) |cycle| {
        for (members) |member| {
            if (indexOfPath(cycle, member) == cycle.len) break;
        } else return true;
    }
    return false;
}

fn packageNamed(manifest: Manifest, package_name: []const u8) ?Package {
    for (manifest.packages) |package| {
        if (std.mem.eql(u8, package.name, package_name)) return package;
    }
    return null;
}

fn parseBase(arena: std.mem.Allocator, layers_text: [:0]const u8, baseline_text: [:0]const u8) !Base {
    return .{
        .manifest = try parseZon(Manifest, arena, "base layers.zon", layers_text),
        .baseline = try parseZon(Baseline, arena, "base layer_baseline.zon", baseline_text),
    };
}

fn git(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) !?[]const u8 {
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    return switch (result.term) {
        .exited => |code| if (code == 0) result.stdout else null,
        else => null,
    };
}

fn readBase(arena: std.mem.Allocator, io: std.Io, ref: []const u8) !?Base {
    const commit = try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{ref});
    if (try git(arena, io, &.{ "git", "rev-parse", "--verify", "--quiet", commit }) == null) {
        std.debug.print("layer:check: base `{s}` is not a commit\n", .{ref});
        return error.InvalidBase;
    }
    var texts: [2][:0]const u8 = undefined;
    for ([_][]const u8{ "layers.zon", "layer_baseline.zon" }, &texts) |path, *text| {
        const object = try std.fmt.allocPrint(arena, "{s}:{s}", .{ ref, path });
        if (try git(arena, io, &.{ "git", "cat-file", "-e", object }) == null) {
            std.debug.print("layer:check: base `{s}` has no {s}, so there is nothing to compare against\n", .{ ref, path });
            return null;
        }
        const contents = try git(arena, io, &.{ "git", "show", object }) orelse return error.InvalidBase;
        text.* = try arena.dupeZ(u8, contents);
    }
    return try parseBase(arena, texts[0], texts[1]);
}

const Outcome = struct {
    layers: Layers,
    findings: Findings,
    problems: usize,
};

fn run(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, wiring_text: []const u8, base: ?Base) !Outcome {
    const manifest = try parseZon(Manifest, arena, "layers.zon", try readZ(arena, io, root, "layers.zon"));
    const baseline = try parseZon(Baseline, arena, "layer_baseline.zon", try readZ(arena, io, root, "layer_baseline.zon"));
    const layers = try resolveLayers(arena, manifest);
    const findings = try analyze(arena, layers, try readTree(arena, io, root), try parseWiring(arena, wiring_text));
    var problems = try check(arena, layers, findings, baseline);
    if (base) |before| problems += try growth(arena, before, manifest, baseline);
    return .{ .layers = layers, .findings = findings, .problems = problems };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = std.process.Args.iterateAllocator(init.minimal.args, arena) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const root_path = args.next() orelse return error.InvalidArguments;
    const wiring_path = args.next() orelse return error.InvalidArguments;
    var print_baseline = false;
    var base_ref: ?[]const u8 = null;
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--print-baseline")) {
            print_baseline = true;
        } else if (std.mem.eql(u8, flag, "--base")) {
            base_ref = args.next() orelse return error.InvalidArguments;
        } else return error.InvalidArguments;
    }

    var root = try std.Io.Dir.cwd().openDir(init.io, root_path, .{});
    defer root.close(init.io);
    const wiring_text = try std.Io.Dir.cwd().readFileAlloc(init.io, wiring_path, arena, .limited(16 * 1024 * 1024));
    const base = if (base_ref) |ref| try readBase(arena, init.io, ref) else null;
    const outcome = try run(arena, init.io, root, wiring_text, base);

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
    \\        .{ "src/core/agent_loop.zig", "src/util/fs.zig" },
    \\        .{ "src/core/compact.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/main.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/main.zig", "src/tools/bash.zig" },
    \\        .{ "src/tools/bash.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/tools/bash.zig", "src/util/fs.zig" },
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
    return checkTreeAgainst(files, layers_text, baseline_text, wiring, null);
}

fn checkTreeAgainst(
    files: []const [2][]const u8,
    layers_text: []const u8,
    baseline_text: []const u8,
    wiring: []const u8,
    base_texts: ?[2][:0]const u8,
) !usize {
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
    const base = if (base_texts) |texts| try parseBase(arena.allocator(), texts[0], texts[1]) else null;
    const outcome = try run(arena.allocator(), std.testing.io, tmp.dir, wiring, base);
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
    const split = withFile("src/util/log.zig",
        \\const view = @import // UI dependency
        \\    ("../repl/view.zig");
        \\const spaced = @import ( "../repl/view.zig" );
        \\const other = @importer("../repl/view.zig");
        \\
    );
    try std.testing.expectEqual(@as(usize, 3), try checkTree(&split, test_layers, test_baseline, test_wiring));
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

test "wiring that names no module root in a package fails" {
    try std.testing.expectEqual(@as(usize, 1), try checkTree(&clean_tree, test_layers, test_baseline, "import\tsrc\\main.zig\tplatform\tsrc\\util\\platform.zig\n"));
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

test "a named import counts from the file that writes it, not the module root" {
    var tree = withFile("src/util/log.zig", "const code = @import(\"code\");\n");
    tree[5][1] = "const loop = @import(\"core/agent_loop.zig\");\nconst bash = @import(\"tools/bash.zig\");\nconst log = @import(\"util/log.zig\");\n";
    const wiring = test_wiring ++ "import\tsrc/main.zig\tcode\tsrc/tools/bash.zig\n";
    try std.testing.expectEqual(@as(usize, 0), try checkTree(&clean_tree, test_layers, test_baseline, wiring));
    try std.testing.expectEqual(@as(usize, 4), try checkTree(&tree, test_layers, test_baseline, wiring));
}

test "a deep import is one file edge, so a second file reaching the same target is new" {
    const tree = withFile("src/tools/grep.zig", "const fs = @import(\"../util/fs.zig\");\n");
    try std.testing.expectEqual(@as(usize, 1), try checkTree(&tree, test_layers, test_baseline, test_wiring));
}

const grown_baseline =
    \\.{
    \\    .upward = .{
    \\        .{ "src/core/agent_loop.zig", "src/tools/bash.zig" },
    \\        .{ "src/util/log.zig", "src/repl/view.zig" },
    \\    },
    \\    .deep = .{
    \\        .{ "src/core/agent_loop.zig", "src/util/fs.zig" },
    \\        .{ "src/core/compact.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/main.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/main.zig", "src/tools/bash.zig" },
    \\        .{ "src/tools/bash.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/tools/bash.zig", "src/util/fs.zig" },
    \\    },
    \\    .cycles = .{
    \\        .{ "base", "kernel", "coding", "cli" },
    \\    },
    \\}
    \\
;

test "the baseline may not grow against the base, even when it matches the tree" {
    const base = [2][:0]const u8{ test_layers, test_baseline };
    try std.testing.expectEqual(@as(usize, 0), try checkTreeAgainst(&clean_tree, test_layers, test_baseline, test_wiring, base));
    const tree = withFile("src/util/log.zig", "const view = @import(\"../repl/view.zig\");\n");
    try std.testing.expectEqual(@as(usize, 0), try checkTree(&tree, test_layers, grown_baseline, test_wiring));
    try std.testing.expectEqual(@as(usize, 2), try checkTreeAgainst(&tree, test_layers, grown_baseline, test_wiring, base));
}

test "the kernel budget and allowed_dependencies may not widen against the base" {
    const base = [2][:0]const u8{ test_layers, test_baseline };
    const raised = comptime blk: {
        const needle = ".max_lines = 3";
        const at = std.mem.indexOf(u8, test_layers, needle).?;
        break :blk test_layers[0..at] ++ ".max_lines = 9" ++ test_layers[at + needle.len ..];
    };
    try std.testing.expectEqual(@as(usize, 1), try checkTreeAgainst(&clean_tree, raised, test_baseline, test_wiring, base));
    const narrower = comptime blk: {
        const needle = "\"src/tools/\" }, .allowed_dependencies = .{ \"base\", \"kernel\" } },";
        const at = std.mem.indexOf(u8, test_layers, needle).?;
        break :blk test_layers[0..at] ++ "\"src/tools/\" }, .allowed_dependencies = .{\"base\"} }," ++ test_layers[at + needle.len ..];
    };
    const narrower_base = [2][:0]const u8{ narrower, test_baseline };
    try std.testing.expectEqual(@as(usize, 1), try checkTreeAgainst(&clean_tree, test_layers, test_baseline, test_wiring, narrower_base));
}

test "a shrinking baseline and budget pass against the base" {
    const base = [2][:0]const u8{ test_layers, test_baseline };
    var tree = clean_tree;
    tree[2][1] = "const fs = @import(\"../util/fs.zig\");\n";
    const shrunk_layers = comptime blk: {
        const needle = ".max_lines = 3, .max_dependencies = .{ \"base\", \"coding\" }";
        const at = std.mem.indexOf(u8, test_layers, needle).?;
        break :blk test_layers[0..at] ++ ".max_lines = 1, .max_dependencies = .{\"base\"}" ++ test_layers[at + needle.len ..];
    };
    const shrunk_baseline =
        \\.{
        \\    .deep = .{
        \\        .{ "src/core/agent_loop.zig", "src/util/fs.zig" },
        \\        .{ "src/core/compact.zig", "src/core/agent_loop.zig" },
        \\        .{ "src/main.zig", "src/core/agent_loop.zig" },
        \\        .{ "src/main.zig", "src/tools/bash.zig" },
        \\        .{ "src/tools/bash.zig", "src/core/agent_loop.zig" },
        \\        .{ "src/tools/bash.zig", "src/util/fs.zig" },
        \\    },
        \\}
        \\
    ;
    try std.testing.expectEqual(@as(usize, 0), try checkTreeAgainst(&tree, shrunk_layers, shrunk_baseline, test_wiring, base));
}

const split_layers =
    \\.{
    \\    .packages = .{
    \\        .{ .name = "base", .paths = .{ "src/util/", "src/types.zig", "src/util_root.zig" }, .allowed_dependencies = .{} },
    \\        .{ .name = "kernel", .paths = .{"src/core/agent_loop.zig"}, .allowed_dependencies = .{"base"} },
    \\        .{ .name = "coding", .paths = .{ "src/core/", "src/tools/" }, .allowed_dependencies = .{ "base", "kernel" } },
    \\        .{ .name = "facade", .paths = .{"src/main.zig"}, .allowed_dependencies = .{ "base", "kernel", "coding" } },
    \\        .{ .name = "cli", .paths = .{"src/repl/"}, .allowed_dependencies = .{ "base", "kernel", "coding", "facade" } },
    \\        .{ .name = "tests", .paths = .{"tests/"}, .allowed_dependencies = .{ "base", "kernel", "coding", "facade", "cli" } },
    \\    },
    \\    .kernel_budget = .{ .package = "kernel", .max_lines = 3, .max_dependencies = .{ "base", "coding" } },
    \\}
    \\
;

const split_baseline =
    \\.{
    \\    .upward = .{
    \\        .{ "src/core/agent_loop.zig", "src/tools/bash.zig" },
    \\    },
    \\    .deep = .{
    \\        .{ "src/core/agent_loop.zig", "src/util/fs.zig" },
    \\        .{ "src/core/compact.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/main.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/main.zig", "src/tools/bash.zig" },
    \\        .{ "src/repl/view.zig", "src/main.zig" },
    \\        .{ "src/tools/bash.zig", "src/core/agent_loop.zig" },
    \\        .{ "src/tools/bash.zig", "src/util/fs.zig" },
    \\    },
    \\    .cycles = .{
    \\        .{ "kernel", "coding" },
    \\    },
    \\}
    \\
;

test "splitting a package records its inner edges without growing against the base" {
    const base = [2][:0]const u8{ test_layers, test_baseline };
    const split_wiring = "module\tsrc/util/platform.zig\n";
    try std.testing.expectEqual(@as(usize, 0), try checkTreeAgainst(&clean_tree, split_layers, split_baseline, split_wiring, base));
    const tree = withFile("src/tools/grep.zig", "const fs = @import(\"../util/fs.zig\");\n");
    const grown = comptime blk: {
        const needle = "    .deep = .{\n";
        const at = std.mem.indexOf(u8, split_baseline, needle).?;
        break :blk split_baseline[0 .. at + needle.len] ++ "        .{ \"src/tools/grep.zig\", \"src/util/fs.zig\" },\n" ++ split_baseline[at + needle.len ..];
    };
    try std.testing.expectEqual(@as(usize, 1), try checkTreeAgainst(&tree, split_layers, grown, split_wiring, base));
}

test "a new package is allowed only when it reaches no package the dependent could not" {
    const shim_layers = comptime blk: {
        const needle = "        .{ .name = \"coding\", .paths = .{ \"src/core/\", \"src/tools/\" }, .allowed_dependencies = .{ \"base\", \"kernel\" } },";
        const at = std.mem.indexOf(u8, test_layers, needle).?;
        break :blk test_layers[0..at] ++
            "        .{ .name = \"shim\", .paths = .{\"src/shim/\"}, .allowed_dependencies = .{ \"base\", \"kernel\" } },\n" ++
            "        .{ .name = \"coding\", .paths = .{ \"src/core/\", \"src/tools/\" }, .allowed_dependencies = .{ \"base\", \"kernel\", \"shim\" } }," ++
            test_layers[at + needle.len ..];
    };
    const base = [2][:0]const u8{ test_layers, test_baseline };
    try std.testing.expectEqual(@as(usize, 0), try checkTreeAgainst(&clean_tree, shim_layers, test_baseline, test_wiring, base));
    const narrower = comptime blk: {
        const needle = "\"src/tools/\" }, .allowed_dependencies = .{ \"base\", \"kernel\" } },";
        const at = std.mem.indexOf(u8, test_layers, needle).?;
        break :blk test_layers[0..at] ++ "\"src/tools/\" }, .allowed_dependencies = .{\"base\"} }," ++ test_layers[at + needle.len ..];
    };
    const narrower_base = [2][:0]const u8{ narrower, test_baseline };
    try std.testing.expectEqual(@as(usize, 2), try checkTreeAgainst(&clean_tree, shim_layers, test_baseline, test_wiring, narrower_base));
}
