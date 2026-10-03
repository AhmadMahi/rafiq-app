import SwiftUI
import AppKit

/// Starts the background work the moment the app launches rather than the
/// moment the panel is first opened. Without this the menu bar icon has
/// nothing to report until you click it, which is backwards for an icon
/// whose whole job is to be glanced at.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            if CommandLine.arguments.contains("--panel-sizes") {
                DispatchQueue.main.async { MainActor.assumeIsolated { PanelSizeCheck.run() } }
                return
            }
            if CommandLine.arguments.contains("--panel-shot") {
                DispatchQueue.main.async { MainActor.assumeIsolated { PanelSizeCheck.shoot() } }
                return
            }
            Services.shared.start()
        }
    }
}

/// Apple's menu bar window, not one of ours.
///
/// 1.5.0 replaced this with a hand built NSPanel to stop the window
/// keeping a height it had grown to. It did stop that, and it also
/// stopped the window appearing at all: opening it installed a monitor
/// for clicks outside, and the click on the menu bar icon that opened it
/// counted as one, so it shut in the same breath it opened. The app sat
/// there running with nothing to show for it.
///
/// The band is solved the other way round now, and more simply. Every
/// page is the same size, so the window is set once and never changes,
/// and a window that never grows has nothing left over to show when it
/// does not shrink. Pages that outgrow it scroll inside.
@main
struct RafiqBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var dev = Device.shared

    var body: some Scene {
        MenuBarExtra {
            Panel()
                .environmentObject(Device.shared)
                .environmentObject(Services.shared)
        } label: {
            Image(nsImage: RobotIcon.image(face))
        }
        .menuBarExtraStyle(.window)
    }

    /// Red means it answered before and has stopped. Until the first reply
    /// there is nothing to report, so it stays grey rather than claiming a
    /// fault that has not happened.
    private var face: RobotIcon.State {
        if dev.ip.isEmpty { return .unset }
        switch dev.reachable {
        case .some(true):  return .linked
        case .some(false): return .adrift
        case .none:        return .unset
        }
    }
}

struct Panel: View {
    @EnvironmentObject var dev: Device
    @EnvironmentObject var svc: Services
    @ObservedObject private var ges = Gestures.shared

    @State private var draft = ""
    @State private var showSettings = false
    @State private var showFocus = false
    @State private var showBreak = false
    @State private var showRemind = false
    @State private var showPhrases = false
    @State private var showRobot = false
    @FocusState private var typing: Bool
    @Environment(\.colorScheme) private var systemScheme

    enum Page: String { case grid, settings, robot, pair, focus, breakNow, remind, phrases }

    /// The panel is this size on every page, always.
    ///
    /// The white bands were the menu bar window growing to fit settings
    /// and then not giving the height back when a shorter page replaced
    /// it. Rather than fight a window into shrinking, nothing asks it to:
    /// one size, set once, never changed. Pages shorter than this have
    /// room at the bottom, which reads as a margin because it is inside
    /// the panel. Pages taller than this scroll.
    static let width: CGFloat  = 330
    static let height: CGFloat = 440
    static let pad: CGFloat    = 11
    /// What is left for a page once the header and the padding have had
    /// theirs. Worked out from the numbers above rather than typed in
    /// again, so changing the height changes this too.
    static var pageHeight: CGFloat { height - pad * 2 - 22 - 10 }

    /// One way in for "show this page", used by the window when it opens
    /// so every open starts on the grid, and by the size check so it can
    /// walk the pages and watch the window follow.
    static let goTo = Notification.Name("rafiq.page")

    private func closeOthers(except keep: Page) {
        if keep != .settings { showSettings = false }
        if keep != .robot    { showRobot = false }
        if keep != .focus    { showFocus = false }
        if keep != .breakNow { showBreak = false }
        if keep != .remind   { showRemind = false }
        if keep != .phrases  { showPhrases = false }
    }

    var body: some View {
        // One padding, one spacing, one width. Every page inside is the
        // same shape, so nothing gains or loses a margin on its way in.
        VStack(alignment: .leading, spacing: 10) {
            header
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !dev.status.isEmpty {
                Text(dev.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(Panel.pad)
        // The whole point. Fixed on both axes, the same on every page, so
        // the window is sized once and never asked to change. No
        // background of our own here: the menu bar window already draws
        // one, and a second inside it is what left a band showing round
        // the edges of the first.
        .frame(width: Panel.width, height: Panel.height, alignment: .topLeading)
        .preferredColorScheme(dev.colorScheme)
        .environment(\.colorScheme, dev.colorScheme ?? systemScheme)
        // A focus ring round the gear is what the blue box was. Nothing
        // in a panel like this is reached by tabbing, so nothing in it
        // needs to advertise that it could be.
        .focusEffectDisabled()
        .onAppear {
            closeOthers(except: .grid)
            Task { await dev.refresh() }
        }
        // The door the size check knocks on, so it can walk the pages
        // without a person clicking tiles.
        .onReceive(NotificationCenter.default.publisher(for: Panel.goTo)) { n in
            guard let name = n.object as? String,
                  let page = Page(rawValue: name) else { return }
            closeOthers(except: page)
            switch page {
            case .settings: showSettings = true
            case .robot:    showRobot = true
            case .focus:    showFocus = true
            case .breakNow: showBreak = true
            case .remind:   showRemind = true
            case .phrases:  showPhrases = true
            case .grid, .pair: break
            }
        }
    }

    /// Anything that can outgrow the panel scrolls inside it.
    ///
    /// This was `ViewThatFits(in: .vertical)`, which asks how much height
    /// is going spare before choosing what to show. With the panel a
    /// fixed size that question finally has an answer, but it does not
    /// need asking: the height is known, so a page is either shorter than
    /// it or it scrolls. Measuring happens inside the scroll view, where
    /// the content is offered as much height as it likes and so does not
    /// depend on the frame we put round it.
    private func scrolling<V: View>(@ViewBuilder _ v: @escaping () -> V) -> some View {
        Scrolled(cap: Panel.pageHeight) { v() }
    }

    private struct Scrolled<V: View>: View {
        let cap: CGFloat
        @ViewBuilder let content: () -> V
        @State private var tall: CGFloat = 0

        private struct H: PreferenceKey {
            static var defaultValue: CGFloat { 0 }
            static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
                value = max(value, nextValue())
            }
        }

        private var overflows: Bool { tall > cap + 0.5 }

        // The measurement may decide whether the page scrolls. It may
        // not decide how wide the page is.
        //
        // The gutter used to be ten points only when the content
        // overflowed, which laid the content out from a measurement of
        // itself: add the gutter, the text has ten points less to wrap
        // in, so it gets taller, so the height changes, so whether it
        // overflows can change back. A page sitting near that line
        // never settles and the panel churns through layout passes
        // for as long as it is open. Constant now, so nothing that
        // feeds the measurement depends on it. Scrolling and the
        // indicator do not affect how anything is laid out, so they
        // can still be told.
        var body: some View {
            ScrollView(.vertical) {
                content()
                    .padding(.trailing, 10)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: H.self, value: g.size.height)
                    })
            }
            .scrollIndicators(overflows ? .visible : .hidden)
            .scrollDisabled(!overflows)
            .frame(maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(H.self) { h in
                if abs(h - tall) > 0.5 { tall = h }
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        if dev.ip.isEmpty {
            FirstRun()
        } else if showSettings {
            scrolling { SettingsPane(showing: $showSettings) }
        } else if showRobot {
            scrolling { RobotSettings(showing: $showRobot) }
        } else if dev.pairing {
            PairView()
        } else if showFocus {
            Minutes(title: "Focus for", choices: [5, 10, 15, 25, 30, 45, 60, 90],
                    note: "The panel shows the countdown, then rests, then shows it "
                        + "again. It will not drop off until the time is up.",
                    showing: $showFocus) { m in
                Task { await dev.startFocus(m) }
            }
        } else if showBreak {
            Minutes(title: "On a break for", choices: [5, 10, 15, 20, 30, 45, 60, 90],
                    note: "The robot holds the sign and your Mac locks straight away. "
                        + "The display comes back when the time is up.",
                    showing: $showBreak) { m in
                Task {
                    await dev.startBreak(m)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    Screen.lock()
                }
            }
        } else if showRemind {
            scrolling { RemindSheet(showing: $showRemind) }
        } else if showPhrases {
            Phrases(showing: $showPhrases)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                grid
                compose
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text("RAFIQ")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
            if dev.focusLeft > 0 {
                Text("\(max(0, dev.focusLeft) / 60 + 1)m")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Button { showSettings.toggle(); closeOthers(except: .settings) } label: {
                // Filled when you are in settings, hollow when you are
                // not. It said the same thing in blue before, and blue on
                // this gear has been asked about once too often to keep
                // arguing that this particular one is the good kind.
                Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Settings")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Quit Rafiq")
        }
    }

    private var dot: Color {
        if dev.ip.isEmpty { return .secondary.opacity(0.5) }
        switch dev.reachable {
        case .some(true):  return dev.paired && !dev.linked ? .orange : .green
        case .some(false): return .red
        default:           return .secondary.opacity(0.5)
        }
    }

    private var compose: some View {
        HStack(spacing: 7) {
            TextField("Say something", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($typing)
                .onSubmit(send)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.07)))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || dev.busy)
            .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                             ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.accentColor))
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
                  spacing: 7) {

            // row one
            Tile(icon: "text.quote", name: "Phrases", detail: "saved lines") {
                showPhrases = true
            }
            Tile(icon: dev.focusRunning ? "stop.circle" : "timer", name: "Focus",
                 detail: dev.focusRunning ? "\(dev.focusLeft / 60 + 1) min left  ·  stop" : "",
                 on: dev.focusRunning) {
                if dev.focusRunning { Task { await dev.stopFocus() } } else { showFocus = true }
            }
            Tile(icon: "eyes", name: "Follow",
                 detail: dev.blocked(.follow) ?? "the pointer",
                 on: dev.following, enabled: dev.blocked(.follow) == nil) {
                Task { await dev.setFollow(!dev.following); svc.syncCursor() }
            }

            // row two
            Tile(icon: "wind", name: "Relax",
                 detail: dev.blocked(.relax) ?? "screensaver",
                 on: dev.relaxing, enabled: dev.blocked(.relax) == nil) {
                Task { await dev.setRelax(!dev.relaxing) }
            }
            Tile(icon: "doc.on.clipboard", name: "Clipboard",
                 detail: dev.watchClipboard ? "mirroring" : "off", on: dev.watchClipboard) {
                dev.watchClipboard.toggle(); svc.syncClipboard()
            }
            Tile(icon: "figure.walk", name: "Breaks",
                 detail: dev.breakOn ? "every \(dev.breakMins)m" : "off", on: dev.breakOn) {
                dev.breakOn.toggle(); svc.syncBreaks()
            }

            // row three
            Tile(icon: "bell", name: "Remind me",
                 detail: Reminders.shared.pending.isEmpty
                       ? "nothing set" : "\(Reminders.shared.pending.count) waiting",
                 on: !Reminders.shared.pending.isEmpty) {
                showRemind = true
            }
            Tile(icon: "cup.and.saucer", name: "On a break",
                 detail: dev.dndLeft > 0 ? "\(dev.dndLeft / 60 + 1) min left"
                                         : (dev.blocked(.breakNow) ?? "locks the Mac"),
                 on: dev.dndLeft > 0, enabled: dev.blocked(.breakNow) == nil) {
                if dev.dndLeft > 0 { Task { await dev.endBreak() } } else { showBreak = true }
            }
            Tile(icon: "video", name: "Camera & mic",
                 detail: dev.watchAV ? (svc.avLive ? "live now" : "watching") : "off",
                 on: dev.watchAV) {
                dev.watchAV.toggle(); svc.syncAV()
            }

            // row four
            //
            // Gestures sits here and Update has gone into the robot's
            // settings. Update is something you do now and then and
            // this is something you switch on and off, and a grid you
            // glance at should be made of the second kind.
            Tile(icon: "hand.tap", name: "Gestures",
                 detail: ges.on ? (ges.micLive ? (ges.muted ? "muted" : "on a call") : "on")
                                : "off",
                 on: ges.on, enabled: dev.reachable == true) {
                ges.on.toggle()
            }
            Tile(icon: "moon.zzz", name: "Deep sleep",
                 detail: dev.blocked(.deepSleep) ?? "power to wake",
                 enabled: dev.blocked(.deepSleep) == nil) {
                Task { await dev.deepSleep() }
            }
            Tile(icon: "slider.horizontal.3", name: "Settings", detail: "the robot") {
                showRobot = true; closeOthers(except: .robot)
            }
        }
    }

    // ---------------------------------------------------------------

    private func send() {
        let t = draft
        draft = ""
        Task { await dev.say(t) }
    }

}

// ===================================================================

/// Nothing is set up yet, so there is one thing to do and this says so
/// rather than opening a window full of things that cannot be used.
struct FirstRun: View {
    @EnvironmentObject var dev: Device
    @State private var addr = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Where is the robot?").font(.system(size: 12, weight: .semibold))
            Text("Its SYSTEM screen shows the address.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                TextField("192.168.1.42", text: $addr)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.07)))
                    .onSubmit(save)
                Button("Save", action: save).font(.system(size: 11))
            }
        }
    }
    private func save() {
        dev.ip = addr.trimmingCharacters(in: .whitespaces)
        Task { await dev.refresh() }
    }
}

// ===================================================================
//  One screenful of pixels, to prove the canvas works end to end.
//  128 by 64, one bit each, top row first, which is the layout the
//  SSD1306 buffer already uses.
// ===================================================================
enum TestCard {
    static func bytes() -> Data {
        var buf = [UInt8](repeating: 0, count: 1024)
        func plot(_ x: Int, _ y: Int) {
            guard (0..<128).contains(x), (0..<64).contains(y) else { return }
            buf[x + (y >> 3) * 128] |= UInt8(1 << (y & 7))
        }
        // a frame, and a heart in the middle of it
        for x in 0..<128 { plot(x, 0); plot(x, 63) }
        for y in 0..<64  { plot(0, y); plot(127, y) }
        for t in stride(from: 0.0, through: 6.2832, by: 0.004) {
            let s = 2.1
            let hx = 16 * pow(sin(t), 3)
            let hy = 13 * cos(t) - 5 * cos(2*t) - 2 * cos(3*t) - cos(4*t)
            plot(64 + Int(hx * s / 2.4), 32 - Int(hy * s / 2.4))
        }
        return Data(buf)
    }
}
