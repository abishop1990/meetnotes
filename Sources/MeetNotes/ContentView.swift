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
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var launchError: String? = nil
    @State private var route = SystemOutput.status()
    @State private var diarInstalled = Diarization.isInstalled
    @State private var diarInstalling = false
    @State private var diarError: String? = nil
    @AppStorage(Diarization.enabledKey) private var diarEnabled: Bool = true
    @State private var routeError: String? = nil

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
            } else {
                routingRow
            }

            HStack(spacing: 6) {
                Text("Folder").foregroundStyle(.secondary)
                Text(folderDisplay).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…", action: chooseFolder).disabled(recorder.isBusy)
            }

            Toggle("Keep audio file after transcribing", isOn: $keepAudio)
                .toggleStyle(.checkbox)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, on in
                    do { try LaunchAtLogin.set(on); launchError = nil }
                    catch { launchError = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                }
            if let e = launchError { Text(e).font(.caption).foregroundStyle(.red) }

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
            launchAtLogin = LaunchAtLogin.isEnabled
            route = SystemOutput.status()
            diarInstalled = Diarization.isInstalled
            let ids = Set(recorder.devices.map { $0.uniqueID })
            if systemID.isEmpty || !ids.contains(systemID) {
                systemID = AudioDevices.preferredSystem(from: recorder.devices)?.uniqueID ?? ""
            }
            if micID.isEmpty || !ids.contains(micID) {
                micID = AudioDevices.preferredMic(from: recorder.devices)?.uniqueID ?? ""
            }
        }
    }

    /// System output must go through BlackHole or the Meet track records silence.
    private var routingRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: route.routed ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(route.routed ? .green : .orange)
                Text(route.routed ? "System output → \(route.outputName) (BlackHole hears the call)"
                                  : "System output is \(route.outputName): BlackHole hears nothing")
                    .font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if route.blackHoleInstalled {
                    Button(route.routed ? "Restore" : "Route via BlackHole") {
                        do {
                            if route.routed { try SystemOutput.restore() } else { try SystemOutput.route() }
                            routeError = nil
                        } catch { routeError = error.localizedDescription }
                        route = SystemOutput.status()
            diarInstalled = Diarization.isInstalled
                    }
                    .controlSize(.small)
                    .disabled(recorder.isBusy)
                }
            }
            if let e = routeError { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func meter(_ label: String, _ db: Float?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            ProgressView(value: Double(max(0, min(1, ((db ?? -60) + 60) / 60))))
                .tint((db ?? -60) > -50 ? .green : .orange)
            Text(db.map { String(format: "%.0f dB", $0) } ?? "—").font(.caption).monospacedDigit().frame(width: 48, alignment: .trailing)
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
            VStack(alignment: .leading, spacing: 4) {
                if !systemID.isEmpty { meter("Meet", recorder.meetLevel) }
                if !micID.isEmpty { meter("Mic", recorder.micLevel) }
                if recorder.meetSilent {
                    Text("No audio on the Meet track. System output is not going through BlackHole; use Route via BlackHole and restart the recording.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Say at the top of the call that you're taking notes.").font(.caption).foregroundStyle(.secondary)
                }
            }
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
            diarizationRow
        }
    }

    @ViewBuilder private var diarizationRow: some View {
        if diarInstalled {
            Toggle("Separate remote voices (Voice 1, Voice 2, …)", isOn: $diarEnabled)
                .toggleStyle(.checkbox).font(.caption)
        } else if diarInstalling {
            HStack { ProgressView().controlSize(.small); Text("Installing speaker separation (pip + ~50 MB models)…").font(.caption) }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Speaker separation not installed").font(.caption)
                if Diarization.setupScript != nil {
                    Button("Install") { installDiarization() }.buttonStyle(.link).font(.caption)
                }
            }
        }
        if let e = diarError { Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
    }

    private func installDiarization() {
        guard let script = Diarization.setupScript else { return }
        diarInstalling = true; diarError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = try? Shell.run("/bin/bash", [script.path])
            DispatchQueue.main.async {
                diarInstalling = false
                diarInstalled = Diarization.isInstalled
                if !diarInstalled { diarError = "Install failed:\n" + String((r?.output ?? "could not run script").suffix(400)) }
            }
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
        device that mirrors the system output.

        1. Install BlackHole once:  brew install --cask blackhole-2ch   (then reboot)
        2. Pick BlackHole 2ch as "Meet audio" and your microphone as "Your mic".
        3. Press "Route via BlackHole". MeetNotes creates a Multi-Output Device (your speakers + BlackHole) \
        and makes it the system output. "Restore" switches back. You can also do this by hand in Audio MIDI Setup.

        Volume keys don't work while a Multi-Output Device is selected; set the level first. Headphones keep \
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
