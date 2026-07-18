#include "metacodes_agentcore.h"

int main(void) {
    const mc_agentcore_api_v1 *api =
        (const mc_agentcore_api_v1 *)metacodes_agentcore_get_api(MC_AGENTCORE_ABI_V1);
    if (api == NULL || api->struct_size != sizeof(*api) ||
        api->abi_version != MC_AGENTCORE_ABI_V1) {
        return 1;
    }
    return api->abi_revision == MC_AGENTCORE_ABI_REVISION && api->reserved0 == 0 ? 0 : 1;
}
