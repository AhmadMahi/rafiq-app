import SwiftUI
import AppKit

//  Rafiq's own settings. They live in the panel, scrolling, rather than
//  in a window of their own: a second window to manage is worse than a
//  little scrolling, and everything here belongs with the thing that
//  opened it.
//
//  Every row is the same shape, so the controls line up down one edge
//  instead of each finding its own place, which is what made the old
//  version look thrown together.
/// A row with its label on the left and its control on the right, so the
/// controls line up down the window instead of each finding its own place.
struct Row<Content: View>: View {
    let title: String
    var note: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                if !note.isEmpty {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            content.fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 2)
    }
}

struct Group2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.secondary)
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
    }
}

struct SettingsPane: View {
    @EnvironmentObject var dev: Device
    @EnvironmentObject var svc: Services
    @ObservedObject private var up = Updater.shared
    @ObservedObject private var link = RobotLink.shared
    @ObservedObject private var fx = Features.shared
    @ObservedObject private var diary = BatteryDiary.shared
    @ObservedObject private var reads = Reads.shared
    @State private var keyText = ""
    @State private var keyShown = false
    @State private var capText = ""
    @State private var pinText = ""
    @Binding var showing: Bool

    @State private var addr = ""

    private let breakChoices = [5, 10, 20, 30, 45, 60, 90]

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {

                // The same way back the robot's settings have. Without it
                // the only way out was the gear you came in by, which is
                // not where anyone looks.
                Button { showing = false } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Settings").font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Bluetooth is how it is reached. WiFi is a choice, and off.
                Group2(title: "Connection") {
                    Row(title: "Bluetooth", note: link.name.isEmpty ? "" : link.name) {
                        Text(link.state).font(.system(size: 11))
                            .foregroundStyle(link.connected ? Color.green : Color.secondary)
                    }
                    if !link.firmware.isEmpty {
                        Row(title: "Firmware",
                            note: link.full ? "everything over Bluetooth" : "7.4 brings the rest over Bluetooth") {
                            Text(link.firmware).font(.system(size: 11))
                        }
                    }
                    if link.staleHint {
                        // The robot is new enough but macOS still lists its old services.
                        Row(title: "Old Bluetooth list",
                            note: "System Settings, Bluetooth, Rafiq: Forget This Device. Then come "
                                + "back here and pair again; everything works after that.") {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    Row(title: "Use WiFi too",
                        note: "Turns the robot's WiFi on (off again after ten quiet minutes)") {
                        HStack {
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { dev.useWifi },
                                set: { on in
                                    dev.useWifi = on
                                    if on { dev.command("wifi", say: "Asking the robot onto WiFi") }
                                    Task { await dev.refresh() }
                                })).labelsHidden().toggleStyle(.switch)
                        }
                    }
                    Row(title: "Robot", note: "after a reset, or for another Rafiq") {
                        Button("Forget and look again") { link.forget() }
                            .font(.system(size: 11))
                    }
                }

                // 4.3: what the robot and this Mac do for each other.
                Group2(title: "Rafiq and this Mac") {
                    if !link.full {
                        Row(title: "Needs Rafiq 7.5", note: "Most of this works once the robot is updated") { EmptyView() }
                    }
                    fxToggle("Meeting mute", "In a call, a tap on the pad mutes this Mac's microphone; the next tap unmutes", $fx.meetMute)
                    fxToggle("Presentation clicker", "In Keynote, PowerPoint or a browser: knock for next, lean for back", $fx.clicker)
                    fxToggle("Volume knob", "Hold the pad and tilt Rafiq to turn the volume", $fx.knob)
                    fxToggle("Screenshot", "Three knocks: the whole screen, to the clipboard", $fx.shot)
                    fxToggle("Mac health", "Battery and free space on Rafiq's Mac screen, and a word when something needs you", $fx.health)
                    fxToggle("Dim while typing", "Rafiq's screen goes low while you type", $fx.dimTyping)
                    fxToggle("Prayer pause", "At the call to prayer this Mac goes quiet for \(fx.prayMinutes) minutes (not in a call)", $fx.prayPause)
                    fxToggle("Walk-away lock",
                             "Uses Rafiq. Carry it away and this Mac locks and the screen goes off; come back and the screen wakes for your password",
                             $fx.walkAway)
                    if fx.walkAway {
                        // "Locks when Rafiq is" left five points of margin
                        // beside a 160pt picker, which is not margin.
                        Row(title: "Locks at",
                            note: "How far Rafiq gets before this Mac locks. Radio indoors is not a tape measure, so these are approximate") {
                            Picker("", selection: Binding(get: { fx.walkRange },
                                                          set: { fx.walkRange = $0 })) {
                                Text("2 m").tag(0)
                                Text("3 m").tag(1)
                                Text("5 m").tag(2)
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                        }
                        Row(title: "Calibrate",
                            note: fx.walkDesk == 0
                                ? "Sit at your desk with Rafiq where you keep it, then press"
                                : "Calibrated at your desk. Re-do it if you move desks") {
                            HStack { Spacer(); Button("Here") { fx.calibrateWalk() } }
                        }
                    }
                    fxToggle("Apple Reminders", "Due reminders ring on Rafiq even with this Mac asleep; the top three show on its Mac screen", $fx.reminders)
                    if fx.reminders {
                        Row(title: "Pinned task", note: fx.pinned.isEmpty ? "Shown first; hold on Rafiq to tick it off" : "Now: " + fx.pinned) {
                            HStack(spacing: 4) {
                                TextField("Write proposal", text: $pinText).textFieldStyle(.roundedBorder).frame(width: 110)
                                Button("Pin") { fx.pin(pinText); pinText = "" }
                                if !fx.pinned.isEmpty { Button("Clear") { fx.pin("") } }
                            }
                            .font(.system(size: 11))
                        }
                    }
                    Row(title: "Night sleep", note: "Deep sleep from bedtime until just before Fajr; touch wakes it") {
                        HStack {
                            Spacer()
                            Toggle("", isOn: Binding(get: { dev.night }, set: { dev.setNight($0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    if dev.night {
                        Row(title: "Bedtime", note: dev.nightPush > 0 ? "Tonight \(dev.nightPush / 60) h later" : "") {
                            HStack(spacing: 6) {
                                Picker("", selection: Binding(get: { dev.bed }, set: { dev.setBed($0) })) {
                                    ForEach(Array(stride(from: 21 * 60, through: 25 * 60 + 30, by: 30)), id: \.self) { m in
                                        Text(String(format: "%02d:%02d", (m % 1440) / 60, m % 60)).tag(m % 1440)
                                    }
                                }
                                .labelsHidden().frame(width: 80)
                                Button("An hour later") { dev.pushNight() }
                            }
                            .font(.system(size: 11))
                        }
                    }
                    fxToggle("Weather and prayer times",
                             "Fetched here and sent across, so Rafiq never needs WiFi for them. "
                             + "Prayer times once a day, the weather more often. Your location, "
                             + "or Bangalore if the Mac will not say.",
                             $fx.skyFromMac)
                    if fx.skyFromMac {
                        Row(title: "Weather every", note: "Prayer times are a day's worth and go once a day") {
                            Picker("", selection: Binding(get: { fx.wxHours },
                                                          set: { fx.wxHours = $0 })) {
                                Text("1 h").tag(1); Text("2 h").tag(2)
                                Text("3 h").tag(3); Text("6 h").tag(6)
                            }
                            .labelsHidden().frame(width: 76)
                        }
                    }
                    fxToggle("Low battery warning", "A notification on this Mac at 20% and 10%", $fx.lowBatt)
                    fxToggle("Last seen", fx.lastSeen.isEmpty ? "Remembers when and where Rafiq was last with this Mac" : fx.lastSeen, $fx.lastSeenOn)
                    if !Keys.trusted && (fx.clicker || fx.shot) {
                        Row(title: "Accessibility", note: "The clicker presses keys for you, which macOS asks you to allow once") {
                            HStack { Spacer(); Button("Allow") { Keys.ask() } }
                        }
                    }
                    if !fx.note.isEmpty {
                        Text(fx.note).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }

                // 4.5: where the battery goes. The robot keeps one charge
                // cycle; this Mac keeps every reading until cleared.

                Group2(title: "Short reads") {
                    Text("Rafiq used to write these itself over WiFi with the key kept on the "
                         + "robot. This Mac does it now: the key stays here, and the story goes "
                         + "over the same Bluetooth link as everything else.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Not a Row. Row puts the label on the left and pins
                    // its content to the right at full width, and a 150
                    // point field with two buttons beside it leaves the
                    // label about one character wide, which is how
                    // "OpenAI key" came to be printed down the screen a
                    // letter at a time. A field this size belongs on its
                    // own line.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenAI key").font(.system(size: 12))
                        Text(reads.hasKey ? "Kept in this Mac's keychain"
                                          : "Needed before anything can be written")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Group {
                                if keyShown {
                                    TextField("sk-...", text: $keyText)
                                } else {
                                    SecureField(reads.hasKey ? "................" : "sk-...",
                                                text: $keyText)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 90)
                            Button(keyShown ? "Hide" : "Show") { keyShown.toggle() }
                            Button("Save") { reads.key = keyText; keyText = "" }
                                .disabled(keyText.isEmpty)
                        }
                        .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    fxToggle("Write them on their own", "While there is room on the shelf", $reads.auto)
                    if reads.auto {
                        Row(title: "A new one every", note: "Only while the shelf has room") {
                            Picker("", selection: $reads.everyDays) {
                                Text("day").tag(1)
                                Text("2 days").tag(2)
                                Text("3 days").tag(3)
                                Text("week").tag(7)
                            }
                            .labelsHidden().frame(width: 90)
                        }
                    }
                    Row(title: "Keep on the shelf", note: "\(link.readsOnShelf) there now") {
                        Picker("", selection: $reads.keep) {
                            ForEach([5, 10, 15], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden().frame(width: 64)
                    }
                    Row(title: "What to write", note: "Changed here, not in the firmware") { EmptyView() }
                    TextEditor(text: $reads.prompt)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 86)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    HStack {
                        Button("Put the old one back") { reads.prompt = Reads.defaultPrompt }
                        Spacer()
                        Button("Write one now") { reads.fetchNow() }
                            .disabled(!reads.hasKey || reads.busy || !link.full)
                    }
                    .font(.system(size: 11))
                    if !reads.state.isEmpty {
                        Text(reads.state).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                Group2(title: "Battery") {
                    if let c = diary.cycle {
                        Row(title: "Since full", note: "Robot's own log; estimated mAh in brackets") {
                            EmptyView()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Screen on \(BatteryDiary.hm(c.on))   Light sleep \(BatteryDiary.hm(c.light))")
                            Text("Dark, awake \(BatteryDiary.hm(c.dark))   Deep sleep \(BatteryDiary.hm(c.deep))")
                            Text("WiFi \(BatteryDiary.hm(c.wifi))   Wakes \(c.wakes)   Restarts \(c.restarts)")
                        }
                        .font(.system(size: 11, design: .monospaced))
                        if let n = diary.lightSleepNote {
                            Text(n).font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Row(title: "Diary", note: "Starts once Rafiq 7.8 is linked; a reading every ten minutes") { EmptyView() }
                    }
                    Row(title: "Real drain", note: "From how fast the percentage falls") {
                        Text("6 h: " + mA(diary.drain(hours: 6)) + "   24 h: " + mA(diary.drain(hours: 24)))
                            .font(.system(size: 11))
                    }
                    fxToggle("Keep a diary", "\(diary.entries.count) readings kept on this Mac", $diary.keep)
                    Row(title: "New cycle at", note: "The robot starts a new log when the battery reaches this") {
                        Picker("", selection: $diary.resetAt) {
                            ForEach(0..<4, id: \.self) { i in Text(BatteryDiary.resetVolts[i]).tag(i) }
                        }
                        .labelsHidden().frame(width: 90)
                    }
                    Row(title: "Battery size", note: "mAh, for turning percent into mAh") {
                        HStack(spacing: 4) {
                            TextField("350", text: $capText).textFieldStyle(.roundedBorder).frame(width: 60)
                            Button("Set") { if let v = Int(capText), v >= 50 { diary.capacity = v } }
                        }
                        .font(.system(size: 11))
                    }
                    HStack(spacing: 8) {
                        Button("New cycle now") { dev.command("!cfg blogreset 1", say: "A new battery log") }
                        Button("Export CSV") { diary.exportCSV() }
                        Button("Clear diary") { diary.clear() }
                    }
                    .font(.system(size: 11))
                }
                .onAppear { capText = String(diary.capacity) }

                if dev.useWifi {
                Group2(title: "WiFi") {
                    Row(title: "Address", note: "SYSTEM on the robot shows it") {
                        HStack(spacing: 6) {
                            TextField("192.168.1.42", text: $addr)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onSubmit(saveAddr)
                            Button("Save", action: saveAddr)
                        }
                    }
                    Row(title: "Paired",
                        note: dev.paired ? "Only this Mac can drive it"
                                         : "Anyone on your network can") {
                        HStack {
                            Spacer()
                            if dev.paired {
                                Button("Forget") { Task { await dev.unpair() } }
                            } else {
                                Button("Pair") { Task { await dev.requestCode() } }
                            }
                        }
                    }
                    if dev.paired {
                        Row(title: "Connection",
                            note: dev.linked ? "Connected. It will not sleep deeply."
                                             : "Not connected") {
                            HStack {
                                Spacer()
                                Button(dev.linked ? "Disconnect" : "Reconnect") {
                                    Task {
                                        if dev.linked { await dev.disconnect() }
                                        else { await dev.refresh() }
                                    }
                                }
                            }
                        }
                    }
                }

                }

                Group2(title: "This Mac") {
                    Row(title: "Break reminder", note: "How long before it says to move") {
                        Picker("", selection: Binding(get: { dev.breakMins },
                                                      set: { dev.breakMins = $0; svc.syncBreaks() })) {
                            ForEach(breakChoices, id: \.self) { Text("\($0) min").tag($0) }
                            if !breakChoices.contains(dev.breakMins) {
                                Text("\(dev.breakMins) min").tag(dev.breakMins)
                            }
                        }
                        .labelsHidden()
                    }
                    // Renamed. Both settings used to be called walking away:
                    // this one is a plain idle timer and has nothing to do
                    // with Rafiq, the other one follows Rafiq's signal.
                    Row(title: "Lock when idle",
                        note: dev.lockWhenIdle
                            ? "After \(dev.lockIdleMins) minutes with no keyboard or mouse. Rafiq is not involved"
                            : "Off. A plain idle timer, nothing to do with Rafiq") {
                        HStack(spacing: 6) {
                            if dev.lockWhenIdle {
                                Picker("", selection: Binding(get: { dev.lockIdleMins },
                                                              set: { dev.lockIdleMins = $0 })) {
                                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0)m").tag($0) }
                                }
                                .labelsHidden().frame(width: 72)
                            }
                            Toggle("", isOn: Binding(get: { dev.lockWhenIdle },
                                                     set: { dev.lockWhenIdle = $0 }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    Row(title: "Send what I copy",
                        note: "Skips anything a password manager marks") {
                        Toggle("", isOn: Binding(get: { dev.watchClipboard },
                                                 set: { dev.watchClipboard = $0; svc.syncClipboard() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    Row(title: "Appearance") {
                        Picker("", selection: Binding(get: { dev.theme },
                                                      set: { dev.theme = $0 })) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .labelsHidden()
                    }
                }

                // Rarely needed, so folded away.
                DisclosureGroup {
                    EndpointHelp().padding(.top, 6)
                } label: {
                    Text("REMINDERS OVER THE NETWORK")
                        .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(.secondary)
                }

                Group2(title: "Quick phrases") {
                    PhraseEditor()
                }

                Group2(title: "Updates") {
                    Row(title: "Rafiq \(up.current)", note: appNote) {
                        HStack {
                            Spacer()
                            switch up.phase {
                            case .checking, .downloading, .installing:
                                ProgressView().controlSize(.small)
                            case .found:
                                Button("Install") { Task { await up.check(andInstall: true) } }
                            default:
                                Button("Check") { Task { await up.check(andInstall: false) } }
                            }
                        }
                    }
                    // The robot updates from a file only (firmware 7.4.1): the
                    // Update tile in the robot's settings walks through it.
                    Row(title: dev.version.isEmpty ? "Robot firmware" : "Robot \(dev.version)",
                        note: "From a file: the robot's settings, then Update") {
                        EmptyView()
                    }
                }
            }
        }
        .onAppear { addr = dev.ip }
    }

    private func mA(_ v: Double?) -> String {
        guard let v else { return "--" }
        return String(format: "%.1f mA", v)
    }

    private func fxToggle(_ t: String, _ n: String, _ b: Binding<Bool>) -> some View {
        Row(title: t, note: n) {
            HStack { Spacer(); Toggle("", isOn: b).labelsHidden().toggleStyle(.switch).controlSize(.small) }
        }
    }

    private var appNote: String {
        switch up.phase {
        case .idle:          return "Looks in the rafiq-app repository"
        case .checking:      return "Looking..."
        case .none:          return "Up to date"
        case .found(let v):  return "Version \(v) is available"
        case .downloading:   return "Downloading..."
        case .installing:    return "Installing, it will restart"
        case .failed(let m): return m
        }
    }

    private func saveAddr() {
        dev.ip = addr.trimmingCharacters(in: .whitespaces)
        Task { await dev.refresh() }
    }
}

/// The phrases, as a list you can edit a line at a time.
///
/// It was one bare text area, which meant no way to reorder, no way to
/// delete one without selecting exactly the right characters, and a
/// stray blank line quietly becoming an empty phrase.
struct PhraseEditor: View {
    @EnvironmentObject var dev: Device
    @State private var adding = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(dev.phrases.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 6) {
                    Text(p).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if i > 0 {
                        Button { move(i, by: -1) } label: {
                            Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Button { remove(i) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            }
            HStack(spacing: 6) {
                TextField("Add a phrase", text: $adding)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var lines: [String] { dev.phrases }
    private func write(_ v: [String]) { dev.phrasesRaw = v.joined(separator: "\n") }
    private func add() {
        let t = adding.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        write(lines + [t]); adding = ""
    }
    private func remove(_ i: Int) {
        var v = lines; guard v.indices.contains(i) else { return }
        v.remove(at: i); write(v)
    }
    private func move(_ i: Int, by d: Int) {
        var v = lines
        let j = i + d
        guard v.indices.contains(i), v.indices.contains(j) else { return }
        v.swapAt(i, j); write(v)
    }
}


/// The robot takes reminders over plain HTTP, so anything that can open
/// a web address can set one: a Shortcut, the address bar, a cron line,
/// another machine. This is here rather than in a README because the
/// address and the token are yours and nobody else can write them down
/// for you.
struct EndpointHelp: View {
    @EnvironmentObject var dev: Device
    @State private var copied = ""

    private var host: String { dev.ip.isEmpty ? "robot.local" : dev.ip }
    private var tok: String  { dev.token.isEmpty ? "YOUR-TOKEN" : dev.token }

    /// Spaces and the rest, so it survives being pasted into a browser.
    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
    private func url(_ when: String) -> String {
        "http://\(host)/api/remind?t=\(tok)&text=\(esc("Call mum"))&\(when)"
    }
    /// Three at once, with times an hour, two and three from now so the
    /// example is one you can paste and watch arrive.
    private var bulk: String {
        let now = Int(Date().timeIntervalSince1970)
        var u = "http://\(host)/api/rems?t=\(tok)&n=3"
        let rows = [("Water the plants", 3600), ("Call the garage", 7200),
                    ("Take the bins out", 10800)]
        for (i, r) in rows.enumerated() {
            u += "&t\(i)=\(esc(r.0))&a\(i)=\(now + r.1)"
        }
        return u
    }

    /// The same bulk call as a one line shell command, for the case the
    /// URL form does not cover: anything past about eight reminders is
    /// too long to paste into a browser bar.
    private var curl: String {
        let now = Int(Date().timeIntervalSince1970)
        return "curl -X POST http://\(host)/api/rems -d t=\(tok) -d n=2"
            + " -d 't0=Water the plants' -d a0=\(now + 3600)"
            + " -d 't1=Call the garage' -d a1=\(now + 7200)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line("In 45 minutes", url("in=45"), "in")
            line("At half six", url("at=18:30"), "at")

            VStack(alignment: .leading, spacing: 3) {
                field("text", "what to be reminded of", "required")
                field("in",   "minutes from now",       "either")
                field("at",   "HH:MM, 24 hour",         "either")
                field("d",    "YYYY-MM-DD",             "optional")
            }
            .padding(.top, 2)

            Text("No date means today. Neither in nor at means three times that day, "
                 + "at nine, noon and six. Change the words after text= and open it "
                 + "anywhere: a browser, a Shortcut, anything that fetches a URL.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            line("Several at once", bulk, "bulk")
            VStack(alignment: .leading, spacing: 3) {
                field("n",     "how many rows follow",   "required")
                field("t0..",  "the words, one per row", "required")
                field("a0..",  "unix seconds, per row",  "required")
                field("d0..",  "1 to add it already done", "optional")
                field("clear", "1 empties the whole list", "optional")
            }
            .padding(.top, 2)

            Text("It adds what the robot has not got and leaves the rest alone, so "
                 + "sending the same list twice is harmless. The robot puts a card up "
                 + "saying how many landed.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            line("The same thing from a script", curl, "curl")
            Text("POST works wherever the URL gets too long to paste, which is about "
                 + "eight reminders.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            line("Everything it is holding", "http://\(host)/api/rem?t=\(tok)&list=1", "list")
            VStack(alignment: .leading, spacing: 3) {
                field("list",  "1 returns the whole list",  "")
                field("id",    "which one, from the list",  "to change")
                field("drop",  "1 deletes that one",        "optional")
                field("at",    "a new unix time for it",    "optional")
                field("text",  "new words for it",          "optional")
            }
            .padding(.top, 2)
            Text("Each reminder comes back with an id that does not change, so a script "
                 + "can read the list, pick one and move it. clock:false in the reply "
                 + "means the robot has lost the time and nothing will fire.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The token in the address is what stops anyone else on your network "
                 + "driving the robot. Treat the whole link like a password.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One snippet with a Copy button.
    ///
    /// Three lines, selectable, and that combination is not negotiable:
    /// a selectable Text sharing a page with one that wraps past three
    /// lines puts SwiftUI's layout into a loop it never comes out of,
    /// and the settings page simply never finishes measuring itself.
    /// Found by walking every page and watching it stop on this one.
    /// Anything longer than three lines goes on one line and is used
    /// through the Copy button.
    private func line(_ label: String, _ u: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium))
                Spacer()
                Button(copied == key ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(u, forType: .string)
                    copied = key
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = "" }
                }
                .font(.system(size: 10)).buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            Text(u)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
        }
    }

    private func field(_ k: String, _ what: String, _ need: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(k).font(.system(size: 10, design: .monospaced))
                .frame(width: 30, alignment: .leading)
            Text(what).font(.system(size: 10))
            Spacer()
            Text(need).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
