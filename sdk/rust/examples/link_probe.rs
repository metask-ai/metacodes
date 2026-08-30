fn main() {
    let api = metask_agentcore_sys::Api::discover()
        .expect("AgentCore Revision 15 exact discovery failed");
    let output = api.owned_buffer();
    assert!(output
        .as_bytes()
        .expect("empty output is canonical")
        .is_empty());
    assert_eq!(
        unsafe { (*api.as_raw()).abi_revision },
        metask_agentcore_sys::METASK_AGENTCORE_ABI_REVISION
    );
    let raw = unsafe { &*api.as_raw() };
    let runtime = unsafe { &*raw.runtime };
    let session = unsafe { &*raw.session };
    let session_control = unsafe { &*raw.session_control };
    let skill = unsafe { &*raw.skill };
    let mcp = unsafe { &*raw.mcp };

    macro_rules! assert_slot {
        ($safe:expr, $raw:expr) => {
            assert_eq!($safe.unwrap() as usize, $raw.unwrap() as usize)
        };
    }

    assert_slot!(api.buffer_release(), raw.buffer_release);
    assert_slot!(api.runtime().create(), runtime.create);
    assert_slot!(api.runtime().destroy(), runtime.destroy);
    assert_slot!(api.session().create(), session.create);
    assert_slot!(api.session().destroy(), session.destroy);
    assert_slot!(api.session().run_input(), session.run_input);
    assert_slot!(api.session().abort(), session.abort);
    assert_slot!(api.session_control().restore(), session_control.restore);
    assert_slot!(api.session_control().describe(), session_control.describe);
    assert_slot!(api.session_control().set_model(), session_control.set_model);
    assert_slot!(
        api.session_control().update_permission_rules(),
        session_control.update_permission_rules
    );
    assert_slot!(api.session_control().compact(), session_control.compact);
    assert_slot!(
        api.session_control().abort_compact(),
        session_control.abort_compact
    );
    assert_slot!(
        api.session_control().export_checkpoint(),
        session_control.export_checkpoint
    );
    assert_slot!(api.skill().resolve_catalog(), skill.resolve_catalog);
    assert_slot!(api.skill().release_catalog(), skill.release_catalog);
    assert_slot!(api.skill().bind_policy(), skill.bind_policy);
    assert_slot!(api.mcp().apply_configuration(), mcp.apply_configuration);
    assert_slot!(api.mcp().refresh(), mcp.refresh);
    assert_slot!(api.mcp().describe(), mcp.describe);
    assert_slot!(api.mcp().update_selection(), mcp.update_selection);
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
