import SwiftUI

struct WatchContentView: View {
    @StateObject private var dataRecorder = DataRecorder()

    var body: some View {
        VStack(spacing: 1) {
            Text("IMU & Audio Recorder")
                .font(.subheadline)

            if dataRecorder.startedFromPhone {
                Text("Phone-driven")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
            }

            Text(statusText)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(height: 40)
                
            if dataRecorder.imuStatusText.contains("_G_") {
                Text("Gyroscope Unavailable")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }

            if dataRecorder.imuStatusText.contains("_M_") {
                Text("Magnetometer Unavailable")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }

            Button(action: {
                dataRecorder.toggleRecording()
            }) {
                Text(dataRecorder.isRecording ? "STOP" : "START")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 160, height: 50)
            }
            .background(dataRecorder.isRecording ? Color.red : Color.green)
            .cornerRadius(20)
            .shadow(radius: 5)

            Button(action: {
                dataRecorder.sendFilesToPhone()
            }) {
                Text("Send Data to Phone")
                    .font(.caption)
            }
            .disabled(dataRecorder.isRecording)
            .padding(.top, 2)
        }
        .padding()
    }
    
    private var statusText: String {
        // Recording starts immediately on tap (sensors begin sampling right away), but the
        // `scheduledStartEpoch` is still the agreed clock-anchor between watch and iPhone
        // for post-hoc alignment. Show the countdown until that anchor passes, even while
        // we're already capturing IMU/audio in the background.
        if let anchor = dataRecorder.scheduledStartEpoch {
            let remaining = anchor - Date().timeIntervalSince1970
            if remaining > 0 {
                return String(format: "Starting in %.0f...", ceil(remaining))
            }
        }

        if dataRecorder.isRecording {
            return String(format: "%.1f s", dataRecorder.elapsedTime)
        }

        return "\(dataRecorder.imuStatusText)\n\(dataRecorder.audioStatusText)"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        WatchContentView()
    }
}
