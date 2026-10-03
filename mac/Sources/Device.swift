import Foundation
import SwiftUI
import Network

/// Everything that talks to the robot. It serves plain HTTP on the local
/// network, which is why the bundle asks for local network access and allows
/// local loads only: nothing here should ever leave the house.
@MainActor
final class Device: ObservableObject {
    static let shared = Device()

    /// Set only by the panel size check. Nothing reaches the network
    /// while it is on, and nothing starts a repeating timer either.
    ///
    /// Without it the check could not measure a populated page at all.
    /// Give it an address and it starts talking to the robot while the
    /// check is spinning the run loop by hand; the two never get out of
    /// each other's way and it stops after the first page. Give it no
    /// address and every page draws the "where is the robot" prompt
    /// instead of itself, so the numbers it prints are about a page
    /// nobody ever sees. Either way the thing being measured was not
    /// the thing being shipped.
    nonisolated(unsafe) static var inert = false

    @AppStorage("deviceIP")    var ip: String = ""
    @AppStorage("watchClip")   var watchClipboard: Bool = false
    @AppStorage("breakMins")   var breakMins: Int = 45
    @AppStorage("breakOn")     var breakOn: Bool = false
    @AppStorage("focusMins")   var focusMins: Int = 25
    @AppStorage("breakCustom") var breakCustom: Int = 25
    @AppStorage("lockIdle")    var lockWhenIdle: Bool = false
    @AppStorage("lockIdleMin") var lockIdleMins: Int = 5
    @AppStorage("watchAV")     var watchAV: Bool = false
    @AppStorage("theme")       var theme: String = "system"
    @AppStorage("phrases")     var phrasesRaw: String =
        "On my way\nBack in 5\nIn a meeting\nCall me\nDone"

    var phrases: [String] {
        phrasesRaw.split(separator: "\n").map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    @Published var status: String = ""
    @Published var reachable: Bool? = nil
    @Published var busy = false
    @Published var gesture = false

    /// What the robot last told us about itself. Everything the grid shows
    /// comes from here, so a tile is never lit unless the device agrees.
    @Published var paired = false
    @Published var linked = false
    @Published var following = false
    @Published var relaxing = false
    @Published var focusLeft = 0
    @Published var dndLeft = 0
    @Published var version = ""
    @Published var nets: [(ssid: String, on: Bool)] = []
    @Published var netMax = 5
    @Published var intWired = false
    @Published var deepOff = false
    @Published var autoUp = false
    /// Off on the robot by default from firmware 3.0.0, where the touch
    /// pad took over. This is deliberately reachable from here: the pad
    /// is the only thing driving the robot now, so if it ever stops
    /// there has to be a way back in that is not the pad.
    @Published var knock = false
    @Published var touches = 0
    @Published var shake = true
    @Published var offline = false
    @Published var netDown = false
    @Published var bike = false
    @Published var btpl = 0
    @Published var plate = ""
    @Published var make  = ""
    @Published var model = ""
    @Published var owner = ""
    @Published var deepi = 1
    @Published var battFull = 4.10
    @Published var battPct = -1        // -1 when there is no pack
    @Published var battV = 0.0
    @Published var bri = 160
    @Published var face = 0
    @Published var slpi = 1
    @Published var popi = 2
    @Published var eye = 0
    @Published var tap = 2
    @Published var autoTurn = false

    // The choices the robot itself offers, kept here so the app and the
    // panel can never disagree about what they mean.
    /// Must match BRIGHT_NAME and BRIGHT_OPTS in the firmware. The
    /// robot is sent a contrast value, so a list that disagrees sets
    /// the wrong one and mislabels what is already there.
    static let brightNames = ["10%", "25%", "50%", "75%", "100%"]
    static let brightVals  = [26, 64, 128, 191, 255]
    /// Must match FACE_NAME in the firmware, in order: the robot is
    /// told a number, so a list that disagrees picks the wrong face
    /// and mislabels the one that is on.
    static let faceNames   = ["classic", "stacked", "date up", "minimal", "side",
                              "banner", "drift", "parallax", "water", "sand",
                              "dial", "bauhaus", "regulator", "rings", "infograph",
                              "status", "vitals", "bars", "terminal", "binary",
                              "arabic", "hijri", "crescent"]
    static let sleepNames  = ["5s", "10s", "15s", "30s", "45s", "1m", "2m", "3m", "5m", "10m", "never"]
    static let popupNames  = ["off", "5s", "10s", "20s", "30s", "60s"]
    /// Must match WAKE_NAME in the firmware, in order.
    static let deepNames   = ["1 min", "2 min", "5 min", "10 min", "30 min", "never"]
    static let sleepNames2 = ["5s", "10s", "15s", "30s", "45s", "1m", "2m", "3m", "5m", "10m", "never"]
    /// Must match the order of the cases in drawBike(). The robot is
    /// sent an index, so a list in a different order picks a different
    /// layout from the one you tapped.
    static let bikeTemplates = ["plate", "badge", "board", "ticket", "speedo", "plain"]
    static let eyeNames    = ["round", "square", "wide", "sleepy", "joy", "cyclops"]
    static let tapNames    = ["ultra light", "light", "medium", "hard"]

    /// Set while a six digit code is on the robot's panel.
    @Published var pairing = false
    @Published var pairError = ""

    // ---------------------------------------------------------------
    //  What can run beside what
    // ---------------------------------------------------------------
    //  A few of these cannot sensibly be on at once. The rules live here
    //  rather than inside the buttons, so the tiles and the robot can
    //  never end up disagreeing about what is allowed.

    var focusRunning: Bool { focusLeft > 0 }
    var breakRunning: Bool { dndLeft > 0 }

    // ---------------------------------------------------------------
    //  not letting a poll undo what you just did
    // ---------------------------------------------------------------
    //  The panel asks the robot how it is every ten seconds, and that
    //  answer describes the robot as it was when the request left. Tap
    //  a tile while one of those is in flight and the reply lands
    //  afterwards carrying the old value, which puts the tile straight
    //  back. It read as the first tap not registering: you tapped
    //  Follow, the robot started following, and the tile stayed dark
    //  until you tapped it again.
    //
    //  So a local change is believed for a moment. Anything the robot
    //  says about the switches in that window is a stale answer to a
    //  question asked before the change, and is dropped. Readings the
    //  robot owns outright, the battery and the countdowns, are never
    //  affected.
    private var trustLocalUntil = Date.distantPast
    private func justChanged() { trustLocalUntil = Date().addingTimeInterval(2.5) }
    private var pollMayWrite: Bool { Date() >= trustLocalUntil }

    /// Nil when the tile is free to use, otherwise the reason it is not.
    /// A greyed out tile with no explanation is just a broken tile.
    func blocked(_ what: Tool) -> String? {
        switch what {
        case .breakNow:
            // A break locks the screen, which is the opposite of focusing.
            return focusRunning ? "during focus" : nil
        case .deepSleep:
            // Sleeping would take the countdown with it.
            return focusRunning ? "after focus" : (breakRunning ? "on a break" : nil)
        case .relax:
            // The robot can only hold one of these on its panel.
            return following ? "following" : nil
        case .follow:
            return relaxing ? "relaxing" : nil
        }
    }

    enum Tool { case breakNow, deepSleep, relax, follow }

    var token: String {
        get { Keychain.get("token") }
        set { Keychain.set(newValue, for: "token") }
    }

    // ---------------------------------------------------------------
    //  text
    // ---------------------------------------------------------------

    /// The firmware keeps 84 bytes and cuts on a byte boundary, which would
    /// split a multi byte character in half. Trim by bytes here so it never
    /// has to. The panel draws ASCII, so anything fancier arrives intact but
    /// shows as blanks.
    static let maxLen = 84
    static func clip(_ s: String) -> String {
        if s.utf8.count <= maxLen { return s }
        var out = ""
        var n = 0
        for ch in s {
            let c = String(ch).utf8.count
            if n + c > maxLen - 3 { break }        // 3 bytes for the ellipsis
            out.append(ch); n += c
        }
        return out + "\u{2026}"
    }

    // ---------------------------------------------------------------
    //  what the grid does
    // ---------------------------------------------------------------

    func say(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await run("/api/msg", ["m": Self.clip(text.replacingOccurrences(of: "\n", with: " "))],
                  say: "Sent")
    }

    /// A copy, a paste, or a word about standing up. None of it disturbs the
    /// message the robot is holding, which is yours.
    func toast(_ text: String, kind: String, seconds: Int = 4) async {
        await run("/api/toast",
                  ["m": Self.clip(text), "k": kind, "s": String(seconds)], say: nil)
    }

    func startFocus(_ mins: Int) async {
        await run("/api/focus", ["m": String(mins)], say: "Focus for \(mins) min")
        focusLeft = mins * 60
    }
    func stopFocus() async {
        await run("/api/focus", ["m": "0"], say: "Focus stopped")
        focusLeft = 0
    }

    func setRelax(_ on: Bool) async {
        relaxing = on; justChanged()   // believed at once, see trustLocalUntil
        await run("/api/relax", ["a": on ? "1" : "0"], say: on ? "Resting" : "Back to normal")
        relaxing = on
    }

    func setFollow(_ on: Bool) async {
        following = on; justChanged()   // believed at once, see trustLocalUntil
        await run("/api/follow", ["a": on ? "1" : "0"], say: on ? "Watching the pointer" : "Eyes off")
        following = on
    }

    /// On a break: the robot holds the sign, the Mac locks itself.
    func startBreak(_ mins: Int) async {
        await run("/api/dnd", ["m": String(mins)], say: "On a break for \(mins) min")
        dndLeft = mins * 60
    }
    func endBreak() async {
        await run("/api/dnd", ["m": "0"], say: "Back")
        dndLeft = 0
    }

    /// One flag per device. Nothing about what is being said or seen.
    func setBusy(cam: Bool, mic: Bool, muted: Bool) async {
        await run("/api/busy", ["cam": cam ? "1" : "0", "mic": mic ? "1" : "0",
                                "muted": muted ? "1" : "0"], say: nil)
    }

    func remind(_ text: String) async {
        await toast(text, kind: "remind", seconds: 25)
    }

    // ---------------------------------------------------------------
    //  the robot's own settings
    // ---------------------------------------------------------------

    func setBrightness(_ i: Int) async { await run("/api/cfgv", ["k": "bri", "v": String(i)], say: nil) }
    func setFace(_ i: Int)       async { await run("/api/cfgv", ["k": "face", "v": String(i)], say: nil) }
    func setSleep(_ i: Int)      async { await run("/api/cfgv", ["k": "slpi", "v": String(i)], say: nil) }
    func setEyes(_ i: Int)       async { await run("/api/cfgv", ["k": "eye", "v": String(i)], say: nil) }
    func setPopup(_ i: Int)      async { await run("/api/cfgv", ["k": "popi", "v": String(i)], say: nil) }
    func setTurn(_ auto: Bool)   async { await run("/api/turn", ["a": auto ? "1" : "0"], say: nil) }
    func setTap(_ i: Int)        async { await run("/api/tap", ["n": String(i)], say: "Tap strength set") }
    func setDeepSleep(_ on: Bool) async {
        await run("/api/deep", ["off": on ? "0" : "1"], say: nil)
        deepOff = !on; justChanged()
    }
    func reboot() async { await run("/api/reboot", [:], say: "Rebooting") }

    func setAutoUpdate(_ on: Bool) async {
        await run("/api/autoup", ["a": on ? "1" : "0"], say: nil)
        autoUp = on; justChanged()
    }

    func setOffline(_ on: Bool) async {
        offline = on; justChanged()   // believed at once, see trustLocalUntil
        await run("/api/cfgv", ["k": "offl", "v": on ? "1" : "0"], say: nil)
        offline = on
    }
    func setBike(_ on: Bool) async {
        bike = on; justChanged()   // believed at once, see trustLocalUntil
        await run("/api/cfgv", ["k": "bike", "v": on ? "1" : "0"], say: nil)
        bike = on
    }
    func setBikeTemplate(_ i: Int) async {
        btpl = i; justChanged()
        await run("/api/cfgv", ["k": "btpl", "v": String(i)], say: nil)
        btpl = i
    }
    func setBikeInfo(plate: String, make: String, model: String, owner: String) async {
        await run("/api/bike", ["plate": plate, "make": make,
                                "model": model, "owner": owner], say: "Saved")
    }

    func setShake(_ on: Bool) async {
        shake = on; justChanged()   // believed at once, see trustLocalUntil
        await run("/api/cfgv", ["k": "shake", "v": on ? "1" : "0"], say: nil)
        shake = on
    }
    func setDeepAfter(_ i: Int) async {
        await run("/api/cfgv", ["k": "deepi", "v": String(i)], say: nil)
        deepi = i
    }
    /// Sent in hundredths: the robot's form only carries whole numbers.
    func setBattFull(_ v: Double) async {
        await run("/api/cfgv", ["k": "bfull", "v": String(Int((v * 100).rounded()))], say: nil)
        battFull = v
    }

    /// The whole list, every time. A dozen short lines is smaller than
    /// working out what changed, and the robot needs all of them to know
    /// when to wake itself up.
    /// Returns whether the robot actually took them. The caller only
    /// marks them delivered on a true, so a robot that is asleep or
    /// unplugged simply means trying again later.
    @discardableResult
    func pushReminders(_ list: [Reminder]) async -> Bool {
        guard !list.isEmpty else { return true }
        var f: [String: String] = ["n": String(min(list.count, 12))]
        for (i, r) in list.prefix(12).enumerated() {
            f["t\(i)"] = String(r.text.prefix(Device.remTextMax))
            f["a\(i)"] = String(Int(r.fireAt.timeIntervalSince1970))
            f["d\(i)"] = r.done ? "1" : "0"
        }
        return await run("/api/rems", f, say: nil)
    }

    /// Must match REM_TEXT in the firmware, less the terminator. Send
    /// more and the robot silently keeps the front of it, so the app
    /// would show something the robot is not holding.
    static let remTextMax = 95

    // ---------------------------------------------------------------
    //  the robot's own list
    // ---------------------------------------------------------------
    //  Reminders can arrive at the robot without this Mac ever seeing
    //  them: a plain URL from a phone, a shortcut, anything. So the
    //  robot's copy is the real one and this reads it rather than
    //  assuming the app's copy is complete.

    struct RobotRem: Decodable, Identifiable, Equatable {
        let id: UInt32
        let at: UInt32
        let first: UInt32
        let tries: Int
        let done: Bool
        let text: String
        var fireAt: Date { Date(timeIntervalSince1970: TimeInterval(at)) }
    }
    private struct RemList: Decodable {
        let ok: Bool
        let waiting: Int
        /// False when the robot has lost the time. Its stored times are
        /// then meaningless and nothing will fire, which the app says
        /// rather than showing times that will not happen.
        let clock: Bool
        let rems: [RobotRem]
    }

    /// nil means it could not be asked, which is not the same as an
    /// empty list and must not be treated as one.
    func fetchReminders() async -> (rems: [RobotRem], clock: Bool)? {
        guard !Device.inert, !ip.isEmpty else { return nil }
        do {
            var req = URLRequest(url: try url("/api/rem?list=1"))
            req.timeoutInterval = 4
            req.setValue("1", forHTTPHeaderField: "X-Rafiq-App")
            if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Rafiq-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let l = try JSONDecoder().decode(RemList.self, from: data)
            reachable = true
            return (l.rems, l.clock)
        } catch { return nil }
    }

    @discardableResult
    func clearReminders() async -> Bool {
        await run("/api/rems", ["clear": "1"], say: nil)
    }

    func dropReminder(_ id: UInt32) async -> Bool {
        await run("/api/rem", ["id": String(id), "drop": "1"], say: nil)
    }

    func editReminder(_ id: UInt32, text: String, at when: Date) async -> Bool {
        await run("/api/rem", ["id": String(id),
                               "text": String(text.prefix(Device.remTextMax)),
                               "at": String(Int(when.timeIntervalSince1970))], say: nil)
    }

    /// Gesture mode is not remembered on the robot: it comes up as a
    /// robot and this tells it otherwise. Sent on every refresh while
    /// it is on, so a robot that restarts comes back into the mode by
    /// itself, and dropped the moment this app stops answering.
    func setGesture(_ on: Bool) async {
        gesture = on; justChanged()   // believed at once, see trustLocalUntil
        await run("/api/cfgv", ["k": "gest", "v": on ? "1" : "0"], say: nil)
        gesture = on
    }

    func setGestureSource(_ i: Int) async {
        await run("/api/cfgv", ["k": "gsrc", "v": String(i)], say: nil)
    }

    func setKnock(_ on: Bool) async {
        knock = on; justChanged()   // believed at once, see trustLocalUntil
        await run("/api/cfgv", ["k": "knock", "v": on ? "1" : "0"], say: nil)
        knock = on
    }

    /// Settings back to how they came. Networks, pairing and the shelf
    /// are not settings and are deliberately left alone.
    func resetSettings() async {
        await run("/api/reset", [:], say: "Settings reset")
        await refresh()
    }

    // ---------------------------------------------------------------
    //  networks
    // ---------------------------------------------------------------
    //  The password goes one way only. Nothing reads one back, here or
    //  on the device, so this can add one and still not know the others.

    func addNetwork(_ ssid: String, _ pass: String) async {
        let s = ssid.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        await run("/api/net", ["ssid": s, "pass": pass], say: "Network saved")
        await refresh()
    }
    func removeNetwork(_ i: Int) async {
        await run("/api/net", ["del": String(i)], say: nil)
        await refresh()
    }
    func promoteNetwork(_ i: Int) async {
        await run("/api/net", ["up": String(i)], say: nil)
        await refresh()
    }

    /// Telling the robot we are going, rather than going quiet and
    /// leaving it to wait out the timeout wondering.
    func disconnect() async {
        await run("/api/bye", [:], say: "Disconnected")
        linked = false
    }

    func checkUpdate() async {
        await run("/api/update", [:], say: "Looking for an update")
    }

    /// Nothing wakes it from this but the power switch, which is what was
    /// asked for, so the panel is what confirms it rather than this app.
    func deepSleep() async {
        await run("/api/deepsleep", [:], say: "Going to sleep")
        linked = false
    }

    /// One screenful of pixels, 128 by 64, a bit each, top row first.
    func canvas(_ bytes: Data, seconds: Int = 8) async {
        guard bytes.count == 1024 else { flash("A screen is 1024 bytes"); return }
        await run("/api/canvas", ["b": bytes.base64EncodedString(), "s": String(seconds)], say: "Drawn")
    }

    // ---------------------------------------------------------------
    //  pairing
    // ---------------------------------------------------------------

    /// Asking for a code needs no token, otherwise a device whose token you
    /// had lost could never be paired again. Reading the code still means
    /// standing in front of the thing, which is the whole point of it.
    func requestCode() async {
        guard !ip.isEmpty else { flash("Set the address first"); return }
        pairError = ""
        do {
            try await post("/api/paircode", [:])
            pairing = true
        } catch {
            pairError = "Could not reach it"
        }
    }

    func pair(with code: String) async {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { pairError = "Six digits"; return }
        do {
            let body = try await post("/api/pair", ["c": digits])
            guard let t = Self.jsonString(body, "token"), !t.isEmpty else {
                pairError = "Wrong code"; return
            }
            token = t
            paired = true
            pairing = false
            pairError = ""
            flash("Paired")
            await refresh()
        } catch {
            pairError = "Wrong code, or it expired"
        }
    }

    func unpair() async {
        await run("/api/unpair", [:], say: "Unpaired")
        token = ""
        paired = false
    }

    // ---------------------------------------------------------------
    //  state
    // ---------------------------------------------------------------

    func refresh() async {
        guard !Device.inert else { return }
        guard !ip.isEmpty else { reachable = nil; return }
        do {
            var req = URLRequest(url: try url("/api/state"))
            req.timeoutInterval = 3
            req.setValue("1", forHTTPHeaderField: "X-Rafiq-App")
            if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Rafiq-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 401 still means the robot answered, so the dot stays green and
            // the panel shows the pairing prompt instead of a dead device.
            reachable = (code == 200 || code == 401)
            guard code == 200, let s = String(data: data, encoding: .utf8) else {
                if code == 401 { paired = true; linked = false }
                return
            }
            paired    = Self.jsonBool(s, "paired")
            linked    = Self.jsonBool(s, "linked")
            if pollMayWrite {
                following = Self.jsonBool(s, "follow")
                relaxing  = Self.jsonBool(s, "relax")
            }
            focusLeft = Self.jsonInt(s, "focusLeft")
            dndLeft   = Self.jsonInt(s, "dndLeft")
            version   = Self.jsonString(s, "fw") ?? version
            intWired  = Self.jsonBool(s, "intWired")
            netDown   = Self.jsonBool(s, "netDown")
            // Everything below is a switch you can throw from here, so
            // a reply that left before you threw it is not news.
            if pollMayWrite {
                gesture = Self.jsonBool(s, "gesture")
                deepOff = Self.jsonBool(s, "deepOff")
                autoUp  = Self.jsonBool(s, "autoUp")
                knock   = Self.jsonBool(s, "knock")
                shake   = Self.jsonBool(s, "shake")
                offline = Self.jsonBool(s, "offline")
                bike    = Self.jsonBool(s, "bike")
                btpl    = Self.jsonInt(s, "btpl")
            }
            plate     = Self.jsonString(s, "plate") ?? plate
            make      = Self.jsonString(s, "make") ?? make
            model     = Self.jsonString(s, "model") ?? model
            owner     = Self.jsonString(s, "owner") ?? owner
            deepi     = Self.jsonInt(s, "deepi")
            battPct   = Self.jsonInt(s, "battPct")
            if let bv = Self.jsonDouble(s, "battV")    { battV = bv }
            if let bf = Self.jsonDouble(s, "battFull") { battFull = bf }
            touches   = Self.jsonInt(s, "touches")
            netMax    = max(1, Self.jsonInt(s, "netMax"))
            bri  = Self.jsonInt(s, "bri");  face = Self.jsonInt(s, "face")
            slpi = Self.jsonInt(s, "slpi"); popi = Self.jsonInt(s, "popi")
            eye  = Self.jsonInt(s, "eye");  tap  = Self.jsonInt(s, "tap")
            autoTurn = Self.jsonBool(s, "turn")
            nets      = Self.parseNets(s)
        } catch {
            reachable = false
            linked = false
        }
    }

    // ---------------------------------------------------------------
    //  transport
    // ---------------------------------------------------------------

    private var statusClear: Task<Void, Never>?

    /// Returns whether the robot took it. Most callers ignore that and
    /// read the flash message instead; the reminder queue does not,
    /// because it has to know what still needs sending.
    @discardableResult
    private func run(_ path: String, _ fields: [String: String], say: String?) async -> Bool {
        guard !Device.inert else { return false }
        guard !ip.isEmpty else { flash("Set the address first"); return false }
        busy = true
        defer { busy = false }
        do {
            _ = try await post(path, fields)
            reachable = true
            if let say { flash(say) }
            return true
        } catch let e as URLError where e.code == .userAuthenticationRequired {
            reachable = true
            flash("Pair with the robot first")
            return false
        } catch {
            reachable = false
            // Quietly: a sleeping robot is the normal case for the
            // reminder queue, not something to put on the screen.
            if say != nil { flash("Could not reach it") }
            return false
        }
    }

    private func url(_ path: String) throws -> URL {
        let host = ip.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        return u
    }

    @discardableResult
    private func post(_ path: String, _ fields: [String: String]) async throws -> String {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Rafiq-App")
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Rafiq-Token") }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = fields
            .map { k, v in "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw URLError(.userAuthenticationRequired) }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func flash(_ s: String) {
        status = s
        statusClear?.cancel()
        statusClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.status = "" }
        }
    }

    // ---------------------------------------------------------------
    //  Small readers rather than a decoder: the device hand rolls its
    //  JSON and one unexpected field should never cost us the rest.
    // ---------------------------------------------------------------

    static func jsonString(_ b: String, _ key: String) -> String? {
        guard let r = b.range(of: "\"\(key)\"") else { return nil }
        var i = r.upperBound
        while i < b.endIndex, b[i] == ":" || b[i] == " " { i = b.index(after: i) }
        guard i < b.endIndex, b[i] == "\"" else { return nil }
        i = b.index(after: i)
        guard let end = b[i...].firstIndex(of: "\"") else { return nil }
        return String(b[i..<end])
    }
    static func jsonRaw(_ b: String, _ key: String) -> String? {
        guard let r = b.range(of: "\"\(key)\"") else { return nil }
        var i = r.upperBound
        while i < b.endIndex, b[i] == ":" || b[i] == " " { i = b.index(after: i) }
        var out = ""
        while i < b.endIndex, b[i] != ",", b[i] != "}" { out.append(b[i]); i = b.index(after: i) }
        return out.trimmingCharacters(in: .whitespaces)
    }
    static func jsonBool(_ b: String, _ key: String) -> Bool { jsonRaw(b, key) == "true" }

    /// The networks it knows, by name. There are never passwords in here.
    static func parseNets(_ b: String) -> [(ssid: String, on: Bool)] {
        guard let r = b.range(of: "\"nets\":[") else { return [] }
        guard let close = b[r.upperBound...].firstIndex(of: "]") else { return [] }
        let body = String(b[r.upperBound..<close])
        var out: [(String, Bool)] = []
        for piece in body.split(separator: "{") {
            guard let name = jsonString(String(piece), "ssid"), !name.isEmpty else { continue }
            out.append((name, jsonRaw(String(piece), "on") == "true"))
        }
        return out
    }
    static func jsonInt(_ b: String, _ key: String) -> Int { Int(jsonRaw(b, key) ?? "") ?? 0 }
    static func jsonDouble(_ b: String, _ key: String) -> Double? { Double(jsonRaw(b, key) ?? "") }
}

// ===================================================================
//  The pointer, sent over UDP
// ===================================================================
/// Ten a second through a fresh HTTP handshake each time would drown the
/// device, and a lost reading costs nothing because another is a tenth of a
/// second behind it. So these go out as bare datagrams and nothing is
/// acknowledged or retried.
@MainActor
final class Cursor {
    private var conn: NWConnection?
    private var timer: Timer?
    private var host = ""

    func start(host: String) {
        stop()
        self.host = host
        guard let p = NWEndpoint.Port(rawValue: 4210) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        c.start(queue: .global(qos: .utility))
        conn = c
        timer = Timer.every(0.1) { [weak self] in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        conn?.cancel(); conn = nil
    }

    private func tick() {
        guard let conn else { return }
        let p = NSEvent.mouseLocation
        // The screen the pointer is actually on, so a second monitor does
        // not send the eyes hard over to one side and leave them there.
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        guard let f = screen?.frame, f.width > 0, f.height > 0 else { return }
        let nx = Float((p.x - f.minX) / f.width) * 2 - 1
        // AppKit measures up from the bottom and the robot looks down from
        // the top of the monitor, so this is flipped.
        let ny = 1 - Float((p.y - f.minY) / f.height) * 2
        let msg = "\(Int(nx * 1000)) \(Int(ny * 1000))"
        conn.send(content: msg.data(using: .utf8), completion: .idempotent)
    }
}
