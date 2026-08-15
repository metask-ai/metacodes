#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int fail(const char *message) {
    fprintf(stderr, "fake-metacodes: %s\n", message);
    return 80;
}

static int mkdir_p(const char *path) {
    char buffer[4096];
    size_t length = strlen(path);
    if (length == 0 || length >= sizeof(buffer)) return -1;
    memcpy(buffer, path, length + 1);
    for (char *cursor = buffer + 1; *cursor; cursor++) {
        if (*cursor != '/') continue;
        *cursor = '\0';
        if (mkdir(buffer, 0700) != 0 && errno != EEXIST) return -1;
        *cursor = '/';
    }
    return mkdir(buffer, 0700) == 0 || errno == EEXIST ? 0 : -1;
}

static int write_all(const char *path, const char *content) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return -1;
    size_t size = strlen(content);
    ssize_t written = write(fd, content, size);
    int saved = errno;
    if (fsync(fd) != 0 || close(fd) != 0 || written != (ssize_t)size) {
        errno = saved;
        return -1;
    }
    return 0;
}

static int network_is_loopback_only(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return 0;
    int isolated = 1;
    for (struct ifaddrs *row = interfaces; row; row = row->ifa_next) {
        if (!row->ifa_addr || !(row->ifa_flags & IFF_UP)) continue;
        if (!(row->ifa_flags & IFF_LOOPBACK)) {
            isolated = 0;
            break;
        }
    }
    freeifaddrs(interfaces);
    return isolated;
}

int main(int argc, char **argv) {
    const char *expected_route = NULL;
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--help") == 0) {
            puts("metacodes synthetic WorkBuddy W0 fixture");
            return 0;
        }
        if (strcmp(argv[index], "--model") == 0 && index + 1 < argc)
            expected_route = argv[index + 1];
    }
    const char *home = getenv("HOME");
    const char *fd_raw = getenv("METACODES_API_KEY_FD");
    const char *store = getenv("METACODES_KG_STORE");
    const char *kg_bin = getenv("METACODES_KG_BIN");
    const char *kernel = getenv("METACODES_FORMAL_KERNEL_PATH");
    const char *kernel_sha = getenv("METACODES_FORMAL_KERNEL_SHA256");
    if (!home || !fd_raw || !store || !kg_bin || !kernel || !kernel_sha ||
        !expected_route)
        return fail("missing runtime binding");
    if (getenv("METACODES_ROUTE_TOKEN") || getenv("TINYKG_REMOTE_URL") ||
        getenv("TINYKG_API_KEY") || getenv("TINYKG_REMOTE_EXPECTED_BUILD_ID") ||
        getenv("TINYKG_REMOTE_CONFIG") || getenv("METACODES_KG_CONFIG") ||
        getenv("METACODES_KG_URL") || getenv("METACODES_KG_API_KEY") ||
        getenv("METACODES_KG_EXPECTED_BUILD_ID") ||
        getenv("METACODES_KG_EXPECTED_SCHEMA_DIGEST") || getenv("METASK_API_KEY"))
        return fail("ambient credential or remote TinyKG configuration leaked");
    if (!network_is_loopback_only())
        return fail("container network namespace is not isolated");
    if (strlen(kernel_sha) != 64 || strncmp(store, home, strlen(home)) != 0)
        return fail("kernel/store identity is not bound to the fresh HOME");
    char *end = NULL;
    long fd_number = strtol(fd_raw, &end, 10);
    if (!end || *end || fd_number < 3 || fd_number > 1024)
        return fail("credential fd is invalid");
    char route[1024];
    ssize_t route_bytes = read((int)fd_number, route, sizeof(route));
    size_t expected_route_bytes = strlen(expected_route);
    size_t token_bytes = route_bytes > 0 ? (size_t)(route_bytes - 1) : 0;
    if (route_bytes <= 1 || route[route_bytes - 1] != '\n' ||
        token_bytes <= expected_route_bytes + 2 ||
        memcmp(route + token_bytes - expected_route_bytes, expected_route,
               expected_route_bytes) != 0 ||
        route[token_bytes - expected_route_bytes - 2] != ':' ||
        route[token_bytes - expected_route_bytes - 1] != ':')
        return fail("route token is not trial-scoped to the registered model route");

    if (write_all("/workspace/result.txt", "metacodes workbuddy w0 ok\n") != 0)
        return fail("cannot write task artifact");
    char session_dir[4096];
    int count = snprintf(
        session_dir, sizeof(session_dir),
        "%s/.metacodes/projects/0000000000000000/session-w0", home
    );
    if (count <= 0 || (size_t)count >= sizeof(session_dir) || mkdir_p(session_dir) != 0)
        return fail("cannot create transcript directory");
    char transcript[4096];
    count = snprintf(transcript, sizeof(transcript), "%s/transcript.jsonl", session_dir);
    if (count <= 0 || (size_t)count >= sizeof(transcript)) return fail("path overflow");
    const char *messages =
        "{\"role\":\"user\",\"blocks\":[{\"type\":\"text\",\"text\":\"synthetic W0\"}]}\n"
        "{\"role\":\"assistant\",\"blocks\":[{\"type\":\"tool_use\",\"id\":\"call-w0\",\"name\":\"Write\",\"input\":\"{\\\"file_path\\\":\\\"/workspace/result.txt\\\"}\"}]}\n"
        "{\"role\":\"user\",\"blocks\":[{\"type\":\"tool_result\",\"tool_use_id\":\"call-w0\",\"content\":\"written\",\"is_error\":false}]}\n"
        "{\"role\":\"assistant\",\"blocks\":[{\"type\":\"text\",\"text\":\"synthetic complete\"}]}\n";
    if (write_all(transcript, messages) != 0) return fail("cannot write transcript");
    char observations[4096];
    count = snprintf(
        observations, sizeof(observations), "%s/tool-observations.jsonl", session_dir
    );
    if (count <= 0 || (size_t)count >= sizeof(observations))
        return fail("observation path overflow");
    const char *journal =
        "{\"schema_version\":\"metacodes-tool-observation-journal-v1\",\"sequence\":0,\"monotonic_elapsed_ns\":0,\"session_id\":\"session-w0\",\"run_id\":\"run-w0\",\"event\":{\"run_started\":{}}}\n"
        "{\"schema_version\":\"metacodes-tool-observation-journal-v1\",\"sequence\":1,\"monotonic_elapsed_ns\":1,\"session_id\":\"session-w0\",\"run_id\":\"run-w0\",\"event\":{\"tool_observation\":{\"dispatch_started\":{\"schema_version\":\"metacodes-tool-observation-v1\",\"id\":\"call-w0\",\"requested_name\":\"Write\",\"dispatched_name\":\"Write\",\"origin\":\"authoritative\",\"agent_depth\":0}}}}\n"
        "{\"schema_version\":\"metacodes-tool-observation-journal-v1\",\"sequence\":2,\"monotonic_elapsed_ns\":2,\"session_id\":\"session-w0\",\"run_id\":\"run-w0\",\"event\":{\"tool_observation\":{\"dispatch_finished\":{\"schema_version\":\"metacodes-tool-observation-v1\",\"id\":\"call-w0\",\"requested_name\":\"Write\",\"dispatched_name\":\"Write\",\"origin\":\"authoritative\",\"agent_depth\":0,\"outcome\":\"succeeded\"}}}}\n"
        "{\"schema_version\":\"metacodes-tool-observation-journal-v1\",\"sequence\":3,\"monotonic_elapsed_ns\":3,\"session_id\":\"session-w0\",\"run_id\":\"run-w0\",\"event\":{\"run_finished\":{}}}\n";
    if (write_all(observations, journal) != 0)
        return fail("cannot write tool observation journal");
    if (write_all(
            "/logs/agent/fake-runtime-contract.json",
            "{\"anonymous_fd\":true,\"fresh_home\":true,\"local_tinykg\":true,\"network_loopback_only\":true,\"remote_tinykg\":false,\"provider_requests\":0,\"quality_evidence\":false,\"route_scoped_to_model\":true}\n"
        ) != 0)
        return fail("cannot write runtime evidence");
    puts("{\"type\":\"result\",\"stop_reason\":\"end_turn\",\"turns\":2,\"tool_calls\":1,\"input_tokens\":120,\"output_tokens\":30,\"cache_read_input_tokens\":80,\"cache_creation_input_tokens\":10,\"cost_usd\":0.0,\"text\":\"synthetic complete\"}");
    return 0;
}
