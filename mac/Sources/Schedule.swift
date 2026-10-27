import SwiftUI

/// The day you are going to teach, written here and handed to the
/// watch. Once it is across, the watch owns it: it runs the day whether
/// or not this Mac is awake, present, or on the same continent.
@MainActor
final class Plan: ObservableObject {
    static let shared = Plan()

    struct Block: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var start: Int          // minutes from midnight
        var mins: Int
        var kind: Int           // 0 session, 1 break, 2 lunch, 3 other
    }
    static let kindNames = ["Session", "Break", "Lunch", "Block"]

    @Published var blocks: [Block] = Plan.load() {
        didSet { save() }
    }
    @Published private(set) var sending = false
    @Published private(set) var note = ""

    func add() {
        // A new block starts where the last one ends, because that is
        // what a day looks like and retyping the time is a chore.
        let after = blocks.map { $0.start + $0.mins }.max() ?? 9 * 60
        blocks.append(Block(name: "", start: min(after, 23 * 60), mins: 60, kind: 0))
    }
    func remove(_ id: UUID) { blocks.removeAll { $0.id == id } }

    var sorted: [Block] { blocks.sorted { $0.start < $1.start } }

    /// Overlaps are the one thing the watch cannot sort out for you,
    /// because it cannot know which one you meant.
    var clash: String? {
        let s = sorted
        guard s.count > 1 else { return nil }
        for i in 1..<s.count {
            if s[i].start < s[i - 1].start + s[i - 1].mins {
                return "\(s[i - 1].name.isEmpty ? "Block \(i)" : s[i - 1].name) runs into "
                     + "\(s[i].name.isEmpty ? "block \(i + 1)" : s[i].name)"
            }
        }
        return nil
    }

    static func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60 % 24, m % 60) }

    /// One block per write, so a long name never has to fit beside
    /// fifteen others inside a single MTU.
    func send() {
        let link = RobotLink.shared
        guard link.connected else { note = "Connect the device first"; return }
        let s = sorted
        guard !s.isEmpty else { _ = link.send("!sch clear"); note = "Cleared"; return }
        sending = true
        note = "Sending \(s.count) blocks"
        _ = link.send("!sch clear")
        Task { @MainActor in
            for (i, b) in s.enumerated() {
                let nm = RobotLink.ascii(b.name.isEmpty ? Plan.kindNames[b.kind] : b.name)
                _ = link.send("!sch \(i) \(b.start) \(b.mins) \(b.kind) \(nm)")
                try? await Task.sleep(nanoseconds: 120_000_000)   // let each write land
            }
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
            _ = link.send("!sch go \(f.string(from: Date())) \(s.count)")
            sending = false
            note = "Sent. The watch has today."
        }
    }
    func clearDevice() {
        _ = RobotLink.shared.send("!sch clear")
        note = "Cleared on the device"
    }

    private func save() {
        if let d = try? JSONEncoder().encode(blocks) { UserDefaults.standard.set(d, forKey: "plan") }
    }
    private static func load() -> [Block] {
        guard let d = UserDefaults.standard.data(forKey: "plan"),
              let l = try? JSONDecoder().decode([Block].self, from: d) else { return [] }
        return l
    }
}

struct SchedulePane: View {
    @ObservedObject private var plan = Plan.shared
    @ObservedObject private var link = RobotLink.shared
    @Binding var showing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SheetHead(title: "Today", showing: $showing)

            if plan.blocks.isEmpty {
                Text("Lay out the day and send it across. The watch runs it from "
                     + "there, asks before each block, warns you twice before the end, "
                     + "and keeps going whether or not this Mac is awake.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }

            ForEach($plan.blocks) { $b in
                HStack(spacing: 6) {
                    Picker("", selection: $b.kind) {
                        ForEach(0..<4, id: \.self) { k in Text(Plan.kindNames[k]).tag(k) }
                    }
                    .labelsHidden().frame(width: 84)

                    TextField(Plan.kindNames[b.kind], text: $b.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 96)

                    Stepper(Plan.hhmm(b.start), value: $b.start, in: 0...(23 * 60 + 55), step: 5)
                        .font(.system(size: 11)).frame(width: 96)

                    Stepper("\(b.mins)m", value: $b.mins, in: 5...300, step: 5)
                        .font(.system(size: 11)).frame(width: 78)

                    Button {
                        plan.remove(b.id)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button { plan.add() } label: { Label("Add block", systemImage: "plus") }
                    .font(.system(size: 11))
                Spacer()
                if let c = plan.clash {
                    Label(c, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 8) {
                Button(plan.sending ? "Sending…" : "Send to \(link.shortName)") { plan.send() }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.sending || !link.connected)
                Button("Clear on device") { plan.clearDevice() }
                    .font(.system(size: 11))
                    .disabled(!link.connected)
                Spacer()
                if !plan.note.isEmpty {
                    Text(plan.note).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if !link.connected {
                Text("Nothing is connected, so there is nowhere to send it yet.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}
