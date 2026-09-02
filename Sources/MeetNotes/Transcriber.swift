import Foundation

struct Segment {
    let fromMs: Int
    let toMs: Int
    let text: String
    var speaker: String? = nil
}

enum TranscriberError: LocalizedError {
    case whisperMissing
    case modelMissing
    case toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .whisperMissing: return "whisper-cli not found. Run: brew install whisper-cpp"
        case .modelMissing: return "Whisper model not downloaded yet."
        case .toolFailed(let tool, let out): return "\(tool) failed:\n\(out.suffix(600))"
        }
    }
}

enum Transcriber {
    static let whisperCandidates = [
        "/opt/homebrew/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cli", "/usr/local/bin/whisper-cpp",
    ]

    static func findWhisper() -> String? {
        whisperCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var modelPresent: Bool { FileManager.default.fileExists(atPath: Settings.modelURL.path) }

    /// whisper needs 16 kHz mono; afconvert ships with macOS and handles any input the recorder produced.
    static func normalize(_ wav: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetnotes-\(UUID().uuidString).wav")
        let r = try Shell.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", wav.path, out.path])
        guard r.status == 0 else { throw TranscriberError.toolFailed("afconvert", r.output) }
        return out
    }

    /// Single recording: no speaker labels.
    static func transcribe(wav: URL, prompt: String?) throws -> [Segment] {
        let norm = try normalize(wav)
        defer { try? FileManager.default.removeItem(at: norm) }
        let segments = try runWhisper(on: norm, prompt: prompt)
        let energy = try AudioMix.energyProfile(norm)
        let kept = Diarizer.dropSilent(segments, energy: energy, binMs: AudioMix.binMs)
        return try separateVoices(kept, remoteTrack: norm)
    }

    /// Two recordings made side by side (Meet output + your mic): transcribe the mix once, then label each
    /// segment "You" or "Others" by which track carried the energy.
    static func transcribe(others: URL, you: URL, prompt: String?) throws -> [Segment] {
        let a = try normalize(others)
        let b = try normalize(you)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let mixed = try AudioMix.mixToMono(a, b)
        defer { try? FileManager.default.removeItem(at: mixed.url) }

        let segments = try runWhisper(on: mixed.url, prompt: prompt)
        let labelled = Diarizer.label(segments, others: mixed.energyA, you: mixed.energyB, binMs: AudioMix.binMs)
        return try separateVoices(labelled, remoteTrack: a)
    }

    /// Optional pass: split the remote side into Voice 1..N when the diarization stack is installed.
    /// A diarizer failure is reported, not swallowed, but only after the transcript itself succeeded.
    private static func separateVoices(_ segments: [Segment], remoteTrack: URL) throws -> [Segment] {
        guard Diarization.isInstalled, Diarization.isEnabled else { return segments }
        let turns = try Diarization.run(wav16k: remoteTrack)
        return Diarization.attribute(segments, turns: turns)
    }

    private static func runWhisper(on wav16k: URL, prompt: String?) throws -> [Segment] {
        guard let whisper = findWhisper() else { throw TranscriberError.whisperMissing }
        guard modelPresent else { throw TranscriberError.modelMissing }

        let outBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetnotes-\(UUID().uuidString)")
        let jsonURL = outBase.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        var args = [
            "-m", Settings.modelURL.path, "-f", wav16k.path, "-l", "en",
            "-t", String(threads), "-np", "-oj", "-of", outBase.path,
        ]
        if let prompt, !prompt.isEmpty { args += ["--prompt", prompt] }

        let r = try Shell.run(whisper, args)
        guard r.status == 0, FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw TranscriberError.toolFailed("whisper-cli", r.output)
        }
        return try parse(json: Data(contentsOf: jsonURL))
    }

    private struct WhisperJSON: Decodable {
        struct Item: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Item]
    }

    static func parse(json: Data) throws -> [Segment] {
        let root = try JSONDecoder().decode(WhisperJSON.self, from: json)
        return root.transcription.map { Segment(fromMs: $0.offsets.from, toMs: $0.offsets.to, text: $0.text) }
    }
}
