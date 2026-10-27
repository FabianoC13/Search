// `release` and `all` are written by `./playwright.sh switches`, from
// Playwright's packages/playwright-core/src/server/chromium/chromiumSwitches.ts
// at the release Tests/Playwright pins: move the pin and run it again, rather
// than editing them. `attach` is chosen by hand; the script says when
// upstream has changed under it.

/// The switches Playwright starts Chrome with, at the release Search is
/// measured against (see PLAYWRIGHT_PLAN.md).
enum PlaywrightSwitches {
    /// The release they come from, which ships Chromium 156.0.8078.4: the
    /// branch of Search's CEF.
    static let release = "1.64.1"

    /// Every switch Playwright passes when it starts Chrome itself, without
    /// its dashes. Search gets these on its command line in launch mode
    /// (see Launch.swift) and passes them on; this list is for reference.
    static let all: [String] = [
        "disable-field-trial-config",
        "disable-background-networking",
        "disable-background-timer-throttling",
        "disable-backgrounding-occluded-windows",
        "disable-back-forward-cache",
        "disable-breakpad",
        "disable-client-side-phishing-detection",
        "disable-component-extensions-with-background-pages",
        "disable-component-update",
        "no-default-browser-check",
        "disable-default-apps",
        "disable-dev-shm-usage",
        "disable-edgeupdater",
        "disable-extensions",
        "disable-features=AvoidUnnecessaryBeforeUnloadCheckSync,DestroyProfileOnBrowserClose,DialMediaRouteProvider,GlobalMediaControls,HttpsUpgrades,LensOverlay,MediaRouter,PaintHolding,ThirdPartyStoragePartitioning,BlockOriginHeaderModificationOnRedirect,AvoidCorsURLLoaderRestartOnRedirect,Translate,AutoDeElevate,OptimizationHints,NetworkTimeServiceQuerying,AimEnabled,msForceBrowserSignIn,msEdgeUpdateLaunchServicesPreferredVersion",
        "enable-features=CDPScreenshotNewSurface",
        "allow-pre-commit-input",
        "disable-hang-monitor",
        "disable-ipc-flooding-protection",
        "disable-popup-blocking",
        "disable-prompt-on-repost",
        "disable-renderer-backgrounding",
        "disable-updater-scheduler",
        "force-color-profile=srgb",
        "metrics-recording-only",
        "no-first-run",
        "password-store=basic",
        "use-mock-keychain",
        "no-service-autorun",
        "export-tagged-pdf",
        "disable-search-engine-choice-screen",
        "unsafely-disable-devtools-self-xss-warnings",
        "edge-skip-compat-layer-relaunch",
        "disable-infobars",
        "disable-sync",
    ]

    /// The ones Search runs with when it lets tools drive your own profile
    /// (Settings › Engine): those that make pages behave for a tool as they
    /// do in Playwright's Chrome, and touch nothing you keep. Never the ones
    /// that would: use-mock-keychain and password-store=basic change the key
    /// your cookies are encrypted with, which signs you out everywhere;
    /// ThirdPartyStoragePartitioning off weakens what sites can see of each
    /// other; disable-extensions, disable-sync and the rest are about a
    /// browser nobody uses.
    static let attach: [String] = [
        "disable-background-timer-throttling",
        "disable-backgrounding-occluded-windows",
        "disable-renderer-backgrounding",
        "disable-ipc-flooding-protection",
        "disable-hang-monitor",
        "allow-pre-commit-input",
        "disable-prompt-on-repost",
        "disable-back-forward-cache",
        "disable-popup-blocking",
        "force-color-profile=srgb",
        "disable-features=AvoidUnnecessaryBeforeUnloadCheckSync,DestroyProfileOnBrowserClose,PaintHolding,BlockOriginHeaderModificationOnRedirect,AvoidCorsURLLoaderRestartOnRedirect,HttpsUpgrades",
        "enable-features=CDPScreenshotNewSurface",
    ]
}
