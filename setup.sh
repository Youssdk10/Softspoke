#!/bin/zsh
# Installs what Softspoke needs at runtime: the Whisper engine and a speech model.
set -euo pipefail

MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
MODEL_SHA1="137c40403d78fd54d454da0f9bd998f78703390c"
MODEL_DIR="$HOME/Library/Application Support/Softspoke/models"
MODEL="$MODEL_DIR/ggml-base.en.bin"

if ! command -v brew >/dev/null; then
  echo "Homebrew is required. Install it from https://brew.sh, then run this again."
  exit 1
fi

if brew list whisper-cpp >/dev/null 2>&1; then
  echo "Whisper engine is already installed."
else
  brew install whisper-cpp
fi

verified() {
  [[ -f "$MODEL" ]] && [[ "$(shasum "$MODEL" | cut -d' ' -f1)" == "$MODEL_SHA1" ]]
}

if verified; then
  echo "Speech model is already installed."
else
  echo "Downloading the speech model (about 142 MB)..."
  mkdir -p "$MODEL_DIR"
  curl -fL --retry 3 --progress-bar -o "$MODEL.part" "$MODEL_URL"
  mv "$MODEL.part" "$MODEL"
  if ! verified; then
    rm -f "$MODEL"
    echo "The downloaded model failed its checksum, so it was removed. Please try again."
    exit 1
  fi
fi

echo "Ready. Next, run: ./build.sh --install"
