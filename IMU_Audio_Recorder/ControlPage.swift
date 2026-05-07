import SwiftUI

struct ControlPage: View {
    @Binding var selectedPage: Int
    @EnvironmentObject private var session: RecordingSessionState
    @EnvironmentObject private var connectivity: PhoneConnectivityManager

    @AppStorage("filenameSuffix") private var storedSuffix: String = ""

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Record control")
                .font(.title2.bold())

            Text("Filenames use date/time plus optional suffix:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Suffix (e.g. user1_h2)", text: $storedSuffix)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            Button(session.isVideoRecording ? "STOP" : "START") {
                if session.isVideoRecording {
                    session.isVideoRecording = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        session.scheduledStartEpoch = nil
                        session.sessionTimestamp = ""
                        session.filenameSuffix = ""
                    }
                    connectivity.sendRecordingStop()
                } else {
                    let suf = FilenameSuffixHelper.sanitize(storedSuffix)
                    storedSuffix = suf
                    let ts = timestampString()
                    let epoch = Date().timeIntervalSince1970 + 5.0
                    session.filenameSuffix = suf
                    session.sessionTimestamp = ts
                    session.scheduledStartEpoch = epoch
                    session.isVideoRecording = true
                    connectivity.sendRecordingStart(suffix: suf, scheduledStartEpoch: epoch, sessionTimestamp: ts)
                    withAnimation {
                        selectedPage = 2
                    }
                }
            }
            .font(.title2.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(session.isVideoRecording ? Color.red : Color.green)
            .cornerRadius(14)

            Spacer()
        }
        .padding()
        .onAppear {
            session.filenameSuffix = FilenameSuffixHelper.sanitize(storedSuffix)
        }
    }
}
