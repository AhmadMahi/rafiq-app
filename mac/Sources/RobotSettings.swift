import SwiftUI

/// The robot's own settings, as a grid of tiles rather than a list.
///
/// Deliberately separate from Rafiq's settings behind the gear. Those are
/// about this Mac; these are about the thing on your desk, and mixing them
/// was making both harder to find.
struct RobotSettings: View {
    @EnvironmentObject var dev: Device
    @Binding var showing: Bool

    @State private var page: Page? = nil
    enum Page: Hashable { case brightness, face, sleep, tap, nets, turn, popup, eyes, more }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    if page != nil { page = nil } else { showing = false }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text(page == nil ? "Robot settings" : title(page!))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if dev.version.isEmpty == false {
                    Text(dev.version).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            if let p = page { detail(p) } else { grid }
        }
        .animation(.easeOut(duration: 0.15), value: page)
    }

    private func title(_ p: Page) -> String {
        switch p {
        case .brightness: return "Brightness"
        case .face:       return "Watch face"
        case .sleep:      return "Sleep after"
        case .tap:        return "Knocks"
        case .nets:       return "Networks"
        case .turn:       return "Page turn"
        case .popup:      return "Popup time"
        case .eyes:       return "Eye style"
        case .more:       return "Updates and reset"
        }
    }

    // ---------------------------------------------------------------

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
                  spacing: 7) {
            Tile(icon: "sun.max", name: "Brightness",
                 detail: Device.brightNames[safe: dev.bri == 0 ? 0 : brightIndex] ?? "") { page = .brightness }
            Tile(icon: "clock", name: "Watch face",
                 detail: Device.faceNames[safe: dev.face] ?? "") { page = .face }
            Tile(icon: "moon", name: "Sleep after",
                 detail: Device.sleepNames[safe: dev.slpi] ?? "") { page = .sleep }

            Tile(icon: "hand.tap", name: "Knocks",
                 detail: dev.knock ? (Device.tapNames[safe: dev.tap] ?? "on") : "off") { page = .tap }
            Tile(icon: "wifi", name: "Networks",
                 detail: dev.nets.isEmpty ? "none" : "\(dev.nets.count) saved") { page = .nets }
            Tile(icon: "doc.plaintext", name: "Page turn",
                 detail: dev.autoTurn ? "auto" : "knock") { page = .turn }

            Tile(icon: "bubble.left", name: "Popup time",
                 detail: Device.popupNames[safe: dev.popi] ?? "") { page = .popup }
            Tile(icon: "eyes.inverse", name: "Eye style",
                 detail: Device.eyeNames[safe: dev.eye] ?? "") { page = .eyes }
            Tile(icon: "ellipsis.circle", name: "More",
                 detail: dev.autoUp ? "auto update on" : "updates, reset") { page = .more }
        }
    }

    @ViewBuilder
    private func detail(_ p: Page) -> some View {
        switch p {
        case .brightness:
            Choice(names: Device.brightNames, current: brightIndex) { i in
                Task { await dev.setBrightness(Device.brightVals[i]); await dev.refresh() }
            }
        case .face:
            Choice(names: Device.faceNames, current: dev.face) { i in
                Task { await dev.setFace(i); await dev.refresh() }
            }
        case .sleep:
            Choice(names: Device.sleepNames, current: dev.slpi) { i in
                Task { await dev.setSleep(i); await dev.refresh() }
            }
        case .popup:
            Choice(names: Device.popupNames, current: dev.popi) { i in
                Task { await dev.setPopup(i); await dev.refresh() }
            }
        case .eyes:
            Choice(names: Device.eyeNames, current: dev.eye) { i in
                Task { await dev.setEyes(i); await dev.refresh() }
            }
        case .turn:
            Choice(names: ["knock", "auto"], current: dev.autoTurn ? 1 : 0) { i in
                Task { await dev.setTurn(i == 1); await dev.refresh() }
            }
        case .tap:
            VStack(alignment: .leading, spacing: 9) {
                Toggle(isOn: Binding(get: { dev.knock },
                                     set: { v in Task { await dev.setKnock(v); await dev.refresh() } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Knocking").font(.system(size: 12))
                        Text("The touch pad always works. This adds knocks beside it.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                if dev.knock {
                    Divider()
                    Choice(names: Device.tapNames, current: dev.tap) { i in
                        Task { await dev.setTap(i); await dev.refresh() }
                    }
                    Text("How hard a knock has to be. Try them out on the robot itself, "
                         + "under Settings, where it shows you what it actually heard.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .nets:
            Networks()
        case .more:
            VStack(alignment: .leading, spacing: 9) {
                Toggle(isOn: Binding(get: { dev.autoUp },
                                     set: { v in Task { await dev.setAutoUpdate(v) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update itself").font(.system(size: 12))
                        Text("Looks once a day and installs what it finds, "
                             + "only while it is asleep and nothing is running")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)

                Divider()

                Button { Task { await dev.checkUpdate() } } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle").font(.system(size: 11))
                        Text("Check for firmware now").font(.system(size: 12))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)

                Button { Task { await dev.reboot() } } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        Text("Reboot the robot").font(.system(size: 12))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)

                Divider()

                ResetButton()
            }
        }
    }

    private var brightIndex: Int {
        Device.brightVals.firstIndex(of: dev.bri)
            ?? Device.brightVals.enumerated()
                .min(by: { abs($0.element - dev.bri) < abs($1.element - dev.bri) })?.offset
            ?? 0
    }
}

/// Resetting asks first, in place, because a settings screen is exactly
/// where a misplaced click lands.
struct ResetButton: View {
    @EnvironmentObject var dev: Device
    @State private var asking = false

    var body: some View {
        if asking {
            VStack(alignment: .leading, spacing: 7) {
                Text("Put every setting back the way it came?")
                    .font(.system(size: 11))
                Text("Networks, pairing and the reads stay.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Button("Reset") { asking = false; Task { await dev.resetSettings() } }
                        .font(.system(size: 11))
                    Button("Cancel") { asking = false }.font(.system(size: 11))
                }
            }
        } else {
            Button { asking = true } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                    Text("Reset the robot's settings").font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }
}

/// One of a short list of options, picked by clicking it.
struct Choice: View {
    let names: [String]
    let current: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                Button { pick(i) } label: {
                    HStack {
                        Text(n).font(.system(size: 12))
                        Spacer()
                        if i == current {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(i == current ? AnyShapeStyle(Color.accentColor.opacity(0.20))
                                           : AnyShapeStyle(Color.primary.opacity(0.06))))
                    .foregroundStyle(i == current ? AnyShapeStyle(Color.accentColor)
                                                  : AnyShapeStyle(Color.primary))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The networks the robot knows. The one it is on is marked; the order is
/// the order it tries them in.
struct Networks: View {
    @EnvironmentObject var dev: Device
    @State private var ssid = ""
    @State private var pass = ""
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(dev.nets.enumerated()), id: \.offset) { i, n in
                HStack(spacing: 6) {
                    Circle()
                        .fill(n.on ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(n.ssid).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if i > 0 {
                        Button { Task { await dev.promoteNetwork(i) } } label: {
                            Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Try this one earlier")
                    }
                    Button { Task { await dev.removeNetwork(i) } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            }

            if dev.nets.count < dev.netMax {
                if adding {
                    TextField("Network name", text: $ssid)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                    SecureField("Password", text: $pass)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                        .onSubmit(save)
                    HStack {
                        Button("Save", action: save).font(.system(size: 11))
                            .disabled(ssid.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { adding = false; ssid = ""; pass = "" }
                            .font(.system(size: 11))
                    }
                } else {
                    Button { adding = true } label: {
                        HStack {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text("Add a network").font(.system(size: 12))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            } else {
                Text("Full. Remove one to add another.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Text("Tried from the top down. The password is sent once and never "
                 + "read back, so this list can show names only.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func save() {
        let s = ssid, p = pass
        adding = false; ssid = ""; pass = ""
        Task { await dev.addNetwork(s, p) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
