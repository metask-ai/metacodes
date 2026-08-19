fn main() {
    let api =
        metask_agentcore_sys::Api::discover().expect("AgentCore Revision 9 exact discovery failed");
    let output = api.owned_buffer();
    assert!(output
        .as_bytes()
        .expect("empty output is canonical")
        .is_empty());
    assert_eq!(
        unsafe { (*api.as_raw()).abi_revision },
        metask_agentcore_sys::METASK_AGENTCORE_ABI_REVISION
    );
    assert!(unsafe {
        metask_agentcore_sys::metask_agentcore_get_api(
            metask_agentcore_sys::METASK_AGENTCORE_ABI_V1 + 1,
        )
    }
    .is_null());
    let mut prior_revision = unsafe { *api.as_raw() };
    prior_revision.abi_revision = metask_agentcore_sys::METASK_AGENTCORE_ABI_REVISION - 1;
    assert!(matches!(
        unsafe { metask_agentcore_sys::Api::from_raw(&prior_revision) },
        Err(metask_agentcore_sys::AbiError::UnsupportedAbi)
    ));
}
