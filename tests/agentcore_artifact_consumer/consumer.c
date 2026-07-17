#include "metacodes_agentcore.h"

#include <limits.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static const char RESPONSE_BODY[] =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"c1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"c callback ok\"}}\n\n"
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
    "data: {\"type\":\"message_stop\"}\n\n";

struct test_server {
    int fd;
    uint16_t port;
    pthread_t thread;
    int result;
};

static int write_all(int fd, const void *bytes, size_t len) {
    const char *cursor = (const char *)bytes;
    while (len != 0) {
        ssize_t written = write(fd, cursor, len);
        if (written <= 0) return -1;
        cursor += (size_t)written;
        len -= (size_t)written;
    }
    return 0;
}

static int read_request(int fd) {
    char header[64 * 1024 + 1];
    size_t total = 0;
    char *end = NULL;
    while (total < sizeof(header) - 1 && end == NULL) {
        ssize_t count = read(fd, header + total, sizeof(header) - 1 - total);
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
        ssize_t count = read(fd, discard, needed < sizeof(discard) ? needed : sizeof(discard));
        if (count <= 0) return -1;
        body_read += (size_t)count;
    }
    return 0;
}

static void *serve_once(void *raw) {
    struct test_server *server = (struct test_server *)raw;
    struct pollfd ready = {.fd = server->fd, .events = POLLIN};
    if (poll(&ready, 1, 10000) <= 0) {
        server->result = -1;
        return NULL;
    }
    int client = accept(server->fd, NULL, NULL);
    struct timeval timeout = {.tv_sec = 10, .tv_usec = 0};
    if (client >= 0 &&
        (setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0 ||
         setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) != 0)) {
        close(client);
        server->result = -1;
        return NULL;
    }
    if (client < 0 || read_request(client) != 0) {
        if (client >= 0) close(client);
        server->result = -1;
        return NULL;
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
    close(client);
    return NULL;
}

static int start_server(struct test_server *server) {
    memset(server, 0, sizeof(*server));
    server->fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server->fd < 0) return -1;
    int yes = 1;
    setsockopt(server->fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server->fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(server->fd, 1) != 0) {
        close(server->fd);
        return -1;
    }
    socklen_t length = sizeof(address);
    if (getsockname(server->fd, (struct sockaddr *)&address, &length) != 0) {
        close(server->fd);
        return -1;
    }
    server->port = ntohs(address.sin_port);
    if (pthread_create(&server->thread, NULL, serve_once, server) != 0) {
        close(server->fd);
        return -1;
    }
    return 0;
}

static void stop_server(struct test_server *server) {
    shutdown(server->fd, SHUT_RDWR);
    pthread_join(server->thread, NULL);
    close(server->fd);
    server->fd = -1;
}

static unsigned event_calls = 0;

static uint32_t on_event(void *ctx, mc_session *session, uint64_t run_id,
                         mc_bytes_view_v1 event_json) {
    (void)ctx;
    (void)session;
    if (run_id == 1 && event_json.ptr != NULL && event_json.len != 0) {
        event_calls++;
        return MC_CALLBACK_CONTINUE;
    }
    return MC_CALLBACK_FATAL;
}

static mc_bytes_view_v1 view(const char *text) {
    mc_bytes_view_v1 out;
    out.ptr = (const uint8_t *)text;
    out.len = (uint64_t)strlen(text);
    return out;
}

static int release_error(const mc_agentcore_api_v1 *api,
                         mc_owned_bytes_v1 *diagnostic,
                         int code) {
    api->buffer_release(diagnostic);
    return code;
}

int main(void) {
    const mc_agentcore_api_v1 *api =
        (const mc_agentcore_api_v1 *)metacodes_agentcore_get_api(MC_AGENTCORE_ABI_V1);
    if (api == NULL || api->struct_size != sizeof(*api) ||
        api->abi_version != MC_AGENTCORE_ABI_V1 ||
        (api->capabilities & MC_REQUIRED_CAPABILITIES_V1) !=
            MC_REQUIRED_CAPABILITIES_V1 ||
        api->runtime_create == NULL || api->runtime_destroy == NULL ||
        api->session_create == NULL || api->session_destroy == NULL ||
        api->session_run == NULL || api->session_abort == NULL ||
        api->buffer_release == NULL) {
        return 10;
    }
    for (size_t i = 0; i < sizeof(api->reserved) / sizeof(api->reserved[0]); ++i) {
        if (api->reserved[i] != 0) {
            return 10;
        }
    }
    if (metacodes_agentcore_get_api(MC_AGENTCORE_ABI_V1 + 1) != NULL) {
        return 11;
    }

    mc_owned_bytes_v1 diagnostic = {0};
    mc_runtime_config_v1 runtime_config = {0};
    runtime_config.struct_size = sizeof(runtime_config);
    mc_runtime *runtime = NULL;
    if (api->runtime_create(&runtime_config, &runtime, &diagnostic) != MC_STATUS_OK ||
        runtime == NULL) {
        return release_error(api, &diagnostic, 12);
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

    mc_session_callbacks_v1 callbacks = {0};
    callbacks.struct_size = sizeof(callbacks);
    callbacks.on_event = on_event;
    mc_session_config_v1 session_config = {0};
    session_config.struct_size = sizeof(session_config);
    session_config.provider_kind_code = MC_PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = MC_PERMISSION_BYPASS;
    session_config.shell_policy_code = MC_SHELL_DISABLED;
    session_config.api_key = view("c-consumer-key");
    session_config.model = view("c-consumer-model");
    session_config.base_url = view(base_url);
    session_config.workspace_root = view(cwd);
    session_config.workspace_home = view(cwd);

    mc_session *session = NULL;
    if (api->session_create(runtime, &session_config, &callbacks, &session,
                            &diagnostic) != MC_STATUS_OK ||
        session == NULL) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 15);
    }

    uint32_t busy_status = api->runtime_destroy(runtime, &diagnostic);
    if (busy_status != MC_STATUS_BUSY ||
        diagnostic.ptr == NULL || diagnostic.len == 0) {
        stop_server(&server);
        api->buffer_release(&diagnostic);
        return 16;
    }
    api->buffer_release(&diagnostic);
    if (diagnostic.ptr != NULL || diagnostic.len != 0) {
        diagnostic = (mc_owned_bytes_v1){0};
        stop_server(&server);
        api->session_destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        api->buffer_release(&diagnostic);
        return 17;
    }

    mc_run_options_v1 options = {0};
    options.struct_size = sizeof(options);
    options.max_turns = 1;
    mc_run_result_v1 result = {0};
    uint32_t run_status = api->session_run(session, 1, view("exercise C ABI"),
                                           &options, &result, &diagnostic);
    stop_server(&server);
    if (run_status != MC_STATUS_OK || result.stop_reason_code != MC_STOP_END_TURN ||
        event_calls == 0 || server.result != 0) {
        api->buffer_release(&diagnostic);
        api->session_destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 18);
    }
    if (api->session_destroy(session, &diagnostic) != MC_STATUS_OK) {
        api->buffer_release(&diagnostic);
        api->runtime_destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 19);
    }
    if (api->runtime_destroy(runtime, &diagnostic) != MC_STATUS_OK) {
        return release_error(api, &diagnostic, 20);
    }
    api->buffer_release(&diagnostic);
    puts("AgentCore source-free C consumer: ABI table, callback and lifecycle OK");
    return 0;
}
