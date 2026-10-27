// Chromium in Search's process: started once, pumped from the main run
// loop, stopped once.
//
// SwiftUI owns the application object, so Chromium can't have the
// NSApplication subclass it expects. What it needs of one is small — to be
// told when an event is being sent, and to find two protocols declared —
// and is added to whatever class NSApp already is, at start, which a
// WebKit run never reaches.
//
// Chromium's work runs on the main thread, when Chromium asks for it
// (on_schedule_message_pump_work) and at least thirty times a second, in
// every run loop mode: a page goes on painting while a menu is open or the
// window is being resized. The scheme is cefclient's
// (main_message_loop_external_pump_mac.mm), written again here in C.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <math.h>
#include <string.h>

#include "glue.h"

// MARK: - Strings and turns

void glue_set(cef_string_t *to, const char *utf8) {
    if (utf8) cef_string_utf8_to_utf16(utf8, strlen(utf8), to);
}

char *glue_utf8(const cef_string_t *from) {
    if (!from || !from->str || from->length == 0) return strdup("");
    cef_string_utf8_t out = {0};
    cef_string_utf16_to_utf8(from->str, from->length, &out);
    char *copy = strndup(out.str ? out.str : "", out.length);
    cef_string_utf8_clear(&out);
    return copy;
}

char *glue_take(cef_string_userfree_t from) {
    if (!from) return strdup("");
    char *copy = glue_utf8(from);
    cef_string_userfree_utf16_free(from);
    return copy;
}

void glue_later(dispatch_block_t block) {
    CFRunLoopRef main = CFRunLoopGetMain();
    CFRunLoopPerformBlock(main, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(main);
}

static void CEF_CALLBACK forever_add_ref(cef_base_ref_counted_t *self) {}
static int CEF_CALLBACK forever_release(cef_base_ref_counted_t *self) { return 0; }
static int CEF_CALLBACK forever_one(cef_base_ref_counted_t *self) { return 1; }
static int CEF_CALLBACK forever_some(cef_base_ref_counted_t *self) { return 1; }

void glue_forever(cef_base_ref_counted_t *base, size_t size) {
    base->size = size;
    base->add_ref = forever_add_ref;
    base->release = forever_release;
    base->has_one_ref = forever_one;
    base->has_at_least_one_ref = forever_some;
}

// MARK: - The application object

// Whether NSApp is inside -sendEvent:, which Chromium asks before it runs
// nested loops of its own (menus, drags) and sets around events it sends.
static BOOL sending;
static IMP sent;

static BOOL is_handling_send_event(id self, SEL command) {
    return sending;
}

static void set_handling_send_event(id self, SEL command, BOOL value) {
    sending = value;
}

// MARK: - Real input

// What AppKit delivered last, of each kind: the person's own input. What a
// tool sends over DevTools goes straight to the page and never passes here,
// so a menu or a panel that opens with none of this just before it was
// opened by a tool (see chromium_set_automation).
static CFAbsoluteTime real_mouse = -1e9, real_right = -1e9, real_key = -1e9;
static NSTimeInterval real_key_stamp = -1;
static unsigned short real_key_code;

static void note_real(NSEvent *event) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    switch (event.type) {
    case NSEventTypeRightMouseDown:
        real_mouse = real_right = now;
        break;
    case NSEventTypeLeftMouseDown:
        real_mouse = now;
        // A control-click is a right click on a Mac.
        if (event.modifierFlags & NSEventModifierFlagControl) real_right = now;
        break;
    case NSEventTypeOtherMouseDown:
        real_mouse = now;
        break;
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp:
    case NSEventTypeFlagsChanged:
        real_key = now;
        real_key_stamp = event.timestamp;
        real_key_code = event.keyCode;
        break;
    default:
        break;
    }
}

double glue_real_age(int kind) {
    CFAbsoluteTime when = kind == CHROMIUM_REAL_RIGHT ? real_right : kind == CHROMIUM_REAL_KEY ? real_key : real_mouse;
    return CFAbsoluteTimeGetCurrent() - when;
}

double chromium_real_input_age(int kind) {
    return glue_real_age(kind);
}

int glue_real_key(void *os_event) {
    if (!os_event) return 0;
    NSEvent *event = (__bridge NSEvent *)os_event;
    return event.timestamp == real_key_stamp && event.keyCode == real_key_code;
}

static int automation;

void chromium_set_automation(int on) {
    automation = on ? 1 : 0;
}

int glue_automation(void) {
    return automation;
}

static void send_event(id self, SEL command, NSEvent *event) {
    note_real(event);
    BOOL was = sending;
    sending = YES;
    ((void (*)(id, SEL, NSEvent *))sent)(self, command, event);
    sending = was;
}

static void dress_application(void) {
    NSApplication *app = [NSApplication sharedApplication];
    Class kind = object_getClass(app);
    char getter[16], setter[16];
    snprintf(getter, sizeof getter, "%s%s%s", @encode(BOOL), @encode(id), @encode(SEL));
    snprintf(setter, sizeof setter, "%s%s%s%s", @encode(void), @encode(id), @encode(SEL), @encode(BOOL));
    class_addMethod(kind, sel_registerName("isHandlingSendEvent"), (IMP)is_handling_send_event, getter);
    class_addMethod(kind, sel_registerName("setHandlingSendEvent:"), (IMP)set_handling_send_event, setter);

    // -sendEvent: wrapped, whether the class has its own or inherits it.
    SEL send = @selector(sendEvent:);
    Method method = class_getInstanceMethod(kind, send);
    sent = method_getImplementation(method);
    if (!class_addMethod(kind, send, (IMP)send_event, method_getTypeEncoding(method))) {
        method_setImplementation(method, (IMP)send_event);
    }

    // The framework declares the protocols it checks NSApp against; they
    // are found by name now that it is loaded.
    const char *names[] = {"CrAppProtocol", "CrAppControlProtocol", "CefAppProtocol"};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        Protocol *protocol = objc_getProtocol(names[i]);
        if (protocol) class_addProtocol(kind, protocol);
    }
}

// MARK: - The pump

// What DoWork asks for when Chromium asked for nothing: the next beat.
#define PUMP_BEAT_ASKED INT64_MAX
static const double pump_beat = 1.0 / 30;

static CFRunLoopTimerRef pump_timer;
static int pump_pending, pump_busy, pump_reentered, pump_stopped;

static void pump_work(void);

static void pump_disarm(void) {
    pump_pending = 0;
    if (pump_timer) CFRunLoopTimerSetNextFireDate(pump_timer, CFAbsoluteTimeGetCurrent() + 1.0e9);
}

/// On the main thread: work now, or after `delay` milliseconds, but never
/// later than the next beat.
static void pump_schedule(int64_t delay) {
    if (pump_stopped) return;
    if (delay == PUMP_BEAT_ASKED && pump_pending) return;
    pump_disarm();
    if (delay <= 0) {
        pump_work();
        return;
    }
    double seconds = delay == PUMP_BEAT_ASKED ? pump_beat : fmin(delay / 1000.0, pump_beat);
    CFRunLoopTimerSetNextFireDate(pump_timer, CFAbsoluteTimeGetCurrent() + seconds);
    pump_pending = 1;
}

/// From any thread.
static void pump_ask(int64_t delay) {
    glue_later(^{
        pump_schedule(delay);
    });
}

/// Chromium's work, never inside itself: work asked for from inside is
/// noted and done straight after.
static int pump_perform(void) {
    if (pump_busy) {
        pump_reentered = 1;
        return 0;
    }
    pump_reentered = 0;
    pump_busy = 1;
    cef_do_message_loop_work();
    pump_busy = 0;
    return pump_reentered;
}

static void pump_work(void) {
    if (pump_perform()) {
        pump_ask(0);
    } else if (!pump_pending) {
        pump_ask(PUMP_BEAT_ASKED);
    }
}

static void pump_fired(CFRunLoopTimerRef timer, void *info) {
    pump_pending = 0;
    pump_work();
}

static void pump_start(void) {
    pump_timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1.0e9, 1.0e9, 0, 0, pump_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), pump_timer, kCFRunLoopCommonModes);
}

static void pump_stop(void) {
    pump_stopped = 1;
    if (pump_timer) {
        CFRunLoopTimerInvalidate(pump_timer);
        CFRelease(pump_timer);
        pump_timer = NULL;
    }
}

// MARK: - The app and its browser process

static int started, stopping, stopped, ready, mock_keychain;
static void (*on_ready)(void);
/// chromium_options' switches, kept for before_command_line.
static char **switches;
static int switch_count;

int glue_running(void) {
    return started && !stopping && !stopped;
}

int glue_ready(void) {
    return ready;
}

static cef_app_t app;
static cef_browser_process_handler_t process;

static void append_switch(cef_command_line_t *line, const char *name) {
    cef_string_t text = {0};
    glue_set(&text, name);
    line->append_switch(line, &text);
    cef_string_utf16_clear(&text);
}

/// `name=value`, or `name` alone. A feature list joins the one already
/// there: set again, a switch's value replaces the old one, and CEF keeps
/// features of its own in these.
static void apply_switch(cef_command_line_t *line, const char *given) {
    const char *equals = strchr(given, '=');
    if (!equals) {
        append_switch(line, given);
        return;
    }
    char *name = strndup(given, (size_t)(equals - given));
    const char *value = equals + 1;
    cef_string_t key = {0}, text = {0};
    glue_set(&key, name);
    char *joined = NULL;
    if (strcmp(name, "disable-features") == 0 || strcmp(name, "enable-features") == 0) {
        char *before = line->has_switch(line, &key) ? glue_take(line->get_switch_value(line, &key)) : strdup("");
        if (before[0]) {
            size_t size = strlen(before) + strlen(value) + 2;
            joined = malloc(size);
            snprintf(joined, size, "%s,%s", before, value);
        }
        free(before);
    }
    glue_set(&text, joined ? joined : value);
    line->append_switch_with_value(line, &key, &text);
    cef_string_utf16_clear(&key);
    cef_string_utf16_clear(&text);
    free(joined);
    free(name);
}

static void CEF_CALLBACK before_command_line(cef_app_t *self, const cef_string_t *type,
                                             cef_command_line_t *line) {
    // Only the browser process's: an empty type.
    if (!type || type->length == 0) {
        if (mock_keychain) append_switch(line, "use-mock-keychain");
        for (int i = 0; i < switch_count; i++) apply_switch(line, switches[i]);
    }
    GLUE_RELEASE(line);
}

static cef_browser_process_handler_t *CEF_CALLBACK get_process(cef_app_t *self) {
    return &process;
}

static void CEF_CALLBACK context_initialized(cef_browser_process_handler_t *self) {
    ready = 1;
    glue_pages_ready();
    if (on_ready) on_ready();
}

static void CEF_CALLBACK before_child(cef_browser_process_handler_t *self, cef_command_line_t *line) {
    // A test run's keys stay out of the keychain in every process that
    // might reach for them, the network service's included.
    if (mock_keychain) append_switch(line, "use-mock-keychain");
    GLUE_RELEASE(line);
}

static int CEF_CALLBACK relaunched(cef_browser_process_handler_t *self, cef_command_line_t *line,
                                   const cef_string_t *directory) {
    // Another copy started with the same profile and was turned away; this
    // one carries on as it was rather than open a window of Chromium's.
    GLUE_RELEASE(line);
    return 1;
}

static void CEF_CALLBACK schedule_work(cef_browser_process_handler_t *self, int64_t delay) {
    pump_ask(delay);
}

/// For windows Chromium opens itself with its own interface — a tool's
/// contexts open theirs this way. Given none, such a browser would answer
/// to nobody, and CEF would wait for it to be closed by hand before it
/// could stop.
static cef_client_t *CEF_CALLBACK default_client(cef_browser_process_handler_t *self) {
    cef_client_t *client = glue_loose_client();
    GLUE_ADD_REF(client);
    return client;
}

// MARK: - Browsers Chromium makes for itself

static cef_client_t loose;
static cef_life_span_handler_t loose_life;
static cef_display_handler_t loose_display;
static cef_download_handler_t loose_download;

cef_client_t *glue_loose_client(void) {
    return &loose;
}

static cef_life_span_handler_t *CEF_CALLBACK loose_get_life(cef_client_t *self) {
    return &loose_life;
}

static cef_display_handler_t *CEF_CALLBACK loose_get_display(cef_client_t *self) {
    return &loose_display;
}

static cef_download_handler_t *CEF_CALLBACK loose_get_download(cef_client_t *self) {
    return &loose_download;
}

static int CEF_CALLBACK loose_before_popup(cef_life_span_handler_t *self, cef_browser_t *browser,
                                           cef_frame_t *frame, int popup_id, const cef_string_t *url,
                                           const cef_string_t *name, cef_window_open_disposition_t disposition,
                                           int gesture, const cef_popup_features_t *features,
                                           cef_window_info_t *window, cef_client_t **client,
                                           cef_browser_settings_t *settings, cef_dictionary_value_t **extra,
                                           int *no_script) {
    // A popup's own popups get windows of their own too, with this client
    // — without a click behind them only while a tool drives pages.
    if (client && *client) GLUE_RELEASE(*client);
    if (extra && *extra) GLUE_RELEASE(*extra);
    GLUE_RELEASE(frame);
    GLUE_RELEASE(browser);
    return gesture || glue_automation() ? 0 : 1;
}

static void CEF_CALLBACK loose_created(cef_life_span_handler_t *self, cef_browser_t *browser) {
    glue_register(browser);
    GLUE_RELEASE(browser);
}

static int CEF_CALLBACK loose_do_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    // Its window is Chromium's own, and Chromium closes it.
    GLUE_RELEASE(browser);
    return 0;
}

static void CEF_CALLBACK loose_before_close(cef_life_span_handler_t *self, cef_browser_t *browser) {
    glue_unregister(browser);
    GLUE_RELEASE(browser);
}

static void CEF_CALLBACK loose_title(cef_display_handler_t *self, cef_browser_t *browser,
                                     const cef_string_t *title) {
    cef_browser_host_t *host = browser->get_host(browser);
    if (host) {
        NSView *view = (__bridge NSView *)host->get_window_handle(host);
        char *text = glue_utf8(title);
        NSString *string = [NSString stringWithUTF8String:text];
        if (view.window && string.length) view.window.title = string;
        free(text);
        GLUE_RELEASE(host);
    }
    GLUE_RELEASE(browser);
}

static void dress_loose(void) {
    glue_forever(&loose.base, sizeof loose);
    loose.get_life_span_handler = loose_get_life;
    loose.get_display_handler = loose_get_display;
    loose.get_download_handler = loose_get_download;
    glue_forever(&loose_life.base, sizeof loose_life);
    loose_life.on_before_popup = loose_before_popup;
    loose_life.on_after_created = loose_created;
    loose_life.do_close = loose_do_close;
    loose_life.on_before_close = loose_before_close;
    glue_forever(&loose_display.base, sizeof loose_display);
    loose_display.on_title_change = loose_title;
    glue_forever(&loose_download.base, sizeof loose_download);
    loose_download.can_download = glue_can_download;
    loose_download.on_before_download = glue_before_download;
}

// MARK: - Downloads

// Names given out this run and not yet on disk, so two downloads of the
// same name at once don't share a file.
static NSMutableSet<NSString *> *claimed;

static NSString *download_path(NSString *suggested) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSURL *folder = [[files URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask] firstObject];
    NSString *home = folder.path ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
    [files createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
    // A name, never a path: no separators, nothing hidden.
    NSString *name = [[suggested ?: @"" stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
        stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    while ([name hasPrefix:@"."]) name = [name substringFromIndex:1];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) name = @"Download";
    NSString *stem = name.stringByDeletingPathExtension, *extension = name.pathExtension;
    if (!claimed) claimed = [[NSMutableSet alloc] init];
    for (int count = 1;; count++) {
        NSString *candidate = name;
        if (count > 1) {
            candidate = extension.length ? [NSString stringWithFormat:@"%@ %d.%@", stem, count, extension]
                                         : [NSString stringWithFormat:@"%@ %d", stem, count];
        }
        NSString *path = [home stringByAppendingPathComponent:candidate];
        if (![files fileExistsAtPath:path] && ![claimed containsObject:path]) {
            [claimed addObject:path];
            return path;
        }
    }
}

int glue_can_download(cef_download_handler_t *self, cef_browser_t *browser, const cef_string_t *url,
                      const cef_string_t *method) {
    GLUE_RELEASE(browser);
    return 1;
}

static chromium_downloads downloads;

void chromium_set_downloads(const chromium_downloads *hooks) {
    if (hooks) {
        downloads = *hooks;
    } else {
        memset(&downloads, 0, sizeof downloads);
    }
}

const chromium_downloads *glue_downloads(void) {
    return &downloads;
}

int glue_before_download(cef_download_handler_t *self, cef_browser_t *browser, cef_download_item_t *item,
                         const cef_string_t *suggested, cef_before_download_callback_t *callback) {
    int handled = 1;
    @autoreleasepool {
        char *name = glue_utf8(suggested);
        // Asked first, for a download a tool decides about.
        char *chosen = NULL;
        if (downloads.begin) {
            char *url = glue_take(item->get_url(item));
            chosen = downloads.begin(browser->get_identifier(browser), item->get_id(item), url, name);
            free(url);
        }
        if (chosen && !chosen[0]) {
            // Refused: not handled is cancelled, with Alloy's pages.
            handled = 0;
        } else {
            NSString *path = chosen ? [NSString stringWithUTF8String:chosen] : download_path([NSString stringWithUTF8String:name]);
            cef_string_t target = {0};
            glue_set(&target, path.fileSystemRepresentation);
            callback->cont(callback, &target, 0);
            cef_string_utf16_clear(&target);
        }
        free(chosen);
        free(name);
    }
    GLUE_RELEASE(callback);
    GLUE_RELEASE(item);
    GLUE_RELEASE(browser);
    return handled;
}

// MARK: - Every browser

static cef_browser_t **browsers;
static int browser_count, browser_room;

void glue_register(cef_browser_t *browser) {
    if (browser_count == browser_room) {
        browser_room = browser_room ? browser_room * 2 : 16;
        browsers = realloc(browsers, sizeof *browsers * browser_room);
    }
    GLUE_ADD_REF(browser);
    browsers[browser_count++] = browser;
}

void glue_unregister(cef_browser_t *browser) {
    // By identifier: is_same() would take a reference of its own.
    int id = browser->get_identifier(browser);
    for (int i = 0; i < browser_count; i++) {
        if (browsers[i]->get_identifier(browsers[i]) != id) continue;
        cef_browser_t *gone = browsers[i];
        memmove(browsers + i, browsers + i + 1, sizeof *browsers * (browser_count - i - 1));
        browser_count--;
        GLUE_RELEASE(gone);
        return;
    }
}

int chromium_open(void) {
    return browser_count;
}

// MARK: - Starting and stopping

static int fail(char *error, size_t size, const char *why) {
    if (error && size) snprintf(error, size, "%s", why);
    return 0;
}

int chromium_start(const chromium_options *options, char *error, size_t size) {
    if (started) return fail(error, size, "Chromium has already been started once in this process.");
    if (!chromium_loaded()) return fail(error, size, "Chromium's framework isn't loaded.");

    dress_application();
    dress_loose();
    glue_forever(&app.base, sizeof app);
    app.on_before_command_line_processing = before_command_line;
    app.get_browser_process_handler = get_process;
    glue_forever(&process.base, sizeof process);
    process.on_context_initialized = context_initialized;
    process.on_before_child_process_launch = before_child;
    process.on_already_running_app_relaunch = relaunched;
    process.on_schedule_message_pump_work = schedule_work;
    process.get_default_client = default_client;
    mock_keychain = options->mock_keychain;
    if (options->switches && options->switch_count > 0) {
        switches = calloc((size_t)options->switch_count, sizeof *switches);
        for (int i = 0; i < options->switch_count; i++) {
            if (options->switches[i]) switches[switch_count++] = strdup(options->switches[i]);
        }
    }
    on_ready = options->ready;
    pump_start();

    cef_settings_t settings = {0};
    settings.size = sizeof settings;
    // The helpers aren't built with the sandbox's library; see chromium.sh.
    settings.no_sandbox = 1;
    glue_set(&settings.browser_subprocess_path, options->helper);
    glue_set(&settings.framework_dir_path, options->framework);
    glue_set(&settings.main_bundle_path, options->bundle);
    settings.multi_threaded_message_loop = 0;
    settings.external_message_pump = 1;
    // Chromium is told what to do here and in before_command_line, never by
    // whatever arguments Search was opened with.
    settings.command_line_args_disabled = 1;
    glue_set(&settings.root_cache_path, options->root);
    glue_set(&settings.cache_path, options->cache);
    settings.persist_session_cookies = 1;
    glue_set(&settings.locale, options->locale);
    glue_set(&settings.log_file, options->log);
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.remote_debugging_port = options->port;
    glue_set(&settings.keychain_service_name, options->keychain_service);
    glue_set(&settings.keychain_account_name, options->keychain_account);

    char *argv[] = {(char *)(NSProcessInfo.processInfo.arguments.firstObject.fileSystemRepresentation ?: "Search"), NULL};
    cef_main_args_t args = {1, argv};
    started = 1;
    int ok = cef_initialize(&args, &settings, &app, NULL);

    cef_string_t *strings[] = {
        &settings.browser_subprocess_path, &settings.framework_dir_path, &settings.main_bundle_path,
        &settings.root_cache_path, &settings.cache_path, &settings.locale, &settings.log_file,
        &settings.keychain_service_name, &settings.keychain_account_name,
    };
    for (size_t i = 0; i < sizeof strings / sizeof *strings; i++) cef_string_utf16_clear(strings[i]);

    if (!ok) {
        // Chromium can't be started again in this process, so it stays
        // marked as started, and stopped.
        stopped = 1;
        pump_stop();
        return fail(error, size, "Chromium didn't start. Another copy of Search may be using its profile; "
                                 "its log says more.");
    }
    pump_ask(0);
    return 1;
}

void chromium_stop(double timeout) {
    if (!started || stopping || stopped) return;
    stopping = 1;
    glue_pages_stop();

    // Every browser asked to close, without waiting on pages' unload
    // handlers: pages answer in do_close, Chromium's own windows close.
    int count = browser_count;
    cef_browser_t **all = malloc(sizeof *all * (count ? count : 1));
    for (int i = 0; i < count; i++) {
        all[i] = browsers[i];
        GLUE_ADD_REF(all[i]);
    }
    for (int i = 0; i < count; i++) {
        cef_browser_host_t *host = all[i]->get_host(all[i]);
        if (host) {
            host->close_browser(host, 1);
            GLUE_RELEASE(host);
        }
        GLUE_RELEASE(all[i]);
    }
    free(all);

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while ((browser_count > 0 || glue_pages_making() > 0) && CFAbsoluteTimeGetCurrent() < deadline) {
        @autoreleasepool {
            pump_perform();
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
        }
    }
    // Then the cookies, all of them on disk before the network service
    // goes: a second at most.
    glue_contexts_flush();
    deadline = CFAbsoluteTimeGetCurrent() + 1;
    while (glue_contexts_flushing() > 0 && CFAbsoluteTimeGetCurrent() < deadline) {
        @autoreleasepool {
            pump_perform();
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
        }
    }
    pump_stop();
    glue_contexts_stop();
    // What closing let go of is released on Chromium's side in its next
    // turns; a few more before it stops for good.
    for (int i = 0; i < 4; i++) {
        @autoreleasepool {
            cef_do_message_loop_work();
        }
    }
    stopped = 1;
    cef_shutdown();
}
