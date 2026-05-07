import SwiftUI
import AVFoundation

struct CustomVideoRecorder: UIViewControllerRepresentable {
    @Binding var isRecording: Bool
    var timestamp: String
    var suffix: String
    var scheduledStartEpoch: TimeInterval

    func makeUIViewController(context: Context) -> CameraViewController {
        CameraViewController(timestamp: timestamp, suffix: suffix)
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        uiViewController.updateRecordingConfig(timestamp: timestamp, suffix: suffix)
        if isRecording {
            uiViewController.armRecording(scheduledStartEpoch: scheduledStartEpoch)
        } else {
            uiViewController.disarmRecording()
        }
    }
}

final class CameraViewController: UIViewController, AVCaptureFileOutputRecordingDelegate {
    private let captureSession = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let recordingDot = UIView()
    private let recordingLabel = UILabel()

    private var scheduledWorkItem: DispatchWorkItem?
    private var lastArmedEpoch: TimeInterval?

    private var timestamp: String
    private var suffix: String

    init(timestamp: String, suffix: String) {
        self.timestamp = timestamp
        self.suffix = suffix
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateRecordingConfig(timestamp: String, suffix: String) {
        self.timestamp = timestamp
        self.suffix = suffix
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
        setupRecordingIndicator()
    }

    /// Schedule `movieOutput.startRecording` at wall-clock `scheduledStartEpoch`.
    func armRecording(scheduledStartEpoch: TimeInterval) {
        guard !movieOutput.isRecording else { return }
        if lastArmedEpoch == scheduledStartEpoch, scheduledWorkItem != nil {
            return
        }
        lastArmedEpoch = scheduledStartEpoch
        scheduledWorkItem?.cancel()

        let delay = max(0, scheduledStartEpoch - Date().timeIntervalSince1970)
        let work = DispatchWorkItem { [weak self] in
            self?.scheduledWorkItem = nil
            self?.beginMovieRecording()
        }
        scheduledWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func disarmRecording() {
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        lastArmedEpoch = nil
        stopRecording()
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
        defer { captureSession.commitConfiguration() }

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            print("--- PHONE: Unable to access front camera input ---")
            return
        }

        if captureSession.canAddInput(videoInput) { captureSession.addInput(videoInput) }

        // Add movie output as early as possible so video-only mode still records.
        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
            print("--- PHONE: Movie Output added successfully ---")
        } else {
            print("--- PHONE: Cannot add movie output ---")
        }

        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else {
            print("--- PHONE: Unable to access microphone input; continuing video-only ---")
            return setupPreviewLayerAndRun()
        }

        if captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
        } else {
            print("--- PHONE: Cannot add microphone input; continuing video-only ---")
        }

        setupPreviewLayerAndRun()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func videoFileName() -> String {
        let suf = FilenameSuffixHelper.sanitize(suffix)
        if suf.isEmpty {
            return "video_\(timestamp).mov"
        }
        return "video_\(timestamp)_\(suf).mov"
    }

    private func beginMovieRecording() {
        guard captureSession.isRunning else {
            print("--- PHONE: Session not running yet, retrying... ---")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.beginMovieRecording() }
            return
        }

        guard captureSession.outputs.contains(where: { $0 === movieOutput }) else {
            print("--- PHONE: Movie output unavailable; cannot start recording ---")
            return
        }

        guard !movieOutput.isRecording else { return }

        if let connection = movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(videoFileName())
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

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

        DispatchQueue.global(qos: .background).async {
            do {
                if fileManager.fileExists(atPath: outputFileURL.path) {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.moveItem(at: outputFileURL, to: destinationURL)
                    print("--- PHONE: SUCCESS! Video at: \(destinationURL.path) ---")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .pairingFilesChanged, object: nil)
                    }
                }
            } catch {
                print("--- PHONE: Move Failed: \(error.localizedDescription) ---")
            }
        }
    }

    private func setupPreviewLayerAndRun() {
        if previewLayer == nil {
            let layer = AVCaptureVideoPreviewLayer(session: captureSession)
            layer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer
        } else {
            previewLayer?.session = captureSession
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            print("--- PHONE: Capture Session is now running ---")
        }
    }
}
