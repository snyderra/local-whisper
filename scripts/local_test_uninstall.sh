#!/usr/bin/env bash
#
# Reverses scripts/local_test_install.sh.
#
#   1. Runs `wh uninstall` (stops the service, removes the LaunchAgent,
#      ~/.whisper including models, and the shell alias). Falls back to a
#      manual cleanup when the venv is already gone.
#   2. Removes the project .venv (wh uninstall deliberately preserves it).
#   3. Restores the most recent ~/.whisper backup made by the install script.
#
# Deletes ~/.whisper (config + downloaded models); asks first unless --yes.

set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

say() { echo -e "$1"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WH="$REPO_ROOT/.venv/bin/wh"
PLIST="$HOME/Library/LaunchAgents/com.local-whisper.plist"

if [[ "${1:-}" != "--yes" ]]; then
    say "${YELLOW}This removes the Local Whisper service, ~/.whisper (config + models),"
    say "the wh alias, and $REPO_ROOT/.venv.${NC}"
    LATEST="$(ls -dt "$HOME"/.whisper.bak-* 2>/dev/null | head -1 || true)"
    if [[ -n "$LATEST" ]]; then
        say "${DIM}The newest backup will be restored afterwards: $LATEST${NC}"
    fi
    read -r -p "Continue? [y/N] " REPLY
    [[ "$REPLY" == "y" || "$REPLY" == "Y" ]] || { say "Aborted."; exit 1; }
fi

# ----------------------------------------------------------------------------
# 1. Uninstall the app
# ----------------------------------------------------------------------------
if [[ -x "$WH" ]]; then
    "$WH" uninstall
else
    say "${DIM}.venv missing — manual cleanup mirroring wh uninstall${NC}"
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    pkill -f "wh _run" 2>/dev/null || true
    pkill -x LocalWhisperUI 2>/dev/null || true
    rm -rf "$HOME/.whisper"
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [[ -f "$rc" ]] || continue
        sed -i '' -e '/^# Local Whisper CLI$/d' -e '/^alias wh=.*local-whisper/d' "$rc"
    done
    say "${GREEN}Service, LaunchAgent, ~/.whisper, and alias removed${NC}"
fi

# ----------------------------------------------------------------------------
# 2. Remove the project venv
# ----------------------------------------------------------------------------
if [[ -d "$REPO_ROOT/.venv" ]]; then
    rm -rf "$REPO_ROOT/.venv"
    say "${GREEN}Removed${NC} $REPO_ROOT/.venv"
fi

# ----------------------------------------------------------------------------
# 3. Restore the newest backup made by the install script
# ----------------------------------------------------------------------------
LATEST="$(ls -dt "$HOME"/.whisper.bak-* 2>/dev/null | head -1 || true)"
if [[ -n "$LATEST" && ! -d "$HOME/.whisper" ]]; then
    mv "$LATEST" "$HOME/.whisper"
    say "${GREEN}Restored${NC} $LATEST -> ~/.whisper"
fi
REMAINING="$(ls -dt "$HOME"/.whisper.bak-* 2>/dev/null || true)"
if [[ -n "$REMAINING" ]]; then
    say "${DIM}Older backups kept:${NC}"
    say "${DIM}${REMAINING}${NC}"
fi

# ----------------------------------------------------------------------------
# 4. Permission grants — macOS offers no supported way to remove a single
#    TCC entry from a script (tccutil only resets a service for ALL apps, or
#    by bundle ID, and the service grant is recorded against the bare venv
#    python path). The stale entry is inert once .venv is deleted; point the
#    user at the pane so they can clear the clutter.
# ----------------------------------------------------------------------------
say ""
say "${BOLD}Permission grants (manual, macOS does not allow scripted removal):${NC}"
say "  In ${BOLD}Privacy & Security > Accessibility${NC} remove:"
say "    - ${BOLD}\"Python\"${NC} / ${DIM}python3.12${NC} (the deleted venv runtime; now inert)"
say "    - optionally your terminal app's entry, if setup's pre-check added it"
say "  Check ${BOLD}Privacy & Security > Microphone${NC} for the same two entries."
if [[ -t 0 ]]; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
fi

say ""
say "${GREEN}${BOLD}Done.${NC}"
say "${DIM}Left in place (shared tools the install may have bootstrapped):"
say "  ~/.local/bin/uv and ~/.local/share/uv (uv + its Pythons)"
say "Open a new shell for the alias removal to take effect.${NC}"
