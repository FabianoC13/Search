#ifndef CCHROMIUM_GLUE_H
#define CCHROMIUM_GLUE_H

// What start.m and page.m share, and nobody else sees.
//
// CEF's C API counts references by hand, and the rule is the same both
// ways across the boundary: a structure handed over, as an argument or a
// return value, comes with a reference the receiver owns. So every
// structure a callback receives is released before it returns (except
// `self`, and except one kept on purpose), everything a getter returns is
// released after use, and everything of ours given to CEF is added to
// first. Pointers passed by reference for us to change follow the same
// rule: the one that comes in is ours to release, the one we leave there
// carries a reference of its own.

#import <Foundation/Foundation.h>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_download_item_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_request_context_capi.h"

#include "CChromium.h"

int chromium_loaded(void);

/// Releases any of CEF's structures, whatever its type.
#define GLUE_RELEASE(object)                                                   \
    do {                                                                       \
        if (object) ((cef_base_ref_counted_t *)(object))->release((cef_base_ref_counted_t *)(object)); \
    } while (0)
#define GLUE_ADD_REF(object) ((cef_base_ref_counted_t *)(object))->add_ref((cef_base_ref_counted_t *)(object))

/// UTF-8 in; nothing is set for NULL. Cleared with cef_string_utf16_clear.
void glue_set(cef_string_t *to, const char *utf8);
/// UTF-8 out, malloc'd, never NULL.
char *glue_utf8(const cef_string_t *from);
/// The same for a string CEF hands over, which is freed.
char *glue_take(cef_string_userfree_t from);

/// Runs `block` on the main thread at its next turn, in every run loop
/// mode — menus open and windows resizing included. Callable from any
/// thread.
void glue_later(dispatch_block_t block);

/// For our structures that live as long as the process: their counts mean
/// nothing.
void glue_forever(cef_base_ref_counted_t *base, size_t size);

/// Started and not yet stopping: pages may be made and commands sent.
int glue_running(void);
/// Chromium's own context is up, so browsers may be made.
int glue_ready(void);

/// Every browser that exists, whoever made it, so that stopping can close
/// them all. Each keeps a reference while registered.
void glue_register(cef_browser_t *browser);
void glue_unregister(cef_browser_t *browser);

/// The client of browsers Chromium makes for itself: popups that asked for
/// a window of their own, and DevTools.
cef_client_t *glue_loose_client(void);

/// Downloads, the same for every browser: straight into Downloads, under a
/// name nothing else has.
int glue_can_download(struct _cef_download_handler_t *self, cef_browser_t *browser,
                      const cef_string_t *url, const cef_string_t *method);
int glue_before_download(struct _cef_download_handler_t *self, cef_browser_t *browser,
                         struct _cef_download_item_t *item, const cef_string_t *suggested,
                         struct _cef_before_download_callback_t *callback);

/// page.m's part of starting and stopping.
void glue_pages_ready(void);
void glue_pages_stop(void);
int glue_pages_making(void);
void glue_contexts_stop(void);

#endif
