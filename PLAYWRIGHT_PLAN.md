# Playwright for Search

## Goal
In Chromium mode, Playwright treats Search exactly as it treats Chrome it launched itself: every page is a Search tab, and clicks, keys, the pointer, popups, dialogs, downloads, uploads, screenshots, video and viewports behave as they do in Chrome. Outside automation nothing changes.

Done means two things. First, the attach suite passes against a running Search Beta. Second, Playwright's own test suite fails on Search only where it also fails on Chrome headed on the same Mac, plus a short written list of differences we accept.

## Where it stands
- Engine switch: Settings › Engine, relaunch into Chromium (CEF 156.0.8078.48), Chromium as a download.
- `DevToolsBridge.swift`: Search listens on the port asked for (9222). Chromium listens one port above it. The bridge passes everything through, except that `Target.createTarget` in the default context opens a Search tab, and `closeTarget` closes it.
- `--disable-back-forward-cache` while automation is on.

## How compatibility is measured
- **Pin.** Playwright 1.64.1 ships Chromium 156.0.8078.4, the same branch as our CEF. Everything below is checked against that release. When CEF moves to a new Chromium, the pin moves to the Playwright release with the same branch (see the end).
- **Attach suite** (`Tests/Playwright/`, `@playwright/test` 1.64.1): `connectOverCDP` to a running Search Beta, in the default context. This is how agents and `@playwright/mcp --cdp-endpoint` use Search. It has one spec per area below.
- **Playwright's own suite**, once Search can be launched by Playwright (phase 5). Check out the repository at `v1.64.1`, then run `CRPATH="/Applications/Search Beta.app/Contents/MacOS/Search" npx playwright test --config tests/library/playwright.config.ts --project chromium-page --project chromium-library --headed`. The baseline is the same run against Chrome for Testing 156, headed. Failures that only Search has go into `Tests/Playwright/expectations.txt`, each with a reason, and the work drives that list to the accepted differences.
- `./playwright.sh` runs both suites and prints a pass/fail table.

## Found while reading the code: fix first
These break common Playwright patterns today.
1. **Popups lose their opener.** `before_popup` cancels `target=_blank` links and plain `window.open` calls and reopens the address as a new tab. The new tab has no opener and loses any POST body, so `page.waitForEvent('popup')` never fires and sign-in popups can't report back.
2. **Popups need a click.** Without a user gesture, `before_popup` blocks the popup, so `page.evaluate(() => window.open(u))` gets `null`. Playwright launches Chrome with `--disable-popup-blocking`.
3. **Tabs not on screen stop running.** `Stage.settle` takes them out of the window, so Chromium stops painting and runs no `requestAnimationFrame`. Playwright's click checks an element is stable with `requestAnimationFrame`, and screenshots and video need painted frames, so clicks, screenshots and video hang on a tab you aren't looking at.
4. **Your downloads vanish while a tool is connected.** On connect, Playwright calls `Browser.setDownloadBehavior` on the default context. From then on, every download in a main-profile tab, yours included, goes to Playwright's temporary folder under a GUID name, and that folder is deleted when it disconnects.
5. **Search can't manage Chromium's own windows.** `get_default_client` isn't implemented, so windows that Chromium creates for a tool (the pages of `newContext()`) have no client. Search can't see or close them, and CEF's header says quitting is blocked until they're closed.
6. **Crashes reload themselves.** A crash in the front tab is reloaded by `tabProcessGone` → `recoverFromCrash`, which conflicts with how Playwright handles `page.on('crash')`.
7. **New tabs from links may never load.** With lazy tabs on, a background tab opened from a link only remembers its address and never loads, so `context.waitForEvent('page')` waits forever.

## The work, in order

### 1. Groundwork
- **Map tabs to targets.** In `on_after_created`, each tab asks its own DevTools agent `Target.getTargetInfo` (`execute_dev_tools_method`, which needs no remote session) and keeps its `targetId` and `browserContextId`. The bridge maps `sessionId` to `targetId` from `Target.attachedToTarget`, which gives an exact tab for every session. This replaces the current guess, "the first page created after the request".
- **Track automation state.** Track whether a tool is connected (the bridge's clients) and which tabs a tool is driving (tabs whose session got a command). While a tool is connected, the window shows "Controlled by Playwright" with a Disconnect button, like Chrome's infobar.
- **Tell real input from a tool's input.** `send_event` in `start.m` already sees every real event. Record the last real mouse button and key event. Any native UI that appears without one just before it was caused by a tool.
- Set up the skeleton of the attach suite and the Chrome baseline.

### 2. Pages behave like Chrome's (attach mode, default context)
- **Real popups.** For `target=_blank`, `window.open` and `noopener`, `on_before_popup` makes the Search tab's view and page first, then returns them as `parent_view` and `client`. Chromium creates the popup itself, so the opener, POST body, `sessionStorage` copy and `window.opener` all behave as in Chrome, and Playwright receives `openerId`. Popups with a size open in a small Search window instead of a bare Chromium window.
- **No gesture needed** for popups while a tool is connected.
- **New tabs from a tool's action load at once**, lazy tabs or not.
- **A window for the tool.** Pages from `newPage()` open in one Search window per connection. `createTarget` with `newWindow` opens another window, and `background` is honored. These tabs are marked like the bench's tabs and kept out of the session and history. They always use the main profile, never a space with its own sign-ins.
- **Pages a tool drives keep running off screen.** They stay in their window behind the selected tab instead of being taken out, so they keep painting and their timers keep running. If that turns out not to be enough, they move to an off-screen window as the bench's pages do (`Bench.swift`).
- **`Page.bringToFront`** selects the tab and brings its window forward. Nothing else a tool does activates Search or takes focus from the app you're using.
- **Closing works.** `page.close()` closes the tab, pinned or not, with no question; `tabWantsClose` already does this. While a tool drives a tab, a crash leaves the tab crashed instead of reloading it.
- **Viewport.** When a tool sends `Emulation.setDeviceMetricsOverride`, Chromium's view takes exactly that size, at the top left of the tab (`Holder` stops forcing it to fill), and the window grows if the screen allows. This keeps layout, hit-testing and screenshots identical to Chrome's. `Browser.getWindowForTarget` must fail for Search tabs, which Playwright tolerates, so that Playwright never resizes Search's windows with Chrome's frame sizes. Chromium should already refuse it for embedded views; if it doesn't, the bridge answers with the error itself.
- **The page is the page.** While a tool drives a tab, its zoom is 100% (Playwright's coordinates assume it), restored afterwards, and Search runs no scripts of its own in it (pausing media, site search).

### 3. Native UI, input and the pointer
- **Dialogs.** A `jsdialog` handler shows Search's own non-blocking sheet for `alert`, `confirm`, `prompt` and `beforeunload`, never a modal dialog. When `Page.handleJavaScriptDialog` answers a dialog, `on_dialog_closed` and `on_reset_dialog_state` remove the sheet. This covers both Playwright's automatic dismissal and `page.on('dialog')`. First verify what CEF's default dialog does when DevTools answers it.
- **Native UI only for real input.** The context menu, file panel, `<select>` menu and color panel appear only after real input. After a tool's click, the DOM events fire (`contextmenu`, `click`, `input`) and no native UI appears. A file input clicked by a tool reports "cancel" unless Playwright is intercepting the file chooser.
- **Keys.** A tool's keystrokes never trigger Search's menus. `on_key_event` sends only real `NSEvent`s on to the menu, so a tool pressing `Meta+W` doesn't close a tab and `Meta+Q` doesn't quit. A test checks that the page itself receives all of these keys.
- **Downloads.** The bridge keeps the folder from Playwright's `Browser.setDownloadBehavior` and passes the call on as Chromium's default behavior with events on, so every download still reaches Search's handler and Playwright still receives `Browser.downloadWillBegin` and `downloadProgress`. Downloads you start (real click) land in your Downloads folder as always, and Search also places an APFS clone at Playwright's path under the download's GUID, so `download.path()` and `saveAs()` work. Downloads a tool starts go only to Playwright's folder and stay out of Search's list. `acceptDownloads: false` cancels the tool's downloads, not yours.
- **Permissions.** A permission handler gives Chromium mode Search's own prompts, which it lacks today. Grants from `Browser.grantPermissions` allow without asking, camera and microphone included. CEF's default denies camera and microphone in Search's kind of view; check whether a DevTools grant gets past that, and if not, the handler honors the grants the bridge has seen.
- **Cursor.** CSS cursors show on screen as in Chrome; check `on_cursor_change`. Your real pointer moving over a tab a tool is driving doesn't change its hover state: real mouse moves aren't passed on while the tool has sent input in the last two seconds. A real click counts as you taking over.
- **Visible pointer.** An arrow drawn over the page where the tool's mouse is, with a ripple on each click. The position comes from the `Input.dispatchMouseEvent` calls the bridge sees, converted with the view's position. It's on by default while a tool is connected and can be turned off in Settings › Engine.

### 4. Chromium switches
Generated from Playwright's `chromiumSwitches.ts` at the pinned tag (`./playwright.sh switches`), so moving the pin updates them.
- **Attach mode, on your real profile**, only the switches that don't touch your data or privacy:
  - `--disable-background-timer-throttling`, `--disable-backgrounding-occluded-windows`, `--disable-renderer-backgrounding`
  - `--disable-ipc-flooding-protection`, `--disable-hang-monitor`, `--allow-pre-commit-input`, `--disable-prompt-on-repost`
  - `--disable-back-forward-cache`, `--force-color-profile=srgb`
  - `--disable-features=PaintHolding,AvoidUnnecessaryBeforeUnloadCheckSync,AvoidCorsURLLoaderRestartOnRedirect,BlockOriginHeaderModificationOnRedirect,HttpsUpgrades`
  - `--enable-features=CDPScreenshotNewSurface`
  
  Chromium reads its switches once, when it starts. So these apply to every run launched with automation on in Settings › Engine, whether or not a tool is connected, and background tabs use more energy in those runs. Runs with automation off are unchanged.
- **Never on a real profile:**
  - `--use-mock-keychain` and `--password-store=basic` change the key that encrypts cookies, which signs you out everywhere.
  - Turning off `ThirdPartyStoragePartitioning` weakens privacy.
- **Launch mode** (phase 5) gets exactly the switches Playwright passes.

### 5. Launch mode: Playwright starts Search
- `executablePath: '/Applications/Search Beta.app/Contents/MacOS/Search'`, for `launch`, `launchPersistentContext` and `CRPATH`.
- **`--remote-debugging-pipe`.** The bridge reads fd 3 and writes fd 4, with each message ending in a NUL byte, and talks to Chromium on an internal port. The bridge owns the pipe; Chromium never gets it, so pages are still Search tabs. `--remote-debugging-port=0` prints `DevTools listening on ws://…` to stderr, as Chrome does.
- **`--user-data-dir=DIR`.** Search's whole world lives in `DIR`: its folder, its settings suite and Chromium's profile. It never touches yours, even with your Search Beta open beside it. The add-on is read from the installed beta's folder.
- **Startup.** The engine is forced to Chromium. `--no-startup-window` starts with no window, and `about:blank` starts with one tab. There's no welcome, What's New, update check, session restore, import offer, default-browser question or quit confirmation.
- **Quitting.** `Browser.close`, or the pipe closing, quits at once and exits with code 0.
- **`--headless`** stops Search with one clear line on stderr ("Search runs headed: pass headless: false") until phase 7.
- Then run Playwright's own suite and fill in `expectations.txt`.

### 6. Contexts are private Search windows
Almost every Playwright test calls `newContext()`, so this decides how much of the suite actually exercises Search.
- **New context.** `Target.createBrowserContext` opens a private Search window with a fresh in-memory Chromium context. Its real id comes from its first page (`Target.getTargetInfo`). That page is kept back from the tool and handed to the first `newPage()` in that context.
- **Context-wide commands.** For `Browser.setDownloadBehavior`, `Storage.getCookies`/`setCookies`/`clearCookies`, `Browser.grantPermissions`/`resetPermissions` and `Target.disposeBrowserContext`, Chromium should accept only contexts that DevTools made itself. Check that first: if it accepts CEF's contexts too, this part goes away. Otherwise the bridge answers these for Search's contexts with CEF's own APIs (the download handler, the cookie manager, content settings) and sends `Browser.downloadWillBegin` and `downloadProgress` itself. `proxyServer` sets the context's proxy preference.
- **Until this lands,** `newContext()` pages open in Chromium's own windows, and `get_default_client` (fix 5) lets Search manage them.

### 7. Headless (optional)
`--headless` opens windows off every screen, as the bench does, with occlusion backgrounding off. Playwright still sees a headed browser.

## Safety, in every phase
- Only `127.0.0.1`, or the pipe; the `Host` check is already in.
- Private tabs, and spaces with their own sign-ins, are never shown to a tool. They're filtered from `/json/list`, `Target.getTargets` and attach events using the tab-to-target map. Their cookies and downloads aren't the default context's, so showing them would make `context.cookies()` wrong.
- In attach mode, `Browser.close` and `Browser.crash` from a tool close only the tool's own windows.
- The indicator stays while anything is connected, and Disconnect ends the session.

## Differences we accept (unless CEF is patched)
- Tabs opened by ⌘-click or middle-click have no opener. CEF routes them through `OnOpenURLFromTab`, which creates no window, so `page.on('popup')` doesn't fire for them. `context.on('page')` does.
- Spaces with their own sign-ins are hidden from tools.
- Headless means windows off screen, not Chromium's headless mode.

## Moving the pin
1. CEF moves to Chromium N.
2. The pin moves to the Playwright release that ships N's branch (`browsers.json`).
3. `./playwright.sh switches`.
4. Run both suites, with Chrome for Testing N as the baseline.
5. Update `expectations.txt`.
