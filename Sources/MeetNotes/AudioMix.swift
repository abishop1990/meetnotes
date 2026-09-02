import AVFoundation

/// Sums two 16 kHz mono tracks into one for whisper, and keeps a coarse per-track energy profile so segments
/// can be attributed afterwards. Streams in chunks so a two-hour meeting does not need gigabytes of RAM.
enum AudioMix {
    static let binMs = 100
    static let sampleRate = 16000.0

    struct Result {
        let url: URL
        let energyA: [Float]   // RMS per bin
        let energyB: [Float]
    }

    static func mixToMono(_ a: URL, _ b: URL) throws -> Result {
        let fa = try AVAudioFile(forReading: a)
        let fb = try AVAudioFile(forReading: b)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw TranscriberError.toolFailed("mixer", "bad format") }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("meetnotes-mix-\(UUID().uuidString).wav")
        let outFile = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let binFrames = Int(sampleRate) * binMs / 1000
        let chunk = AVAudioFrameCount(binFrames * 100)   // 10 s per read
        var energyA: [Float] = [], energyB: [Float] = []

        func read(_ f: AVAudioFile) throws -> AVAudioPCMBuffer? {
            guard f.framePosition < f.length else { return nil }
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
            try f.read(into: buf)
            return buf.frameLength > 0 ? buf : nil
        }

        while true {
            let ba = try read(fa)
            let bb = try read(fb)
            if ba == nil && bb == nil { break }
            let n = Int(max(ba?.frameLength ?? 0, bb?.frameLength ?? 0))
            let mix = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            mix.frameLength = AVAudioFrameCount(n)
            let pa = ba?.floatChannelData?[0], pb = bb?.floatChannelData?[0]
            let la = Int(ba?.frameLength ?? 0), lb = Int(bb?.frameLength ?? 0)
            let pm = mix.floatChannelData![0]
            for i in 0..<n {
                let x = i < la ? pa![i] : 0
                let y = i < lb ? pb![i] : 0
                pm[i] = max(-1, min(1, x + y))
            }
            try outFile.write(from: mix)

            var i = 0
            while i < n {
                let end = min(n, i + binFrames)
                var sa: Float = 0, sb: Float = 0
                for j in i..<end {
                    if j < la { sa += pa![j] * pa![j] }
                    if j < lb { sb += pb![j] * pb![j] }
                }
                let cnt = Float(end - i)
                energyA.append((sa / cnt).squareRoot())
                energyB.append((sb / cnt).squareRoot())
                i = end
            }
        }
        return Result(url: out, energyA: energyA, energyB: energyB)
    }
}

extension AudioMix {
    /// One-line level summary for the note's Diagnostics section: how much of the track had signal and how loud.
    static func describe(_ name: String, _ energy: [Float]) -> String {
        let active = energy.filter { $0 >= Diarizer.silenceRMS }
        guard !energy.isEmpty, !active.isEmpty else { return "\(name): silent" }
        let pct = Int((Double(active.count) / Double(energy.count) * 100).rounded())
        let avg = active.reduce(0, +) / Float(active.count)
        let peak = active.max() ?? avg
        let db = { (v: Float) in Int((20 * log10(max(v, 1e-6))).rounded()) }
        return "\(name): active \(pct)% of the time, avg \(db(avg)) dBFS, peak \(db(peak)) dBFS"
    }

    /// Per-bin RMS of one 16 kHz mono file.
    static func energyProfile(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { return [] }
        let binFrames = Int(sampleRate) * binMs / 1000
        var out: [Float] = []
        while f.framePosition < f.length {
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(binFrames * 100))!
            try f.read(into: buf)
            let n = Int(buf.frameLength); if n == 0 { break }
            let p = buf.floatChannelData![0]
            var i = 0
            while i < n {
                let end = min(n, i + binFrames)
                var sum: Float = 0
                for j in i..<end { sum += p[j] * p[j] }
                out.append((sum / Float(end - i)).squareRoot())
                i = end
            }
        }
        return out
    }
}

enum Diarizer {
    static let you = "You"
    static let others = "Others"
    /// RMS below this (about -54 dBFS) is treated as silence. Whisper reliably hallucinates short phrases
    /// like "Thank you." over silence, so segments with no energy on any track are dropped.
    static let silenceRMS: Float = 0.002

    static func meanEnergy(_ e: [Float], fromMs: Int, toMs: Int, binMs: Int) -> Float {
        let lo = max(0, fromMs / binMs), hi = max(lo + 1, toMs / binMs)
        let r = lo..<min(hi, e.count)
        return r.isEmpty ? 0 : e[r].reduce(0, +) / Float(r.count)
    }

    static func dropSilent(_ segments: [Segment], energy: [Float], binMs: Int) -> [Segment] {
        segments.filter { meanEnergy(energy, fromMs: $0.fromMs, toMs: $0.toMs, binMs: binMs) >= silenceRMS }
    }

    /// Attribute each whisper segment to whichever track carried it. The remote track is clean (Meet never
    /// plays your own mic back), so when you talk it is near silent; when others talk the mic hears at most a
    /// quiet echo through speakers. A fixed absolute floor plus a ratio is enough; no per-track statistics,
    /// which go wrong when one track is speech most of the time.
    static func label(_ segments: [Segment], others: [Float], you: [Float], binMs: Int) -> [Segment] {
        return segments.compactMap { seg in
            let eo = meanEnergy(others, fromMs: seg.fromMs, toMs: seg.toMs, binMs: binMs)
            let ey = meanEnergy(you, fromMs: seg.fromMs, toMs: seg.toMs, binMs: binMs)
            if eo < silenceRMS && ey < silenceRMS { return nil }
            var s = seg
            let youWins = ey >= silenceRMS && (eo < silenceRMS || ey > eo * 1.5)
            s.speaker = youWins ? Diarizer.you : Diarizer.others
            return s
        }
    }
}
