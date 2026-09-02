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
- Audio files are kept next to the note by default (untick *Keep audio* to delete them after a successful
  transcription). Keeping them is what makes re-running speaker separation with other settings possible.
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
.build/release/MeetNotes --diarize meeting-others.wav
.build/release/MeetNotes --transcribe meeting-others.wav --mic meeting-you.wav --name "Design review"
.build/release/MeetNotes --transcribe meeting.wav --name "Standup"
```

## Speaker identification

Whisper transcribes; it does not identify voices. Two layers add that:

1. **You / Others** comes for free from recording the two inputs as separate tracks and attributing each
   segment to the louder one.
2. **Voice 1, Voice 2, …** on the remote side comes from an optional offline diarization pass
   (sherpa-onnx: pyannote segmentation-3.0 + NeMo TitaNet speaker embeddings). Install it with the
   *Install* link in the popover or:

   ```bash
   scripts/setup-diarization.sh     # venv + models under ~/.meetnotes, ~50 MB, offline afterwards
   ```

   The note then opens with a **Speakers** section (talk time and first appearance per voice) so the labels
   can be renamed in one pass, by hand or by handing the file to an LLM with the attendee list. Remote speech
   the separator could not place stays labelled *Others*; voices with under 8 s of speech are folded into
   *Others* too, since those are almost always fragments of someone already labelled.

   **Tuning.** Real calls over-split more than clean audio does. Two knobs:

   - *Max remote voices* in the popover caps the cluster count. Set it to the number of other people on the
     call. (sherpa-onnx treats it as a ceiling, not a target.)
   - The clustering threshold, default 0.7 (pyannote 3.1's tuned value); larger merges more. Set it with
     `defaults write com.alanbishop.meetnotes diarizationThreshold -float 0.8` or `--threshold` on the CLI.

   **Speakers instead of headphones.** The mic then hears a delayed copy of everyone else. The mix whisper
   gets is built per 100 ms slice: when one track is ~10 dB louder the other is muted for that slice, with a
   20 ms crossfade, so remote sentences reach whisper once, from the clean Meet track. Speaker separation
   already reads only the Meet track. Headphones still give the best result.

   **Repetition.** Whisper's decoder occasionally locks onto a phrase and repeats it many times. The app runs
   whisper with `--max-context 0` (the usual trigger is feeding the previous window's text back in) and then
   collapses any 2–8 word phrase repeated three or more times in a row, and drops back-to-back identical
   segments. Single-word repeats ("no, no, no") are left alone. The Diagnostics block reports what was cleaned.

   Every note ends its header with a collapsed **Diagnostics** block: per-track signal levels and what the
   separator did. Audio is kept by default so a note can be regenerated with different settings:

   ```bash
   .build/release/MeetNotes --transcribe X-others.wav --mic X-you.wav --name "X" --speakers 8 --threshold 0.8
   ```

## Requirements

macOS 14+, Apple Silicon recommended. `whisper-cpp` from Homebrew. The `large-v3-turbo` model is ~1.6 GB
and transcribes roughly 10x faster than real time on an M-series Mac.

## License

MIT

## Layout

- `Recorder.swift` — AVCaptureSession with one file output per input device
- `Diarization.swift` + `scripts/diarize.py` — optional sherpa-onnx speaker separation, Voice N attribution
- `SystemOutput.swift` — CoreAudio: multi-output device creation, default output switch/restore
- `AudioMix.swift` — echo-suppressing mix of the two tracks for whisper plus per-track energy profiles; `Diarizer` labels segments
- `Transcriber.swift` — afconvert normalisation, whisper-cli invocation, JSON parse
- `Cleanup.swift` — collapses whisper repetition loops
- `MarkdownFormatter.swift` — paragraphs, timestamps, speaker labels, note skeleton
- `ContentView.swift` / `MeetNotesApp.swift` — the menu bar popover
