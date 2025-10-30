import SwiftUI

struct WatchContentView: View {
    @StateObject private var dataRecorder = DataRecorder()

    var body: some View {
        VStack(spacing: 1) {
            Text("IMU & Audio Recorder")
                .font(.subheadline)

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
        if dataRecorder.isRecording {
            return String(format: "%.1f s", dataRecorder.elapsedTime)
        } else {
            return "\(dataRecorder.imuStatusText)\n\(dataRecorder.audioStatusText)"
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        WatchContentView()
    }
}
