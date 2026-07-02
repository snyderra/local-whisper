#!/usr/bin/env bash
#
# Brew-free local test install for Local Whisper.
#
# Reproduces the manual Tier 1 verification flow:
#   1. Backs up ~/.whisper (config + models) to a timestamped copy.
#   2. Removes the project .venv so setup must provision Python itself.
#   3. Runs ./setup.sh with PATH stripped to macOS system dirs, which hides
#      Homebrew/MacPorts and forces the new brew-free paths: uv bootstraps
#      Python 3.12 and a static ffmpeg is vendored to ~/.whisper/bin/ffmpeg.
#   4. Verifies the result: wh doctor, the vendored ffmpeg, and the
#      LaunchAgent service PATH.
#
# Reverse with: scripts/local_test_uninstall.sh
#
# Note: setup.sh is interactive (macOS permission prompts) — run this from a
# real terminal, not a pipe.

set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

say() { echo -e "$1"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRIPPED_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

[[ "$(uname -s)" == "Darwin" ]] || { say "macOS required."; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { say "Apple Silicon required."; exit 1; }
[[ -f "$REPO_ROOT/setup.sh" ]] || { say "setup.sh not found at $REPO_ROOT."; exit 1; }

# ----------------------------------------------------------------------------
# 1. Back up existing config and models
# ----------------------------------------------------------------------------
if [[ -d "$HOME/.whisper" ]]; then
    BACKUP="$HOME/.whisper.bak-$(date +%Y%m%d-%H%M%S)"
    cp -R "$HOME/.whisper" "$BACKUP"
    say "${GREEN}Backed up${NC} ~/.whisper -> $BACKUP"
fi

# ----------------------------------------------------------------------------
# 2. Fresh venv so setup provisions Python (via uv) itself
# ----------------------------------------------------------------------------
if [[ -d "$REPO_ROOT/.venv" ]]; then
    rm -rf "$REPO_ROOT/.venv"
    say "${GREEN}Removed${NC} $REPO_ROOT/.venv (setup will recreate it)"
fi

# ----------------------------------------------------------------------------
# 3. Run setup with package managers hidden
# ----------------------------------------------------------------------------
say ""
say "${BOLD}Running setup.sh with PATH=$STRIPPED_PATH${NC}"
say "${DIM}Homebrew and MacPorts are off PATH, so setup must use uv + vendored ffmpeg.${NC}"
say ""
env PATH="$STRIPPED_PATH" bash "$REPO_ROOT/setup.sh"

# ----------------------------------------------------------------------------
# 4. Verify
# ----------------------------------------------------------------------------
WH="$REPO_ROOT/.venv/bin/wh"
PLIST="$HOME/Library/LaunchAgents/com.local-whisper.plist"
FAILED=0

say ""
say "${BOLD}== Verification ==${NC}"

say ""
say "${BOLD}-- wh doctor${NC}"
if ! "$WH" doctor; then
    say "${YELLOW}doctor reported issues.${NC} Pending Accessibility permission is expected"
    say "on a first install: grant it in System Settings, then run: wh restart"
fi

say ""
say "${BOLD}-- vendored ffmpeg${NC}"
if [[ -x "$HOME/.whisper/bin/ffmpeg" ]]; then
    ls -l "$HOME/.whisper/bin/ffmpeg"
    "$HOME/.whisper/bin/ffmpeg" -version | head -1
else
    say "${YELLOW}~/.whisper/bin/ffmpeg missing or not executable${NC}"
    FAILED=1
fi

say ""
say "${BOLD}-- LaunchAgent service PATH${NC}"
SERVICE_PATH="$(plutil -extract EnvironmentVariables.PATH raw "$PLIST" 2>/dev/null || true)"
say "${DIM}${SERVICE_PATH}${NC}"
if [[ "$SERVICE_PATH" == "$HOME/.whisper/bin:"* ]]; then
    say "${GREEN}OK:${NC} ~/.whisper/bin leads the service PATH"
else
    say "${YELLOW}FAIL:${NC} ~/.whisper/bin does not lead the service PATH"
    FAILED=1
fi

say ""
if [[ "$FAILED" -eq 0 ]]; then
    say "${GREEN}${BOLD}Brew-free install checks passed.${NC}"
else
    say "${YELLOW}${BOLD}Some checks failed — see above.${NC}"
fi
say ""
say "Try it: double-tap ${BOLD}Right Option${NC}, speak, tap again to stop."
say "${DIM}Double-tap copies to the clipboard (paste with Cmd+V). Hold Right Option"
say "past the double-tap threshold instead to paste directly on release.${NC}"
say ""
exit "$FAILED"
