/*
 * open_apple_models.h — C ABI for open-apple-models (OpenAppleModelsFFI).
 *
 * Drive on-device Apple Foundation Models agents from any language that can
 * call C: Unity (C# P/Invoke), Godot (GDExtension), Unreal (C++), Python
 * (ctypes), Rust, Zig, ...
 *
 * The ABI is a message pipe. You send JSON-RPC 2.0 messages in with
 * oam_bridge_send(); the bridge sends responses, notifications and its own
 * requests (tool/call) out through your callback. The message reference is
 * docs/PROTOCOL.md. Every message is one line of UTF-8 JSON without a
 * trailing newline.
 *
 * Typical flow:
 *
 *   static void on_message(const char *json_line, void *user_data) {
 *       // Copy json_line and hand it to your main thread (see THREADING).
 *   }
 *
 *   oam_bridge *bridge = oam_bridge_create(on_message, my_context);
 *   oam_bridge_send(bridge, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
 *   ...
 *   oam_bridge_destroy(bridge);
 *
 * MEMORY
 *   - Strings passed IN (json_line, request_json) are borrowed only for the
 *     duration of the call; the bridge copies what it needs. You keep
 *     ownership and may free them as soon as the call returns.
 *   - The json_line passed to your callback is valid ONLY until the callback
 *     returns. Copy it if you need it later. Do not free it.
 *   - oam_call_blocking() returns a heap string you own: release it with
 *     oam_string_free() (not free(), which may use a different allocator
 *     on some hosts).
 *   - oam_version() returns a static string. Do not free it.
 *   - user_data is opaque to the bridge; it must stay valid until
 *     oam_bridge_destroy() returns.
 *
 * THREADING
 *   - All functions may be called from any thread.
 *   - oam_bridge_send() never blocks on model work: it parses the line,
 *     queues it and returns. Requests are handled in the order they were
 *     sent (so you may send session/create and session/respond back to back),
 *     but long requests (session/respond) run concurrently with later ones.
 *   - The callback runs on a background thread owned by the bridge, never
 *     concurrently with itself, and in a well-defined order: for any request,
 *     all of its notifications and tool/call requests arrive before its
 *     response. Engines with a main-thread-only API (Unity, Godot) should
 *     copy the line into a thread-safe queue and process it on the main
 *     thread.
 *   - Keep the callback short. It may call oam_bridge_send() (for example to
 *     answer a tool/call right away); that does not deadlock.
 *   - Do not call oam_call_blocking() from inside the callback.
 *
 * LIFETIME
 *   - oam_bridge_destroy() cancels all running turns and pending tool calls
 *     and waits for an in-flight callback to finish. Once it returns, the
 *     callback is never called again and the handle is invalid.
 *   - Calling oam_bridge_destroy() from inside the callback is allowed; that
 *     callback invocation is the last one.
 *   - Using a handle after oam_bridge_destroy() is undefined behavior, and so is
 *     destroying it while another thread is inside oam_bridge_send() or
 *     oam_call_blocking() with it. Hosts that call from several threads must
 *     make destroy wait for those calls (see oam_call_blocking below).
 *
 * MINIMUM OS
 *   - The library links FoundationModels (OS 27) APIs strongly. Apps must set
 *     their deployment target / minimum OS version to 27.0 (macOS, iOS,
 *     visionOS); with a lower minimum the app crashes at launch on older OS
 *     versions instead of degrading.
 */

#ifndef OPEN_APPLE_MODELS_H
#define OPEN_APPLE_MODELS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque bridge handle. */
typedef struct oam_bridge oam_bridge;

/*
 * Receives every outgoing message: responses to your requests, notifications
 * (session/event, npc/event, world/changed, tool/cancel) and requests from the
 * bridge (tool/call, which you must answer with a JSON-RPC response via
 * oam_bridge_send()).
 *
 * json_line: one line of UTF-8 JSON, valid only during the call.
 * user_data: the pointer given to oam_bridge_create().
 */
typedef void (*oam_message_callback)(const char *json_line, void *user_data);

/* Return codes of oam_bridge_send(). */
#define OAM_OK 0
#define OAM_ERROR_INVALID_ARGUMENT (-1) /* NULL bridge or json_line */
#define OAM_ERROR_INVALID_UTF8 (-2)     /* json_line is not valid UTF-8 */

/*
 * Creates a bridge. Returns NULL if callback is NULL.
 * Diagnostics can be printed to stderr by setting the environment variable
 * OAM_BRIDGE_LOG to debug, info, warning or error.
 */
oam_bridge *oam_bridge_create(oam_message_callback callback, void *user_data);

/*
 * Sends one JSON-RPC message (request, notification, or response to a
 * tool/call) to the bridge. Non-blocking. Returns OAM_OK when the message was
 * accepted; malformed JSON is reported asynchronously as a JSON-RPC error
 * (-32700) through the callback, not through the return value.
 */
int oam_bridge_send(oam_bridge *bridge, const char *json_line);

/*
 * Cancels all work and releases the bridge. After it returns, the callback is
 * never called again. NULL is ignored.
 */
void oam_bridge_destroy(oam_bridge *bridge);

/* The library version, e.g. "0.1.0". Static storage; do not free. */
const char *oam_version(void);

/*
 * Convenience for simple request/response use: sends request_json (a JSON-RPC
 * request; "jsonrpc" and "id" are optional) and blocks the calling thread
 * until its response is ready or timeout_ms elapses (timeout_ms <= 0 waits
 * forever). Returns the JSON-RPC response line, which you must release with
 * oam_string_free(). On timeout the request is cancelled and an error
 * response with code -32024 ("timeout") is returned. Returns NULL only if
 * bridge or request_json is NULL.
 *
 * Notifications (streaming) and tool/call requests caused by the request
 * still go to the callback, with request_json's "id" as their "requestId"
 * (give each call a distinct id to tell them apart). Do not use this for
 * sessions with client tools unless another thread answers tool/call
 * requests, and never call it from inside the callback.
 *
 * Do not call oam_bridge_destroy() while another thread is inside this call:
 * guard the handle (bindings count calls in flight, send
 * {"jsonrpc":"2.0","method":"shutdown"} to cancel them, wait, then destroy).
 */
char *oam_call_blocking(oam_bridge *bridge, const char *request_json, int timeout_ms);

/* Frees a string returned by oam_call_blocking(). NULL is ignored. */
void oam_string_free(char *string);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OPEN_APPLE_MODELS_H */
