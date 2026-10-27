import AppKit
import CChromium

// Tools driving Search's Chromium pages over DevTools — Playwright,
// Puppeteer, an agent through @playwright/mcp — and what Search does so that
// its tabs behave for them as Chrome's do (DevToolsBridge.swift carries the
// protocol; this is Search's side of it):
//
// - which tab is which target, as each page reported it (ChromiumPage);
// - the tabs a tool is driving: kept running out of sight, at 100% zoom,
//   at the size of the viewport the tool set, with a pointer drawn where
//   the tool's mouse is, and left alone by your own pointer while the tool
//   is at work;
// - the window a tool's own pages open in, one per connection;
// - the contexts a tool makes (browser.newContext()): private windows of
//   Search's, signed in as nobody, gone when the tool is done with them;
// - what tools grant (permissions) and where their downloads go;
// - the pill that says a tool is at work, with its Disconnect.

/// A tab, held weakly.
private struct Held {
    weak var tab: Tab?
}

@MainActor
final class Automation {
    static let shared = Automation()

    /// Settings › Engine › Show where a tool clicks.
    nonisolated static let pointerKey = "automation.pointer"
    /// The pill's line, among the extensions' (RecordingIndicator).
    static let lineID = "automation"

    // MARK: - Tools connected

    private struct Tool {
        /// What the pill calls it: Playwright, Puppeteer, or "A tool".
        var name: String
        /// Where its pages open (Target.createTarget in the default context).
        weak var window: Browser?
    }

    private var tools: [ObjectIdentifier: Tool] = [:]

    /// A tool is connected: popups need no click, menus and panels open
    /// only for real input, and its pages behave as Chrome's would.
    var connected: Bool { !tools.isEmpty }

    /// A tool connected: `agent` is what its connection said it was.
    func came(_ tool: AnyObject, agent: String?) {
        tools[ObjectIdentifier(tool)] = Tool(name: Automation.name(of: agent), window: nil)
        settle()
    }

    /// A tool's connection ended. Its contexts made to go with it go
    /// (Target.createBrowserContext's disposeOnDetach); with the last one,
    /// every tab it drove is yours again.
    func left(_ tool: AnyObject) {
        let key = ObjectIdentifier(tool)
        tools[key] = nil
        for (id, context) in contexts where context.owner == key && context.disposeOnDetach { dispose(id) }
        if tools.isEmpty { letGo() }
        settle()
    }

    private static func name(of agent: String?) -> String {
        let said = agent?.lowercased() ?? ""
        if said.contains("playwright") { return "Playwright" }
        if said.contains("puppeteer") { return "Puppeteer" }
        if said.contains("selenium") || said.contains("webdriver") { return "WebDriver" }
        return "A tool"
    }

    /// Chromium told, the pill put up or taken down, your pointer watched.
    private func settle() {
        chromium_set_automation(connected ? 1 : 0)
        let names = Set(tools.values.map(\.name))
        let line = connected
            ? RecordingLine(id: Automation.lineID, name: names.count == 1 ? names.first ?? "A tool" : "Tools",
                            what: names.count == 1 ? "is controlling Search" : "are controlling Search",
                            automation: true)
            : nil
        RecordingIndicator.shared.automation(line)
        watchYourPointer(connected)
        watchMenus(connected)
    }

    /// The pill's Disconnect: every tool's connection closed.
    func disconnectAll() {
        DevToolsBridge.shared.disconnectAll()
    }

    // MARK: - Targets

    private var targets: [String: Held] = [:]
    private var browsers: [Int32: Held] = [:]
    private var waiting: [ObjectIdentifier: [(id: UUID, done: (String?) -> Void)]] = [:]

    /// The browser context of tabs signed in as you (the main profile).
    /// Tools see its pages; a private tab's and a space's that keeps its own
    /// sign-ins are kept from them (see hides).
    private(set) var defaultContext: String?

    /// A tab's page said which target it is.
    func register(_ tab: Tab, target: String, context: String, browser: Int32) {
        targets = targets.filter { $0.value.tab != nil }
        browsers = browsers.filter { $0.value.tab != nil }
        targets[target] = Held(tab: tab)
        browsers[browser] = Held(tab: tab)
        if defaultContext == nil, !context.isEmpty, case .main? = tab.profile, tab.toolContext == nil {
            defaultContext = context
        }
        for waiter in waiting.removeValue(forKey: ObjectIdentifier(tab)) ?? [] { waiter.done(target) }
        // A page a tool's context opened is that context's from the start.
        if let id = tab.toolContext, contexts[id] != nil { contexts[id]?.tabs.append(Held(tab: tab)) }
    }

    /// Learned from Chromium itself (Target.getBrowserContexts), before any
    /// page of yours has said.
    func learnDefaultContext(_ context: String) {
        if defaultContext == nil, !context.isEmpty { defaultContext = context }
    }

    func tab(for target: String) -> Tab? { targets[target]?.tab }

    func tab(forBrowser browser: Int32) -> Tab? { browsers[browser]?.tab }

    /// `done` gets the tab's target once its page says, or nil after
    /// `seconds`.
    func whenTarget(of tab: Tab, within seconds: Double = 10, _ done: @escaping (String?) -> Void) {
        if let known = tab.targetID { return done(known) }
        let key = ObjectIdentifier(tab)
        let id = UUID()
        waiting[key, default: []].append((id, done))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, var list = self.waiting[key], let at = list.firstIndex(where: { $0.id == id }) else { return }
            let waiter = list.remove(at: at)
            self.waiting[key] = list.isEmpty ? nil : list
            waiter.done(nil)
        }
    }

    /// Whether tools may not see a target: a private tab's, or a space's
    /// that keeps its own sign-ins — its cookies and downloads aren't the
    /// default context's, so `context.cookies()` would lie about it. A
    /// context a tool made is always its own to see.
    func hides(target: String, context: String?) -> Bool {
        // A context's keeper is Search's own, never the tool's.
        if keepers.contains(target) { return true }
        if let context, contexts[context] != nil || madeContexts.contains(context) { return false }
        if let tab = tab(for: target) {
            if tab.toolContext != nil { return false }
            if tab.shy { return true }
            if case .space? = tab.profile { return true }
            return false
        }
        guard let context, !context.isEmpty, let defaultContext else { return false }
        return context != defaultContext
    }

    /// Contexts Chromium made for a tool itself (its own windows), which
    /// tools see.
    private var madeContexts: Set<String> = []
    /// The targets of contexts' keepers (see Keeper).
    private var keepers: Set<String> = []

    func keeperCame(_ target: String) { keepers.insert(target) }

    func chromiumMadeContext(_ context: String) { madeContexts.insert(context) }

    // MARK: - Pages a tool drives

    private var driven: [Tab.ID: Held] = [:]
    /// When a tool last sent input to each tab: your pointer leaves it be
    /// for a moment after (see watchYourPointer).
    private var toolInput: [Tab.ID: Date] = [:]

    /// A command reached a target: its tab is being driven. `input`: it
    /// was the mouse or the keyboard.
    func driving(_ target: String, input: Bool = false) {
        guard let tab = tab(for: target) else { return }
        if input { toolInput[tab.id] = Date() }
        if driven[tab.id]?.tab == nil {
            driven[tab.id] = Held(tab: tab)
            tab.driven = true
            tab.holdZoom()
        }
        keepRunning(tab)
    }

    /// The tabs a tool drives now.
    var drivenTabs: [Tab] { driven.values.compactMap(\.tab) }

    /// Every tab a tool drove is yours again: its zoom back, its size its
    /// window's, no pointer, out of the room.
    private func letGo() {
        for tab in drivenTabs {
            tab.driven = false
            guard let page = tab.page as? ChromiumPage else { continue }
            page.viewport = nil
            page.hidePointer()
            if page.view.window === room { page.view.removeFromSuperview() }
            tab.applyRememberedZoom()
        }
        driven.removeAll()
        toolInput.removeAll()
        grants.removeAll()
        downloadFolder = nil
        downloads.removeAll()
    }

    // MARK: Running out of sight

    /// A window off every screen, as the bench keeps its pages (Bench.swift):
    /// a page a tool drives goes on being laid out and painted here while
    /// you look at another tab. Chromium paints a window it thinks covered
    /// because tools drive it with occluded windows left running (see
    /// PlaywrightSwitches.attach).
    private(set) var room: NSWindow?

    private func makeRoom() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1920, height: 1200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        window.orderBack(nil)
        room = window
        return window
    }

    /// A page a tool drives that isn't in a window — its tab behind
    /// another, or opened in the background — goes to the room, at the size
    /// it had.
    func keepRunning(_ tab: Tab) {
        guard let page = tab.page as? ChromiumPage, page.view.window == nil else { return }
        let window = room ?? makeRoom()
        let view = page.view
        let size = view.frame.size
        view.frame = NSRect(origin: .zero, size: size.width > 100 && size.height > 100 ? size : NSSize(width: 1280, height: 800))
        window.contentView?.addSubview(view)
    }

    /// The stage put a page down (StageView.settle): one a tool drives goes
    /// on running in the room. The stage takes it back when its tab is
    /// picked.
    func steppedAside(_ view: NSView) {
        guard connected, let tab = drivenTabs.first(where: { ($0.page as? ChromiumPage)?.view === view }) else { return }
        keepRunning(tab)
    }

    // MARK: Viewport, zoom, pointer

    /// Emulation.setDeviceMetricsOverride: the page laid out at exactly
    /// that size, at the top left of its tab, as Chrome's window is sized
    /// to it. 0 for either: the tab's own size again.
    func viewport(_ target: String, width: Int, height: Int) {
        guard let page = tab(for: target)?.page as? ChromiumPage else { return }
        page.viewport = width > 0 && height > 0 ? NSSize(width: width, height: height) : nil
    }

    var showsPointer: Bool { Store.settings.object(forKey: Automation.pointerKey) as? Bool ?? true }

    /// Input.dispatchMouseEvent: an arrow drawn where the tool's mouse is,
    /// rippling on a press, gone a moment after it stops.
    func pointer(_ target: String, type: String, x: Double, y: Double) {
        guard let page = tab(for: target)?.page as? ChromiumPage else { return }
        guard showsPointer else { return page.hidePointer() }
        page.showPointer(at: CGPoint(x: x, y: y), pressed: type == "mousePressed")
    }

    // MARK: Your pointer

    private var yourPointer: Any?

    /// While a tool drives a tab, your pointer passing over it would hover
    /// what the tool is about to click — or end a drag it started. For two
    /// seconds after the tool's last input, your pointer's moves over that
    /// page aren't passed on; a click is, and is you taking over.
    private func watchYourPointer(_ on: Bool) {
        if on, yourPointer == nil {
            yourPointer = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
                let swallowed = MainActor.assumeIsolated { Automation.shared.disturbs(event) }
                return swallowed ? nil : event
            }
        } else if !on, let watch = yourPointer {
            NSEvent.removeMonitor(watch)
            yourPointer = nil
        }
    }

    private func disturbs(_ event: NSEvent) -> Bool {
        guard let window = event.window, let hit = window.contentView?.hitTest(event.locationInWindow) else { return false }
        let now = Date()
        for tab in drivenTabs {
            guard let at = toolInput[tab.id], now.timeIntervalSince(at) < 2,
                  let view = (tab.page as? ChromiumPage)?.view, hit === view || hit.isDescendant(of: view) else { continue }
            return true
        }
        return false
    }

    // MARK: Menus a tool's click opened

    private var menus: NSObjectProtocol?

    /// A <select> a tool clicks opens the system's menu, as in Chrome, and
    /// it would sit on your screen until you clicked somewhere: one that
    /// opens with no click or key of yours just before is closed at once.
    /// The page still had its click, and the tool sets the value its own way.
    /// Context menus never open for a tool at all (see page.m).
    private func watchMenus(_ on: Bool) {
        if on, menus == nil {
            menus = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    guard let menu = note.object as? NSMenu, menu.supermenu == nil, menu !== NSApp.mainMenu,
                          chromium_real_input_age(Int32(CHROMIUM_REAL_MOUSE)) > 1,
                          chromium_real_input_age(Int32(CHROMIUM_REAL_KEY)) > 1 else { return }
                    menu.cancelTrackingWithoutAnimation()
                }
            }
        } else if !on, let watch = menus {
            NotificationCenter.default.removeObserver(watch)
            menus = nil
        }
    }

    // MARK: - The tool's windows and pages

    /// A page for a tool (Target.createTarget): a tab at the end of the
    /// row of the tool's window, made the first time it asks, in front
    /// unless it asked for the background. `newWindow` makes another.
    func openPage(_ url: URL, for tool: AnyObject, newWindow: Bool, background: Bool) -> Tab {
        let key = ObjectIdentifier(tool)
        let browser: Browser
        if !newWindow, let kept = tools[key]?.window, kept.isOpen {
            browser = kept
        } else {
            browser = Automation.window(space: Space.firstID)
            tools[key]?.window = browser
        }
        return page(url, in: browser, background: background)
    }

    /// A window for a tool's pages: in the space signed in as you, put in
    /// front of Search's other windows without taking the keyboard from
    /// whatever you are doing.
    private static func window(space: UUID) -> Browser {
        let browser = Browser(record: WindowRecord(space: space))
        Browsers.open(browser, frame: nil, quietly: true)
        return browser
    }

    private func page(_ url: URL, in browser: Browser, shy: Bool = false, kin: UUID? = nil, context: String? = nil,
                      background: Bool) -> Tab {
        // A window's own empty tab makes way for the first page.
        let blanks = browser.tabs.filter { $0.isBlank && !$0.automated }
        let tab = browser.toolOpen(url, shy: shy, kin: kin, context: context,
                                   foreground: !background || blanks.count == browser.tabs.count)
        for blank in blanks { browser.close(blank) }
        driven[tab.id] = Held(tab: tab)
        tab.driven = true
        keepRunning(tab)
        return tab
    }

    /// Target.closeTarget: the tab closed the way Search closes tabs,
    /// pinned or not.
    func close(_ tab: Tab) {
        guard let browser = Automation.browser(of: tab) else { return }
        tab.pin = nil
        browser.close(tab)
    }

    /// Page.bringToFront: the tab picked, its window in front of Search's
    /// others — without taking the keyboard from the app you are in.
    func bringToFront(_ tab: Tab) {
        guard let browser = Automation.browser(of: tab) else { return }
        if browser.activeID != tab.id { browser.select(tab) }
        browser.window?.orderFront(nil)
    }

    /// Browser.close from a tool that attached to your Search: only what
    /// it opened goes — its windows and its contexts' — never Search.
    func closeWindows(of tool: AnyObject) {
        let key = ObjectIdentifier(tool)
        tools[key]?.window?.window?.close()
        for (id, context) in contexts where context.owner == key { dispose(id) }
    }

    static func browser(of tab: Tab) -> Browser? {
        Browsers.all.first { $0.tabs.contains { $0 === tab } || $0.parkedTabs.contains { $0 === tab } }
    }

    // MARK: - Contexts a tool makes

    /// A context of a tool's own (browser.newContext()): a window of
    /// Search's whose tabs are private — in memory, signed in as nobody —
    /// and share one profile, the context. Its id is Chromium's own for
    /// that profile, learned from a page kept in it for as long as it lives
    /// (`keeper`), which tools never see.
    private struct Context {
        let owner: ObjectIdentifier
        let kin: UUID
        weak var window: Browser?
        var keeper: Keeper
        var tabs: [Held] = []
        let disposeOnDetach: Bool
        var downloads: (behavior: String, folder: URL?)?
        var grants: [String: Set<String>] = [:]
        /// Origins whose grants are kept as their settings
        /// (ChromiumRuntime.setPermissions), to undo on resetPermissions.
        var settings: Set<String> = []
    }

    private var contexts: [String: Context] = [:]

    /// Whether a browser context id is one of Search's windows.
    func isSearchContext(_ id: String?) -> Bool { id.map { contexts[$0] != nil } ?? false }

    /// Its keeper's target, for the bridge to ask things of the context
    /// (cookies) through a page in it.
    func keeperTarget(of id: String) -> String? { contexts[id]?.keeper.target }

    /// Target.createBrowserContext: the window made, empty, and its id
    /// given once its keeper says — or nil if it never does.
    func makeContext(for tool: AnyObject, disposeOnDetach: Bool, proxy: String?, bypass: String?,
                     _ done: @escaping (String?) -> Void) {
        let kin = UUID()
        let keeper = Keeper(kin: kin)
        keeper.start { [weak self] target, context in
            guard let self, let target, let context, !context.isEmpty else {
                keeper.stop()
                return done(nil)
            }
            let window = Automation.window(space: Space.firstID)
            self.contexts[context] = Context(owner: ObjectIdentifier(tool), kin: kin, window: window, keeper: keeper,
                                             disposeOnDetach: disposeOnDetach)
            _ = target
            done(context)
        }
        // After the keeper, whose page holds the profile: set on the context
        // its pages will use, before any of them goes anywhere.
        if let proxy, !proxy.isEmpty { ChromiumRuntime.setProxy(proxy, bypass: bypass, for: .ephemeral(kin)) }
    }

    /// Target.createTarget in a context of Search's.
    func openPage(_ url: URL, inContext id: String, background: Bool) -> Tab? {
        guard let context = contexts[id] else { return nil }
        let browser: Browser
        if let kept = context.window, kept.isOpen {
            browser = kept
        } else {
            browser = Automation.window(space: Space.firstID)
            contexts[id]?.window = browser
        }
        let tab = page(url, in: browser, shy: true, kin: context.kin, context: id, background: background)
        contexts[id]?.tabs.append(Held(tab: tab))
        return tab
    }

    /// Target.disposeBrowserContext: its window and every tab of it
    /// closed, and the profile let go of.
    func dispose(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        for tab in context.tabs.compactMap(\.tab) {
            if let browser = Automation.browser(of: tab) { browser.close(tab) }
        }
        if let window = context.window?.window { window.close() }
        context.keeper.stop()
    }

    var searchContexts: [String] { Array(contexts.keys) }

    // MARK: - Permissions

    /// What tools granted (Browser.grantPermissions), by origin, "*" for
    /// every origin, in DevTools' names: for the default context, and for
    /// each of Search's. Each grant to an origin replaces the last, as in
    /// Chrome; Playwright sends all it has granted every time.
    private var grants: [String: Set<String>] = [:]

    func grant(_ permissions: [String], origin: String?, context: String?) {
        let key = Automation.origin(origin) ?? "*"
        guard let context, let held = contexts[context] else {
            grants[key] = Set(permissions)
            return
        }
        contexts[context]?.grants[key] = Set(permissions)
        // Kept where Chromium keeps a site's permissions too, so a page sees
        // them before it asks (navigator.permissions, Notification.permission),
        // as in Chrome. Every origin at once is no setting: those are
        // answered when the page asks.
        guard key != "*" else { return }
        ChromiumRuntime.setPermissions(permissions, origin: key, for: .ephemeral(held.kin))
        contexts[context]?.settings.insert(key)
    }

    func resetGrants(context: String?) {
        guard let context, let held = contexts[context] else {
            grants.removeAll()
            return
        }
        for origin in held.settings { ChromiumRuntime.setPermissions(nil, origin: origin, for: .ephemeral(held.kin)) }
        contexts[context]?.settings.removeAll()
        contexts[context]?.grants.removeAll()
    }

    /// A page's permission request, answered as Chrome answers once a tool
    /// has granted an origin anything — Browser.grantPermissions grants
    /// those and refuses the rest: 1 when all it asks for was granted, 0
    /// when not. -1, to ask as ever, where no tool granted anything.
    func permits(_ tab: Tab, origin: String, media: Bool, kinds: UInt32) -> Int32 {
        let given = tab.toolContext.flatMap { contexts[$0]?.grants } ?? grants
        let site = Automation.origin(origin) ?? ""
        guard given["*"] != nil || given[site] != nil else { return -1 }
        let have = (given["*"] ?? []).union(given[site] ?? [])
        guard let wanted = media ? Automation.mediaNames(kinds) : Automation.permissionNames(kinds),
              !wanted.isEmpty else { return 0 }
        return wanted.isSubset(of: have) ? 1 : 0
    }

    /// "https://example.com/" and "https://example.com" alike.
    private static func origin(_ text: String?) -> String? {
        guard var text = text?.lowercased(), !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// CEF's media bits in DevTools' names; nil for the screen, which no
    /// permission grants.
    private static func mediaNames(_ kinds: UInt32) -> Set<String>? {
        var names: Set<String> = []
        if kinds & 1 != 0 { names.insert("audioCapture") }
        if kinds & 2 != 0 { names.insert("videoCapture") }
        return kinds & (4 | 8) != 0 ? nil : names
    }

    /// CEF's permission bits (cef_permission_request_types_t) in DevTools'
    /// names (Browser.PermissionType); nil for one it has no name for.
    private static func permissionNames(_ kinds: UInt32) -> Set<String>? {
        let known: [(UInt32, String)] = [
            (1 << 0, "ar"), (1 << 1, "cameraPanTiltZoom"), (1 << 2, "videoCapture"), (1 << 3, "capturedSurfaceControl"),
            (1 << 4, "clipboardReadWrite"), (1 << 5, "topLevelStorageAccess"), (1 << 7, "localFonts"),
            (1 << 8, "geolocation"), (1 << 9, "handTracking"), (1 << 11, "idleDetection"), (1 << 12, "audioCapture"),
            (1 << 13, "midiSysex"), (1 << 15, "notifications"), (1 << 16, "keyboardLock"), (1 << 17, "pointerLock"),
            (1 << 18, "protectedMediaIdentifier"), (1 << 20, "storageAccess"), (1 << 21, "vr"),
            (1 << 22, "webAppInstallation"), (1 << 23, "windowManagement"), (1 << 25, "localNetworkAccess"),
            (1 << 26, "localNetwork"), (1 << 27, "loopbackNetwork"), (1 << 28, "sensors"),
        ]
        var names: Set<String> = []
        var left = kinds
        for (bit, name) in known where kinds & bit != 0 {
            names.insert(name)
            left &= ~bit
        }
        return left == 0 ? names : nil
    }

    // MARK: - Downloads

    /// Where a tool wants the default context's downloads
    /// (Browser.setDownloadBehavior): Playwright's own folder, each under
    /// its GUID.
    private(set) var downloadFolder: URL?
    private var downloads: [String: (url: String, name: String, yours: Bool)] = [:]

    func downloadBehavior(_ behavior: String, path: String?, context: String?) {
        let folder = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let context, contexts[context] != nil {
            contexts[context]?.downloads = (behavior, folder)
        } else {
            downloadFolder = behavior == "allow" || behavior == "allowAndName" ? folder : nil
        }
    }

    /// Browser.downloadWillBegin, in the default context: yours when you
    /// clicked or typed just before it.
    func downloadBegan(guid: String, url: String, name: String) {
        let yours = chromium_real_input_age(Int32(CHROMIUM_REAL_MOUSE)) < 3 || chromium_real_input_age(Int32(CHROMIUM_REAL_KEY)) < 3
        downloads[guid] = (url, name, yours)
    }

    /// Browser.downloadProgress: one of yours, finished in the tool's
    /// folder, is kept in your Downloads too — where it would have gone
    /// with no tool connected — and listed there. The tool's copy stays for
    /// the tool, and goes with its folder.
    func downloadProgressed(guid: String, state: String) {
        guard state == "completed" || state == "canceled" else { return }
        guard let entry = downloads.removeValue(forKey: guid), state == "completed", entry.yours,
              let folder = downloadFolder else { return }
        let file = folder.appendingPathComponent(guid)
        let browser = Browsers.acting
        let kept = Browser.free(entry.name.isEmpty ? "download" : entry.name, in: browser.downloadsFolder)
        // A clone on APFS: no second copy of the bytes.
        guard (try? FileManager.default.copyItem(at: file, to: kept)) != nil else { return }
        browser.saved(kept, from: URL(string: entry.url))
    }

    /// A file in a tool's folder: the tool's, not one for Search's list.
    func isToolDownload(_ file: URL) -> Bool {
        let path = file.standardizedFileURL.path
        let folders = [downloadFolder] + contexts.values.map { $0.downloads?.folder }
        return folders.contains { folder in folder.map { path.hasPrefix($0.standardizedFileURL.path + "/") } ?? false }
    }

    /// Downloads in Search's contexts, where Chromium takes no download
    /// behavior from a tool: Search answers as it would, saving under a
    /// GUID in the tool's folder and telling the tool as Chromium does.
    private var contextDownloads: [String: (guid: String, context: String, target: String)] = [:]

    func contextDownloadBegins(browser: Int32, id: UInt32, url: String, name: String) -> String? {
        guard let tab = tab(forBrowser: browser), let contextID = tab.toolContext,
              let behavior = contexts[contextID]?.downloads else { return nil }
        guard behavior.behavior != "deny" else { return "" }
        guard let folder = behavior.folder else { return nil }
        let guid = UUID().uuidString.lowercased()
        let target = tab.targetID ?? ""
        contextDownloads["\(browser):\(id)"] = (guid, contextID, target)
        DevToolsBridge.shared.event("Browser.downloadWillBegin", [
            "frameId": target, "guid": guid, "url": url, "suggestedFilename": name,
        ], context: contextID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(guid).path
    }

    /// True back cancels it: the tool asked (cancelDownload).
    func contextDownloadProgress(browser: Int32, id: UInt32, received: Int64, total: Int64, state: Int32) -> Bool {
        let key = "\(browser):\(id)"
        guard let entry = contextDownloads[key] else { return false }
        let word = state == Int32(CHROMIUM_DOWNLOAD_DONE) ? "completed"
            : state == Int32(CHROMIUM_DOWNLOAD_STOPPED) ? "canceled" : "inProgress"
        if word != "inProgress" {
            contextDownloads[key] = nil
            cancelling.remove(entry.guid)
        }
        DevToolsBridge.shared.event("Browser.downloadProgress", [
            "guid": entry.guid, "totalBytes": max(0, total), "receivedBytes": max(0, received), "state": word,
        ], context: entry.context)
        return word == "inProgress" && cancelling.contains(entry.guid)
    }

    /// Browser.cancelDownload in one of Search's contexts: done as it next
    /// says how it goes. Chromium says nothing back either way, nor does this.
    private var cancelling: Set<String> = []

    func cancelDownload(_ guid: String, context: String) {
        guard contextDownloads.values.contains(where: { $0.guid == guid && $0.context == context }) else { return }
        cancelling.insert(guid)
    }

    /// A page in one of Search's contexts, whose downloads Search tells the
    /// tool of itself (contextDownloadBegins).
    func inSearchContext(target: String) -> Bool {
        isSearchContext(tab(for: target)?.toolContext)
    }

    /// The hooks the C layer asks about every download (chromium_set_downloads).
    static func installDownloadHooks() {
        var hooks = chromium_downloads()
        hooks.begin = { browser, id, url, name in
            let address = url.map { String(cString: $0) } ?? ""
            let suggested = name.map { String(cString: $0) } ?? ""
            let path = MainActor.assumeIsolated {
                Automation.shared.contextDownloadBegins(browser: browser, id: id, url: address, name: suggested)
            }
            return path.flatMap { strdup($0) }
        }
        hooks.progress = { browser, id, received, total, state -> Int32 in
            MainActor.assumeIsolated {
                Automation.shared.contextDownloadProgress(browser: browser, id: id, received: received, total: total,
                                                          state: state) ? 1 : 0
            }
        }
        chromium_set_downloads(&hooks)
    }
}

// MARK: - A context's keeper

/// A page that holds a context of a tool's open for as long as the context
/// lives, and says what Chromium calls it: about:blank, in no window, never
/// shown to the tool.
@MainActor
private final class Keeper: PageEventSink {
    let kin: UUID
    private var page: ChromiumPage?
    private(set) var target: String?
    private var told: ((String?, String?) -> Void)?

    init(kin: UUID) { self.kin = kin }

    func start(_ done: @escaping (String?, String?) -> Void) {
        told = done
        page = ChromiumPage(url: URL(string: "about:blank"), profile: .ephemeral(kin), sink: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let told = self.told else { return }
            self.told = nil
            told(nil, nil)
        }
    }

    func stop() {
        told = nil
        page?.tearDown()
        page = nil
    }

    func pageTarget(_ target: String, context: String, browser: Int32) {
        self.target = target
        Automation.shared.keeperCame(target)
        guard let told else { return }
        self.told = nil
        told(target, context)
    }

    func pageTitle(_ title: String) {}
    func pageURL(_ url: URL) {}
    func pageProgress(_ progress: Double) {}
    func pageLoading(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    func pageCommitted() {}
    func pageFinished() {}
    func pageFailed(code: Int, description: String) {}
    func pageAudible(_ audible: Bool) {}
    func pageFavicons(_ urls: [URL]) {}
    func pageHover(_ link: URL?) {}
    func pageFullscreen(_ on: Bool) {}
    func pageProcessGone() {}
    func pageWantsTab(_ url: URL, foreground: Bool) {}
    func pageWantsClose() {}
    func pageDownloaded(_ file: URL, from source: URL?) {}
    func pageTouched() {}
    func pageAsks(_ kind: Int, origin: String, message: String, text: String, reload: Bool) -> Bool { false }
    func pageQuestionGone() {}
    func pageWantsPopup(_ url: URL?, kind: Int) -> ChromiumPage? { nil }
    func pagePermission(origin: String, media: Bool, kinds: UInt32) -> Int32 { -1 }
}

// MARK: - Tabs for tools

extension Browser {
    /// A page for a tool: at the end of the row, out of the session and
    /// the history (Tab.automated), in front unless asked otherwise.
    /// `shy` and `kin` for a context of the tool's own.
    func toolOpen(_ url: URL, shy: Bool, kin: UUID?, context: String?, foreground: Bool) -> Tab {
        let tab = Tab(shy: shy)
        if let kin { tab.kin = kin }
        tab.automated = true
        tab.toolContext = context
        prepare(tab)
        insert(tab, at: tabs.count)
        tab.go(to: url)
        if foreground { select(tab) }
        return tab
    }
}
