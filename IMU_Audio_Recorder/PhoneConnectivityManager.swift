import Combine
import Foundation
import WatchConnectivity

final class PhoneConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {
    var session: WCSession?

    @Published var activationState: WCSessionActivationState = .notActivated
    @Published var isReachable: Bool = false
    @Published var isPaired: Bool = false
    @Published var isWatchAppInstalled: Bool = false
    @Published var lastErrorDescription: String?

    override init() {
        super.init()
        print("\(Date()): --- PHONE: PhoneConnectivityManager initialized ---")

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
            refreshDerivedSessionState()
            print("\(Date()): --- PHONE: WCSession activated ---")
        } else {
            print("\(Date()): --- PHONE: WCSession not supported ---")
        }
    }

    private func refreshDerivedSessionState() {
        guard let s = session else { return }
        DispatchQueue.main.async {
            self.activationState = s.activationState
            self.isReachable = s.isReachable
            self.isPaired = s.isPaired
            self.isWatchAppInstalled = s.isWatchAppInstalled
        }
    }

    func sendRecordingStart(suffix: String, scheduledStartEpoch: TimeInterval, sessionTimestamp: String) {
        let payload: [String: Any] = [
            "action": "startRecording",
            "suffix": suffix,
            "scheduledStartEpoch": scheduledStartEpoch,
            "sessionTimestamp": sessionTimestamp
        ]

        guard WCSession.isSupported() else { return }
        let wc = WCSession.default
        if wc.isReachable {
            wc.sendMessage(payload, replyHandler: nil) { error in
                print("sendRecordingStart failed, using transferUserInfo: \(error.localizedDescription)")
                wc.transferUserInfo(payload)
            }
        } else {
            wc.transferUserInfo(payload)
        }
    }

    func sendRecordingStop() {
        let payload: [String: Any] = ["action": "stopRecording"]

        guard WCSession.isSupported() else { return }
        let wc = WCSession.default
        if wc.isReachable {
            wc.sendMessage(payload, replyHandler: nil) { error in
                print("sendRecordingStop failed, using transferUserInfo: \(error.localizedDescription)")
                wc.transferUserInfo(payload)
            }
        } else {
            wc.transferUserInfo(payload)
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        print("\(Date()): --- PHONE: Received file at \(file.fileURL.path) ---")

        let fileName = file.fileURL.lastPathComponent
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("\(Date()): --- PHONE: CRITICAL ERROR - No documents directory ---")
            return
        }

        let destinationURL = documentsURL.appendingPathComponent(fileName)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
                print("\(Date()): --- PHONE: Replaced existing file: \(fileName) ---")
            }

            try FileManager.default.moveItem(at: file.fileURL, to: destinationURL)
            print("\(Date()): --- PHONE: SUCCESS! Moved file to \(destinationURL.path) ---")

            if WCSession.default.isReachable {
                let confirmationMessage = ["fileSent": fileName]
                WCSession.default.sendMessage(confirmationMessage, replyHandler: nil) { error in
                    print("Error sending confirmation for \(fileName): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .pairingFilesChanged, object: nil)
            }
        } catch {
            print("\(Date()): --- PHONE: CRITICAL ERROR - File move failed: \(error.localizedDescription) ---")
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.lastErrorDescription = error.localizedDescription
                print("\(Date()): --- PHONE: Activation failed: \(error.localizedDescription) ---")
            } else {
                self.lastErrorDescription = nil
            }

            self.activationState = activationState
            self.refreshDerivedSessionState()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        print("\(Date()): --- PHONE: Reachability changed: \(session.isReachable ? "Reachable" : "Unreachable") ---")
        refreshDerivedSessionState()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("\(Date()): --- PHONE: Session became inactive ---")
        refreshDerivedSessionState()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("\(Date()): --- PHONE: Session deactivated - Reactivating ---")
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncomingMessage(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleIncomingMessage(userInfo)
    }

    private func handleIncomingMessage(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }

        let epoch = message["scheduledStartEpoch"] as? TimeInterval
        let sessionTs = (message["sessionTimestamp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = FilenameSuffixHelper.sanitize(message["suffix"] as? String ?? "")

        DispatchQueue.main.async {
            if action == "startCamera" {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let resolvedEpoch = epoch ?? (Date().timeIntervalSince1970 + 5)
                let resolvedTs = (sessionTs?.isEmpty == false) ? sessionTs! : formatter.string(from: Date())
                var info: [AnyHashable: Any] = [
                    "scheduledStartEpoch": resolvedEpoch,
                    "sessionTimestamp": resolvedTs
                ]
                if !suffix.isEmpty {
                    info["suffix"] = suffix
                }
                NotificationCenter.default.post(name: .startiPhoneCamera, object: nil, userInfo: info)
            } else if action == "stopCamera" {
                NotificationCenter.default.post(name: .stopiPhoneCamera, object: nil)
            }
        }
    }
}
