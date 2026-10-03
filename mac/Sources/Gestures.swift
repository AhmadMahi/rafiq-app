import Foundation
import AppKit
import Network
import CoreAudio
import Carbon.HIToolbox

// ================================================================
//  GESTURE MODE
// ================================================================
//  The robot's pad, pointed at this Mac.
//
//  While it is on, one press and two presses stop driving the robot
//  and arrive here instead, and what they do depends on which
//  application you have in front of you. The robot is not remembering
//  any of this: it comes up as a robot, this app switches the mode on
//  when it finds it, and the robot drops it the moment this app stops
//  answering. Quitting Rafiq is therefore enough to get your robot
//  back, and so is holding the pad for four seconds.

/// What a press does.
enum GAction: Codable, Equatable, Hashable {
    case nothing
    case openApp(String)         // a bundle id
    case shortcut(String)        // a Shortcuts shortcut, by name
    case keys(String)            // "cmd+shift+a"

    var label: String {
        switch self {
        case .nothing:        return "nothing"
        case .openApp(let b): return "open " + (GAction.appName(b) ?? b)
        case .shortcut(let n): return "run \(n)"
        case .keys(let k):    return k
        }
    }
    /// Needs Accessibility, which cannot be asked for in code.
    var needsTrust: Bool { if case .keys = self { return true }; return false }

    static func appName(_ bundleId: String) -> String? {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return FileManager.default.displayName(atPath: u.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// One press and two presses, for one application or for everything.
struct GMap: Codable, Equatable, Identifiable {
    var id = UUID()
    /// nil is the fallback used when nothing more specific matches.
    var bundleId: String?
    var one: GAction = .nothing
    var two: GAction = .nothing
    var name: String {
        guard let b = bundleId else { return "Everything else" }
        return GAction.appName(b) ?? b
    }
}

@MainActor
final class Gestures: ObservableObject {
    static let shared = Gestures()

    /// The robot is told this on every refresh, so a robot that
    /// restarts comes back into the mode on its own.
    @Published var on = false { didSet { persist(); push() } }
    /// While the microphone is live this takes over from the mappings
    /// below: one press kills the mic and the camera, two brings the
    /// mic back. Turning a camera on for someone is not something a
    /// tap should do, so that stays yours.
    @Published var micTakesOver = true { didSet { persist() } }
    @Published var maps: [GMap] = [GMap(bundleId: nil)] { didSet { persist() } }

    /// What the mic is doing, as far as we have set it.
    @Published private(set) var muted = false
    /// Whether anything is listening. Set by Services, which owns the
    /// watcher, rather than reached for through a second singleton.
    @Published var micLive = false
    @Published var camLive = false
    /// The last press that arrived and what it did, for the panel.
    @Published private(set) var lastSaid = ""
    @Published private(set) var frontApp = ""

    private var listener: NWListener?
    private let key = "gestures"

    private init() {
        load()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.readFront() }
            }
        readFront()
    }

    // ------------------------------------------------------------
    //  who is in front
    // ------------------------------------------------------------
    //  NSWorkspace gives the application, with no permission at all.
    //  What it does not give is the window, the document or the
    //  browser tab: those need Accessibility or Screen Recording. So
    //  "you are in Chrome" is free and "you are in Meet" is not, which
    //  is why the mute table below is keyed on the browser and not on
    //  the meeting.
    private func readFront() {
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }

    // ------------------------------------------------------------
    //  the listening end
    // ------------------------------------------------------------
    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: 4211)!)
            l.newConnectionHandler = { [weak self] c in
                c.start(queue: .main)
                Task { @MainActor in self?.receive(on: c) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            NSLog("gesture listener did not start: \(error)")
        }
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                if let d = data, let s = String(data: d, encoding: .utf8) { self.heard(s, from: c) }
                self.receive(on: c)
            }
        }
    }

    /// A packet that presses keys on your Mac is a packet anyone on
    /// the network could send, so both halves are checked: the word,
    /// and that it came from the robot and not from somewhere else.
    private func heard(_ raw: String, from c: NWConnection) {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let token = Device.shared.token
        guard !token.isEmpty, parts[0] == token else {
            NSLog("gesture packet with the wrong word, ignored")
            return
        }
        if case let .hostPort(host, _) = c.endpoint {
            let from = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
            let want = Device.shared.ip.trimmingCharacters(in: .whitespaces)
            guard !want.isEmpty, from == want else {
                NSLog("gesture packet from \(from), expected \(want), ignored")
                return
            }
        }
        act(parts[1])
    }

    // ------------------------------------------------------------
    //  what a press does
    // ------------------------------------------------------------
    private func act(_ which: String) {
        readFront()
        let single = (which == "1")

        if micTakesOver && micLive {
            if single { muteAll() } else { unmute() }
            return
        }
        let m = mapping(for: frontApp)
        run(single ? m.one : m.two)
    }

    /// The most specific mapping that matches, or the fallback.
    func mapping(for bundleId: String) -> GMap {
        maps.first { $0.bundleId == bundleId }
            ?? maps.first { $0.bundleId == nil }
            ?? GMap(bundleId: nil)
    }

    private func run(_ a: GAction) {
        switch a {
        case .nothing:
            say("nothing set for this one")
        case .openApp(let b):
            guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else {
                say("cannot find that app"); return
            }
            NSWorkspace.shared.openApplication(at: u, configuration: .init())
            say("opened \(GAction.appName(b) ?? b)")
        case .shortcut(let n):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", n]
            do { try p.run() } catch { say("could not run \(n)"); return }
            say("ran \(n)")
        case .keys(let spec):
            guard Keys.trusted else { say("needs Accessibility"); return }
            if Keys.press(spec) { say(spec) } else { say("could not read \(spec)") }
        }
    }

    private func say(_ s: String) {
        lastSaid = s
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000)
               await MainActor.run { if self.lastSaid == s { self.lastSaid = "" } } }
    }

    // ------------------------------------------------------------
    //  mute
    // ------------------------------------------------------------
    //  The microphone can be stopped at the device, with no
    //  permission, and then nothing is heard in any application at
    //  all. What that does not do is tell Zoom, which goes on showing
    //  you as unmuted to everybody else even though you are silent.
    //  So both: the device, always, and the application's own key if
    //  it is one we know and Accessibility has been granted.
    //
    //  The camera has no equivalent. macOS has no public way to stop
    //  one, so the only way off is the application's own key, which
    //  means it works in the three we know and nowhere else.
    func muteAll() {
        Audio.setInputMuted(true)
        muted = true
        var did = "mic off"
        if let app = Calls.known(frontApp), Keys.trusted {
            if Keys.press(app.mic) { did += ", told \(app.name)" }
            if Keys.press(app.cam) { did += " and the camera" }
        } else if Calls.known(frontApp) != nil {
            did += ", camera needs Accessibility"
        }
        say(did)
        tellRobot()
    }

    func unmute() {
        Audio.setInputMuted(false)
        muted = false
        var did = "mic on"
        if let app = Calls.known(frontApp), Keys.trusted, Keys.press(app.mic) {
            did += ", told \(app.name)"
        }
        say(did)
        tellRobot()
    }

    /// So the robot can show it across the desk, which is most of
    /// what this feature is for.
    private func tellRobot() {
        let c = camLive, m = micLive, mu = muted
        Task { await Device.shared.setBusy(cam: c, mic: m, muted: mu) }
    }

    // ------------------------------------------------------------
    //  keeping the robot in step
    // ------------------------------------------------------------
    func push() {
        Task { await Device.shared.setGesture(on) }
    }

    private func persist() {
        let box = Box(on: on, micTakesOver: micTakesOver, maps: maps)
        if let d = try? JSONEncoder().encode(box) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(Box.self, from: d) else { return }
        on = b.on; micTakesOver = b.micTakesOver
        maps = b.maps.isEmpty ? [GMap(bundleId: nil)] : b.maps
    }
    private struct Box: Codable { var on: Bool; var micTakesOver: Bool; var maps: [GMap] }
}

// ================================================================
//  The three we know how to tell
// ================================================================
enum Calls {
    struct App { let name: String; let mic: String; let cam: String }
    static let table: [String: App] = [
        "us.zoom.xos":          App(name: "Zoom",  mic: "cmd+shift+a", cam: "cmd+shift+v"),
        "com.microsoft.teams":  App(name: "Teams", mic: "cmd+shift+m", cam: "cmd+shift+o"),
        "com.microsoft.teams2": App(name: "Teams", mic: "cmd+shift+m", cam: "cmd+shift+o"),
        // Meet lives in a browser and we cannot see the tab, so this
        // is the browser's key and it is only right when Meet is the
        // tab you are looking at.
        "com.google.Chrome":    App(name: "Meet",  mic: "cmd+d",       cam: "cmd+e"),
        "com.apple.Safari":     App(name: "Meet",  mic: "cmd+d",       cam: "cmd+e"),
    ]
    static func known(_ bundleId: String) -> App? { table[bundleId] }
}

// ================================================================
//  Stopping the microphone at the device
// ================================================================
enum Audio {
    private static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                           &a, 0, nil, &sz, &id)
        return r == noErr && id != 0 ? id : nil
    }

    /// Mute if the device has a mute switch, and otherwise take the
    /// volume to zero, which not every device offers either.
    @discardableResult
    static func setInputMuted(_ muted: Bool) -> Bool {
        guard let dev = defaultInput() else { return false }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                           mScope: kAudioDevicePropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &a) {
            var v: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(dev, &a, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &v) == noErr {
                return true
            }
        }
        var va = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &va) else { return false }
        var vol: Float32 = muted ? 0 : 1
        return AudioObjectSetPropertyData(dev, &va, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &vol) == noErr
    }

    static func inputMuted() -> Bool {
        guard let dev = defaultInput() else { return false }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                           mScope: kAudioDevicePropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr else { return false }
        return v != 0
    }
}

// ================================================================
//  Pressing keys, which is the one part that needs permission
// ================================================================
enum Keys {
    /// Accessibility. It cannot be asked for in code; it is granted
    /// by hand in System Settings, and it is tied to the app's
    /// signature, which is why Rafiq is signed with a certificate
    /// that stays the same from build to build.
    static var trusted: Bool { AXIsProcessTrusted() }

    static func openSettings() {
        let u = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }

    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// "cmd+shift+a" and the like. Returns false if it cannot read it
    /// or has not been allowed to press anything.
    @discardableResult
    static func press(_ spec: String) -> Bool {
        guard trusted else { return false }
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for raw in spec.lowercased().split(separator: "+") {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift":          flags.insert(.maskShift)
            case "alt", "option":  flags.insert(.maskAlternate)
            case "ctrl", "control":flags.insert(.maskControl)
            case "fn":             flags.insert(.maskSecondaryFn)
            case let k:            code = codes[k]
            }
        }
        guard let c = code, let src = CGEventSource(stateID: .combinedSessionState)
        else { return false }
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: false)
        else { return false }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
