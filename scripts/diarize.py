#!/usr/bin/env python3
"""Offline speaker diarization with sherpa-onnx.

usage: diarize.py FILE.wav [NUM_SPEAKERS]
FILE must be 16 kHz mono 16-bit PCM. Prints JSON: [{"start": s, "end": s, "speaker": n}, ...]
NUM_SPEAKERS defaults to -1 (estimate from the audio).
"""
import json
import os
import sys
import wave

import numpy as np
import sherpa_onnx

ROOT = os.path.expanduser("~/.meetnotes/models")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]
    num_speakers = int(sys.argv[2]) if len(sys.argv) > 2 else -1
    threshold = float(os.environ.get("MEETNOTES_DIARIZE_THRESHOLD", "0.5"))

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=os.path.join(ROOT, "sherpa-onnx-pyannote-segmentation-3-0", "model.onnx")
            ),
            num_threads=max(2, (os.cpu_count() or 4) - 2),
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=os.path.join(ROOT, "nemo_en_titanet_small.onnx"),
            num_threads=max(2, (os.cpu_count() or 4) - 2),
        ),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=num_speakers, threshold=threshold),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    if not config.validate():
        print("invalid diarization config (models missing?)", file=sys.stderr)
        return 1
    sd = sherpa_onnx.OfflineSpeakerDiarization(config)

    with wave.open(path) as w:
        if w.getnchannels() != 1 or w.getframerate() != sd.sample_rate or w.getsampwidth() != 2:
            print(f"expected 16 kHz mono 16-bit, got {w.getnchannels()}ch {w.getframerate()}Hz", file=sys.stderr)
            return 1
        data = w.readframes(w.getnframes())
    samples = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0

    result = sd.process(samples).sort_by_start_time()
    print(json.dumps([{"start": r.start, "end": r.end, "speaker": r.speaker} for r in result]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
