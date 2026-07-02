#!/usr/bin/env bash
#
# Notarize and staple an app bundle or dmg. Credential-gated: exits 0 with
# a skip message when no notary credentials are configured, so the same
# pipeline runs on machines/CI without an Apple Developer account.
#
# Credentials (either):
#   NOTARY_KEYCHAIN_PROFILE          profile stored via
#                                    `xcrun notarytool store-credentials`
#   NOTARY_KEY_ID + NOTARY_ISSUER_ID + NOTARY_KEY_P8_PATH
#                                    App Store Connect API key triplet
#
# Usage: scripts/notarize_app.sh <path to .app or .dmg>

set -euo pipefail

ARTIFACT="${1:?usage: notarize_app.sh <path to .app or .dmg>}"
[[ -e "$ARTIFACT" ]] || { echo "not found: $ARTIFACT"; exit 1; }

CRED_ARGS=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    CRED_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" && -n "${NOTARY_KEY_P8_PATH:-}" ]]; then
    CRED_ARGS=(--key "$NOTARY_KEY_P8_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
    echo "notarization skipped: no credentials (set NOTARY_KEYCHAIN_PROFILE or NOTARY_KEY_ID/NOTARY_ISSUER_ID/NOTARY_KEY_P8_PATH)"
    exit 0
fi

# .app bundles must be zipped for submission; dmgs submit as-is.
SUBMIT_PATH="$ARTIFACT"
CLEANUP=""
if [[ -d "$ARTIFACT" && "$ARTIFACT" == *.app ]]; then
    SUBMIT_PATH="$(mktemp -d)/app.zip"
    CLEANUP="$(dirname "$SUBMIT_PATH")"
    ditto -c -k --keepParent "$ARTIFACT" "$SUBMIT_PATH"
fi

echo "Submitting $ARTIFACT for notarization..."
RESULT_JSON=$(xcrun notarytool submit "$SUBMIT_PATH" "${CRED_ARGS[@]}" \
    --wait --timeout 30m --output-format json | tee /dev/stderr)
[[ -n "$CLEANUP" ]] && rm -rf "$CLEANUP"

STATUS=$(printf '%s' "$RESULT_JSON" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))")
SUBMISSION_ID=$(printf '%s' "$RESULT_JSON" | /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")

if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization failed (status: ${STATUS:-unknown})."
    if [[ -n "$SUBMISSION_ID" ]]; then
        # The log names the exact offending files (usually unsigned nested
        # Mach-Os) — the loop back into sign_bundle.sh.
        echo "--- notary log ---"
        xcrun notarytool log "$SUBMISSION_ID" "${CRED_ARGS[@]}" || true
    fi
    exit 1
fi

echo "Notarization accepted; stapling..."
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "Stapled: $ARTIFACT"
