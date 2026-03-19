import SwiftUI

// Defining the names clearly so the compiler never loses them
extension Notification.Name {
    static let startiPhoneCamera = Notification.Name("startiPhoneCamera")
    static let stopiPhoneCamera = Notification.Name("stopiPhoneCamera")
}

struct PhoneContentView: View {
    
    @State private var showCamera = false
    @State private var isRecordingVideo = false
    
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
        
        // --- START LISTENER ---
        .onReceive(NotificationCenter.default.publisher(for: .startiPhoneCamera)) { _ in
            self.showCamera = true
            self.isRecordingVideo = true
        }
        
        // --- STOP LISTENER ---
        .onReceive(NotificationCenter.default.publisher(for: .stopiPhoneCamera)) { _ in
            print("--- PHONE: Stop Signal Received ---")
            self.isRecordingVideo = false // Stops the recording
            
            // INCREASE THIS DELAY to 4 seconds just for testing
            // This ensures the file move logic in CameraManager has plenty of time
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                self.showCamera = false
                print("--- PHONE: Dismissing Camera View ---")
            }
        }
        
        // --- CAMERA VIEW ---
        .fullScreenCover(isPresented: $showCamera) {
            // This now uses the CustomVideoRecorder from your CameraManager.swift
            CustomVideoRecorder(isRecording: $isRecordingVideo)
                .ignoresSafeArea()
        }
    }
}
