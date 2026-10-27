# Playwright for Search

## Goal
In Chromium mode, Playwright treats Search exactly as it treats Chrome it launched itself: every page is a Search tab, and clicks, keys, the pointer, popups, dialogs, downloads, uploads, screenshots, video and viewports behave as they do in Chrome. Outside automation nothing changes.

Done means two things. First, Tests/Playwright's specs pass against a running Search Beta and a launched one. Second, Playwright's own test suite fails on Search only where it also fails on Playwright's Chromium headed on the same Mac, plus a short written list of differences we accept.

## Where it stands
Everything below is built. The bridge has been run end to end: Tests/Bridge builds it unchanged, puts it in front of a real headless Chromium, and runs the specs and a safety probe through it both ways in. All pass, except one skipped on purpose in attach mode. The rest of Search, its C layer and its Swift, is checked but hasn't been built yet: the first `./beta.sh` will tell. Playwright's own suite hasn't been run yet; it needs the Mac.

### Groundwork
- **Tabs map to targets exactly.** Each page asks its own DevTools agent for `Target.getTargetInfo` (`execute_dev_tools_method`) and registers its target, context and browser id with `Automation`. The bridge maps sessions to targets from `Target.attachedToTarget`.
- **Automation state.** While a tool is connected, the recording pill says "Playwright is controlling Search", with Disconnect. Driven tabs carry a glyph in the tab bar and the side.
- **Real input versus a tool's.** `send_event` in `start.m` stamps every real mouse and key event. Native UI asks `chromium_real_input_age` before it shows.

### Fixed along the way
- Popups keep their opener. `on_before_popup` hands Chromium a Search tab's view and page (`parent_view`, `client`), so `window.opener`, POST bodies and `openerId` behave as in Chrome. A sized popup is a popup tab, as in WebKit mode.
- Popups need no click while a tool is connected.
- Tabs a tool opens load at once, lazy tabs or not.
- `get_default_client` gives Chromium's own windows a client Search manages.
- A tab a tool drives that crashes stays crashed for the tool to hear (`page.on('crash')`).
- Your downloads aren't lost to a tool's folder: one you start by hand while a tool is connected is also kept in your Downloads.

### Pages behave like Chrome's
- `newPage()` opens a tab in a window of the tool's own, which opens quietly. `newWindow` and `background` are honored. These tabs stay out of the session and history.
- A page a tool drives keeps painting and running timers when it isn't on screen: it waits in a window off every screen (`Automation.room`).
- `Page.bringToFront` selects the tab and brings its window forward. Nothing else takes focus from the app you're using.
- A viewport from `Emulation.setDeviceMetricsOverride` is the view's exact size. `Browser.getWindowForTarget` fails for Search tabs, so Playwright never resizes Search's windows.
- Zoom is held at 100% while a tool drives a tab and restored after. Site search stays out of driven tabs.

### Native UI, input and the pointer
- **Dialogs** show as Search's sheet. They go away when a tool answers them (`Page.javascriptDialogClosed`).
- **Native UI only for real input.** The context menu, the file panel and `<select>` menus show only after real input. A tool's right-click still reaches the page as `contextmenu`.
- **Keys.** A tool's keystrokes reach the page and never Search's menus: `Meta+W` closes no tab, `Meta+Q` doesn't quit.
- **Downloads.** In the default context they go where Playwright asks, as in Chrome. In Search's own contexts, Search saves them under the tool's GUID and sends `Browser.downloadWillBegin`/`downloadProgress` itself. Chromium also tells every tool that turned download events on about every download, so the bridge drops its copies for Search's contexts. `download.cancel()` works in both.
- **Permissions.** Grants answer prompts as Chrome does: what's granted is allowed, everything else for that origin is refused. Where nothing was granted, you're asked. In Search's contexts, grants for an origin are also kept as its site settings (`chromium_context_set_permissions`), so `navigator.permissions.query` and `Notification.permission` say so before the page asks.
- **Cursor and pointer.** CSS cursors are Chromium's own in a windowed view. Your real pointer leaves a driven tab's hover state alone for a moment after the tool's input. An arrow shows where the tool's mouse is, with a ring on each click; it can be turned off in Settings › Engine.

### Chromium switches
- Attach mode on your own profile: `PlaywrightSwitches.attach`, which leaves your data and privacy alone (the file says why each was left out). These apply only to runs started with automation on in Settings › Engine.
- Launch mode: exactly what Playwright passes, minus what Search answers itself (`Launch.swift`).
- `./playwright.sh switches` regenerates the reference list from the pinned release. It says what changed upstream, so the hand-chosen `attach` list can be checked again.

### Launch mode: Playwright starts Search
- `chromium.launch({ executablePath: '/Applications/Search Beta.app/Contents/MacOS/Search', headless: false })`, `launchPersistentContext`, or `CRPATH`.
- `--remote-debugging-pipe` (fd 3 and 4) or `--remote-debugging-port`. "DevTools listening on" is printed only once the bridge really listens. If the port is taken, Search says so on stderr and quits.
- `--user-data-dir`: Search's whole world is in that folder, with the add-on read from the installed beta's. The engine is Chromium, with no welcome, no restore and no update check. `--no-startup-window` and a start URL are honored.
- `Browser.close`, or the pipe closing, quits.
- `--headless` is refused with one line on stderr: Search runs headed.

### Contexts are private Search windows
- `Target.createBrowserContext` makes a window of private, in-memory tabs that share one Chromium context. A hidden keeper page holds the context open and learns its id. `proxyServer` and `proxyBypassList` set the context's proxy.
- The bridge answers what Chromium refuses for contexts it didn't make:
  - downloads, cookies (through the keeper), permissions and `cancelDownload`;
  - `disposeBrowserContext`, which, as in Chrome, answers only after the tool has heard each page go.
- `disposeOnDetach` contexts close when their tool disconnects.

## Safety
- Only `127.0.0.1`, or the pipe. A request whose `Host` isn't loopback is refused. So is a WebSocket a web page opens, because it carries an `Origin`.
- Private tabs, spaces with their own sign-ins, and the contexts' keepers are never shown to a tool, in any list, event or endpoint. Asking for one by id fails as if it didn't exist.
- In attach mode, `Browser.close` closes only the tool's windows, and `Browser.crash` is refused.
- If another app has the port, Settings › Engine says so, because tools would reach that app instead.
- Chromium's own server is on a port nothing else had, and only the bridge talks to it.

## Running it
| | |
|---|---|
| `./playwright.sh bridge` | The bridge alone, with no Search built: the specs both ways in and the safety probe (`Tests/Bridge`). |
| `./playwright.sh attach` | The specs against the Search Beta you have open, in Chromium mode, with tools allowed. |
| `./playwright.sh launch` | The specs, Playwright starting Search Beta. |
| `./playwright.sh baseline` | The specs against Playwright's own Chromium. |
| `./playwright.sh suite` | Playwright 1.64.1's own tests against Search Beta, headed. Extra args go to `playwright test`. |
| `./playwright.sh suite-baseline` | The same against Playwright's Chromium. |
| `./playwright.sh expectations` | Writes `Tests/Playwright/expectations.txt`: what passes in the baseline and fails in Search. The aim is to bring it down to the differences below. |

## Differences we accept (unless CEF is patched)
- Tabs opened by ⌘-click or middle-click have no opener. CEF routes them through `OnOpenURLFromTab`, which creates no window, so `page.on('popup')` doesn't fire for them. `context.on('page')` does.
- Spaces with their own sign-ins are hidden from tools.
- No headless mode.
- In Search's contexts, a grant for every origin at once (`grantPermissions` with no origin) answers prompts but isn't a site setting, so `navigator.permissions.query` still says "prompt" before the page asks.

## Moving the pin
1. CEF moves to Chromium N.
2. The pin in `Tests/Playwright/package.json` moves to the Playwright release that ships N's branch (`browsers.json`).
3. `./playwright.sh switches`, and check `attach` against what it reports.
4. `./playwright.sh suite-baseline`, `./playwright.sh suite`, `./playwright.sh expectations`.
