import Foundation
import AppKit
import UniformTypeIdentifiers

/// The battery diary (app 4.5, firmware 7.8). Every ten minutes while the
/// robot is linked, its battery and its own log (time on, dark, in light
/// sleep, in deep sleep, on WiFi, wakes, restarts) are written down here.
/// The robot keeps one charge cycle; this keeps everything until cleared,
/// and works out the real drain from how fast the percentage falls.
@MainActor
final class BatteryDiary: ObservableObject {
    static let shared = BatteryDiary()

    struct Entry: Codable {
        var at: Date
        var pct: Int, volts: Double, lightNow: Bool
        var on: Int, dark: Int, light: Int, deep: Int, wifi: Int, wakes: Int, restarts: Int
        var cycle: Int                     // when the robot's cycle began (epoch)
    }
    @Published private(set) var entries: [Entry] = []
    @Published var keep = UserDefaults.standard.object(forKey: "diaryOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keep, forKey: "diaryOn") }
    }
    @Published var capacity = UserDefaults.standard.object(forKey: "diaryCap") as? Int ?? 350 {
        didSet { UserDefaults.standard.set(capacity, forKey: "diaryCap"); RobotLink.shared.sendOrQueue("!cfg cap \(capacity)") }
    }
    @Published var resetAt = UserDefaults.standard.object(forKey: "diaryResetAt") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(resetAt, forKey: "diaryResetAt"); RobotLink.shared.sendOrQueue("!cfg blogv \(resetAt)") }
    }
    static let resetVolts = ["4.10 V", "4.20 V", "4.25 V", "4.30 V"]

    private var started = false
    private var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rafiq", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("battery-diary.json")
    }

    func start() {
        guard !started, !Device.inert else { return }
        started = true
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
        let me = self
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in Task { @MainActor in me.record() } }
    }

    /// One line, from what the robot said last.
    func record() {
        let l = RobotLink.shared
        guard keep, l.connected, l.full else { return }
        let s = l.stat
        func i(_ k: String) -> Int { Int(s[k] ?? "") ?? 0 }
        guard let pct = l.battery else { return }
        entries.append(Entry(at: Date(), pct: pct, volts: Double(s["v"] ?? "") ?? 0, lightNow: s["ls"] == "1",
                             on: i("lon"), dark: i("ldk"), light: i("lls"), deep: i("ldp"), wifi: i("lwf"),
                             wakes: i("lwk"), restarts: i("lrs"), cycle: i("lst")))
        save()
    }
    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: file, options: .atomic) }
    }
    func clear() { entries = []; save() }

    // ------------------------------------------------------------ what it says

    /// The real average drain over the last `hours`, from the fall in the
    /// percentage (charging spans are left out). Nil until there is enough.
    func drain(hours: Double) -> Double? {
        let from = Date().addingTimeInterval(-hours * 3600)
        let span = entries.filter { $0.at >= from }
        guard span.count >= 2 else { return nil }
        var used = 0.0, secs = 0.0
        for (a, b) in zip(span, span.dropFirst()) where b.pct <= a.pct {
            used += Double(a.pct - b.pct) / 100 * Double(capacity)
            secs += b.at.timeIntervalSince(a.at)
        }
        guard secs > 1800 else { return nil }
        return used / (secs / 3600)
    }

    /// The robot's own log now: seconds in each state since the cycle began.
    var cycle: Entry? { entries.last }

    /// The thing worth knowing: dark but awake instead of in light sleep.
    var lightSleepNote: String? {
        guard let c = cycle else { return nil }
        let dark = c.dark, light = c.light
        guard dark + light > 1800 else { return nil }
        let share = Double(light) / Double(dark + light)
        if share < 0.6 {
            return "Only \(Int(share * 100))% of its dark time was light sleep. The rest costs about six times as much."
        }
        return "\(Int(share * 100))% of its dark time was light sleep, as it should be."
    }

    static func hm(_ s: Int) -> String { String(format: "%d:%02d", s / 3600, (s / 60) % 60) }

    // ------------------------------------------------------------ out

    func exportCSV() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "rafiq-battery-diary.csv"
        if let csv = UTType(filenameExtension: "csv") { p.allowedContentTypes = [csv] }
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        let f = ISO8601DateFormatter()
        var out = "time,battery_pct,volts,light_sleep_now,on_s,dark_s,light_s,deep_s,wifi_s,wakes,restarts,cycle_start\n"
        for e in entries {
            out += "\(f.string(from: e.at)),\(e.pct),\(String(format: "%.2f", e.volts)),\(e.lightNow ? 1 : 0),"
                 + "\(e.on),\(e.dark),\(e.light),\(e.deep),\(e.wifi),\(e.wakes),\(e.restarts),\(e.cycle)\n"
        }
        try? out.write(to: u, atomically: true, encoding: .utf8)
    }
}
