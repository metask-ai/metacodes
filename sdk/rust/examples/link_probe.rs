fn main() {
    let api = unsafe {
        metask_agentcore_sys::metask_agentcore_get_api(
            metask_agentcore_sys::METASK_AGENTCORE_ABI_V1,
        )
    };
    assert!(!api.is_null(), "AgentCore ABI v1 discovery failed");
    let api = unsafe { &*(api as *const metask_agentcore_sys::metask_agentcore_api_v1) };
    assert_eq!(
        api.struct_size as usize,
        std::mem::size_of::<metask_agentcore_sys::metask_agentcore_api_v1>()
    );
    assert_eq!(
        api.abi_version,
        metask_agentcore_sys::METASK_AGENTCORE_ABI_V1
    );
    assert_eq!(
        api.abi_revision,
        metask_agentcore_sys::METASK_AGENTCORE_ABI_REVISION
    );
    assert_eq!(api.reserved0, 0);
    assert_eq!(
        api.capabilities,
        metask_agentcore_sys::METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1 as u64
    );
    assert!(api.reserved.iter().all(|value| *value == 0));
    assert!(api.session_set_model.is_some());
    assert!(api.session_update_skills.is_some());
    assert!(api.session_update_permission_rules.is_some());
    assert!(api.session_compact.is_some());
    assert!(api.session_abort_compact.is_some());
}
