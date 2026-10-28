import SwiftUI

/// The devices this Mac knows about. One is current at a time, because
/// the panel speaks to one at a time; the rest sit here so swapping is
/// a tap rather than a scan and a guess.
@MainActor
final class Devices: ObservableObject {
    static let shared = Devices()

    struct Saved: Codable, Identifiable, Equatable {
        var id: String          // the advertised name, which is how we find it again
        var label: String       // what you call it
        var kind: String        // "zuno" or "rafiq"
    }

    @Published private(set) var list: [Saved] = Devices.load()
    /// The one the panel is for. Empty before anything has been added.
    @Published var currentId: String = UserDefaults.standard.string(forKey: "curDevice") ?? "" {
        didSet { UserDefaults.standard.set(currentId, forKey: "curDevice") }
    }

    var current: Saved? { list.first { $0.id == currentId } }
    var isEmpty: Bool { list.isEmpty }

    /// What a name tells us, before the device has said anything itself.
    static func kindOf(_ advertised: String) -> String {
        advertised.hasPrefix("Zuno") ? "zuno" : "rafiq"
    }

    func add(id: String, label: String, kind: String) {
        let clean = label.trimmingCharacters(in: .whitespaces)
        let one = Saved(id: id, label: clean.isEmpty ? id : clean, kind: kind)
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = one } else { list.append(one) }
        save()
        select(id)
    }
    func remove(_ id: String) {
        list.removeAll { $0.id == id }
        save()
        if currentId == id { select(list.first?.id ?? "") }
    }
    func rename(_ id: String, to label: String) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let clean = label.trimmingCharacters(in: .whitespaces)
        list[i].label = clean.isEmpty ? id : clean
        save()
    }
    /// Point the link at this one and let go of whatever it was on.
    func select(_ id: String) {
        currentId = id
        RobotLink.shared.choose(id)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(d, forKey: "devices")
        }
    }
    private static func load() -> [Saved] {
        guard let d = UserDefaults.standard.data(forKey: "devices"),
              let l = try? JSONDecoder().decode([Saved].self, from: d) else { return [] }
        return l
    }
}

/// First run, or after removing the last one: there is nothing to show
/// a panel about, so this asks for a device instead of pretending.
struct AddDevice: View {
    @ObservedObject private var link = RobotLink.shared
    @ObservedObject private var reg = Devices.shared
    @State private var naming: String? = nil
    @State private var label = ""
    /// True once looking has gone on long enough to be worth
    /// explaining. Said straight away it reads as an error; said after
    /// ten seconds of nothing it reads as help.
    @State private var patient = false
    var done: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Add a device").font(.system(size: 15, weight: .semibold))

            if let naming {
                Text("Found \(naming). What do you want to call it?")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                TextField(naming, text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                HStack(spacing: 8) {
                    Button("Cancel") { self.naming = nil; label = "" }
                        .font(.system(size: 11))
                    Button("Add") {
                        reg.add(id: naming, label: label, kind: Devices.kindOf(naming))
                        self.naming = nil; label = ""
                        done()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.borderedProminent)
                }
            } else if link.found.isEmpty {
                Text("Looking. Touch the device to wake it, and keep it near this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                ProgressView().controlSize(.small).padding(.top, 2)
                // A watch that is already connected in Bluetooth
                // settings has stopped advertising, so there is nothing
                // for a scan to hear. The panel asks macOS for what it
                // is holding as well, which takes a moment longer than
                // a scan does -- and if that still comes up empty, the
                // way through is to unpair, not to keep waiting.
                if patient {
                    Text("Already connected in System Settings > Bluetooth? "
                         + "Remove it there, then touch the device and look again.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18).padding(.top, 2)
                }
                Button("Look again") { link.rescan() }
                    .font(.system(size: 11)).buttonStyle(.link).padding(.top, 1)
            } else {
                Text("Pick the one you want to add.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                VStack(spacing: 5) {
                    ForEach(link.found) { d in
                        Button {
                            naming = d.name
                            label = d.name
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: Devices.kindOf(d.name) == "zuno" ? "circle.circle" : "square.circle")
                                Text(d.name).font(.system(size: 12))
                                Spacer()
                                if reg.list.contains(where: { $0.id == d.name }) {
                                    Text("added").font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .disabled(reg.list.contains(where: { $0.id == d.name }))
                    }
                }
                .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            patient = true
        }
    }
}
