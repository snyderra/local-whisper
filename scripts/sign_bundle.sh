#!/usr/bin/env bash
#
# Inside-out code signing for "Local Whisper.app" with hardened runtime.
#
# Env:
#   SIGN_IDENTITY   codesign identity. Default "-" (ad-hoc) for local
#                   builds; set to a "Developer ID Application: ..." for
#                   release. Entitlements are identical either way.
#   ENTITLEMENTS    path to the entitlements plist
#                   (default: packaging/entitlements.plist)
#
# Order matters: leaves (every nested Mach-O) before frameworks before the
# executables that exec at runtime (python3.12, ffmpeg — entitlements bind
# per-executable, and the service process IS python) before the outer app.
# Never uses --deep for signing (deprecated, wrong order); only in verify.
#
# Usage: scripts/sign_bundle.sh "build/Local Whisper.app"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: sign_bundle.sh <path to .app>}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="${ENTITLEMENTS:-$REPO_ROOT/packaging/entitlements.plist}"

[[ -d "$APP" ]] || { echo "not a bundle: $APP"; exit 1; }
plutil -lint "$ENTITLEMENTS" >/dev/null

# Ad-hoc signatures cannot carry secure timestamps.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    TIMESTAMP="--timestamp=none"
    echo "Signing ad-hoc (SIGN_IDENTITY=-); Gatekeeper will not accept this build."
else
    TIMESTAMP="--timestamp"
    echo "Signing with identity: $SIGN_IDENTITY"
fi

# ----------------------------------------------------------------------------
# 1. Sanitize: resource forks / Finder metadata make codesign fail
# ----------------------------------------------------------------------------
xattr -rc "$APP" 2>/dev/null || true
find "$APP" \( -name '.DS_Store' -o -name '._*' \) -delete

# ----------------------------------------------------------------------------
# 2. Leaves: every nested Mach-O by magic bytes (wheels ship extensionless
#    binaries), excluding the runtime executables signed with entitlements
#    in step 4 and the main executable sealed with the app in step 5.
# ----------------------------------------------------------------------------
echo "Signing nested Mach-O leaves..."
PYBIN="$APP/Contents/Resources/python/bin"
LEAF_DIRS=("$APP/Contents/Resources")
[[ -d "$APP/Contents/Frameworks" ]] && LEAF_DIRS+=("$APP/Contents/Frameworks")
find "${LEAF_DIRS[@]}" -type f ! -type l \
    | while IFS= read -r f; do
        case "$f" in
            "$PYBIN"/python*|"$APP/Contents/Resources/bin/ffmpeg") continue ;;
        esac
        magic=$(xxd -p -l4 "$f" 2>/dev/null || true)
        case "$magic" in
            cffaedfe|cafebabe|feedfacf|bebafeca) printf '%s\0' "$f" ;;
        esac
    done \
    | xargs -0 -P "$(sysctl -n hw.ncpu)" -I{} \
        codesign --force --options runtime $TIMESTAMP --sign "$SIGN_IDENTITY" "{}"

# ----------------------------------------------------------------------------
# 3. Frameworks (inside-out), when present — Sparkle lands here later
# ----------------------------------------------------------------------------
if [[ -d "$APP/Contents/Frameworks" ]]; then
    find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 \
        | while IFS= read -r -d '' fw; do
            # Inner XPC services and helper apps first
            find "$fw" \( -name '*.xpc' -o -name '*.app' \) -type d -print0 2>/dev/null \
                | xargs -0 -I{} codesign --force --options runtime $TIMESTAMP --sign "$SIGN_IDENTITY" "{}"
            codesign --force --options runtime $TIMESTAMP --sign "$SIGN_IDENTITY" "$fw"
        done
fi

# ----------------------------------------------------------------------------
# 4. Runtime executables that record audio / exec independently — signed
#    WITH entitlements (the mic entitlement must be on the interpreter).
# ----------------------------------------------------------------------------
echo "Signing runtime executables with entitlements..."
for exe in "$PYBIN"/python3.12 "$APP/Contents/Resources/bin/ffmpeg"; do
    [[ -f "$exe" ]] || continue
    codesign --force --options runtime $TIMESTAMP \
        --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$exe"
done

# ----------------------------------------------------------------------------
# 5. Outer app (signs the main executable and seals Resources)
# ----------------------------------------------------------------------------
echo "Signing the app bundle..."
codesign --force --options runtime $TIMESTAMP \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"

# ----------------------------------------------------------------------------
# 6. Verify
# ----------------------------------------------------------------------------
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signature verification passed."
