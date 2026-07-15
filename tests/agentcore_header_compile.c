#include "metacodes_agentcore.h"

const mc_agentcore_api_v1 *agentcore_header_compile_probe(void) {
    return (const mc_agentcore_api_v1 *)metacodes_agentcore_get_api(MC_AGENTCORE_ABI_V1);
}
