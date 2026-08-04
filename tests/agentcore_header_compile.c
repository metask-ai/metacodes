#include <metask/agentcore.h>

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

const metask_agentcore_api_v1 *agentcore_header_compile_probe(void) {
    return metask_agentcore_api_v1_discover();
}

void agentcore_revision_six_type_probe(void) {
    metask_agentcore_runtime_config_v1 runtime = {0};
    metask_agentcore_session_host_config_v1 host = {0};
    metask_agentcore_session_create_config_v1 create = {0};
    metask_agentcore_session_restore_config_v1 restore = {0};
    metask_agentcore_mcp_server_v1 server = {0};
    metask_agentcore_checkpoint_export_config_v1 checkpoint = {0};
    metask_agentcore_checkpoint_export_result_v1 checkpoint_result = {0};
    metask_agentcore_owned_bytes_v1 diagnostic =
        metask_agentcore_owned_bytes_v1_empty();

    runtime.struct_size = (uint32_t)sizeof(runtime);
    host.struct_size = (uint32_t)sizeof(host);
    create.struct_size = (uint32_t)sizeof(create);
    create.host = &host;
    restore.struct_size = (uint32_t)sizeof(restore);
    restore.host = &host;
    server.struct_size = (uint32_t)sizeof(server);
    server.namespace_ = metask_agentcore_bytes_view_v1_from("probe", 5);
    checkpoint.struct_size = (uint32_t)sizeof(checkpoint);
    checkpoint_result.struct_size = (uint32_t)sizeof(checkpoint_result);

    (void)runtime;
    (void)create;
    (void)restore;
    (void)server;
    (void)checkpoint;
    (void)checkpoint_result;
    metask_agentcore_owned_bytes_v1_release((const metask_agentcore_api_v1 *)0,
                                            &diagnostic);
}
