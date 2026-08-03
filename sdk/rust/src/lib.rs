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

/// Validated Revision 6 function table. Discovery rejects every earlier
/// revision; there is no legacy probe or alternate layout.
#[derive(Clone, Copy)]
pub struct Api {
    raw: NonNull<raw::metask_agentcore_api_v1>,
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
        if (ptr as usize) % std::mem::align_of::<raw::metask_agentcore_api_v1>() != 0 {
            return Err(AbiError::UnsupportedAbi);
        }
        let raw = NonNull::new(ptr.cast_mut()).ok_or(AbiError::UnsupportedAbi)?;
        let table = unsafe { raw.as_ref() };
        if table.struct_size as usize != size_of::<raw::metask_agentcore_api_v1>()
            || table.abi_version != raw::METASK_AGENTCORE_ABI_V1
            || table.abi_revision != raw::METASK_AGENTCORE_ABI_REVISION
            || table.reserved0 != 0
            || table.capabilities != raw::METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1 as u64
            || table.reserved.iter().any(|value| *value != 0)
            || table.runtime_create.is_none()
            || table.runtime_destroy.is_none()
            || table.runtime_query_skill_catalog.is_none()
            || table.skill_catalog_release.is_none()
            || table.runtime_refresh_mcp.is_none()
            || table.runtime_describe_mcp.is_none()
            || table.session_create.is_none()
            || table.session_restore.is_none()
            || table.session_destroy.is_none()
            || table.session_describe.is_none()
            || table.session_set_model.is_none()
            || table.session_update_skills.is_none()
            || table.session_update_permission_rules.is_none()
            || table.session_update_mcp.is_none()
            || table.session_run_input.is_none()
            || table.session_abort.is_none()
            || table.session_compact.is_none()
            || table.session_abort_compact.is_none()
            || table.session_export_checkpoint.is_none()
            || table.buffer_release.is_none()
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
/// `runtime_create` output and must not retain another owner of the handle.
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
            (self.api.table().runtime_destroy.unwrap())(self.raw.as_ptr(), diagnostic.as_mut_ptr());
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
            (self.api.table().session_destroy.unwrap())(self.raw.as_ptr(), diagnostic.as_mut_ptr());
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
            notify: None,
            close: None,
            release_response: None,
            reserved: [0; 3],
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
    fn revision_six_layout_and_host_buffer_helpers_are_exact() {
        assert_eq!(raw::METASK_AGENTCORE_ABI_REVISION, 6);
        assert_eq!(size_of::<raw::metask_agentcore_api_v1>(), 216);
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
