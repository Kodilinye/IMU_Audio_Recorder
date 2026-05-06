import Foundation
import SwiftUI

/// Shared recording session parameters across TabView pages (phone).
final class RecordingSessionState: ObservableObject {
    /// Unix epoch when capture starts (synced with Apple Watch).
    @Published var scheduledStartEpoch: TimeInterval?
    /// Filename stem `yyyyMMdd_HHmmss` shared with watch CSV/WAV/video.
    @Published var sessionTimestamp: String = ""
    /// Sanitized user suffix (may be empty).
    @Published var filenameSuffix: String = ""
    /// When true, `CustomVideoRecorder` arms recording at `scheduledStartEpoch`.
    @Published var isVideoRecording: Bool = false
}

enum FilenameSuffixHelper {
    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(trimmed.unicodeScalars.filter { allowed.contains($0) })
    }
}
