#ifndef CCHROMIUM_H
#define CCHROMIUM_H

// What Swift sees of Chromium: plain C, nothing of CEF's. The framework is
// loaded at run time from the add-on (loader.c) and driven through CEF's C
// API (start.m, page.m); its own headers never leave this target.
//
// Everything here is called on the main thread, and every callback arrives
// on it.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The CEF version these headers come from, such as
/// "156.0.8+g426920c+chromium-156.0.8078.48": the only one Search can run,
/// and the name of the add-on's folder.
const char *chromium_pinned_version(void);

/// Opens the framework's binary and checks that the C API it was built with
/// is the one these headers describe, before anything else in it is called.
/// 1 when it is, 0 with the reason in `error` when it isn't. The helper apps
/// call this too.
int chromium_load(const char *binary, char *error, size_t size);

/// The full version the loaded framework reports; empty before loading.
const char *chromium_version(void);

typedef struct chromium_options {
    /// The "Chromium Embedded Framework.framework" folder.
    const char *framework;
    /// The plain helper's executable; its variants sit beside it.
    const char *helper;
    /// The running app's bundle.
    const char *bundle;
    /// Where Chromium keeps everything; `cache`, inside it, is the profile
    /// of the global context.
    const char *root;
    const char *cache;
    const char *log;
    /// Such as "en-GB"; NULL for Chromium's own choice.
    const char *locale;
    /// The keychain item that keeps cookies' encryption key; NULL for
    /// Chromium's own.
    const char *keychain_service;
    const char *keychain_account;
    /// Remote debugging, on 127.0.0.1; 0 for none.
    int port;
    /// Keys in memory instead of the keychain, for test runs.
    int mock_keychain;
    /// Called once Chromium has finished starting; may be NULL.
    void (*ready)(void);
} chromium_options;

/// Starts Chromium and its message pump. Only once in a process, and only
/// after chromium_load.
int chromium_start(const chromium_options *options, char *error, size_t size);

/// Closes every page and popup, waits up to `timeout` seconds for them to
/// go, and stops Chromium for good. Nothing may call into it afterwards;
/// whatever does is ignored.
void chromium_stop(double timeout);

/// Browsers still open: pages, popups and DevTools.
int chromium_open(void);

/// Where a page keeps its cookies and storage.
typedef struct chromium_context chromium_context;
chromium_context *chromium_context_global(void);
/// One of its own, kept in `cache` (which must be inside the root), or in
/// memory when `cache` is NULL or empty.
chromium_context *chromium_context_make(const char *cache);
/// Lets go of it; pages already using it keep it until they close.
void chromium_context_drop(chromium_context *context);

/// What a page reports, to `context`. Strings are UTF-8 and only valid for
/// the call. Any of these may be NULL.
typedef struct chromium_events {
    void *context;
    /// The browser exists, and commands sent so far have been carried out.
    void (*created)(void *context);
    void (*title)(void *context, const char *title);
    /// The main frame's address.
    void (*address)(void *context, const char *url);
    void (*progress)(void *context, double progress);
    void (*loading)(void *context, int loading, int back, int forward);
    /// A new document in the main frame.
    void (*committed)(void *context);
    void (*finished)(void *context, int status);
    /// A net error (net_error_list.h) in the main frame, never ERR_ABORTED.
    void (*failed)(void *context, int code, const char *text, const char *url);
    void (*icons)(void *context, const char *const *urls, int count);
    /// The link under the pointer; NULL when it leaves.
    void (*hover)(void *context, const char *url);
    void (*fullscreen)(void *context, int on);
    void (*gone)(void *context, int status);
    /// A link that asked for a tab of its own.
    void (*tab)(void *context, const char *url, int foreground);
    /// window.close(). The page waits, half closed, for chromium_page_close.
    void (*close)(void *context);
    /// Chromium says when a page starts making sound, never when it stops:
    /// 0 comes only with a new document or a dead process.
    void (*audible)(void *context, int on);
    void (*downloaded)(void *context, const char *file, const char *source);
    void (*touched)(void *context);
    /// The browser is gone. Always the last call, and always made — after
    /// chromium_page_close, the only one.
    void (*closed)(void *context);
} chromium_events;

typedef struct chromium_page chromium_page;

/// A browser inside `view` (an NSView, kept until the browser is gone),
/// opening `url` (NULL for a blank page). It is made asynchronously;
/// commands sent before `created` wait for it. NULL when Chromium isn't
/// running.
chromium_page *chromium_page_make(void *view, const char *url, chromium_context *context,
                                  const chromium_events *events);
void chromium_page_open(chromium_page *page, const char *url);
void chromium_page_reload(chromium_page *page, int ignore_cache);
void chromium_page_stop(chromium_page *page);
void chromium_page_back(chromium_page *page);
void chromium_page_forward(chromium_page *page);
/// Chromium's zoom level: 0 is 100%, each step 20% more or less.
void chromium_page_set_zoom(chromium_page *page, double level);
double chromium_page_zoom(chromium_page *page);
void chromium_page_set_muted(chromium_page *page, int muted);
void chromium_page_run(chromium_page *page, const char *script);
void chromium_page_inspect(chromium_page *page);
void chromium_page_print(chromium_page *page);
void chromium_page_focus(chromium_page *page);
/// Where Back would go, or NULL; free() it.
char *chromium_page_back_url(chromium_page *page);
/// Closes the browser: events stop, `closed` follows once it is gone, and
/// `page` must not be used again.
void chromium_page_close(chromium_page *page);

#ifdef __cplusplus
}
#endif

#endif
