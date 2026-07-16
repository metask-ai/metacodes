#include "metacodes_agentcore.h"

int main(void) {
    const mc_agentcore_api_v1 *api =
        (const mc_agentcore_api_v1 *)metacodes_agentcore_get_api(MC_AGENTCORE_ABI_V1);
    return api == NULL ? 1 : 0;
}
