import Foundation
import WatchConnectivity

struct WatchTrigger {
    static func remoteStartPhoneCamera(scheduledStartEpoch: TimeInterval, sessionTimestamp: String, suffix: String = "") {
        var payload: [String: Any] = [
            "action": "startCamera",
            "scheduledStartEpoch": scheduledStartEpoch,
            "sessionTimestamp": sessionTimestamp
        ]
        if !suffix.isEmpty {
            payload["suffix"] = suffix
        }

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { error in
                print("Failed to trigger phone camera: \(error.localizedDescription)")
                WCSession.default.transferUserInfo(payload)
            }
        } else {
            WCSession.default.transferUserInfo(payload)
        }
    }
}
