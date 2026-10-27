// The framework, opened at run time: Search links nothing of Chromium's, so
// a copy that never turns it on never loads a byte of it, and one that does
// can find it outside the app, in the add-on.
//
// CEF ships a loader of its own (libcef_dll_dylib.cc) that looks up all of
// its four hundred functions. This one looks up the few Search calls, and
// defines each under CEF's own name, so the vendored headers' declarations
// are the ones the rest of the code calls through. The helper apps use it
// too (Chromium/helper.c), so it is plain C and nothing else.

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#include "include/cef_api_hash.h"
#include "include/cef_version.h"
#include "include/cef_version_info.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_values_capi.h"
#include "include/internal/cef_string_list.h"

#include "CChromium.h"

int chromium_loaded(void);

// Each function Search calls: its return type, name, parameters and the
// arguments to pass them on.
#define CHROMIUM_FUNCTIONS(F, V)                                                              \
    F(int, cef_api_version, (void), ())                                                       \
    F(const char *, cef_version_full, (void), ())                                             \
    F(int, cef_execute_process,                                                               \
      (const cef_main_args_t *args, cef_app_t *application, void *windows_sandbox_info),      \
      (args, application, windows_sandbox_info))                                              \
    F(int, cef_initialize,                                                                    \
      (const cef_main_args_t *args, const struct _cef_settings_t *settings,                   \
       cef_app_t *application, void *windows_sandbox_info),                                   \
      (args, settings, application, windows_sandbox_info))                                    \
    V(cef_shutdown, (void), ())                                                               \
    V(cef_do_message_loop_work, (void), ())                                                   \
    F(int, cef_browser_host_create_browser,                                                   \
      (const cef_window_info_t *windowInfo, struct _cef_client_t *client,                     \
       const cef_string_t *url, const struct _cef_browser_settings_t *settings,               \
       struct _cef_dictionary_value_t *extra_info,                                            \
       struct _cef_request_context_t *request_context),                                       \
      (windowInfo, client, url, settings, extra_info, request_context))                       \
    F(cef_request_context_t *, cef_request_context_get_global_context, (void), ())            \
    F(cef_request_context_t *, cef_request_context_create_context,                            \
      (const struct _cef_request_context_settings_t *settings,                                \
       struct _cef_request_context_handler_t *handler),                                       \
      (settings, handler))                                                                    \
    F(int, cef_string_utf8_to_utf16, (const char *src, size_t src_len, cef_string_utf16_t *output), \
      (src, src_len, output))                                                                 \
    F(int, cef_string_utf16_to_utf8,                                                          \
      (const char16_t *src, size_t src_len, cef_string_utf8_t *output),                       \
      (src, src_len, output))                                                                 \
    V(cef_string_utf16_clear, (cef_string_utf16_t * str), (str))                              \
    V(cef_string_utf8_clear, (cef_string_utf8_t * str), (str))                                \
    V(cef_string_userfree_utf16_free, (cef_string_userfree_utf16_t str), (str))               \
    F(cef_value_t *, cef_value_create, (void), ())                                            \
    F(cef_dictionary_value_t *, cef_dictionary_value_create, (void), ())                      \
    F(size_t, cef_string_list_size, (cef_string_list_t list), (list))                         \
    F(int, cef_string_list_value, (cef_string_list_t list, size_t index, cef_string_t *value), \
      (list, index, value))

#define POINTER(type, name, params, args) static type(*p_##name) params;
#define POINTER_VOID(name, params, args) static void(*p_##name) params;
CHROMIUM_FUNCTIONS(POINTER, POINTER_VOID)
static const char *(*p_cef_api_hash)(int version, int entry);

static void *library;

static int fail(char *error, size_t size, const char *why, const char *detail) {
    if (error && size) snprintf(error, size, "%s%s%s", why, detail ? ": " : "", detail ? detail : "");
    return 0;
}

int chromium_load(const char *binary, char *error, size_t size) {
    if (library) return 1;
    // Local, so its symbols never stand in for anybody else's; first, so a
    // name it doesn't define isn't looked for in what it links.
    void *handle = dlopen(binary, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    if (!handle) return fail(error, size, "Chromium's framework didn't load", dlerror());

    // The API hash first, exactly as libcef_dll_wrapper.cc checks it: the
    // first call also tells the framework which version of its API these
    // headers speak, and a framework that hashes it differently lays out
    // its structures differently, so nothing else in it may be called.
    p_cef_api_hash = (const char *(*)(int, int))dlsym(handle, "cef_api_hash");
    if (!p_cef_api_hash) return fail(error, size, "Chromium's framework has no API hash", NULL);
    const char *hash = p_cef_api_hash(CEF_API_VERSION, 0);
    if (!hash || strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
        p_cef_api_hash = NULL;
        return fail(error, size, "This Chromium speaks a different version of its API than Search", hash);
    }

#define LOOKUP(type, name, params, args)                                                \
    p_##name = (type(*) params)dlsym(handle, #name);                                    \
    if (!p_##name) return fail(error, size, "Chromium's framework lacks " #name, NULL);
#define LOOKUP_VOID(name, params, args)                                                 \
    p_##name = (void(*) params)dlsym(handle, #name);                                    \
    if (!p_##name) return fail(error, size, "Chromium's framework lacks " #name, NULL);
    CHROMIUM_FUNCTIONS(LOOKUP, LOOKUP_VOID)

    if (p_cef_api_version() != CEF_API_VERSION) {
        return fail(error, size, "Chromium didn't take the API version Search asked for", NULL);
    }
    library = handle;
    return 1;
}

int chromium_loaded(void) {
    return library != NULL;
}

const char *chromium_version(void) {
    return library ? p_cef_version_full() : "";
}

const char *chromium_pinned_version(void) {
    return CEF_VERSION;
}

// CEF's own names, passed on.
const char *cef_api_hash(int version, int entry) {
    return p_cef_api_hash(version, entry);
}

#define FORWARD(type, name, params, args) type name params { return p_##name args; }
#define FORWARD_VOID(name, params, args) void name params { p_##name args; }
CHROMIUM_FUNCTIONS(FORWARD, FORWARD_VOID)
