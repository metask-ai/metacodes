fn main() {
    let api = unsafe {
        metask_agentcore_sys::metask_agentcore_get_api(
            metask_agentcore_sys::METASK_AGENTCORE_ABI_V1,
        )
    };
    assert!(!api.is_null(), "AgentCore ABI v1 discovery failed");
}
