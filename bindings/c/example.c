/*
 * Minimal C host for the open-apple-models bridge.
 *
 * Build (from the repository root):
 *   swift build -c release --product OpenAppleModelsFFI
 *   clang -I bindings/c bindings/c/example.c -L .build/release -lOpenAppleModelsFFI \
 *         -Wl,-rpath,.build/release -o /tmp/oam-example
 *   /tmp/oam-example            # scripted model (no Apple Intelligence needed)
 *   /tmp/oam-example --live     # on-device model
 *
 * It creates a session with one client tool ("ring_bell"), answers the
 * bridge's tool/call request from the callback, and prints every message.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include "open_apple_models.h"

typedef struct {
    oam_bridge *bridge;
    pthread_mutex_t lock;
    pthread_cond_t done;
    int finished;
} host_state;

/* Called on a bridge thread. A real engine would queue the line for its main
 * thread; this demo answers tool calls inline and watches for the final
 * response (id "turn"). */
static void on_message(const char *json_line, void *user_data) {
    host_state *state = (host_state *)user_data;
    printf("<- %s\n", json_line);

    if (strstr(json_line, "\"method\":\"tool/call\"") != NULL) {
        /* Extract the request id ("t-<n>") and answer it. */
        const char *id_start = strstr(json_line, "\"id\":\"");
        if (id_start != NULL) {
            id_start += 6;
            const char *id_end = strchr(id_start, '"');
            char reply[256];
            snprintf(reply, sizeof reply,
                     "{\"jsonrpc\":\"2.0\",\"id\":\"%.*s\",\"result\":{\"output\":{\"rang\":true,\"times\":3}}}",
                     (int)(id_end - id_start), id_start);
            printf("-> %s\n", reply);
            oam_bridge_send(state->bridge, reply);
        }
    }
    if (strstr(json_line, "\"id\":\"turn\"") != NULL && strstr(json_line, "\"method\"") == NULL) {
        pthread_mutex_lock(&state->lock);
        state->finished = 1;
        pthread_cond_signal(&state->done);
        pthread_mutex_unlock(&state->lock);
    }
}

int main(int argc, char **argv) {
    int live = argc > 1 && strcmp(argv[1], "--live") == 0;
    host_state state = {0};
    pthread_mutex_init(&state.lock, NULL);
    pthread_cond_init(&state.done, NULL);

    printf("open-apple-models %s\n", oam_version());
    state.bridge = oam_bridge_create(on_message, &state);

    /* Simple request/response without tools: the blocking helper. */
    char *availability = oam_call_blocking(state.bridge, "{\"method\":\"model/availability\"}", 5000);
    printf("model/availability: %s\n", availability);
    oam_string_free(availability);

    const char *model = live
        ? "\"system\""
        : "{\"type\":\"scripted\",\"steps\":["
          "{\"toolCalls\":[{\"name\":\"ring_bell\",\"arguments\":{\"times\":3}}]},"
          "{\"template\":\"Ding! The bell answered: {toolOutput}\"}]}";
    char create[1024];
    snprintf(create, sizeof create,
             "{\"jsonrpc\":\"2.0\",\"id\":\"create\",\"method\":\"session/create\",\"params\":{"
             "\"session\":\"bell\",\"model\":%s,"
             "\"instructions\":\"You are a village bell ringer in a game. Use tools to act. Reply in one sentence.\","
             "\"tools\":[{\"name\":\"ring_bell\",\"description\":\"Ring the village bell a number of times.\","
             "\"parameters\":{\"type\":\"object\",\"properties\":{\"times\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":12}},"
             "\"required\":[\"times\"]}}],"
             "\"options\":{\"toolChoice\":\"required\"}}}",
             model);
    oam_bridge_send(state.bridge, create);
    oam_bridge_send(state.bridge,
                    "{\"jsonrpc\":\"2.0\",\"id\":\"turn\",\"method\":\"session/respond\","
                    "\"params\":{\"session\":\"bell\",\"prompt\":\"Ring the bell three times.\",\"stream\":true}}");

    pthread_mutex_lock(&state.lock);
    while (!state.finished) pthread_cond_wait(&state.done, &state.lock);
    pthread_mutex_unlock(&state.lock);

    oam_bridge_destroy(state.bridge);
    printf("done\n");
    return 0;
}
