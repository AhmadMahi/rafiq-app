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
    enum Page: Hashable { case brightness, face, sleep, tap, nets, turn, popup, eyes,
                          battery, power, network, vehicle, firmware, reset }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The whole row goes back, not just the chevron. Hitting a
            // nine pixel arrow with a mouse is a chore, and the title
            // beside it points the same way, so it may as well mean it.
            Button {
                if page != nil { page = nil } else { showing = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(page == nil ? "Robot settings" : title(page!))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if dev.version.isEmpty == false {
                        Text(dev.version).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())        // the gaps count too
            }
            .buttonStyle(.plain)

            // Every page in here is given the same height as the grid,
            // so choosing one does not shuffle everything up the panel
            // and choosing another shuffle it back down. Short pages sit
            // at the top of their space rather than floating in it.
            Group {
                if let p = page {
                    detail(p)
                } else {
                    VStack(spacing: 10) { grid; rebootRow }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        }
        .animation(.easeOut(duration: 0.15), value: page)
    }

    private func title(_ p: Page) -> String {
        switch p {
        case .brightness: return "Brightness"
        case .face:       return "Watch face"
        case .sleep:      return "Sleep after"
        case .tap:        return "Controls"
        case .nets:       return "Networks"
        case .turn:       return "Page turn"
        case .popup:      return "Popup time"
        case .eyes:       return "Eye style"
        case .network:    return "Network"
        case .vehicle:    return "Vehicle"
        case .battery:    return "Battery"
        case .power:      return "Power down"
        case .firmware:   return "Firmware"
        case .reset:      return "Reset"
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

            Tile(icon: "hand.tap", name: "Controls",
                 detail: dev.knock ? "touch + knock" : "touch") { page = .tap }
            Tile(icon: "wifi", name: "Networks",
                 detail: dev.nets.isEmpty ? "none" : "\(dev.nets.count) saved") { page = .nets }
            Tile(icon: "doc.plaintext", name: "Page turn",
                 detail: dev.autoTurn ? "auto" : "knock") { page = .turn }

            Tile(icon: "bubble.left", name: "Popup time",
                 detail: Device.popupNames[safe: dev.popi] ?? "") { page = .popup }
            Tile(icon: "eyes.inverse", name: "Eye style",
                 detail: Device.eyeNames[safe: dev.eye] ?? "") { page = .eyes }
            // What used to be behind More. There was a grid's worth of
            // empty space under three rows and four things hidden
            // behind one tile, which is two problems that cancel.
            Tile(icon: "battery.100", name: "Battery",
                 detail: dev.battPct < 0 ? "no pack" : "\(dev.battPct)%") { page = .battery }
            Tile(icon: "powersleep", name: "Power down",
                 detail: dev.deepOff ? "off" : (Device.deepNames[safe: dev.deepi] ?? "")) { page = .power }
            Tile(icon: "arrow.down.circle", name: "Firmware",
                 detail: dev.autoUp ? "auto" : (dev.version.isEmpty ? "check" : dev.version)) { page = .firmware }
            Tile(icon: "arrow.counterclockwise", name: "Reset",
                 detail: "settings only") { page = .reset }
            Tile(icon: dev.offline ? "wifi.slash" : "wifi", name: "Network",
                 detail: dev.offline ? "off" : (dev.netDown ? "no signal" : "on")) { page = .network }
            Tile(icon: "bicycle", name: "Vehicle",
                 detail: dev.bike ? (Device.bikeTemplates[safe: dev.btpl] ?? "on") : "off") { page = .vehicle }
        }
    }

    /// Reboot sits under the grid rather than in it. It is the one
    /// thing here that interrupts whatever the robot is doing, and a
    /// tile among twelve identical tiles is too easy to hit by accident.
    private var rebootRow: some View {
        Button { Task { await dev.reboot() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                Text("Reboot the robot").font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
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

                Divider()

                Toggle(isOn: Binding(get: { dev.shake },
                                     set: { v in Task { await dev.setShake(v); await dev.refresh() } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shake to go back").font(.system(size: 12))
                        Text("One step back per shake, never past the clock")
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
        case .battery:
            VStack(alignment: .leading, spacing: 9) {
                Text(dev.battPct < 0 ? "No pack connected"
                                     : "\(dev.battPct)%  ·  \(String(format: "%.2f", dev.battV))V")
                    .font(.system(size: 13, weight: .medium))
                Divider()
                Text("Full charge").font(.system(size: 11, weight: .medium))
                Choice(names: ["3.95V", "4.00V", "4.05V", "4.10V", "4.15V", "4.20V"],
                       current: max(0, min(5, Int(((dev.battFull - 3.95) / 0.05).rounded())))) { i in
                    Task { await dev.setBattFull(3.95 + Double(i) * 0.05); await dev.refresh() }
                }
                Text("Charge it fully, measure the pack, and pick what you measured. "
                     + "Everything scales from it, so the top of the charge reads as "
                     + "the top of the scale.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .power:
            VStack(alignment: .leading, spacing: 9) {
                Toggle(isOn: Binding(get: { !dev.deepOff },
                                     set: { v in Task { await dev.setDeepSleep(v); await dev.refresh() } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Switch off when alone").font(.system(size: 12))
                        Text("Only while Rafiq is not connected. With the app talking to it "
                             + "it just darkens the screen, so it stays reachable.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)

                if !dev.deepOff {
                    Divider()
                    Choice(names: Device.deepNames, current: dev.deepi) { i in
                        Task { await dev.setDeepAfter(i); await dev.refresh() }
                    }
                    Text("Only a touch wakes it. Reminders and prayer times still bring it "
                         + "back on their own: it works out when to return before it goes.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .network:
            VStack(alignment: .leading, spacing: 9) {
                Toggle(isOn: Binding(get: { !dev.offline },
                                     set: { v in Task { await dev.setOffline(!v); await dev.refresh() } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Use the network").font(.system(size: 12))
                        Text("Off means the radio is off and stays off. Everything "
                             + "except the weather still works, and it switches itself "
                             + "off between touches to save the battery.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
                if dev.netDown && !dev.offline {
                    Text("It tried and found nothing, so the radio is off until it next "
                         + "wakes. This is not a fault.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .vehicle:
            VehiclePane()

        case .firmware:
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
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)

                if dev.version.isEmpty == false {
                    Text("On \(dev.version) now.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

        case .reset:
            VStack(alignment: .leading, spacing: 9) {
                ResetButton()
                Text("Every setting back to how it arrived. Networks, pairing and the "
                     + "shelf of reads are not settings and are left alone.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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


/// The vehicle screen's contents. Four layouts; the robot cycles them
/// on a long press and this picks one directly.
struct VehiclePane: View {
    @EnvironmentObject var dev: Device
    @State private var plate = ""
    @State private var model = ""
    @State private var owner = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(get: { dev.bike },
                                 set: { v in Task { await dev.setBike(v); await dev.refresh() } })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show the vehicle screen").font(.system(size: 12))
                    Text("Second screen on the robot, after the clock")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)

            if dev.bike {
                Divider()
                Choice(names: Device.bikeTemplates, current: dev.btpl) { i in
                    Task { await dev.setBikeTemplate(i); await dev.refresh() }
                }
                field("Number plate", $plate)
                field("Model", $model)
                field("Owner", $owner)
                Button("Save") {
                    Task { await dev.setBikeInfo(plate: plate, model: model, owner: owner)
                           await dev.refresh() }
                }
                .font(.system(size: 11)).buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Text("A long press on the vehicle screen walks the four layouts too.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            plate = dev.plate; model = dev.model; owner = dev.owner
        }
    }

    private func field(_ label: String, _ v: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).frame(width: 86, alignment: .leading)
            TextField("", text: v).textFieldStyle(.roundedBorder).font(.system(size: 11))
        }
    }
}
