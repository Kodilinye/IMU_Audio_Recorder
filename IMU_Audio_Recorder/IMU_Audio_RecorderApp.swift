import SwiftUI

@main
struct IMU_Audio_RecorderApp: App {
    private var connectivityManager = PhoneConnectivityManager()

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
        }
    }
}
