import SwiftUI
import AppKit

/// The menu bar item and the window under it.
///
/// This used to be `MenuBarExtra(.window)`, and the white bands above and
/// below the panel were that window refusing to shrink. It grew to fit
/// settings, you went back to the grid, and it stayed tall: the leftover
/// is what showed as a margin. Nothing that can be done to the SwiftUI
/// content fixes that, because the content was already the right size and
/// the window was not listening. Three attempts at it from the content
/// side is enough to say so plainly.
///
/// So the window is ours now. `NSHostingController` publishes the size
/// SwiftUI actually wants through `preferredContentSize`, and every time
/// that changes this sets the window to exactly that, upwards or
/// downwards, and puts it back under the menu bar icon. There is no
/// slack for a band to live in, because there is no part of the window
/// that is not content.
@MainActor
final class Bar: NSObject, NSWindowDelegate {
    static let shared = Bar()

    private var item: NSStatusItem!
    private var panel: Sheet!
    private var host: NSHostingController<AnyView>!
    private var beat: Timer?
    private var outside: Any?
    private var fitting = false          // fit() is not allowed to call itself
    private var fitQueued = false
    private var lastFit: NSSize = .zero

    /// A panel rather than a window: it can float over other apps without
    /// taking the foreground away from them, and it can still take a key
    /// press, which a non activating panel otherwise cannot and which the
    /// "Say something" field needs.
    final class Sheet: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    func install() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = RobotIcon.image(.unset)
        item.button?.target = self
        item.button?.action = #selector(toggle)

        host = NSHostingController(rootView: AnyView(
            Panel()
                .environmentObject(Device.shared)
                .environmentObject(Services.shared)
        ))
        // Deliberately empty. With .preferredContentSize, SwiftUI resizes
        // the window itself from inside its own layout pass: the resize
        // lays the content out, the layout resizes the window, and the
        // stack is gone in about a second. It crashed on the way into
        // settings every single time, and the recursion bottomed out in
        // NSHostingView.updateAnimatedWindowSize. So SwiftUI does not get
        // to touch the window. It lays the content out, this reads how
        // big that came out, and this sets the window. One direction.
        host.sizingOptions = []

        panel = Sheet(contentRect: NSRect(x: 0, y: 0, width: 330, height: 200),
                      styleMask: [.fullSizeContentView, .borderless],
                      backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear      // the SwiftUI view draws the only one
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        // Pages change from tiles inside the panel as well as from the
        // page notification, so rather than trying to catch every way in,
        // this looks at what the content came out as. Often enough to be
        // invisible, and cheap because fit() does nothing at all unless
        // the number has actually moved.
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.fit()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        beat = t
    }

    /// The icon, green when it is answering and red when it has stopped.
    func face(_ s: RobotIcon.State) { item?.button?.image = RobotIcon.image(s) }

    var isOpen: Bool { panel?.isVisible ?? false }

    /// What the window actually is, for the check that walks the pages.
    var windowHeight: CGFloat { panel?.frame.height ?? 0 }
    var windowWidth:  CGFloat { panel?.frame.width  ?? 0 }
    var rootView: NSView? { panel?.contentView }
    var isKey: Bool { panel?.isKeyWindow ?? false }
    var canBecomeKey: Bool { panel?.canBecomeKey ?? false }

    @objc private func toggle() { isOpen ? close() : open() }

    func open() {
        guard let panel else { return }
        // Every open starts on the grid. The window is kept between opens
        // now, so nothing else would reset it.
        NotificationCenter.default.post(name: Panel.goTo, object: Panel.Page.grid.rawValue)
        fit()
        // Order matters. The window has to exist on screen before it can
        // be made key, and an accessory app has to be brought forward for
        // a key press to reach it at all, or "Say something" is a field
        // you can click and cannot type into.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Activation is not instant. If the first go did not take, try
        // again once the run loop has caught up rather than leaving a
        // field that can be clicked and not typed into.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let p = self?.panel, p.isVisible, !p.isKeyWindow else { return }
                NSApp.activate(ignoringOtherApps: true)
                p.makeKey()
            }
        }
        // A click anywhere else puts it away, the way a menu does.
        outside = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let o = outside { NSEvent.removeMonitor(o); outside = nil }
    }

    func windowDidResignKey(_ n: Notification) {
        // Only when the click really went elsewhere. A menu opening inside
        // the panel takes key too, and closing on that would make every
        // popup in here a way of dismissing the window.
        guard NSApp.keyWindow !== panel else { return }
        close()
    }

    /// The window becomes exactly the size of what is in it, and moves to
    /// stay under the icon. Called on every change of page, so going back
    /// to a short page takes the height back down with it.
    func needsFit() {
        guard !fitQueued else { return }
        fitQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fitQueued = false
                self.fit()
            }
        }
    }

    func fit() {
        guard !fitting, let panel, let host else { return }
        fitting = true
        defer { fitting = false }

        // What the content actually came out as, laid out at our width.
        // Nothing here asks SwiftUI what size it would like the window to
        // be, which is the question that recursed.
        host.view.layoutSubtreeIfNeeded()
        var s = host.view.fittingSize
        s.width = 330
        if s.height < 1 { s = host.preferredContentSize }
        // Whole points. A size that lands a fraction either side of the
        // same number would otherwise look like a change forever.
        s = NSSize(width: s.width.rounded(), height: s.height.rounded())
        guard s.width >= 1, s.height >= 1 else { return }

        if s != lastFit || panel.contentRect(forFrameRect: panel.frame).size != s {
            lastFit = s
            panel.setContentSize(s)
        }
        place()
    }

    /// Under the icon, nudged in from the edge, and never off the screen.
    private func place() {
        guard let panel,
              let button = item?.button,
              let win = button.window,
              let screen = win.screen ?? NSScreen.main else { return }
        let anchor = win.convertToScreen(button.convert(button.bounds, to: nil))
        let w = panel.frame.width
        var x = anchor.midX - w / 2
        let vis = screen.visibleFrame
        x = min(max(x, vis.minX + 8), vis.maxX - w - 8)
        let y = anchor.minY - panel.frame.height - 6
        let want = NSPoint(x: x.rounded(), y: max(y, vis.minY + 8).rounded())
        // Only when it has actually moved. This runs on a heartbeat, and
        // setting the same origin twelve times a second is a way to make
        // a window shimmer for no reason.
        let now = panel.frame.origin
        if abs(now.x - want.x) > 0.5 || abs(now.y - want.y) > 0.5 {
            panel.setFrameOrigin(want)
        }
    }
}
