#include <metask/agentcore.h>

int main(void) {
    const metask_agentcore_api_v1 *api = metask_agentcore_api_v1_discover();
    if (api == NULL || metask_agentcore_get_api(0) != NULL ||
        metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1 + 1) != NULL) {
        return 1;
    }
    metask_agentcore_api_v1 revision_5 = *api;
    revision_5.abi_revision = 5;
    return metask_agentcore_api_v1_is_compatible(&revision_5) ? 1 : 0;
}
