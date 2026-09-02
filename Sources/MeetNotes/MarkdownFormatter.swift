import Foundation

struct NoteMetadata {
    let title: String
    let start: Date
    let duration: TimeInterval
    let device: String
    let audioFiles: [String]   // empty when the recordings were deleted
}

enum MarkdownFormatter {
    /// Segments are 2–10 s whisper chunks; merge them into readable paragraphs and drop noise markers.
    struct Paragraph { let startMs: Int; let speaker: String?; let text: String }

    static func paragraphs(_ segments: [Segment]) -> [Paragraph] {
        var out: [Paragraph] = []
        var curStart = 0
        var curSpeaker: String? = nil
        var cur = ""
        var lastEnd = 0
        let gapMs = 1500
        let softLimit = 700

        for s in segments {
            let t = clean(s.text)
            if t.isEmpty { continue }
            let gap = s.fromMs - lastEnd
            let endsSentence = cur.last.map { ".?!".contains($0) } ?? false
            let speakerChanged = s.speaker != curSpeaker
            if !cur.isEmpty && (speakerChanged || gap > gapMs || (cur.count > softLimit && endsSentence)) {
                out.append(Paragraph(startMs: curStart, speaker: curSpeaker, text: cur))
                cur = ""
            }
            if cur.isEmpty { curStart = s.fromMs; curSpeaker = s.speaker }
            cur = cur.isEmpty ? t : cur + " " + t
            lastEnd = s.toMs
        }
        if !cur.isEmpty { out.append(Paragraph(startMs: curStart, speaker: curSpeaker, text: cur)) }
        return out
    }

    struct SpeakerStat { let name: String; let seconds: Double; let firstMs: Int }

    /// Talk time per label, in order of first appearance. Empty when nothing was labelled.
    static func speakerSummary(_ segments: [Segment]) -> [SpeakerStat] {
        var order: [String] = []
        var secs: [String: Double] = [:]
        var first: [String: Int] = [:]
        for s in segments {
            guard let sp = s.speaker, !clean(s.text).isEmpty else { continue }
            if first[sp] == nil { first[sp] = s.fromMs; order.append(sp) }
            secs[sp, default: 0] += Double(s.toMs - s.fromMs) / 1000
        }
        return order.map { SpeakerStat(name: $0, seconds: secs[$0] ?? 0, firstMs: first[$0] ?? 0) }
    }

    static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // whisper emits markers like [BLANK_AUDIO], (silence), [Music] on quiet stretches
        if let f = t.first, let l = t.last, "[(".contains(f), "])".contains(l) { return "" }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t
    }

    static func stamp(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func duration(_ d: TimeInterval) -> String {
        let mins = Int(d.rounded()) / 60
        if mins < 1 { return "\(Int(d.rounded())) s" }
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60) h \(mins % 60) min"
    }

    static func render(meta: NoteMetadata, segments: [Segment], diagnostics: [String] = []) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy · HH:mm zzz"

        var md = "# \(meta.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Meeting" : meta.title)\n\n"
        md += "- **Date**: \(df.string(from: meta.start))\n"
        md += "- **Duration**: \(duration(meta.duration))\n"
        md += "- **Input**: \(meta.device)\n"
        if !meta.audioFiles.isEmpty { md += "- **Audio**: " + meta.audioFiles.map { "`\($0)`" }.joined(separator: ", ") + "\n" }
        md += "- **Transcribed by**: \(Settings.modelLabel), on-device\n\n"

        md += "## Specs & decisions to confirm\n\n- [ ] \n\n"
        md += "## Action items\n\n- [ ] \n\n"
        if !diagnostics.isEmpty {
            md += "<details><summary>Diagnostics</summary>\n\n"
            for d in diagnostics { md += "- \(d)\n" }
            md += "\n</details>\n\n"
        }

        let paras = paragraphs(segments)
        let speakers = speakerSummary(segments)
        if !speakers.isEmpty {
            md += "## Speakers\n\n"
            for sp in speakers {
                md += "- **\(sp.name)** — \(duration(sp.seconds)), first at \(stamp(sp.firstMs))\n"
            }
            md += "\n_Rename the Voice N labels once you know who is who. \"You\" is your microphone; " +
                  "\"Others\" is remote speech the separator could not attribute._\n\n"
        }

        md += "## Transcript\n\n"

        if paras.isEmpty {
            md += "_No speech detected._\n"
        } else {
            for p in paras {
                let who = p.speaker.map { " \($0):" } ?? ""
                md += "**[\(stamp(p.startMs))]\(who)** \(p.text)\n\n"
            }
        }
        return md
    }
}
