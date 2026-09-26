import SwiftUI
import AppKit

/// Starts the background work the moment the app launches rather than the
/// moment the panel is first opened. Without this the menu bar icon has
/// nothing to report until you click it, which is backwards for an icon
/// whose whole job is to be glanced at.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated { Services.shared.start() }
    }
}

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

    @State private var draft = ""
    @State private var showSettings = false
    @State private var showFocus = false
    @State private var showBreak = false
    @State private var showRemind = false
    @State private var showPhrases = false
    @State private var showRobot = false
    @FocusState private var typing: Bool
    @Environment(\.colorScheme) private var systemScheme

    enum Page { case grid, settings, robot, pair, focus, breakNow, remind, phrases }

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
            if !dev.status.isEmpty {
                Text(dev.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(11)
        .frame(width: 330)
        // Takes its natural height rather than whatever it is offered.
        // Without this a scroll view inside will happily swell to fill
        // the window and leave the content floating in the middle of it.
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: showSettings)
        .animation(.easeOut(duration: 0.16), value: showRobot)
        .animation(.easeOut(duration: 0.16), value: showFocus)
        .animation(.easeOut(duration: 0.16), value: showBreak)
        .animation(.easeOut(duration: 0.16), value: showRemind)
        .animation(.easeOut(duration: 0.16), value: showPhrases)
        .animation(.easeOut(duration: 0.16), value: dev.pairing)
        .preferredColorScheme(dev.colorScheme)
        .environment(\.colorScheme, dev.colorScheme ?? systemScheme)
        .onAppear {
            // Whatever page you were on last time, it opens on the grid.
            closeOthers(except: .grid)
            Task { await dev.refresh() }
        }
    }

    /// Anything that can outgrow the panel scrolls inside it, with the
    /// bar given a gutter of its own so it stops sitting on the content.
    private func scrolling<V: View>(@ViewBuilder _ v: @escaping () -> V) -> some View {
        // A scroll view takes every inch it is offered, so capping it at
        // 440 left short pages padded out with slack. This gives the
        // plain view first and only falls back to scrolling when the
        // content genuinely will not fit.
        ViewThatFits(in: .vertical) {
            v()
            ScrollView(.vertical) { v().padding(.trailing, 10) }
                .frame(height: 440)
                .scrollIndicators(.visible)
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
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(showSettings ? AnyShapeStyle(Color.accentColor)
                                                  : AnyShapeStyle(Color.secondary))
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
            Tile(icon: "arrow.down.circle", name: "Update", detail: "the robot") {
                Task { await dev.checkUpdate() }
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
