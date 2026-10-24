# Playwright for Search (on WebKit, without Chromium)

## Goal
`chromium.connectOverCDP('http://127.0.0.1:9222')` attaches to a running Search and drives its real tabs: navigate, click, type, fill, evaluate, wait for selectors, screenshot. Search stays on WebKit. This adds an opt-in debugging server that speaks the subset of the Chrome DevTools Protocol (CDP) Playwright needs, built on WKWebView's public API.

## Why CDP
- Playwright attaches to an *open* browser only through `connectOverCDP`. Its WebKit mode launches its own patched WebKit and can't attach to an app.
- Puppeteer, `@playwright/mcp`, browser-use and Stagehand speak CDP too, so they come along almost free. This also covers the roadmap item "Drive Search from an agent".

## Architecture — `Sources/Search/Automation/`
| File | Job |
|---|---|
| `DebugServer.swift` | `NWListener` on 127.0.0.1 only. HTTP `/json/version`, `/json/list`, `/json/new`, `/json/close`; WebSocket at `/devtools/browser/<id>` and `/devtools/page/<id>`. |
| `CDPSession.swift` | JSON-RPC routing, flat `sessionId` multiplexing, `-32601` for unknown methods, `{}` stubs for methods Playwright tolerates as no-ops. |
| `Domains/*.swift` | One file per domain (Browser, Target, Page, Runtime, DOM, Input, Network, Fetch, Emulation), mapping onto `Tab` / `WKWebView`. |
| `RemoteObjects.swift` + `Bridge.js` | Bridge script in a private `WKContentWorld`: CDP-style value serialization, `objectId` handle table, console/exception/binding events through `WKScriptMessageHandler`. |

## Coverage, mapped to WebKit
| CDP | WebKit implementation | Fidelity |
|---|---|---|
| Browser.getVersion / close | Product `Search/<VERSION>` | full |
| Target.* (discover, setAutoAttach+flatten, attach, create, close, activate, events) | Tab model (`ScriptTab.shown`), tab open/close/title/URL observers | full |
| Target.createBrowserContext | Non-persistent `WKWebsiteDataStore` in its own window | good |
| Page.navigate / reload / history / stopLoading | `load`, `reload`, `goBack/Forward`, `stopLoading` | full |
| Page lifecycle (init, DOMContentLoaded, load, networkIdle) | `WKNavigationDelegate` + bridge events + in-flight counter | good (main frame) |
| Page.getFrameTree / frame events | Bridge + `WKFrameInfo` | partial for cross-origin iframes |
| addScriptToEvaluateOnNewDocument / createIsolatedWorld | `WKUserScript` at document start, `WKContentWorld.world(name:)` | full |
| Page.captureScreenshot (clip, fullPage) / printToPDF | `takeSnapshot`, `createPDF` | good |
| JavaScript dialogs | `WKUIDelegate` holds the completion until `handleJavaScriptDialog` | full |
| Downloads | Existing download code | good |
| Runtime.enable / evaluate / callFunctionOn / awaitPromise / getProperties / release | `callAsyncJavaScript(in:in:)` + handle table; one context per frame×world | full |
| Console / exceptions | Bridge hooks `console.*`, `error`, `unhandledrejection` | good |
| Runtime.addBinding (`exposeFunction`) | One message handler per binding | full |
| DOM.describeNode / resolveNode / getContentQuads / getBoxModel / scrollIntoViewIfNeeded / setFileInputFiles | Bridge rects; file inputs via the open-panel delegate | good |
| Input.dispatchMouseEvent / dispatchKeyEvent / insertText | Synthesized `NSEvent`s sent to the web view: trusted events, so hover, focus, IME and native controls act like a real user | good |
| Emulation (viewport, UA, color scheme, geolocation, timezone, locale) | Resize view + `pageZoom`, `customUserAgent`, `appearance`, document-start overrides | partial to full |
| Network events, extra headers, cookies | Navigation delegate for documents, bridge for fetch/XHR, `WKHTTPCookieStore` | partial (no headers for images/CSS) |
| Fetch / `page.route` | Abort via content rule lists; fulfill/continue for fetch/XHR in the bridge; documents via `decidePolicyFor` | partial |
| Tracing, Profiler, video, coverage, service-worker targets, full AX tree | Not offered; clean "not supported" error | — |

## Turning it on (security)
- Off by default. Turned on by launching with `--remote-debugging-port=9222`, or with Settings › Advanced › "Allow automation".
- While it's on, a visible indicator shows (like Chrome's "controlled by automated test software").
- Listens on 127.0.0.1 only. Rejects bad `Host`/`Origin` headers, so web pages and DNS rebinding can't reach it.
- Private tabs are never listed or attachable, matching the existing AppleScript rule.

## Phases
1. **Handshake**: server, `/json/*`, sessions, the minimum of Target/Browser/Page/Runtime, plus stubs. Done when `connectOverCDP` resolves and `contexts()[0].pages()` lists the open tabs.
2. **Core actions**: `goto` + waits, evaluate/handles, quads, mouse/keyboard, screenshots, dialogs. Done when `goto`, `click`, `fill`, `press`, `waitFor`, `screenshot` and `expect().toHaveText` pass.
3. **Pages and contexts**: `newPage`, `close`, popups from `window.open`, `newContext`, cookies, storage state.
4. **Network and emulation**: events, `route`, headers, UA, viewport, color scheme, downloads, uploads, `exposeFunction`.
5. **Turn on and protect**: launch flag, Settings toggle, indicator, Host/Origin checks, private-tab exclusion.
6. **Compatibility suite**: `Tests/Playwright/`, a Node project pinned to one Playwright version that runs a curated set of Playwright-style tests against Search. Adds a pass/fail table to the README, plus Swift unit tests per domain.
7. **Extras**: `do JavaScript` / `open location` in `Search.sdef`; docs for `@playwright/mcp --cdp-endpoint`.

## Known limits
- Cross-origin iframes: you can evaluate in them, but their lifecycle and frame tree are weaker than in Chromium.
- Images, CSS and fonts can be seen after they load but can't be intercepted.
- No tracing, video, coverage, CPU throttling, or service workers.
- Playwright upgrades may start calling new CDP methods; the phase 6 suite catches that.

## Verification
- `npx playwright test` in `Tests/Playwright` against a Search built with `./build.sh` and launched with `--remote-debugging-port=9222`.
- `swift test` for the CDP layer.
- Manual: `@playwright/mcp --cdp-endpoint http://127.0.0.1:9222` from Claude Code, driving a real tab.
