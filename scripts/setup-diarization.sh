#!/usr/bin/env bash
# Installs the optional speaker-separation stack into ~/.meetnotes:
#   venv with sherpa-onnx, pyannote segmentation-3.0 (ONNX) and a speaker-embedding model.
# Everything runs offline after this. Re-running is idempotent.
set -euo pipefail
ROOT="$HOME/.meetnotes"
PY="${PYTHON:-$(command -v python3.13 || command -v python3.12 || command -v python3)}"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$ROOT/models"
[ -x "$ROOT/venv/bin/python" ] || "$PY" -m venv "$ROOT/venv"
"$ROOT/venv/bin/pip" install --quiet --upgrade pip sherpa-onnx numpy

cd "$ROOT/models"
if [ ! -f sherpa-onnx-pyannote-segmentation-3-0/model.onnx ]; then
  curl -sSL -o seg.tar.bz2 "$BASE/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
  tar xjf seg.tar.bz2 && rm seg.tar.bz2
fi
[ -f nemo_en_titanet_small.onnx ] || curl -sSL -o nemo_en_titanet_small.onnx "$BASE/speaker-recongition-models/nemo_en_titanet_small.onnx"

cp "$HERE/diarize.py" "$ROOT/diarize.py"
echo "speaker separation installed in $ROOT"
