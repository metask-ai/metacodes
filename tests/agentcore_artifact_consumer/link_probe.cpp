#include <metask/agentcore.h>

int main() {
    const auto *api = metask_agentcore_api_v1_discover();
    if (api == nullptr || metask_agentcore_get_api(0) != nullptr ||
        metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1 + 1) != nullptr) {
        return 1;
    }
    auto prior_revision = *api;
    prior_revision.abi_revision = METASK_AGENTCORE_ABI_REVISION - 1u;
    return metask_agentcore_api_v1_is_compatible(&prior_revision) ? 1 : 0;
}
