import Foundation

/// Short reads, written here and sent across.
///
/// The robot used to call OpenAI itself over WiFi with the key stored on
/// the device. That meant the radio coming up for a story and a key on a
/// thing you carry around. Both are gone: the key lives in this Mac's
/// keychain, the Mac does the writing, and the story goes over the same
/// Bluetooth link as everything else.
///
/// The prompt is yours to change. It is a text field rather than
/// something compiled in, so what Rafiq reads can be different tomorrow
/// without a firmware update.
@MainActor
final class Reads: ObservableObject {
    static let shared = Reads()

    static let defaultPrompt =
        "Write a warm, romantic short story of about 900 words in simple English. "
        + "Give the characters Muslim names such as Ayaan, Zaynab, Bilal, Maryam, Idris, "
        + "Safiya, Yusuf, Aisha, Hamza or Khadija. Keep it tender and respectful, the kind "
        + "of story that ends happily. Set it somewhere ordinary and real. Begin with a "
        + "short line of five or six words that works as a title, then a blank line, then "
        + "the story. Plain prose only: no headings, no markdown, no lists."

    @Published var auto = UserDefaults.standard.object(forKey: "rdAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: "rdAuto") } }
    @Published var keep = UserDefaults.standard.object(forKey: "rdKeep") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(keep, forKey: "rdKeep") } }
    /// How many days between stories. One was the only choice before.
    @Published var everyDays = UserDefaults.standard.object(forKey: "rdEvery") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(everyDays, forKey: "rdEvery") } }
    @Published var prompt = UserDefaults.standard.string(forKey: "rdPrompt") ?? Reads.defaultPrompt {
        didSet { UserDefaults.standard.set(prompt, forKey: "rdPrompt") } }
    @Published var state = ""
    @Published var busy = false

    var key: String {
        get { Keychain.get("openai") }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "openai") }
    }
    var hasKey: Bool { !key.isEmpty }

    private var lastDay = UserDefaults.standard.string(forKey: "rdDay") ?? ""
    private var link: RobotLink { RobotLink.shared }

    // ---- what is being sent, and how far it has got ----
    private var outChunks: [String] = []
    private var outAt = 0
    private var outLen = 0
    private var sending = false
    private var retried = false

    private static func dayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Once a minute. One every so many days, and only while there is
    /// room on the shelf.
    func tick() {
        guard auto, hasKey, link.full, !busy, !sending else { return }
        guard link.readsOnShelf < keep else { return }
        guard Self.daysSince(lastDay) >= max(1, everyDays) else { return }
        Task { await fetchAndSend(becauseAsked: false) }
    }

    /// Whole days between a stored key and today. A missing or unreadable
    /// one means "long ago", so the first run writes something.
    private static func daysSince(_ key: String) -> Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let then = f.date(from: key) else { return 9999 }
        return Calendar.current.dateComponents([.day], from: then, to: Date()).day ?? 9999
    }

    /// The robot asked for one, so it gets one whatever the day says.
    func askedFor() {
        guard hasKey else { state = "No key on this Mac"; return }
        guard !busy, !sending else { return }
        Task { await fetchAndSend(becauseAsked: true) }
    }

    func fetchNow() { askedFor() }

    private func fetchAndSend(becauseAsked: Bool) async {
        busy = true; state = "Writing"
        defer { busy = false }
        guard let text = await write() else { return }
        // Only now does the day count as used. A failed call must not
        // cost the whole day, which is the mistake the weather made.
        if !becauseAsked {
            lastDay = Self.dayKey()
            UserDefaults.standard.set(lastDay, forKey: "rdDay")
        }
        send(text)
    }

    private func write() async -> String? {
        guard let u = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
        let body: [String: Any] = ["model": "gpt-4o-mini", "max_tokens": 1800,
                                   "temperature": 1.0,
                                   "messages": [["role": "user", "content": prompt]]]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                state = "OpenAI said \(h.statusCode)"
                return nil
            }
            guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ch = j["choices"] as? [[String: Any]],
                  let m = ch.first?["message"] as? [String: Any],
                  let t = m["content"] as? String, t.count > 200 else {
                state = "The reply was not a story"
                return nil
            }
            return t
        } catch {
            state = "Could not reach OpenAI"
            return nil
        }
    }

    // ---- across the link, in pieces ----
    //
    //  Up to 6000 characters will not fit in one write. The robot's queue
    //  is four deep, so this waits for its "read ok" before sending the
    //  next piece rather than trusting it to keep up, and the length goes
    //  with the end so a piece lost in the middle is caught rather than
    //  stored as a story with a hole in it.
    private func send(_ textIn: String) {
        let text = String(textIn.prefix(6000))
        // The robot turns 0x1E back into a newline. A real one would be
        // flattened to a space on the way out, and the blank line after
        // the title is what makes it a title.
        // Capped after the conversion, not before: ascii() can make a
        // string longer, because an ellipsis becomes three dots, and the
        // robot stops at 6000 characters whatever we think we sent.
        let safe = String(RobotLink.ascii(text.replacingOccurrences(of: "\n", with: "\u{1E}"))
                          .prefix(6000))
        outLen = safe.count
        // Sized to one write rather than a round number. 360 plus the
        // "!read+ |" fence is 369 bytes, past what a single packet
        // holds, so CoreBluetooth sent each piece as a long write:
        // several round trips behind the scenes, each one a connection
        // interval, which is where the minute went. Nine bytes of
        // fence, and a floor so a small MTU cannot make this crawl.
        let step = max(80, link.singleWriteRoom - 9)
        outChunks = stride(from: 0, to: safe.count, by: step).map {
            let a = safe.index(safe.startIndex, offsetBy: $0)
            let b = safe.index(a, offsetBy: min(step, safe.count - $0))
            return String(safe[a..<b])
        }
        outAt = 0; sending = true; retried = false
        state = "Sending piece 1 of \(outChunks.count)"
        link.send("!read begin")
    }

    /// Events from the robot: one piece acknowledged, or the whole thing.
    func heard(_ ev: String) -> Bool {
        guard ev.hasPrefix("read ") else { return false }
        if ev == "read ok" {
            guard sending else { return true }
            if outAt < outChunks.count {
                let c = outChunks[outAt]; outAt += 1
                state = "Sending piece \(outAt) of \(outChunks.count)"
                // Fenced with bars. Every command goes through ascii(),
                // which trims the ends, so a piece that happened to end
                // on a space would arrive one character shorter than the
                // length we promised and the whole story would be
                // refused. The bars are stripped on the other side.
                link.send("!read+ |" + c + "|")
            } else {
                link.send("!read end \(outLen)")
            }
            return true
        }
        if ev == "read done" {
            sending = false; outChunks = []
            state = "Sent"
            link.readStat()
            return true
        }
        if ev.hasPrefix("read err") {
            sending = false; outChunks = []
            state = "It arrived short"
            return true
        }
        return true
    }

    func stopSending() {
        guard sending else { return }
        sending = false; outChunks = []
        link.send("!read abort")
        state = "Stopped"
    }
}
