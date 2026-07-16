const std = @import("std");

pub const max_nodes: usize = 4_000_000;
pub const max_texts_file_bytes: u64 = 1024 * 1024 * 1024;

pub const CatalogSummary = struct {
    node_count: u64,
    node_id_base: u64 = 0,
    texts_bytes: u64,
    texts_digest: u64,
    nodes_record_digest: u64,
    exact_record_digest: u64,

    pub fn validate(self: CatalogSummary) !void {
        if (self.node_count > max_nodes) return error.RecordTooLarge;
        if (self.texts_bytes > max_texts_file_bytes) return error.RecordTooLarge;
        if (self.node_count == 0 and self.node_id_base != 0) return error.InvalidRecord;
        if (self.node_id_base == std.math.maxInt(u64)) return error.InvalidRecord;
    }
};
