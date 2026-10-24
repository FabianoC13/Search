// Search Helper: the program Chromium starts for each of its other
// processes — pages, the GPU, the network service, plugins. The same
// program sits in each of the five helper apps (chromium.sh makes them);
// Chromium picks the app by the kind of process it wants, and the
// signature on each says what that kind may do.
//
// It loads the framework from beside its own app, three folders up from
// the executable, with the same loader Search uses (loader.c), checks the
// API hash the same way, and hands over to Chromium.

#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "include/capi/cef_app_capi.h"

#include "CChromium.h"

int main(int argc, char *argv[]) {
    char executable[PATH_MAX], resolved[PATH_MAX], framework[PATH_MAX], error[512];
    uint32_t size = sizeof executable;
    if (_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved)) {
        fprintf(stderr, "Search Helper: can't find where it is\n");
        return 1;
    }
    // <add-on>/Search Helper (GPU).app/Contents/MacOS/Search Helper (GPU)
    char *name = strrchr(resolved, '/');
    if (!name) return 1;
    *name = 0;
    snprintf(framework, sizeof framework,
             "%s/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework", resolved);
    if (!chromium_load(framework, error, sizeof error)) {
        fprintf(stderr, "Search Helper: %s\n", error);
        return 1;
    }
    cef_main_args_t args = {argc, argv};
    return cef_execute_process(&args, NULL, NULL);
}
