#!/usr/bin/env python3
"""Offline speaker diarization with sherpa-onnx.

usage: diarize.py FILE.wav [--speakers N] [--threshold T]
FILE must be 16 kHz mono 16-bit PCM. Prints JSON: [{"start": s, "end": s, "speaker": n}, ...]
--speakers   ceiling on the number of speakers (sherpa-onnx treats it as a cap), -1 (default) = none
--threshold  clustering distance cutoff used when estimating; larger merges more (default 0.7)
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
    args = sys.argv[1:]
    path = args[0]
    num_speakers = int(args[args.index("--speakers") + 1]) if "--speakers" in args else -1
    threshold = float(args[args.index("--threshold") + 1]) if "--threshold" in args else 0.7

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
        # keep segmentation at its defaults; fragment clusters are folded away downstream instead
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
