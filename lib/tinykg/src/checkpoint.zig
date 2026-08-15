/// Compact canonical repository façade.
///
/// This subsystem is deliberately separate from `storage.zig`: legacy Store
/// remains the persistence dependency of query and task code, while the
/// daemon-owned compact Runtime may depend on query execution and rebuildable
/// in-memory indexes without creating a Storage façade cycle. Only reviewed
/// aliases are public; codec and file ownership stay private and movable.
const format_mod = @import("checkpoint/format.zig");
const mutation_mod = @import("checkpoint/mutation.zig");
const repository_mod = @import("checkpoint/repository.zig");
const restore_mod = @import("checkpoint/restore.zig");
const runtime_mod = @import("checkpoint/runtime.zig");
const snapshot_mod = @import("checkpoint/snapshot.zig");
const store_mod = @import("checkpoint/store.zig");
const wal_mod = @import("checkpoint/wal.zig");

pub const max_payload_bytes = format_mod.max_payload_bytes;
pub const current_format_version = format_mod.current_version;
pub const header_bytes = format_mod.header_len;
pub const Node = format_mod.Node;
pub const Edge = format_mod.Edge;
pub const EdgeOrder = format_mod.EdgeOrder;
pub const PropertyValueKind = format_mod.PropertyValueKind;
pub const Property = format_mod.Property;
pub const Snapshot = format_mod.Snapshot;

pub const Operation = mutation_mod.Operation;
pub const PreparedMutation = mutation_mod.Prepared;
pub const prepareMutationAlloc = mutation_mod.prepareAlloc;
pub const encodeMutationAlloc = mutation_mod.encodeAlloc;
pub const applyMutationEncodedAlloc = mutation_mod.applyEncodedAlloc;

pub const current_leaf = repository_mod.current_leaf;
pub const Current = repository_mod.Current;
pub const Loaded = repository_mod.Loaded;
pub const Collection = repository_mod.Collection;
pub const Footprint = repository_mod.Footprint;
pub const Repository = repository_mod.Repository;

pub const materializeStoreDirectory = restore_mod.materializeDirectory;
pub const LogicalBreakdown = runtime_mod.LogicalBreakdown;
pub const PublicationReceipt = runtime_mod.PublicationReceipt;
pub const Runtime = runtime_mod.Runtime;
pub const captureStoreAlloc = snapshot_mod.captureAlloc;

pub const Header = store_mod.Header;
pub const EncodedCheckpoint = store_mod.EncodedCheckpoint;
pub const DecodedCheckpoint = store_mod.DecodedCheckpoint;
pub const canonicalDigestAlloc = store_mod.canonicalDigestAlloc;
pub const encodeAlloc = store_mod.encodeAlloc;
pub const decodeAlloc = store_mod.decodeAlloc;

pub const wal_max_file_bytes = wal_mod.max_file_bytes;
pub const wal_file_header_len = wal_mod.file_header_len;
pub const wal_record_header_len = wal_mod.record_header_len;
pub const WalEncodedPayload = wal_mod.EncodedPayload;
pub const Wal = wal_mod.Wal;
pub const encodeWalPayloadAlloc = wal_mod.encodePayloadAlloc;

test {
    _ = Runtime;
    _ = Repository;
    _ = Snapshot;
}
