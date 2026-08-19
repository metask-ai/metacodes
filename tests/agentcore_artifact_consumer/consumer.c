#include <metask/agentcore.h>

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(METASK_AGENTCORE_CALLBACK_CONTINUE) || defined(METASK_AGENTCORE_CALLBACK_FATAL)
#error "revision 9 must not retain historical callback aliases"
#endif

#if METASK_AGENTCORE_ABI_REVISION != 9u || \
    METASK_AGENTCORE_MCP_NEGOTIATION_AUTO != 1u || \
    METASK_AGENTCORE_MCP_NEGOTIATION_MODERN_ONLY != 2u || \
    METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_ONLY != 3u || \
    METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_2025_06_ONLY != 4u || \
    METASK_AGENTCORE_MCP_ERA_2026_07_28 != 1u || \
    METASK_AGENTCORE_MCP_ERA_2025_11_25 != 2u || \
    METASK_AGENTCORE_MCP_ERA_2025_06_18 != 3u || \
    METASK_AGENTCORE_MCP_APPLY_APPLIED != 1u || \
    METASK_AGENTCORE_MCP_APPLY_SUPERSEDED != 2u || \
    METASK_AGENTCORE_MCP_APPLY_REJECTED != 3u
#error "source-free Revision 9 MCP codes must match the public contract"
#endif

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <direct.h>
typedef SOCKET socket_handle;
typedef HANDLE thread_handle;
#define INVALID_SOCKET_HANDLE INVALID_SOCKET
#define SHUTDOWN_BOTH SD_BOTH
#define getcwd _getcwd
#ifndef PATH_MAX
#define PATH_MAX MAX_PATH
#endif
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
typedef int socket_handle;
typedef pthread_t thread_handle;
#define INVALID_SOCKET_HANDLE (-1)
#define SHUTDOWN_BOTH SHUT_RDWR
#endif

static const char RESPONSE_BODY[] =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"c1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"c callback ok\"}}\n\n"
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
    "data: {\"type\":\"message_stop\"}\n\n";

struct test_server {
    socket_handle fd;
    uint16_t port;
    thread_handle thread;
    int result;
};

static int socket_is_valid(socket_handle fd) {
    return fd != INVALID_SOCKET_HANDLE;
}

static void close_socket(socket_handle fd) {
#ifdef _WIN32
    closesocket(fd);
#else
    close(fd);
#endif
}

static int socket_read(socket_handle fd, void *bytes, size_t len) {
    size_t chunk = len > INT_MAX ? INT_MAX : len;
#ifdef _WIN32
    return recv(fd, (char *)bytes, (int)chunk, 0);
#else
    ssize_t count = recv(fd, bytes, chunk, 0);
    return count < 0 || count > INT_MAX ? -1 : (int)count;
#endif
}

static int socket_write(socket_handle fd, const void *bytes, size_t len) {
    size_t chunk = len > INT_MAX ? INT_MAX : len;
#ifdef _WIN32
    return send(fd, (const char *)bytes, (int)chunk, 0);
#else
    ssize_t count = send(fd, bytes, chunk, 0);
    return count < 0 || count > INT_MAX ? -1 : (int)count;
#endif
}

static int write_all(socket_handle fd, const void *bytes, size_t len) {
    const char *cursor = (const char *)bytes;
    while (len != 0) {
        int written = socket_write(fd, cursor, len);
        if (written <= 0) return -1;
        cursor += (size_t)written;
        len -= (size_t)written;
    }
    return 0;
}

static int read_request(socket_handle fd) {
    char header[64 * 1024 + 1];
    size_t total = 0;
    char *end = NULL;
    while (total < sizeof(header) - 1 && end == NULL) {
        int count = socket_read(fd, header + total, sizeof(header) - 1 - total);
        if (count <= 0) return -1;
        total += (size_t)count;
        header[total] = '\0';
        end = strstr(header, "\r\n\r\n");
    }
    if (end == NULL) return -1;
    size_t header_len = (size_t)(end - header) + 4;
    size_t content_len = 0;
    char *length = strstr(header, "Content-Length:");
    if (length != NULL) content_len = (size_t)strtoull(length + 15, NULL, 10);
    size_t body_read = total - header_len;
    char discard[8192];
    while (body_read < content_len) {
        size_t needed = content_len - body_read;
        int count = socket_read(fd, discard, needed < sizeof(discard) ? needed : sizeof(discard));
        if (count <= 0) return -1;
        body_read += (size_t)count;
    }
    return 0;
}

#ifdef _WIN32
static DWORD WINAPI serve_once(LPVOID raw) {
#define THREAD_RETURN return 0
#else
static void *serve_once(void *raw) {
#define THREAD_RETURN return NULL
#endif
    struct test_server *server = (struct test_server *)raw;
    socket_handle client = accept(server->fd, NULL, NULL);
#ifdef _WIN32
    DWORD timeout = 10000;
    if (socket_is_valid(client) &&
        (setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout,
                    sizeof(timeout)) != 0 ||
         setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout,
                    sizeof(timeout)) != 0)) {
#else
    struct timeval timeout = {.tv_sec = 10, .tv_usec = 0};
    if (socket_is_valid(client) &&
        (setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
         setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0)) {
#endif
        close_socket(client);
        server->result = -1;
        THREAD_RETURN;
    }
    if (!socket_is_valid(client) || read_request(client) != 0) {
        if (socket_is_valid(client)) close_socket(client);
        server->result = -1;
        THREAD_RETURN;
    }
    char header[256];
    int header_len = snprintf(header, sizeof(header),
                              "HTTP/1.1 200 OK\r\n"
                              "Content-Type: text/event-stream\r\n"
                              "Content-Length: %zu\r\n"
                              "Connection: close\r\n\r\n",
                              sizeof(RESPONSE_BODY) - 1);
    server->result = header_len > 0 &&
                             write_all(client, header, (size_t)header_len) == 0 &&
                             write_all(client, RESPONSE_BODY, sizeof(RESPONSE_BODY) - 1) == 0
                         ? 0
                         : -1;
    close_socket(client);
    THREAD_RETURN;
#undef THREAD_RETURN
}

static int start_server(struct test_server *server) {
    memset(server, 0, sizeof(*server));
#ifdef _WIN32
    WSADATA winsock;
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) return -1;
#endif
    server->fd = socket(AF_INET, SOCK_STREAM, 0);
    if (!socket_is_valid(server->fd)) {
#ifdef _WIN32
        WSACleanup();
#endif
        return -1;
    }
    int yes = 1;
    setsockopt(server->fd, SOL_SOCKET, SO_REUSEADDR,
#ifdef _WIN32
               (const char *)&yes,
#else
               &yes,
#endif
               sizeof(yes));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server->fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(server->fd, 1) != 0) {
        close_socket(server->fd);
#ifdef _WIN32
        WSACleanup();
#endif
        return -1;
    }
#ifdef _WIN32
    int length = sizeof(address);
#else
    socklen_t length = sizeof(address);
#endif
    if (getsockname(server->fd, (struct sockaddr *)&address, &length) != 0) {
        close_socket(server->fd);
#ifdef _WIN32
        WSACleanup();
#endif
        return -1;
    }
    server->port = ntohs(address.sin_port);
#ifdef _WIN32
    server->thread = CreateThread(NULL, 0, serve_once, server, 0, NULL);
    if (server->thread == NULL) {
#else
    if (pthread_create(&server->thread, NULL, serve_once, server) != 0) {
#endif
        close_socket(server->fd);
#ifdef _WIN32
        WSACleanup();
#endif
        return -1;
    }
    return 0;
}

static void stop_server(struct test_server *server) {
    shutdown(server->fd, SHUTDOWN_BOTH);
    close_socket(server->fd);
    server->fd = INVALID_SOCKET_HANDLE;
#ifdef _WIN32
    WaitForSingleObject(server->thread, INFINITE);
    CloseHandle(server->thread);
#else
    pthread_join(server->thread, NULL);
#endif
#ifdef _WIN32
    WSACleanup();
#endif
}

static unsigned event_calls = 0;
static metask_agentcore_session *registered_session = NULL;
static uint64_t active_run_id = 0;
static uint8_t bound_session_id[METASK_AGENTCORE_MAX_SESSION_ID_BYTES_V1];
static size_t bound_session_id_len = 0;

static int accept_run_context(const metask_agentcore_run_context_v1 *run) {
    if (run == NULL || run->struct_size != sizeof(*run) || run->reserved0 != 0 ||
        run->session != registered_session || run->run_id != active_run_id ||
        run->session_id.ptr == NULL || run->session_id.len == 0 ||
        run->session_id.len > METASK_AGENTCORE_MAX_SESSION_ID_BYTES_V1 ||
        run->reserved[0] != 0 || run->reserved[1] != 0) {
        return 0;
    }
    size_t len = (size_t)run->session_id.len;
    if (bound_session_id_len == 0) {
        memcpy(bound_session_id, run->session_id.ptr, len);
        bound_session_id_len = len;
        return 1;
    }
    return bound_session_id_len == len &&
           memcmp(bound_session_id, run->session_id.ptr, len) == 0;
}

static uint32_t on_event(void *ctx, const metask_agentcore_run_context_v1 *run,
                         metask_agentcore_bytes_view_v1 event_json) {
    (void)ctx;
    if (accept_run_context(run) && event_json.ptr != NULL && event_json.len != 0) {
        event_calls++;
        return METASK_AGENTCORE_EVENT_CONTINUE;
    }
    return METASK_AGENTCORE_EVENT_FATAL;
}

static metask_agentcore_bytes_view_v1 view(const char *text) {
    metask_agentcore_bytes_view_v1 out;
    out.ptr = (const uint8_t *)text;
    out.len = (uint64_t)strlen(text);
    return out;
}

static int release_error(const metask_agentcore_api_v1 *api,
                         metask_agentcore_owned_bytes_v1 *diagnostic,
                         int code) {
    api->buffer_release(diagnostic);
    return code;
}

int main(void) {
    const metask_agentcore_api_v1 *api = metask_agentcore_api_v1_discover();
    if (api == NULL) {
        return 10;
    }
    metask_agentcore_api_v1 prior_revision = *api;
    prior_revision.abi_revision = METASK_AGENTCORE_ABI_REVISION - 1u;
    if (metask_agentcore_api_v1_is_compatible(&prior_revision)) {
        return 10;
    }
    if (metask_agentcore_get_api(0) != NULL ||
        metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1 + 1) != NULL) {
        return 11;
    }

    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    metask_agentcore_runtime_config_v1 runtime_config = {0};
    runtime_config.struct_size = sizeof(runtime_config);
    metask_agentcore_runtime *runtime = NULL;
    if (api->runtime_create(&runtime_config, &runtime, &diagnostic) != METASK_AGENTCORE_STATUS_OK ||
        runtime == NULL) {
        return release_error(api, &diagnostic, 12);
    }
    metask_agentcore_mcp_configuration_v1 mcp_configuration = {0};
    mcp_configuration.struct_size = sizeof(mcp_configuration);
    mcp_configuration.desired_revision = 1;
    metask_agentcore_mcp_apply_report_v1 mcp_report = {0};
    if (api->runtime_apply_mcp_configuration(
            runtime, &mcp_configuration, &mcp_report, &diagnostic) !=
            METASK_AGENTCORE_STATUS_OK ||
        mcp_report.struct_size != sizeof(mcp_report) ||
        mcp_report.disposition_code != METASK_AGENTCORE_MCP_APPLY_APPLIED ||
        mcp_report.desired_revision != 1 || mcp_report.active_revision != 1 ||
        mcp_report.catalog_generation != 1) {
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 40);
    }

    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)) == NULL) {
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 13);
    }
    struct test_server server;
    if (start_server(&server) != 0) {
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 14);
    }
    char base_url[128];
    snprintf(base_url, sizeof(base_url), "http://127.0.0.1:%u/v1/messages",
             (unsigned)server.port);

    metask_agentcore_session_callbacks_v1 callbacks = {0};
    callbacks.struct_size = sizeof(callbacks);
    callbacks.on_event = on_event;
    metask_agentcore_session_host_config_v1 session_host = {0};
    session_host.struct_size = sizeof(session_host);
    session_host.provider_kind_code = METASK_AGENTCORE_PROVIDER_ANTHROPIC;
    session_host.permission_mode_code = METASK_AGENTCORE_PERMISSION_FULL_ACCESS;
    session_host.shell_policy_code = METASK_AGENTCORE_SHELL_DISABLED;
    session_host.api_key = view("c-consumer-key");
    session_host.base_url = view(base_url);
    session_host.workspace_root = view(cwd);
    session_host.workspace_home = view(cwd);
    metask_agentcore_session_create_config_v1 session_config = {0};
    session_config.struct_size = sizeof(session_config);
    session_config.host = &session_host;
    session_config.model = view("c-consumer-model");

    metask_agentcore_session *session = NULL;
    if (api->session_create(runtime, &session_config, &callbacks, &session,
                            &diagnostic) != METASK_AGENTCORE_STATUS_OK ||
        session == NULL) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 15);
    }
    registered_session = session;

    if (api->session_set_model(session, view("c-consumer-model-v2"),
                               &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        stop_server(&server);
        api->session_destroy(session, &diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 16);
    }
    metask_agentcore_permission_rule_set_v1 empty_rules = {0};
    empty_rules.struct_size = sizeof(empty_rules);
    if (api->session_update_permission_rules(session, &empty_rules,
                                             &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        stop_server(&server);
        api->session_destroy(session, &diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 17);
    }
    metask_agentcore_compact_result_v1 compact_result = {0};
    if (api->session_compact(session, 1, &compact_result,
                             &diagnostic) != METASK_AGENTCORE_STATUS_OK ||
        compact_result.struct_size != sizeof(compact_result) ||
        compact_result.outcome_code != METASK_AGENTCORE_COMPACT_NO_CHANGE ||
        api->session_abort_compact(session, 1, &diagnostic) !=
            METASK_AGENTCORE_STATUS_TOO_LATE) {
        stop_server(&server);
        api->buffer_release(&diagnostic);
        api->session_destroy(session, &diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 18);
    }
    api->buffer_release(&diagnostic);

    uint32_t busy_status = api->runtime_destroy(runtime, &diagnostic);
    if (busy_status != METASK_AGENTCORE_STATUS_BUSY ||
        diagnostic.ptr == NULL || diagnostic.len == 0) {
        stop_server(&server);
        api->buffer_release(&diagnostic);
        return 16;
    }
    api->buffer_release(&diagnostic);
    if (diagnostic.ptr != NULL || diagnostic.len != 0) {
        diagnostic = (metask_agentcore_owned_bytes_v1){0};
        stop_server(&server);
        api->session_destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        api->buffer_release(&diagnostic);
        return 17;
    }

    metask_agentcore_run_options_v1 options = {0};
    options.struct_size = sizeof(options);
    options.max_turns = 1;
    metask_agentcore_run_input_v1 input = {0};
    input.struct_size = sizeof(input);
    input.kind_code = METASK_AGENTCORE_RUN_INPUT_TEXT;
    input.text = view("exercise C ABI");
    metask_agentcore_run_result_v1 result = {0};
    active_run_id = 1;
    uint32_t run_status = api->session_run_input(session, 1, &input, &options,
                                                 &result, &diagnostic);
    active_run_id = 0;
    stop_server(&server);
    if (run_status != METASK_AGENTCORE_STATUS_OK || result.stop_reason_code != METASK_AGENTCORE_STOP_END_TURN ||
        event_calls == 0 || server.result != 0) {
        api->buffer_release(&diagnostic);
        api->session_destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 18);
    }
    if (api->session_destroy(session, &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        api->buffer_release(&diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 19);
    }
    if (api->runtime_destroy(runtime, &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        return release_error(api, &diagnostic, 20);
    }
    api->buffer_release(&diagnostic);
    puts("AgentCore source-free C consumer: ABI table, callback and lifecycle OK");
    return 0;
}
