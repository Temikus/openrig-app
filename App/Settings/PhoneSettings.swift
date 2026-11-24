import AppKit
import CoreImage.CIFilterBuiltins
import RigClient
import RigModel
import SwiftUI

/// Settings › Phone (Paper board "Mac app · where a phone is paired", A): the pairing code and the paired phones.
struct PhoneSettings: View {
    @Environment(AppStore.self) private var store
    @State private var phones = PhoneStore()

    private var daemon: URL { store.endpoint.baseURL }
    private var daemonHere: Bool { PairingCode.Reach.Kind.loopback.accepts(daemon.host() ?? "") }

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
                if phones.phones.list.isEmpty {
                    Text("No phones paired.").foregroundStyle(.secondary)
                }
                ForEach(phones.phones.list) { phone in row(phone) }
            } header: {
                Text("Paired phones")
            } footer: {
                Text("Unpair cuts the phone off at once. It can pair again with a new code.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsForm()
        // The code carries a live token: it closes when the person leaves the tab.
        .onDisappear { phones.hideCode() }
    }

    /// Until the Mac relays for phones on the Wi-Fi, a code works only in the iOS simulator on this Mac.
    private var status: some View {
        LabeledContent {
            if case .showing = phones.code {
                Button("Hide Code") { phones.hideCode() }
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
                .foregroundStyle(Color.attention)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(Color.attention).imageScale(.small)
            }
        }
    }

    private func row(_ phone: PairedPhone) -> some View {
        LabeledContent {
            Button("Unpair") { Task { await phones.unpair(phone, daemon: daemon, bearer: store.token) } }
                .disabled(phones.unpairing.contains(phone.id))
                .accessibilityLabel("Unpair \(phone.name), paired \(paired(phone))")
        } label: {
            Text(phone.name)
            if let error = phones.unpairErrors[phone.id] {
                Text(error).foregroundStyle(Color.attention)
            } else {
                Text("Paired \(paired(phone)) · answers as \(phone.actor)")
            }
        }
    }

    private func paired(_ phone: PairedPhone) -> String {
        phone.paired.formatted(date: .abbreviated, time: .shortened)
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
                    "Anyone with this code can answer as you until you unpair it. It closes when you leave this tab."
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
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.url.absoluteString, forType: .string)
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
