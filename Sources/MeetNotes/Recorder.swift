import AVFoundation
import AppKit

enum RecorderError: LocalizedError {
    case noDevice, micDenied, cannotAdd(String)
    var errorDescription: String? {
        switch self {
        case .noDevice: return "Pick at least one input device."
        case .micDenied: return "Microphone access denied. Allow MeetNotes in System Settings → Privacy & Security → Microphone."
        case .cannotAdd(let n): return "Could not attach input \"\(n)\"."
        }
    }
}

final class Recorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case done(URL)
        case failed(String)
    }

    /// One capture track: a device recorded to its own file.
    private struct Track {
        let device: AVCaptureDevice
        let output: AVCaptureAudioFileOutput
        let url: URL
        let role: Role
        enum Role { case others, you, single }
    }

    @Published var state: State = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var devices: [AVCaptureDevice] = []

    private var session: AVCaptureSession?
    private var tracks: [Track] = []
    private var finished: [URL: Error?] = [:]
    private var timer: Timer?
    private var startDate = Date()
    private var meetingName = ""

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .recording || state == .transcribing }

    func refreshDevices() { devices = AudioDevices.inputs() }

    /// `systemID` is the device carrying Meet's output (BlackHole); `micID` is your microphone. Either may be nil.
    func start(systemID: String?, micID: String?, name: String) {
        guard !isBusy else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { self.state = .failed(RecorderError.micDenied.localizedDescription); return }
                do { try self.begin(systemID: systemID, micID: micID, name: name) }
                catch { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func begin(systemID: String?, micID: String?, name: String) throws {
        refreshDevices()
        let sys = devices.first { $0.uniqueID == systemID }
        var mic = devices.first { $0.uniqueID == micID }
        if let s = sys, let m = mic, s.uniqueID == m.uniqueID { mic = nil }

        var plan: [(AVCaptureDevice, Track.Role)] = []
        switch (sys, mic) {
        case (let s?, let m?): plan = [(s, .others), (m, .you)]
        case (let s?, nil):    plan = [(s, .single)]
        case (nil, let m?):    plan = [(m, .single)]
        case (nil, nil):       throw RecorderError.noDevice
        }

        let dir = Settings.notesDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Settings.ensureVocabularyFile()
        startDate = Date()
        meetingName = name
        let base = Naming.base(date: startDate, name: name)

        let s = AVCaptureSession()
        s.beginConfiguration()
        var built: [Track] = []
        for (device, role) in plan {
            let input = try AVCaptureDeviceInput(device: device)
            let out = AVCaptureAudioFileOutput()
            out.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            guard s.canAddInput(input), s.canAddOutput(out) else { throw RecorderError.cannotAdd(device.localizedName) }
            // Manual wiring so each input feeds only its own file output.
            s.addInputWithNoConnections(input)
            s.addOutputWithNoConnections(out)
            let ports = input.ports.filter { $0.mediaType == .audio }
            let conn = AVCaptureConnection(inputPorts: ports, output: out)
            guard s.canAddConnection(conn) else { throw RecorderError.cannotAdd(device.localizedName) }
            s.addConnection(conn)

            let suffix: String
            switch role { case .others: suffix = "-others"; case .you: suffix = "-you"; case .single: suffix = "" }
            let url = dir.appendingPathComponent(base + suffix + ".wav")
            try? FileManager.default.removeItem(at: url)
            built.append(Track(device: device, output: out, url: url, role: role))
        }
        s.commitConfiguration()
        s.startRunning()
        for t in built { t.output.startRecording(to: t.url, outputFileType: .wav, recordingDelegate: self) }

        session = s
        tracks = built
        finished = [:]
        elapsed = 0
        state = .recording
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(self.startDate)
        }
    }

    func stop() {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        state = .transcribing
        for t in tracks { t.output.stopRecording() }
    }

    private func trackFinished(url: URL, error: Error?) {
        finished[url] = error
        guard finished.count == tracks.count else { return }
        session?.stopRunning()
        session = nil

        for (_, e) in finished {
            if let e {
                let ok = (e as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
                if !ok { state = .failed(e.localizedDescription); return }
            }
        }
        transcribe()
    }

    private func transcribe() {
        let tracks = self.tracks
        let keep = Settings.keepAudio
        let mdURL = Settings.notesDir
            .appendingPathComponent(Naming.base(date: startDate, name: meetingName))
            .appendingPathExtension("md")
        let meta = NoteMetadata(
            title: meetingName.trimmingCharacters(in: .whitespaces).isEmpty ? "Meeting" : meetingName,
            start: startDate,
            duration: Date().timeIntervalSince(startDate),
            device: tracks.map { $0.device.localizedName }.joined(separator: " + "),
            audioFiles: keep ? tracks.map { $0.url.lastPathComponent } : []
        )
        let prompt = Settings.vocabulary()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let segments: [Segment]
                if let o = tracks.first(where: { $0.role == .others }), let y = tracks.first(where: { $0.role == .you }) {
                    segments = try Transcriber.transcribe(others: o.url, you: y.url, prompt: prompt)
                } else {
                    segments = try Transcriber.transcribe(wav: tracks[0].url, prompt: prompt)
                }
                let md = MarkdownFormatter.render(meta: meta, segments: segments)
                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                if !keep { for t in tracks { try? FileManager.default.removeItem(at: t.url) } }
                DispatchQueue.main.async {
                    self.state = .done(mdURL)
                    NSWorkspace.shared.open(mdURL)
                }
            } catch {
                // Keep the audio on failure so nothing is lost; it can be re-run with --transcribe.
                DispatchQueue.main.async {
                    self.state = .failed(error.localizedDescription + "\nAudio kept in the notes folder.")
                }
            }
        }
    }
}

extension Recorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.trackFinished(url: outputFileURL, error: error) }
    }
}
