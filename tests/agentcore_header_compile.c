#include <metask/agentcore.h>

_Static_assert(METASK_AGENTCORE_ABI_REVISION == 19,
               "AgentCore revision changed");
_Static_assert(sizeof(metask_agentcore_api_v1) == 64,
               "AgentCore root layout changed");
_Static_assert(sizeof(metask_agentcore_runtime_api_v1) == 24,
               "Runtime table layout changed");
_Static_assert(sizeof(metask_agentcore_session_api_v1) == 40,
               "Session table layout changed");
_Static_assert(sizeof(metask_agentcore_session_control_api_v1) == 80,
               "Session Control table layout changed");
_Static_assert(sizeof(metask_agentcore_skill_api_v1) == 32,
               "Skill table layout changed");
_Static_assert(sizeof(metask_agentcore_mcp_api_v1) == 40,
               "MCP table layout changed");

_Static_assert(METASK_AGENTCORE_MAX_SKILL_FILE_CONTENT_BYTES_V1 == 16777216ULL,
               "Skill file limit changed");
_Static_assert(METASK_AGENTCORE_MAX_SKILL_CONTENT_BYTES_V1 == 33554432ULL,
               "Skill content limit changed");
_Static_assert(METASK_AGENTCORE_MAX_SKILL_FILES_V1 == 1024ULL,
               "Skill file-count limit changed");
_Static_assert(METASK_AGENTCORE_MAX_SKILL_ENTRIES_V1 == 4096ULL,
               "Skill entry-count limit changed");
_Static_assert(METASK_AGENTCORE_MAX_SKILL_CATALOG_CONTENT_BYTES_V1 == 67108864ULL,
               "catalog content limit changed");
_Static_assert(METASK_AGENTCORE_MAX_SKILL_RUNTIME_RETAINED_SNAPSHOT_BYTES_V1 == 268435456ULL,
               "Runtime retained-snapshot limit changed");
_Static_assert(METASK_AGENTCORE_PROTOCOL_DEFAULT == 0u,
               "provider protocol default changed");
_Static_assert(METASK_AGENTCORE_OPENAI_PROTOCOL_RESPONSES == 1u,
               "OpenAI Responses protocol code changed");
_Static_assert(sizeof(metask_agentcore_run_input_part_v1) == 72,
               "multimodal part layout changed");
_Static_assert(METASK_AGENTCORE_RUN_INPUT_MULTIMODAL == 3u &&
                   METASK_AGENTCORE_RUN_INPUT_PART_TEXT == 1u &&
                   METASK_AGENTCORE_RUN_INPUT_PART_IMAGE == 2u,
               "multimodal run input codes changed");
_Static_assert(METASK_AGENTCORE_MAX_RUN_INPUT_PARTS_V1 == 64ULL,
               "multimodal part-count limit changed");
_Static_assert(METASK_AGENTCORE_MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1 == 5000000ULL,
               "image part payload limit changed");
_Static_assert(METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED == 28u,
               "image capability status changed");
_Static_assert(sizeof(metask_agentcore_prompt_section_v1) == 72 &&
                   sizeof(metask_agentcore_prompt_profile_v1) == 56 &&
                   sizeof(metask_agentcore_context_block_v1) == 56,
               "prompt profile and context block layouts changed");
_Static_assert(METASK_AGENTCORE_PROMPT_OP_ADD == 1u &&
                   METASK_AGENTCORE_PROMPT_OP_REPLACE == 2u &&
                   METASK_AGENTCORE_PROMPT_OP_REMOVE == 3u,
               "prompt profile op codes changed");
_Static_assert(METASK_AGENTCORE_MAX_PROMPT_PROFILE_SECTIONS_V1 == 64ULL &&
                   METASK_AGENTCORE_MAX_PROMPT_SECTION_TEXT_BYTES_V1 == 65536ULL &&
                   METASK_AGENTCORE_MAX_PROMPT_PROFILE_TEXT_BYTES_V1 == 262144ULL &&
                   METASK_AGENTCORE_MAX_CONTEXT_BLOCKS_V1 == 32ULL &&
                   METASK_AGENTCORE_MAX_CONTEXT_BLOCK_LABEL_BYTES_V1 == 64ULL &&
                   METASK_AGENTCORE_MAX_CONTEXT_BLOCK_TEXT_BYTES_V1 == 65536ULL &&
                   METASK_AGENTCORE_MAX_CONTEXT_BLOCKS_TOTAL_BYTES_V1 == 262144ULL,
               "prompt profile and context block limits changed");

const metask_agentcore_api_v1 *agentcore_header_compile_probe(void) {
    return metask_agentcore_api_v1_discover();
}

void agentcore_revision_fifteen_type_probe(void) {
    metask_agentcore_runtime_config_v1 runtime = {0};
    metask_agentcore_session_host_config_v1 host = {0};
    metask_agentcore_session_create_config_v1 create = {0};
    metask_agentcore_session_restore_config_v1 restore = {0};
    metask_agentcore_mcp_server_v1 server = {0};
    metask_agentcore_mcp_configuration_v1 mcp_configuration = {0};
    metask_agentcore_mcp_apply_report_v1 mcp_report = {0};
    metask_agentcore_run_input_part_v1 part = {0};
    metask_agentcore_run_input_v1 run_input = {0};
    metask_agentcore_checkpoint_export_config_v1 checkpoint = {0};
    metask_agentcore_checkpoint_export_result_v1 checkpoint_result = {0};
    metask_agentcore_prompt_section_v1 prompt_section = {0};
    metask_agentcore_prompt_profile_v1 prompt_profile = {0};
    metask_agentcore_context_block_v1 context_block = {0};
    metask_agentcore_run_options_v1 run_options = {0};
    metask_agentcore_owned_bytes_v1 diagnostic =
        metask_agentcore_owned_bytes_v1_empty();

    runtime.struct_size = (uint32_t)sizeof(runtime);
    host.struct_size = (uint32_t)sizeof(host);
    host.protocol_kind_code = METASK_AGENTCORE_PROTOCOL_DEFAULT;
    create.struct_size = (uint32_t)sizeof(create);
    create.host = &host;
    restore.struct_size = (uint32_t)sizeof(restore);
    restore.host = &host;
    server.struct_size = (uint32_t)sizeof(server);
    server.namespace_ = metask_agentcore_bytes_view_v1_from("probe", 5);
    mcp_configuration.struct_size = (uint32_t)sizeof(mcp_configuration);
    mcp_report.struct_size = (uint32_t)sizeof(mcp_report);
    part.struct_size = (uint32_t)sizeof(part);
    part.kind_code = METASK_AGENTCORE_RUN_INPUT_PART_IMAGE;
    run_input.struct_size = (uint32_t)sizeof(run_input);
    run_input.kind_code = METASK_AGENTCORE_RUN_INPUT_MULTIMODAL;
    run_input.parts = &part;
    run_input.part_count = 1;
    checkpoint.struct_size = (uint32_t)sizeof(checkpoint);
    checkpoint_result.struct_size = (uint32_t)sizeof(checkpoint_result);
    prompt_section.struct_size = (uint32_t)sizeof(prompt_section);
    prompt_section.op_code = METASK_AGENTCORE_PROMPT_OP_REPLACE;
    prompt_section.id = metask_agentcore_bytes_view_v1_from("metacodes:identity", 18);
    prompt_section.text = metask_agentcore_bytes_view_v1_from("You are a probe.", 16);
    prompt_profile.struct_size = (uint32_t)sizeof(prompt_profile);
    prompt_profile.sections = &prompt_section;
    prompt_profile.section_count = 1;
    create.prompt_profile = &prompt_profile;
    context_block.struct_size = (uint32_t)sizeof(context_block);
    context_block.label = metask_agentcore_bytes_view_v1_from("currentDate", 11);
    context_block.text = metask_agentcore_bytes_view_v1_from("Today.", 6);
    run_options.struct_size = (uint32_t)sizeof(run_options);
    run_options.max_turns = 1;
    run_options.context_blocks = &context_block;
    run_options.context_block_count = 1;

    (void)runtime;
    (void)create;
    (void)restore;
    (void)server;
    (void)mcp_configuration;
    (void)mcp_report;
    (void)run_input;
    (void)checkpoint;
    (void)checkpoint_result;
    (void)run_options;
    metask_agentcore_owned_bytes_v1_release((const metask_agentcore_api_v1 *)0,
                                            &diagnostic);
}

void agentcore_revision_fifteen_call_shape_probe(
    const metask_agentcore_api_v1 *api,
    const metask_agentcore_runtime_config_v1 *runtime_config,
    const metask_agentcore_runtime_plugin_config_v1 *plugins,
    metask_agentcore_runtime **runtime,
    metask_agentcore_owned_bytes_v1 *diagnostic) {
    if (api == 0) return;
    (void)api->runtime->create(runtime_config, plugins, runtime, diagnostic);
    (void)api->runtime->destroy(*runtime, diagnostic);
    (void)api->session->create;
    (void)api->session->destroy;
    (void)api->session->run_input;
    (void)api->session->abort;
    (void)api->session_control->restore;
    (void)api->session_control->describe;
    (void)api->session_control->set_model;
    (void)api->session_control->update_permission_rules;
    (void)api->session_control->compact;
    (void)api->session_control->abort_compact;
    (void)api->session_control->export_checkpoint;
    (void)api->session_control->set_prompt_profile;
    (void)api->skill->resolve_catalog;
    (void)api->skill->release_catalog;
    (void)api->skill->bind_policy;
    (void)api->mcp->apply_configuration;
    (void)api->mcp->refresh;
    (void)api->mcp->describe;
    (void)api->mcp->update_selection;
    (void)api->buffer_release;
}
