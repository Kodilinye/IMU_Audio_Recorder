// DataRecorder.swift (Using CMDeviceMotion and Your Reference Code)

import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import HealthKit
import WatchConnectivity

class DataRecorder: NSObject, ObservableObject, WCSessionDelegate, CLLocationManagerDelegate {
    private static let suffixDefaultsKey = "watchFilenameSuffix"

    // MARK: - Properties
    private let motionManager = CMMotionManager()
    private let audioEngine = AVAudioEngine()
    private let healthStore = HKHealthStore()
    private let locationManager = CLLocationManager()
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
    private var motionSampleCount: Int = 0
    private var motionDebugTimer: Timer?
    private var lastMotionSnapshot: (accel: CMAcceleration, gyro: CMRotationRate, mag: CMMagneticField, magAccuracy: Int32, attitude: CMAttitude, gravity: CMAcceleration)?
    private var lastReportedReferenceFrameRawValue: UInt = 0
    // --- SIMPLIFIED: Only one file handle is needed for all motion data ---
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
            motionManager.deviceMotionUpdateInterval = 1.0 / 100.0 // 100 Hz
            // Allows the system to ask the user for the figure-8 calibration
            // dance when needed; without this the magnetometer can stay
            // uncalibrated and CMDeviceMotion.magneticField stays at zero.
            motionManager.showsDeviceMovementDisplay = true
        }
        currentFilenameSuffix = sanitizeSuffix(UserDefaults.standard.string(forKey: Self.suffixDefaultsKey) ?? "")

        // Location permission is required for the xTrueNorthZVertical attitude
        // reference frame. Without it the OS rejects the start request with
        // "Failed to get true north" and no motion samples are delivered.
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()

        computeDeviceCapabilities()
    }
    
    // This function now checks raw sensor availability for the UI string, as requested.
    private func computeDeviceCapabilities() {
        var status = "Sensors: "
        status += motionManager.isAccelerometerAvailable ? "A" : "_"
        status += motionManager.isGyroAvailable ? "G" : "_"
        status += motionManager.isMagnetometerAvailable ? "M" : "_"
        // We add "D" to confirm the primary service we are using is ready.
        status += motionManager.isDeviceMotionAvailable ? "D" : "_"
        imuStatusText = status
        
        let sampleRate = Int(audioOutputFormat.sampleRate / 1000)
        let bitDepth = 16
        audioStatusText = "Audio: \(sampleRate)kHz \(bitDepth)-bit"
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
        print("toggle recording called")
        if isRecording || scheduledStartWorkItem != nil {
            stopRecording(sendStopCamera: true)
        } else {
            computeDeviceCapabilities() // Re-check sensors right before we start
            startedFromPhone = false
            setCurrentFilenameSuffix(currentFilenameSuffix)
            currentSessionTimestamp = getTimestampString()
            let epoch = Date().timeIntervalSince1970 + 5.0
            scheduledStartEpoch = epoch

            WatchTrigger.remoteStartPhoneCamera(
                scheduledStartEpoch: epoch,
                sessionTimestamp: currentSessionTimestamp,
                suffix: currentFilenameSuffix
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestPermissionsAndStart(scheduledStartEpoch: epoch)
            }
        }
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
        print("[DBG] requestPermissionsAndStart called, scheduledEpoch=\(scheduledStartEpoch), now=\(Date().timeIntervalSince1970)")
        let workoutTypes: Set<HKSampleType> = [HKObjectType.workoutType()]

        // HealthKit is best-effort: it only powers the workout session that
        // keeps the watch awake. If it fails (e.g. capability removed, denied,
        // or simulator), we still continue so motion + audio can record.
        healthStore.requestAuthorization(toShare: workoutTypes, read: workoutTypes) { [weak self] success, error in
            guard let self = self else { return }
            print("[DBG] HK requestAuthorization callback success=\(success) error=\(error?.localizedDescription ?? "nil")")

            self.requestMicrophonePermission { [weak self] granted in
                guard let self = self else { return }
                print("[DBG] mic permission granted=\(granted)")
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
        print("[DBG] scheduleStart delay=\(delay)s epoch=\(epoch)")
        let work = DispatchWorkItem { [weak self] in
            print("[DBG] scheduled work item firing -> startWorkoutSession")
            self?.scheduledStartWorkItem = nil
            self?.startWorkoutSession(anchorEpoch: epoch)
        }
        scheduledStartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startWorkoutSession(anchorEpoch: TimeInterval) {
        print("[DBG] startWorkoutSession entered")
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        // Workout session is best-effort. Without it the watch may sleep mid
        // recording, but failing to start it must NOT prevent motion/audio
        // capture (which is the whole point of the app).
        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            workoutSession?.startActivity(with: nil)
            print("[DBG] workout session started OK")
        } catch {
            print("[DBG] Workout session error (continuing without keep-awake): \(error.localizedDescription)")
            workoutSession = nil
        }

        startDataRecording(timestamp: currentSessionTimestamp, suffix: currentFilenameSuffix)
        isRecording = true
        startTimer(anchorEpoch: anchorEpoch)
    }
    
    // This is the main function that begins all data collection.
    private func startDataRecording(timestamp: String, suffix: String) {
        startMotionUpdates(timestamp: timestamp, suffix: suffix)
        startAudioRecording(timestamp: timestamp, suffix: suffix)
    }

    private func startMotionUpdates(timestamp: String, suffix: String) {
        print("[DBG] startMotionUpdates entered. isDeviceMotionAvailable=\(motionManager.isDeviceMotionAvailable) isAccelAvail=\(motionManager.isAccelerometerAvailable) isGyroAvail=\(motionManager.isGyroAvailable) isMagAvail=\(motionManager.isMagnetometerAvailable)")
        guard motionManager.isDeviceMotionAvailable else {
            print("[DBG] Device Motion service is not available. (Are you running on the Watch simulator? It has no IMU.)")
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / 100.0

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[DBG] Could not resolve documents URL")
            return
        }
        let motionFileURL = documentsURL.appendingPathComponent(makeMotionFileName(timestamp: timestamp, suffix: suffix))
        print("[DBG] motion file path: \(motionFileURL.path)")

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
            print("[DBG] motion file created with header (\(header.count) bytes)")
        } catch {
            print("[DBG] Failed to create motion file: \(error.localizedDescription)")
            return
        }

        motionSampleCount = 0

        let handler: CMDeviceMotionHandler = { [weak self] (deviceMotion, error) in
            guard let self = self else { return }
            if let error = error {
                print("[DBG] DeviceMotion error: \(error.localizedDescription)")
                return
            }
            guard let motion = deviceMotion else {
                print("[DBG] DeviceMotion handler fired with nil motion")
                return
            }

            let timestamp = self.getCurrentTimestamp()
            let accel = motion.userAcceleration
            let gyro = motion.rotationRate
            let magField = motion.magneticField
            let mag = magField.field
            let magAccuracy = magField.accuracy.rawValue
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

            if let data = row.data(using: .utf8), let fh = self.motionFileHandle {
                fh.write(data)
                self.motionSampleCount += 1
                self.lastMotionSnapshot = (accel: accel, gyro: gyro, mag: mag, magAccuracy: magAccuracy, attitude: attitude, gravity: gravity)
                if self.motionSampleCount == 1 {
                    print("[DBG] FIRST motion sample written.")
                    print("[DBG]   accel=(\(accel.x), \(accel.y), \(accel.z)) G")
                    print("[DBG]   gyro=(\(gyro.x), \(gyro.y), \(gyro.z)) rad/s")
                    print("[DBG]   mag=(\(mag.x), \(mag.y), \(mag.z)) uT, accuracy=\(magAccuracy) (-1=uncal, 0=low, 1=med, 2=high)")
                    print("[DBG]   attitude roll=\(attitude.roll) pitch=\(attitude.pitch) yaw=\(attitude.yaw) rad")
                    print("[DBG]   gravity=(\(gravity.x), \(gravity.y), \(gravity.z)) G")
                }
            } else if self.motionFileHandle == nil {
                print("[DBG] Sample arrived but motionFileHandle is nil (file already closed)")
            }
        }

        let referenceFrames = CMMotionManager.availableAttitudeReferenceFrames()
        print("[DBG] availableAttitudeReferenceFrames raw=\(referenceFrames.rawValue)")

        // Reference-frame priority (mirrors the older reference project, but
        // with verified activation and graceful fallback):
        //   1. xTrueNorthZVertical: needs working magnetometer + CoreLocation
        //      auth. Gives mag data + true-north heading.
        //   2. xMagneticNorthZVertical: needs magnetometer only, no location.
        //   3. xArbitraryCorrectedZVertical: gyro+accel attitude, mag-corrected
        //      yaw over time when the magnetometer is available.
        //   4. xArbitraryZVertical: pure gyro+accel, mag stays zero.
        // We try them in order and verify each actually activates, because
        // availableAttitudeReferenceFrames() over-reports support on watches
        // with no usable magnetometer.
        let candidateFrames: [CMAttitudeReferenceFrame] = [
            .xTrueNorthZVertical,
            .xMagneticNorthZVertical,
            .xArbitraryCorrectedZVertical,
            .xArbitraryZVertical
        ]

        var started = false
        lastReportedReferenceFrameRawValue = 0
        for frame in candidateFrames {
            guard referenceFrames.contains(frame) else { continue }
            motionManager.stopDeviceMotionUpdates()
            print("[DBG] trying motion with reference frame raw=\(frame.rawValue)")
            motionManager.startDeviceMotionUpdates(using: frame, to: motionQueue, withHandler: handler)
            if motionManager.isDeviceMotionActive {
                started = true
                lastReportedReferenceFrameRawValue = frame.rawValue
                print("[DBG] motion ACTIVE with frame raw=\(frame.rawValue) (\(referenceFrameName(frame.rawValue)))")
                break
            }
            print("[DBG] frame raw=\(frame.rawValue) did not activate, trying next")
        }

        if !started {
            motionManager.stopDeviceMotionUpdates()
            print("[DBG] starting motion with NO reference frame (universal fallback)")
            motionManager.startDeviceMotionUpdates(to: motionQueue, withHandler: handler)
        }
        print("[DBG] startDeviceMotionUpdates returned. isDeviceMotionActive=\(motionManager.isDeviceMotionActive)")

        DispatchQueue.main.async { [weak self] in
            self?.motionDebugTimer?.invalidate()
            self?.motionDebugTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let frameName = self.referenceFrameName(self.lastReportedReferenceFrameRawValue)
                if let s = self.lastMotionSnapshot {
                    let magMag = sqrt(s.mag.x * s.mag.x + s.mag.y * s.mag.y + s.mag.z * s.mag.z)
                    let rad2deg = 180.0 / .pi
                    print(String(format: "[DBG] tick samples=%d active=%@ frame=%@ |mag|=%.2fuT (acc=%d) attRPY=(%.1f, %.1f, %.1f)deg",
                                 self.motionSampleCount,
                                 self.motionManager.isDeviceMotionActive ? "Y" : "N",
                                 frameName,
                                 magMag, s.magAccuracy,
                                 s.attitude.roll * rad2deg,
                                 s.attitude.pitch * rad2deg,
                                 s.attitude.yaw * rad2deg))
                } else {
                    print("[DBG] tick samples=0 active=\(self.motionManager.isDeviceMotionActive ? "Y" : "N") frame=\(frameName) (no samples yet)")
                }
            }
        }
    }
    
    // This function now stops the single device motion service.
    private func stopRecording(sendStopCamera: Bool = true) {
        print("[DBG] stopRecording called. sendStopCamera=\(sendStopCamera) isRecording=\(isRecording) samples=\(motionSampleCount) caller=\(Thread.callStackSymbols.dropFirst().prefix(4).joined(separator: " | "))")
        motionDebugTimer?.invalidate()
        motionDebugTimer = nil
        let hadActiveCapture = isRecording || motionFileHandle != nil || audioFileHandle != nil
        scheduledStartWorkItem?.cancel()
        scheduledStartWorkItem = nil
        motionManager.stopDeviceMotionUpdates()

        if sendStopCamera {
            let stopPayload: [String: Any] = ["action": "stopCamera"]
            WCSession.default.sendMessage(stopPayload, replyHandler: nil) { error in
                print("Failed sending stopCamera: \(error.localizedDescription)")
                WCSession.default.transferUserInfo(stopPayload)
            }
            WCSession.default.transferUserInfo(stopPayload)
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

        if hadActiveCapture {
            sendFilesToPhone()
        }
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
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("Audio start error (motion will continue): \(error.localizedDescription)")
            audioEngine.inputNode.removeTap(onBus: 0)
            audioFileHandle?.closeFile()
            audioFileHandle = nil
            self.audioFileURL = nil
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

    private func setCurrentFilenameSuffix(_ suffix: String) {
        currentFilenameSuffix = sanitizeSuffix(suffix)
        UserDefaults.standard.set(currentFilenameSuffix, forKey: Self.suffixDefaultsKey)
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

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
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
            setCurrentFilenameSuffix(suffix)
            currentSessionTimestamp = (rawTs?.isEmpty == false) ? rawTs! : getTimestampString()
            startedFromPhone = true
            scheduledStartEpoch = epoch
            requestPermissionsAndStart(scheduledStartEpoch: epoch)
        case "updateSuffix":
            let suffix = sanitizeSuffix(payload["suffix"] as? String ?? "")
            setCurrentFilenameSuffix(suffix)
            print("Updated watch suffix to: \(suffix)")
        case "stopRecording":
            stopRecording(sendStopCamera: false)
        default:
            break
        }
    }

    // This is the helper function that moves a file into the "sent_files" folder.
    private func moveFileToSentDirectory(fileName: String) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        let sourceURL = documentsURL.appendingPathComponent(fileName)
        let sentDirectoryURL = documentsURL.appendingPathComponent("sent_files")
        let destinationURL = sentDirectoryURL.appendingPathComponent(fileName)
        
        do {
            try FileManager.default.createDirectory(at: sentDirectoryURL, withIntermediateDirectories: true, attributes: nil)

            // If the destination already exists (re-confirmation of an earlier
            // transfer), just delete the source. Otherwise move it.
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try FileManager.default.removeItem(at: sourceURL)
                    print("Source \(fileName) deleted (already archived).")
                } else {
                    print("\(fileName) already archived; nothing to do.")
                }
            } else {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                print("Successfully archived \(fileName) to sent_files directory.")
            }
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            print("Warning: Could not find \(fileName) to archive (it may have already been moved).")
        } catch {
            print("Error archiving file \(fileName): \(error.localizedDescription)")
        }
    }

    private func referenceFrameName(_ raw: UInt) -> String {
        switch raw {
        case CMAttitudeReferenceFrame.xArbitraryZVertical.rawValue: return "xArbitraryZVertical (no mag)"
        case CMAttitudeReferenceFrame.xArbitraryCorrectedZVertical.rawValue: return "xArbitraryCorrectedZVertical (mag-corrected yaw)"
        case CMAttitudeReferenceFrame.xMagneticNorthZVertical.rawValue: return "xMagneticNorthZVertical (mag, no GPS)"
        case CMAttitudeReferenceFrame.xTrueNorthZVertical.rawValue: return "xTrueNorthZVertical (mag + GPS)"
        default: return "unknown(\(raw))"
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("[DBG] CLLocationManager authorization status changed -> \(status.rawValue) (3=AlwaysWhenInUse-ish, 4=Always, 0=NotDetermined, 2=Denied)")
    }
}
extension Data { init<T>(from value: T) { var value = value; self = Swift.withUnsafeBytes(of: &value) { Data($0) } } }
