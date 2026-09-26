import SwiftUI
import AppKit

/// Walks the pages and prints what the window actually became.
///
/// The bands above and below the panel were the window keeping a height
/// it had grown to for a taller page. It is not something a screenshot
/// argues about and not something a person should have to check by eye
/// after every release, so the app can be asked:
///
///     Rafiq.app/Contents/MacOS/Rafiq --panel-sizes
///
/// The one that matters is the last line. Going settings, then back to
/// the grid, has to give the grid's own height back, not the settings
/// height with white in the gap.
@MainActor
enum PanelSizeCheck {
    private static func say(_ line: String) {
        print(line); fflush(stdout)
    }

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        Bar.shared.open()
        // activation is not instant, so let it happen before asking
        for _ in 0..<50 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        var seen: [String: CGFloat] = [:]
        var fails: [String] = []

        func go(_ page: Panel.Page) -> CGFloat {
            NotificationCenter.default.post(name: Panel.goTo, object: page.rawValue)
            // SwiftUI lays out on the run loop, so let it.
            for _ in 0..<40 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            Bar.shared.fit()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return Bar.shared.windowHeight
        }

        say("width \(Int(Bar.shared.windowWidth))pt")
        say("app active \(NSApp.isActive)  policy \(NSApp.activationPolicy().rawValue)  "
            + "visible \(Bar.shared.isOpen)  key \(Bar.shared.isKey)  "
            + "canBecomeKey \(Bar.shared.canBecomeKey)")
        say("takes the keyboard: \(Bar.shared.isKey ? "yes" : "NO, Say something would be dead")\n")
        if !Bar.shared.isKey && NSApp.isActive { fails.append("the panel cannot become key") }
        for page in [Panel.Page.grid, .settings, .grid, .robot, .grid,
                     .remind, .grid, .phrases, .grid] {
            let h = go(page)
            say(String(format: "  %-9@  %4dpt", page.rawValue as NSString, Int(h)))
            if let before = seen[page.rawValue], abs(before - h) > 1 {
                fails.append("\(page.rawValue) came back \(Int(h))pt, was \(Int(before))pt")
            }
            seen[page.rawValue] = h
            if h < 40 { fails.append("\(page.rawValue) measured \(Int(h))pt, which is nothing") }
        }

        say("")
        let grid = seen["grid"] ?? 0
        for (name, h) in seen.sorted(by: { $0.key < $1.key }) where name != "grid" {
            if h > grid { say("  \(name) is \(Int(h - grid))pt taller than the grid, as it should be") }
        }
        if fails.isEmpty {
            say("\nPASS: every page sets the window to its own height, and going back takes it down again")
            exit(0)
        }
        say("\nFAIL:"); fails.forEach { say("  - \($0)") }
        exit(1)
    }

    /// The numbers say the window is exactly as tall as its content. This
    /// says whether the content actually covers it, which is a different
    /// question and the one the screenshots were really about: a band can
    /// also be the window painting nothing where the view does not reach.
    /// Drawn from the view itself, so it needs no screen recording.
    /// Launched the way a person launches it, through LaunchServices,
    /// because a binary started straight from a shell is not allowed to
    /// bring itself to the front and would fail this for the wrong reason.
    static func keyCheck() {
        // macOS will not let a menu bar accessory bring itself to the
        // front with no user event behind it, and a window in an app that
        // is not frontmost cannot be key. Clicking the icon is that user
        // event, so in real use this is not a question; in a test with
        // nobody clicking anything it always would be. Asking to be a
        // normal app for the length of the check takes that out of the
        // way and leaves the thing actually worth knowing: whether this
        // window can hold the keyboard once the app has it.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Bar.shared.open()
        var out = ""
        for step in 1...6 {
            for _ in 0..<50 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            out += "after \(step)  active \(NSApp.isActive)  visible \(Bar.shared.isOpen)  "
                 + "key \(Bar.shared.isKey)  height \(Int(Bar.shared.windowHeight))\n"
            if Bar.shared.isKey { break }
        }
        if Bar.shared.isKey {
            out += "PASS: it takes the keyboard\n"
        } else if !NSApp.isActive {
            // Not a result. macOS would not bring the app forward, so no
            // window of it could be key whatever this one is like. What
            // is worth saying is what makes it safe anyway: the panel is
            // not a non activating one, so a click inside it brings the
            // app forward and makes it key, and clicking into the field
            // is how anybody types into it.
            out += "UNTESTED: macOS never made the app frontmost here, so no window "
                 + "of it could be key. canBecomeKey \(Bar.shared.canBecomeKey), "
                 + "and the panel activates on a click, which is how the field is reached.\n"
        } else {
            out += "FAIL: app is frontmost and the panel still will not take the keyboard\n"
        }
        try? out.write(toFile: "/tmp/rafiq_key.txt", atomically: true, encoding: .utf8)
        exit(Bar.shared.isKey || !NSApp.isActive ? 0 : 1)
    }

    /// The one path that matters and the one nothing was testing: icon
    /// to window. Everything else measured a window that had been opened
    /// by hand, which is not how anybody opens it.
    static func clickCheck() {
        var fail = false
        var out = "before: visible \(Bar.shared.isOpen)\n"
        out += "press 1: " + Bar.shared.pressTheIcon() + "\n"
        for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        out += "settled: visible \(Bar.shared.isOpen)  height \(Int(Bar.shared.windowHeight))\n"
        Bar.shared.pokeResignKey()
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        out += "after losing key: visible \(Bar.shared.isOpen)"
            + (Bar.shared.isOpen ? "  (stays open, which is the fix)\n" : "  <-- it shut itself\n")
        if !Bar.shared.isOpen { fail = true; Bar.shared.open()
            for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
        // The press that opened it can still land here. Reopen and ask
        // straight away, with no waiting, which is the real ordering.
        Bar.shared.close(); Bar.shared.open()
        Bar.shared.clickedAway(at: .zero)
        out += "its own opening click: visible \(Bar.shared.isOpen)"
            + (Bar.shared.isOpen ? "  (ignored, good)\n" : "  <-- closed on its own opening click\n")
        if !Bar.shared.isOpen { fail = true; Bar.shared.open() }
        // and a click away once it has settled does close it
        for _ in 0..<70 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        Bar.shared.clickedAway(at: .zero)
        out += "a click away, settled: visible \(Bar.shared.isOpen)"
            + (Bar.shared.isOpen ? "  <-- it should have closed\n" : "  (closed, good)\n")
        if Bar.shared.isOpen { fail = true }
        Bar.shared.open()
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        out += "press 2: " + Bar.shared.pressTheIcon() + "\n"
        for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        out += "settled: visible \(Bar.shared.isOpen)\n"
        out += "press 3: " + Bar.shared.pressTheIcon() + "\n"
        for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        out += "settled: visible \(Bar.shared.isOpen)  height \(Int(Bar.shared.windowHeight))\n"
        out += fail ? "\nFAIL\n" : "\nPASS: the icon opens it, and only a real click away shuts it\n"
        try? out.write(toFile: "/tmp/rafiq_click.txt", atomically: true, encoding: .utf8)
        exit(fail ? 1 : 0)
    }

    static func shoot() {
        setvbuf(stdout, nil, _IOLBF, 0)
        Bar.shared.open()
        for page in [Panel.Page.grid, .settings, .robot] {
            NotificationCenter.default.post(name: Panel.goTo, object: page.rawValue)
            for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            Bar.shared.fit()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let v = Bar.shared.rootView else { continue }
            let r = v.bounds
            guard let rep = v.bitmapImageRepForCachingDisplay(in: r) else { continue }
            v.cacheDisplay(in: r, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let path = "/tmp/panel_\(page.rawValue).png"
                try? png.write(to: URL(fileURLWithPath: path))
                say("  \(path)  \(Int(r.width))x\(Int(r.height))pt")
            }
        }
        exit(0)
    }
}
