//! tinykg lib 链接烟雾(walking skeleton)。
//!
//! 目的:证明 tinykg 作为 Zig lib 真链接进 metacodes 并编译通过——先拿到"能链接",
//! 再谈把 KgClient 的子进程调用逐个换成直接 lib 调用。
//!
//! 现状:仅编译期引用 tinykg 顶层模块(storage/schema/catalog/dag/graph),确认符号可达、
//! std API 兼容(两边同 zig 0.16)。运行期调用(open store / read version / add-node)在
//! 后续阶段接入 KgClient。

const tinykg = @import("tinykg");

/// 编译期确认核心模块可达(被 client.zig comptime 引用,拉进编译图)。
pub fn linkOk() void {
    _ = tinykg.storage;
    _ = tinykg.schema;
    _ = tinykg.catalog;
    _ = tinykg.dag;
    _ = tinykg.graph;
    _ = tinykg.core;
}

test "tinykg lib 链接:核心模块符号可达" {
    linkOk();
    // 引用具体类型,强制实例化编译(不只是模块存在)。
    const NodeKind = tinykg.core.NodeKind;
    try @import("std").testing.expect(@typeInfo(NodeKind) == .@"enum");
}
