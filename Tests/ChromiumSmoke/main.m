// The C layer on its own, with nothing of Search's: a window, one page
// opening example.com, what it reports, Chromium's DevTools endpoint when a
// port is given, and Chromium stopped again — its helpers gone with it.
//
//   ./chromium.sh test [port]
//   .build/debug/ChromiumSmoke [--addon <folder>] [--port <n>] [--url <address>] [--hold <seconds>]
//
// chromium.sh runs it from inside an app of its own, as Search runs. The
// add-on defaults to the test world's copy (./chromium.sh install). The
// profile is a fresh folder of its own, deleted afterwards. Exits 0 when the
// page loaded and everything closed, 1 when it failed, 2 when it timed out.

#import <AppKit/AppKit.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

#include "CChromium.h"

static chromium_page *page;
static NSWindow *window;
static int port, finished, failures;
static double hold = 1.0;
static int inspect;
static NSString *root;

static void say(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    printf("smoke: ");
    vprintf(format, arguments);
    printf("\n");
    fflush(stdout);
    va_end(arguments);
}

/// This process's children, as ps sees them.
static int children(const char *when) {
    char command[64];
    snprintf(command, sizeof command, "/bin/ps -A -o pid=,ppid=,command=");
    FILE *ps = popen(command, "r");
    if (!ps) return 0;
    char line[4096];
    int count = 0;
    say("children %s:", when);
    while (fgets(line, sizeof line, ps)) {
        int pid = 0, parent = 0, read = 0;
        if (sscanf(line, "%d %d %n", &pid, &parent, &read) < 2 || parent != getpid()) continue;
        if (strstr(line + read, "/bin/ps")) continue;
        // Exited, waiting only to be reaped: gone, as far as running goes.
        if (strstr(line + read, "<defunct>")) continue;
        line[strcspn(line, "\n")] = 0;
        // The executable and its --type, not the whole command line.
        char *text = line + read, *type = strstr(text, "--type=");
        char *dash = strstr(text, " --");
        int shown = dash ? (int)(dash - text) : (int)strlen(text);
        printf("  %d %.*s", pid, shown, text);
        if (type) printf("  [%.*s]", (int)strcspn(type, " "), type);
        printf("\n");
        count++;
    }
    pclose(ps);
    if (!count) printf("  none\n");
    fflush(stdout);
    return count;
}

static void finish(int code) {
    say("stopping Chromium (%d open)", chromium_open());
    chromium_stop(2.0);
    say("stopped (%d open)", chromium_open());
    // The helpers go when the browser process tells them to; a moment.
    int left = 0;
    for (int i = 0; i < 50 && (left = children(i ? "after stopping, still" : "after stopping")) > 0; i++) {
        usleep(100 * 1000);
    }
    if (left) code = code ? code : 1;
    if (root) [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
    exit(code);
}

static void later(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(),
                   block);
}

static void close_page(void) {
    say("closing the page");
    chromium_page_close(page);
}

/// Chromium's view inside the window's: there, and filling it.
static void views(const char *when) {
    NSView *container = window.contentView;
    for (NSView *view in container.subviews) {
        say("%s: %s %s in %s", when, NSStringFromClass(view.class).UTF8String, NSStringFromRect(view.frame).UTF8String,
            NSStringFromRect(container.bounds).UTF8String);
    }
}

static void on_created(void *context) {
    say("created");
    views("view");
}

static void on_title(void *context, const char *title) {
    say("title: %s", title);
}

static void on_address(void *context, const char *url) {
    say("address: %s", url);
}

static void on_loading(void *context, int loading, int back, int forward) {
    say("loading: %d back: %d forward: %d", loading, back, forward);
}

static void on_committed(void *context) {
    say("committed");
}

static void on_icons(void *context, const char *const *urls, int count) {
    for (int i = 0; i < count; i++) say("icon: %s", urls[i]);
}

static void on_failed(void *context, int code, const char *text, const char *url) {
    say("failed: %d %s %s", code, text, url);
    failures++;
    later(0.5, ^{
        close_page();
    });
}

static void on_finished(void *context, int status) {
    say("load end: %d", status);
    if (finished++) return;
    [window setContentSize:NSMakeSize(1200, 800)];
    views("view after resizing");
    say("zoom level: %.2f", chromium_page_zoom(page));
    if (inspect) {
        chromium_page_inspect(page);
        later(2, ^{
            say("open with DevTools: %d", chromium_open());
        });
    }
    later(hold, ^{
        children("while the page is open");
        if (!port) {
            close_page();
            return;
        }
        NSString *address = [NSString stringWithFormat:@"http://127.0.0.1:%d/json/version", port];
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
              dataTaskWithURL:[NSURL URLWithString:address]
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (text) {
                        say("%s:\n%s", address.UTF8String, text.UTF8String);
                    } else {
                        say("%s: %s", address.UTF8String, error.localizedDescription.UTF8String);
                        failures++;
                    }
                    close_page();
                });
            }];
        [task resume];
    });
}

static void on_closed(void *context) {
    say("closed");
    page = NULL;
    // Never inside Chromium's own call.
    later(0, ^{
        finish(failures || !finished ? 1 : 0);
    });
}

static void on_ready(void) {
    say("Chromium is ready");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *addon = nil, *url = @"https://example.com/";
        for (int i = 1; i + 1 < argc; i += 2) {
            NSString *value = [NSString stringWithUTF8String:argv[i + 1]];
            if (!strcmp(argv[i], "--addon")) addon = value;
            if (!strcmp(argv[i], "--port")) port = value.intValue;
            if (!strcmp(argv[i], "--url")) url = value;
            if (!strcmp(argv[i], "--hold")) hold = value.doubleValue;
            if (!strcmp(argv[i], "--inspect")) inspect = value.intValue;
        }
        NSString *version = [NSString stringWithUTF8String:chromium_pinned_version()];
        if (!addon) {
            NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0];
            addon = [[support stringByAppendingPathComponent:@"Search (test)/Chromium"] stringByAppendingPathComponent:version];
        }
        NSString *framework = [addon stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
        NSString *helper = [addon stringByAppendingPathComponent:@"Search Helper.app/Contents/MacOS/Search Helper"];

        char error[512];
        if (!chromium_load([framework stringByAppendingPathComponent:@"Chromium Embedded Framework"].fileSystemRepresentation,
                           error, sizeof error)) {
            say("load failed: %s", error);
            return 1;
        }
        say("loaded %s (pinned %s)", chromium_version(), version.UTF8String);

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 1024, 720)
                                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.title = @"Chromium smoke";
        window.releasedWhenClosed = NO;
        [window makeKeyAndOrderFront:nil];

        char folder[] = "/tmp/search-chromium-smoke.XXXXXX";
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:@"search-chromium-smoke.XXXXXX"];
        char *made = strdup(temporary.fileSystemRepresentation ?: folder), real[PATH_MAX];
        // Without symbolic links (/var is one): Chromium checks that the
        // profile is inside the root by its path as given.
        root = mkdtemp(made) && realpath(made, real) ? [NSString stringWithUTF8String:real] : nil;
        free(made);
        if (!root) {
            say("no profile folder");
            return 1;
        }
        NSString *cache = [root stringByAppendingPathComponent:@"Default"];
        NSString *log = [root stringByAppendingPathComponent:@"chromium.log"];

        chromium_options options = {
            .framework = framework.fileSystemRepresentation,
            .helper = helper.fileSystemRepresentation,
            .bundle = [NSBundle mainBundle].bundlePath.fileSystemRepresentation,
            .root = root.fileSystemRepresentation,
            .cache = cache.fileSystemRepresentation,
            .log = log.fileSystemRepresentation,
            .locale = "en-GB",
            .port = port,
            .mock_keychain = 1,
            .ready = on_ready,
        };
        if (!chromium_start(&options, error, sizeof error)) {
            say("start failed: %s", error);
            return 1;
        }
        say("started (profile %s, port %d)", root.UTF8String, port);

        chromium_events events = {
            .created = on_created,
            .title = on_title,
            .address = on_address,
            .loading = on_loading,
            .committed = on_committed,
            .finished = on_finished,
            .failed = on_failed,
            .icons = on_icons,
            .closed = on_closed,
        };
        page = chromium_page_make((__bridge void *)window.contentView, url.UTF8String, chromium_context_global(), &events);
        if (!page) {
            say("no page");
            finish(1);
        }
        later(60, ^{
            say("timed out");
            finish(2);
        });
        [app run];
    }
    return 0;
}
