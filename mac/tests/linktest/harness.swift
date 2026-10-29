// A fake CoreBluetooth, just wide enough for the real find/attach/resweep
// bodies to compile and run. The bodies themselves are pulled verbatim
// out of RobotLink.swift by extract.py -- what runs here is what ships.
import Foundation

/// Shadows the real one: the suite must not write to this Mac's defaults.
final class FakeDefaults {
    var store: [String: Any] = [:]
    func dictionary(forKey k: String) -> [String: Any]? { store[k] as? [String: Any] }
    func set(_ v: Any?, forKey k: String) { store[k] = v }
}
enum UserDefaults { static let standard = FakeDefaults() }

struct CBUUID: Equatable { let s: String; init(string: String) { s = string } }

final class CBPeripheral: Equatable {
    let identifier: UUID
    var name: String?
    var delegate: AnyObject?
    /// Is it actually in range? A fake peripheral that is not will never
    /// complete a connect, which is the case that used to wedge things.
    var reachable: Bool
    init(_ n: String?, reachable: Bool = true) {
        identifier = UUID(); name = n; self.reachable = reachable
    }
    static func == (a: CBPeripheral, b: CBPeripheral) -> Bool { a.identifier == b.identifier }
}

final class FakeCentral {
    enum St { case poweredOn, poweredOff }
    var state: St = .poweredOn
    var known: [CBPeripheral] = []        // what macOS remembers
    var heldBySystem: [CBPeripheral] = [] // what macOS is connected to
    var advertising: [CBPeripheral] = []  // what a scan can hear
    var scanning = false
    var connectCalls = 0
    var cancels = 0
    var onConnect: ((CBPeripheral) -> Void)?

    func retrievePeripherals(withIdentifiers ids: [UUID]) -> [CBPeripheral] {
        known.filter { ids.contains($0.identifier) }
    }
    func retrieveConnectedPeripherals(withServices _: [CBUUID]) -> [CBPeripheral] { heldBySystem }
    func scanForPeripherals(withServices _: [CBUUID]?, options _: [String: Any]?) {
        scanning = true
        // A scan only ever hears what is advertising, and delivers it
        // asynchronously -- the harness calls deliverScan() for that.
    }
    func stopScan() { scanning = false }
    func connect(_ p: CBPeripheral, options _: [String: Any]?) {
        connectCalls += 1
        if p.reachable { onConnect?(p) }      // otherwise: pending for ever
    }
    func cancelPeripheralConnection(_ p: CBPeripheral) { cancels += 1 }
}

@MainActor
final class Link {
    struct Seen: Equatable { let id: UUID; let name: String }

    let central = FakeCentral()
    var peripheral: CBPeripheral?
    var connected = false
    var state = ""
    var name = ""
    var prefer = ""
    var savedId: UUID?
    var found: [Seen] = []
    var pendingSince: Date?
    var scanning = false
    /// The real one is a computed property over UserDefaults; the
    /// extractor takes functions only, so it is restated here.
    var knownIds: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "bleKnown") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "bleKnown") }
    }
    var sweep: AnyObject? = nil
    var sweepStarted = 0
    var misses = 0
    var hint = ""
    var sawServices: [String] = []
    var discoverTry = 0

    static let uSvc = CBUUID(string: "52a1f000-7a3e-4b5c-9d6f-0a1b2c3d4e5f")
    static let uHid = CBUUID(string: "1812")
    static func ours(_ n: String) -> Bool { n.hasPrefix("Rafiq") || n.hasPrefix("Zuno") }
    func wanted(_ n: String) -> Bool { prefer.isEmpty || n == prefer }
    func startSweepStub() { sweepStarted += 1 }

    init() {
        // The real delegate callback arrives from CoreBluetooth's queue, so
        // the app hops to the main actor for it. The fake is already on the
        // main actor, and a Task would not run until this synchronous test
        // returned -- which is why four checks that a connect had completed
        // were reading the state from before it.
        central.onConnect = { [weak self] p in
            MainActor.assumeIsolated { self?.arrive(p) }
        }
    }
    /// Stand-in for didConnect + service discovery succeeding.
    func arrive(_ p: CBPeripheral) {
        guard peripheral == p else { return }
        connected = true
        stopScanning()
        pendingSince = nil
        state = "Connected"
        name = p.name ?? ""
    }
    /// Stand-in for didDiscover on the scan.
    func deliverScan() {
        guard central.scanning else { return }
        for p in central.advertising where !central.heldBySystem.contains(p) {
            let n = p.name ?? ""
            guard Link.ours(n) else { continue }
            note(p, as: n)
            guard peripheral == nil, wanted(n) else { continue }
            attach(p)
        }
    }
    func kick() { find() }
    /// resweep() is private where it ships. The suite drives it through
    /// here rather than changing the real declaration to suit a test.
    func tick() { resweep() }

#include_real_bodies
}

// ------------------------- the suite -------------------------------
@MainActor
func run() {
    var fails = 0
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
        if !ok { fails += 1 }
    }

    print("\n1. The reported bug: a stale remembered device, and a Zuno macOS holds")
    do {
        let l = Link()
        let oldRafiq = CBPeripheral("Rafiq Ahmed", reachable: false)   // left at the office
        let zuno = CBPeripheral("Zuno")                                 // held by macOS as a mouse
        l.central.known = [oldRafiq, zuno]
        l.central.heldBySystem = [zuno]      // so it is NOT advertising
        l.central.advertising = []
        l.savedId = oldRafiq.identifier
        l.kick()
        l.deliverScan()
        check(l.found.contains { $0.name == "Zuno" },
              "the Zuno macOS is holding is offered in the Add Device list")
        check(l.central.scanning, "the scan is still running while a connect is pending")
    }

    print("\n2. A connect that never completes is given up on")
    do {
        let l = Link()
        let gone = CBPeripheral("Rafiq Ahmed", reachable: false)
        l.central.known = [gone]
        l.savedId = gone.identifier
        l.kick()
        check(l.peripheral != nil, "it attached to the remembered one")
        check(!l.connected, "which never connects")
        l.pendingSince = Date().addingTimeInterval(-20)   // twelve seconds later
        l.tick()
        check(l.central.cancels == 1, "the pending connect was cancelled")
        check(l.savedId == gone.identifier, "but which device we want is remembered")
    }

    print("\n3. Once given up on, a device that IS there gets the link")
    do {
        let l = Link()
        let gone = CBPeripheral("Zuno", reachable: false)
        l.central.known = [gone]
        l.savedId = gone.identifier
        l.kick()
        check(!l.connected, "stuck on the one that is not there")
        gone.reachable = true                      // the watch wakes up
        l.pendingSince = Date().addingTimeInterval(-20)
        l.tick()
        check(l.connected, "the retry connects it")
    }

    print("\n4. A preferred device is not displaced by a remembered one")
    do {
        let l = Link()
        let rafiq = CBPeripheral("Rafiq Ahmed")
        let zuno = CBPeripheral("Zuno")
        l.central.known = [rafiq, zuno]
        l.central.heldBySystem = [zuno]
        l.savedId = rafiq.identifier
        l.prefer = "Zuno"
        l.kick()
        check(l.peripheral?.name == "Zuno", "it went to the Zuno, not the remembered Rafiq")
    }

    print("\n5. Ordinary case: one watch, advertising, nothing remembered")
    do {
        let l = Link()
        let zuno = CBPeripheral("Zuno")
        l.central.advertising = [zuno]
        l.kick()
        l.deliverScan()
        check(l.connected, "it connects")
        check(!l.central.scanning, "and the scan stops once it is on")
    }

    print("\n6. Look again clears a list that has gone stale")
    do {
        let l = Link()
        let zuno = CBPeripheral("Zuno")
        l.central.heldBySystem = [zuno]
        l.kick()
        check(l.found.count == 1, "one on the list")
        l.central.heldBySystem = []
        l.peripheral = nil
        l.rescan()
        check(l.found.isEmpty, "gone after a rescan")
    }

    print("\n7. Nothing anywhere: it says so and keeps sweeping")
    do {
        let l = Link()
        l.kick()
        check(l.found.isEmpty, "nothing offered")
        check(l.state.contains("Looking"), "it says it is looking: \"\(l.state)\"")
        check(l.sweepStarted > 0, "and a sweep is running, so it will look again")
    }

    print("\n8. A device met before, now neither advertising nor held")
    do {
        let first = Link()
        let zuno = CBPeripheral("Zuno")
        first.central.heldBySystem = [zuno]
        first.kick()                               // meets it once
        let second = Link()                        // the panel, relaunched
        second.central.known = [zuno]              // macOS still knows it
        second.central.heldBySystem = []           // but is not holding it
        second.central.advertising = []            // and it is not advertising
        second.kick()
        check(second.found.contains { $0.name == "Zuno" },
              "it is still offered, from what this Mac remembers")
    }

    print("\n9. A device that never answers stops hogging the search")
    do {
        let l = Link()
        let drawer = CBPeripheral("Rafiq Ahmed", reachable: false)  // in a drawer
        let zuno = CBPeripheral("Zuno")                             // on the desk
        l.central.known = [drawer, zuno]
        l.central.advertising = [zuno]
        l.savedId = drawer.identifier
        l.kick()
        l.deliverScan()
        check(l.peripheral == drawer, "it starts on the remembered one")
        for _ in 0..<2 {                      // two timeouts in a row
            l.pendingSince = Date().addingTimeInterval(-20)
            l.tick()
            l.deliverScan()
        }
        check(l.connected, "and ends up on the one that is actually there")
        check(l.name == "Zuno", "which is the Zuno")
    }

    print(fails == 0 ? "\nAll checks passed." : "\n\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}
Task { @MainActor in run() }
RunLoop.main.run()
