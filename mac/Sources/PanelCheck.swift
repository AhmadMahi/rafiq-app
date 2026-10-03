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
///
/// Run it against a clean settings domain, which `mac/panelcheck.sh`
/// does for you. Run from an installed bundle on a Mac that has a
/// robot address saved, it stops after the first page and never
/// finishes: the pages do real network work while this is spinning
/// the run loop by hand, and the two do not cooperate. That looks
/// exactly like a layout that will not settle, and it is not one.
@MainActor
enum PanelSizeCheck {
    private static let pages: [Panel.Page] =
        [.grid, .settings, .grid, .robot, .grid, .remind, .grid, .phrases, .grid]

    private static func say(_ s: String) { print(s); fflush(stdout) }
    /// No newline, so the result can finish the line the page name
    /// started. The name has to be out before the work: a page that
    /// will not settle takes AppKit's layout with it on this thread,
    /// where nothing can time it out, and the half written line is the
    /// only evidence of which page it was.
    private static func sayPart(_ s: String) { print(s, terminator: ""); fflush(stdout) }

    /// Fill the pages in. A page drawn against an unset device shows
    /// the "where is the robot" prompt, which is four lines tall and
    /// proves nothing about the page that is actually shipped.
    private static func furnish() {
        Device.inert = true
        let d = Device.shared
        d.ip = "192.168.0.123"
        d.token = "0123456789abcdef"
        d.paired = true
        d.reachable = true
        d.linked = true
        d.version = "5.2.0"
        d.bike = true
        d.gesture = true
        Gestures.shared.on = true
        d.plate = "KA 50 HJ 5683"
        d.make = "Royal Enfield"
        d.model = "Meteor 350"
        d.owner = "Ahmed"
        let r = Reminders.shared
        if r.pending.isEmpty {
            r.add("Service the bike", inMinutes: 90)
            r.add("Submit the integration report before the review", inMinutes: 200)
            r.add("Call Amma", inMinutes: 320)
        }
    }

    /// A window off to one side holding the real Panel, so what is
    /// measured is the view the menu bar would show, not a copy of it.
    private static func stage() -> (NSWindow, NSView) {
        furnish()
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
        say("every page should be \(Int(want.width)) x \(Int(want.height)), "
          + "with nothing running off the bottom\n")

        for page in pages {
            sayPart(String(format: "  %-9@ ", page.rawValue as NSString))
            settle(host, page)
            let s = host.bounds.size
            var why: [String] = []
            if abs(s.width - want.width) >= 1 || abs(s.height - want.height) >= 1 {
                why.append("is \(Int(s.width))x\(Int(s.height))")
            }
            if let cut = cutOff(host) { why.append(cut) }
            say(String(format: "%4d x %4d   %@",
                       Int(s.width), Int(s.height),
                       why.isEmpty ? "fits, same as every other page"
                                   : why.joined(separator: ", ") as NSString))
            if !why.isEmpty { fails.append("\(page.rawValue): \(why.joined(separator: ", "))") }
        }

        say("")
        if fails.isEmpty {
            say("PASS: one size on every page and nothing cut off at the bottom of any")
            exit(0)
        }
        say("FAIL:"); fails.forEach { say("  - \($0)") }
        exit(1)
    }

    /// Whether the page is still drawing where the window has run out.
    ///
    /// This used to ask the hosting view for its fittingSize. That
    /// never returns on a page with much in it: the measurement
    /// recurses and the check stops dead, which reads as a hang rather
    /// than a failure, and it is why the check had only ever been run
    /// against an app with no robot set up, where every page is nearly
    /// empty. It was also the wrong question. The panel declares a hard
    /// frame, so the size is not in doubt. What is in doubt is whether
    /// a page has more in it than the frame holds, and the way that
    /// shows is content painted hard against the last few rows with no
    /// margin under it.
    ///
    /// The panel draws no background of its own, so transparent is the
    /// normal state of any row; only ink in the bottom margin means
    /// something.
    private static func cutOff(_ v: NSView) -> String? {
        let r = v.bounds
        guard let rep = v.bitmapImageRepForCachingDisplay(in: r) else { return nil }
        v.cacheDisplay(in: r, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let scale = CGFloat(h) / r.height
        // Inside the padding there should be nothing at all.
        let margin = max(2, Int((Panel.pad - 2) * scale))
        var ink = 0
        for y in (h - margin)..<h {
            for x in stride(from: 1, to: w - 1, by: 3) {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { ink += 1 }
            }
        }
        return ink > 6 ? "content running into the bottom margin (\(ink) marks)" : nil
    }

    /// A number can be right while the content leaves part of the window
    /// unpainted, and that strip is indistinguishable from the bug. This
    /// draws each page from the view itself, so it needs no permission.
    static func shoot() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let (_, host) = stage()
        for page in pages where page != .grid || true {
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
