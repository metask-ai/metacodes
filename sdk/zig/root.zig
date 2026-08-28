//! Typed Zig convenience layer shipped beside the binary ABI. No AgentCore
//! implementation source is imported (source-free binary consumption).

pub const types = @import("metask_agentcore_types");
pub const protocol = @import("metask_agentcore_protocol");

pub const Status = types.Status;
pub const StopReason = types.StopReason;
pub const ProviderKind = types.ProviderKind;
pub const CoreEvent = protocol.CoreEvent;
pub const OutputSegmentDisposition = protocol.OutputSegmentDisposition;
pub const FileChangeRecord = protocol.FileChangeRecord;
pub const FileChangeKind = protocol.FileChangeKind;
pub const FileChangeStatus = protocol.FileChangeStatus;
pub const FileReference = protocol.FileReference;
pub const FileReferenceLocator = protocol.FileReferenceLocator;
pub const FileReferencePosition = protocol.FileReferencePosition;
pub const FileReferenceRange = protocol.FileReferenceRange;
pub const DecodedCoreEvent = protocol.DecodedCoreEvent;
pub const UnknownCoreEvent = protocol.UnknownCoreEvent;
pub const UiRequest = protocol.UiRequest;
pub const UiResponse = protocol.UiResponse;
pub const PermissionRequest = protocol.PermissionRequest;
pub const PermissionResponse = protocol.PermissionResponse;
pub const PermissionProvenance = protocol.PermissionProvenance;
pub const SkillCatalog = protocol.SkillCatalog;
pub const SkillDescriptor = protocol.SkillDescriptor;
pub const SkillArgumentSchema = protocol.SkillArgumentSchema;
pub const SkillCatalogIssue = protocol.SkillCatalogIssue;
pub const SkillCatalogHealth = protocol.SkillCatalogHealth;
pub const SkillCatalogIssueCode = protocol.SkillCatalogIssueCode;
pub const SkillCatalogIssueKind = protocol.SkillCatalogIssueKind;
pub const SkillCatalogResourceReason = protocol.SkillCatalogResourceReason;
pub const SkillSourceProjection = protocol.SkillSourceProjection;
pub const SkillSourceScope = protocol.SkillSourceScope;
pub const McpCatalog = protocol.McpCatalog;
pub const SessionDescription = protocol.SessionDescription;
pub const RestoreReport = protocol.RestoreReport;
pub const ParsedCoreEvent = protocol.ParsedCoreEvent;
pub const ParsedUiRequest = protocol.ParsedUiRequest;
pub const ParsedSkillCatalog = protocol.ParsedSkillCatalog;
pub const ParsedMcpCatalog = protocol.ParsedMcpCatalog;
pub const ParsedSessionDescription = protocol.ParsedSessionDescription;
pub const ParsedRestoreReport = protocol.ParsedRestoreReport;
pub const DecodeError = protocol.DecodeError;
pub const EncodeError = protocol.EncodeError;
pub const SkillCatalogDecodeError = protocol.SkillCatalogDecodeError;
pub const SkillArgumentsEncodeError = protocol.SkillArgumentsEncodeError;
pub const decodeCoreEvent = protocol.decodeCoreEvent;
pub const decodeUiRequest = protocol.decodeUiRequest;
pub const decodeSkillCatalog = protocol.decodeSkillCatalog;
pub const decodeMcpCatalog = protocol.decodeMcpCatalog;
pub const decodeSessionDescription = protocol.decodeSessionDescription;
pub const decodeRestoreReport = protocol.decodeRestoreReport;
pub const encodeUiResponse = protocol.encodeUiResponse;
pub const encodeSkillArguments = protocol.encodeSkillArguments;

comptime {
    if (protocol.MAX_SKILL_CATALOG_SKILLS_V1 != types.MAX_SKILL_CATALOG_SKILLS_V1 or
        protocol.MAX_SKILL_CATALOG_DESCRIPTOR_BYTES_V1 != types.MAX_SKILL_CATALOG_DESCRIPTOR_BYTES_V1 or
        protocol.MAX_SKILL_FILE_CONTENT_BYTES_V1 != types.MAX_SKILL_FILE_CONTENT_BYTES_V1 or
        protocol.MAX_SKILL_CONTENT_BYTES_V1 != types.MAX_SKILL_CONTENT_BYTES_V1 or
        protocol.MAX_SKILL_FILES_V1 != types.MAX_SKILL_FILES_V1 or
        protocol.MAX_SKILL_ENTRIES_V1 != types.MAX_SKILL_ENTRIES_V1 or
        protocol.MAX_SKILL_DIRECTORY_DEPTH_V1 != types.MAX_SKILL_DIRECTORY_DEPTH_V1 or
        protocol.MAX_SKILL_RELATIVE_PATH_BYTES_V1 != types.MAX_SKILL_RELATIVE_PATH_BYTES_V1 or
        protocol.MAX_SKILL_CATALOG_CONTENT_BYTES_V1 != types.MAX_SKILL_CATALOG_CONTENT_BYTES_V1 or
        protocol.MAX_SKILL_CATALOG_FILES_V1 != types.MAX_SKILL_CATALOG_FILES_V1 or
        protocol.MAX_SKILL_CATALOG_TRAVERSAL_ENTRIES_V1 != types.MAX_SKILL_CATALOG_TRAVERSAL_ENTRIES_V1 or
        protocol.MAX_SKILL_RUNTIME_RETAINED_SNAPSHOT_BYTES_V1 != types.MAX_SKILL_RUNTIME_RETAINED_SNAPSHOT_BYTES_V1 or
        protocol.MAX_SKILL_ARGUMENT_VALUES_V1 != types.MAX_SKILL_ARGUMENT_VALUES_V1 or
        protocol.MAX_SKILL_ARGUMENT_JSON_BYTES_V1 != types.MAX_SKILL_ARGUMENT_JSON_BYTES_V1 or
        protocol.MAX_DESCRIPTION_JSON_BYTES_V1 != types.MAX_DESCRIPTION_JSON_BYTES_V1 or
        protocol.MAX_MCP_SERVERS_V1 != types.MAX_MCP_SERVERS_V1 or
        protocol.MAX_MCP_TOOLS_V1 != types.MAX_MCP_TOOLS_V1 or
        protocol.MAX_AUTHORITY_ISSUES_V1 != types.MAX_MCP_CATALOG_ISSUES_V1 or
        protocol.MAX_PERMISSION_ARGUMENT_JSON_BYTES_V1 != types.MAX_PERMISSION_ARGUMENT_JSON_BYTES_V1)
        @compileError("JSON codec limits must match the raw ABI contract");
}

pub extern fn metask_agentcore_get_api(requested_abi: u32) callconv(.c) ?*const anyopaque;

pub fn bytesView(bytes: []const u8) types.BytesViewV1 {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

pub fn borrowedBytes(view: types.BytesViewV1) error{InvalidBytesView}![]const u8 {
    const len = std.math.cast(usize, view.len) orelse return error.InvalidBytesView;
    if (len == 0) return "";
    return (view.ptr orelse return error.InvalidBytesView)[0..len];
}

pub const RunContext = struct {
    session: *types.SessionHandle,
    run_id: u64,
    session_id: []const u8,
};

/// Validation order is part of the ABI defense: bound the Host-provided length
/// before constructing a slice from its pointer.
pub fn validateRunContext(raw: ?*const types.RunContextV1) error{InvalidRunContext}!RunContext {
    const run = raw orelse return error.InvalidRunContext;
    if (run.struct_size != @sizeOf(types.RunContextV1) or run.reserved0 != 0 or
        run.session == null or run.run_id == 0 or !allZero(run.reserved))
        return error.InvalidRunContext;
    if (run.session_id.len == 0 or run.session_id.len > types.MAX_SESSION_ID_BYTES_V1)
        return error.InvalidRunContext;
    const len: usize = @intCast(run.session_id.len);
    const bytes = (run.session_id.ptr orelse return error.InvalidRunContext)[0..len];
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidRunContext;
    return .{ .session = run.session.?, .run_id = run.run_id, .session_id = bytes };
}

pub const Api = struct {
    raw: *const types.ApiV1,

    pub fn discover() error{UnsupportedAbi}!Api {
        const ptr = metask_agentcore_get_api(types.ABI_VERSION_V1) orelse return error.UnsupportedAbi;
        return validate(ptr);
    }

    pub fn validate(raw_ptr: ?*const anyopaque) error{UnsupportedAbi}!Api {
        // Offsets 0..7 are the stable discovery prefix. Never read revision or
        // later fields from a differently sized table before the exact check.
        const ptr = raw_ptr orelse return error.UnsupportedAbi;
        if (@intFromPtr(ptr) % @alignOf(types.ApiV1) != 0) return error.UnsupportedAbi;
        const prefix: *const AbiPrefixV1 = @ptrCast(@alignCast(ptr));
        if (prefix.struct_size != @sizeOf(types.ApiV1) or prefix.abi_version != types.ABI_VERSION_V1)
            return error.UnsupportedAbi;
        const raw: *const types.ApiV1 = @ptrCast(@alignCast(ptr));
        if (raw.abi_revision != types.ABI_REVISION or raw.reserved0 != 0 or
            raw.buffer_release == null or !validateRuntimeApi(raw.runtime) or
            !validateSessionApi(raw.session) or
            !validateSessionControlApi(raw.session_control) or
            !validateSkillApi(raw.skill) or !validateMcpApi(raw.mcp))
            return error.UnsupportedAbi;
        return .{ .raw = raw };
    }

    pub fn runtime(self: Api) RuntimeApi {
        return .{ .raw = self.raw.runtime.? };
    }
    pub fn session(self: Api) SessionApi {
        return .{ .raw = self.raw.session.? };
    }
    pub fn sessionControl(self: Api) SessionControlApi {
        return .{ .raw = self.raw.session_control.? };
    }
    pub fn skill(self: Api) SkillApi {
        return .{ .raw = self.raw.skill.? };
    }
    pub fn mcp(self: Api) McpApi {
        return .{ .raw = self.raw.mcp.? };
    }
    pub fn bufferRelease(self: Api) types.BufferReleaseFnV1 {
        return self.raw.buffer_release.?;
    }
};

const AbiPrefixV1 = extern struct {
    struct_size: u32,
    abi_version: u32,
};

pub const RuntimeApi = struct {
    raw: *const types.RuntimeApiV1,

    pub fn create(self: RuntimeApi) types.RuntimeCreateFnV1 {
        return self.raw.create.?;
    }
    pub fn destroy(self: RuntimeApi) types.RuntimeDestroyFnV1 {
        return self.raw.destroy.?;
    }
};

pub const SessionApi = struct {
    raw: *const types.SessionApiV1,

    pub fn create(self: SessionApi) types.SessionCreateFnV1 {
        return self.raw.create.?;
    }
    pub fn destroy(self: SessionApi) types.SessionDestroyFnV1 {
        return self.raw.destroy.?;
    }
    pub fn runInput(self: SessionApi) types.SessionRunInputFnV1 {
        return self.raw.run_input.?;
    }
    pub fn runText(
        self: SessionApi,
        session: ?*types.SessionHandle,
        run_id: u64,
        prompt: types.BytesViewV1,
        options: ?*const types.RunOptionsV1,
        out_result: ?*types.RunResultV1,
        out_diagnostic: ?*types.OwnedBytesV1,
    ) u32 {
        const input = types.RunInputV1{
            .struct_size = @sizeOf(types.RunInputV1),
            .kind_code = types.RUN_INPUT_TEXT,
            .text = prompt,
            .skill_id = bytesView(""),
            .catalog_revision = bytesView(""),
            .arguments_json = bytesView(""),
            .reserved = [_]u64{0} ** 4,
        };
        return self.runInput()(
            session,
            run_id,
            &input,
            options,
            out_result,
            out_diagnostic,
        );
    }
    pub fn runSkill(
        self: SessionApi,
        session: ?*types.SessionHandle,
        run_id: u64,
        skill_id: types.BytesViewV1,
        catalog_revision: types.BytesViewV1,
        arguments_json: types.BytesViewV1,
        options: ?*const types.RunOptionsV1,
        out_result: ?*types.RunResultV1,
        out_diagnostic: ?*types.OwnedBytesV1,
    ) u32 {
        const input = types.RunInputV1{
            .struct_size = @sizeOf(types.RunInputV1),
            .kind_code = types.RUN_INPUT_SKILL,
            .text = bytesView(""),
            .skill_id = skill_id,
            .catalog_revision = catalog_revision,
            .arguments_json = arguments_json,
            .reserved = [_]u64{0} ** 4,
        };
        return self.runInput()(
            session,
            run_id,
            &input,
            options,
            out_result,
            out_diagnostic,
        );
    }
    pub fn abort(self: SessionApi) types.SessionAbortFnV1 {
        return self.raw.abort.?;
    }
};

pub const SessionControlApi = struct {
    raw: *const types.SessionControlApiV1,

    pub fn restore(self: SessionControlApi) types.SessionRestoreFnV1 {
        return self.raw.restore.?;
    }
    pub fn describe(self: SessionControlApi) types.SessionDescribeFnV1 {
        return self.raw.describe.?;
    }
    pub fn setModel(self: SessionControlApi) types.SessionSetModelFnV1 {
        return self.raw.set_model.?;
    }
    pub fn updatePermissionRules(self: SessionControlApi) types.SessionUpdatePermissionRulesFnV1 {
        return self.raw.update_permission_rules.?;
    }
    pub fn compact(self: SessionControlApi) types.SessionCompactFnV1 {
        return self.raw.compact.?;
    }
    pub fn abortCompact(self: SessionControlApi) types.SessionAbortCompactFnV1 {
        return self.raw.abort_compact.?;
    }
    pub fn exportCheckpoint(self: SessionControlApi) types.SessionExportCheckpointFnV1 {
        return self.raw.export_checkpoint.?;
    }
};

pub const SkillApi = struct {
    raw: *const types.SkillApiV1,

    pub fn resolveCatalog(self: SkillApi) types.RuntimeQuerySkillCatalogFnV1 {
        return self.raw.resolve_catalog.?;
    }
    pub fn releaseCatalog(self: SkillApi) types.SkillCatalogReleaseFnV1 {
        return self.raw.release_catalog.?;
    }
    /// Atomically binds a complete Catalog plus default-deny policy, or
    /// replaces only the policy when the Catalog argument is null.
    pub fn bindPolicy(self: SkillApi) types.SessionBindSkillsFnV1 {
        return self.raw.bind_policy.?;
    }
};

pub const McpApi = struct {
    raw: *const types.McpApiV1,

    pub fn applyConfiguration(self: McpApi) types.RuntimeApplyMcpConfigurationFnV1 {
        return self.raw.apply_configuration.?;
    }
    pub fn refresh(self: McpApi) types.RuntimeRefreshMcpFnV1 {
        return self.raw.refresh.?;
    }
    pub fn describe(self: McpApi) types.RuntimeDescribeMcpFnV1 {
        return self.raw.describe.?;
    }
    pub fn updateSelection(self: McpApi) types.SessionUpdateMcpFnV1 {
        return self.raw.update_selection.?;
    }
};

fn validateRuntimeApi(raw: ?*const types.RuntimeApiV1) bool {
    const api = raw orelse return false;
    if (@intFromPtr(api) % @alignOf(types.RuntimeApiV1) != 0) return false;
    return api.struct_size == @sizeOf(types.RuntimeApiV1) and api.reserved0 == 0 and
        api.create != null and api.destroy != null;
}

fn validateSessionApi(raw: ?*const types.SessionApiV1) bool {
    const api = raw orelse return false;
    if (@intFromPtr(api) % @alignOf(types.SessionApiV1) != 0) return false;
    return api.struct_size == @sizeOf(types.SessionApiV1) and api.reserved0 == 0 and
        api.create != null and api.destroy != null and api.run_input != null and api.abort != null;
}

fn validateSessionControlApi(raw: ?*const types.SessionControlApiV1) bool {
    const api = raw orelse return false;
    if (@intFromPtr(api) % @alignOf(types.SessionControlApiV1) != 0) return false;
    return api.struct_size == @sizeOf(types.SessionControlApiV1) and api.reserved0 == 0 and
        api.restore != null and api.describe != null and api.set_model != null and
        api.update_permission_rules != null and api.compact != null and
        api.abort_compact != null and api.export_checkpoint != null;
}

fn validateSkillApi(raw: ?*const types.SkillApiV1) bool {
    const api = raw orelse return false;
    if (@intFromPtr(api) % @alignOf(types.SkillApiV1) != 0) return false;
    return api.struct_size == @sizeOf(types.SkillApiV1) and api.reserved0 == 0 and
        api.resolve_catalog != null and api.release_catalog != null and api.bind_policy != null;
}

fn validateMcpApi(raw: ?*const types.McpApiV1) bool {
    const api = raw orelse return false;
    if (@intFromPtr(api) % @alignOf(types.McpApiV1) != 0) return false;
    return api.struct_size == @sizeOf(types.McpApiV1) and api.reserved0 == 0 and
        api.apply_configuration != null and api.refresh != null and api.describe != null and
        api.update_selection != null;
}

fn allZero(values: anytype) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

const std = @import("std");

test "SDK rejects incomplete API tables" {
    var raw: types.ApiV1 = std.mem.zeroes(types.ApiV1);
    try std.testing.expectError(error.UnsupportedAbi, Api.validate(&raw));
}

test "RunContext validator bounds length before pointer slicing" {
    var session_byte: u8 = 0;
    const session: *types.SessionHandle = @ptrCast(&session_byte);
    var run = std.mem.zeroes(types.RunContextV1);
    run.struct_size = @sizeOf(types.RunContextV1);
    run.session = session;
    run.run_id = 9;
    run.session_id = .{ .ptr = null, .len = std.math.maxInt(u64) };
    try std.testing.expectError(error.InvalidRunContext, validateRunContext(&run));

    const id = "0123456789abcdef01234567";
    run.session_id = bytesView(id);
    const valid = try validateRunContext(&run);
    try std.testing.expectEqual(@as(u64, 9), valid.run_id);
    try std.testing.expectEqualStrings(id, valid.session_id);
}

test "Revision 14 SDK rejects Revision 13 and old Revision 14 roots" {
    const Revision13Api = extern struct {
        struct_size: u32,
        abi_version: u32,
        abi_revision: u32,
        reserved0: u32,
        tail: [264]u8,
    };
    var revision13: Revision13Api align(@alignOf(types.ApiV1)) =
        std.mem.zeroes(Revision13Api);
    revision13.struct_size = @sizeOf(Revision13Api);
    revision13.abi_version = types.ABI_VERSION_V1;
    revision13.abi_revision = 13;
    try std.testing.expectEqual(@as(usize, 280), @sizeOf(Revision13Api));
    try std.testing.expectError(error.UnsupportedAbi, Api.validate(&revision13));

    const OldRevision14Api = extern struct {
        struct_size: u32,
        abi_version: u32,
        abi_revision: u32,
        reserved0: u32,
        tail: [56]u8,
    };
    var old_revision14: OldRevision14Api align(@alignOf(types.ApiV1)) =
        std.mem.zeroes(OldRevision14Api);
    old_revision14.struct_size = @sizeOf(OldRevision14Api);
    old_revision14.abi_version = types.ABI_VERSION_V1;
    old_revision14.abi_revision = 14;
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(OldRevision14Api));
    try std.testing.expectError(error.UnsupportedAbi, Api.validate(&old_revision14));
}
