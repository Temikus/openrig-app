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
    /// Only this daemon's: another daemon's credentials can't be revoked from here.
    private var list: [PairedPhone] { phones.phones.list(for: daemon) }

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

    /// Until the Mac relays for phones on the Wi-Fi, a code works only in the iOS simulator on this Mac.
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
                    Task { await phones.pair(daemon: daemon, bearer: store.token, actor: store.me) }
                }
                .disabled(!daemonHere || phones.code == .issuing)
            }
        } label: {
            Label {
                Text("Phones can't reach this Mac yet")
                Text(
                    daemonHere
                        ? "The Mac doesn't listen for phones on the Wi-Fi yet. Until it does, a code works only in "
                            + "the iOS simulator on this Mac."
                        : PhoneStore.elsewhere(daemon.host() ?? daemon.absoluteString)
                )
                .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(Color.attention).imageScale(.small)
            }
        }
    }

    private func row(_ phone: PairedPhone) -> some View {
        LabeledContent {
            Button("Unpair") { confirming = phone }
                .disabled(phones.unpairing.contains(phone.id))
                .accessibilityLabel("Unpair \(phone.title)")
        } label: {
            Text(phone.title)
            if let error = phones.unpairErrors[phone.id] {
                Text(error).foregroundStyle(Color.attention)
            } else {
                Text("answers as \(phone.actor)")
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
