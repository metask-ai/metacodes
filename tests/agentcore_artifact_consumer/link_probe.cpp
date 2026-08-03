#include <metask/agentcore.h>

int main() {
    const auto *api = metask_agentcore_api_v1_discover();
    if (api == nullptr || metask_agentcore_get_api(0) != nullptr ||
        metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1 + 1) != nullptr) {
        return 1;
    }
    auto revision_5 = *api;
    revision_5.abi_revision = 5;
    return metask_agentcore_api_v1_is_compatible(&revision_5) ? 1 : 0;
}
