import SwiftUI
import AVFoundation

struct CustomVideoRecorder: UIViewControllerRepresentable {
    @Binding var isRecording: Bool

    func makeUIViewController(context: Context) -> CameraViewController {
        return CameraViewController()
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        if isRecording {
            // We give it a tiny buffer to make sure the session is actually hot
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                uiViewController.startRecording()
            }
        } else {
            uiViewController.stopRecording()
        }
    }
}

class CameraViewController: UIViewController, AVCaptureFileOutputRecordingDelegate {
    private let captureSession = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let recordingDot = UIView()
    private let recordingLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
        setupRecordingIndicator()
    }

    private func setupRecordingIndicator() {
        recordingDot.frame = CGRect(x: 20, y: 60, width: 20, height: 20)
        recordingDot.backgroundColor = .red
        recordingDot.layer.cornerRadius = 10
        recordingDot.alpha = 0
        view.addSubview(recordingDot)
        
        recordingLabel.text = "RECORDING"
        recordingLabel.textColor = .red
        recordingLabel.font = .systemFont(ofSize: 18, weight: .bold)
        recordingLabel.frame = CGRect(x: 50, y: 55, width: 150, height: 30)
        recordingLabel.alpha = 0
        view.addSubview(recordingLabel)
    }
    
    private func setupSession() {
        captureSession.beginConfiguration()
        
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else { return }
        
        if captureSession.canAddInput(videoInput) { captureSession.addInput(videoInput) }
        
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else { return }
        
        if captureSession.canAddInput(audioInput) { captureSession.addInput(audioInput) }
        
        // FIX 1: Added only ONCE
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            print("--- PHONE: Movie Output added successfully ---")
        }
        
        captureSession.commitConfiguration()
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            print("--- PHONE: Capture Session is now running ---")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    func startRecording() {
        // FIX 2: If the session isn't running yet, wait 0.5s and try again
        guard captureSession.isRunning else {
            print("--- PHONE: Session not running yet, retrying... ---")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startRecording() }
            return
        }
        
        guard !movieOutput.isRecording else { return }
        
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        let fileName = "iPhoneVideo_\(Int(Date().timeIntervalSince1970)).mov"
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        
        print("--- PHONE: Recording starting to \(outputURL.lastPathComponent) ---")
        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        
        UIView.animate(withDuration: 0.3) {
            self.recordingDot.alpha = 1
            self.recordingLabel.alpha = 1
        }
    }

    func stopRecording() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            print("--- PHONE: Stop command sent to MovieOutput ---")
            UIView.animate(withDuration: 0.3) {
                self.recordingDot.alpha = 0
                self.recordingLabel.alpha = 0
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        print("--- PHONE: Delegate fired. File exists: \(FileManager.default.fileExists(atPath: outputFileURL.path)) ---")
        
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let destinationURL = documentsURL.appendingPathComponent(outputFileURL.lastPathComponent)

        // Ensure we move the file on a background thread so we don't freeze the UI
        DispatchQueue.global(qos: .background).async {
            do {
                if fileManager.fileExists(atPath: outputFileURL.path) {
                    try fileManager.moveItem(at: outputFileURL, to: destinationURL)
                    print("--- PHONE: SUCCESS! Video at: \(destinationURL.path) ---")
                }
            } catch {
                print("--- PHONE: Move Failed: \(error.localizedDescription) ---")
            }
        }
    }
}
