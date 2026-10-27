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
    /// More switches for the browser process, each "name" or "name=value"
    /// without its dashes. disable-features and enable-features join the
    /// lists already there rather than replacing them.
    const char *const *switches;
    int switch_count;
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

/// A tool is driving pages over DevTools (see DevToolsBridge.swift). While
/// one is, the menus and file panels a page opens appear only for real
/// input, a key a tool sends never reaches the app's menus, and popups need
/// no click behind them.
void chromium_set_automation(int on);

/// Seconds since the last real input of a kind, as AppKit delivered it —
/// never input a DevTools client sent. A very large number when there was
/// none.
enum {
    CHROMIUM_REAL_MOUSE = 0,
    CHROMIUM_REAL_RIGHT = 1,
    CHROMIUM_REAL_KEY = 2,
};
double chromium_real_input_age(int kind);

/// Where a page keeps its cookies and storage.
typedef struct chromium_context chromium_context;
chromium_context *chromium_context_global(void);
/// One of its own, kept in `cache` (which must be inside the root), or in
/// memory when `cache` is NULL or empty.
chromium_context *chromium_context_make(const char *cache);
/// Lets go of it; pages already using it keep it until they close.
void chromium_context_drop(chromium_context *context);
/// Every page of `context` goes through a proxy: `server` such as
/// "http://host:3128" or "socks5://host:1080", `bypass` a list of hosts
/// separated by commas, or NULL. Not the global context. 1 when set.
int chromium_context_set_proxy(chromium_context *context, const char *server, const char *bypass);
/// What a tool granted `origin` in `context` (Browser.grantPermissions), as
/// the site's settings, so its pages see it before they ask: the
/// permissions named granted — DevTools' names (Browser.PermissionType),
/// such as "geolocation" or "videoCapture" — and every other one that is a
/// setting refused, as Chrome grants them. `names` NULL puts every one back
/// to the default. Not the global context.
void chromium_context_set_permissions(chromium_context *context, const char *origin, const char *const *names,
                                      int count);

struct chromium_page;

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
    /// The page's DevTools target and its browser context, as tools name
    /// them, once the browser exists, and the browser's own identifier
    /// (what chromium_downloads names it by).
    void (*target)(void *context, const char *target_id, const char *browser_context_id, int browser);
    /// A question from the page: CHROMIUM_DIALOG_*. `text` is a prompt's
    /// default answer; `reload` is for leaving. 1 when Swift asks it and
    /// answers with chromium_page_answer, 0 for Chromium's own dialog.
    int (*dialog)(void *context, int kind, const char *origin, const char *message, const char *text,
                  int reload);
    /// The question was answered elsewhere — by a tool over DevTools, or
    /// taken back by a navigation: put away whatever shows it.
    void (*dialog_gone)(void *context);
    /// The page opens another: a window with `url` (empty for about:blank),
    /// CHROMIUM_POPUP_*. Answered with a page made by chromium_page_make_popup
    /// for Chromium to make the new browser in, or NULL to refuse it.
    struct chromium_page *(*popup)(void *context, const char *url, int kind, int gesture);
    /// A site asks for a permission: `media` 1 for the camera, microphone
    /// or screen (CEF's media bits), 0 for anything else (its permission
    /// bits). 1 grant, 0 deny, -1 Chromium's own answer, 2 asked, to be
    /// answered with chromium_page_permit.
    int (*permission)(void *context, const char *origin, int media, unsigned int kinds);
} chromium_events;

enum {
    CHROMIUM_DIALOG_ALERT = 0,
    CHROMIUM_DIALOG_CONFIRM = 1,
    CHROMIUM_DIALOG_PROMPT = 2,
    CHROMIUM_DIALOG_LEAVE = 3,
};

enum {
    CHROMIUM_POPUP_TAB = 0,
    CHROMIUM_POPUP_BACKGROUND_TAB = 1,
    CHROMIUM_POPUP_WINDOW = 2,
};

typedef struct chromium_page chromium_page;

/// A browser inside `view` (an NSView, kept until the browser is gone),
/// opening `url` (NULL for a blank page). It is made asynchronously;
/// commands sent before `created` wait for it. NULL when Chromium isn't
/// running.
chromium_page *chromium_page_make(void *view, const char *url, chromium_context *context,
                                  const chromium_events *events);
/// A page for a popup, inside `view`, made only from the `popup` event:
/// Chromium makes its browser itself, with the opener's context, so the
/// popup keeps its opener, its POST body and everything else a popup has.
chromium_page *chromium_page_make_popup(void *view, const chromium_events *events);
/// Answers the page's question (the `dialog` event): `ok`, and a prompt's
/// `text` (NULL for none).
void chromium_page_answer(chromium_page *page, int ok, const char *text);
/// Lets go of the page's question without answering it: it was answered
/// elsewhere, by a tool over DevTools.
void chromium_page_forget_question(chromium_page *page);
/// Answers the permission the page asked for (the `permission` event,
/// answered 2): the media request, or the prompt.
void chromium_page_permit(chromium_page *page, int media, int granted);

/// Where a page's downloads go, when something other than Search decides:
/// a tool driving a context of its own (see Automation.swift). By the
/// browser's identifier (the `target` event's) and the download's id.
typedef struct chromium_downloads {
    /// A path to save to (malloc'd; freed here), "" to refuse the
    /// download, or NULL for Search's own choice.
    char *(*begin)(int browser, unsigned int id, const char *url, const char *name);
    /// As it goes: CHROMIUM_DOWNLOAD_*. Nonzero back cancels it (a tool's
    /// Browser.cancelDownload), at the next word of how it goes.
    int (*progress)(int browser, unsigned int id, long long received, long long total, int state);
} chromium_downloads;

enum {
    CHROMIUM_DOWNLOAD_GOING = 0,
    CHROMIUM_DOWNLOAD_DONE = 1,
    CHROMIUM_DOWNLOAD_STOPPED = 2,
};

void chromium_set_downloads(const chromium_downloads *hooks);
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
