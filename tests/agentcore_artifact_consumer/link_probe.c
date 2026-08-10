#include <metask/agentcore.h>

int main(void) {
    const metask_agentcore_api_v1 *api = metask_agentcore_api_v1_discover();
    if (api == NULL || metask_agentcore_get_api(0) != NULL ||
        metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1 + 1) != NULL) {
        return 1;
    }
    metask_agentcore_api_v1 prior_revision = *api;
    prior_revision.abi_revision = METASK_AGENTCORE_ABI_REVISION - 1u;
    return metask_agentcore_api_v1_is_compatible(&prior_revision) ? 1 : 0;
}
