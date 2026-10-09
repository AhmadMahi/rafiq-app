import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import IOKit.ps
import EventKit
import CoreLocation
import UserNotifications

/// The Mac batch (app 4.3, firmware 7.5). One place decides what a gesture
/// from the robot means right now, in this order:
///   a call ringing (the robot answers it itself), then a meeting (a pad tap
///   mutes the Mac's microphone; a knock never does), then a presentation
///   (knock next, lean back), then the knob (hold and tilt), then the
///   screenshot (three knocks), and only then your own gestures.
/// Everything else here feeds the robot: Mac health, Apple Reminders, a
/// pinned task, dim while typing, prayer pause, walk-away, last seen, a
/// low battery warning, and weather and prayer times from this Mac.
@MainActor
final class Features: NSObject, ObservableObject {
    static let shared = Features()

    // ------------------------------------------------------------ switches
    nonisolated private static func flag(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    @Published var meetMute   = flag("fMeet", true)   { didSet { save("fMeet", meetMute) } }
    @Published var clicker    = flag("fClick", false) { didSet { save("fClick", clicker) } }
    @Published var knob       = flag("fKnob", false)  { didSet { save("fKnob", knob); push() } }
    @Published var shot       = flag("fShot", true)   { didSet { save("fShot", shot) } }
    @Published var health     = flag("fHealth", true) { didSet { save("fHealth", health); lastHealth = ""; tickHealth() } }
    @Published var dimTyping  = flag("fDim", false)   { didSet { save("fDim", dimTyping); if !dimTyping { setDim(false) } } }
    @Published var prayPause  = flag("fPray", true)   { didSet { save("fPray", prayPause) } }
    @Published var walkAway   = flag("fWalk", false)  { didSet { save("fWalk", walkAway); push() } }
    @Published var lastSeenOn = flag("fSeen", true)   { didSet { save("fSeen", lastSeenOn); if lastSeenOn { askLocation() } } }
    @Published var lowBatt    = flag("fBatt", true)   { didSet { save("fBatt", lowBatt); if lowBatt { askNotify() } } }
    @Published var reminders  = flag("fRem", false)   { didSet { save("fRem", reminders); if reminders { askReminders() } else { clearTasks() } } }
    @Published var skyFromMac = flag("fSky", false)   { didSet { save("fSky", skyFromMac); if skyFromMac { askLocation(); skyDay = "" ; tickSky() } } }
    @Published var prayMinutes = UserDefaults.standard.object(forKey: "fPrayMin") as? Int ?? 15 {
        didSet { UserDefaults.standard.set(prayMinutes, forKey: "fPrayMin") } }
    @Published var walkLimit = UserDefaults.standard.object(forKey: "fWalkDb") as? Int ?? -85 {
        didSet { UserDefaults.standard.set(walkLimit, forKey: "fWalkDb") } }

    /// How far away counts as gone, kept as a distance rather than a number
    /// of decibels.
    ///
    /// Signal strength is negative and gets more negative with distance: at
    /// the desk it is around -55, across a room -85, through a wall -100.
    /// "Calibrated: leaving starts below -89 dBm" is true and tells you
    /// nothing you can act on, so the reading at the desk is stored instead
    /// and the threshold is worked out from it. Radio indoors is not a tape
    /// measure, so these are honest approximations: about 6 dB per doubling
    /// of distance in the open, more through furniture and bodies.
    @Published var walkDesk = UserDefaults.standard.object(forKey: "fWalkDesk") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(walkDesk, forKey: "fWalkDesk"); applyWalkRange() } }
    @Published var walkRange = UserDefaults.standard.object(forKey: "fWalkRange") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(walkRange, forKey: "fWalkRange"); applyWalkRange() } }
    static let walkMargins = [12, 18, 24]
    static let walkWords   = ["about 2 m, 6 feet", "about 3 m, 10 feet", "about 5 m, 16 feet"]
    private func applyWalkRange() {
        guard walkDesk != 0 else { return }
        walkLimit = walkDesk - Features.walkMargins[min(max(walkRange, 0), 2)]
    }

    // ------------------------------------------------------------ state shown
    @Published private(set) var pinned = UserDefaults.standard.string(forKey: "fPin") ?? ""
    @Published private(set) var topTitles: [String] = []
    @Published private(set) var lastSeen = UserDefaults.standard.string(forKey: "fSeenText") ?? ""
    @Published private(set) var note = ""

    private func save(_ k: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: k) }
    private var started = false
    private var link: RobotLink { RobotLink.shared }

    // ================================================================
    //  life
    // ================================================================

    /// Once, when the app starts.
    func start() {
        guard !started, !Device.inert else { return }
        started = true
        let me = self
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in me.everySecond() } }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in Task { @MainActor in me.everyMinute() } }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in me.goingToSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in me.awake = true }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in me.refreshTasks() }
        }
        if reminders { askReminders() }
        if lowBatt { askNotify() }
    }

    /// Every time the robot links: tell it what is switched on, and
    /// send what it should be showing.
    func linked() {
        awake = true; walkGoneAt = nil
        // Walking back in often means the link dropped and came back rather
        // than the signal merely rising, and that path only cleared the flag
        // and left the screen dark. Coming back is coming back either way.
        if locked { locked = false; wakeScreen() } else { locked = false }
        push()
        lastHealth = ""; tickHealth()
        refreshTasks()
        tickSky()
    }

    /// The robot went. Remembered as last seen, and maybe a walk-away.
    func unlinked() {
        noteLastSeen()
        if walkAway && awake { walkGoneAt = Date() }
    }

    private func push() {
        guard link.full else { return }
        link.send("!knob \(knob ? 1 : 0)")
        link.send("!walk \(walkAway ? 1 : 0)")
    }

    private var awake = true
    private func goingToSleep() {
        awake = false
        link.send("!bye")                       // asleep in a bag is not left behind
    }

    private func everySecond() {
        tickDim()
        tickWalk()
    }
    private func everyMinute() {
        tickHealth()
        tickBattery()
        tickSky()
        if link.connected { noteSeenNow() }
    }

    // ================================================================
    //  gestures: who gets this one
    // ================================================================

    private var inCall: Bool { Gestures.shared.micLive }
    private static let presenters: Set<String> = [
        "com.apple.iWork.Keynote", "com.microsoft.Powerpoint",
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox"]
    private var presenting: Bool {
        guard clicker, let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Features.presenters.contains(b)
    }

    /// True when it was used here; false and it goes to your gestures.
    func handle(_ ev: String) -> Bool {
        if ev.hasPrefix("ota ") { link.otaEvent(ev); return true }
        if ev.hasPrefix("pray ") { prayer(String(ev.dropFirst(5))); return true }
        if ev.hasPrefix("done ") { done(Int(ev.dropFirst(5)) ?? -1); return true }
        if ev.hasPrefix("kv ") { if knob { turn(Int(ev.dropFirst(3)) ?? 0) }; return true }
        // a meeting: the pad, and only the pad, mutes and unmutes
        if meetMute && inCall && ev == "t1" { toggleMute(); return true }
        // presenting: knock next, lean back (lean forward next too)
        if presenting {
            switch ev {
            case "k1", "lr": _ = Keys.press("right"); return true
            case "ll":       _ = Keys.press("left");  return true
            default: break
            }
        }
        if shot && ev == "k3" { screenshot(); return true }
        return false
    }

    // ---- meeting mute: the Mac's microphone itself ----
    private var mutedByUs = false
    private func toggleMute() {
        mutedByUs.toggle()
        Audio.setInputMuted(mutedByUs)
        link.send("!busy 0 1 \(mutedByUs ? 1 : 0)")   // the robot shows muted or live
    }

    // ---- the knob: degrees from where the hold began ----
    private var knobLast = 0
    private var knobAt = Date.distantPast
    private func turn(_ deg: Int) {
        if Date().timeIntervalSince(knobAt) > 1.5 { knobLast = 0 }   // a new hold
        knobAt = Date()
        let step = deg - knobLast
        knobLast = deg
        guard step != 0, let v = OutVol.get() else { return }
        OutVol.set(min(1, max(0, v + Float(step) * 0.012)))
    }

    // ---- three knocks: the whole screen, to the clipboard ----
    private func screenshot() {
        // screencapture needs Screen Recording, and without it it exits
        // quietly having copied nothing. The old version launched it, never
        // waited, and told the robot "Screenshot copied" either way, so a
        // permission that had never been granted looked exactly like success.
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            note = "Allow Screen Recording for Rafiq in System Settings, Privacy and Security, then try again"
            link.send("msg: Allow Screen Recording")
            return
        }
        let before = NSPasteboard.general.changeCount
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-c", "-x"]
        do { try p.run(); p.waitUntilExit() }
        catch { link.send("msg: Screenshot failed"); return }
        if NSPasteboard.general.changeCount != before {
            link.send("msg: Screenshot copied")
        } else {
            note = "The screenshot did not reach the clipboard"
            link.send("msg: Screenshot failed")
        }
    }

    // ================================================================
    //  dim while typing: the keyboard's idle time, no monitoring
    // ================================================================

    private var dimSent = false
    private func tickDim() {
        guard dimTyping, link.full else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if idle < 2 && !dimSent { setDim(true) }
        else if idle > 6 && dimSent { setDim(false) }
    }
    private func setDim(_ on: Bool) {
        dimSent = on
        if link.full { link.send("!dim \(on ? 1 : 0)") }
    }

    // ================================================================
    //  prayer pause
    // ================================================================

    private var prayPaused = false, prayMutedOut = false
    private func prayer(_ name: String) {
        guard prayPause, !inCall else { return }   // in a call the robot shows it; the call goes on
        prayMutedOut = !OutVol.muted()
        if prayMutedOut { OutVol.setMuted(true) }
        Media.isPlaying { playing in
            MainActor.assumeIsolated {
                if playing { Media.send(1); self.prayPaused = true }        // pause
            }
        }
        let me = self
        Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, prayMinutes)) * 60, repeats: false) { _ in
            Task { @MainActor in me.prayerOver() }
        }
    }
    private func prayerOver() {
        if prayMutedOut { OutVol.setMuted(false); prayMutedOut = false }
        if prayPaused { Media.send(0); prayPaused = false }                  // play
    }

    // ================================================================
    //  Mac health: a card on the robot, a word when something needs you
    // ================================================================

    private var lastHealth = ""
    private var warned: Set<String> = []
    private func tickHealth() {
        guard link.full else { return }
        guard health else { if !lastHealth.isEmpty { link.send("!card 0"); lastHealth = "" }; return }
        var parts: [String] = []
        let b = MacHealth.battery()
        if let pct = b.pct { parts.append("\(pct)%" + (b.charging ? "+" : "")) }
        let free = MacHealth.freeGB()
        if let f = free { parts.append("\(f)GB free") }
        let hot = ProcessInfo.processInfo.thermalState
        if hot == .serious || hot == .critical { parts.append("hot") }
        let line = parts.joined(separator: "  ")
        if line != lastHealth {
            lastHealth = line
            link.send("!card 0 Mac" + "\u{1F}" + line)
        }
        let day = Self.dayKey()
        func once(_ k: String, _ title: String, _ text: String) {
            guard !warned.contains(day + k) else { return }
            warned.insert(day + k)
            link.sendNote(cat: 0, app: "Mac", title: title, text: text)
        }
        if let pct = b.pct, pct < 15, !b.charging { once("bat", "Mac battery \(pct)%", "Plug it in soon.") }
        if let f = free, f < 10 { once("disk", "Mac disk nearly full", "\(f) GB left.") }
        if hot == .serious || hot == .critical { once("hot", "Mac is running hot", "Something is working it hard.") }
    }
    private static func dayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    // ================================================================
    //  Apple Reminders: alerts kept on the robot, the top three, a pin
    // ================================================================

    private let store = EKEventStore()
    private var topIds: [String] = []
    private var pinnedId = UserDefaults.standard.string(forKey: "fPinId")
    private var sentRems: Set<String> = []

    private func askReminders() {
        store.requestFullAccessToReminders { ok, _ in
            Task { @MainActor in
                if ok { Features.shared.refreshTasks() }
                else { Features.shared.note = "Allow Reminders for Rafiq in System Settings, Privacy" }
            }
        }
    }

    func refreshTasks() {
        guard reminders, link.full,
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: pred) { found in
            let list = (found ?? []).map { r -> (id: String, title: String, due: Date?) in
                (r.calendarItemIdentifier, r.title ?? "", r.dueDateComponents?.date)
            }
            Task { @MainActor in Features.shared.gotReminders(list) }
        }
    }

    private func gotReminders(_ list: [(id: String, title: String, due: Date?)]) {
        // the top three: soonest due first, then the undated ones
        let sorted = list.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.title < b.title
            }
        }
        let top = Array(sorted.filter { $0.id != pinnedId }.prefix(3))
        topIds = top.map { $0.id }
        topTitles = top.map { $0.title }
        if top.isEmpty { link.send("!card 1") }
        else { link.send("!card 1 Today" + top.map { "\u{1F}" + RobotLink.ascii($0.title) }.joined()) }
        // alerts: anything due in the next two days, kept on the robot so
        // it rings even with this Mac asleep. The robot ignores repeats.
        let soon = Date().addingTimeInterval(2 * 86400)
        for r in list {
            guard let d = r.due, d > Date(), d < soon else { continue }
            let key = r.id + "\(Int(d.timeIntervalSince1970))"
            guard !sentRems.contains(key) else { continue }
            sentRems.insert(key)
            let wall = Int(d.timeIntervalSince1970) + TimeZone.current.secondsFromGMT(for: d)
            link.send("!rem \(wall) 0 " + RobotLink.ascii(r.title))
        }
        sendPinned()
    }

    /// Pin a task: typed, or one of the top three by its index.
    func pin(_ text: String, id: String? = nil) {
        pinned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pinnedId = id
        UserDefaults.standard.set(pinned, forKey: "fPin")
        UserDefaults.standard.set(id, forKey: "fPinId")
        sendPinned()
        refreshTasks()
    }
    func pinTop(_ i: Int) { if i < topIds.count { pin(topTitles[i], id: topIds[i]) } }
    private func sendPinned() {
        guard link.full else { return }
        link.send(pinned.isEmpty ? "!card 2" : "!card 2 Now" + "\u{1F}" + RobotLink.ascii(pinned))
    }
    private func clearTasks() { link.send("!card 1"); topIds = []; topTitles = [] }

    /// A hold on the robot ticked one off: 0 the pin, 1 to 3 the list.
    private func done(_ k: Int) {
        var id: String? = nil
        if k == 0 { id = pinnedId; pin("") }
        else if k >= 1 && k <= topIds.count { id = topIds[k - 1] }
        guard let rid = id, let item = store.calendarItem(withIdentifier: rid) as? EKReminder else {
            refreshTasks(); return
        }
        item.isCompleted = true
        try? store.save(item, commit: true)
        refreshTasks()
    }

    // ================================================================
    //  walk-away: the Mac locks, the robot says the Mac stayed
    // ================================================================

    private var walkGoneAt: Date?
    private var weakSince: Date?
    private var locked = false
    private func tickWalk() {
        guard walkAway, awake, !inCall, !presenting else { weakSince = nil; return }
        if link.connected {
            walkGoneAt = nil
            link.readRSSI()
            let r = link.rssi
            if r != 0 && r < Double(walkLimit) {
                if weakSince == nil { weakSince = Date() }
                if Date().timeIntervalSince(weakSince!) > 20 { lockNow() }
            } else {
                weakSince = nil
                if locked && r > Double(walkLimit + 6) { locked = false; wakeScreen() }
            }
        } else if let g = walkGoneAt, Date().timeIntervalSince(g) > 10 {
            walkGoneAt = nil
            lockNow()
        }
    }
    /// Where you sit now is the reference; the distance setting does the rest.
    func calibrateWalk() {
        let r = link.rssi
        guard r != 0 else { note = "Keep Rafiq with you at your desk, then try again"; return }
        walkDesk = Int(r)                       // didSet works out the threshold
        note = "Calibrated at your desk. The Mac locks when Rafiq is "
             + Features.walkWords[min(max(walkRange, 0), 2)] + " away."
    }
    private func lockNow() {
        guard !locked else { return }
        locked = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]                 // locks, with a password set for sleep
        try? p.run()
    }
    private func wakeScreen() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-t", "2"]
        try? p.run()
    }

    // ================================================================
    //  last seen
    // ================================================================

    private var seenAt = Date.distantPast
    private func noteSeenNow() {
        seenAt = Date()
        // The private timestamp was being kept up to date and the line on
        // the panel was not, so while Rafiq sat there linked you were still
        // reading the time of the last drop, minutes old. Nothing extra goes
        // over the radio for this: the app already reads STAT every ten
        // seconds, so being linked is itself the evidence.
        guard lastSeenOn else { return }
        lastSeen = "With this Mac now"
        UserDefaults.standard.set(lastSeen, forKey: "fSeenText")
    }
    private func noteLastSeen() {
        guard lastSeenOn else { return }
        // Stamped from the last confirmed contact rather than from the
        // moment the disconnect was noticed, which can be much later.
        let when = seenAt == Date.distantPast ? Date() : seenAt
        let t = DateFormatter.localizedString(from: when, dateStyle: .none, timeStyle: .short)
        lastSeen = "Last with this Mac at \(t)"
        UserDefaults.standard.set(lastSeen, forKey: "fSeenText")
        placeThen { place in
            guard let place else { return }
            self.lastSeen = "Last with this Mac at \(t), near \(place)"
            UserDefaults.standard.set(self.lastSeen, forKey: "fSeenText")
        }
    }

    // ================================================================
    //  low battery on the robot
    // ================================================================

    private var told20 = false, told10 = false
    private func tickBattery() {
        guard lowBatt, let b = link.battery else { return }
        if b > 30 { told20 = false; told10 = false }
        if b <= 10 && !told10 { told10 = true; told20 = true; notify("Rafiq is at \(b)%", "Charge it soon, or it will switch itself off.") }
        else if b <= 20 && !told20 { told20 = true; notify("Rafiq is at \(b)%", "Time to charge it.") }
    }
    private func askNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // ================================================================
    //  weather and prayer times from this Mac
    // ================================================================

    private var skyDay = UserDefaults.standard.string(forKey: "fSkyDay") ?? ""
    private func tickSky() {
        guard skyFromMac, link.full else { return }
        let day = Self.dayKey()
        guard day != skyDay else { return }
        locate { loc in
            guard let loc else { return }
            Task { @MainActor in await self.fetchSky(loc, day: day) }
        }
    }
    private func fetchSky(_ loc: CLLocation, day: String) async {
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        // prayer times, the same way the robot asks for them (method 1, school 0)
        let f = DateFormatter(); f.dateFormat = "dd-MM-yyyy"
        if let u = URL(string: "https://api.aladhan.com/v1/timings/\(f.string(from: Date()))?latitude=\(lat)&longitude=\(lon)&method=1&school=0"),
           let r = try? await URLSession.shared.data(from: u),
           let j = try? JSONSerialization.jsonObject(with: r.0) as? [String: Any],
           let data = j["data"] as? [String: Any], let t = data["timings"] as? [String: String] {
            let mins = ["Fajr", "Dhuhr", "Asr", "Maghrib", "Isha"].compactMap { k -> Int? in
                guard let v = t[k] else { return nil }
                let hm = v.prefix(5).split(separator: ":").compactMap { Int($0) }
                return hm.count == 2 ? hm[0] * 60 + hm[1] : nil
            }
            if mins.count == 5 { link.send("!pt " + mins.map(String.init).joined(separator: " ")) }
        }
        // the weather, now
        if let u = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code"),
           let r = try? await URLSession.shared.data(from: u),
           let j = try? JSONSerialization.jsonObject(with: r.0) as? [String: Any],
           let c = j["current"] as? [String: Any] {
            let temp = Int(((c["temperature_2m"] as? Double) ?? 0).rounded())
            let hum = Int((c["relative_humidity_2m"] as? Double) ?? 0)
            let wind = Int(((c["wind_speed_10m"] as? Double) ?? 0).rounded())
            let cond = Self.sky((c["weather_code"] as? Int) ?? 0)
            placeThen { place in
                self.link.send("temp=\(temp);cond=\(cond);hum=\(hum);wind=\(wind);city=" + RobotLink.ascii(place ?? ""))
            }
        }
        skyDay = day
        UserDefaults.standard.set(day, forKey: "fSkyDay")
    }
    private static func sky(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorm"
        default: return "Cloudy"
        }
    }

    // ================================================================
    //  location, asked once and only for the switches that need it
    // ================================================================

    private let loc = CLLocationManager()
    private var locWaiters: [(CLLocation?) -> Void] = []
    private func askLocation() {
        loc.delegate = self
        loc.requestWhenInUseAuthorization()
    }
    private func locate(_ done: @escaping (CLLocation?) -> Void) {
        loc.delegate = self
        locWaiters.append(done)
        if locWaiters.count == 1 { loc.requestLocation() }
    }
    private func placeThen(_ done: @escaping (String?) -> Void) {
        locate { l in
            guard let l else { done(nil); return }
            CLGeocoder().reverseGeocodeLocation(l) { marks, _ in
                let m = marks?.first
                let name = m?.subLocality ?? m?.locality ?? m?.name
                Task { @MainActor in done(name) }
            }
        }
    }
    fileprivate func gotLocation(_ l: CLLocation?) {
        let w = locWaiters; locWaiters = []
        for f in w { f(l) }
    }
}

extension Features: CLLocationManagerDelegate {
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations ls: [CLLocation]) {
        let l = ls.last
        MainActor.assumeIsolated { self.gotLocation(l) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.gotLocation(nil) }
    }
}

// ================================================================
//  small helpers
// ================================================================

/// The Mac's speakers: volume and mute, on the default output.
enum OutVol {
    private static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
        return r == noErr && id != 0 ? id : nil
    }
    static func get() -> Float? {
        guard let d = device() else { return nil }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                           mScope: kAudioDevicePropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: Float32 = 0
        var sz = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr ? v : nil
    }
    static func set(_ v: Float) {
        guard let d = device() else { return }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                           mScope: kAudioDevicePropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        var x: Float32 = v
        _ = AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &x)
    }
    static func muted() -> Bool {
        guard let d = device() else { return false }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                           mScope: kAudioDevicePropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v) == noErr && v != 0
    }
    static func setMuted(_ m: Bool) {
        guard let d = device() else { return }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                           mScope: kAudioDevicePropertyScopeOutput,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = m ? 1 : 0
        _ = AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}

/// Now playing, through the system's own media controls. A private
/// framework, used carefully: if it is not there, prayer pause still mutes.
enum Media {
    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias PlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private static func sym(_ n: String) -> UnsafeMutableRawPointer? {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else { return nil }
        return dlsym(h, n)
    }
    static func send(_ command: UInt32) {
        guard let s = sym("MRMediaRemoteSendCommand") else { return }
        _ = unsafeBitCast(s, to: SendFn.self)(command, nil)
    }
    static func isPlaying(_ done: @escaping (Bool) -> Void) {
        guard let s = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying") else { done(false); return }
        unsafeBitCast(s, to: PlayingFn.self)(DispatchQueue.main) { playing in done(playing) }
    }
}

enum MacHealth {
    static func battery() -> (pct: Int?, charging: Bool) {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let pct = d[kIOPSCurrentCapacityKey] as? Int
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            if pct != nil { return (pct, charging) }
        }
        return (nil, false)
    }
    static func freeGB() -> Int? {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let b = v?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(b / 1_000_000_000)
    }
}
