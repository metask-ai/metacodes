const std = @import("std");
const pfs = @import("platform").fs;
const common = @import("common.zig");
const toolchain = @import("../util/toolchain.zig");
const symbols = @import("../symbols/symbol.zig");
const symbol_provider = @import("symbol_provider.zig");
const capability = @import("../lsp/capability.zig");
const ToolContext = @import("context.zig").ToolContext;

const MAX_CANDIDATE_FILES: usize = 300;
const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;
/// `rg -l -w` 候选文件列表字节上限:巨型仓库防护,读到此上限就 killpg。
/// 路径均长 ~80B × MAX_CANDIDATE_FILES=300 ≈ 24KB,256KB 给足余量又能在巨仓快速止血。
const LIST_BYTE_CAP: usize = 256 * 1024;

/// 一次跨文件定义扫描的结果。
pub const Scan = struct {
    /// 匹配的定义(owned:字符串字段 dupe 到 allocator,调用方负责 freeSymbol + free slice)。
    defs: []symbols.Symbol,
    /// 有候选文件因**符号能力缺失**被跳过时,记下**最可操作**的那个原因(不是最先遇到的——
    /// 见 `capability.moreActionable`);否则 null。
    /// 非 null ⇒ `defs` 不保证完整,空 `defs` **不得**解读为"查无定义"(issue #17)。
    unavailable: ?capability.Unavailable,
};

/// 跨文件找符号*定义*,并如实报告扫描过程中的能力缺失。kind_filter 非 null 时按
/// kind.jsonName() 过滤。
pub fn scanDefinitions(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    kind_filter: ?[]const u8,
    ctx: *const ToolContext,
) !Scan {
    const files = try listCandidateFiles(allocator, name, path, ctx);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }

    var defs: std.ArrayList(symbols.Symbol) = .empty;
    errdefer {
        for (defs.items) |s| freeSymbol(allocator, s);
        defs.deinit(allocator);
    }

    // 候选文件为空(rg 一个都没找到)时保持 null:那是真正的"查无此名",裸 `[]` 才是诚实的。
    var unavailable: ?capability.Unavailable = null;
    // 门禁答案只取决于扩展名,而每算一次要扫一遍 PATH(30 段 PATH 实测 36–43µs)。候选文件可达
    // 数千个、且被挡掉的那些此外什么都不做 → 不记忆化就是上百 ms 的纯 access(2)。
    var caps = symbol_provider.CapabilityCache.init(ctx);

    var processed: usize = 0;
    for (files) |file| {
        if (processed >= MAX_CANDIDATE_FILES) break;
        // 门禁:需要 LSP 在位 + 注册 server + 该 server 二进制真的装了。
        switch (caps.get(file)) {
            .available => {},
            .unavailable => |u| {
                unavailable = capability.moreActionable(unavailable, u);
                continue;
            },
        }
        processed += 1;
        try ctx.throwIfAborted();

        const source = readFile(allocator, file) catch continue;
        defer allocator.free(source);
        if (source.len > MAX_SOURCE_BYTES) continue;

        // **不 catch**:这里唯一的错误来源是分配失败。把 OOM 吞成"这文件没匹配"会得到一份
        // 短了却看起来完整的定义列表——正是本 issue 要消灭的那类谎报,只是换了个原因。
        var outcome = try symbol_provider.extractSymbols(ctx, allocator, file, source);
        switch (outcome) {
            // 门禁看不见的运行期失败(spawn 失败 / broken-set / client 满员 / 不在 git 仓)。
            .unavailable => |u| {
                unavailable = capability.moreActionable(unavailable, u);
                continue;
            },
            .symbols => |*syms| {
                defer syms.deinit();
                for (syms.items) |s| {
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    if (kind_filter) |kf| {
                        if (!std.mem.eql(u8, s.kind.jsonName(), kf)) continue;
                    }
                    try defs.append(allocator, try dupeSymbol(allocator, s));
                }
            },
        }
    }
    return .{ .defs = try defs.toOwnedSlice(allocator), .unavailable = unavailable };
}

/// `scanDefinitions` 的只要结果版。供 Grep 搭车复用——Grep 的主结果本就完整,拿不到定义前缀
/// 时静默降级是正确的,故它不需要能力状态。
pub fn findDefinitions(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    kind_filter: ?[]const u8,
    ctx: *const ToolContext,
) ![]symbols.Symbol {
    const scan = try scanDefinitions(allocator, name, path, kind_filter, ctx);
    return scan.defs;
}

/// Symbol 的字符串字段借用 extractSymbols 的临时 buffer(syms.deinit 后失效),
/// 跨函数边界返回前必须深拷贝。
fn dupeSymbol(allocator: std.mem.Allocator, s: symbols.Symbol) !symbols.Symbol {
    return .{
        .name = try allocator.dupe(u8, s.name),
        .kind = s.kind,
        .file = try allocator.dupe(u8, s.file),
        .line_start = s.line_start,
        .line_end = s.line_end,
        .signature = try allocator.dupe(u8, s.signature),
        .parent = if (s.parent) |p| try allocator.dupe(u8, p) else null,
        .doc = if (s.doc) |d| try allocator.dupe(u8, d) else null,
    };
}

/// 释放 findDefinitions 返回的单个 Symbol。公开供 Grep 搭车复用。
pub fn freeSymbolPublic(allocator: std.mem.Allocator, s: symbols.Symbol) void {
    freeSymbol(allocator, s);
}

fn freeSymbol(allocator: std.mem.Allocator, s: symbols.Symbol) void {
    allocator.free(s.name);
    allocator.free(s.file);
    allocator.free(s.signature);
    if (s.parent) |p| allocator.free(p);
    if (s.doc) |d| allocator.free(d);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FileNotFound;
    defer pfs.close(fd);
    return try common.readAllFromFdCapped(fd, allocator, MAX_SOURCE_BYTES);
}

/// rg -l -w --regexp=<name> -- <path>:列出含该词(词边界)的文件。
/// name 来自模型:只作为 `--regexp=` 的值传入,路径放在 `--` 之后,
/// 以 `-` 开头的 name(如 `--pre=<程序>`)不会被 rg 当成选项(#460)。
fn listCandidateFiles(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    ctx: *const ToolContext,
) ![][]const u8 {
    const rg_path = try toolchain.ripgrepPath();
    const name_z = try std.fmt.allocPrintSentinel(allocator, "--regexp={s}", .{name}, 0);
    defer allocator.free(name_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var argv = [_]?[*:0]const u8{
        rg_path.ptr,
        "-l",
        "-w",
        "--no-messages",
        name_z.ptr,
        "--",
        path_z.ptr,
        null,
    };
    const raw = common.spawnCaptureStdoutCapped(argv[0..argv.len], allocator, ctx.abort, 0, LIST_BYTE_CAP) catch
        return try allocator.alloc([]const u8, 0);
    defer allocator.free(raw);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, cursor, '\n')) |nl| {
        if (nl > cursor) {
            try files.append(allocator, try allocator.dupe(u8, raw[cursor..nl]));
        }
        cursor = nl + 1;
    }
    return try files.toOwnedSlice(allocator);
}
