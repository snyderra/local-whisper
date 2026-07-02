#!/usr/bin/env bash
#
# Assemble the standalone "Local Whisper.app" bundle (Tier 2).
#
# Copies a relocatable python-build-standalone runtime (uv-managed) into the
# bundle, installs local-whisper + deps into its site-packages (no venv —
# pyvenv.cfg bakes absolute paths), places launcher shims and a static
# ffmpeg, then hard-fails a relocatability audit. No signing here; see
# scripts/sign_bundle.sh.
#
# Usage: scripts/build_bundle.sh [--skip-ui]
#   --skip-ui   Runtime-only prototype: skip the Swift UI build.
#
# Output: build/Local Whisper.app

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
say() { echo -e "$1"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
APP="$BUILD_DIR/Local Whisper.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"

SKIP_UI=false
[[ "${1:-}" == "--skip-ui" ]] && SKIP_UI=true

[[ "$(uname -s)" == "Darwin" ]] || { say "${RED}macOS required${NC}"; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { say "${RED}Apple Silicon required${NC}"; exit 1; }

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$REPO_ROOT/pyproject.toml" | head -1)
[[ -n "$VERSION" ]] || { say "${RED}could not read version from pyproject.toml${NC}"; exit 1; }
say "${BOLD}Building Local Whisper.app v$VERSION${NC}"

# ----------------------------------------------------------------------------
# 1. Relocatable Python runtime (uv-managed python-build-standalone)
# ----------------------------------------------------------------------------
if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
command -v uv &>/dev/null || { say "${RED}uv not available${NC}"; exit 1; }

# only-managed: never pick up a system/MacPorts interpreter — the bundle
# needs the relocatable python-build-standalone tree.
export UV_PYTHON_PREFERENCE=only-managed
uv python install 3.12 --quiet
PY_BIN=$(uv python find 3.12)
PBS_ROOT=$(cd -P "$(dirname "$(readlink -f "$PY_BIN")")/.." && pwd)
say "  runtime: $PBS_ROOT"

rm -rf "$APP"
mkdir -p "$RES" "$CONTENTS/MacOS"
mkdir -p "$RES/python"
cp -R "$PBS_ROOT/." "$RES/python/"
BPY="$RES/python/bin/python3.12"
[[ -x "$BPY" ]] || { say "${RED}embedded python missing at $BPY${NC}"; exit 1; }
# The copy is our bundle runtime, not a uv-managed install: drop the PEP 668
# marker so pip can install into it.
rm -f "$RES/python/lib/python3.12/EXTERNALLY-MANAGED"

# ----------------------------------------------------------------------------
# 2. Install the package (non-editable) into the embedded site-packages
# ----------------------------------------------------------------------------
say "${BOLD}Installing local-whisper into the bundle...${NC}"
if ! "$BPY" -m pip --version &>/dev/null; then
    "$BPY" -m ensurepip --upgrade >/dev/null
fi
# Bundle targets macOS 26+, so include the Apple Intelligence extra.
if ! "$BPY" -m pip install --no-cache-dir --quiet "$REPO_ROOT[apple-intelligence]"; then
    say "  pip resolution failed; retrying with uv pip + modern numba pin"
    uv pip install --python "$BPY" "$REPO_ROOT[apple-intelligence]" "numba>=0.60"
fi

# No .pyc anywhere: -B at runtime (shims) + stripped here. Writes inside
# Resources after signing would invalidate the bundle seal.
find "$RES/python" -name '__pycache__' -type d -prune -exec rm -rf {} +

# Prune dead weight that would otherwise be signed and shipped: pyobjc's
# test package and the debug-symbol bundles its wheels include.
rm -rf "$RES/python/lib/python3.12/site-packages/PyObjCTest"
find "$RES/python" -name '*.dSYM' -type d -prune -exec rm -rf {} +

# pip-generated console scripts carry absolute build-path shebangs; the
# bundle ships its own shims instead. Keep only real binaries.
for f in "$RES/python/bin"/*; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then
        rm -f "$f"
    fi
done
# Removing those scripts orphans their aliases (2to3, pydoc3, ...);
# dangling symlinks break codesign's strict verification.
find "$RES/python/bin" -type l ! -exec test -e {} \; -delete

# ----------------------------------------------------------------------------
# 3. Launcher shims + static ffmpeg
# ----------------------------------------------------------------------------
mkdir -p "$RES/bin"
cp "$REPO_ROOT/scripts/bundle/wh" "$REPO_ROOT/scripts/bundle/wh.py" "$RES/bin/"
chmod 755 "$RES/bin/wh" "$RES/bin/wh.py"
# Copy (not symlink): codesign needs a real file.
"$BPY" -c "import imageio_ffmpeg, shutil; shutil.copy(imageio_ffmpeg.get_ffmpeg_exe(), r'$RES/bin/ffmpeg')"
chmod 755 "$RES/bin/ffmpeg"

# ----------------------------------------------------------------------------
# 4. Info.plist + icon (+ Swift UI unless --skip-ui)
# ----------------------------------------------------------------------------
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LocalWhisperUI</string>
    <key>CFBundleIdentifier</key>
    <string>com.local-whisper</string>
    <key>CFBundleName</key>
    <string>Local Whisper</string>
    <key>CFBundleDisplayName</key>
    <string>Local Whisper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Local Whisper records your voice locally to transcribe dictation on-device.</string>
    <key>LWBundledRuntime</key>
    <true/>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null
cp "$REPO_ROOT/src/whisper_voice/assets/LocalWhisper.icns" "$RES/AppIcon.icns"

if [[ "$SKIP_UI" == "false" ]]; then
    say "${BOLD}Building LocalWhisperUI...${NC}"
    command -v swift &>/dev/null || { say "${RED}swift not found (use --skip-ui for the runtime prototype)${NC}"; exit 1; }
    # Frameworks rpath so the executable finds the embedded Sparkle.framework.
    swift build -c release --package-path "$REPO_ROOT/LocalWhisperUI" \
        -Xlinker -rpath -Xlinker "@executable_path/../Frameworks"
    cp "$REPO_ROOT/LocalWhisperUI/.build/release/LocalWhisperUI" "$CONTENTS/MacOS/LocalWhisperUI"
    SPARKLE_FW="$REPO_ROOT/LocalWhisperUI/.build/release/Sparkle.framework"
    if [[ -d "$SPARKLE_FW" ]]; then
        mkdir -p "$CONTENTS/Frameworks"
        cp -R "$SPARKLE_FW" "$CONTENTS/Frameworks/"
    fi
else
    say "  (skipping Swift UI)"
fi

# Sparkle activates only when the appcast keys are configured (release
# builds). Without them the app keeps the legacy IPC update path.
if [[ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]]; then
    FEED_URL="${SPARKLE_FEED_URL:-https://gabrimatic.github.io/local-whisper/appcast.xml}"
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_ED_PUBLIC_KEY" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 86400" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS/Info.plist"
    say "  Sparkle feed configured: $FEED_URL"
fi

# ----------------------------------------------------------------------------
# 5. Relocatability audit (hard gate)
# ----------------------------------------------------------------------------
say "${BOLD}Auditing relocatability...${NC}"
AUDIT_RES="$RES" AUDIT_REPO="$REPO_ROOT" "$BPY" -s -E -B - <<'PYAUDIT'
import os
import pathlib
import subprocess
import sys

res = pathlib.Path(os.environ["AUDIT_RES"])
needles = [
    os.environ["AUDIT_REPO"],
    str(pathlib.Path.home() / ".local" / "share" / "uv"),
    str(res.parent.parent.parent),  # the build dir itself
]
MAGICS = {b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca"}
ALLOWED = ("/usr/lib/", "/System/", "@rpath", "@loader_path", "@executable_path")
bad = []
stripped_rpaths = 0

machos = []
for f in res.rglob("*"):
    if not f.is_file() or f.is_symlink():
        continue
    try:
        with open(f, "rb") as fh:
            if fh.read(4) in MAGICS:
                machos.append(f)
    except OSError:
        pass

for f in machos:
    own_id = None
    id_out = subprocess.run(["otool", "-D", str(f)], capture_output=True, text=True).stdout.splitlines()
    if len(id_out) > 1 and not id_out[1].endswith(":"):
        own_id = id_out[1].strip()
    # Load commands: absolute dependency paths break when the bundle moves.
    # Only tab-indented lines are load entries — unindented lines are per-
    # architecture headers on universal binaries and must be skipped.
    for line in subprocess.run(["otool", "-L", str(f)], capture_output=True, text=True).stdout.splitlines():
        if not line.startswith("\t"):
            continue
        dep = line.strip().split(" (")[0].strip()
        if not dep or dep == own_id or dep.startswith(ALLOWED):
            continue
        if dep.startswith("/"):
            bad.append(f"load path: {f}: {dep}")
    # Absolute rpaths are non-relocatable. Wheels commonly ship stale ones
    # baked by their build machines (e.g. sklearn's /Users/runner/miniconda3
    # path, dead in every pip install); strip them and re-sign ad-hoc —
    # arm64 refuses to load binaries whose signature was invalidated.
    lines = subprocess.run(["otool", "-l", str(f)], capture_output=True, text=True).stdout.splitlines()
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for follow in lines[i:i + 4]:
                follow = follow.strip()
                if follow.startswith("path "):
                    rpath = follow.split()[1]
                    if rpath.startswith("/") and not rpath.startswith(("/usr/lib", "/System")):
                        strip = subprocess.run(
                            ["install_name_tool", "-delete_rpath", rpath, str(f)],
                            capture_output=True, text=True,
                        )
                        resign = subprocess.run(
                            ["codesign", "--force", "--sign", "-", str(f)],
                            capture_output=True, text=True,
                        )
                        if strip.returncode == 0 and resign.returncode == 0:
                            stripped_rpaths += 1
                        else:
                            bad.append(f"rpath (strip failed): {f}: {rpath}")

# Baked build paths in text files (generated configs, .pth) break relocation.
# dist-info metadata (RECORD, direct_url.json) legitimately records the build
# origin and is never read at runtime — excluded.
site = res / "python" / "lib" / "python3.12" / "site-packages"
if site.is_dir():
    for f in site.rglob("*"):
        if not f.is_file() or f.suffix not in {".py", ".pth", ".cfg"}:
            continue
        if any(p.endswith(".dist-info") for p in f.parts):
            continue
        try:
            text = f.read_text(errors="ignore")
        except OSError:
            continue
        for needle in needles:
            if needle in text:
                bad.append(f"baked path: {f}: contains {needle}")
                break

print(f"  {len(machos)} Mach-O files audited, {stripped_rpaths} stale absolute rpaths stripped")
if bad:
    print("RELOCATABILITY AUDIT FAILED:", file=sys.stderr)
    for b in bad[:40]:
        print(f"  {b}", file=sys.stderr)
    if len(bad) > 40:
        print(f"  ... and {len(bad) - 40} more", file=sys.stderr)
    sys.exit(1)
print("  audit clean")
PYAUDIT

say ""
say "${GREEN}${BOLD}Bundle built:${NC} $APP"
say "  python runtime: $(du -sh "$RES/python" | cut -f1)"
say "  total:          $(du -sh "$APP" | cut -f1)"
