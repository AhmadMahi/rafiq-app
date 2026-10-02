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
    @Binding var showing: Bool

    @State private var addr = ""
    @State private var robotUpdate = ""

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

                Group2(title: "The robot") {
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
                    Row(title: "Lock when I walk away",
                        note: dev.lockWhenIdle ? "After \(dev.lockIdleMins) minutes with no keyboard or mouse"
                                               : "Off") {
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

                Group2(title: "Reminders over the network") {
                    EndpointHelp()
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
                    Row(title: dev.version.isEmpty ? "Robot firmware" : "Robot \(dev.version)",
                        note: robotUpdate.isEmpty ? "Asks the robot to look for its own update"
                                                  : robotUpdate) {
                        HStack {
                            Spacer()
                            Button("Check") {
                                robotUpdate = "Asked it to look"
                                Task { await dev.checkUpdate() }
                            }
                            .disabled(dev.reachable != true)
                        }
                    }
                }
            }
        }
        .onAppear { addr = dev.ip }
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


/// The robot takes reminders over HTTP, so anything on your network can
/// add one: a Shortcut, a cron line, another machine. This is here
/// rather than in a README because the address and the token are yours
/// and nobody else can write them down for you.
struct EndpointHelp: View {
    @EnvironmentObject var dev: Device
    @State private var copied = false

    private var curl: String {
        let ip = dev.ip.isEmpty ? "robot.local" : dev.ip
        let tok = dev.token.isEmpty ? "YOUR-TOKEN" : dev.token
        return "curl -X POST http://\(ip)/api/remind \\\n"
             + "  -H 'X-Rafiq-App: 1' -H 'X-Rafiq-Token: \(tok)' \\\n"
             + "  -d 'text=Take the washing out' -d 'at=18:30'"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("POST or GET  /api/remind")
                .font(.system(size: 11, design: .monospaced))

            VStack(alignment: .leading, spacing: 3) {
                field("text", "what to be reminded of", "required")
                field("at", "HH:MM, 24 hour", "optional")
                field("d", "YYYY-MM-DD", "optional, today")
            }

            Text("No date means today. No time at all means three times that day, "
                 + "at nine, noon and six, skipping any hour already gone.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(curl)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))

            HStack {
                Button(copied ? "Copied" : "Copy the command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(curl, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
            }

            Text("The token is what stops anyone else on your network driving the robot. "
                 + "Treat it like a password.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ k: String, _ what: String, _ need: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(k).font(.system(size: 10, design: .monospaced))
                .frame(width: 34, alignment: .leading)
            Text(what).font(.system(size: 10))
            Spacer()
            Text(need).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
