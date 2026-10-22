import AppKit
import Combine
import SwiftUI
import WebKit

// Escape pressed twice to leave a page's full screen, as in Arc: Settings ›
// General › Press Esc twice to leave full screen. WebKit leaves on the first
// Escape it is given, before the page's own listeners, so a video went at a
// touch of the key that was meant for something else. With the switch on,
// the key monitor (ContentView.watchKeys) keeps the first press from WebKit
// and the page, and a reminder comes up over the video; a second press in
// the same full screen within `within` goes on, and WebKit leaves. A key held
// down sends Escape again and again: each is kept too and keeps the reminder
// up, so holding it never counts as the second press. Leaving full screen
// any other way, the page's own button, takes the reminder with it.
//
// The reminder is a small pill of its own, a child of the window the key went
// to: WebKit's full-screen window in real use, so it is in that full screen's
// Space and goes where it goes. It never becomes key and the pointer goes
// through it, so the page keeps the keys and the clicks. A test run keeps it
// off every screen, as the recording pill does: whether it is up is what is
// tested there (Bench, probe).

@MainActor
final class FullScreenEscape {
    static let shared = FullScreenEscape()

    /// How long after the first press a second one still leaves.
    static let within: TimeInterval = 2

    /// Whether the reminder is up, for the bench.
    private(set) var showing = false

    /// The full screen waiting for its second press: the window the first
    /// went to, and the page in it.
    private weak var window: NSWindow?
    private weak var page: PageView?
    /// When the wait is over, in seconds since the Mac started.
    private var deadline: TimeInterval = 0
    private var expiry: DispatchWorkItem?
    /// The page leaving full screen by itself: WebKit's word, and the
    /// tab's, which is also how the bench fakes it (Tab.immersed).
    private var leaving: NSKeyValueObservation?
    private var coming: AnyCancellable?
    private var panel: ReminderPanel?

    /// An Escape on its way to a page that fills the screen, with the switch
    /// on: true lets it go on to WebKit, which leaves full screen; false
    /// keeps it, and the reminder says to press again.
    func passes(_ event: NSEvent, to page: PageView) -> Bool {
        guard let window = event.window else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        let waiting = self.window === window && self.page === page && now < deadline
        if event.isARepeat {
            // Held down: kept, and the wait starts again from this one, so
            // the press after letting go is the second. Once the second has
            // gone on, its own repeats are kept too, and bring nothing up.
            if waiting { arm(window, page: page, now: now) }
            return false
        }
        // On its way out already: there is nothing left to guard.
        if page.fullscreenState == .exitingFullscreen {
            disarm(fading: false)
            return true
        }
        if waiting {
            disarm(fading: false)
            return true
        }
        arm(window, page: page, now: now)
        return false
    }

    private func arm(_ window: NSWindow, page: PageView, now: TimeInterval) {
        if self.page !== page { watch(page) }
        self.window = window
        self.page = page
        deadline = now + Self.within
        expiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.disarm(fading: true) }
        }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.within, execute: expiry)
        show(over: window)
    }

    /// The wait over, and the reminder gone with it: faded once its time is
    /// up, at once when the second press or the page itself leaves.
    func disarm(fading: Bool) {
        expiry?.cancel()
        expiry = nil
        leaving = nil
        coming = nil
        window = nil
        page = nil
        deadline = 0
        guard showing else { return }
        showing = false
        guard let panel else { return }
        guard fading, !Motion.reduced, panel.isVisible else { return takeAway(panel) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Up again for a new first press while it faded: it stays.
            MainActor.assumeIsolated {
                guard let self, !self.showing else { return }
                self.takeAway(panel)
            }
        })
    }

    private func watch(_ page: PageView) {
        leaving = page.observe(\.fullscreenState, options: [.new]) { [weak self] page, _ in
            MainActor.assumeIsolated {
                let state = page.fullscreenState
                guard state == .exitingFullscreen || state == .notInFullscreen else { return }
                self?.disarm(fading: false)
            }
        }
        let tab = Browsers.all.lazy.flatMap(\.tabs).first { $0.built === page }
        // Only its changes: $immersed says what it is as soon as it is
        // watched, and the page says it again with every fullscreenchange.
        coming = tab?.$immersed.removeDuplicates().dropFirst().sink { [weak self] on in
            MainActor.assumeIsolated { if !on { self?.disarm(fading: false) } }
        }
    }

    // MARK: - the reminder

    private func show(over window: NSWindow) {
        let first = !showing
        showing = true
        let panel = self.panel ?? ReminderPanel()
        self.panel = panel
        panel.place(over: window)
        guard !Store.testing else { return }
        // A child is ordered in with its window, and kept above it.
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            if !panel.isVisible { panel.alphaValue = 0 }
            window.addChildWindow(panel, ordered: .above)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduced ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
        // The pill is never focused, so VoiceOver is told what it says.
        if first {
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: ReminderView.words,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    private func takeAway(_ panel: ReminderPanel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.alphaValue = 0
    }
}

/// The reminder's window: borderless, never key or main, and nothing the
/// pointer can catch, over the window it is a child of.
private final class ReminderPanel: NSPanel {
    /// From the top of the full screen to the top of the pill.
    static let fromTop: CGFloat = 44

    private let content = NSHostingView(rootView: ReminderView())

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        alphaValue = 0
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Its size for what it says, centred near the top of the window.
    func place(over window: NSWindow) {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let over = window.frame
        content.frame = NSRect(origin: .zero, size: size)
        setFrame(NSRect(x: (over.midX - size.width / 2).rounded(), y: over.maxY - Self.fromTop - size.height,
                        width: size.width, height: size.height), display: false)
    }
}

/// What the pill says, light on dark whatever the appearance, since it lies
/// over a video: "Press Esc again to leave full screen", the key as a key.
private struct ReminderView: View {
    static let words = "Press Esc again to leave full screen"

    var body: some View {
        HStack(spacing: 6) {
            Text("Press")
            Text("Esc")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 6)
                .frame(height: 20)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
            Text("again to leave full screen")
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 18)
        .frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.words)
    }
}
