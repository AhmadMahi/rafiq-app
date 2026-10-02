import Foundation
import SwiftUI

struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var fireAt: Date
    var done = false
    /// Whether the robot has it. Reminders are written here and kept
    /// here until the robot answers, because the robot is very often
    /// asleep when you think of something.
    var delivered = false
    /// The robot's own id for this one, once it has taken it. Editing
    /// and deleting go by this: matching on the words and the minute
    /// fell apart the moment the thing being changed was the minute.
    var robotId: UInt32?
}

/// A short list of things to be told about. Edited here, and mirrored
/// onto the robot, which keeps its own copy and wakes itself when one
/// comes due. That used to be this Mac's job on the grounds that the
/// robot lost track of time while it slept. It does not: the clock runs
/// through deep sleep. What the Mac cannot do is be open at nine in the
/// morning, which is exactly when a reminder is wanted.
@MainActor
final class Reminders: ObservableObject {
    static let shared = Reminders()
    static let maxKept = 20

    @Published private(set) var items: [Reminder] = []
    /// False when the robot has lost the clock. Its times then mean
    /// nothing and nothing will fire, so the list says so instead of
    /// showing times that will not happen.
    @Published private(set) var robotClock = true
    /// When the robot's list was last actually read, so the panel can
    /// tell a genuinely empty robot from one that could not be asked.
    @Published private(set) var lastSynced: Date?

    private var timer: Timer?
    private var fire: ((Reminder) -> Void)?
    private let key = "reminders"

    init() { load() }

    var pending: [Reminder] {
        items.filter { !$0.done }.sorted { $0.fireAt < $1.fireAt }
    }

    /// Hands the robot everything it has not got yet, and marks them
    /// off only when it says so. Anything still undelivered waits for
    /// the next go: a robot that is switched off is the normal case,
    /// not an error.
    ///
    /// Nothing is ever withdrawn. The robot owns the list now, and a
    /// push that replaced it would throw away anything added straight
    /// to the robot, which is exactly what used to happen.
    func deliver() async {
        let waiting = items.filter { !$0.delivered && !$0.done && $0.fireAt > Date() }
        guard !waiting.isEmpty else { return }
        guard await Device.shared.pushReminders(waiting) else { return }
        for i in items.indices where waiting.contains(where: { $0.id == items[i].id }) {
            items[i].delivered = true
        }
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: key)
        }
        // The push does not hand back ids, so read the list straight
        // after to find out what the robot called them. Without this
        // the app could never edit or delete anything it had just sent.
        await refresh()
    }

    /// Read the robot's own list and make this one agree with it.
    ///
    /// The robot's copy is the real one: reminders can arrive there
    /// from a plain URL, a phone shortcut, anything, and never pass
    /// through this Mac at all. Anything still queued here is left
    /// alone, because the robot has not seen it yet and its absence
    /// from the robot's list is not evidence of anything.
    func refresh() async {
        guard let (robot, clock) = await Device.shared.fetchReminders() else { return }
        robotClock = clock
        lastSynced = Date()

        var byId: [UInt32: Int] = [:]
        for (i, r) in items.enumerated() { if let rid = r.robotId { byId[rid] = i } }

        var claimedLocally = Set<UUID>()
        for rr in robot {
            if let i = byId[rr.id] {
                items[i].text = rr.text
                items[i].fireAt = rr.fireAt
                items[i].done = rr.done
                items[i].delivered = true
                claimedLocally.insert(items[i].id)
                continue
            }
            // Something sent a moment ago, back with an id now. Claim
            // it rather than showing the same reminder twice.
            let minute = rr.at / 60
            if let i = items.firstIndex(where: {
                $0.robotId == nil && !claimedLocally.contains($0.id) &&
                $0.text == rr.text && UInt32($0.fireAt.timeIntervalSince1970) / 60 == minute
            }) {
                items[i].robotId = rr.id
                items[i].done = rr.done
                items[i].delivered = true
                claimedLocally.insert(items[i].id)
                continue
            }
            // Never seen here: added straight to the robot.
            var n = Reminder(text: rr.text, fireAt: rr.fireAt, done: rr.done)
            n.delivered = true
            n.robotId = rr.id
            items.append(n)
            claimedLocally.insert(n.id)
        }

        // Anything this app thought the robot had, and the robot does
        // not: cleared on the robot, so cleared here.
        let live = Set(robot.map(\.id))
        items.removeAll { r in r.robotId.map { !live.contains($0) } ?? false }

        items.sort { $0.fireAt < $1.fireAt }
        persist()
    }

    var undelivered: Int {
        items.filter { !$0.delivered && !$0.done && $0.fireAt > Date() }.count
    }

    func start(_ fire: @escaping (Reminder) -> Void) {
        self.fire = fire
        timer?.invalidate()
        guard !Device.inert else { return }
        // Ten seconds is close enough for something measured in minutes,
        // and it costs nothing to check.
        timer = Timer.every(10) { [weak self] in
            Task { @MainActor in
                self?.tick()
                await self?.deliver()        // anything the robot missed
                await self?.refresh()        // and anything added without us
            }
        }
        tick()
    }

    func add(_ text: String, at when: Date) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(Reminder(text: t, fireAt: when))
        trim()
        save()
    }

    func add(_ text: String, inMinutes m: Int) {
        add(text, at: Date().addingTimeInterval(TimeInterval(max(1, m) * 60)))
    }

    func remove(_ r: Reminder) {
        items.removeAll { $0.id == r.id }
        persist()                       // not save(): nothing to push
        if let rid = r.robotId {
            Task { _ = await Device.shared.dropReminder(rid) }
        }
    }

    /// Change the words or the time of one already in the list. A
    /// reminder the robot has is changed on the robot too; one still
    /// queued here is simply queued differently.
    func update(_ r: Reminder, text: String, at when: Date) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = items.firstIndex(where: { $0.id == r.id }) else { return }
        items[i].text = String(t.prefix(Device.remTextMax))
        items[i].fireAt = when
        items[i].done = false
        items.sort { $0.fireAt < $1.fireAt }
        persist()
        if let rid = r.robotId {
            let text = items.first { $0.id == r.id }?.text ?? t
            Task { _ = await Device.shared.editReminder(rid, text: text, at: when) }
        } else {
            Task { await deliver() }    // not there yet; it goes with the next push
        }
    }

    func clearAll() {
        items.removeAll()
        persist()
        Task { await Device.shared.clearReminders() }
    }

    /// Ten minutes on, the same as a snooze on the robot.
    func snooze(_ r: Reminder) {
        guard let i = items.firstIndex(where: { $0.id == r.id }) else { return }
        items[i].done = false
        items[i].fireAt = Date().addingTimeInterval(600)
        save()
    }

    private func tick() {
        let now = Date()
        for i in items.indices where !items[i].done && items[i].fireAt <= now {
            items[i].done = true
            fire?(items[i])
        }
        // Anything long since said is cleared out, so the list stays the
        // things still ahead of you rather than a history.
        let cutoff = now.addingTimeInterval(-3600)
        items.removeAll { $0.done && $0.fireAt < cutoff }
        save()
    }

    private func trim() {
        let extra = pending.count - Self.maxKept
        if extra > 0 {
            for r in pending.suffix(extra) { items.removeAll { $0.id == r.id } }
        }
    }

    private func persist() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    private func save() {
        persist()
        // And down to the robot, which keeps its own copy from firmware
        // 4.0.0. It has to: this Mac may be shut at nine in the morning,
        // and the robot can only wake itself for something it knows
        // about. The Mac still owns the editing; the robot owns the
        // knowing when.
        Task { await deliver() }
    }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([Reminder].self, from: d) else { return }
        items = v
    }
}
