import SwiftUI
import AppKit

/// Walks every page and checks the panel is the same size on all of them.
///
/// The white bands above and below were the menu bar window growing to
/// fit settings and then not handing the height back to the grid. The
/// answer is that nothing ever changes size, and this is how that stops
/// being a claim. Run it:
///
///     Rafiq.app/Contents/MacOS/Rafiq --panel-sizes
///     Rafiq.app/Contents/MacOS/Rafiq --panel-shot
///
/// The first prints what each page came out as. Every line has to be the
/// same. The second draws each page to a PNG, because a number can be
/// right while the content leaves a strip of the window unpainted, and
/// that strip would look exactly like the thing being fixed.
@MainActor
enum PanelSizeCheck {
    private static let pages: [Panel.Page] =
        [.grid, .settings, .grid, .robot, .grid, .remind, .grid, .phrases, .grid]

    private static func say(_ s: String) { print(s); fflush(stdout) }

    /// A window off to one side holding the real Panel, so what is
    /// measured is the view the menu bar would show, not a copy of it.
    private static func stage() -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: AnyView(
            Panel()
                .environmentObject(Device.shared)
                .environmentObject(Services.shared)
        ))
        host.frame = NSRect(x: 0, y: 0, width: Panel.width, height: Panel.height)
        let w = NSWindow(contentRect: host.frame,
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -4000, y: -4000))   // present, not in the way
        w.orderFront(nil)
        return (w, host)
    }

    private static func settle(_ v: NSView, _ page: Panel.Page) {
        NotificationCenter.default.post(name: Panel.goTo, object: page.rawValue)
        for _ in 0..<50 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        v.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let (_, host) = stage()
        var fails: [String] = []
        let want = NSSize(width: Panel.width, height: Panel.height)
        say("every page should be \(Int(want.width)) x \(Int(want.height))\n")

        for page in pages {
            settle(host, page)
            let s = host.fittingSize
            let ok = abs(s.width - want.width) < 1 && abs(s.height - want.height) < 1
            say(String(format: "  %-9@ %4d x %4d   %@",
                       page.rawValue as NSString, Int(s.width), Int(s.height),
                       ok ? "same as every other page" : "DIFFERENT" as NSString))
            if !ok {
                fails.append("\(page.rawValue) is \(Int(s.width))x\(Int(s.height)), "
                           + "not \(Int(want.width))x\(Int(want.height))")
            }
        }

        say("")
        if fails.isEmpty {
            say("PASS: one size on every page, so the window is set once and never "
              + "asked to give a height back")
            exit(0)
        }
        say("FAIL:"); fails.forEach { say("  - \($0)") }
        exit(1)
    }

    /// A number can be right while the content leaves part of the window
    /// unpainted, and that strip is indistinguishable from the bug. This
    /// draws each page from the view itself, so it needs no permission.
    static func shoot() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let (_, host) = stage()
        for page in [Panel.Page.grid, .settings, .robot] {
            settle(host, page)
            let r = host.bounds
            guard let rep = host.bitmapImageRepForCachingDisplay(in: r) else { continue }
            host.cacheDisplay(in: r, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let path = "/tmp/panel_\(page.rawValue).png"
                try? png.write(to: URL(fileURLWithPath: path))
                say("  \(path)  \(Int(r.width))x\(Int(r.height))pt")
            }
        }
        exit(0)
    }
}
