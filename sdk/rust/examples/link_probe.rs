fn main() {
    let api =
        metask_agentcore_sys::Api::discover().expect("AgentCore Revision 6 exact discovery failed");
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
    let mut revision_5 = unsafe { *api.as_raw() };
    revision_5.abi_revision = 5;
    assert!(matches!(
        unsafe { metask_agentcore_sys::Api::from_raw(&revision_5) },
        Err(metask_agentcore_sys::AbiError::UnsupportedAbi)
    ));
}
