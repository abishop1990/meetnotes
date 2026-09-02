# MeetNotes

Menu bar app that records a meeting from your Mac and writes a Markdown transcript, entirely on-device
(whisper.cpp). No bots join the call, nothing leaves the machine.

Tell people at the top of the call that you're taking notes. Recording-consent law varies by state and
country, and most employers have a policy; this tool does nothing to hide itself, and you shouldn't either.

## What it does

- Type a meeting name, hit **Start**. The menu bar shows a red dot and the elapsed time.
- **Stop & transcribe** writes `<folder>/YYYY-MM-DD_HHMM-<name>.md` and opens it.
- Two inputs are captured as separate tracks: the Meet audio (via BlackHole) and your mic. The transcript
  labels paragraphs **You** / **Others** from which track carried the sound. Whisper cannot tell remote
  voices apart from each other.
- Audio files are deleted after a successful transcription unless *Keep audio file* is ticked. On a failure
  they are always kept so nothing is lost; re-run with the CLI below.
- *Launch at login* in the popover registers the app as a login item (System Settings → General → Login Items).
- `vocabulary.txt` in the notes folder is fed to whisper as a bias prompt. Add any term it keeps mangling.

## Setup (once)

```bash
brew install whisper-cpp                 # transcription engine (done)
brew install --cask blackhole-2ch        # virtual audio device, needs your password, then reboot
```

Model: `~/.whisper/ggml-large-v3-turbo.bin` (the app offers a download button if it is missing).

After the reboot, in MeetNotes pick *BlackHole 2ch* as **Meet audio** and your microphone as **Your mic**, then
press **Route via BlackHole**. The app creates a Multi-Output Device (your speakers + BlackHole) and makes it the
system output, so you keep hearing the call while BlackHole gets a copy. **Restore** switches back. The same thing
can be done by hand in Audio MIDI Setup.

While recording, the popover shows live levels for both tracks and warns if the Meet track is silent. Segments
whisper produces over silence (its "Thank you." hallucination) are dropped.

Without BlackHole the app still works with the mic alone, but the transcript is not split into You / Others
and only your side is captured unless you use speakers.

## Build

```bash
./make-app.sh        # → ~/Applications/MeetNotes.app (Command Line Tools are enough, no Xcode project)
```

## CLI

```bash
.build/release/MeetNotes --list-devices
.build/release/MeetNotes --route-output on|off|status
.build/release/MeetNotes --transcribe meeting-others.wav --mic meeting-you.wav --name "Design review"
.build/release/MeetNotes --transcribe meeting.wav --name "Standup"
```

## Speaker identification

Whisper transcribes; it does not identify voices. The You / Others split comes from recording the two
inputs as separate tracks and attributing each segment to the louder one. Telling remote participants
apart would need a diarization model on the Meet track (pyannote or sherpa-onnx); not built yet.

## Requirements

macOS 14+, Apple Silicon recommended. `whisper-cpp` from Homebrew. The `large-v3-turbo` model is ~1.6 GB
and transcribes roughly 10x faster than real time on an M-series Mac.

## License

MIT

## Layout

- `Recorder.swift` — AVCaptureSession with one file output per input device
- `SystemOutput.swift` — CoreAudio: multi-output device creation, default output switch/restore
- `AudioMix.swift` — sums the two tracks for whisper and keeps a per-track energy profile; `Diarizer` labels segments
- `Transcriber.swift` — afconvert normalisation, whisper-cli invocation, JSON parse
- `MarkdownFormatter.swift` — paragraphs, timestamps, speaker labels, note skeleton
- `ContentView.swift` / `MeetNotesApp.swift` — the menu bar popover
