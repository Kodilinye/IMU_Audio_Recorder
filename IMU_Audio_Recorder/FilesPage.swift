import SwiftUI

private struct PairedRow: Identifiable {
    let id: String
    let timestamp: String
    let suffix: String
    var hasMotion: Bool
    var hasAudio: Bool
    var hasVideo: Bool
}

private let pairingRegex = try! NSRegularExpression(pattern: #"^(motion|audio|video)_(\d{8}_\d{6})(?:_(.+))?\.(csv|wav|mov)$"#)

struct FilesPage: View {
    @State private var rows: [PairedRow] = []

    var body: some View {
        NavigationStack {
            List(rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.timestamp + (row.suffix.isEmpty ? "" : "_\(row.suffix)"))
                        .font(.headline.monospaced())
                    HStack(spacing: 8) {
                        pill("Motion", ok: row.hasMotion)
                        pill("Audio", ok: row.hasAudio)
                        pill("Video", ok: row.hasVideo)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Paired files")
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .pairingFilesChanged)) { _ in
                reload()
            }
        }
    }

    private func pill(_ title: String, ok: Bool) -> some View {
        Text(ok ? "✓ \(title)" : "— \(title)")
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ok ? Color.green.opacity(0.2) : Color.gray.opacity(0.15))
            .cornerRadius(8)
    }

    private func reload() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            rows = []
            return
        }

        var accum: [String: PairedRow] = [:]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            rows = []
            return
        }

        for url in urls {
            let name = url.lastPathComponent
            let ns = name as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = pairingRegex.firstMatch(in: name, options: [], range: range),
                  match.numberOfRanges >= 5 else { continue }

            let kind = (ns.substring(with: match.range(at: 1))).lowercased()
            let ts = ns.substring(with: match.range(at: 2))
            let suffixRange = match.range(at: 3)
            let suffix = suffixRange.location != NSNotFound ? ns.substring(with: suffixRange) : ""

            let key = ts + "|" + suffix
            var row = accum[key] ?? PairedRow(id: key, timestamp: ts, suffix: suffix, hasMotion: false, hasAudio: false, hasVideo: false)
            switch kind {
            case "motion": row.hasMotion = true
            case "audio": row.hasAudio = true
            case "video": row.hasVideo = true
            default: break
            }
            accum[key] = row
        }

        rows = accum.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.suffix < $1.suffix
        }
    }
}
