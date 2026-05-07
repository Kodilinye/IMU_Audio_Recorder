import Foundation

extension Notification.Name {
    static let startiPhoneCamera = Notification.Name("startiPhoneCamera")
    static let stopiPhoneCamera = Notification.Name("stopiPhoneCamera")
    /// Posted when Documents folder gains/loses pairing-relevant files.
    static let pairingFilesChanged = Notification.Name("pairingFilesChanged")
    /// Posted after CameraManager completes/aborts file finalize for current recording.
    static let videoRecordingFinalized = Notification.Name("videoRecordingFinalized")
}
