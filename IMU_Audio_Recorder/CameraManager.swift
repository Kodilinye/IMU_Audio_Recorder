import SwiftUI
import AVFoundation

struct CustomVideoRecorder: UIViewControllerRepresentable {
    @Binding var isRecording: Bool
    var timestamp: String

    func makeUIViewController(context: Context) -> CameraViewController {
        return CameraViewController(timestamp: timestamp)
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        if isRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {

                uiViewController.startCountdownAndRecording()
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
    private let countdownLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
        setupRecordingIndicator()
        setupCountdownLabel()
    }
    
    private func setupCountdownLabel() {
        countdownLabel.frame = view.bounds
        countdownLabel.textAlignment = .center
        countdownLabel.font = UIFont.systemFont(ofSize: 80, weight: .bold)
        countdownLabel.textColor = .white
        countdownLabel.alpha = 0
        view.addSubview(countdownLabel)
    }
    
    func startCountdownAndRecording() {
        startRecording()
        
        var count = 5
        countdownLabel.alpha = 1
        
        countdownLabel.text = "\(count)"
        
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            count -= 1
            
            if count > 0 {
                self.countdownLabel.text = "\(count)"
            } else if count == 0 {
                self.countdownLabel.text = "GO"
            } else {
                timer.invalidate()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.countdownLabel.alpha = 0
                }
            }
        }
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

    
    
    private var timestamp: String

    init(timestamp: String) {
        self.timestamp = timestamp
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
    func startRecording() {
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

        let fileName = "video_\(timestamp).mov"
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
