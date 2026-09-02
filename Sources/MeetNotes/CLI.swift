import Foundation
import AVFoundation

/// Headless entry points, mainly so the pipeline can be tested without clicking through the UI.
enum CLI {
    static let usage = """
    MeetNotes CLI
      --list-devices                 print audio input devices
      --transcribe FILE.wav [--mic YOU.wav] [--name NAME]
                                     transcribe an existing recording to FILE.md next to it;
                                     with --mic, FILE is the Meet track and segments get You/Others labels
      --launch-at-login on|off|status  register the .app as a login item (run via the installed bundle)
      --md-from-json FILE.json [--name NAME]
                                     render whisper JSON to markdown on stdout (formatter test)
    """

    static func run(_ args: [String]) -> Int32 {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let name = value(after: "--name") ?? "Meeting"

        switch args.first {
        case "--list-devices":
            for d in AudioDevices.inputs() { print("\(d.localizedName)\t\(d.uniqueID)") }
            return 0

        case "--transcribe":
            guard let path = value(after: "--transcribe") else { print(usage); return 2 }
            let wav = URL(fileURLWithPath: path)
            do {
                let started = Date()
                let segments: [Segment]
                var files = [wav.lastPathComponent]
                if let micPath = value(after: "--mic") {
                    let mic = URL(fileURLWithPath: micPath)
                    files.append(mic.lastPathComponent)
                    segments = try Transcriber.transcribe(others: wav, you: mic, prompt: Settings.vocabulary())
                } else {
                    segments = try Transcriber.transcribe(wav: wav, prompt: Settings.vocabulary())
                }
                let dur = segments.last.map { Double($0.toMs) / 1000 } ?? 0
                let meta = NoteMetadata(title: name, start: started, duration: dur, device: "file",
                                        audioFiles: files)
                let md = MarkdownFormatter.render(meta: meta, segments: segments)
                let out = wav.deletingPathExtension().appendingPathExtension("md")
                try md.write(to: out, atomically: true, encoding: .utf8)
                print(out.path)
                return 0
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                return 1
            }

        case "--launch-at-login":
            switch value(after: "--launch-at-login") {
            case "on":  do { try LaunchAtLogin.set(true) }  catch { print(error.localizedDescription); return 1 }
            case "off": do { try LaunchAtLogin.set(false) } catch { print(error.localizedDescription); return 1 }
            case "status": break
            default: print(usage); return 2
            }
            print("launch at login: \(LaunchAtLogin.statusText)")
            return 0

        case "--md-from-json":
            guard let path = value(after: "--md-from-json") else { print(usage); return 2 }
            do {
                let segments = try Transcriber.parse(json: Data(contentsOf: URL(fileURLWithPath: path)))
                let dur = segments.last.map { Double($0.toMs) / 1000 } ?? 0
                let meta = NoteMetadata(title: name, start: Date(), duration: dur, device: "test", audioFiles: [])
                print(MarkdownFormatter.render(meta: meta, segments: segments))
                return 0
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                return 1
            }

        default:
            print(usage)
            return 2
        }
    }
}
