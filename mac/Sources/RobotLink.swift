import Foundation
import CoreBluetooth

/// Bluetooth to the robot.
///
/// Since firmware 6.0 the robot lives on Bluetooth and goes onto WiFi
/// only when asked, so this is the main way in. The HTTP path in Device
/// is kept for the times it is on WiFi, and for the few things that
/// still need it.
///
/// One service, firmware 7.2 and newer. Every characteristic needs an
/// encrypted link, so the first read is what makes macOS ask to pair:
///   CMD   write  a RAFIQ command, exactly as a Shortcut would send it
///   TIME  write  8 bytes, little end first: the wall clock in seconds
///   STAT  read   key=value pairs, ';' between them
///
/// The Mac says who it is ("iam Mac ...") when it connects, so the
/// robot's Devices list can name it and it can be chosen as Second.
@MainActor
final class RobotLink: NSObject, ObservableObject {
    static let shared = RobotLink()

    static let uSvc = CBUUID(string: "52a1f000-7a3e-4b5c-9d6f-0a1b2c3d4e5f")
    static let uCmd = CBUUID(string: "52a1f001-7a3e-4b5c-9d6f-0a1b2c3d4e5f")
    static let uTime = CBUUID(string: "52a1f003-7a3e-4b5c-9d6f-0a1b2c3d4e5f")
    static let uStat = CBUUID(string: "52a1f004-7a3e-4b5c-9d6f-0a1b2c3d4e5f")
    // firmware 7.4: gestures out, the pointer in, the settings read back
    static let uEvt = CBUUID(string: "52a1f005-7a3e-4b5c-9d6f-0a1b2c3d4e5f")
    static let uPtr = CBUUID(string: "52a1f006-7a3e-4b5c-9d6f-0a1b2c3d4e5f")
    static let uCfg = CBUUID(string: "52a1f007-7a3e-4b5c-9d6f-0a1b2c3d4e5f")
    /// The robot also advertises HID, which is how macOS may already
    /// hold a connection to it before this app asks.
    static let uHid = CBUUID(string: "1812")

    @Published private(set) var state = "Starting Bluetooth"
    @Published private(set) var connected = false
    @Published private(set) var stat: [String: String] = [:]
    @Published private(set) var name = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChr: CBCharacteristic?
    private var timeChr: CBCharacteristic?
    private var statChr: CBCharacteristic?
    private var evtChr: CBCharacteristic?
    private var ptrChr: CBCharacteristic?
    private var cfgChr: CBCharacteristic?
    private var lastPtr = ""
    private var lastPtrAt = Date.distantPast

    /// Firmware 7.4 or newer: everything the app does goes over Bluetooth,
    /// gestures and the pointer included.
    @Published private(set) var full = false
    private var poll: Timer?

    /// The robot this Mac belongs to, once one has been found. Kept so
    /// a second Rafiq in the room is never picked up by mistake.
    var savedId: UUID? {
        get { UserDefaults.standard.string(forKey: "bleRobot").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "bleRobot") }
    }

    private override init() {
        super.init()
        guard !Device.inert else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // ---------------------------------------------------------------
    //  reading what the robot says
    // ---------------------------------------------------------------

    var battery: Int? { stat["bat"].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } }
    var timerLeft: Int { stat["timer"].flatMap(Int.init) ?? 0 }
    var away: Bool { stat["away"] == "1" }
    var unread: Int { stat["unread"].flatMap(Int.init) ?? 0 }
    var quiet: Bool { stat["quiet"] == "1" }
    var guarding: Bool { stat["guard"] == "1" }
    var firmware: String { stat["fw"] ?? "" }
    var relaxing: Bool { stat["relax"] == "1" }
    var following: Bool { stat["follow"] == "1" }

    // ---------------------------------------------------------------
    //  sending
    // ---------------------------------------------------------------

    /// True when it went out. The robot's status is read again a moment
    /// later, so what the panel shows follows what was done.
    @discardableResult
    func send(_ command: String) -> Bool {
        guard connected, let p = peripheral, let c = cmdChr else { return false }
        let room = max(20, p.maximumWriteValueLength(for: .withResponse))
        var bytes = Array(Self.ascii(command).utf8)
        if bytes.count > room { bytes = Array(bytes.prefix(room)) }
        p.writeValue(Data(bytes), for: c, type: .withResponse)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.readStat()
        }
        return true
    }

    func readStat() {
        guard connected, let p = peripheral, let c = statChr else { return }
        p.readValue(for: c)
        if let k = cfgChr { p.readValue(for: k) }       // the settings too, on 7.4
    }

    /// The pointer, "x y" from -1000 to 1000. Only when it moved, or once
    /// a second so the robot knows it is still being followed: both ends
    /// stay asleep between, which is most of the time.
    func pointer(_ msg: String) {
        guard connected, let p = peripheral, let c = ptrChr else { return }
        let now = Date()
        if msg == lastPtr && now.timeIntervalSince(lastPtrAt) < 1 { return }
        lastPtr = msg; lastPtrAt = now
        p.writeValue(Data(msg.utf8), for: c, type: .withoutResponse)
    }

    /// Forget this robot and look again, for a new one or after a reset.
    func forget() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        savedId = nil
        connected = false
        stat = [:]
        name = ""
        find()
    }

    // ---------------------------------------------------------------
    //  finding and keeping the robot
    // ---------------------------------------------------------------

    private func find() {
        guard central.state == .poweredOn else { return }
        // The one we know, if macOS still has it.
        if let id = savedId, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(p)
            return
        }
        // One macOS is already holding (the robot advertises HID).
        if let p = central.retrieveConnectedPeripherals(withServices: [RobotLink.uSvc, RobotLink.uHid])
            .first(where: { ($0.name ?? "").hasPrefix("Rafiq") }) {
            attach(p)
            return
        }
        state = "Looking for Rafiq. Touch it to wake it."
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func attach(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        savedId = p.identifier
        name = p.name ?? "Rafiq"
        state = "Connecting to \(name)"
        // A pending connect never times out: macOS completes it whenever
        // the robot is next in range, which is exactly what is wanted.
        central.connect(p, options: nil)
    }

    private func ready() {
        guard let p = peripheral else { return }
        connected = true
        state = "Connected"
        if let t = timeChr { p.writeValue(Self.clock(), for: t, type: .withResponse) }
        if let c = cmdChr {
            let who = Self.ascii("iam Mac " + (Host.current().localizedName ?? ""))
            p.writeValue(Data(Array(who.utf8).prefix(21)), for: c, type: .withResponse)
        }
        readStat()
        poll?.invalidate()
        let me = self                        // a constant: see Gestures for why
        poll = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in me.readStat() }
        }
    }

    private func lost() {
        connected = false
        full = false
        evtChr = nil; ptrChr = nil; cfgChr = nil
        poll?.invalidate(); poll = nil
        cmdChr = nil; timeChr = nil; statChr = nil
        state = "Waiting for Rafiq"
        if let p = peripheral { central.connect(p, options: nil) }   // back when it is
    }

    // ---------------------------------------------------------------
    //  helpers
    // ---------------------------------------------------------------

    /// The phone's wall clock, which is what the robot shows.
    static func clock() -> Data {
        let now = Date()
        let wall = Int64(now.timeIntervalSince1970) + Int64(TimeZone.current.secondsFromGMT(for: now))
        return withUnsafeBytes(of: wall.littleEndian) { Data($0) }
    }

    /// The panel draws ASCII. Turn what it cannot draw into what it can.
    static func ascii(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\u{2018}", "\u{2019}": out.append("'")
            case "\u{201C}", "\u{201D}": out.append("\"")
            case "\u{2013}", "\u{2014}": out.append("-")
            case "\u{2026}": out.append("...")
            case "\n", "\r", "\t": out.append(" ")
            default:
                if u.value >= 0x20 && u.value < 0x7F { out.unicodeScalars.append(u) }
                else {
                    // letters with accents keep the letter
                    let base = String(u).decomposedStringWithCanonicalMapping.unicodeScalars.first
                    if let b = base, b.value >= 0x20 && b.value < 0x7F { out.unicodeScalars.append(b) }
                }
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ s: String) -> [String: String] {
        var m: [String: String] = [:]
        for kv in s.split(separator: ";") {
            guard let e = kv.firstIndex(of: "=") else { continue }
            m[String(kv[..<e])] = String(kv[kv.index(after: e)...])
        }
        return m
    }
}

// ===================================================================
//  CoreBluetooth calls these on the main queue (the manager was made
//  with queue: .main), so stepping onto the main actor is only saying
//  so out loud.
// ===================================================================

extension RobotLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let st = c.state
        MainActor.assumeIsolated {
            switch st {
            case .poweredOn:    self.find()
            case .poweredOff:   self.state = "Bluetooth is off"; self.connected = false
            case .unauthorized: self.state = "Allow Bluetooth for Rafiq in System Settings"
            case .unsupported:  self.state = "This Mac has no Bluetooth LE"
            default:            self.state = "Starting Bluetooth"
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi: NSNumber) {
        let n = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard n.hasPrefix("Rafiq") else { return }
        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            self.attach(p)
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            self.state = "Setting up"
            p.discoverServices([RobotLink.uSvc])
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.lost() }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated { self.lost() }
    }
}

extension RobotLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == RobotLink.uSvc }) else {
                self.state = "Rafiq needs firmware 7.2 or newer"
                return
            }
            p.discoverCharacteristics([RobotLink.uCmd, RobotLink.uTime, RobotLink.uStat,
                                       RobotLink.uEvt, RobotLink.uPtr, RobotLink.uCfg], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for c in s.characteristics ?? [] {
                if c.uuid == RobotLink.uCmd  { self.cmdChr = c }
                if c.uuid == RobotLink.uTime { self.timeChr = c }
                if c.uuid == RobotLink.uStat { self.statChr = c }
                if c.uuid == RobotLink.uEvt  { self.evtChr = c; p.setNotifyValue(true, for: c) }
                if c.uuid == RobotLink.uPtr  { self.ptrChr = c }
                if c.uuid == RobotLink.uCfg  { self.cfgChr = c }
            }
            self.full = self.evtChr != nil && self.ptrChr != nil && self.cfgChr != nil
            if self.cmdChr != nil && self.statChr != nil { self.ready() }
            else { self.state = "Rafiq needs firmware 7.2 or newer" }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            let v = c.value
            let isStat = c.uuid == RobotLink.uStat
            if let error {
                // An encrypted read before pairing: macOS shows its prompt
                // and the next poll succeeds once it is accepted.
                self.state = "Pairing: accept on this Mac (\(error.localizedDescription))"
                return
            }
            if isStat, let v, let s = String(data: v, encoding: .ascii) {
                self.stat = RobotLink.parse(s)
                if self.state != "Connected" { self.state = "Connected" }
            }
            // a knock or a press, in gesture mode
            if c.uuid == RobotLink.uEvt, let v, let s = String(data: v, encoding: .ascii), !s.isEmpty {
                Gestures.shared.heardBluetooth(s)
            }
            // the robot's settings, with /api/state's own names
            if c.uuid == RobotLink.uCfg, let v, let s = String(data: v, encoding: .utf8) {
                Device.shared.applyBleState(s)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic,
                                error: Error?) {
        guard let error else { return }
        let msg = error.localizedDescription
        MainActor.assumeIsolated { self.state = "Not sent: \(msg)" }
    }
}
