import AppKit
import WebKit
import CChromium

// The questions a page is allowed to ask, and the answers it gets.
//
// WebKit does nothing with alert(), confirm(), prompt(), a file input or a
// password-protected site unless somebody answers for them — and "nothing"
// means confirm() is always false, so "leave without saving?" leaves, and a
// file picker that never opens. Each one here is the system's own sheet on the
// window the page is in, which is what every other browser on this Mac shows.

/// A question held for a tab in the background. WebKit wants every one of
/// them answered; one let go without being shown answers as dismissed.
@MainActor
final class HeldQuestion {
    private let show: () -> Void
    private var drop: (() -> Void)?

    init(show: @escaping () -> Void, drop: @escaping () -> Void) {
        self.show = show
        self.drop = drop
    }

    func present() {
        drop = nil
        show()
    }

    func dismiss() {
        let drop = drop
        self.drop = nil
        drop?()
    }

    deinit { drop?() }
}

/// A question from a page of the pair on screen, drawn over that page alone
/// (see PaneQuestionCard), so the other page goes on working. Answered
/// exactly once, whatever happens to it: WebKit wants every one answered,
/// and answering twice would crash the page. Let go unanswered — the page
/// closed, gone elsewhere, Split View turned off — it answers as dismissed.
@MainActor
final class PaneQuestion: Identifiable {
    enum Kind: Equatable { case alert, confirm, prompt(String) }

    let id = UUID()
    let tab: Tab.ID
    /// The site asking: the frame's own origin, never the page's address,
    /// so a frame from another site is named as itself.
    let host: String
    let message: String
    let kind: Kind
    let asked = Date()
    private var reply: ((Bool, String?) -> Void)?

    init(tab: Tab.ID, host: String, message: String, kind: Kind, reply: @escaping (Bool, String?) -> Void) {
        self.tab = tab
        self.host = host
        self.message = message
        self.kind = kind
        self.reply = reply
    }

    var open: Bool { reply != nil }

    func answer(ok: Bool, text: String? = nil) {
        let reply = reply
        self.reply = nil
        reply?(ok, text)
    }

    deinit { reply?(false, nil) }
}

extension Browser {
    // MARK: - asked over one page of a pair

    /// The tab asking, when it is a page of the pair on screen: its question
    /// goes over it, not over the window.
    private func paneAsking(_ webView: WKWebView) -> Tab? {
        guard let pair = activeSplit,
              let tab = tabs.first(where: { $0.built === webView }), pair.contains(tab.id) else { return nil }
        return tab
    }

    private func askInPane(_ tab: Tab, frame: WKFrameInfo, message: String, kind: PaneQuestion.Kind,
                           reply: @escaping (Bool, String?) -> Void) {
        let host = frame.securityOrigin.host
        paneQuestions.append(PaneQuestion(tab: tab.id, host: host, message: message, kind: kind, reply: reply))
    }

    /// The card's buttons, and the bench.
    func answer(_ question: PaneQuestion, ok: Bool, text: String? = nil) {
        question.answer(ok: ok, text: text)
        paneQuestions.removeAll { $0.id == question.id }
    }

    /// A page closed, gone to another address, or out of Split View: what it
    /// asked is answered as dismissed.
    func dropQuestions(for tab: Tab.ID? = nil) {
        let dropping = paneQuestions.filter { tab == nil || $0.tab == tab }
        guard !dropping.isEmpty else { return }
        paneQuestions.removeAll { question in dropping.contains { $0.id == question.id } }
        for question in dropping { question.answer(ok: false) }
    }

    // MARK: - alert, confirm, prompt

    /// A page's question goes over its own page only. One from a tab in the
    /// background — or in another space — waits until you go to that tab, as
    /// in Safari and Chrome: over the tab in front, a prompt() asking for a
    /// password would pass for that page's. A tab closed first gets the
    /// answer a dismissed dialog gives.
    func ask(from webView: WKWebView, show: @escaping () -> Void, drop: @escaping () -> Void) {
        let known = tabs + parkedTabs
        // Questions from tabs that have gone some other way than close(_:).
        for id in heldDialogs.keys where !known.contains(where: { $0.id == id }) {
            heldDialogs.removeValue(forKey: id)?.forEach { $0.dismiss() }
        }
        guard let tab = known.first(where: { $0.built === webView }), tab.id != activeID else {
            show()
            return
        }
        heldDialogs[tab.id, default: []].append(HeldQuestion(show: show, drop: drop))
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        if let tab = paneAsking(webView) {
            return askInPane(tab, frame: frame, message: message, kind: .alert) { _, _ in completionHandler() }
        }
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: message)
            alert.addButton(withTitle: "OK")
            Dialogs.show(alert, over: webView) { _ in completionHandler() }
        }, drop: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if let tab = paneAsking(webView) {
            return askInPane(tab, frame: frame, message: message, kind: .confirm) { ok, _ in completionHandler(ok) }
        }
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: message)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            Dialogs.show(alert, over: webView) { answer in
                completionHandler(answer == .alertFirstButtonReturn)
            }
        }, drop: { completionHandler(false) })
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        if let tab = paneAsking(webView) {
            return askInPane(tab, frame: frame, message: prompt, kind: .prompt(defaultText ?? "")) { ok, text in
                completionHandler(ok ? (text ?? "") : nil)
            }
        }
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: prompt)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            Dialogs.show(alert, over: webView) { answer in
                completionHandler(answer == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }, drop: { completionHandler(nil) })
    }

    // MARK: - a Chromium page's questions

    /// The same as `ask(from:)`, for a tab whose page Chromium draws.
    func ask(for tab: Tab, show: @escaping () -> Void, drop: @escaping () -> Void) {
        let known = tabs + parkedTabs
        for id in heldDialogs.keys where !known.contains(where: { $0.id == id }) {
            heldDialogs.removeValue(forKey: id)?.forEach { $0.dismiss() }
        }
        guard known.contains(where: { $0.id == tab.id }), tab.id != activeID else {
            show()
            return
        }
        heldDialogs[tab.id, default: []].append(HeldQuestion(show: show, drop: drop))
    }

    /// alert(), confirm(), prompt() and leaving, from a page Chromium
    /// draws: the sheets WebKit's pages get, over its own page only. A tool
    /// may answer first, over DevTools: then the sheet goes without an
    /// answer of its own (chromiumQuestionGone).
    func askChromium(_ tab: Tab, kind: Int, origin: String, message: String, text: String, reload: Bool) -> Bool {
        guard let page = tab.page as? ChromiumPage else { return false }
        let id = tab.id
        let finish: (Bool, String?) -> Void = { [weak self, weak page] ok, answer in
            self?.chromiumQuestions[id] = nil
            page?.answer(ok: ok, text: answer)
        }
        ask(for: tab, show: { [weak self, weak page] in
            guard let self, let page else { return finish(false, nil) }
            let alert = NSAlert()
            let host = URL(string: origin)?.host() ?? ""
            alert.messageText = host.isEmpty ? "This page says" : host
            alert.informativeText = message
            alert.alertStyle = .informational
            var field: NSTextField?
            switch kind {
            case Int(CHROMIUM_DIALOG_CONFIRM):
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
            case Int(CHROMIUM_DIALOG_PROMPT):
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
                let input = NSTextField(string: text)
                input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
                alert.accessoryView = input
                alert.window.initialFirstResponder = input
                field = input
            case Int(CHROMIUM_DIALOG_LEAVE):
                alert.messageText = reload ? "Reload this page?" : "Leave this page?"
                alert.informativeText = "Changes you made may not be saved."
                alert.addButton(withTitle: reload ? "Reload" : "Leave")
                alert.addButton(withTitle: "Stay")
            default:
                alert.addButton(withTitle: "OK")
            }
            self.chromiumQuestions[id] = alert
            Dialogs.show(alert, over: page.view) { answer in
                let ok = answer == .alertFirstButtonReturn
                finish(ok, ok ? field?.stringValue : nil)
            }
        }, drop: { finish(false, nil) })
        return true
    }

    /// What a Chromium page may be let do, answered for this launch, by
    /// site and kind.
    private static var chromiumPermits: [String: Bool] = [:]

    /// A Chromium page asking for the camera, the microphone or your
    /// location: Allow or Don't Allow, over its own page, once per site and
    /// kind for as long as Search runs. What has no words here — the
    /// screen, notifications, which Chromium mode doesn't show — is left to
    /// Chromium, which refuses it.
    func askChromiumPermission(_ tab: Tab, origin: String, media: Bool, kinds: UInt32) -> Int32 {
        guard let page = tab.page as? ChromiumPage, let what = Browser.wanted(media: media, kinds: kinds) else { return -1 }
        let host = URL(string: origin)?.host() ?? origin
        let key = "\(host) \(media) \(kinds)"
        if let known = Browser.chromiumPermits[key] { return known ? 1 : 0 }
        // A test run is never asked on a screen: refused, as cancelled.
        if Store.testing { return 0 }
        ask(for: tab, show: { [weak page] in
            guard let page else { return }
            let alert = NSAlert()
            alert.messageText = "\(host) wants to \(what)"
            alert.informativeText = "Only for as long as Search is open. You can stop it any time by closing the page."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            Dialogs.show(alert, over: page.view) { [weak page] answer in
                let granted = answer == .alertFirstButtonReturn
                Browser.chromiumPermits[key] = granted
                page?.permit(media: media, granted: granted)
            }
        }, drop: { [weak page] in page?.permit(media: media, granted: false) })
        return 2
    }

    /// The words for what a page asks to do; nil for anything else.
    private static func wanted(media: Bool, kinds: UInt32) -> String? {
        if media {
            // CEF's media bits: 1 the microphone, 2 the camera; the screen's
            // are left to Chromium.
            guard kinds & ~UInt32(3) == 0 else { return nil }
            switch kinds {
            case 1: return "use your microphone"
            case 2: return "use your camera"
            case 3: return "use your camera and microphone"
            default: return nil
            }
        }
        // CEF's permission bits (cef_permission_request_types_t).
        let words: [(UInt32, String)] = [
            (1 << 8, "know your location"), (1 << 2, "use your camera"), (1 << 12, "use your microphone"),
        ]
        var said: [String] = []
        var left = kinds
        for (bit, word) in words where kinds & bit != 0 {
            said.append(word)
            left &= ~bit
        }
        guard left == 0, !said.isEmpty else { return nil }
        return said.joined(separator: " and ")
    }

    /// A Chromium page's question was answered elsewhere — by a tool over
    /// DevTools, or taken back by a navigation: its sheet goes, and so does
    /// one still waiting for its tab, neither answering again.
    func chromiumQuestionGone(_ tab: Tab) {
        (tab.page as? ChromiumPage)?.forgetQuestion()
        heldDialogs.removeValue(forKey: tab.id)?.forEach { $0.dismiss() }
        if let alert = chromiumQuestions.removeValue(forKey: tab.id), let parent = alert.window.sheetParent {
            parent.endSheet(alert.window)
        }
    }

    // MARK: - choosing a file

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        // Over its own page only, as its other questions are (see ask): a
        // page behind, or the other page of a pair, choosing a file would
        // have it chosen under the page you are looking at. A test run never
        // shows one — it would be a window on the screen of whoever is
        // working beside it — and is answered as cancelled.
        if Store.testing {
            Dialogs.askedInTest.append("Choose a file (\(frame.securityOrigin.host))")
            return completionHandler(nil)
        }
        ask(from: webView, show: {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.resolvesAliases = true
            // The site the file goes to, named.
            let host = frame.securityOrigin.host
            panel.message = host.isEmpty ? "Choose a file for this page" : "Choose a file for \(host)"
            let finish: (NSApplication.ModalResponse) -> Void = { answer in
                completionHandler(answer == .OK ? panel.urls : nil)
            }
            if let window = Dialogs.window(for: webView) {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(panel.runModal())
            }
        }, drop: { completionHandler(nil) })
    }

    // MARK: - a site that asks who you are, or can't prove who it is

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            trust(webView, challenge, completionHandler)
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            signIn(webView, challenge, completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Every https connection comes through here, not only the broken ones,
    /// so the certificate is checked first and the system is left to it when
    /// it holds up. When it doesn't: this Mac itself — localhost and its
    /// loopback addresses, which nothing on the network can stand in for —
    /// is taken on trust; anything else, a .local name or a private address
    /// on the same Wi-Fi included, is asked about, once per site per launch,
    /// and only for the page itself, never for something a page pulled in.
    private func trust(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host.lowercased()
        if Dialogs.isLoopback(host) || Dialogs.excused.contains(host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // A picture, a script, a font from a site with a bad certificate is
        // simply not loaded. Only the page you asked for is worth a question.
        guard let tab = tab(for: webView),
              (tab.address?.host() ?? tab.pending?.host())?.lowercased() == host
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Over its own tab only, as a page's own questions are (see ask).
        ask(from: webView, show: {
            let alert = NSAlert()
            alert.messageText = "\(host) can't prove who it is"
            alert.informativeText = "Its certificate isn't trusted by this Mac. Someone could be reading what you send. Continue only if you know why it looks like this."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Go Back")
            alert.addButton(withTitle: "Continue Anyway")
            Dialogs.show(alert, over: webView) { answer in
                guard answer == .alertSecondButtonReturn else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                Dialogs.excused.insert(host)
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
        }, drop: { completionHandler(.cancelAuthenticationChallenge, nil) })
    }

    /// A site behind a name and a password — a staging server, a router. One
    /// wrong answer gets another go; the second is taken as "not for me".
    private func signIn(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.previousFailureCount < 2 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // A tab behind yours asking for a name and a password would put the
        // question over the page you are looking at, where it would pass for
        // that page's. It waits for its own tab, as a page's questions do.
        ask(from: webView, show: { [weak self] in
            self?.askSignIn(webView, challenge, completionHandler)
        }, drop: { completionHandler(.cancelAuthenticationChallenge, nil) })
    }

    private func askSignIn(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "\(space.host) asks you to sign in"
        alert.informativeText = space.realm.map { "“\($0)”" } ?? "The site wants a name and a password."
        if challenge.previousFailureCount > 0 {
            alert.informativeText += "\nThat wasn't accepted — try again."
        }
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        name.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        name.nextKeyView = pass
        box.addSubview(name)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = name

        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: name.stringValue, password: pass.stringValue, persistence: .forSession)
            )
        }
    }

    // MARK: - a page whose process went away

    /// WebKit runs each page in a process of its own, and the system kills
    /// those under memory pressure — background tabs first. Left alone, the
    /// tab shows white until somebody thinks to reload. Saying so, with the
    /// one thing worth offering, is what the failure view is for.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        tabProcessGone(tab)
    }
}

enum Dialogs {
    /// Sites with bad certificates that were accepted, for this launch only.
    static var excused = Set<String>()

    static func alert(from frame: WKFrameInfo, saying message: String) -> NSAlert {
        let alert = NSAlert()
        // The site's name as the title, so a page can't dress its message up
        // as one from the system or from the browser.
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : host
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    /// The window the page is in, or the browser's window for a tab that
    /// isn't on stage right now.
    static func window(for webView: WKWebView) -> NSWindow? {
        webView.window ?? NSApp.mainWindow ?? NSApp.windows.first { $0.contentView != nil && $0.isVisible }
    }

    /// A test run's questions, in the order they would have been shown.
    static var askedInTest: [String] = []

    static func show(
        _ alert: NSAlert,
        over webView: WKWebView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        // A test run never shows one — a sheet, or a window of its own for a
        // page without one, would be on the screen of whoever is working
        // beside it. What it would have asked is written down (bench probe),
        // and it is answered as if cancelled.
        if Store.testing {
            askedInTest.append(alert.messageText)
            finish(.cancel)
            return
        }
        if let window = window(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// The same, over a page that isn't WebKit's (a Chromium page's view).
    static func show(
        _ alert: NSAlert,
        over view: NSView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if Store.testing {
            askedInTest.append(alert.messageText)
            finish(.cancel)
            return
        }
        // A page running out of sight for a tool (Automation's room) has no
        // window anybody sees: the sheet goes on the one in front.
        let own = view.window === Automation.shared.room ? nil : view.window
        if let window = own ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// This Mac itself: a certificate here can only have been made here.
    /// Only the names that can't mean anything else: localhost, and the
    /// loopback addresses written as addresses — four numbers and nothing
    /// more, so 127.0.0.1.example.com is a website like any other.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "127"
    }
}
