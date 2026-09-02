import Foundation

struct SpeakerTurn: Decodable {
    let start: Double
    let end: Double
    let speaker: Int
}

/// Optional speaker separation: sherpa-onnx (pyannote segmentation + speaker embeddings) in a venv under
/// ~/.meetnotes, installed by scripts/setup-diarization.sh. Runs fully offline.
enum Diarization {
    static let enabledKey = "diarizationEnabled"

    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meetnotes") }
    static var python: URL { root.appendingPathComponent("venv/bin/python") }
    static var segModel: URL { root.appendingPathComponent("models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx") }
    static var embModel: URL { root.appendingPathComponent("models/nemo_en_titanet_small.onnx") }

    /// Prefer the copy shipped inside the app bundle so the app and script stay in step; ~/.meetnotes is the
    /// fallback for the bare CLI binary.
    static var script: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("diarize.py"),
            root.appendingPathComponent("diarize.py"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var setupScript: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("setup-diarization.sh"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("../../scripts/setup-diarization.sh").standardizedFileURL,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python.path) && fm.fileExists(atPath: segModel.path)
            && fm.fileExists(atPath: embModel.path) && script != nil
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func run(wav16k: URL) throws -> [SpeakerTurn] {
        guard let script else { throw TranscriberError.toolFailed("diarize", "diarize.py not found") }
        let r = try Shell.run(python.path, [script.path, wav16k.path])
        guard r.status == 0 else { throw TranscriberError.toolFailed("diarize", r.output) }
        // stderr is merged into output; the JSON array is the last line
        guard let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("[") }),
              let data = line.data(using: .utf8)
        else { throw TranscriberError.toolFailed("diarize", r.output) }
        return try JSONDecoder().decode([SpeakerTurn].self, from: data)
    }

    /// Relabel segments that belong to the remote side ("Others", or unlabelled in single-track mode) as
    /// "Voice N", numbered by first appearance. Segments with no overlapping turn keep their label.
    static func attribute(_ segments: [Segment], turns: [SpeakerTurn]) -> [Segment] {
        var order: [Int: Int] = [:]
        return segments.map { seg in
            guard seg.speaker == nil || seg.speaker == Diarizer.others else { return seg }
            let from = Double(seg.fromMs) / 1000, to = Double(seg.toMs) / 1000
            var overlap: [Int: Double] = [:]
            for t in turns {
                let o = min(to, t.end) - max(from, t.start)
                if o > 0 { overlap[t.speaker, default: 0] += o }
            }
            guard let best = overlap.max(by: { $0.value < $1.value })?.key else { return seg }
            if order[best] == nil { order[best] = order.count + 1 }
            var s = seg
            s.speaker = "Voice \(order[best]!)"
            return s
        }
    }
}
