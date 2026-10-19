#!/usr/bin/env bash
# One-time setup: system tools, Python virtualenv, speech model, motion kit, config file.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="$(uname -s)"
say() { printf '\n== %s\n' "$1"; }

say "System tools"
if [ "$OS" = "Darwin" ]; then
  if ! command -v brew >/dev/null; then
    echo "Homebrew is needed first: https://brew.sh"; exit 1
  fi
  for pkg in ffmpeg whisper-cpp node python@3.12; do
    brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
  done
elif command -v apt-get >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y ffmpeg nodejs npm python3 python3-venv python3-pip espeak-ng cmake build-essential
  if ! command -v whisper-cli >/dev/null; then
    echo "whisper.cpp is not packaged for apt. Build it once:"
    echo "  git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp"
    echo "  cmake -B build && cmake --build build -j && sudo cp build/bin/whisper-cli /usr/local/bin/"
    echo "Or run: $REPO/.venv/bin/pip install faster-whisper (slower, no build needed)."
  fi
else
  echo "Unsupported system. Install ffmpeg, node, python3 and whisper.cpp by hand, then re-run."
fi

say "Python environment"
PY=""
for c in python3.12 python3.13 python3.11 python3.10 python3; do
  if command -v "$c" >/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "Python 3.10 or newer is required."; exit 1; }
[ -d "$REPO/.venv" ] || "$PY" -m venv "$REPO/.venv"
"$REPO/.venv/bin/pip" install --quiet --upgrade pip
"$REPO/.venv/bin/pip" install --quiet -r "$REPO/requirements.txt"

say "Speech model"
MODEL_DIR="$HOME/.cache/whisper-cpp"
MODEL="$MODEL_DIR/ggml-base.en.bin"
mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL" ]; then
  curl -L --fail -o "$MODEL" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
fi

if [ -f "$REPO/motion/package.json" ]; then
  say "Motion kit"
  (cd "$REPO/motion" && npm install)
fi

say "Config"
PYTHONPATH="$REPO" "$REPO/.venv/bin/python" -c "from cstudio import config; print('Wrote', config.write('$REPO'))"
mkdir -p "$REPO/workspace"
echo
echo "Done. Next: ./studio doctor"
