import SwiftUI

@main
struct IMU_Audio_RecorderApp: App {
    @StateObject private var connectivityManager = PhoneConnectivityManager()
    @StateObject private var recordingSession = RecordingSessionState()

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
                .environmentObject(connectivityManager)
                .environmentObject(recordingSession)
        }
    }
}
