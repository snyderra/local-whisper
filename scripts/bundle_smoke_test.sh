#!/usr/bin/env bash
#
# Stage-1 gate for the Tier 2 bundle: prove the assembled "Local Whisper.app"
# transcribes end-to-end using ONLY bundle-internal binaries — no Homebrew,
# no MacPorts, no system Python — and survives being moved (relocatability).
#
# Needs the Parakeet model already cached in ~/.whisper/models (run setup or
# the service once first); the test itself is offline.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$REPO_ROOT/build/Local Whisper.app"
[[ -d "$APP_SRC" ]] || { echo "Bundle not found. Run: scripts/build_bundle.sh [--skip-ui]"; exit 1; }

FIXTURE="$REPO_ROOT/tests/fixtures/test_audio.wav"
[[ -f "$FIXTURE" ]] || { echo "Missing fixture $FIXTURE"; exit 1; }

MODELS="$HOME/.whisper/models"
if ! ls "$MODELS"/models--mlx-community--parakeet* >/dev/null 2>&1; then
    echo "Parakeet model not cached in $MODELS — run the service or setup once first."
    exit 1
fi

# Move test: run from a copy in a temp dir, never from the build location.
STRIPPED="/usr/bin:/bin:/usr/sbin:/sbin"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp -R "$APP_SRC" "$TMP/"
RES="$TMP/Local Whisper.app/Contents/Resources"
WH="$RES/bin/wh"
BPY="$RES/python/bin/python3.12"

echo "1/4 wh version (isolated env)"
out=$(env -i PATH="$STRIPPED" HOME="$HOME" "$WH" version)
echo "   $out"
[[ "$out" == *"Local Whisper"* ]]

echo "2/4 MLX Metal compute"
env -i PATH="$STRIPPED" HOME="$HOME" "$BPY" -s -E -B -c \
    "import mlx.core as mx; assert mx.ones((2,2)).sum().item() == 4.0; print('   mlx ok')"

echo "3/4 bundled ffmpeg"
env -i PATH="$STRIPPED" HOME="$HOME" "$RES/bin/ffmpeg" -version | head -1 | sed 's/^/   /'

echo "4/4 Parakeet transcription (bundle python + bundle ffmpeg only)"
# parakeet-mlx shells out to a bare `ffmpeg`; only Resources/bin is prepended,
# exactly as the app's ServiceManager will do.
env -i PATH="$RES/bin:$STRIPPED" HOME="$HOME" \
    HF_HUB_CACHE="$MODELS" HF_HUB_DISABLE_TELEMETRY=1 HF_HUB_OFFLINE=1 \
    "$BPY" -s -E -B -c "
from parakeet_mlx import from_pretrained
model = from_pretrained('mlx-community/parakeet-tdt-0.6b-v3')
result = model.transcribe(r'$FIXTURE')
text = getattr(result, 'text', str(result))
print('   transcript:', text.strip())
assert text.strip(), 'empty transcription'
"

echo ""
echo "SMOKE TEST PASSED — bundle transcribes in isolation."
