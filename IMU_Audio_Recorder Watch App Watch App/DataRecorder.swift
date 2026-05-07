import AVFoundation
import CoreMotion
import Foundation
import HealthKit
import WatchConnectivity

final class DataRecorder: NSObject, ObservableObject, WCSessionDelegate {

    private let motionManager = CMMotionManager()
    private let audioEngine = AVAudioEngine()
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    private let motionQueue = OperationQueue()

    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var imuStatusText: String = "Sensors: "
    @Published var audioStatusText: String = "Audio: "
    @Published var scheduledStartEpoch: TimeInterval?
    @Published var startedFromPhone = false

    private var timer: Timer?
    private var scheduledStartWorkItem: DispatchWorkItem?
    private var motionFileHandle: FileHandle?
    private var audioFileHandle: FileHandle?
    private var audioFileURL: URL?

    private var currentSessionTimestamp = ""
    private var currentFilenameSuffix = ""

    private let audioOutputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!

    override init() {
        super.init()
        motionQueue.qualityOfService = .userInitiated

        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
        }

        computeDeviceCapabilities()
    }

    private func computeDeviceCapabilities() {
        var status = "Sensors: "
        status += motionManager.isAccelerometerAvailable ? "A" : "_"
        status += motionManager.isGyroAvailable ? "G" : "_"
        status += motionManager.isMagnetometerAvailable ? "M" : "_"
        status += motionManager.isDeviceMotionAvailable ? "D" : "_"
        imuStatusText = status

        let sampleRate = Int(audioOutputFormat.sampleRate / 1000)
        audioStatusText = "Audio: \(sampleRate)kHz 16-bit"
    }

    private func deleteExistingFiles() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                if fileURL.pathExtension == "csv" || fileURL.pathExtension == "wav" {
                    try FileManager.default.removeItem(at: fileURL)
                    print("Deleted old file: \(fileURL.lastPathComponent)")
                }
            }
        } catch {
            print("Error deleting files: \(error.localizedDescription)")
        }
    }

    func toggleRecording() {
        if isRecording || scheduledStartWorkItem != nil {
            stopRecording(sendStopCamera: true)
            return
        }

        computeDeviceCapabilities()
        startedFromPhone = false
        currentFilenameSuffix = ""
        currentSessionTimestamp = getTimestampString()
        let epoch = Date().timeIntervalSince1970 + 5.0
        scheduledStartEpoch = epoch

        WatchTrigger.remoteStartPhoneCamera(
            scheduledStartEpoch: epoch,
            sessionTimestamp: currentSessionTimestamp,
            suffix: currentFilenameSuffix
        )

        requestPermissionsAndStart(scheduledStartEpoch: epoch)
    }
    
    func sendFilesToPhone() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            // Get only the files in the main documents directory, skipping any subdirectories like "sent_files".
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: nil,
                options: .skipsSubdirectoryDescendants
            )
            
            // Filter for only the data files we want to send.
            let filesToSend = fileURLs.filter { $0.pathExtension == "csv" || $0.pathExtension == "wav" }
            
            if filesToSend.isEmpty {
                print("No new files to send.")
                return
            }
            
            print("Found \(filesToSend.count) new file(s) to queue for transfer.")
            for fileURL in filesToSend {
                print("Queueing file for transfer: \(fileURL.lastPathComponent)")
                WCSession.default.transferFile(fileURL, metadata: nil)
            }
        } catch {
            print("Directory error while sending files: \(error.localizedDescription)")
        }
    }
    
    private func requestPermissionsAndStart(scheduledStartEpoch: TimeInterval) {
        let workoutTypes: Set<HKSampleType> = [HKObjectType.workoutType()]

        healthStore.requestAuthorization(toShare: workoutTypes, read: workoutTypes) { [weak self] success, error in
            guard let self = self else { return }
            if let error = error { print("HealthKit error: \(error.localizedDescription)") }
            guard success else { return }

            self.requestMicrophonePermission { [weak self] granted in
                guard let self = self else { return }
                guard granted else {
                    print("Microphone permission denied")
                    return
                }
                DispatchQueue.main.async {
                    self.scheduleStart(at: scheduledStartEpoch)
                }
            }
        }
    }

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        if #available(watchOS 10.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }

    private func scheduleStart(at epoch: TimeInterval) {
        scheduledStartWorkItem?.cancel()

        let delay = max(0, epoch - Date().timeIntervalSince1970)
        let work = DispatchWorkItem { [weak self] in
            self?.scheduledStartWorkItem = nil
            self?.startWorkoutSession(anchorEpoch: epoch)
        }
        scheduledStartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startWorkoutSession(anchorEpoch: TimeInterval) {
        guard !isRecording else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            workoutSession?.startActivity(with: nil)
            startDataRecording(timestamp: currentSessionTimestamp, suffix: currentFilenameSuffix)
            isRecording = true
            startTimer(anchorEpoch: anchorEpoch)
        } catch {
            print("Workout session error: \(error.localizedDescription)")
            stopRecording(sendStopCamera: true)
        }
    }

    private func startDataRecording(timestamp: String, suffix: String) {
        startMotionUpdates(timestamp: timestamp, suffix: suffix)
        startAudioRecording(timestamp: timestamp, suffix: suffix)
    }

    private func startMotionUpdates(timestamp: String, suffix: String) {
        guard motionManager.isDeviceMotionAvailable else {
            print("Device Motion service is not available.")
            return
        }

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let motionFileURL = documentsURL.appendingPathComponent(makeMotionFileName(timestamp: timestamp, suffix: suffix))

        let header = [
            "timestamp",
            "accel_x(G)", "accel_y(G)", "accel_z(G)",
            "gyro_x(rad/s)", "gyro_y(rad/s)", "gyro_z(rad/s)",
            "mag_x(uT)", "mag_y(uT)", "mag_z(uT)",
            "attitude_roll(rad)", "attitude_pitch(rad)", "attitude_yaw(rad)",
            "gravity_x(G)", "gravity_y(G)", "gravity_z(G)"
        ].joined(separator: ",") + "\n"

        do {
            try header.write(to: motionFileURL, atomically: true, encoding: .utf8)
            motionFileHandle = try FileHandle(forWritingTo: motionFileURL)
            motionFileHandle?.seekToEndOfFile()
        } catch {
            print("Failed to create motion file: \(error.localizedDescription)")
            return
        }

        // Use the start method that includes the magnetometer
        motionManager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: motionQueue) { [weak self] (deviceMotion, _) in
            guard let self = self, let motion = deviceMotion else { return }
            
            let timestamp = self.getCurrentTimestamp()
            let accel = motion.userAcceleration
            let gyro = motion.rotationRate
            let mag = motion.magneticField.field // This will now have valid data
            let attitude = motion.attitude
            let gravity = motion.gravity

            let row = [
                "\(timestamp)",
                "\(accel.x)", "\(accel.y)", "\(accel.z)",
                "\(gyro.x)", "\(gyro.y)", "\(gyro.z)",
                "\(mag.x)", "\(mag.y)", "\(mag.z)",
                "\(attitude.roll)", "\(attitude.pitch)", "\(attitude.yaw)",
                "\(gravity.x)", "\(gravity.y)", "\(gravity.z)"
            ].joined(separator: ",") + "\n"

            if let data = row.data(using: .utf8) {
                self.motionFileHandle?.write(data)
            }
        }
    }
    
    private func stopRecording(sendStopCamera: Bool) {
        scheduledStartWorkItem?.cancel()
        scheduledStartWorkItem = nil

        motionManager.stopDeviceMotionUpdates()

        if sendStopCamera {
            WCSession.default.sendMessage(["action": "stopCamera"], replyHandler: nil) { error in
                print("Failed sending stopCamera: \(error.localizedDescription)")
            }
        }

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        workoutSession?.end()
        workoutSession = nil
        
        if let audioFileHandle = audioFileHandle, let _ = audioFileURL {
            updateWAVHeader(fileHandle: audioFileHandle)
            audioFileHandle.closeFile()
        }
        
        motionFileHandle?.closeFile()
        
        motionFileHandle = nil
        audioFileHandle = nil
        audioFileURL = nil
        isRecording = false
        scheduledStartEpoch = nil
        startedFromPhone = false
        stopTimer()
    }
    
    private func startAudioRecording(timestamp: String, suffix: String) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        audioFileURL = documentsURL.appendingPathComponent(makeAudioFileName(timestamp: timestamp, suffix: suffix))
        guard let audioFileURL = audioFileURL else { return }
        do {
            audioFileHandle = createWAVFile(url: audioFileURL)
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, when) in
                guard let self = self,
                      let converter = AVAudioConverter(from: inputFormat, to: self.audioOutputFormat),
                      let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.audioOutputFormat, frameCapacity: AVAudioFrameCount(self.audioOutputFormat.sampleRate*Double(buffer.frameLength)/buffer.format.sampleRate))
                else { return }
                
                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in outStatus.pointee = .haveData; return buffer }
                converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
                
                if let error = error { print("Audio conversion error: \(error.localizedDescription)"); return }
                
                if let channelData = convertedBuffer.int16ChannelData?.pointee {
                    let data = Data(bytes: channelData, count: Int(convertedBuffer.frameLength) * Int(self.audioOutputFormat.streamDescription.pointee.mBytesPerFrame))
                    self.audioFileHandle?.write(data)
                }
            }
            try audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("Audio start error: \(error.localizedDescription)")
            stopRecording(sendStopCamera: true)
        }
    }
    
    private func createWAVFile(url: URL) -> FileHandle? {
        let header = Data(count: 44)
        do {
            try header.write(to: url)
            return try FileHandle(forWritingTo: url)
        } catch {
            print("WAV creation error: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func updateWAVHeader(fileHandle: FileHandle) {
        let len = fileHandle.offsetInFile; let sr = UInt32(audioOutputFormat.sampleRate); let ch = UInt32(audioOutputFormat.channelCount); let bps: UInt16 = 16
        var header = Data(); header.append(contentsOf: "RIFF".utf8); header.append(Data(from: UInt32(len-8).littleEndian)); header.append(contentsOf: "WAVE".utf8); header.append(contentsOf: "fmt ".utf8); header.append(Data(from: UInt32(16).littleEndian)); header.append(Data(from: UInt16(1).littleEndian)); header.append(Data(from: UInt16(ch).littleEndian)); header.append(Data(from: sr.littleEndian)); let byteRate = sr * ch * UInt32(bps/8); header.append(Data(from: byteRate.littleEndian)); let blockAlign = UInt16(ch) * bps/8; header.append(Data(from: blockAlign.littleEndian)); header.append(Data(from: bps.littleEndian)); header.append(contentsOf: "data".utf8); header.append(Data(from: UInt32(len-44).littleEndian))
        do { try fileHandle.seek(toOffset: 0); fileHandle.write(header) } catch { print("WAV header error: \(error.localizedDescription)") }
    }
    
    private func startTimer(anchorEpoch: TimeInterval) {
        DispatchQueue.main.async {
            self.elapsedTime = 0
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.elapsedTime = Date().timeIntervalSince1970 - anchorEpoch
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func getTimestampString() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd_HHmmss"; return formatter.string(from: Date())
    }
    
    private func getCurrentTimestamp() -> TimeInterval {
        return Date().timeIntervalSince1970
    }
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error { print("Watch session error: \(error.localizedDescription)"); return }
        print("Watch session state: \(activationState.rawValue)")
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if let sentFileName = message["fileSent"] as? String {
            print("Watch received confirmation for: \(sentFileName)")
            
            // We need to do the file move on the main thread.
            DispatchQueue.main.async {
                self.moveFileToSentDirectory(fileName: sentFileName)
            }
            return
        }

        if message["action"] != nil {
            DispatchQueue.main.async {
                self.handleIncomingAction(message)
            }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        if userInfo["action"] != nil {
            DispatchQueue.main.async {
                self.handleIncomingAction(userInfo)
            }
        }
    }

    private func handleIncomingAction(_ payload: [String: Any]) {
        guard let action = payload["action"] as? String else { return }
        switch action {
        case "startRecording":
            let epoch = payload["scheduledStartEpoch"] as? TimeInterval ?? (Date().timeIntervalSince1970 + 5)
            let suffix = sanitizeSuffix(payload["suffix"] as? String ?? "")
            let rawTs = (payload["sessionTimestamp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            currentFilenameSuffix = suffix
            currentSessionTimestamp = (rawTs?.isEmpty == false) ? rawTs! : getTimestampString()
            startedFromPhone = true
            scheduledStartEpoch = epoch
            requestPermissionsAndStart(scheduledStartEpoch: epoch)
        case "stopRecording":
            stopRecording(sendStopCamera: false)
        default:
            break
        }
    }

    private func sanitizeSuffix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(trimmed.unicodeScalars.filter { allowed.contains($0) })
    }

    private func makeMotionFileName(timestamp: String, suffix: String) -> String {
        suffix.isEmpty ? "motion_\(timestamp).csv" : "motion_\(timestamp)_\(suffix).csv"
    }

    private func makeAudioFileName(timestamp: String, suffix: String) -> String {
        suffix.isEmpty ? "audio_\(timestamp).wav" : "audio_\(timestamp)_\(suffix).wav"
    }

    // This is the helper function that moves a file into the "sent_files" folder.
    private func moveFileToSentDirectory(fileName: String) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        let sourceURL = documentsURL.appendingPathComponent(fileName)
        let sentDirectoryURL = documentsURL.appendingPathComponent("sent_files")
        let destinationURL = sentDirectoryURL.appendingPathComponent(fileName)
        
        do {
            // Create the "sent_files" directory if it doesn't already exist.
            try FileManager.default.createDirectory(at: sentDirectoryURL, withIntermediateDirectories: true, attributes: nil)
            
            // Move the file from the main directory to the sent directory.
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            print("Successfully archived \(fileName) to sent_files directory.")
            
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // This is not a critical error. It just means we got a confirmation for a file that was already moved.
            print("Warning: Could not find \(fileName) to archive (it may have already been moved).")
        } catch {
            print("Error archiving file \(fileName): \(error.localizedDescription)")
        }
    }
}
extension Data { init<T>(from value: T) { var value = value; self = Swift.withUnsafeBytes(of: &value) { Data($0) } } }
