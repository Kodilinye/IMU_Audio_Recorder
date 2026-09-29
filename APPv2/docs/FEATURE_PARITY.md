# Source-grounded parity checklist

Reviewed before implementation: the authoritative repository-root `IMU_Audio_Recorder.xcodeproj/project.pbxproj` and both synchronized source groups. The Apple project is preserved alongside `APPv2`; the checklist's source references describe the original review. Research files were inspected read-only and are not included in this repository.

- [x] Start/Stop on watch and phone; five-second countdown with Cancel. Original: `DataRecorder.swift:108–129,238–271`, `ControlPage.swift`.
- [x] Shared local-time `yyyyMMdd_HHmmss` name and sanitized optional suffix; separate UUID directory prevents same-second overwrites. Original: `RecordingSessionState.swift`, `DataRecorder.swift:547–572`.
- [x] Watch motion and mono PCM16 WAV; local Stop/save without phone. Original: `DataRecorder.swift:289–387,413–530`.
- [x] Phone front-camera video with associated audio when permitted; explicit missing/failed video. Original: `CameraManager.swift`.
- [x] Countdown, elapsed time, actual recording status and connection status. Original: `WatchContentView.swift`, phone `StatusPage.swift`, `VideoPage.swift`.
- [x] Durable local recordings, automatic watch-to-phone transfer and manual retry. Verify bytes and SHA-256 before receipt; retain originals. Original: `DataRecorder.swift:132–159,629–658`, `PhoneConnectivityManager.swift`.
- [x] Phone session file listing and Android share/export. Original: `FilesPage.swift`, document sharing configuration in Xcode project.

Scientific differences: raw Android streams are asynchronous with native monotonic timing; preserve them. Apple requests 100 Hz fused CMDeviceMotion, writes callback Unix seconds, userAcceleration in G, rotationRate rad/s, magneticField µT, attitude R/P/Y radians, gravity G. Its true-north attitude can fall back to magnetic/arbitrary frames. Do not label Android angles as Apple Euler angles. Raw export adapter is separately documented.

Defects to correct: cancellation/permission races; queued stale starts; unscoped Stop; recordings falsely reported as active; same-second overwrite; WAV header offset; archiving without a content-verified receipt.

Platform boundary: Android background camera/microphone restrictions require both apps visible for a new paired start. A started foreground capture can continue with screen off; the watch holds a partial wake lock. Phone unavailability is explicit; disconnected watch recording is useful and supported. Countdown coordinates intent, not sample-accurate synchronization.
