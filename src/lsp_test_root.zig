//! test:lsp 隔离测试入口(仅 build.zig 的 test:lsp step 用,不进产品二进制)。
//!
//! 为什么不直接用 src/lsp/lsp.zig 当模块根:module path = 根文件所在目录。
//! service.zig 相对引用 ../util/time.zig(src/util/),根若在 src/lsp/ 就越出
//! module path,编译报 "import of file outside module path"。根放 src/ 一层即覆盖。
test {
    _ = @import("lsp/lsp.zig");
}
