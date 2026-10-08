import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Updating the robot from a file, the only way since firmware 7.4.1.
///
/// The robot opens its own hotspot (asked over Bluetooth), this Mac joins
/// it, and the file goes to the same page a browser would use,
/// http://192.168.4.1/ota. When the robot restarts its hotspot goes, and
/// macOS goes back to your usual WiFi by itself.
struct UpdatePane: View {
    @EnvironmentObject var dev: Device
    @ObservedObject private var link = RobotLink.shared

    enum Phase: Equatable { case pick, hotspot, sending, done(String), failed(String) }
    @State private var file: URL?
    @State private var size = 0
    @State private var phase: Phase = .pick

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !dev.version.isEmpty {
                Text("The robot is on \(dev.version).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            step(1, "Choose the firmware file",
                 file.map { "\($0.lastPathComponent), \(size / 1024) KB" } ?? "the APP .bin, not the FULL one") {
                Button(file == nil ? "Choose..." : "Change") { choose() }
            }
            step(2, "Open the robot's hotspot",
                 "Then join RAFIQ-SETUP (password: password) from the WiFi menu at the top of the screen") {
                Button("Open hotspot") {
                    dev.command("config", say: "Hotspot on")
                    phase = .hotspot
                }
                .disabled(file == nil || !link.connected)
            }
            step(3, "Send it",
                 "Takes about a minute. The robot restarts by itself when it is done") {
                Button("Upload") { Task { await upload() } }
                    .disabled(file == nil || phase == .sending)
            }
            switch phase {
            case .sending:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sending. Keep this Mac on RAFIQ-SETUP.").font(.system(size: 11))
                }
            case .done(let m):
                Label(m, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, _ note: String,
                               @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(n)").font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control().font(.system(size: 11))
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        if let bin = UTType(filenameExtension: "bin") { p.allowedContentTypes = [bin] }
        p.message = "Choose the Rafiq firmware (the APP .bin)"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url,
              let d = try? Data(contentsOf: u) else { return }
        // An app image starts with 0xE9 and fits its 1.9 MB slot. The FULL
        // image starts the same way but is far too big for an update.
        guard d.first == 0xE9 else { phase = .failed("That is not a firmware file."); return }
        guard d.count < 1_966_080 else { phase = .failed("That is the FULL image. Choose the APP .bin."); return }
        file = u; size = d.count; phase = .pick
    }

    private func upload() async {
        guard let u = file, let d = try? Data(contentsOf: u),
              let url = URL(string: "http://192.168.4.1/ota") else { return }
        phase = .sending
        let boundary = "rafiq-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"f\"; filename=\"\(u.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(d)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        do {
            let (resp, r) = try await URLSession.shared.upload(for: req, from: body)
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: resp, encoding: .utf8) ?? ""
            if code == 200 { phase = .done("Installed. The robot is restarting.") }
            else { phase = .failed(text.isEmpty ? "The robot said no (\(code))." : text) }
        } catch {
            phase = .failed("Could not reach the robot at 192.168.4.1. Is this Mac on RAFIQ-SETUP?")
        }
    }
}
