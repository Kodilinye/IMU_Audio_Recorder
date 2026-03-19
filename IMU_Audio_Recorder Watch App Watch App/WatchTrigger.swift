import WatchConnectivity

struct WatchTrigger {
    static func remoteStartPhoneCamera() {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["action": "startCamera"], replyHandler: nil) { error in
                print("Failed to trigger phone camera: \(error.localizedDescription)")
            }
        }
    }
}
