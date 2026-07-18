#include "metacodes_agentcore.h"

int main() {
    const auto *api = static_cast<const mc_agentcore_api_v1 *>(
        metacodes_agentcore_get_api(MC_AGENTCORE_ABI_V1));
    if (api == nullptr || api->struct_size != sizeof(*api) ||
        api->abi_version != MC_AGENTCORE_ABI_V1) {
        return 1;
    }
    if (api->abi_revision != MC_AGENTCORE_ABI_REVISION || api->reserved0 != 0 ||
        (api->capabilities & MC_REQUIRED_CAPABILITIES_V1) !=
            MC_REQUIRED_CAPABILITIES_V1) {
        return 1;
    }
    return 0;
}
