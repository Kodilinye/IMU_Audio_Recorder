import SwiftUI

struct PhoneContentView: View {
    @EnvironmentObject private var session: RecordingSessionState
    @EnvironmentObject private var connectivity: PhoneConnectivityManager

    @State private var selectedPage = 1

    var body: some View {
        TabView(selection: $selectedPage) {
            StatusPage()
                .tag(0)

            ControlPage(selectedPage: $selectedPage)
                .tag(1)

            VideoPage()
                .tag(2)

            FilesPage()
                .tag(3)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .onReceive(NotificationCenter.default.publisher(for: .startiPhoneCamera)) { note in
            let epoch = (note.userInfo?["scheduledStartEpoch"] as? TimeInterval)
                ?? (Date().timeIntervalSince1970 + 5)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"

            let rawTs = (note.userInfo?["sessionTimestamp"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            session.sessionTimestamp = (rawTs?.isEmpty == false) ? rawTs! : formatter.string(from: Date())
            session.filenameSuffix = FilenameSuffixHelper.sanitize(note.userInfo?["suffix"] as? String ?? "")
            session.scheduledStartEpoch = epoch
            session.isVideoRecording = true

            withAnimation {
                selectedPage = 2
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopiPhoneCamera)) { _ in
            session.isVideoRecording = false
            session.scheduledStartEpoch = nil
            session.sessionTimestamp = ""
            session.filenameSuffix = ""
        }
    }
}
