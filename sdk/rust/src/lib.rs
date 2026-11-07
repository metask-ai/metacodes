#![allow(non_camel_case_types, non_snake_case, non_upper_case_globals)]

pub mod raw;
pub use raw::*;

use std::ffi::c_void;
use std::marker::PhantomData;
use std::mem::{size_of, ManuallyDrop};
use std::ptr::{self, NonNull};
use std::slice;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AbiError {
    UnsupportedAbi,
    InvalidOwnedBytes,
    LengthOverflow,
}

/// Validated root at exactly `METASK_AGENTCORE_ABI_REVISION`, plus its
/// mandatory domain tables. Discovery rejects every other layout; there is no
/// legacy probe or alternate dispatch.
#[derive(Clone, Copy)]
pub struct Api {
    raw: NonNull<raw::metask_agentcore_api_v1>,
}

#[repr(C)]
struct AbiPrefixV1 {
    struct_size: u32,
    abi_version: u32,
}

impl Api {
    pub fn discover() -> Result<Self, AbiError> {
        let ptr = unsafe { raw::metask_agentcore_get_api(raw::METASK_AGENTCORE_ABI_V1) };
        unsafe { Self::from_raw(ptr.cast()) }
    }

    /// `ptr` must be a readable table returned by
    /// `metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1)` and remain valid for
    /// the process lifetime.
    pub unsafe fn from_raw(ptr: *const raw::metask_agentcore_api_v1) -> Result<Self, AbiError> {
        if ptr.is_null()
            || (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_api_v1>() != 0
        {
            return Err(AbiError::UnsupportedAbi);
        }
        let prefix = unsafe { &*ptr.cast::<AbiPrefixV1>() };
        if prefix.struct_size as usize != size_of::<raw::metask_agentcore_api_v1>()
            || prefix.abi_version != raw::METASK_AGENTCORE_ABI_V1
        {
            return Err(AbiError::UnsupportedAbi);
        }
        let raw = NonNull::new(ptr.cast_mut()).ok_or(AbiError::UnsupportedAbi)?;
        let table = unsafe { raw.as_ref() };
        if table.abi_revision != raw::METASK_AGENTCORE_ABI_REVISION
            || table.reserved0 != 0
            || table.buffer_release.is_none()
            || !unsafe { validate_runtime_api(table.runtime) }
            || !unsafe { validate_session_api(table.session) }
            || !unsafe { validate_session_control_api(table.session_control) }
            || !unsafe { validate_skill_api(table.skill) }
            || !unsafe { validate_mcp_api(table.mcp) }
            || !unsafe { validate_goal_api(table.goal) }
            || !unsafe { validate_team_api(table.team) }
        {
            return Err(AbiError::UnsupportedAbi);
        }
        Ok(Self { raw })
    }

    pub fn as_raw(self) -> *const raw::metask_agentcore_api_v1 {
        self.raw.as_ptr()
    }

    fn table(self) -> &'static raw::metask_agentcore_api_v1 {
        unsafe { self.raw.as_ref() }
    }

    pub fn owned_buffer(self) -> OwnedBuffer {
        OwnedBuffer::new(self)
    }

    pub fn buffer_release(self) -> raw::metask_agentcore_buffer_release_fn_v1 {
        self.table().buffer_release
    }

    pub fn runtime(self) -> RuntimeApi {
        RuntimeApi {
            raw: NonNull::new(self.table().runtime.cast_mut()).expect("validated Runtime API"),
        }
    }

    pub fn session(self) -> SessionApi {
        SessionApi {
            raw: NonNull::new(self.table().session.cast_mut()).expect("validated Session API"),
        }
    }

    pub fn session_control(self) -> SessionControlApi {
        SessionControlApi {
            raw: NonNull::new(self.table().session_control.cast_mut())
                .expect("validated Session Control API"),
        }
    }

    pub fn skill(self) -> SkillApi {
        SkillApi {
            raw: NonNull::new(self.table().skill.cast_mut()).expect("validated Skill API"),
        }
    }

    pub fn mcp(self) -> McpApi {
        McpApi {
            raw: NonNull::new(self.table().mcp.cast_mut()).expect("validated MCP API"),
        }
    }

    /// Revision 23: the Session's goal.
    pub fn goal(self) -> GoalApi {
        GoalApi {
            raw: NonNull::new(self.table().goal.cast_mut()).expect("validated Goal API"),
        }
    }

    /// Revision 24: the Session's host-scheduled team (issue #277).
    pub fn team(self) -> TeamApi {
        TeamApi {
            raw: NonNull::new(self.table().team.cast_mut()).expect("validated Team API"),
        }
    }
}

#[derive(Clone, Copy)]
pub struct RuntimeApi {
    raw: NonNull<raw::metask_agentcore_runtime_api_v1>,
}

impl RuntimeApi {
    fn table(self) -> &'static raw::metask_agentcore_runtime_api_v1 {
        unsafe { self.raw.as_ref() }
    }

    pub fn create(self) -> raw::metask_agentcore_runtime_create_fn_v1 {
        self.table().create
    }

    pub fn destroy(self) -> raw::metask_agentcore_runtime_destroy_fn_v1 {
        self.table().destroy
    }
}

#[derive(Clone, Copy)]
pub struct SessionApi {
    raw: NonNull<raw::metask_agentcore_session_api_v1>,
}

impl SessionApi {
    fn table(self) -> &'static raw::metask_agentcore_session_api_v1 {
        unsafe { self.raw.as_ref() }
    }

    pub fn create(self) -> raw::metask_agentcore_session_create_fn_v1 {
        self.table().create
    }
    pub fn destroy(self) -> raw::metask_agentcore_session_destroy_fn_v1 {
        self.table().destroy
    }
    pub fn run_input(self) -> raw::metask_agentcore_session_run_input_fn_v1 {
        self.table().run_input
    }
    pub fn abort(self) -> raw::metask_agentcore_session_abort_fn_v1 {
        self.table().abort
    }
    /// Revision 20: queue more user text for the active Run.
    pub fn submit_input(self) -> raw::metask_agentcore_session_submit_input_fn_v1 {
        self.table().submit_input
    }
    /// Revision 25: replace the Session's provider credential in place, also
    /// while a Run is active and from that Run's own callbacks.
    pub fn update_credential(self) -> raw::metask_agentcore_session_update_credential_fn_v1 {
        self.table().update_credential
    }
}

#[derive(Clone, Copy)]
pub struct SessionControlApi {
    raw: NonNull<raw::metask_agentcore_session_control_api_v1>,
}

impl SessionControlApi {
    fn table(self) -> &'static raw::metask_agentcore_session_control_api_v1 {
        unsafe { self.raw.as_ref() }
    }

    pub fn restore(self) -> raw::metask_agentcore_session_restore_fn_v1 {
        self.table().restore
    }
    pub fn describe(self) -> raw::metask_agentcore_session_describe_fn_v1 {
        self.table().describe
    }
    pub fn set_model(self) -> raw::metask_agentcore_session_set_model_fn_v1 {
        self.table().set_model
    }
    pub fn update_permission_rules(
        self,
    ) -> raw::metask_agentcore_session_update_permission_rules_fn_v1 {
        self.table().update_permission_rules
    }
    pub fn compact(self) -> raw::metask_agentcore_session_compact_fn_v1 {
        self.table().compact
    }
    pub fn abort_compact(self) -> raw::metask_agentcore_session_abort_compact_fn_v1 {
        self.table().abort_compact
    }
    pub fn export_checkpoint(self) -> raw::metask_agentcore_session_export_checkpoint_fn_v1 {
        self.table().export_checkpoint
    }
    /// Replaces the Session's prompt profile while idle; null clears it.
    pub fn set_prompt_profile(self) -> raw::metask_agentcore_session_set_prompt_profile_fn_v1 {
        self.table().set_prompt_profile
    }
    /// Replaces the Session's permission mode while idle; a change revokes
    /// every Session grant.
    pub fn update_permission_mode(
        self,
    ) -> raw::metask_agentcore_session_update_permission_mode_fn_v1 {
        self.table().update_permission_mode
    }
    /// Revision 27 (#441): drops the user message at a 1-based position and
    /// everything after it while idle, so the next Run reruns from there.
    pub fn rewind_to_user_message(
        self,
    ) -> raw::metask_agentcore_session_rewind_to_user_message_fn_v1 {
        self.table().rewind_to_user_message
    }
}

#[derive(Clone, Copy)]
pub struct SkillApi {
    raw: NonNull<raw::metask_agentcore_skill_api_v1>,
}

impl SkillApi {
    fn table(self) -> &'static raw::metask_agentcore_skill_api_v1 {
        unsafe { self.raw.as_ref() }
    }

    pub fn resolve_catalog(self) -> raw::metask_agentcore_runtime_query_skill_catalog_fn_v1 {
        self.table().resolve_catalog
    }
    pub fn release_catalog(self) -> raw::metask_agentcore_skill_catalog_release_fn_v1 {
        self.table().release_catalog
    }
    pub fn bind_policy(self) -> raw::metask_agentcore_session_bind_skills_fn_v1 {
        self.table().bind_policy
    }
}

#[derive(Clone, Copy)]
pub struct McpApi {
    raw: NonNull<raw::metask_agentcore_mcp_api_v1>,
}

impl McpApi {
    fn table(self) -> &'static raw::metask_agentcore_mcp_api_v1 {
        unsafe { self.raw.as_ref() }
    }

    pub fn apply_configuration(
        self,
    ) -> raw::metask_agentcore_runtime_apply_mcp_configuration_fn_v1 {
        self.table().apply_configuration
    }
    pub fn refresh(self) -> raw::metask_agentcore_runtime_refresh_mcp_fn_v1 {
        self.table().refresh
    }
    pub fn describe(self) -> raw::metask_agentcore_runtime_describe_mcp_fn_v1 {
        self.table().describe
    }
    pub fn update_selection(self) -> raw::metask_agentcore_session_update_mcp_fn_v1 {
        self.table().update_selection
    }
}

#[derive(Clone, Copy)]
pub struct GoalApi {
    raw: NonNull<raw::metask_agentcore_goal_api_v1>,
}

impl GoalApi {
    fn table(self) -> &'static raw::metask_agentcore_goal_api_v1 {
        unsafe { self.raw.as_ref() }
    }

    pub fn get(self) -> raw::metask_agentcore_goal_get_fn_v1 {
        self.table().get
    }
    pub fn set(self) -> raw::metask_agentcore_goal_set_fn_v1 {
        self.table().set
    }
    pub fn update(self) -> raw::metask_agentcore_goal_update_fn_v1 {
        self.table().update
    }
    pub fn clear(self) -> raw::metask_agentcore_goal_clear_fn_v1 {
        self.table().clear
    }
}

unsafe fn validate_goal_api(ptr: *const raw::metask_agentcore_goal_api_v1) -> bool {
    if ptr.is_null()
        || (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_goal_api_v1>() != 0
    {
        return false;
    }
    let table = unsafe { &*ptr };
    table.struct_size as usize == size_of::<raw::metask_agentcore_goal_api_v1>()
        && table.reserved0 == 0
        && table.get.is_some()
        && table.set.is_some()
        && table.update.is_some()
        && table.clear.is_some()
}

#[derive(Clone, Copy)]
pub struct TeamApi {
    raw: NonNull<raw::metask_agentcore_team_api_v1>,
}

impl TeamApi {
    fn table(self) -> &'static raw::metask_agentcore_team_api_v1 {
        unsafe { self.raw.as_ref() }
    }

    pub fn describe(self) -> raw::metask_agentcore_team_describe_fn_v1 {
        self.table().describe
    }
    pub fn poll(self) -> raw::metask_agentcore_team_poll_fn_v1 {
        self.table().poll
    }
}

unsafe fn validate_team_api(ptr: *const raw::metask_agentcore_team_api_v1) -> bool {
    if ptr.is_null()
        || (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_team_api_v1>() != 0
    {
        return false;
    }
    let table = unsafe { &*ptr };
    table.struct_size as usize == size_of::<raw::metask_agentcore_team_api_v1>()
        && table.reserved0 == 0
        && table.describe.is_some()
        && table.poll.is_some()
}

unsafe fn validate_runtime_api(ptr: *const raw::metask_agentcore_runtime_api_v1) -> bool {
    if ptr.is_null()
        || (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_runtime_api_v1>() != 0
    {
        return false;
    }
    let table = unsafe { &*ptr };
    table.struct_size as usize == size_of::<raw::metask_agentcore_runtime_api_v1>()
        && table.reserved0 == 0
        && table.create.is_some()
        && table.destroy.is_some()
}

unsafe fn validate_session_api(ptr: *const raw::metask_agentcore_session_api_v1) -> bool {
    if ptr.is_null()
        || (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_session_api_v1>() != 0
    {
        return false;
    }
    let table = unsafe { &*ptr };
    table.struct_size as usize == size_of::<raw::metask_agentcore_session_api_v1>()
        && table.reserved0 == 0
        && table.create.is_some()
        && table.destroy.is_some()
        && table.run_input.is_some()
        && table.abort.is_some()
        && table.submit_input.is_some()
        && table.update_credential.is_some()
}

unsafe fn validate_session_control_api(
    ptr: *const raw::metask_agentcore_session_control_api_v1,
) -> bool {
    if ptr.is_null()
        || (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_session_control_api_v1>()
            != 0
    {
        return false;
    }
    let table = unsafe { &*ptr };
    table.struct_size as usize == size_of::<raw::metask_agentcore_session_control_api_v1>()
        && table.reserved0 == 0
        && table.restore.is_some()
        && table.describe.is_some()
        && table.set_model.is_some()
        && table.update_permission_rules.is_some()
        && table.compact.is_some()
        && table.abort_compact.is_some()
        && table.export_checkpoint.is_some()
        && table.set_prompt_profile.is_some()
        && table.update_permission_mode.is_some()
        && table.rewind_to_user_message.is_some()
}

unsafe fn validate_skill_api(ptr: *const raw::metask_agentcore_skill_api_v1) -> bool {
    if ptr.is_null()
        || (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_skill_api_v1>() != 0
    {
        return false;
    }
    let table = unsafe { &*ptr };
    table.struct_size as usize == size_of::<raw::metask_agentcore_skill_api_v1>()
        && table.reserved0 == 0
        && table.resolve_catalog.is_some()
        && table.release_catalog.is_some()
        && table.bind_policy.is_some()
}

unsafe fn validate_mcp_api(ptr: *const raw::metask_agentcore_mcp_api_v1) -> bool {
    if ptr.is_null()
        || (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_mcp_api_v1>() != 0
    {
        return false;
    }
    let table = unsafe { &*ptr };
    table.struct_size as usize == size_of::<raw::metask_agentcore_mcp_api_v1>()
        && table.reserved0 == 0
        && table.apply_configuration.is_some()
        && table.refresh.is_some()
        && table.describe.is_some()
        && table.update_selection.is_some()
}

/// Library-owned output buffer. Use this only for diagnostics, catalog/session
/// descriptions, and restore reports returned by AgentCore. Host-owned MCP,
/// Tool, and UI callback buffers must use their paired Host release callback.
pub struct OwnedBuffer {
    api: Api,
    raw: raw::metask_agentcore_owned_bytes_v1,
}

impl OwnedBuffer {
    pub fn new(api: Api) -> Self {
        Self {
            api,
            raw: raw::metask_agentcore_owned_bytes_v1 {
                ptr: ptr::null_mut(),
                len: 0,
            },
        }
    }

    /// Pass this pointer only to an AgentCore output parameter. Release or
    /// clear the previous value before reusing it for another call.
    pub fn as_mut_ptr(&mut self) -> *mut raw::metask_agentcore_owned_bytes_v1 {
        &mut self.raw
    }

    pub fn as_raw(&self) -> &raw::metask_agentcore_owned_bytes_v1 {
        &self.raw
    }

    pub fn as_bytes(&self) -> Result<&[u8], AbiError> {
        owned_bytes_slice(&self.raw)
    }

    pub fn release(&mut self) {
        unsafe { (self.api.table().buffer_release.unwrap())(&mut self.raw) };
    }

    pub fn into_raw(self) -> raw::metask_agentcore_owned_bytes_v1 {
        let this = ManuallyDrop::new(self);
        this.raw
    }

    /// `raw` must be a canonical library-owned output produced by this exact
    /// `api`. It must not be a Host callback buffer.
    pub unsafe fn from_raw(api: Api, raw: raw::metask_agentcore_owned_bytes_v1) -> Self {
        Self { api, raw }
    }
}

impl Drop for OwnedBuffer {
    fn drop(&mut self) {
        self.release();
    }
}

/// Unique Runtime ownership guard. The caller must create it from a successful
/// `RuntimeApi::create` output and must not retain another owner of the handle.
pub struct Runtime {
    api: Api,
    raw: NonNull<raw::metask_agentcore_runtime>,
}

impl Runtime {
    pub unsafe fn from_owned_raw(
        api: Api,
        raw: *mut raw::metask_agentcore_runtime,
    ) -> Result<Self, AbiError> {
        Ok(Self {
            api,
            raw: NonNull::new(raw).ok_or(AbiError::UnsupportedAbi)?,
        })
    }

    pub fn as_raw(&self) -> *mut raw::metask_agentcore_runtime {
        self.raw.as_ptr()
    }

    pub fn into_raw(self) -> *mut raw::metask_agentcore_runtime {
        let this = ManuallyDrop::new(self);
        this.raw.as_ptr()
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        let mut diagnostic = self.api.owned_buffer();
        unsafe {
            (self.api.runtime().destroy().unwrap())(self.raw.as_ptr(), diagnostic.as_mut_ptr());
        }
    }
}

/// Unique Session ownership guard. Its lifetime prevents the wrapped Runtime
/// from being dropped first. The Host must still obey the ABI rule that all
/// Run/compact/abort calls are quiescent before this guard is dropped.
pub struct Session<'runtime> {
    api: Api,
    raw: NonNull<raw::metask_agentcore_session>,
    _runtime: PhantomData<&'runtime Runtime>,
}

impl<'runtime> Session<'runtime> {
    pub unsafe fn from_owned_raw(
        runtime: &'runtime Runtime,
        raw: *mut raw::metask_agentcore_session,
    ) -> Result<Self, AbiError> {
        Ok(Self {
            api: runtime.api,
            raw: NonNull::new(raw).ok_or(AbiError::UnsupportedAbi)?,
            _runtime: PhantomData,
        })
    }

    pub fn as_raw(&self) -> *mut raw::metask_agentcore_session {
        self.raw.as_ptr()
    }

    pub fn into_raw(self) -> *mut raw::metask_agentcore_session {
        let this = ManuallyDrop::new(self);
        this.raw.as_ptr()
    }
}

impl Drop for Session<'_> {
    fn drop(&mut self) {
        let mut diagnostic = self.api.owned_buffer();
        unsafe {
            (self.api.session().destroy().unwrap())(self.raw.as_ptr(), diagnostic.as_mut_ptr());
        }
    }
}

pub fn bytes_view(bytes: &[u8]) -> raw::metask_agentcore_bytes_view_v1 {
    raw::metask_agentcore_bytes_view_v1 {
        ptr: if bytes.is_empty() {
            ptr::null()
        } else {
            bytes.as_ptr()
        },
        len: bytes.len() as u64,
    }
}

/// The returned lifetime must not outlive the synchronous callback or
/// AgentCore call that owns `view`.
pub unsafe fn borrowed_bytes<'a>(
    view: raw::metask_agentcore_bytes_view_v1,
) -> Result<&'a [u8], AbiError> {
    if view.len == 0 {
        return if view.ptr.is_null() {
            Ok(&[])
        } else {
            Err(AbiError::InvalidOwnedBytes)
        };
    }
    let len = usize::try_from(view.len).map_err(|_| AbiError::LengthOverflow)?;
    if view.ptr.is_null() {
        return Err(AbiError::InvalidOwnedBytes);
    }
    Ok(unsafe { slice::from_raw_parts(view.ptr, len) })
}

fn owned_bytes_slice(value: &raw::metask_agentcore_owned_bytes_v1) -> Result<&[u8], AbiError> {
    if value.len == 0 {
        return if value.ptr.is_null() {
            Ok(&[])
        } else {
            Err(AbiError::InvalidOwnedBytes)
        };
    }
    let len = usize::try_from(value.len).map_err(|_| AbiError::LengthOverflow)?;
    if value.ptr.is_null() {
        return Err(AbiError::InvalidOwnedBytes);
    }
    Ok(unsafe { slice::from_raw_parts(value.ptr, len) })
}

/// Converts Rust-owned callback bytes into the exact Host ownership token.
/// The paired release callback must call `release_host_bytes` exactly once.
pub fn host_bytes_from_vec(bytes: Vec<u8>) -> raw::metask_agentcore_owned_bytes_v1 {
    let boxed = bytes.into_boxed_slice();
    if boxed.is_empty() {
        return raw::metask_agentcore_owned_bytes_v1 {
            ptr: ptr::null_mut(),
            len: 0,
        };
    }
    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut u8;
    raw::metask_agentcore_owned_bytes_v1 {
        ptr,
        len: len as u64,
    }
}

/// `value` must be canonical and must have been produced by
/// `host_bytes_from_vec` in the same Rust allocator domain.
pub unsafe fn release_host_bytes(
    value: *mut raw::metask_agentcore_owned_bytes_v1,
) -> Result<(), AbiError> {
    let value = unsafe { value.as_mut() }.ok_or(AbiError::InvalidOwnedBytes)?;
    if value.len == 0 {
        if !value.ptr.is_null() {
            return Err(AbiError::InvalidOwnedBytes);
        }
        return Ok(());
    }
    let len = usize::try_from(value.len).map_err(|_| AbiError::LengthOverflow)?;
    if value.ptr.is_null() {
        return Err(AbiError::InvalidOwnedBytes);
    }
    let ptr = value.ptr;
    value.ptr = ptr::null_mut();
    value.len = 0;
    let slice = ptr::slice_from_raw_parts_mut(ptr, len);
    drop(unsafe { Box::from_raw(slice) });
    Ok(())
}

impl raw::metask_agentcore_session_callbacks_v1 {
    pub fn empty() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            reserved0: 0,
            ctx: ptr::null_mut::<c_void>(),
            on_event: None,
            on_ui_request: None,
            release_response: None,
            reserved: [0; 4],
        }
    }
}

impl raw::metask_agentcore_mcp_connector_v1 {
    pub fn empty() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            reserved0: 0,
            ctx: ptr::null_mut::<c_void>(),
            open: None,
            request: None,
            request_tool_stream: None,
            notify: None,
            close: None,
            release_response: None,
            retain_connector: None,
            release_connector: None,
            reserved: [0; 1],
        }
    }
}

impl raw::metask_agentcore_checkpoint_sink_v1 {
    pub fn empty() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            reserved0: 0,
            ctx: ptr::null_mut::<c_void>(),
            write: None,
            reserved: [0; 4],
        }
    }
}

impl raw::metask_agentcore_checkpoint_source_v1 {
    pub fn empty() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            reserved0: 0,
            ctx: ptr::null_mut::<c_void>(),
            read: None,
            reserved: [0; 4],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn revision_fifteen_layout_codes_and_host_buffer_helpers_are_exact() {
        assert_eq!(raw::METASK_AGENTCORE_ABI_REVISION, 27);
        assert_eq!(raw::METASK_AGENTCORE_MAX_CREDENTIAL_BYTES_V1, 16_384);
        assert_eq!(raw::METASK_AGENTCORE_MAX_SUBMITTED_INPUTS_V1, 64);
        assert_eq!(raw::METASK_AGENTCORE_MAX_SUBMITTED_INPUT_BYTES_V1, 16_777_216);
        assert_eq!(size_of::<raw::metask_agentcore_submitted_input_v1>(), 48);
        assert_eq!(size_of::<raw::metask_agentcore_input_receipt_v1>(), 24);
        assert_eq!(size_of::<raw::metask_agentcore_run_result_v1>(), 72);
        assert_eq!(raw::METASK_AGENTCORE_PROMPT_OP_ADD, 1);
        assert_eq!(raw::METASK_AGENTCORE_PROMPT_OP_REPLACE, 2);
        assert_eq!(raw::METASK_AGENTCORE_PROMPT_OP_REMOVE, 3);
        assert_eq!(raw::METASK_AGENTCORE_MAX_PROMPT_PROFILE_SECTIONS_V1, 64);
        assert_eq!(raw::METASK_AGENTCORE_MAX_CONTEXT_BLOCKS_V1, 32);
        assert_eq!(size_of::<raw::metask_agentcore_prompt_section_v1>(), 72);
        assert_eq!(size_of::<raw::metask_agentcore_prompt_profile_v1>(), 56);
        assert_eq!(size_of::<raw::metask_agentcore_context_block_v1>(), 56);
        assert_eq!(size_of::<raw::metask_agentcore_run_options_v1>(), 40);
        assert_eq!(
            size_of::<raw::metask_agentcore_session_create_config_v1>(),
            64
        );
        assert_eq!(raw::METASK_AGENTCORE_STATUS_SKILL_CATALOG_INCOMPLETE, 27);
        assert_eq!(raw::METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED, 28);
        assert_eq!(raw::METASK_AGENTCORE_STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN, 29);
        assert_eq!(raw::METASK_AGENTCORE_STATUS_MESSAGE_POSITION_OUT_OF_RANGE, 31);
        assert_eq!(raw::METASK_AGENTCORE_STATUS_NOT_USER_MESSAGE, 32);
        assert_eq!(raw::METASK_AGENTCORE_STATUS_MESSAGE_POSITION_COMPACTED, 33);
        assert_eq!(raw::METASK_AGENTCORE_CAPABILITY_SUPPORTED, 1);
        assert_eq!(raw::METASK_AGENTCORE_CAPABILITY_UNSUPPORTED, 2);
        assert_eq!(raw::METASK_AGENTCORE_MAX_MODEL_CAPABILITIES_V1, 256);
        assert_eq!(raw::METASK_AGENTCORE_MAX_MODEL_CAPABILITY_MODEL_BYTES_V1, 256);
        assert_eq!(size_of::<raw::metask_agentcore_model_capability_v1>(), 40);
        assert_eq!(
            size_of::<raw::metask_agentcore_session_host_config_v1>(),
            168
        );
        assert_eq!(raw::METASK_AGENTCORE_RUN_INPUT_MULTIMODAL, 3);
        assert_eq!(raw::METASK_AGENTCORE_RUN_INPUT_PART_TEXT, 1);
        assert_eq!(raw::METASK_AGENTCORE_RUN_INPUT_PART_IMAGE, 2);
        assert_eq!(raw::METASK_AGENTCORE_MAX_RUN_INPUT_PARTS_V1, 64);
        assert_eq!(
            raw::METASK_AGENTCORE_MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1,
            5_000_000
        );
        assert_eq!(size_of::<raw::metask_agentcore_run_input_part_v1>(), 72);
        assert_eq!(size_of::<raw::metask_agentcore_run_input_v1>(), 104);
        assert_eq!(raw::METASK_AGENTCORE_RUN_JOURNAL_EPHEMERAL, 0);
        assert_eq!(raw::METASK_AGENTCORE_RUN_JOURNAL_DURABLE_WORKSPACE, 1);
        assert_eq!(raw::METASK_AGENTCORE_MCP_NEGOTIATION_AUTO, 1);
        assert_eq!(raw::METASK_AGENTCORE_MCP_NEGOTIATION_MODERN_ONLY, 2);
        assert_eq!(raw::METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_ONLY, 3);
        assert_eq!(raw::METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_2025_06_ONLY, 4);
        assert_eq!(raw::METASK_AGENTCORE_MCP_ERA_2026_07_28, 1);
        assert_eq!(raw::METASK_AGENTCORE_MCP_ERA_2025_11_25, 2);
        assert_eq!(raw::METASK_AGENTCORE_MCP_ERA_2025_06_18, 3);
        assert_eq!(raw::METASK_AGENTCORE_MCP_APPLY_APPLIED, 1);
        assert_eq!(raw::METASK_AGENTCORE_MCP_APPLY_SUPERSEDED, 2);
        assert_eq!(raw::METASK_AGENTCORE_MCP_APPLY_REJECTED, 3);
        assert_eq!(size_of::<raw::metask_agentcore_runtime_api_v1>(), 24);
        assert_eq!(size_of::<raw::metask_agentcore_session_api_v1>(), 56);
        assert_eq!(
            size_of::<raw::metask_agentcore_session_control_api_v1>(),
            88
        );
        assert_eq!(size_of::<raw::metask_agentcore_skill_api_v1>(), 32);
        assert_eq!(size_of::<raw::metask_agentcore_mcp_api_v1>(), 40);
        assert_eq!(size_of::<raw::metask_agentcore_goal_api_v1>(), 40);
        assert_eq!(size_of::<raw::metask_agentcore_goal_set_v1>(), 56);
        assert_eq!(size_of::<raw::metask_agentcore_goal_update_v1>(), 64);
        assert_eq!(size_of::<raw::metask_agentcore_team_api_v1>(), 24);
        assert_eq!(size_of::<raw::metask_agentcore_team_config_v1>(), 88);
        assert_eq!(raw::METASK_AGENTCORE_TEAM_ROLE_LEAD, 1);
        assert_eq!(raw::METASK_AGENTCORE_TEAM_ROLE_MEMBER, 2);
        assert_eq!(raw::METASK_AGENTCORE_MAX_TEAM_NAME_BYTES_V1, 64);
        assert_eq!(raw::METASK_AGENTCORE_MAX_TEAM_MEMBER_BYTES_V1, 64);
        assert_eq!(size_of::<raw::metask_agentcore_api_v1>(), 80);
        assert_eq!(
            size_of::<raw::metask_agentcore_process_plugin_source_v1>(),
            48
        );
        assert_eq!(
            size_of::<raw::metask_agentcore_runtime_plugin_config_v1>(),
            72
        );
        assert_eq!(size_of::<raw::metask_agentcore_host_result_sink_v1>(), 56);
        assert_eq!(size_of::<raw::metask_agentcore_host_stream_tool_v1>(), 96);
        assert_eq!(size_of::<raw::metask_agentcore_mcp_configuration_v1>(), 64);
        assert_eq!(size_of::<raw::metask_agentcore_mcp_apply_report_v1>(), 64);
        assert_eq!(
            size_of::<raw::metask_agentcore_session_host_config_v1>(),
            168
        );
        assert_eq!(
            size_of::<raw::metask_agentcore_checkpoint_export_result_v1>(),
            96
        );

        let mut raw = host_bytes_from_vec(b"owned".to_vec());
        assert_eq!(
            unsafe { borrowed_bytes(bytes_view(b"borrowed")) }.unwrap(),
            b"borrowed"
        );
        assert_eq!(owned_bytes_slice(&raw).unwrap(), b"owned");
        unsafe { release_host_bytes(&mut raw) }.unwrap();
        assert!(raw.ptr.is_null());
        assert_eq!(raw.len, 0);
    }
}
