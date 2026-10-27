import Foundation

// The rest of Search, as the bridge sees it, played by a connection of its
// own to Chromium: a tab is a page made with Target.createTarget; a context
// of Search's is one of Chromium's with a keeper page in it, as Search keeps
// one (Automation.swift); and in attach mode your own tabs are a page in the
// default context and a private one in a context of its own, which tools
// must never see — its target is said on stderr, "private <id>", for
// safety.mjs, once everything is up. Names and signatures are Automation's,
// so DevToolsBridge.swift builds against this unchanged.

@MainActor final class Tab {
    let id = UUID()
    var targetID: String?
    var toolContext: String?
}

@MainActor final class Browser {
    func chromiumQuestionGone(_ tab: Tab) {}
}

@MainActor final class Automation {
    static let shared = Automation()
    private var socket: DevToolsSocket?
    private var next = 1
    private var replies: [Int: ([String: Any]) -> Void] = [:]
    private var queued: [String] = []
    private var targets: [String: Tab] = [:]
    private(set) var defaultContext: String?
    private var keepers: Set<String> = []
    private var contexts: [String: String] = [:]
    private var made: Set<String> = []
    private var waiting: [ObjectIdentifier: [(String?) -> Void]] = [:]
    /// The private tab's target, which tools must never reach.
    private(set) var privateTarget: String?
    /// Downloads in Search's contexts, by Chromium's GUID: their context.
    private var downloads: [String: String] = [:]

    func start(_ url: URL, yours: Bool) {
        socket = DevToolsNet.socket(url)
        for text in queued { socket?.send(text) }
        queued.removeAll()
        receive()
        call("Target.getBrowserContexts") { reply in
            if let id = (reply["result"] as? [String: Any])?["defaultBrowserContextId"] as? String { self.learnDefaultContext(id) }
        }
        guard yours else { return }
        _ = create(URL(string: "about:blank#yours")!, context: nil)
        call("Target.createBrowserContext") { reply in
            guard let context = Automation.result(reply, "browserContextId") else { return }
            self.call("Target.createTarget", ["url": "about:blank#private", "browserContextId": context]) { reply in
                self.privateTarget = Automation.result(reply, "targetId")
                if let target = self.privateTarget { FileHandle.standardError.write(Data("private \(target)\n".utf8)) }
            }
        }
    }

    private func receive() {
        socket?.receive { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard case .success(let text) = result,
                          let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
                    if let id = message["id"] as? Int, let done = self.replies.removeValue(forKey: id) {
                        done(message)
                    } else if let method = message["method"] as? String {
                        self.heard(method, message["params"] as? [String: Any] ?? [:])
                    }
                    self.receive()
                }
            }
        }
    }

    /// Chromium's word of a download in one of Search's contexts, passed on
    /// as Search does (contextDownloadBegins): to the tools of the context.
    private func heard(_ method: String, _ params: [String: Any]) {
        guard let guid = params["guid"] as? String else { return }
        switch method {
        case "Browser.downloadWillBegin":
            guard let frame = params["frameId"] as? String, let context = targets[frame]?.toolContext else { return }
            downloads[guid] = context
            DevToolsBridge.shared.event(method, params, context: context)
        case "Browser.downloadProgress":
            guard let context = downloads[guid] else { return }
            if params["state"] as? String != "inProgress" { downloads[guid] = nil }
            DevToolsBridge.shared.event(method, params, context: context)
        default:
            break
        }
    }

    private func call(_ method: String, _ params: [String: Any] = [:], _ done: (([String: Any]) -> Void)? = nil) {
        let id = next
        next += 1
        replies[id] = done ?? { _ in }
        let data = try! JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let text = String(decoding: data, as: UTF8.self)
        if let socket { socket.send(text) } else { queued.append(text) }
    }

    private static func result(_ reply: [String: Any], _ key: String) -> String? {
        (reply["result"] as? [String: Any])?[key] as? String
    }

    func came(_ tool: AnyObject, agent: String?) {}
    func left(_ tool: AnyObject) {}
    func driving(_ target: String, input: Bool = false) {}
    func learnDefaultContext(_ context: String) { if defaultContext == nil, !context.isEmpty { defaultContext = context } }
    func chromiumMadeContext(_ context: String) { made.insert(context) }
    func tab(for target: String) -> Tab? { targets[target] }
    func isSearchContext(_ id: String?) -> Bool { id.map { contexts[$0] != nil } ?? false }
    func keeperTarget(of id: String) -> String? { contexts[id] }
    func inSearchContext(target: String) -> Bool { isSearchContext(tab(for: target)?.toolContext) }

    func hides(target: String, context: String?) -> Bool {
        if keepers.contains(target) || target == privateTarget { return true }
        if let context, contexts[context] != nil || made.contains(context) { return false }
        if targets[target] != nil { return false }
        guard let context, !context.isEmpty, let defaultContext else { return false }
        return context != defaultContext
    }

    func whenTarget(of tab: Tab, within seconds: Double = 10, _ done: @escaping (String?) -> Void) {
        if let known = tab.targetID { return done(known) }
        waiting[ObjectIdentifier(tab), default: []].append(done)
    }

    private func create(_ url: URL, context: String?) -> Tab {
        let tab = Tab()
        tab.toolContext = context
        var params: [String: Any] = ["url": url.absoluteString]
        if let context { params["browserContextId"] = context }
        call("Target.createTarget", params) { reply in
            let id = Automation.result(reply, "targetId")
            if let id {
                tab.targetID = id
                self.targets[id] = tab
            }
            for waiter in self.waiting.removeValue(forKey: ObjectIdentifier(tab)) ?? [] { waiter(id) }
        }
        return tab
    }

    func openPage(_ url: URL, for tool: AnyObject, newWindow: Bool, background: Bool) -> Tab { create(url, context: nil) }

    func openPage(_ url: URL, inContext id: String, background: Bool) -> Tab? {
        contexts[id] == nil ? nil : create(url, context: id)
    }

    func close(_ tab: Tab) {
        if let target = tab.targetID { call("Target.closeTarget", ["targetId": target]) }
    }

    func bringToFront(_ tab: Tab) {
        if let target = tab.targetID { call("Target.activateTarget", ["targetId": target]) }
    }

    func closeWindows(of tool: AnyObject) {}

    func makeContext(for tool: AnyObject, disposeOnDetach: Bool, proxy: String?, bypass: String?,
                     _ done: @escaping (String?) -> Void) {
        var params: [String: Any] = [:]
        if let proxy { params["proxyServer"] = proxy }
        if let bypass { params["proxyBypassList"] = bypass }
        call("Target.createBrowserContext", params) { reply in
            guard let context = Automation.result(reply, "browserContextId") else { return done(nil) }
            self.call("Target.createTarget", ["url": "about:blank", "browserContextId": context]) { reply in
                guard let keeper = Automation.result(reply, "targetId") else { return done(nil) }
                self.keepers.insert(keeper)
                self.contexts[context] = keeper
                done(context)
            }
        }
    }

    func dispose(_ id: String) {
        guard contexts.removeValue(forKey: id) != nil else { return }
        call("Target.disposeBrowserContext", ["browserContextId": id])
    }

    func downloadBehavior(_ behavior: String, path: String?, context: String?) {
        guard let context, contexts[context] != nil else { return }
        var params: [String: Any] = ["behavior": behavior, "browserContextId": context, "eventsEnabled": true]
        if let path { params["downloadPath"] = path }
        call("Browser.setDownloadBehavior", params)
    }

    func cancelDownload(_ guid: String, context: String) {
        call("Browser.cancelDownload", ["guid": guid, "browserContextId": context])
    }

    func grant(_ permissions: [String], origin: String?, context: String?) {
        guard let context, contexts[context] != nil else { return }
        var params: [String: Any] = ["permissions": permissions, "browserContextId": context]
        if let origin { params["origin"] = origin }
        call("Browser.grantPermissions", params)
    }

    func resetGrants(context: String?) {
        guard let context, contexts[context] != nil else { return }
        call("Browser.resetPermissions", ["browserContextId": context])
    }

    func viewport(_ target: String, width: Int, height: Int) {}
    func pointer(_ target: String, type: String, x: Double, y: Double) {}
    func downloadBegan(guid: String, url: String, name: String) {}
    func downloadProgressed(guid: String, state: String) {}
    static func browser(of tab: Tab) -> Browser? { nil }
}
