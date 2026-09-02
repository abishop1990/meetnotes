import Foundation

enum Settings {
    static let notesDirKey = "notesDir"
    static let systemDeviceIDKey = "systemDeviceID"
    static let micDeviceIDKey = "micDeviceID"
    static let micNone = "none"
    static let keepAudioKey = "keepAudio"

    private static var d: UserDefaults { .standard }
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var notesDir: URL {
        get {
            if let p = d.string(forKey: notesDirKey), !p.isEmpty { return URL(fileURLWithPath: p) }
            return home.appendingPathComponent("MeetNotes")
        }
        set { d.set(newValue.path, forKey: notesDirKey) }
    }

    static var systemDeviceID: String? { d.string(forKey: systemDeviceIDKey) }
    static var micDeviceID: String? { d.string(forKey: micDeviceIDKey) }
    /// Default on: the recordings are what make re-running speaker separation with other settings possible.
    static var keepAudio: Bool { d.object(forKey: keepAudioKey) as? Bool ?? true }

    static let expectedSpeakersKey = "expectedSpeakers"
    static let diarizationThresholdKey = "diarizationThreshold"
    /// Ceiling on remote voices (sherpa-onnx treats num_clusters as a cap, not a target), nil = uncapped.
    static var expectedSpeakers: Int? {
        let n = d.integer(forKey: expectedSpeakersKey)
        return n > 0 ? n : nil
    }
    /// Clustering distance cutoff; larger merges more. 0.7 is the value pyannote 3.1 ships with.
    static var diarizationThreshold: Double {
        let t = d.double(forKey: diarizationThresholdKey)
        return t > 0 ? t : 0.7
    }

    static var modelURL: URL { home.appendingPathComponent(".whisper/ggml-large-v3-turbo.bin") }
    static let modelDownloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    static let modelLabel = "whisper.cpp large-v3-turbo"

    /// Domain vocabulary fed to whisper as the initial prompt. Lives next to the notes so it is easy to edit.
    static var vocabularyURL: URL { notesDir.appendingPathComponent("vocabulary.txt") }

    /// Placeholder shipped on first launch. The real list lives in vocabulary.txt in the notes folder, where
    /// product names, teammates, and ticket prefixes belong; whisper spells what it has already seen.
    static let defaultVocabulary = """
    Kubernetes, Prometheus, Grafana, PostgreSQL, pull request, acceptance criteria, sprint, on-call, \
    root cause, deployment, rollback.
    """

    static func vocabulary() -> String {
        if let s = try? String(contentsOf: vocabularyURL, encoding: .utf8) {
            let t = s.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return defaultVocabulary
    }

    static func ensureVocabularyFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: vocabularyURL.path) else { return }
        let body = """
        # One line or many; lines starting with # are ignored.
        # Whisper biases toward words listed here, so add anything it keeps getting wrong.
        \(defaultVocabulary)

        """
        try? body.write(to: vocabularyURL, atomically: true, encoding: .utf8)
    }
}

enum Naming {
    static func slug(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "meeting" }
        let allowed = CharacterSet.alphanumerics
        var out = ""
        var lastDash = false
        for scalar in trimmed.lowercased().unicodeScalars {
            if allowed.contains(scalar) { out.unicodeScalars.append(scalar); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "meeting"
            : out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 2026-09-01_1330-intent-api-review
    static func base(date: Date, name: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(f.string(from: date))-\(slug(name))"
    }
}
