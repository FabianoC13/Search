# Playwright for Search

## Where it stands
Search has two engines, picked in Settings › Engine or with the Search menu's Switch to … item. Switching saves the session and relaunches into the other engine (CEF can be started only once per process), so the engine not in use loads nothing. Chromium is an optional download (`chromium.sh`, `ChromiumAddon.swift`).

- **Chromium mode**: native Playwright. This is the supported way to drive Search.
- **WebKit mode**: no automation beyond read-only AppleScript. A CDP layer over WKWebView is a possible later step (see the end).

## Using it
1. Settings › Engine › Chromium, and let tools drive Chromium (or launch with `--remote-debugging-port=9222`).
2. ```js
   const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
   const context = browser.contexts()[0];
   const page = await context.newPage();   // a real Search tab
   ```

## The bridge (`Sources/Search/Chromium/DevToolsBridge.swift`)
Chromium's own DevTools server listens on the port above the one asked for (9223 for 9222). Search listens on the one asked for and passes everything through, rewriting Chromium's port in `/json` answers and in messages, except:

| Command | What Search does |
|---|---|
| `Target.createTarget` in the default context (`newPage`, `window.open` from a tool) | Opens a real tab in the window in front, then answers with the target that tab became: the first page Chromium reports after it was asked for. |
| `Target.closeTarget` for such a tab | Closes it the way Search closes tabs. |

Everything else (attaching, `Page`, `Runtime`, `Input`, `Network`, tracing, screenshots) is Chromium's own, so it behaves as with Chrome.

With automation on, Chromium runs with `--disable-back-forward-cache`, as when Playwright starts Chrome itself.

Only 127.0.0.1; requests whose `Host` isn't a loopback name are refused (DNS rebinding).

## Known limits
- `browser.newContext()` still makes Chromium's own context and window, not a Search window. Next step: map it to a private (in-memory) Search window, `ChromiumProfile.ephemeral`.
- A page that opens a popup while a tool's `newPage` is pending could be taken as the new tab's target. Unlikely in practice; the fix is to match on the tab's `chromium_page` once the C layer exposes its DevTools id.
- If no Search window is open, `newPage` falls back to Chromium's own window.

## Verification (on a Mac)
- `./build.sh`, open the build with `--remote-debugging-port=9222`, switch to Chromium.
- `curl -s 127.0.0.1:9222/json/version` shows `webSocketDebuggerUrl` on port 9222.
- A script that runs `newPage` → `goto` → `click` → `screenshot` → `page.close()`: the tab appears in Search's sidebar and goes away on close.
- `@playwright/mcp --cdp-endpoint http://127.0.0.1:9222` from Claude Code drives a real tab.

## Later, optional: CDP over WebKit
The earlier plan: a CDP subset on top of WKWebView (`Target`, `Page`, `Runtime`, `DOM`, `Input`, partial `Network`/`Fetch`, `Emulation`), so WebKit mode can be driven too. It's weaker than Chromium (cross-origin iframes, no tracing or video, no interception of images and CSS), so it's only worth doing if WebKit mode needs automation.
