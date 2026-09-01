import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var model: ModelManager

    @AppStorage(Settings.systemDeviceIDKey) private var systemID: String = ""
    @AppStorage(Settings.micDeviceIDKey) private var micID: String = ""
    @AppStorage(Settings.keepAudioKey) private var keepAudio: Bool = false
    @AppStorage(Settings.notesDirKey) private var notesDirPath: String = ""
    @State private var name: String = ""

    private var whisperFound: Bool { Transcriber.findWhisper() != nil }
    private var ready: Bool { whisperFound && model.present && !(systemID.isEmpty && micID.isEmpty) }
    private var folderDisplay: String {
        let p = Settings.notesDir.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TextField("Meeting name (used in the file name)", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(recorder.isBusy)
                .onSubmit { if !recorder.isBusy && ready { startRecording() } }

            Picker("Meet audio", selection: $systemID) {
                Text("None").tag("")
                ForEach(recorder.devices, id: \.uniqueID) { d in
                    Text(d.localizedName).tag(d.uniqueID)
                }
            }
            .disabled(recorder.isBusy)
            .help("The virtual device carrying the other participants (BlackHole). See Audio setup.")

            Picker("Your mic", selection: $micID) {
                Text("None").tag("")
                ForEach(recorder.devices, id: \.uniqueID) { d in
                    Text(d.localizedName).tag(d.uniqueID)
                }
            }
            .disabled(recorder.isBusy)

            if systemID.isEmpty {
                Text("No Meet audio device: only your mic will be captured and the transcript will not be split into You / Others.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text("Folder").foregroundStyle(.secondary)
                Text(folderDisplay).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…", action: chooseFolder).disabled(recorder.isBusy)
            }

            Toggle("Keep audio file after transcribing", isOn: $keepAudio)
                .toggleStyle(.checkbox)

            Divider()
            mainButton
            statusLine
            Divider()
            readiness
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            recorder.refreshDevices()
            model.refresh()
            let ids = Set(recorder.devices.map { $0.uniqueID })
            if systemID.isEmpty || !ids.contains(systemID) {
                systemID = AudioDevices.preferredSystem(from: recorder.devices)?.uniqueID ?? ""
            }
            if micID.isEmpty || !ids.contains(micID) {
                micID = AudioDevices.preferredMic(from: recorder.devices)?.uniqueID ?? ""
            }
        }
    }

    private var header: some View {
        HStack {
            Text("MeetNotes").font(.headline)
            Spacer()
            Button { recorder.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Rescan audio devices")
        }
    }

    @ViewBuilder private var mainButton: some View {
        switch recorder.state {
        case .recording:
            Button(action: recorder.stop) {
                Label("Stop & transcribe  ·  \(elapsedText)", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .tint(.red)
        case .transcribing:
            HStack { ProgressView().controlSize(.small); Text("Transcribing… this can take a few minutes") }
                .frame(maxWidth: .infinity)
        default:
            Button(action: startRecording) {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(!ready)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch recorder.state {
        case .done(let url):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
            }.font(.caption)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .recording:
            Text("Say at the top of the call that you're taking notes.").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(ok: whisperFound, ok_text: "whisper-cli found",
                bad_text: "whisper-cli missing — run `brew install whisper-cpp`")
            if model.present {
                row(ok: true, ok_text: "Model ready (\(Settings.modelLabel))", bad_text: "")
            } else if let p = model.progress {
                HStack { ProgressView(value: p).controlSize(.small); Text("\(Int(p * 100))%").font(.caption).monospacedDigit() }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle").foregroundStyle(.orange)
                    Text("Model missing").font(.caption)
                    Button("Download (1.6 GB)") { model.download() }.buttonStyle(.link).font(.caption)
                }
            }
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func row(ok: Bool, ok_text: String, bad_text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle" : "xmark.circle").foregroundStyle(ok ? .green : .orange)
            Text(ok ? ok_text : bad_text).font(.caption).textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open folder") { openFolder() }
            Button("Vocabulary") { Settings.ensureVocabularyFile(); NSWorkspace.shared.open(Settings.vocabularyURL) }
            Button("Audio setup") { openAudioSetup() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private var elapsedText: String {
        let t = Int(recorder.elapsed)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }

    private func startRecording() {
        recorder.start(systemID: systemID.isEmpty ? nil : systemID, micID: micID.isEmpty ? nil : micID, name: name)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: Settings.notesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.notesDir)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.notesDir
        panel.prompt = "Use folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.notesDir = url
            notesDirPath = url.path
        }
    }

    private func openAudioSetup() {
        let alert = NSAlert()
        alert.messageText = "Capture Meet audio + your mic"
        alert.informativeText = """
        Your mic is captured directly. Meet's audio comes out of your speakers, so it needs a virtual \
        device that mirrors the system output. One-time setup:

        1. Install BlackHole:  brew install --cask blackhole-2ch   (then reboot)
        2. Open Audio MIDI Setup, click + → Create Multi-Output Device. Tick your speakers/headphones \
        and BlackHole 2ch. Set it as the system output in the sound menu.
        3. Back in MeetNotes, hit ↻ and pick BlackHole 2ch as "Meet audio" and your microphone as "Your mic".

        Volume keys don't work on a Multi-Output Device; set the level before switching. Headphones keep \
        your mic track clean, which makes the You / Others split more accurate.
        """
        alert.addButton(withTitle: "Open Audio MIDI Setup")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Utilities/Audio MIDI Setup.app"))
        }
    }
}
