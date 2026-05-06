import AVFoundation
import SwiftUI
import WatchConnectivity

struct StatusPage: View {
    @EnvironmentObject private var connectivity: PhoneConnectivityManager

    @State private var micAuthorized = false
    @State private var cameraStatusText = "Unknown"

    private var documentsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "(none)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Status")
                    .font(.title2.bold())

                Group {
                    labeledRow("WCSession", connectivity.activationStateDescription)
                    labeledRow("Reachable", connectivity.isReachable ? "Yes" : "No")
                    labeledRow("Paired", connectivity.isPaired ? "Yes" : "No")
                    labeledRow("Watch app installed", connectivity.isWatchAppInstalled ? "Yes" : "No")
                    if let err = connectivity.lastErrorDescription {
                        labeledRow("Last WC error", err)
                    }
                }

                Divider()

                labeledRow("Microphone", micAuthorized ? "Authorized" : "Not authorized")
                labeledRow("Camera", cameraStatusText)

                Divider()

                Text("Documents")
                    .font(.headline)
                Text(documentsPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                Button("Copy Documents path") {
                    UIPasteboard.general.string = documentsPath
                }
                .buttonStyle(.bordered)

                Button("List received files (console)") {
                    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        do {
                            let files = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
                            print("--- PHONE: Received Files ---")
                            files.forEach { print($0.lastPathComponent) }
                        } catch {
                            print("--- PHONE: File list error: \(error) ---")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .onAppear {
            refreshPermissions()
        }
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body)
        }
    }

    private func refreshPermissions() {
        if #available(iOS 17.0, *) {
            micAuthorized = AVAudioApplication.shared.recordPermission == .granted
        } else {
            micAuthorized = AVAudioSession.sharedInstance().recordPermission == .granted
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraStatusText = "Authorized"
        case .denied: cameraStatusText = "Denied"
        case .restricted: cameraStatusText = "Restricted"
        case .notDetermined: cameraStatusText = "Not determined"
        @unknown default: cameraStatusText = "Unknown"
        }
    }
}

private extension PhoneConnectivityManager {
    var activationStateDescription: String {
        switch activationState {
        case .activated: return "Activated"
        case .inactive: return "Inactive"
        case .notActivated: return "Not activated"
        @unknown default: return "Unknown"
        }
    }
}
