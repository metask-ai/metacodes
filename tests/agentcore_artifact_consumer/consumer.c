#include <metask/agentcore.h>

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(METASK_AGENTCORE_CALLBACK_CONTINUE) || defined(METASK_AGENTCORE_CALLBACK_FATAL)
#error "revision 27 must not retain historical callback aliases"
#endif

#if METASK_AGENTCORE_ABI_REVISION != 27u || \
    METASK_AGENTCORE_MAX_CREDENTIAL_BYTES_V1 != 16384u || \
    METASK_AGENTCORE_MAX_SUBMITTED_INPUTS_V1 != 64u || \
    METASK_AGENTCORE_MAX_SUBMITTED_INPUT_BYTES_V1 != 16777216u || \
    METASK_AGENTCORE_PROMPT_OP_ADD != 1u || \
    METASK_AGENTCORE_PROMPT_OP_REPLACE != 2u || \
    METASK_AGENTCORE_PROMPT_OP_REMOVE != 3u || \
    METASK_AGENTCORE_MAX_CONTEXT_BLOCKS_V1 != 32u || \
    METASK_AGENTCORE_STATUS_SKILL_CATALOG_INCOMPLETE != 27u || \
    METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED != 28u || \
    METASK_AGENTCORE_STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN != 29u || \
    METASK_AGENTCORE_CAPABILITY_SUPPORTED != 1u || \
    METASK_AGENTCORE_CAPABILITY_UNSUPPORTED != 2u || \
    METASK_AGENTCORE_MAX_MODEL_CAPABILITIES_V1 != 256u || \
    METASK_AGENTCORE_MAX_MODEL_CAPABILITY_MODEL_BYTES_V1 != 256u || \
    METASK_AGENTCORE_TIME_CONTEXT_SYSTEM != 0u || \
    METASK_AGENTCORE_TIME_CONTEXT_UTC_OFFSET != 1u || \
    METASK_AGENTCORE_TIME_CONTEXT_OFF != 2u || \
    METASK_AGENTCORE_MIN_UTC_OFFSET_MINUTES_V1 != -840 || \
    METASK_AGENTCORE_MAX_UTC_OFFSET_MINUTES_V1 != 840 || \
    METASK_AGENTCORE_RUN_INPUT_MULTIMODAL != 3u || \
    METASK_AGENTCORE_RUN_INPUT_PART_TEXT != 1u || \
    METASK_AGENTCORE_RUN_INPUT_PART_IMAGE != 2u || \
    METASK_AGENTCORE_MAX_RUN_INPUT_PARTS_V1 != 64u || \
    METASK_AGENTCORE_MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1 != 5000000u || \
    METASK_AGENTCORE_PROTOCOL_DEFAULT != 0u || \
    METASK_AGENTCORE_OPENAI_PROTOCOL_RESPONSES != 1u || \
    METASK_AGENTCORE_MCP_NEGOTIATION_AUTO != 1u || \
    METASK_AGENTCORE_MCP_NEGOTIATION_MODERN_ONLY != 2u || \
    METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_ONLY != 3u || \
    METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_2025_06_ONLY != 4u || \
    METASK_AGENTCORE_MCP_ERA_2026_07_28 != 1u || \
    METASK_AGENTCORE_MCP_ERA_2025_11_25 != 2u || \
    METASK_AGENTCORE_MCP_ERA_2025_06_18 != 3u || \
    METASK_AGENTCORE_MCP_APPLY_APPLIED != 1u || \
    METASK_AGENTCORE_MCP_APPLY_SUPERSEDED != 2u || \
    METASK_AGENTCORE_MCP_APPLY_REJECTED != 3u || \
    METASK_AGENTCORE_STATUS_GOAL_CONFLICT != 30u || \
    METASK_AGENTCORE_RUN_INPUT_GOAL_CONTINUATION != 4u || \
    METASK_AGENTCORE_GOAL_FIELD_OBJECTIVE != 1u || \
    METASK_AGENTCORE_GOAL_FIELD_TOKEN_BUDGET != 2u || \
    METASK_AGENTCORE_GOAL_FIELD_ACTION != 4u || \
    METASK_AGENTCORE_GOAL_ACTION_PAUSE != 1u || \
    METASK_AGENTCORE_GOAL_ACTION_ACTIVATE != 2u || \
    METASK_AGENTCORE_GOAL_ACTION_COMPLETE != 3u || \
    METASK_AGENTCORE_GOAL_ACTION_BLOCK != 4u || \
    METASK_AGENTCORE_MAX_GOAL_OBJECTIVE_CODEPOINTS_V1 != 4000u || \
    METASK_AGENTCORE_MAX_GOAL_OBJECTIVE_BYTES_V1 != 16384u || \
    METASK_AGENTCORE_TEAM_ROLE_LEAD != 1u || \
    METASK_AGENTCORE_TEAM_ROLE_MEMBER != 2u || \
    METASK_AGENTCORE_MAX_TEAM_NAME_BYTES_V1 != 64u || \
    METASK_AGENTCORE_MAX_TEAM_MEMBER_BYTES_V1 != 64u || \
    METASK_AGENTCORE_STATUS_MESSAGE_POSITION_OUT_OF_RANGE != 31u || \
    METASK_AGENTCORE_STATUS_NOT_USER_MESSAGE != 32u || \
    METASK_AGENTCORE_STATUS_MESSAGE_POSITION_COMPACTED != 33u
#error "source-free Revision 23-27 codes must match the public contract"
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
/* glibc declares PATH_MAX only with a POSIX feature macro, which -std=c11
   does not set; 4096 is Linux's value. */
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
#endif

/* METASK_AGENTCORE_CONSUMER_DYNAMIC (#182): the same consumer, but the API
 * comes from the bundle's shared library through the platform loader, as a
 * ctypes or FFI Host obtains it, and nothing links the static library. */
#if defined(METASK_AGENTCORE_CONSUMER_DYNAMIC)
#ifndef _WIN32
#include <dlfcn.h>
#endif
typedef const void *(*agentcore_get_api_fn)(uint32_t);
static agentcore_get_api_fn loaded_get_api = NULL;

static int load_agentcore(const char *path) {
#ifdef _WIN32
    /* The altered search path resolves the DLL's own imports beside it. */
    HMODULE module = LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (module == NULL) {
        fprintf(stderr, "LoadLibraryExA(%s) failed: %lu\n", path, (unsigned long)GetLastError());
        return 0;
    }
    FARPROC symbol = GetProcAddress(module, "metask_agentcore_get_api");
    if (symbol == NULL) return 0;
    loaded_get_api = (agentcore_get_api_fn)(void (*)(void))symbol;
#else
    void *module = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (module == NULL) {
        fprintf(stderr, "dlopen(%s) failed: %s\n", path, dlerror());
        return 0;
    }
    void *symbol = dlsym(module, "metask_agentcore_get_api");
    if (symbol == NULL) return 0;
    /* ISO C has no object-to-function pointer conversion; POSIX guarantees
       the representation, so copy the bytes. */
    memcpy(&loaded_get_api, &symbol, sizeof(symbol));
#endif
    return 1;
}

static const void *agentcore_get_api(uint32_t requested_abi) {
    return loaded_get_api(requested_abi);
}
#else
static const void *agentcore_get_api(uint32_t requested_abi) {
    return metask_agentcore_get_api(requested_abi);
}
#endif

static const char RESPONSE_BODY[] =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"c1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"c callback ok\"}}\n\n"
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
    "data: {\"type\":\"message_stop\"}\n\n";

/* Revision 25 (#336): the first round of the credential rotation Run calls
 * the Host stream tool, whose callback rotates the credential. */
static const char ROTATE_TOOL_BODY[] =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"c2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_rotate\",\"name\":\"HostStreamC\",\"input\":{}}}\n\n"
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n"
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n"
    "data: {\"type\":\"message_stop\"}\n\n";

/* Rolling substring scan over a streamed request so the multimodal image
 * payload is proven inside provider-visible request bytes even when recv
 * splits it across chunks. */
struct needle_scan {
    const char *needle;
    size_t needle_len;
    char carry[96];
    size_t carry_len;
    int found;
};

static void scan_feed(struct needle_scan *scan, const char *bytes, size_t len) {
    char window[8192 + 96];
    if (scan == NULL || scan->found || scan->needle_len == 0 ||
        scan->needle_len > sizeof(scan->carry)) {
        return;
    }
    while (len != 0) {
        size_t chunk = len > 8192 ? 8192 : len;
        size_t total = scan->carry_len + chunk;
        size_t keep = scan->needle_len - 1;
        size_t index;
        memcpy(window, scan->carry, scan->carry_len);
        memcpy(window + scan->carry_len, bytes, chunk);
        for (index = 0; index + scan->needle_len <= total; index++) {
            if (memcmp(window + index, scan->needle, scan->needle_len) == 0) {
                scan->found = 1;
                return;
            }
        }
        if (keep > total) keep = total;
        memcpy(scan->carry, window + total - keep, keep);
        scan->carry_len = keep;
        bytes += chunk;
        len -= chunk;
    }
}

struct test_server {
    socket_handle fd;
    uint16_t port;
    thread_handle thread;
    int result;
    int rounds;
    struct needle_scan scan;
    /* Revision 22: the runtime's time context for the UTC-offset Run. */
    struct needle_scan time_scan;
    /* Revision 23: the input the runtime writes for a goal continuation. */
    struct needle_scan goal_scan;
    /* Revision 25: per-round response bodies (NULL: RESPONSE_BODY every
     * round) and the authorization header value each round's request carried. */
    const char *const *bodies;
    char authorization[4][128];
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

/* Copy the value of the request header `name` (lower case, with its colon,
 * matched in any case), or an empty string when the head has none. `header`
 * is the NUL-terminated head. */
static void copy_header_value(const char *header, const char *name, char *out,
                              size_t cap) {
    const size_t name_len = strlen(name);
    const char *line = header;
    out[0] = '\0';
    while (line != NULL) {
        const char *end = strstr(line, "\r\n");
        size_t len = end != NULL ? (size_t)(end - line) : strlen(line);
        size_t index;
        int same = len >= name_len;
        if (len == 0) return; /* the blank line ends the head */
        for (index = 0; same && index < name_len; index++) {
            char c = line[index];
            if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
            same = c == name[index];
        }
        if (same) {
            const char *value = line + name_len;
            size_t value_len = len - name_len;
            while (value_len != 0 && (*value == ' ' || *value == '\t')) {
                value++;
                value_len--;
            }
            if (value_len >= cap) value_len = cap - 1;
            memcpy(out, value, value_len);
            out[value_len] = '\0';
            return;
        }
        line = end != NULL ? end + 2 : NULL;
    }
}

static int read_request(socket_handle fd, struct needle_scan *scan,
                        struct needle_scan *time_scan,
                        struct needle_scan *goal_scan, char *authorization,
                        size_t authorization_cap) {
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
    if (authorization != NULL)
        copy_header_value(header, "authorization:", authorization, authorization_cap);
    scan_feed(scan, header, total);
    scan_feed(time_scan, header, total);
    scan_feed(goal_scan, header, total);
    size_t header_len = (size_t)(end - header) + 4;
    /* The client sends `content-length` in lower case. Matching only
     * `Content-Length` left a body that arrived after the head unread, and
     * Winsock resets a connection closed over unread bytes, discarding the
     * response already sent. */
    char length[32];
    copy_header_value(header, "content-length:", length, sizeof(length));
    size_t content_len = (size_t)strtoull(length, NULL, 10);
    size_t body_read = total - header_len;
    char discard[8192];
    while (body_read < content_len) {
        size_t needed = content_len - body_read;
        int count = socket_read(fd, discard, needed < sizeof(discard) ? needed : sizeof(discard));
        if (count <= 0) return -1;
        scan_feed(scan, discard, (size_t)count);
        scan_feed(time_scan, discard, (size_t)count);
        scan_feed(goal_scan, discard, (size_t)count);
        body_read += (size_t)count;
    }
    return 0;
}

#ifdef _WIN32
static DWORD WINAPI serve_rounds(LPVOID raw) {
#define THREAD_RETURN return 0
#else
static void *serve_rounds(void *raw) {
#define THREAD_RETURN return NULL
#endif
    struct test_server *server = (struct test_server *)raw;
    int round;
    for (round = 0; round < server->rounds; round++) {
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
        if (!socket_is_valid(client) ||
            read_request(client, &server->scan, &server->time_scan,
                         &server->goal_scan,
                         round < 4 ? server->authorization[round] : NULL,
                         sizeof(server->authorization[0])) != 0) {
            if (socket_is_valid(client)) close_socket(client);
            server->result = -1;
            THREAD_RETURN;
        }
        {
            const char *body =
                server->bodies != NULL ? server->bodies[round] : RESPONSE_BODY;
            size_t body_len = strlen(body);
            char header[256];
            int header_len = snprintf(header, sizeof(header),
                                      "HTTP/1.1 200 OK\r\n"
                                      "Content-Type: text/event-stream\r\n"
                                      "Content-Length: %zu\r\n"
                                      "Connection: close\r\n\r\n",
                                      body_len);
            int round_ok = header_len > 0 &&
                           write_all(client, header, (size_t)header_len) == 0 &&
                           write_all(client, body, body_len) == 0;
            close_socket(client);
            if (!round_ok) {
                server->result = -1;
                THREAD_RETURN;
            }
        }
    }
    server->result = 0;
    THREAD_RETURN;
#undef THREAD_RETURN
}

static int start_server(struct test_server *server, int rounds,
                        const char *needle, const char *const *bodies) {
    memset(server, 0, sizeof(*server));
    server->rounds = rounds;
    server->bodies = bodies;
    server->result = -1;
    if (needle != NULL) {
        server->scan.needle = needle;
        server->scan.needle_len = strlen(needle);
    }
    server->time_scan.needle = "Time zone: UTC+05:30.";
    server->time_scan.needle_len = strlen(server->time_scan.needle);
    server->goal_scan.needle = "Continue working toward the active goal.";
    server->goal_scan.needle_len = strlen(server->goal_scan.needle);
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
    server->thread = CreateThread(NULL, 0, serve_rounds, server, 0, NULL);
    if (server->thread == NULL) {
#else
    if (pthread_create(&server->thread, NULL, serve_rounds, server) != 0) {
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

static metask_agentcore_bytes_view_v1 view(const char *text);
static unsigned event_calls = 0;
static metask_agentcore_session *registered_session = NULL;
static uint64_t active_run_id = 0;
static uint8_t bound_session_id[METASK_AGENTCORE_MAX_SESSION_ID_BYTES_V1];
static size_t bound_session_id_len = 0;

/* Revision 20: the first text_chunk of the armed Run submits more input from
 * inside the callback. The request is already out and the Run is a single
 * turn, so it ends before another boundary and the input must reconcile as
 * accepted but not adopted. (Input submitted before the first request — at
 * the starting run_state — would ride that very request.) */
static const metask_agentcore_api_v1 *callback_api = NULL;
static int submit_on_event = 0;
static uint32_t submit_status = UINT32_MAX;
static uint32_t submit_sequence = 0;

/* Revision 25: the armed Host stream tool call rotates the provider
 * credential from inside its own callback, first with a candidate the
 * library must refuse (a space), then with the replacement. */
static int rotate_on_tool = 0;
static uint32_t rotate_refused_status = UINT32_MAX;
static uint32_t rotate_status = UINT32_MAX;

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
        static const char text_chunk_tag[] = "{\"text_chunk\"";
        if (submit_on_event && callback_api != NULL &&
            event_json.len >= sizeof(text_chunk_tag) - 1 &&
            memcmp(event_json.ptr, text_chunk_tag, sizeof(text_chunk_tag) - 1) == 0) {
            metask_agentcore_submitted_input_v1 input = {0};
            metask_agentcore_input_receipt_v1 receipt = {0};
            metask_agentcore_owned_bytes_v1 diagnostic = {0};
            submit_on_event = 0;
            input.struct_size = (uint32_t)sizeof(input);
            input.input_id = 77;
            input.text = view("one more thing");
            submit_status = callback_api->session->submit_input(
                registered_session, run->run_id, &input, &receipt, &diagnostic);
            callback_api->buffer_release(&diagnostic);
            submit_sequence = receipt.sequence;
        }
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

/* 1 when the Session description contains `needle`. */
static int description_contains(const metask_agentcore_api_v1 *api,
                                metask_agentcore_session *session,
                                const char *needle) {
    metask_agentcore_owned_bytes_v1 description = {0};
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    struct needle_scan scan = {0};
    if (api->session_control->describe(session, &description, &diagnostic) !=
        METASK_AGENTCORE_STATUS_OK) {
        api->buffer_release(&diagnostic);
        return 0;
    }
    scan.needle = needle;
    scan.needle_len = strlen(needle);
    scan_feed(&scan, (const char *)description.ptr, (size_t)description.len);
    api->buffer_release(&description);
    return scan.found;
}

/* Revision 27: describe's conversation.message_count, or UINT64_MAX when the
 * description cannot be read. */
static uint64_t description_message_count(const metask_agentcore_api_v1 *api,
                                          metask_agentcore_session *session) {
    static const char key[] = "\"message_count\":";
    metask_agentcore_owned_bytes_v1 description = {0};
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint64_t count = UINT64_MAX;
    if (api->session_control->describe(session, &description, &diagnostic) !=
        METASK_AGENTCORE_STATUS_OK) {
        api->buffer_release(&diagnostic);
        return count;
    }
    if (description.ptr != NULL && description.len >= sizeof(key) - 1) {
        size_t len = (size_t)description.len;
        size_t index;
        for (index = 0; index + sizeof(key) - 1 <= len; ++index) {
            if (memcmp(description.ptr + index, key, sizeof(key) - 1) == 0) {
                size_t digit = index + sizeof(key) - 1;
                uint64_t value = 0;
                int any = 0;
                while (digit < len && description.ptr[digit] >= '0' &&
                       description.ptr[digit] <= '9') {
                    value = value * 10u + (uint64_t)(description.ptr[digit] - '0');
                    any = 1;
                    ++digit;
                }
                if (any) count = value;
                break;
            }
        }
    }
    api->buffer_release(&description);
    return count;
}

/* Revision 27: rewind_to_user_message's status; a refusal must carry a
 * diagnostic, which is released here. */
static uint32_t rewind_status(const metask_agentcore_api_v1 *api,
                              metask_agentcore_session *session,
                              uint64_t position) {
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = api->session_control->rewind_to_user_message(
        session, position, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK &&
        (diagnostic.ptr == NULL || diagnostic.len == 0)) {
        status = METASK_AGENTCORE_STATUS_INTERNAL_ERROR;
    }
    api->buffer_release(&diagnostic);
    return status;
}

/* Revision 23: whether goal->get's JSON contains `needle`. */
static int goal_contains(const metask_agentcore_api_v1 *api,
                         metask_agentcore_session *session,
                         const char *needle) {
    metask_agentcore_owned_bytes_v1 goal = {0};
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    struct needle_scan scan = {0};
    if (api->goal->get(session, &goal, &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        api->buffer_release(&diagnostic);
        return 0;
    }
    scan.needle = needle;
    scan.needle_len = strlen(needle);
    scan_feed(&scan, (const char *)goal.ptr, (size_t)goal.len);
    api->buffer_release(&goal);
    return scan.found;
}


static uint32_t host_stream(
    void *ctx, const metask_agentcore_run_context_v1 *run,
    metask_agentcore_bytes_view_v1 arguments,
    const metask_agentcore_host_result_sink_v1 *sink, uint32_t *media_code,
    metask_agentcore_owned_bytes_v1 *detail) {
    (void)ctx;
    (void)arguments;
    if (rotate_on_tool && callback_api != NULL && run != NULL) {
        metask_agentcore_owned_bytes_v1 rotate_diagnostic = {0};
        rotate_on_tool = 0;
        rotate_refused_status = callback_api->session->update_credential(
            run->session, view("c rotated key"), &rotate_diagnostic);
        callback_api->buffer_release(&rotate_diagnostic);
        rotate_status = callback_api->session->update_credential(
            run->session, view("c-rotated-key"), &rotate_diagnostic);
        callback_api->buffer_release(&rotate_diagnostic);
    }
    if (sink == NULL || sink->struct_size != sizeof(*sink) ||
        sink->write == NULL ||
        sink->max_bytes != METASK_AGENTCORE_MAX_HOST_STREAM_ARTIFACT_BYTES_V1 ||
        media_code == NULL || detail == NULL) {
        return METASK_AGENTCORE_HOST_FATAL;
    }
    metask_agentcore_bytes_view_v1 bytes = view("c-stream");
    if (sink->write(sink->ctx, bytes) != METASK_AGENTCORE_HOST_SINK_OK) {
        return METASK_AGENTCORE_HOST_FAILED;
    }
    *media_code = METASK_AGENTCORE_HOST_STREAM_MEDIA_TEXT_UTF8;
    *detail = (metask_agentcore_owned_bytes_v1){0};
    return METASK_AGENTCORE_HOST_OK;
}

static void host_stream_release(void *ctx,
                                metask_agentcore_owned_bytes_v1 *detail) {
    (void)ctx;
    if (detail != NULL) *detail = (metask_agentcore_owned_bytes_v1){0};
}

/* Revision 25 (#336): one Session's provider credential, rotated twice
 * against a loopback provider that records each request's authorization
 * header. The Run's first request carries the creation key; its Host stream
 * tool callback rotates the key (after a refused candidate), so the Run's
 * second request carries the rotation; an update while idle reaches the next
 * Run; refusals keep the key; describe never names a key. 0 or an exit code. */
static int credential_rotation(const metask_agentcore_api_v1 *api,
                               metask_agentcore_runtime *runtime,
                               const metask_agentcore_session_callbacks_v1 *callbacks,
                               const char *cwd) {
    static const char *const bodies[] = {ROTATE_TOOL_BODY, RESPONSE_BODY, RESPONSE_BODY};
    static char oversized[METASK_AGENTCORE_MAX_CREDENTIAL_BYTES_V1 + 1];
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    struct test_server server;
    if (start_server(&server, 3, NULL, bodies) != 0) return 80;
    char base_url[128];
    snprintf(base_url, sizeof(base_url), "http://127.0.0.1:%u/v1/messages",
             (unsigned)server.port);

    metask_agentcore_session_host_config_v1 host = {0};
    host.struct_size = sizeof(host);
    host.provider_kind_code = METASK_AGENTCORE_PROVIDER_ANTHROPIC;
    host.protocol_kind_code = METASK_AGENTCORE_PROTOCOL_DEFAULT;
    host.permission_mode_code = METASK_AGENTCORE_PERMISSION_FULL_ACCESS;
    host.shell_policy_code = METASK_AGENTCORE_SHELL_DISABLED;
    host.api_key = view("c-consumer-key");
    host.base_url = view(base_url);
    host.workspace_root = view(cwd);
    host.workspace_home = view(cwd);
    metask_agentcore_bytes_view_v1 allowed[] = {view("HostStreamC")};
    host.allowed_tools = allowed;
    host.allowed_tool_count = 1;
    metask_agentcore_session_create_config_v1 config = {0};
    config.struct_size = sizeof(config);
    config.host = &host;
    config.model = view("c-consumer-model");
    metask_agentcore_session *session = NULL;
    if (api->session->create(runtime, &config, callbacks, &session, &diagnostic) !=
            METASK_AGENTCORE_STATUS_OK ||
        session == NULL) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        return 81;
    }
    registered_session = session;
    bound_session_id_len = 0;

    metask_agentcore_run_options_v1 options = {0};
    options.struct_size = sizeof(options);
    options.max_turns = 4;
    metask_agentcore_run_input_v1 input = {0};
    input.struct_size = sizeof(input);
    input.kind_code = METASK_AGENTCORE_RUN_INPUT_TEXT;
    input.text = view("rotate the credential");
    metask_agentcore_run_result_v1 result = {0};
    int code = 0;

    active_run_id = 1;
    callback_api = api;
    rotate_on_tool = 1;
    uint32_t status = api->session->run_input(session, 1, &input, &options, &result, &diagnostic);
    active_run_id = 0;
    api->buffer_release(&diagnostic);
    memset(oversized, 'k', sizeof(oversized));
    metask_agentcore_bytes_view_v1 too_long = {(const uint8_t *)oversized, sizeof(oversized)};
    metask_agentcore_bytes_view_v1 empty = {NULL, 0};
    if (status != METASK_AGENTCORE_STATUS_OK ||
        result.stop_reason_code != METASK_AGENTCORE_STOP_END_TURN || result.turns != 2) {
        code = 82;
    } else if (rotate_refused_status != METASK_AGENTCORE_STATUS_INVALID_ARGUMENT ||
               rotate_status != METASK_AGENTCORE_STATUS_OK) {
        code = 83;
    } else if (api->session->update_credential(session, view("c-idle-key"), &diagnostic) !=
               METASK_AGENTCORE_STATUS_OK) {
        code = 84;
    } else if (api->session->update_credential(session, empty, &diagnostic) !=
                   METASK_AGENTCORE_STATUS_INVALID_ARGUMENT ||
               (api->buffer_release(&diagnostic),
                api->session->update_credential(session, too_long, &diagnostic)) !=
                   METASK_AGENTCORE_STATUS_RESOURCE_LIMIT) {
        code = 85;
    } else {
        api->buffer_release(&diagnostic);
        input.text = view("once more");
        active_run_id = 2;
        status = api->session->run_input(session, 2, &input, &options, &result, &diagnostic);
        active_run_id = 0;
        if (status != METASK_AGENTCORE_STATUS_OK ||
            result.stop_reason_code != METASK_AGENTCORE_STOP_END_TURN) {
            code = 86;
        } else if (description_contains(api, session, "c-consumer-key") ||
                   description_contains(api, session, "c-rotated-key") ||
                   description_contains(api, session, "c-idle-key")) {
            code = 87;
        }
    }
    api->buffer_release(&diagnostic);
    if (api->session->destroy(session, &diagnostic) != METASK_AGENTCORE_STATUS_OK && code == 0)
        code = 88;
    api->buffer_release(&diagnostic);
    registered_session = NULL;
    stop_server(&server);
    if (code == 0 &&
        (server.result != 0 ||
         strcmp(server.authorization[0], "Bearer c-consumer-key") != 0 ||
         strcmp(server.authorization[1], "Bearer c-rotated-key") != 0 ||
         strcmp(server.authorization[2], "Bearer c-idle-key") != 0)) {
        fprintf(stderr, "credential rotation saw [%s] [%s] [%s]\n",
                server.authorization[0], server.authorization[1], server.authorization[2]);
        code = 89;
    }
    return code;
}

int main(int argc, char **argv) {
#if defined(METASK_AGENTCORE_CONSUMER_DYNAMIC)
    if (argc != 2 || !load_agentcore(argv[1])) {
        return 9;
    }
    const metask_agentcore_api_v1 *discovered =
        (const metask_agentcore_api_v1 *)agentcore_get_api(METASK_AGENTCORE_ABI_V1);
    const metask_agentcore_api_v1 *api =
        metask_agentcore_api_v1_is_compatible(discovered) ? discovered : NULL;
#else
    (void)argc;
    (void)argv;
    const metask_agentcore_api_v1 *api = metask_agentcore_api_v1_discover();
#endif
    if (api == NULL) {
        return 10;
    }
    const metask_agentcore_api_v1 *raw_api =
        (const metask_agentcore_api_v1 *)agentcore_get_api(
            METASK_AGENTCORE_ABI_V1);
    if (raw_api != api || api->buffer_release != raw_api->buffer_release ||
        api->runtime->create != raw_api->runtime->create ||
        api->runtime->destroy != raw_api->runtime->destroy ||
        api->session->create != raw_api->session->create ||
        api->session->destroy != raw_api->session->destroy ||
        api->session->run_input != raw_api->session->run_input ||
        api->session->abort != raw_api->session->abort ||
        api->session->submit_input != raw_api->session->submit_input ||
        api->session->update_credential != raw_api->session->update_credential ||
        api->session_control->restore != raw_api->session_control->restore ||
        api->session_control->describe != raw_api->session_control->describe ||
        api->session_control->set_model != raw_api->session_control->set_model ||
        api->session_control->update_permission_rules !=
            raw_api->session_control->update_permission_rules ||
        api->session_control->compact != raw_api->session_control->compact ||
        api->session_control->abort_compact !=
            raw_api->session_control->abort_compact ||
        api->session_control->export_checkpoint !=
            raw_api->session_control->export_checkpoint ||
        api->session_control->set_prompt_profile !=
            raw_api->session_control->set_prompt_profile ||
        api->session_control->update_permission_mode !=
            raw_api->session_control->update_permission_mode ||
        api->session_control->rewind_to_user_message !=
            raw_api->session_control->rewind_to_user_message ||
        api->skill->resolve_catalog != raw_api->skill->resolve_catalog ||
        api->skill->release_catalog != raw_api->skill->release_catalog ||
        api->skill->bind_policy != raw_api->skill->bind_policy ||
        api->mcp->apply_configuration != raw_api->mcp->apply_configuration ||
        api->mcp->refresh != raw_api->mcp->refresh ||
        api->mcp->describe != raw_api->mcp->describe ||
        api->mcp->update_selection != raw_api->mcp->update_selection) {
        return 10;
    }
    metask_agentcore_api_v1 prior_revision = *api;
    prior_revision.abi_revision = METASK_AGENTCORE_ABI_REVISION - 1u;
    if (metask_agentcore_api_v1_is_compatible(&prior_revision)) {
        return 10;
    }
    if (agentcore_get_api(0) != NULL ||
        agentcore_get_api(METASK_AGENTCORE_ABI_V1 + 1) != NULL) {
        return 11;
    }

    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    metask_agentcore_runtime_config_v1 runtime_config = {0};
    runtime_config.struct_size = sizeof(runtime_config);
    /* Revision 24 (issue #277): admit the team tools; the main Session below
     * carries no team config, so only the dedicated team Session is affected. */
    runtime_config.enable_teams = 1;
    metask_agentcore_host_stream_tool_v1 stream_tool = {0};
    stream_tool.struct_size = sizeof(stream_tool);
    stream_tool.name = view("HostStreamC");
    stream_tool.description = view("C source-free Host streaming descriptor");
    stream_tool.input_schema_json =
        view("{\"type\":\"object\",\"properties\":{},\"required\":[]}");
    stream_tool.execute_stream = host_stream;
    stream_tool.release_detail = host_stream_release;
    metask_agentcore_runtime_plugin_config_v1 plugin_config = {0};
    plugin_config.struct_size = sizeof(plugin_config);
    plugin_config.host_stream_tools = &stream_tool;
    plugin_config.host_stream_tool_count = 1;
    metask_agentcore_runtime *runtime = NULL;
    if (api->runtime->create(
            &runtime_config, &plugin_config, &runtime, &diagnostic) !=
            METASK_AGENTCORE_STATUS_OK ||
        runtime == NULL) {
        return release_error(api, &diagnostic, 12);
    }
    metask_agentcore_mcp_configuration_v1 mcp_configuration = {0};
    mcp_configuration.struct_size = sizeof(mcp_configuration);
    mcp_configuration.desired_revision = 1;
    metask_agentcore_mcp_apply_report_v1 mcp_report = {0};
    if (api->mcp->apply_configuration(
            runtime, &mcp_configuration, &mcp_report, &diagnostic) !=
            METASK_AGENTCORE_STATUS_OK ||
        mcp_report.struct_size != sizeof(mcp_report) ||
        mcp_report.disposition_code != METASK_AGENTCORE_MCP_APPLY_APPLIED ||
        mcp_report.desired_revision != 1 || mcp_report.active_revision != 1 ||
        mcp_report.catalog_generation != 1) {
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 40);
    }

    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof(cwd)) == NULL) {
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 13);
    }
    struct test_server server;
    if (start_server(&server, 3, "\"data\":\"aWNvbi1ieXRlcw==\"", NULL) != 0) {
        api->runtime->destroy(runtime, &diagnostic);
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
    session_host.protocol_kind_code = METASK_AGENTCORE_PROTOCOL_DEFAULT;
    session_host.permission_mode_code = METASK_AGENTCORE_PERMISSION_FULL_ACCESS;
    session_host.shell_policy_code = METASK_AGENTCORE_SHELL_DISABLED;
    session_host.api_key = view("c-consumer-key");
    session_host.base_url = view(base_url);
    session_host.workspace_root = view(cwd);
    session_host.workspace_home = view(cwd);
    metask_agentcore_bytes_view_v1 allowed_tools[] = {view("HostStreamC")};
    session_host.allowed_tools = allowed_tools;
    session_host.allowed_tool_count = 1;
    /* Revision 21: the Host's own knowledge of its models' image input. The
     * vision model's name is in no built-in family; the Claude name is, and
     * the Host's "unsupported" outranks that family. */
    metask_agentcore_model_capability_v1 model_capabilities[2];
    memset(model_capabilities, 0, sizeof(model_capabilities));
    model_capabilities[0].struct_size = (uint32_t)sizeof(model_capabilities[0]);
    model_capabilities[0].image_input_code = METASK_AGENTCORE_CAPABILITY_SUPPORTED;
    model_capabilities[0].model = view("c-consumer-vision");
    model_capabilities[1].struct_size = (uint32_t)sizeof(model_capabilities[1]);
    model_capabilities[1].image_input_code = METASK_AGENTCORE_CAPABILITY_UNSUPPORTED;
    model_capabilities[1].model = view("claude-c-consumer");
    session_host.model_capabilities = model_capabilities;
    session_host.model_capability_count = 2;
    /* A Host persona: replace the kernel identity, add one Host section. */
    metask_agentcore_prompt_section_v1 prompt_sections[2];
    memset(prompt_sections, 0, sizeof(prompt_sections));
    prompt_sections[0].struct_size = (uint32_t)sizeof(prompt_sections[0]);
    prompt_sections[0].op_code = METASK_AGENTCORE_PROMPT_OP_REPLACE;
    prompt_sections[0].id = view("metacodes:identity");
    prompt_sections[0].text = view("You are the C consumer probe.");
    prompt_sections[1].struct_size = (uint32_t)sizeof(prompt_sections[1]);
    prompt_sections[1].op_code = METASK_AGENTCORE_PROMPT_OP_ADD;
    prompt_sections[1].id = view("host:c-consumer");
    prompt_sections[1].order = 500;
    prompt_sections[1].text = view("Platform: {{platform}}.");
    prompt_sections[1].interpolate = 1;
    metask_agentcore_prompt_profile_v1 prompt_profile = {0};
    prompt_profile.struct_size = sizeof(prompt_profile);
    prompt_profile.sections = prompt_sections;
    prompt_profile.section_count = 2;
    metask_agentcore_session_create_config_v1 session_config = {0};
    session_config.struct_size = sizeof(session_config);
    session_config.host = &session_host;
    session_config.model = view("c-consumer-model");
    session_config.prompt_profile = &prompt_profile;

    metask_agentcore_session *session = NULL;
    if (api->session->create(runtime, &session_config, &callbacks, &session,
                            &diagnostic) != METASK_AGENTCORE_STATUS_OK ||
        session == NULL) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 15);
    }
    registered_session = session;

    if (api->session_control->set_model(session, view("c-consumer-model-v2"),
                               &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 16);
    }
    metask_agentcore_permission_rule_set_v1 empty_rules = {0};
    empty_rules.struct_size = sizeof(empty_rules);
    if (api->session_control->update_permission_rules(session, &empty_rules,
                                             &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 17);
    }
    /* The permission mode changes in place and describe names it; an unknown
     * code is refused with a diagnostic and changes nothing. */
    if (api->session_control->update_permission_mode(
            session, METASK_AGENTCORE_PERMISSION_DEFAULT, &diagnostic) !=
            METASK_AGENTCORE_STATUS_OK ||
        !description_contains(api, session, "\"permission_mode\":\"default\"")) {
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 62);
    }
    if (api->session_control->update_permission_mode(session, 99u, &diagnostic) !=
            METASK_AGENTCORE_STATUS_INVALID_ARGUMENT ||
        diagnostic.ptr == NULL || diagnostic.len == 0 ||
        !description_contains(api, session, "\"permission_mode\":\"default\"")) {
        stop_server(&server);
        api->buffer_release(&diagnostic);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 63);
    }
    api->buffer_release(&diagnostic);
    if (api->session_control->update_permission_mode(
            session, METASK_AGENTCORE_PERMISSION_FULL_ACCESS, &diagnostic) !=
            METASK_AGENTCORE_STATUS_OK ||
        !description_contains(api, session, "\"permission_mode\":\"full_access\"")) {
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 64);
    }
    /* A locked section is refused with a diagnostic and nothing changes; a
     * valid replacement (drop the Host section) is accepted while idle. */
    metask_agentcore_prompt_section_v1 locked_section = prompt_sections[0];
    locked_section.id = view("metacodes:system");
    metask_agentcore_prompt_profile_v1 locked_profile = prompt_profile;
    locked_profile.sections = &locked_section;
    locked_profile.section_count = 1;
    if (api->session_control->set_prompt_profile(session, &locked_profile,
                                                 &diagnostic) !=
            METASK_AGENTCORE_STATUS_INVALID_ARGUMENT ||
        diagnostic.ptr == NULL || diagnostic.len == 0) {
        stop_server(&server);
        api->buffer_release(&diagnostic);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 60);
    }
    api->buffer_release(&diagnostic);
    metask_agentcore_prompt_profile_v1 identity_only = prompt_profile;
    identity_only.section_count = 1;
    if (api->session_control->set_prompt_profile(session, &identity_only,
                                                 &diagnostic) !=
        METASK_AGENTCORE_STATUS_OK) {
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 61);
    }
    metask_agentcore_compact_result_v1 compact_result = {0};
    if (api->session_control->compact(session, 1, &compact_result,
                             &diagnostic) != METASK_AGENTCORE_STATUS_OK ||
        compact_result.struct_size != sizeof(compact_result) ||
        compact_result.outcome_code != METASK_AGENTCORE_COMPACT_NO_CHANGE ||
        api->session_control->abort_compact(session, 1, &diagnostic) !=
            METASK_AGENTCORE_STATUS_TOO_LATE) {
        stop_server(&server);
        api->buffer_release(&diagnostic);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 18);
    }
    api->buffer_release(&diagnostic);

    uint32_t busy_status = api->runtime->destroy(runtime, &diagnostic);
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
        api->session->destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        api->buffer_release(&diagnostic);
        return 17;
    }

    metask_agentcore_run_options_v1 options = {0};
    options.struct_size = sizeof(options);
    options.max_turns = 1;

    /* Multimodal pre-provider probes: nothing says the current model takes
     * images (CAPABILITY_UNKNOWN, not UNSUPPORTED), a model the Host declared
     * unsupported is refused, and malformed wire is rejected outright. None
     * of these requests reaches the mock provider (both response rounds stay
     * unconsumed) and the rejected Run id stays reusable. */
    metask_agentcore_run_input_part_v1 image_parts[2];
    memset(image_parts, 0, sizeof(image_parts));
    image_parts[0].struct_size = (uint32_t)sizeof(image_parts[0]);
    image_parts[0].kind_code = METASK_AGENTCORE_RUN_INPUT_PART_TEXT;
    image_parts[0].text = view("what is in this icon?");
    image_parts[1].struct_size = (uint32_t)sizeof(image_parts[1]);
    image_parts[1].kind_code = METASK_AGENTCORE_RUN_INPUT_PART_IMAGE;
    image_parts[1].media_type = view("image/png");
    image_parts[1].data = view("aWNvbi1ieXRlcw==");
    metask_agentcore_run_input_v1 multimodal = {0};
    multimodal.struct_size = sizeof(multimodal);
    multimodal.kind_code = METASK_AGENTCORE_RUN_INPUT_MULTIMODAL;
    multimodal.parts = image_parts;
    multimodal.part_count = 2;
    metask_agentcore_run_result_v1 result = {0};
    if (api->session->run_input(session, 1, &multimodal, &options, &result,
                                &diagnostic) !=
            METASK_AGENTCORE_STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN ||
        !description_contains(api, session,
                              "\"image_input\":{\"supported\":false,\"source\":\"unknown\"}")) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 21);
    }
    api->buffer_release(&diagnostic);
    metask_agentcore_run_input_v1 malformed = multimodal;
    malformed.parts = (const metask_agentcore_run_input_part_v1 *)0;
    malformed.part_count = 0;
    metask_agentcore_run_input_v1 text_with_parts = {0};
    text_with_parts.struct_size = sizeof(text_with_parts);
    text_with_parts.kind_code = METASK_AGENTCORE_RUN_INPUT_TEXT;
    text_with_parts.text = view("text with stray parts");
    text_with_parts.parts = image_parts;
    text_with_parts.part_count = 1;
    if (api->session->run_input(session, 1, &malformed, &options, &result,
                                &diagnostic) !=
            METASK_AGENTCORE_STATUS_INVALID_ARGUMENT ||
        (api->buffer_release(&diagnostic),
         api->session->run_input(session, 1, &text_with_parts, &options,
                                 &result, &diagnostic)) !=
            METASK_AGENTCORE_STATUS_INVALID_ARGUMENT) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 22);
    }
    api->buffer_release(&diagnostic);

    /* The family table says Claude takes images; the Host's declaration says
     * this route does not, and the Host wins - before any provider round. */
    if (api->session_control->set_model(session, view("claude-c-consumer"),
                                        &diagnostic) != METASK_AGENTCORE_STATUS_OK ||
        (api->buffer_release(&diagnostic),
         api->session->run_input(session, 1, &multimodal, &options, &result,
                                 &diagnostic)) !=
            METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED ||
        !description_contains(api, session,
                              "\"image_input\":{\"supported\":false,\"source\":\"host\"}")) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 65);
    }
    api->buffer_release(&diagnostic);

    /* Vision-capable model for the two real provider rounds: a name no
     * built-in family knows, admitted only by the Host's declaration. */
    if (api->session_control->set_model(session, view("c-consumer-vision"),
                                        &diagnostic) != METASK_AGENTCORE_STATUS_OK ||
        !description_contains(api, session,
                              "\"image_input\":{\"supported\":true,\"source\":\"host\"}")) {
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 23);
    }

    metask_agentcore_run_input_v1 input = {0};
    input.struct_size = sizeof(input);
    input.kind_code = METASK_AGENTCORE_RUN_INPUT_TEXT;
    input.text = view("exercise C ABI");
    /* A volatile Host fact for this Run only, as user-role context. */
    metask_agentcore_context_block_v1 context_block = {0};
    context_block.struct_size = sizeof(context_block);
    context_block.label = view("currentDate");
    context_block.text = view("Today's date is 2026/10/02.");
    metask_agentcore_run_options_v1 context_options = options;
    context_options.context_blocks = &context_block;
    context_options.context_block_count = 1;
    active_run_id = 1;
    callback_api = api;
    submit_on_event = 1;
    uint32_t run_status = api->session->run_input(session, 1, &input,
                                                 &context_options, &result,
                                                 &diagnostic);
    active_run_id = 0;
    if (run_status != METASK_AGENTCORE_STATUS_OK ||
        result.stop_reason_code != METASK_AGENTCORE_STOP_END_TURN) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 18);
    }
    /* Accepted from the callback, never adopted: the single turn ended the
     * Run first. After the Run its id is too late and an unknown id stale. */
    {
        metask_agentcore_submitted_input_v1 late = {0};
        metask_agentcore_input_receipt_v1 receipt = {0};
        late.struct_size = (uint32_t)sizeof(late);
        late.input_id = 78;
        late.text = view("late");
        if (submit_status != METASK_AGENTCORE_STATUS_OK || submit_sequence != 1 ||
            result.input_accepted_count != 1 || result.input_adopted_count != 0 ||
            api->session->submit_input(session, 1, &late, &receipt, &diagnostic) !=
                METASK_AGENTCORE_STATUS_TOO_LATE ||
            (api->buffer_release(&diagnostic),
             api->session->submit_input(session, 99, &late, &receipt,
                                        &diagnostic)) !=
                METASK_AGENTCORE_STATUS_STALE_RUN) {
            api->buffer_release(&diagnostic);
            stop_server(&server);
            api->session->destroy(session, &diagnostic);
            api->buffer_release(&diagnostic);
            api->runtime->destroy(runtime, &diagnostic);
            return release_error(api, &diagnostic, 25);
        }
        api->buffer_release(&diagnostic);
    }

    /* End-to-end multimodal Run: the ordered text+image parts must reach the
     * captured provider request bytes (base64 payload verified by the mock
     * server's rolling scan). Revision 22: the Host gives the user's UTC
     * offset, and the runtime's date context names it in the same request. */
    metask_agentcore_run_options_v1 offset_options = options;
    offset_options.time_context_code = METASK_AGENTCORE_TIME_CONTEXT_UTC_OFFSET;
    offset_options.utc_offset_minutes = 330;
    /* Revision 27: the Run's own message is message_count + 1, read while
     * idle just before it. */
    const uint64_t multimodal_position = description_message_count(api, session) + 1u;
    active_run_id = 2;
    run_status = api->session->run_input(session, 2, &multimodal, &offset_options,
                                         &result, &diagnostic);
    active_run_id = 0;
    if (run_status != METASK_AGENTCORE_STATUS_OK ||
        result.stop_reason_code != METASK_AGENTCORE_STOP_END_TURN ||
        event_calls == 0 || !server.scan.found || !server.time_scan.found) {
        api->buffer_release(&diagnostic);
        stop_server(&server);
        api->session->destroy(session, &diagnostic);
        api->buffer_release(&diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 24);
    }
    /* Revision 27 (#441): positions whose context cannot be rebuilt are
     * refused with their own status and change nothing; the multimodal
     * message is dropped with its reply, so the next Run follows exactly the
     * context before it. */
    {
        const uint64_t count = description_message_count(api, session);
        if (multimodal_position == 0u || count == UINT64_MAX || count <= multimodal_position ||
            rewind_status(api, session, 0u) != METASK_AGENTCORE_STATUS_INVALID_ARGUMENT ||
            rewind_status(api, session, multimodal_position + 1u) !=
                METASK_AGENTCORE_STATUS_NOT_USER_MESSAGE ||
            rewind_status(api, session, UINT64_MAX) !=
                METASK_AGENTCORE_STATUS_MESSAGE_POSITION_OUT_OF_RANGE ||
            description_message_count(api, session) != count ||
            rewind_status(api, session, multimodal_position) != METASK_AGENTCORE_STATUS_OK ||
            description_message_count(api, session) != multimodal_position - 1u) {
            stop_server(&server);
            api->session->destroy(session, &diagnostic);
            api->buffer_release(&diagnostic);
            api->runtime->destroy(runtime, &diagnostic);
            return release_error(api, &diagnostic, 66);
        }
    }

    /* Revision 23: the Host sets a goal; a goal-continuation Run, whose
     * input the runtime writes, works toward it and is charged to it. Once
     * paused, the goal cannot be continued and nothing is sent. */
    {
        metask_agentcore_goal_set_v1 goal = {0};
        metask_agentcore_goal_update_v1 pause = {0};
        metask_agentcore_run_input_v1 continuation = {0};
        goal.struct_size = (uint32_t)sizeof(goal);
        goal.objective = view("ship the C consumer");
        goal.token_budget = 100000;
        pause.struct_size = (uint32_t)sizeof(pause);
        pause.fields = METASK_AGENTCORE_GOAL_FIELD_ACTION;
        pause.action_code = METASK_AGENTCORE_GOAL_ACTION_PAUSE;
        continuation.struct_size = (uint32_t)sizeof(continuation);
        continuation.kind_code = METASK_AGENTCORE_RUN_INPUT_GOAL_CONTINUATION;
        int goal_ok = goal_contains(api, session, "{\"goal\":null}") &&
                      api->goal->set(session, &goal, &diagnostic) == METASK_AGENTCORE_STATUS_OK &&
                      goal_contains(api, session, "\"status\":\"active\"") &&
                      goal_contains(api, session, "\"tokens_used\":0,");
        active_run_id = 3;
        run_status = goal_ok ? api->session->run_input(session, 3, &continuation,
                                                       &options, &result, &diagnostic)
                             : METASK_AGENTCORE_STATUS_INTERNAL_ERROR;
        active_run_id = 0;
        stop_server(&server);
        if (run_status != METASK_AGENTCORE_STATUS_OK ||
            result.stop_reason_code != METASK_AGENTCORE_STOP_END_TURN ||
            server.result != 0 || !server.goal_scan.found ||
            goal_contains(api, session, "\"tokens_used\":0,") ||
            api->goal->update(session, &pause, &diagnostic) != METASK_AGENTCORE_STATUS_OK ||
            !goal_contains(api, session, "\"status\":\"paused\"") ||
            api->session->run_input(session, 4, &continuation, &options, &result,
                                    &diagnostic) != METASK_AGENTCORE_STATUS_GOAL_CONFLICT) {
            api->buffer_release(&diagnostic);
            api->session->destroy(session, &diagnostic);
            api->buffer_release(&diagnostic);
            api->runtime->destroy(runtime, &diagnostic);
            return release_error(api, &diagnostic, 26);
        }
        api->buffer_release(&diagnostic);
    }
    /* Revision 24 (issue #277): a source-free host reaches team->describe and
     * team->poll on a lead Session with teams enabled. A lead that has not run
     * TeamCreate has no team, so both report empty. The populated round-trip is
     * the AgentCore L2 team test. */
    {
        metask_agentcore_team_config_v1 team_cfg = {0};
        team_cfg.struct_size = (uint32_t)sizeof(team_cfg);
        team_cfg.role_code = METASK_AGENTCORE_TEAM_ROLE_LEAD;
        team_cfg.team_name = view("");

        metask_agentcore_session_host_config_v1 team_host = {0};
        team_host.struct_size = (uint32_t)sizeof(team_host);
        team_host.provider_kind_code = METASK_AGENTCORE_PROVIDER_ANTHROPIC;
        team_host.protocol_kind_code = METASK_AGENTCORE_PROTOCOL_DEFAULT;
        team_host.permission_mode_code = METASK_AGENTCORE_PERMISSION_FULL_ACCESS;
        team_host.shell_policy_code = METASK_AGENTCORE_SHELL_DISABLED;
        team_host.api_key = view("c-consumer-key");
        team_host.base_url = view(base_url);
        team_host.workspace_root = view(cwd);
        team_host.workspace_home = view(cwd);
        metask_agentcore_bytes_view_v1 team_allowed[] = {view("HostStreamC")};
        team_host.allowed_tools = team_allowed;
        team_host.allowed_tool_count = 1;
        team_host.team = &team_cfg;

        metask_agentcore_session_create_config_v1 team_config = {0};
        team_config.struct_size = (uint32_t)sizeof(team_config);
        team_config.host = &team_host;
        team_config.model = view("c-consumer-model");

        metask_agentcore_session *team_session = NULL;
        metask_agentcore_owned_bytes_v1 team_json = {0};
        metask_agentcore_owned_bytes_v1 poll_json = {0};
        int team_ok =
            api->session->create(runtime, &team_config, &callbacks, &team_session,
                                 &diagnostic) == METASK_AGENTCORE_STATUS_OK &&
            team_session != NULL &&
            api->team->describe(team_session, &team_json, &diagnostic) ==
                METASK_AGENTCORE_STATUS_OK &&
            team_json.len == 13 &&
            memcmp(team_json.ptr, "{\"team\":null}", 13) == 0 &&
            api->team->poll(team_session, &poll_json, &diagnostic) ==
                METASK_AGENTCORE_STATUS_OK &&
            poll_json.len == 14 &&
            memcmp(poll_json.ptr, "{\"input\":null}", 14) == 0;
        api->buffer_release(&team_json);
        api->buffer_release(&poll_json);
        if (team_session != NULL)
            api->session->destroy(team_session, &diagnostic);
        if (!team_ok) {
            api->buffer_release(&diagnostic);
            api->session->destroy(session, &diagnostic);
            api->buffer_release(&diagnostic);
            api->runtime->destroy(runtime, &diagnostic);
            return release_error(api, &diagnostic, 27);
        }
        api->buffer_release(&diagnostic);
    }
    if (api->session->destroy(session, &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        api->buffer_release(&diagnostic);
        api->runtime->destroy(runtime, &diagnostic);
        return release_error(api, &diagnostic, 19);
    }
    {
        int rotation = credential_rotation(api, runtime, &callbacks, cwd);
        if (rotation != 0) {
            api->runtime->destroy(runtime, &diagnostic);
            return release_error(api, &diagnostic, rotation);
        }
    }
    if (api->runtime->destroy(runtime, &diagnostic) != METASK_AGENTCORE_STATUS_OK) {
        return release_error(api, &diagnostic, 20);
    }
    api->buffer_release(&diagnostic);
    puts("AgentCore source-free C consumer: ABI table, callback, active-Run input, multimodal input, rewind to a user message, goal, host-scheduled team, credential rotation and lifecycle OK");
    return 0;
}
