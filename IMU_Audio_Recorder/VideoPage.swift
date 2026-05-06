import SwiftUI

struct VideoPage: View {
    @EnvironmentObject private var session: RecordingSessionState

    var body: some View {
        ZStack(alignment: .top) {
            if let anchor = session.scheduledStartEpoch, !session.sessionTimestamp.isEmpty {
                CustomVideoRecorder(
                    isRecording: $session.isVideoRecording,
                    timestamp: session.sessionTimestamp,
                    suffix: session.filenameSuffix,
                    scheduledStartEpoch: anchor
                )
                .ignoresSafeArea()

                TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    let now = context.date.timeIntervalSince1970
                    overlayLabel(now: now, anchor: anchor)
                        .padding(.top, 56)
                        .padding(.horizontal, 16)
                }
            } else {
                ContentUnavailableView(
                    "No active session",
                    systemImage: "video.slash",
                    description: Text("Start recording from the Control tab.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func overlayLabel(now: TimeInterval, anchor: TimeInterval) -> some View {
        let delta = now - anchor
        let text: String
        let fontSize: CGFloat

        if delta < 0 {
            text = "\(max(1, Int(ceil(anchor - now))))"
            fontSize = 72
        } else if delta < 0.5 {
            text = "GO"
            fontSize = 72
        } else {
            let secs = Int(delta)
            let frac = Int((delta.truncatingRemainder(dividingBy: 1)) * 10)
            text = String(format: "%02d:%02d.%d", secs / 60, secs % 60, frac)
            fontSize = 44
        }

        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 6, x: 0, y: 2)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}
