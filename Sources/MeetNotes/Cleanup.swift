import Foundation

/// Whisper's decoder sometimes locks onto a phrase and emits it over and over ("I'm going to look at it."
/// fourteen times). Collapse those runs after decoding; the timestamps of the first occurrence are kept.
enum Cleanup {
    struct Report { var droppedSegments = 0; var collapsedLoops = 0 }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // A phrase of 2–8 words followed by itself two or more times (three or more occurrences total).
    // Single words are left alone: "no, no, no" is emphasis, not a decoder loop.
    private static let loop = try! NSRegularExpression(
        pattern: "\\b((?:[\\w'’-]+[ ,]+){1,7}[\\w'’-]+[.,!?]?)(?:\\s+\\1){2,}", options: [.caseInsensitive])

    static func collapseLoops(_ text: String) -> (String, Int) {
        var s = text
        var n = 0
        // repeat until stable: collapsing an inner loop can expose an outer one
        while true {
            let range = NSRange(s.startIndex..., in: s)
            guard let m = loop.firstMatch(in: s, range: range), let r = Range(m.range, in: s),
                  let keep = Range(m.range(at: 1), in: s) else { break }
            s.replaceSubrange(r, with: String(s[keep]))
            n += 1
        }
        return (s, n)
    }

    static func dedupe(_ segments: [Segment]) -> ([Segment], Report) {
        var out: [Segment] = []
        var rep = Report()
        var prevKey = ""
        for var seg in segments {
            let (t, n) = collapseLoops(seg.text)
            rep.collapsedLoops += n
            seg = Segment(fromMs: seg.fromMs, toMs: seg.toMs, text: t, speaker: seg.speaker)
            let key = normalize(t)
            // identical text back-to-back is a loop across segments, unless it is a very short interjection
            if !key.isEmpty, key == prevKey, key.count > 12 {
                rep.droppedSegments += 1
                continue
            }
            prevKey = key
            out.append(seg)
        }
        return (out, rep)
    }
}
