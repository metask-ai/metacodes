#include <metask/agentcore.h>

int main(void) {
    const metask_agentcore_api_v1 *api =
        (const metask_agentcore_api_v1 *)metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1);
    if (api == NULL || api->struct_size != sizeof(*api) ||
        api->abi_version != METASK_AGENTCORE_ABI_V1) {
        return 1;
    }
    return api->abi_revision == METASK_AGENTCORE_ABI_REVISION && api->reserved0 == 0 ? 0 : 1;
}
