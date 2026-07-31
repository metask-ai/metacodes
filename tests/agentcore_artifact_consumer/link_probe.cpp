#include <metask/agentcore.h>

int main() {
    const auto *api = static_cast<const metask_agentcore_api_v1 *>(
        metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1));
    if (api == nullptr || api->struct_size != sizeof(*api) ||
        api->abi_version != METASK_AGENTCORE_ABI_V1) {
        return 1;
    }
    if (api->abi_revision != METASK_AGENTCORE_ABI_REVISION || api->reserved0 != 0 ||
        api->capabilities != METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1 ||
        api->session_set_model == nullptr || api->session_update_skills == nullptr ||
        api->session_update_permission_rules == nullptr ||
        api->session_compact == nullptr || api->session_abort_compact == nullptr) {
        return 1;
    }
    return 0;
}
