// DataRecorder.swift (Using CMDeviceMotion and Your Reference Code)

import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import HealthKit
import WatchConnectivity
import WatchKit

class DataRecorder: NSObject, ObservableObject, WCSessionDelegate, CLLocationManagerDelegate, HKWorkoutSessionDelegate {
    private static let suffixDefaultsKey = "watchFilenameSuffix"

    // MARK: - Properties
    private let motionManager = CMMotionManager()
    private let audioEngine = AVAudioEngine()
    private let healthStore = HKHealthStore()
    private let locationManager = CLLocationManager()
    private var workoutSession: HKWorkoutSession?
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
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
        // Raise QoS so the motion queue is treated as a foreground / interactive
        // workload by watchOS. Combined with an active HKWorkoutSession this is
        // what keeps CoreMotion samples flowing after the wrist drops.
        motionQueue.qualityOfService = .userInteractive
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.name = "com.imuaudio.motionQueue"

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
                    // *** CRITICAL ***
                    // Start the keep-awake workout session NOW, before the
                    // 5-second countdown begins. Otherwise, if the user lowers
                    // their wrist during the countdown, watchOS will suspend
                    // the app before any sampling has a chance to start.
                    // The actual file writing is still deferred to the
                    // scheduled epoch so watch + phone stay in sync.
                    self.startKeepAwakeWorkout()
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

    /// Starts an HKWorkoutSession (.other) right when the user/phone asks for
    /// recording. The workout session is what grants the app extended
    /// background runtime on watchOS; without it, lowering your wrist causes
    /// the app to suspend within a couple of seconds and motion updates stop.
    /// We also kick off a WKExtendedRuntimeSession as a second-line safety
    /// net for cases where HealthKit isn't authorized.
    private func startKeepAwakeWorkout() {
        // If a workout is already running (e.g. user spam-pressed start), don't
        // start a new one.
        if workoutSession != nil { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session.delegate = self
            session.startActivity(with: Date())
            workoutSession = session
            print("[DBG] keep-awake workout session started OK (state=\(session.state.rawValue))")
        } catch {
            print("[DBG] Workout session failed to start, falling back to ExtendedRuntimeSession: \(error.localizedDescription)")
            workoutSession = nil
            startExtendedRuntimeSessionFallback()
        }
    }

    /// Fallback path when HKWorkoutSession is unavailable (denied auth,
    /// simulator, etc). Buys us up to ~1h of background runtime but is less
    /// reliable than a workout session.
    private func startExtendedRuntimeSessionFallback() {
        if extendedRuntimeSession?.state == .running { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedRuntimeSession = session
        print("[DBG] Started WKExtendedRuntimeSession fallback")
    }

    private func scheduleStart(at epoch: TimeInterval) {
        scheduledStartWorkItem?.cancel()
        let delay = max(0, epoch - Date().timeIntervalSince1970)
        print("[DBG] scheduleStart delay=\(delay)s epoch=\(epoch)")
        let work = DispatchWorkItem { [weak self] in
            print("[DBG] scheduled work item firing -> beginDataCapture")
            self?.scheduledStartWorkItem = nil
            self?.beginDataCapture(anchorEpoch: epoch)
        }
        scheduledStartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Called at the synchronized epoch. The workout session has already been
    /// running for the past ~5 seconds keeping the watch alive, so we just
    /// kick off the motion+audio file streams here.
    private func beginDataCapture(anchorEpoch: TimeInterval) {
        print("[DBG] beginDataCapture entered, workoutSession=\(workoutSession != nil ? "alive" : "nil")")
        // Defensive: if for any reason the workout session wasn't started in
        // requestPermissionsAndStart (e.g. action came in via a path that
        // bypassed it), make sure it's running now before we touch motion.
        if workoutSession == nil {
            startKeepAwakeWorkout()
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

                    // Sanity-check that the sensor data looks valid. These
                    // are diagnostic prints only — they do NOT change what
                    // is written to the CSV (still the original 16 columns).
                    let gravNorm = sqrt(gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z)
                    let magNorm = sqrt(mag.x * mag.x + mag.y * mag.y + mag.z * mag.z)
                    if mag.x == 0 && mag.y == 0 && mag.z == 0 {
                        print("[DBG]   !! magneticField is exactly zero -> compass uncalibrated. Wave the watch in a figure-8 to calibrate.")
                    } else if magAccuracy < 0 {
                        print("[DBG]   !! mag accuracy = -1 (uncalibrated). Values present (|mag|=\(magNorm)uT) but not trustworthy yet.")
                    }
                    if abs(gravNorm - 1.0) > 0.2 {
                        print("[DBG]   !! gravity magnitude=\(gravNorm)G is far from 1G — gravity model may not be converged yet.")
                    }
                }
            } else if self.motionFileHandle == nil {
                print("[DBG] Sample arrived but motionFileHandle is nil (file already closed)")
            }
        }

        let referenceFrames = CMMotionManager.availableAttitudeReferenceFrames()
        print("[DBG] availableAttitudeReferenceFrames raw=\(referenceFrames.rawValue) hasMag=\(motionManager.isMagnetometerAvailable) locationAuth=\(locationManager.authorizationStatus.rawValue)")

        // Match the original/reference project: just ask for the magnetic
        // frame and let samples flow. isDeviceMotionActive is unreliable
        // immediately after start, so don't gate on it. If for some reason
        // no samples arrive within 1 second (e.g. true-north can't be
        // computed because the compass needs calibration or there's no GPS
        // fix), the watchdog below will downgrade us automatically.
        print("[DBG] starting motion with xTrueNorthZVertical (matches reference project)")
        motionManager.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: motionQueue, withHandler: handler)
        lastReportedReferenceFrameRawValue = CMAttitudeReferenceFrame.xTrueNorthZVertical.rawValue

        scheduleMotionFallbackChain(handler: handler, remainingFrames: [
            .xMagneticNorthZVertical,
            .xArbitraryCorrectedZVertical,
            .xArbitraryZVertical
        ])

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

        // Release the shared audio session so other apps can use the mic.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("[DBG] AVAudioSession setActive(false) failed: \(error.localizedDescription)")
        }

        workoutSession?.end()
        workoutSession = nil

        // Tear down the extended-runtime fallback if it was started.
        if let ers = extendedRuntimeSession, ers.state == .running {
            ers.invalidate()
        }
        extendedRuntimeSession = nil
        
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
            // Configure the shared audio session for recording. Without this
            // watchOS often denies microphone access in the background, even
            // with the workout session keeping the app alive.
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [])
            try audioSession.setActive(true, options: [])

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

    /// Watchdog: if the currently-selected reference frame fails to deliver
    /// any motion samples within `delay` seconds, stop and try the next one.
    /// This protects against silent failures (e.g. true-north can't be
    /// computed) without sacrificing the ability to use the best frame in
    /// the common case.
    private func scheduleMotionFallbackChain(handler: @escaping CMDeviceMotionHandler,
                                             remainingFrames: [CMAttitudeReferenceFrame],
                                             delay: TimeInterval = 1.0) {
        let baseline = motionSampleCount
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.isRecording else { return }
            if self.motionSampleCount > baseline {
                print("[DBG] watchdog OK: \(self.motionSampleCount - baseline) samples in last \(delay)s with frame \(self.referenceFrameName(self.lastReportedReferenceFrameRawValue))")
                return
            }
            print("[DBG] watchdog: zero samples in \(delay)s with frame \(self.referenceFrameName(self.lastReportedReferenceFrameRawValue)) — falling back")
            self.motionManager.stopDeviceMotionUpdates()

            if let next = remainingFrames.first {
                print("[DBG]   -> trying \(self.referenceFrameName(next.rawValue))")
                self.motionManager.startDeviceMotionUpdates(using: next, to: self.motionQueue, withHandler: handler)
                self.lastReportedReferenceFrameRawValue = next.rawValue
                self.scheduleMotionFallbackChain(handler: handler,
                                                 remainingFrames: Array(remainingFrames.dropFirst()),
                                                 delay: delay)
            } else {
                print("[DBG]   -> all frames exhausted, using no reference frame")
                self.motionManager.startDeviceMotionUpdates(to: self.motionQueue, withHandler: handler)
                self.lastReportedReferenceFrameRawValue = 0
            }
        }
    }

    private func referenceFrameName(_ raw: UInt) -> String {
        switch raw {
        case 0: return "noReferenceFrame (relative attitude, no mag)"
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

    // MARK: - HKWorkoutSessionDelegate
    // We don't need to do anything special here, but having the delegate set
    // (a) lets us SEE if/when watchOS ends the session for us, and
    // (b) is required by Apple's modern workout API.

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        print("[DBG] workout session state \(fromState.rawValue) -> \(toState.rawValue) at \(date)")
        // If the system ended the session out from under us while we're still
        // supposed to be recording (e.g. low power), surface that loudly so
        // we can diagnose in the Xcode console instead of silently going
        // idle.
        if toState == .ended && isRecording {
            print("[DBG] !! workout session ended while still recording — background runtime likely revoked")
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("[DBG] workout session failed: \(error.localizedDescription)")
    }
}

extension DataRecorder: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[DBG] WKExtendedRuntimeSession started")
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[DBG] WKExtendedRuntimeSession about to expire — recording may stop")
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        print("[DBG] WKExtendedRuntimeSession invalidated, reason=\(reason.rawValue), error=\(error?.localizedDescription ?? "nil")")
    }
}
extension Data { init<T>(from value: T) { var value = value; self = Swift.withUnsafeBytes(of: &value) { Data($0) } } }
