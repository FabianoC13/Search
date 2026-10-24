// One tab's browser, and the contexts that keep pages' cookies.
//
// A page is one allocation holding CEF's client and every handler it
// hands out, all sharing one count: CEF keeps the client and handlers for
// as long as the browser lives, and the page keeps a reference of its own
// until the browser has gone and Swift has been told (`closed`).
//
// The browser's view sits inside the view Swift gives (the container,
// which the tab's stage moves between windows), and goes with it: closing
// takes the view out of the container, and Chromium destroys a browser
// whose view is freed. do_close always says "handled", because the
// alternative is Chromium closing the window the view is in — Search's.

#import <AppKit/AppKit.h>
#include <stdatomic.h>
#include <string.h>

#include "glue.h"
#include "include/capi/cef_audio_handler_capi.h"
#include "include/capi/cef_callback_capi.h"
#include "include/capi/cef_cookie_capi.h"
#include "include/capi/cef_focus_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_navigation_entry_capi.h"
#include "include/capi/cef_request_capi.h"
#include "include/capi/cef_request_handler_capi.h"

// MARK: - Contexts

struct chromium_context {
    /// Made when a page first needs it, since Chromium must be up first.
    cef_request_context_t *context;
    /// Its own folder; empty for memory only. NULL for the global context.
    char *cache;
    int global, dead;
    /// Swift's, plus one for each page waiting to be made with it.
    int holds;
    struct chromium_context *next;
};

static struct chromium_context global = {.global = 1, .holds = 1};
static struct chromium_context *contexts;

chromium_context *chromium_context_global(void) {
    return glue_running() ? &global : NULL;
}

chromium_context *chromium_context_make(const char *cache) {
    if (!glue_running()) return NULL;
    struct chromium_context *made = calloc(1, sizeof *made);
    made->cache = strdup(cache ? cache : "");
    made->holds = 1;
    made->next = contexts;
    contexts = made;
    return made;
}

static void context_hold(struct chromium_context *context) {
    if (context && !context->global) context->holds++;
}

static void context_let_go(struct chromium_context *context) {
    if (!context || context->global || --context->holds > 0) return;
    for (struct chromium_context **link = &contexts; *link; link = &(*link)->next) {
        if (*link != context) continue;
        *link = context->next;
        break;
    }
    if (!context->dead) GLUE_RELEASE(context->context);
    free(context->cache);
    free(context);
}

void chromium_context_drop(chromium_context *context) {
    context_let_go(context);
}

/// A new reference to CEF's context, for a browser to take.
static cef_request_context_t *context_take(struct chromium_context *context) {
    if (!context || context->dead) return NULL;
    if (!context->context) {
        if (context->global) {
            context->context = cef_request_context_get_global_context();
        } else {
            cef_request_context_settings_t settings = {0};
            settings.size = sizeof settings;
            glue_set(&settings.cache_path, context->cache);
            settings.persist_session_cookies = 1;
            context->context = cef_request_context_create_context(&settings, NULL);
            cef_string_utf16_clear(&settings.cache_path);
        }
    }
    if (context->context) GLUE_ADD_REF(context->context);
    return context->context;
}

// Cookies are written to disk a while after they change; on the way out
// they are written at once, or a sign-in made just before quitting is lost.
static cef_completion_callback_t flushed;
static int flushing;

static void CEF_CALLBACK flush_done(cef_completion_callback_t *self) {
    flushing--;
}

static void flush(struct chromium_context *context) {
    if (!context->context || context->dead) return;
    cef_cookie_manager_t *cookies = context->context->get_cookie_manager(context->context, NULL);
    if (!cookies) return;
    flushing++;
    GLUE_ADD_REF(&flushed);
    if (!cookies->flush_store(cookies, &flushed)) flushing--;
    GLUE_RELEASE(cookies);
}

void glue_contexts_flush(void) {
    glue_forever(&flushed.base, sizeof flushed);
    flushed.on_complete = flush_done;
    flush(&global);
    for (struct chromium_context *context = contexts; context; context = context->next) {
        if (context->cache && context->cache[0]) flush(context);
    }
}

int glue_contexts_flushing(void) {
    return flushing;
}

void glue_contexts_stop(void) {
    GLUE_RELEASE(global.context);
    global.context = NULL;
    global.dead = 1;
    for (struct chromium_context *context = contexts; context; context = context->next) {
        GLUE_RELEASE(context->context);
        context->context = NULL;
        context->dead = 1;
    }
}

// MARK: - Pages

enum { WAITING, MAKING, LIVE, CLOSED };

struct script {
    char *code;
    struct script *next;
};

struct chromium_page {
    cef_client_t client;
    cef_life_span_handler_t life;
    cef_display_handler_t display;
    cef_load_handler_t load;
    cef_request_handler_t request;
    cef_download_handler_t download;
    cef_audio_handler_t audio;
    cef_focus_handler_t focus;
    atomic_int refs;

    chromium_events events;
    /// The container, kept until the browser is gone.
    void *view;
    /// Until the browser is asked for.
    struct chromium_context *context;
    char *url;
    /// From on_after_created to on_before_close.
    cef_browser_t *browser;
    int state;
    /// chromium_page_close was called: nothing but `closed` goes to Swift.
    int asked;
    /// do_close has been and gone; only the view is left to take away.
    int doomed;
    int ended, audible;
    /// The main frame's address as last told, so it is told once.
    char *address;

    // What waits for the browser.
    char *open;
    struct script *scripts, **last;
    double zoom;
    int zoomed, muted, focus_wanted, inspect_wanted, print_wanted;

    uint32_t *reported;
    int reported_count;

    struct chromium_page *next;
};

static chromium_page *waiting, **waiting_end = &waiting;
static int making;

static void dress(chromium_page *page);

static void page_free(chromium_page *page) {
    free(page->url);
    free(page->address);
    free(page->open);
    for (struct script *script = page->scripts, *next; script; script = next) {
        next = script->next;
        free(script->code);
        free(script);
    }
    free(page->reported);
    free(page);
}

static int page_release(chromium_page *page) {
    if (atomic_fetch_sub(&page->refs, 1) != 1) return 0;
    page_free(page);
    return 1;
}

#define PAGE_OF(object, member) ((chromium_page *)((char *)(object) - offsetof(chromium_page, member)))

// Each structure's count is the page's.
#define COUNTED(member)                                                                     \
    static void CEF_CALLBACK member##_add_ref(cef_base_ref_counted_t *self) {               \
        atomic_fetch_add(&PAGE_OF(self, member)->refs, 1);                                  \
    }                                                                                       \
    static int CEF_CALLBACK member##_release(cef_base_ref_counted_t *self) {                \
        return page_release(PAGE_OF(self, member));                                         \
    }                                                                                       \
    static int CEF_CALLBACK member##_one(cef_base_ref_counted_t *self) {                    \
        return atomic_load(&PAGE_OF(self, member)->refs) == 1;                              \
    }                                                                                       \
    static int CEF_CALLBACK member##_some(cef_base_ref_counted_t *self) {                   \
        return atomic_load(&PAGE_OF(self, member)->refs) > 0;                               \
    }                                                                                       \
    static void member##_count(chromium_page *page) {                                       \
        cef_base_ref_counted_t *base = (cef_base_ref_counted_t *)&page->member;             \
        base->size = sizeof page->member;                                                   \
        base->add_ref = member##_add_ref;                                                   \
        base->release = member##_release;                                                   \
        base->has_one_ref = member##_one;                                                   \
        base->has_at_least_one_ref = member##_some;                                         \
    }

COUNTED(client)
COUNTED(life)
COUNTED(display)
COUNTED(load)
COUNTED(request)
COUNTED(download)
COUNTED(audio)
COUNTED(focus)

/// Tells Swift, unless Swift has closed the page.
#define EMIT(page, name, ...)                                                               \
    do {                                                                                    \
        if (!(page)->asked && (page)->events.name) (page)->events.name((page)->events.context, ##__VA_ARGS__); \
    } while (0)

static cef_browser_host_t *page_host(chromium_page *page) {
    return page->browser ? page->browser->get_host(page->browser) : NULL;
}

static cef_frame_t *page_frame(chromium_page *page) {
    return page->browser ? page->browser->get_main_frame(page->browser) : NULL;
}

static int is_main(cef_frame_t *frame) {
    return frame && frame->is_main(frame);
}

/// The page is over: Swift is told, and lets go of it.
static void page_end(chromium_page *page) {
    if (page->ended) return;
    page->ended = 1;
    page->state = CLOSED;
    if (page->events.closed) page->events.closed(page->events.context);
    if (page->view) CFRelease((CFTypeRef)page->view);
    page->view = NULL;
    context_let_go(page->context);
    page->context = NULL;
    page_release(page);
}

/// Takes the browser's view out of the container, which frees it, and
/// with it the browser. At the next turn, never inside Chromium's call.
static void page_dismantle(chromium_page *page) {
    cef_browser_host_t *host = page_host(page);
    if (!host) return;
    NSView *view = (__bridge NSView *)host->get_window_handle(host);
    GLUE_RELEASE(host);
    if (!view) return;
    glue_later(^{
        [view removeFromSuperview];
    });
}

static void page_create(chromium_page *page) {
    NSView *container = (__bridge NSView *)page->view;
    cef_window_info_t window = {0};
    window.size = sizeof window;
    NSRect bounds = container.bounds;
    window.bounds = (cef_rect_t){0, 0, (int)NSWidth(bounds), (int)NSHeight(bounds)};
    window.parent_view = page->view;
    window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    cef_browser_settings_t settings = {0};
    settings.size = sizeof settings;
    cef_string_t url = {0};
    glue_set(&url, page->url);

    cef_request_context_t *context = context_take(page->context);
    context_let_go(page->context);
    page->context = NULL;
    page->state = MAKING;
    making++;
    // Both references go to Chromium, whether it makes the browser or not.
    client_add_ref(&page->client.base);
    int made = cef_browser_host_create_browser(&window, &page->client, &url, &settings, NULL, context);
    cef_string_utf16_clear(&url);
    if (!made) {
        making--;
        page->state = CLOSED;
        glue_later(^{
            page_end(page);
        });
    }
}

void glue_pages_ready(void) {
    chromium_page *list = waiting;
    waiting = NULL;
    waiting_end = &waiting;
    for (chromium_page *page = list, *next; page; page = next) {
        next = page->next;
        page->next = NULL;
        page_create(page);
    }
}

void glue_pages_stop(void) {
    chromium_page *list = waiting;
    waiting = NULL;
    waiting_end = &waiting;
    for (chromium_page *page = list, *next; page; page = next) {
        next = page->next;
        page_end(page);
    }
}

int glue_pages_making(void) {
    return making;
}

// MARK: Commands

static int page_usable(chromium_page *page) {
    return page && !page->asked && page->state != CLOSED && glue_running();
}

static int page_live(chromium_page *page) {
    return page->state == LIVE && page->browser;
}

static void run_script(chromium_page *page, const char *code) {
    cef_frame_t *frame = page_frame(page);
    if (!frame) return;
    cef_string_t text = {0}, origin = {0};
    glue_set(&text, code);
    frame->execute_java_script(frame, &text, &origin, 0);
    cef_string_utf16_clear(&text);
    GLUE_RELEASE(frame);
}

static void show_inspector(chromium_page *page) {
    cef_browser_host_t *host = page_host(page);
    if (!host) return;
    // A window of its own, Chromium's. Chrome's style, which is what
    // DevTools has to be: asked for Alloy's, Chromium refuses and falls back.
    cef_window_info_t window = {0};
    window.size = sizeof window;
    window.bounds = (cef_rect_t){120, 120, 1100, 760};
    window.runtime_style = CEF_RUNTIME_STYLE_DEFAULT;
    cef_browser_settings_t settings = {0};
    settings.size = sizeof settings;
    cef_client_t *client = glue_loose_client();
    GLUE_ADD_REF(client);
    host->show_dev_tools(host, &window, client, &settings, NULL);
    GLUE_RELEASE(host);
}

void chromium_page_open(chromium_page *page, const char *url) {
    if (!page_usable(page) || !url) return;
    if (!page_live(page)) {
        free(page->open);
        page->open = strdup(url);
        return;
    }
    cef_frame_t *frame = page_frame(page);
    if (!frame) return;
    cef_string_t text = {0};
    glue_set(&text, url);
    frame->load_url(frame, &text);
    cef_string_utf16_clear(&text);
    GLUE_RELEASE(frame);
}

void chromium_page_reload(chromium_page *page, int ignore_cache) {
    if (!page_usable(page) || !page_live(page)) return;
    if (ignore_cache) {
        page->browser->reload_ignore_cache(page->browser);
    } else {
        page->browser->reload(page->browser);
    }
}

void chromium_page_stop(chromium_page *page) {
    if (page_usable(page) && page_live(page)) page->browser->stop_load(page->browser);
}

void chromium_page_back(chromium_page *page) {
    if (page_usable(page) && page_live(page)) page->browser->go_back(page->browser);
}

void chromium_page_forward(chromium_page *page) {
    if (page_usable(page) && page_live(page)) page->browser->go_forward(page->browser);
}

void chromium_page_set_zoom(chromium_page *page, double level) {
    if (!page_usable(page)) return;
    page->zoom = level;
    page->zoomed = 1;
    cef_browser_host_t *host = page_host(page);
    if (!host) return;
    host->set_zoom_level(host, level);
    GLUE_RELEASE(host);
}

double chromium_page_zoom(chromium_page *page) {
    if (!page_usable(page)) return page ? page->zoom : 0;
    cef_browser_host_t *host = page_host(page);
    if (!host) return page->zoom;
    double level = host->get_zoom_level(host);
    GLUE_RELEASE(host);
    return level;
}

void chromium_page_set_muted(chromium_page *page, int muted) {
    if (!page_usable(page)) return;
    page->muted = muted ? 1 : 0;
    cef_browser_host_t *host = page_host(page);
    if (!host) return;
    host->set_audio_muted(host, page->muted);
    GLUE_RELEASE(host);
}

void chromium_page_run(chromium_page *page, const char *script) {
    if (!page_usable(page) || !script) return;
    if (page_live(page)) {
        run_script(page, script);
        return;
    }
    struct script *queued = calloc(1, sizeof *queued);
    queued->code = strdup(script);
    *page->last = queued;
    page->last = &queued->next;
}

void chromium_page_inspect(chromium_page *page) {
    if (!page_usable(page)) return;
    if (page_live(page)) {
        show_inspector(page);
    } else {
        page->inspect_wanted = 1;
    }
}

void chromium_page_print(chromium_page *page) {
    if (!page_usable(page)) return;
    cef_browser_host_t *host = page_host(page);
    if (!host) {
        page->print_wanted = 1;
        return;
    }
    host->print(host);
    GLUE_RELEASE(host);
}

void chromium_page_focus(chromium_page *page) {
    if (!page_usable(page)) return;
    cef_browser_host_t *host = page_host(page);
    if (!host) {
        page->focus_wanted = 1;
        return;
    }
    host->set_focus(host, 1);
    GLUE_RELEASE(host);
}

// Back's address, from the list of entries: the one before the current.
typedef struct {
    cef_navigation_entry_visitor_t visitor;
    atomic_int refs;
    char *previous, *back;
} looking_back;

static void CEF_CALLBACK back_add_ref(cef_base_ref_counted_t *self) {
    atomic_fetch_add(&((looking_back *)self)->refs, 1);
}

static int CEF_CALLBACK back_release(cef_base_ref_counted_t *self) {
    looking_back *looking = (looking_back *)self;
    if (atomic_fetch_sub(&looking->refs, 1) != 1) return 0;
    free(looking->previous);
    free(looking->back);
    free(looking);
    return 1;
}

static int CEF_CALLBACK back_one(cef_base_ref_counted_t *self) {
    return atomic_load(&((looking_back *)self)->refs) == 1;
}

static int CEF_CALLBACK back_some(cef_base_ref_counted_t *self) {
    return atomic_load(&((looking_back *)self)->refs) > 0;
}

static int CEF_CALLBACK back_visit(cef_navigation_entry_visitor_t *self, cef_navigation_entry_t *entry,
                                   int current, int index, int total) {
    looking_back *looking = (looking_back *)self;
    if (current) {
        free(looking->back);
        looking->back = looking->previous;
        looking->previous = NULL;
        GLUE_RELEASE(entry);
        return 0;
    }
    free(looking->previous);
    looking->previous = glue_take(entry->get_url(entry));
    GLUE_RELEASE(entry);
    return 1;
}

char *chromium_page_back_url(chromium_page *page) {
    if (!page_usable(page)) return NULL;
    cef_browser_host_t *host = page_host(page);
    if (!host) return NULL;
    looking_back *looking = calloc(1, sizeof *looking);
    cef_base_ref_counted_t *base = &looking->visitor.base;
    base->size = sizeof looking->visitor;
    base->add_ref = back_add_ref;
    base->release = back_release;
    base->has_one_ref = back_one;
    base->has_at_least_one_ref = back_some;
    looking->visitor.visit = back_visit;
    atomic_store(&looking->refs, 1);
    // On the UI thread, which this is, the entries are visited before the
    // call returns.
    GLUE_ADD_REF(&looking->visitor);
    host->get_navigation_entries(host, &looking->visitor, 0);
    GLUE_RELEASE(host);
    char *back = looking->back && looking->back[0] ? strdup(looking->back) : NULL;
    GLUE_RELEASE(&looking->visitor);
    return back;
}

void chromium_page_close(chromium_page *page) {
    if (!page || page->asked || page->ended) return;
    page->asked = 1;
    switch (page->state) {
    case WAITING:
        for (chromium_page **link = &waiting; *link; link = &(*link)->next) {
            if (*link != page) continue;
            *link = page->next;
            if (!*link) waiting_end = link;
            break;
        }
        glue_later(^{
            page_end(page);
        });
        break;
    case MAKING:
        // on_after_created closes it.
        break;
    case LIVE:
        if (page->doomed) {
            page_dismantle(page);
        } else if (glue_running()) {
            cef_browser_host_t *host = page_host(page);
            if (host) {
                host->close_browser(host, 1);
                GLUE_RELEASE(host);
            }
        }
        break;
    default:
        break;
    }
}

chromium_page *chromium_page_make(void *view, const char *url, chromium_context *context,
                                  const chromium_events *events) {
    if (!glue_running() || !view) return NULL;
    chromium_page *page = calloc(1, sizeof *page);
    client_count(page);
    life_count(page);
    display_count(page);
    load_count(page);
    request_count(page);
    download_count(page);
    audio_count(page);
    focus_count(page);
    atomic_store(&page->refs, 1);
    dress(page);
    if (events) page->events = *events;
    page->view = (void *)CFRetain((CFTypeRef)view);
    page->context = context ? context : chromium_context_global();
    context_hold(page->context);
    page->url = url ? strdup(url) : NULL;
    page->muted = -1;
    page->last = &page->scripts;
    if (glue_ready()) {
        page_create(page);
    } else {
        page->state = WAITING;
        *waiting_end = page;
        waiting_end = &page->next;
    }
    return page;
}

// MARK: - What the browser reports

static cef_life_span_handler_t *CEF_CALLBACK get_life(cef_client_t *self) {
    chromium_page *page = PAGE_OF(self, client);
    life_add_ref(&page->life.base);
    return &page->life;
}

static cef_display_handler_t *CEF_CALLBACK get_display(cef_client_t *self) {
    chromium_page *page = PAGE_OF(self, client);
    display_add_ref(&page->display.base);
    return &page->display;
}

static cef_load_handler_t *CEF_CALLBACK get_load(cef_client_t *self) {
    chromium_page *page = PAGE_OF(self, client);
    load_add_ref(&page->load.base);
    return &page->load;
}

static cef_request_handler_t *CEF_CALLBACK get_request(cef_client_t *self) {
    chromium_page *page = PAGE_OF(self, client);
    request_add_ref(&page->request.base);
    return &page->request;
}

static cef_download_handler_t *CEF_CALLBACK get_download(cef_client_t *self) {
    chromium_page *page = PAGE_OF(self, client);
    download_add_ref(&page->download.base);
    return &page->download;
}

static cef_audio_handler_t *CEF_CALLBACK get_audio(cef_client_t *self) {
    chromium_page *page = PAGE_OF(self, client);
    audio_add_ref(&page->audio.base);
    return &page->audio;
}

static cef_focus_handler_t *CEF_CALLBACK get_focus(cef_client_t *self) {
    chromium_page *page = PAGE_OF(self, client);
    focus_add_ref(&page->focus.base);
    return &page->focus;
}

// MARK: Life

/// What a link that wants somewhere else of its own gets: a tab, a window
/// of Chromium's (window.open with a size, sign-in windows), or nothing.
enum { TAB, BACKGROUND_TAB, POPUP, NOTHING };

static int destination(cef_window_open_disposition_t disposition) {
    switch (disposition) {
    case CEF_WOD_NEW_BACKGROUND_TAB:
        return BACKGROUND_TAB;
    case CEF_WOD_NEW_POPUP:
        return POPUP;
    case CEF_WOD_SAVE_TO_DISK:
    case CEF_WOD_IGNORE_ACTION:
    case CEF_WOD_NEW_PICTURE_IN_PICTURE:
        return NOTHING;
    default:
        return TAB;
    }
}

static int CEF_CALLBACK before_popup(cef_life_span_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                     int popup_id, const cef_string_t *url, const cef_string_t *name,
                                     cef_window_open_disposition_t disposition, int gesture,
                                     const cef_popup_features_t *features, cef_window_info_t *window,
                                     cef_client_t **client, cef_browser_settings_t *settings,
                                     cef_dictionary_value_t **extra, int *no_script) {
    chromium_page *page = PAGE_OF(self, life);
    int cancel = 1;
    int where = gesture ? destination(disposition) : NOTHING;
    // Nothing opens without a click behind it, as Chrome blocks popups.
    if (where == TAB || where == BACKGROUND_TAB) {
        char *text = glue_utf8(url);
        if (text[0]) EMIT(page, tab, text, where == TAB);
        free(text);
    }
    // The client that came in (this page's) is ours to release. A popup's
    // events must never reach this page's tab: it gets a client of its
    // own, in a window of its own, carrying a reference for Chromium.
    cef_client_t *incoming = client ? *client : NULL;
    if (incoming) GLUE_RELEASE(incoming);
    if (where == POPUP && client) {
        cef_client_t *loose = glue_loose_client();
        if (incoming != loose) {
            GLUE_ADD_REF(loose);
            *client = loose;
        }
        cancel = 0;
    }
    if (extra && *extra) GLUE_RELEASE(*extra);
    GLUE_RELEASE(frame);
    GLUE_RELEASE(browser);
    return cancel;
}

static void CEF_CALLBACK after_created(cef_life_span_handler_t *self, cef_browser_t *browser) {
    chromium_page *page = PAGE_OF(self, life);
    making--;
    // The reference it came with is the page's now.
    page->browser = browser;
    page->state = LIVE;
    glue_register(browser);

    cef_browser_host_t *host = browser->get_host(browser);
    if (!host) return;
    // The browser's view fills the container, now and as it changes.
    NSView *view = (__bridge NSView *)host->get_window_handle(host);
    NSView *container = (__bridge NSView *)page->view;
    if (view && container) {
        view.frame = container.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    if (page->asked || !glue_running()) {
        host->close_browser(host, 1);
        GLUE_RELEASE(host);
        return;
    }

    if (page->open) {
        char *url = page->open;
        page->open = NULL;
        chromium_page_open(page, url);
        free(url);
    }
    if (page->zoomed) host->set_zoom_level(host, page->zoom);
    if (page->muted >= 0) host->set_audio_muted(host, page->muted);
    for (struct script *script = page->scripts, *next; script; script = next) {
        next = script->next;
        run_script(page, script->code);
        free(script->code);
        free(script);
    }
    page->scripts = NULL;
    page->last = &page->scripts;
    if (page->focus_wanted) host->set_focus(host, 1);
    if (page->print_wanted) host->print(host);
    if (page->inspect_wanted) show_inspector(page);
    page->focus_wanted = page->print_wanted = page->inspect_wanted = 0;
    GLUE_RELEASE(host);
    EMIT(page, created);
}

static int CEF_CALLBACK do_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    chromium_page *page = PAGE_OF(self, life);
    page->doomed = 1;
    if (page->asked || !glue_running()) {
        page_dismantle(page);
    } else {
        // The page called window.close(): its tab decides, and closes it.
        EMIT(page, close);
    }
    GLUE_RELEASE(browser);
    return 1;
}

static void CEF_CALLBACK before_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    chromium_page *page = PAGE_OF(self, life);
    glue_unregister(browser);
    GLUE_RELEASE(page->browser);
    page->browser = NULL;
    GLUE_RELEASE(browser);
    page_end(page);
}

// MARK: Display

/// Takes `text`. Told when it changes only: it comes both from here and
/// with each new document.
static void tell_address(chromium_page *page, char *text) {
    if (!text[0] || (page->address && strcmp(page->address, text) == 0)) {
        free(text);
        return;
    }
    free(page->address);
    page->address = text;
    EMIT(page, address, text);
}

static void CEF_CALLBACK address_change(cef_display_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                        const cef_string_t *url) {
    chromium_page *page = PAGE_OF(self, display);
    if (is_main(frame)) tell_address(page, glue_utf8(url));
    GLUE_RELEASE(frame);
    GLUE_RELEASE(browser);
}

static void CEF_CALLBACK title_change(cef_display_handler_t *self, cef_browser_t *browser,
                                      const cef_string_t *title) {
    chromium_page *page = PAGE_OF(self, display);
    char *text = glue_utf8(title);
    EMIT(page, title, text);
    free(text);
    GLUE_RELEASE(browser);
}

static void CEF_CALLBACK favicons_change(cef_display_handler_t *self, cef_browser_t *browser,
                                         cef_string_list_t list) {
    chromium_page *page = PAGE_OF(self, display);
    int count = list ? (int)cef_string_list_size(list) : 0;
    char **urls = calloc(count ? count : 1, sizeof *urls);
    for (int i = 0; i < count; i++) {
        cef_string_t value = {0};
        cef_string_list_value(list, i, &value);
        urls[i] = glue_utf8(&value);
        cef_string_utf16_clear(&value);
    }
    EMIT(page, icons, (const char *const *)urls, count);
    for (int i = 0; i < count; i++) free(urls[i]);
    free(urls);
    GLUE_RELEASE(browser);
}

static void CEF_CALLBACK fullscreen_change(cef_display_handler_t *self, cef_browser_t *browser, int on) {
    chromium_page *page = PAGE_OF(self, display);
    EMIT(page, fullscreen, on);
    GLUE_RELEASE(browser);
}

static void CEF_CALLBACK status_message(cef_display_handler_t *self, cef_browser_t *browser,
                                        const cef_string_t *value) {
    chromium_page *page = PAGE_OF(self, display);
    char *text = glue_utf8(value);
    EMIT(page, hover, text[0] ? text : NULL);
    free(text);
    GLUE_RELEASE(browser);
}

static void CEF_CALLBACK progress_change(cef_display_handler_t *self, cef_browser_t *browser, double progress) {
    chromium_page *page = PAGE_OF(self, display);
    EMIT(page, progress, progress);
    GLUE_RELEASE(browser);
}

// MARK: Load

static void CEF_CALLBACK loading_change(cef_load_handler_t *self, cef_browser_t *browser, int loading, int back,
                                        int forward) {
    chromium_page *page = PAGE_OF(self, load);
    EMIT(page, loading, loading, back, forward);
    GLUE_RELEASE(browser);
}

static void quiet(chromium_page *page) {
    if (!page->audible) return;
    page->audible = 0;
    EMIT(page, audible, 0);
}

static void CEF_CALLBACK load_start(cef_load_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                    cef_transition_type_t transition) {
    chromium_page *page = PAGE_OF(self, load);
    if (is_main(frame)) {
        quiet(page);
        // A page brought back from the back-forward cache says where it
        // is only after it has finished loading; the tab hears it first.
        tell_address(page, glue_take(frame->get_url(frame)));
        EMIT(page, committed);
    }
    GLUE_RELEASE(frame);
    GLUE_RELEASE(browser);
}

static void CEF_CALLBACK load_end(cef_load_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                  int status) {
    chromium_page *page = PAGE_OF(self, load);
    if (is_main(frame)) EMIT(page, finished, status);
    GLUE_RELEASE(frame);
    GLUE_RELEASE(browser);
}

static void CEF_CALLBACK load_error(cef_load_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                    cef_errorcode_t code, const cef_string_t *text, const cef_string_t *url) {
    chromium_page *page = PAGE_OF(self, load);
    // ERR_ABORTED is a navigation stopped or replaced, not a failure.
    if (is_main(frame) && code != ERR_ABORTED) {
        char *why = glue_utf8(text), *where = glue_utf8(url);
        EMIT(page, failed, (int)code, why, where);
        free(why);
        free(where);
    }
    GLUE_RELEASE(frame);
    GLUE_RELEASE(browser);
}

// MARK: Requests

/// Schemes Chromium shows itself; anything else belongs to another app.
static int is_web(const char *url) {
    const char *colon = strchr(url, ':');
    if (!colon) return 1;
    size_t length = (size_t)(colon - url);
    static const char *const schemes[] = {
        "http", "https", "about", "data", "blob", "file", "filesystem", "javascript", "view-source",
        "ws", "wss", "chrome", "chrome-error", "chrome-untrusted", "chrome-extension", "devtools",
    };
    for (size_t i = 0; i < sizeof schemes / sizeof *schemes; i++) {
        if (strlen(schemes[i]) == length && strncasecmp(url, schemes[i], length) == 0) return 1;
    }
    return 0;
}

static int CEF_CALLBACK before_browse(cef_request_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                      cef_request_t *request, int gesture, int redirect) {
    char *url = glue_take(request->get_url(request));
    int cancel = 0;
    if (url[0] && !is_web(url)) {
        cancel = 1;
        // mailto:, tel:, an app's own links: handed to macOS when the page
        // itself goes there or somebody clicked, never from a frame on its
        // own.
        if (is_main(frame) || gesture) {
            NSString *text = [NSString stringWithUTF8String:url];
            glue_later(^{
                NSURL *link = text ? [NSURL URLWithString:text] : nil;
                if (link) [[NSWorkspace sharedWorkspace] openURL:link];
            });
        }
    }
    free(url);
    GLUE_RELEASE(request);
    GLUE_RELEASE(frame);
    GLUE_RELEASE(browser);
    return cancel;
}

static int CEF_CALLBACK open_from_tab(cef_request_handler_t *self, cef_browser_t *browser, cef_frame_t *frame,
                                      const cef_string_t *url, cef_window_open_disposition_t disposition,
                                      int gesture) {
    chromium_page *page = PAGE_OF(self, request);
    int cancel = 0;
    // ⌘-click, middle-click, shift-click.
    if (disposition == CEF_WOD_NEW_FOREGROUND_TAB || disposition == CEF_WOD_NEW_BACKGROUND_TAB ||
        disposition == CEF_WOD_NEW_WINDOW) {
        char *text = glue_utf8(url);
        if (text[0]) EMIT(page, tab, text, disposition != CEF_WOD_NEW_BACKGROUND_TAB);
        free(text);
        cancel = 1;
    }
    GLUE_RELEASE(frame);
    GLUE_RELEASE(browser);
    return cancel;
}

static void CEF_CALLBACK process_gone(cef_request_handler_t *self, cef_browser_t *browser,
                                      cef_termination_status_t status, int code, const cef_string_t *text) {
    chromium_page *page = PAGE_OF(self, request);
    quiet(page);
    EMIT(page, gone, (int)status);
    GLUE_RELEASE(browser);
}

// MARK: Downloads, sound and focus

static int reported(chromium_page *page, uint32_t id) {
    for (int i = 0; i < page->reported_count; i++) {
        if (page->reported[i] == id) return 1;
    }
    page->reported = realloc(page->reported, sizeof *page->reported * (page->reported_count + 1));
    page->reported[page->reported_count++] = id;
    return 0;
}

static void CEF_CALLBACK download_updated(cef_download_handler_t *self, cef_browser_t *browser,
                                          cef_download_item_t *item, cef_download_item_callback_t *callback) {
    chromium_page *page = PAGE_OF(self, download);
    if (item->is_complete(item) && !reported(page, item->get_id(item))) {
        char *file = glue_take(item->get_full_path(item));
        char *source = glue_take(item->get_url(item));
        if (file[0]) EMIT(page, downloaded, file, source[0] ? source : NULL);
        free(file);
        free(source);
    }
    GLUE_RELEASE(callback);
    GLUE_RELEASE(item);
    GLUE_RELEASE(browser);
}

static int CEF_CALLBACK audio_parameters(cef_audio_handler_t *self, cef_browser_t *browser,
                                         cef_audio_parameters_t *parameters) {
    // Asked each time the page starts to make sound, to capture it. Saying
    // no leaves the sound going to the speakers, and the asking still says
    // it started.
    chromium_page *page = PAGE_OF(self, audio);
    if (!page->audible) {
        page->audible = 1;
        EMIT(page, audible, 1);
    }
    GLUE_RELEASE(browser);
    return 0;
}

static void CEF_CALLBACK got_focus(cef_focus_handler_t *self, cef_browser_t *browser) {
    chromium_page *page = PAGE_OF(self, focus);
    EMIT(page, touched);
    GLUE_RELEASE(browser);
}

static void dress(chromium_page *page) {
    page->client.get_life_span_handler = get_life;
    page->client.get_display_handler = get_display;
    page->client.get_load_handler = get_load;
    page->client.get_request_handler = get_request;
    page->client.get_download_handler = get_download;
    page->client.get_audio_handler = get_audio;
    page->client.get_focus_handler = get_focus;

    page->life.on_before_popup = before_popup;
    page->life.on_after_created = after_created;
    page->life.do_close = do_close;
    page->life.on_before_close = before_close;

    page->display.on_address_change = address_change;
    page->display.on_title_change = title_change;
    page->display.on_favicon_urlchange = favicons_change;
    page->display.on_fullscreen_mode_change = fullscreen_change;
    page->display.on_status_message = status_message;
    page->display.on_loading_progress_change = progress_change;

    page->load.on_loading_state_change = loading_change;
    page->load.on_load_start = load_start;
    page->load.on_load_end = load_end;
    page->load.on_load_error = load_error;

    page->request.on_before_browse = before_browse;
    page->request.on_open_urlfrom_tab = open_from_tab;
    page->request.on_render_process_terminated = process_gone;

    page->download.can_download = glue_can_download;
    page->download.on_before_download = glue_before_download;
    page->download.on_download_updated = download_updated;

    page->audio.get_audio_parameters = audio_parameters;

    page->focus.on_got_focus = got_focus;
}
