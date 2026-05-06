import SwiftUI

struct PhoneContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("IMU & Audio Recorder")
                .font(.largeTitle)
            Text("Companion App")
                .font(.title2)
                .foregroundColor(.gray)
            Divider()
            
            Text("This app receives data from the watch.\nCheck the debug console in Xcode for transfer status.")
                .multilineTextAlignment(.center)
                .padding()
            
            Button("Print Documents Path") {
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    print("--- PHONE: Documents Path: \(docs.path) ---")
                } else {
                    print("--- PHONE: Documents directory not found ---")
                }
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            
            Button("List Received Files") {
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    do {
                        let files = try FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
                        print("--- PHONE: Received Files ---")
                        files.forEach { print($0.lastPathComponent) }
                    } catch {
                        print("--- PHONE: File list error: \(error) ---")
                    }
                }
            }
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .padding()
    }
}
