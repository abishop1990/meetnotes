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

enum Diarizer {
    static let you = "You"
    static let others = "Others"

    /// Attribute each whisper segment to whichever track was louder over its span. Near-silent segments
    /// (whisper hallucinating on a pause) inherit the previous speaker rather than flipping.
    static func label(_ segments: [Segment], others: [Float], you: [Float], binMs: Int) -> [Segment] {
        // noise floor: 2x the median bin energy of the quieter track, with a small absolute floor
        func floor(_ e: [Float]) -> Float {
            guard !e.isEmpty else { return 0.002 }
            let s = e.sorted(); return max(0.002, s[s.count / 2] * 2)
        }
        let floorO = floor(others), floorY = floor(you)
        var last = Diarizer.others
        return segments.map { seg in
            var s = seg
            let lo = max(0, seg.fromMs / binMs), hi = max(lo + 1, seg.toMs / binMs)
            func mean(_ e: [Float]) -> Float {
                let r = lo..<min(hi, e.count)
                return r.isEmpty ? 0 : e[r].reduce(0, +) / Float(r.count)
            }
            let eo = mean(others), ey = mean(you)
            let oSpeaking = eo > floorO, ySpeaking = ey > floorY
            switch (oSpeaking, ySpeaking) {
            case (true, false): last = Diarizer.others
            case (false, true): last = Diarizer.you
            case (true, true): last = ey > eo * 1.5 ? Diarizer.you : Diarizer.others
            case (false, false): break
            }
            s.speaker = last
            return s
        }
    }
}
