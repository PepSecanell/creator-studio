#!/usr/bin/env bash
# Builds the Studio desktop app. Prints where the bundle is. Never installs anything system wide.
# Needs: Rust (rustup.rs), Node 18 or newer. On Linux also the Tauri system libraries:
# https://v2.tauri.app/start/prerequisites/#linux
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

for tool in cargo node npm; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. See README.md for what to install." >&2; exit 1; }
done

npm install --no-audit --no-fund

if [ "$(uname)" = "Darwin" ]; then
  npx tauri build --bundles app
  OUT="src-tauri/target/release/bundle/macos"
else
  npx tauri build
  OUT="src-tauri/target/release/bundle"
fi

echo
echo "Built. Bundle folder: $(pwd)/$OUT"
find "$OUT" -maxdepth 2 \( -name "*.app" -o -name "*.AppImage" -o -name "*.deb" \) -print 2>/dev/null | sed 's/^/  /'
echo "Open it from there. It was not installed anywhere."
