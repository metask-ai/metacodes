//! Typed Zig convenience layer shipped beside the binary ABI. No AgentCore
//! implementation source is imported (source-free binary consumption).

pub const types = @import("metask_agentcore_types");
pub const protocol = @import("metask_agentcore_protocol");

pub const Status = types.Status;
pub const StopReason = types.StopReason;
pub const CoreEvent = protocol.CoreEvent;
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
        return validate(@ptrCast(@alignCast(ptr)));
    }

    pub fn validate(raw: *const types.ApiV1) error{UnsupportedAbi}!Api {
        // Offsets 0..7 are the stable discovery prefix. Never read revision or
        // later fields from a differently sized table before the exact check.
        if (raw.struct_size != @sizeOf(types.ApiV1) or raw.abi_version != types.ABI_VERSION_V1)
            return error.UnsupportedAbi;
        if (raw.abi_revision != types.ABI_REVISION or raw.reserved0 != 0 or
            raw.capabilities != types.REQUIRED_CAPABILITIES_V1 or
            !allZero(raw.reserved) or
            raw.runtime_create == null or raw.runtime_destroy == null or
            raw.runtime_query_skill_catalog == null or raw.skill_catalog_release == null or
            raw.runtime_refresh_mcp == null or raw.runtime_describe_mcp == null or
            raw.runtime_apply_mcp_configuration == null or
            raw.session_restore == null or raw.session_describe == null or
            raw.session_create == null or raw.session_destroy == null or
            raw.session_set_model == null or raw.session_update_skills == null or
            raw.session_update_permission_rules == null or raw.session_update_mcp == null or
            raw.session_run_input == null or
            raw.session_abort == null or raw.session_compact == null or
            raw.session_abort_compact == null or raw.session_export_checkpoint == null or
            raw.completion_create == null or raw.completion_destroy == null or
            raw.completion_describe == null or raw.completion_complete == null or
            raw.completion_stream_start == null or raw.completion_stream_next == null or
            raw.completion_stream_abort == null or raw.completion_stream_destroy == null or
            raw.buffer_release == null)
            return error.UnsupportedAbi;
        return .{ .raw = raw };
    }

    pub fn runtimeCreate(self: Api) types.RuntimeCreateFnV1 {
        return self.raw.runtime_create.?;
    }
    pub fn runtimeDestroy(self: Api) types.RuntimeDestroyFnV1 {
        return self.raw.runtime_destroy.?;
    }
    /// Safe SDK name for the raw `runtime_query_skill_catalog` ABI slot.
    pub fn resolveWorkspaceSkillCatalog(self: Api) types.RuntimeQuerySkillCatalogFnV1 {
        return self.raw.runtime_query_skill_catalog.?;
    }
    pub fn skillCatalogRelease(self: Api) types.SkillCatalogReleaseFnV1 {
        return self.raw.skill_catalog_release.?;
    }
    pub fn runtimeRefreshMcp(self: Api) types.RuntimeRefreshMcpFnV1 {
        return self.raw.runtime_refresh_mcp.?;
    }
    pub fn runtimeDescribeMcp(self: Api) types.RuntimeDescribeMcpFnV1 {
        return self.raw.runtime_describe_mcp.?;
    }
    pub fn runtimeApplyMcpConfiguration(self: Api) types.RuntimeApplyMcpConfigurationFnV1 {
        return self.raw.runtime_apply_mcp_configuration.?;
    }
    pub fn sessionCreate(self: Api) types.SessionCreateFnV1 {
        return self.raw.session_create.?;
    }
    pub fn sessionRestore(self: Api) types.SessionRestoreFnV1 {
        return self.raw.session_restore.?;
    }
    pub fn sessionDestroy(self: Api) types.SessionDestroyFnV1 {
        return self.raw.session_destroy.?;
    }
    pub fn sessionDescribe(self: Api) types.SessionDescribeFnV1 {
        return self.raw.session_describe.?;
    }
    pub fn sessionSetModel(self: Api) types.SessionSetModelFnV1 {
        return self.raw.session_set_model.?;
    }
    /// Atomically binds a complete Catalog plus default-deny policy, or
    /// replaces only the policy when the Catalog argument is null.
    pub fn sessionBindSkillPolicy(self: Api) types.SessionBindSkillsFnV1 {
        return self.raw.session_update_skills.?;
    }
    pub fn sessionUpdatePermissionRules(self: Api) types.SessionUpdatePermissionRulesFnV1 {
        return self.raw.session_update_permission_rules.?;
    }
    pub fn sessionUpdateMcp(self: Api) types.SessionUpdateMcpFnV1 {
        return self.raw.session_update_mcp.?;
    }
    pub fn sessionRunInput(self: Api) types.SessionRunInputFnV1 {
        return self.raw.session_run_input.?;
    }
    pub fn sessionRunText(
        self: Api,
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
        return self.sessionRunInput()(
            session,
            run_id,
            &input,
            options,
            out_result,
            out_diagnostic,
        );
    }
    pub fn sessionRunSkill(
        self: Api,
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
        return self.sessionRunInput()(
            session,
            run_id,
            &input,
            options,
            out_result,
            out_diagnostic,
        );
    }
    pub fn sessionAbort(self: Api) types.SessionAbortFnV1 {
        return self.raw.session_abort.?;
    }
    pub fn sessionCompact(self: Api) types.SessionCompactFnV1 {
        return self.raw.session_compact.?;
    }
    pub fn sessionAbortCompact(self: Api) types.SessionAbortCompactFnV1 {
        return self.raw.session_abort_compact.?;
    }
    pub fn sessionExportCheckpoint(self: Api) types.SessionExportCheckpointFnV1 {
        return self.raw.session_export_checkpoint.?;
    }
    pub fn completionCreate(self: Api) types.CompletionCreateFnV1 {
        return self.raw.completion_create.?;
    }
    pub fn completionDestroy(self: Api) types.CompletionDestroyFnV1 {
        return self.raw.completion_destroy.?;
    }
    pub fn completionDescribe(self: Api) types.CompletionDescribeFnV1 {
        return self.raw.completion_describe.?;
    }
    pub fn completionComplete(self: Api) types.CompletionCompleteFnV1 {
        return self.raw.completion_complete.?;
    }
    pub fn completionStreamStart(self: Api) types.CompletionStreamStartFnV1 {
        return self.raw.completion_stream_start.?;
    }
    pub fn completionStreamNext(self: Api) types.CompletionStreamNextFnV1 {
        return self.raw.completion_stream_next.?;
    }
    pub fn completionStreamAbort(self: Api) types.CompletionStreamAbortFnV1 {
        return self.raw.completion_stream_abort.?;
    }
    pub fn completionStreamDestroy(self: Api) types.CompletionStreamDestroyFnV1 {
        return self.raw.completion_stream_destroy.?;
    }
    pub fn bufferRelease(self: Api) types.BufferReleaseFnV1 {
        return self.raw.buffer_release.?;
    }
};

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

test "Revision 9 SDK rejects an earlier table from the stable prefix" {
    const Revision5Api = extern struct {
        struct_size: u32,
        abi_version: u32,
        abi_revision: u32,
        reserved0: u32,
        capabilities: u64,
        tail: [144]u8,
    };
    var legacy: Revision5Api align(@alignOf(types.ApiV1)) =
        std.mem.zeroes(Revision5Api);
    legacy.struct_size = @sizeOf(Revision5Api);
    legacy.abi_version = types.ABI_VERSION_V1;
    legacy.abi_revision = 6;
    const raw: *const types.ApiV1 = @ptrCast(&legacy);
    try std.testing.expectError(error.UnsupportedAbi, Api.validate(raw));
}
