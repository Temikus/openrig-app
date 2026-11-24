import AVFoundation
import RigClient
import SwiftUI
import VisionKit

/// First launch: the explainer, then the scanner (visual decision 3, B).
struct PairingFlow: View {
    @State private var path = PairingStep.launchPath

    var body: some View {
        NavigationStack(path: $path) {
            ExplainerView()
                .navigationDestination(for: PairingStep.self) { _ in ScannerView() }
        }
    }
}

struct ExplainerView: View {
    @Environment(RemoteSession.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Pair with your Mac").font(.largeTitle.bold())
                Text("This phone shows the questions your seats ask you, and lets you answer them.")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    step(1, "On the Mac, open OpenRig and go to Settings › Phone.")
                    Divider().padding(.leading, 44)
                    step(2, "Choose Pair a Phone… to show a code.")
                    Divider().padding(.leading, 44)
                    step(3, "Scan the code with this phone.")
                }
                .background(.background.secondary, in: .rect(cornerRadius: 20))
                Text(
                    "The phone reaches your Mac over this Wi-Fi. iOS will ask whether OpenRig may find devices on your local network: allow it, or the phone can't reach the Mac."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                PairingErrorText()
                NavigationLink(value: PairingStep.scanner) {
                    Text("Scan the code").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                PasteLinkButton()
            }
            .padding(20)
            // Opaque, so scrolled text doesn't show through the buttons at large text sizes.
            .background(.bar)
        }
    }

    func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("\(number)").foregroundStyle(.secondary).monospacedDigit().frame(width: 12)
            Text(text)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

struct ScannerView: View {
    @Environment(RemoteSession.self) private var model
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        // Scrolls, so the paste explanation isn't cut at large text sizes. Paste stays pinned below.
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text(heading).font(.title2.bold())
                    Text(guidance).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                viewfinder
                PairingErrorText()
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            PasteLinkButton()
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(.bar)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if camera == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var heading: String {
        switch camera {
        case .denied, .restricted: "Camera access is off"
        default: canScan || camera == .notDetermined ? "Scan the code on your Mac" : "This phone can't scan"
        }
    }

    var guidance: String {
        switch camera {
        case .denied, .restricted:
            "To scan the code, allow the camera for OpenRig in Settings. Or copy the link under the code on your Mac and paste it here."
        default:
            canScan || camera == .notDetermined
                ? "In OpenRig on the Mac, choose Pair a Phone… in Settings › Phone."
                : "Copy the link under the code on your Mac and paste it here."
        }
    }

    @ViewBuilder var viewfinder: some View {
        if camera == .authorized, canScan {
            QRScanner { model.pair(link: $0) }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 24))
                .accessibilityLabel("Camera viewfinder")
        } else if camera == .denied || camera == .restricted {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// Paste without the system's paste prompt: the person's tap on PasteButton is the permission.
struct PasteLinkButton: View {
    @Environment(RemoteSession.self) private var model

    var body: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let link = strings.first else { return }
            Task { @MainActor in model.pair(link: link) }
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
    }
}

struct PairingErrorText: View {
    @Environment(RemoteSession.self) private var model

    var body: some View {
        if let error = model.pairingError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(Color.statusBad)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// VisionKit's live scanner, reading QR codes only. Each new code is passed on once.
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
        ) {
            for case .barcode(let code) in addedItems {
                if let payload = code.payloadStringValue { onCode(payload) }
            }
        }
    }
}
