import SwiftUI

struct MeetNotesApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var model = ModelManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView(recorder: recorder, model: model)
        } label: {
            switch recorder.state {
            case .recording:
                HStack(spacing: 3) {
                    Image(systemName: "record.circle.fill")
                    Text(shortElapsed).monospacedDigit()
                }
            case .transcribing:
                Image(systemName: "ellipsis.circle")
            default:
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var shortElapsed: String {
        let t = Int(recorder.elapsed)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}
