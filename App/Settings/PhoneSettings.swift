import AppKit
import CoreImage.CIFilterBuiltins
import RigClient
import RigModel
import SwiftUI

/// Settings › Phone (Paper board "Mac app · where a phone is paired", A): the pairing code and the paired phones.
struct PhoneSettings: View {
    @Environment(AppStore.self) private var store
    #if DEBUG
        @State private var phones = PhoneStore.launch()
    #else
        @State private var phones = PhoneStore()
    #endif

    @State private var confirming: PairedPhone?

    private var daemon: URL { store.endpoint.baseURL }
    private var daemonHere: Bool { PairingCode.Reach.Kind.loopback.accepts(daemon.host() ?? "") }
    /// This daemon's phones first, then any other daemon's. Those can't be revoked from here, but stay in sight: this
    /// list is the only place that revokes them.
    private var list: [PairedPhone] {
        let here = phones.phones.list(for: daemon)
        return here + phones.phones.list.filter { phone in !here.contains { $0.id == phone.id } }
    }

    var body: some View {
        Form {
            Section("Pair a phone") {
                status
                switch phones.code {
                case .showing(let code): CodePanel(code: code)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(Color.attention)
                case .hidden, .issuing: EmptyView()
                }
            }
            Section("Phones on the Wi-Fi") {
                Toggle(
                    isOn: Binding {
                        store.relay.enabled
                    } set: {
                        store.relay.enabled = $0
                        Task { await store.relay.refresh(daemon: daemon) }
                    }
                ) {
                    Text("Let paired phones connect")
                    Text(relayCaption)
                }
            }
            Section {
                if list.isEmpty {
                    Text("No phones paired.").foregroundStyle(.secondary)
                }
                ForEach(list) { phone in row(phone) }
            } header: {
                Text("Paired phones")
            } footer: {
                Text("Unpair cuts the phone off at once. It can pair again with a new code.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsForm()
        // The code carries a live token: it hides when the person leaves the tab.
        .onDisappear { phones.hideCode() }
        // The relay listens only while a phone on this daemon is paired, so it follows the list.
        .task { await store.relay.refresh(daemon: daemon) }
        .onChange(of: phones.phones) { Task { await store.relay.refresh(daemon: daemon) } }
        .confirmationDialog(
            "Unpair this phone?",
            isPresented: Binding {
                confirming != nil
            } set: {
                if !$0 { confirming = nil }
            },
            presenting: confirming
        ) { phone in
            Button("Unpair", role: .destructive) {
                Task { await phones.unpair(phone, daemon: daemon, bearer: store.token) }
            }
        } message: { _ in
            Text("It stops answering at once.")
        }
    }

    /// Whether a phone can reach this Mac: the relay on the Wi-Fi, or why not.
    private var status: some View {
        LabeledContent {
            if case .showing = phones.code {
                HStack {
                    Button("Cancel Code") { Task { await phones.cancelCode(daemon: daemon, bearer: store.token) } }
                        .help("Revokes this code. Use it if no phone has scanned it.")
                    Button("Hide Code") { phones.hideCode() }
                        .help("Hides the code. It still works until you unpair it.")
                }
            } else {
                Button("Pair a Phone…") {
                    Task { await phones.pair(daemon: daemon, bearer: store.token, actor: store.me, relay: store.relay) }
                }
                .disabled(!daemonHere || !store.relay.enabled || phones.code == .issuing)
                .help(store.relay.enabled ? "Shows a code to scan." : PairingRefusal.relayOff.message)
            }
        } label: {
            Label {
                Text(reachable ? "Phones on this Wi-Fi can reach this Mac" : "Phones can't reach this Mac")
                Text(reachCaption).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(dot).imageScale(.small)
            }
        }
    }

    /// The same check a code passes before it is shown: green means a phone could use one.
    private var reachable: Bool { store.relay.usable }

    /// Green when usable, attention when something is wrong, grey when simply off or nothing is paired yet.
    private var dot: Color {
        if reachable { return .green }
        if !daemonHere { return .attention }
        switch store.relay.state {
        case .failed: return .attention
        case .listening(let host, _) where host != "127.0.0.1": return .attention  // listening, but no address
        default: return .secondary
        }
    }

    private var reachCaption: String {
        guard daemonHere else { return PhoneStore.elsewhere(daemon.host() ?? daemon.absoluteString) }
        switch store.relay.state {
        case .listening(let host, _) where host == "127.0.0.1":
            return "Held to this Mac for testing (OPENRIG_RELAY_LOOPBACK): only the simulator can connect."
        case .listening where !reachable: return PairingRefusal.noWiFiAddress.message
        case .listening: return "Listening on \(store.relay.address ?? "this Mac")."
        case .off where !store.relay.enabled: return "Turn on “Let paired phones connect” below."
        case .off: return "Pair a phone, and this Mac listens for it on the Wi-Fi."
        case .failed(let message): return message
        }
    }

    private let relayCaption =
        "This Mac listens on the Wi-Fi only while a phone is paired. macOS may ask whether OpenRig can accept "
        + "incoming connections. Allow it, or phones can't connect."

    /// Why this phone can't be unpaired from here (another daemon's), or nil.
    private func elsewhere(_ phone: PairedPhone) -> String? {
        guard case .otherDaemon = phones.phones.refusesRevoke(phone, at: daemon) else { return nil }
        return phones.phones.refusesRevoke(phone, at: daemon)?.message
    }

    private func row(_ phone: PairedPhone) -> some View {
        LabeledContent {
            Button("Unpair") { confirming = phone }
                .disabled(phones.unpairing.contains(phone.id) || elsewhere(phone) != nil)
                .accessibilityLabel("Unpair \(phone.title)")
        } label: {
            Text(phone.title)
            if let error = phones.unpairErrors[phone.id] {
                Text(error).foregroundStyle(Color.attention)
            } else if let elsewhere = elsewhere(phone) {
                Text(elsewhere).foregroundStyle(.secondary)
            } else {
                Text("Answers as \(phone.actor)")
            }
        }
    }
}

/// The QR code and its link, shown after Pair a Phone….
private struct CodePanel: View {
    let code: PairingCode

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let image = Self.qr(code.url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 120, height: 120)
                    .padding(6)
                    .background(.white, in: .rect(cornerRadius: 6))
                    .accessibilityLabel("Pairing code")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Scan this with OpenRig on your iPhone")
                Text(
                    "Anyone with this code can answer as you. Leaving this tab hides the code. It still works until "
                        + "you unpair it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(code.url.absoluteString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 4))
                        .accessibilityLabel("Pairing link")
                    Button("Copy Link") {
                        // Concealed, so clipboard managers don't keep the token; Universal Clipboard still carries it.
                        let pasteboard = NSPasteboard.general
                        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
                        pasteboard.declareTypes([.string, concealed], owner: nil)
                        pasteboard.setString(code.url.absoluteString, forType: .string)
                        pasteboard.setString("", forType: concealed)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Black on white at whole-pixel scale, so a phone camera reads it.
    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
