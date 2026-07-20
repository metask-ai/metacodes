#include <metask/agentcore.h>

const metask_agentcore_api_v1 *agentcore_header_compile_probe(void) {
    return (const metask_agentcore_api_v1 *)metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1);
}
