# Tier 2 — Finalization plan (resume here)

> **Status:** All seven implementation stages of Tier 2 are **complete and verified locally** as of 2026-07-02, but the implementation is **uncommitted** (only `plans/` is committed). Everything below is what remains between "works ad-hoc on the dev machine" and "shipped, signed channel".
> **Companions:** [`tier2-standalone-signed-app.md`](./tier2-standalone-signed-app.md) (the original design), [`tier2-implementation-context.md`](./tier2-implementation-context.md) (full implementation context: decisions, gotchas, file inventory).

## Where things stand

| Stage | State | Evidence |
|---|---|---|
| 1. Prototype bundle | ✅ done | `scripts/bundle_smoke_test.sh` green: isolated MLX transcription from a moved copy, stripped PATH, offline |
| 2. `INSTALL_APP` Python layer | ✅ done | `wh version` → `(app)` inside the bundle; doctor all-green; 410 tests pass |
| 3. Swift inversion | ✅ done | UI is the launchd job (ppid 1), python service is its child; crash-restart/stop/quit semantics verified live |
| 4. Sign / notarize / dmg | ✅ done (ad-hoc) | strict `codesign --verify` passes; seal intact after a service run; 360 MB `LocalWhisper-1.6.14-adhoc.dmg` mounts and verifies |
| 5. Sparkle updater | ✅ done (dormant) | Sparkle 2.8 linked and running; activates only when `SPARKLE_ED_PUBLIC_KEY` is injected at build |
| 6. Release automation | ✅ done (untriggered) | `.github/workflows/release-app.yml` on `release: published`; ad-hoc fallback without secrets |
| 7. Docs + contract tests | ✅ done | installation.mdx "Standalone app" section; `tests/test_release_pipeline_contracts.py` |

**Dev-machine state right now:** the LaunchAgent points at `build/Local Whisper.app` (a dev path, will self-heal via `FirstRunManager`/`wh doctor --fix` when a real install lands in `/Applications`). The app is running in the menu bar; the service exited 0 waiting for Microphone/Accessibility grants to the new bundle identity. Grants reset on every ad-hoc rebuild — that churn is expected and ends with Developer ID signing.

## Remaining work, in order

### 1. Commit the implementation
The full Tier 2 diff is sitting uncommitted on `main` (see `git status`; inventory in the context doc). Suggested: single `feat: add standalone signed-app distribution channel (Tier 2)` commit. All 410 tests pass; ruff clean on `src/`.

### 2. Local human verification (no credentials needed)
- Grant Microphone + Accessibility to the running app (menu bar → onboarding), then `wh restart` from `build/Local Whisper.app/Contents/Resources/bin/wh`.
- Dictation round-trip on the bundle: double-tap Right Option → speak → ⌘V. Drive with the `/verify` skill; don't trust doctor alone.
- Login autostart: log out/in, confirm the app returns (plist `RunAtLoad` is in place, structurally verified only).

### 3. Apple Developer prerequisites (blocking Stage 4 "for real")
- Enroll in the Apple Developer Program ($99/yr).
- Create a **Developer ID Application** certificate; export as `.p12`.
- Create an **App Store Connect API key** for notarytool.
- Local test: `SIGN_IDENTITY="Developer ID Application: …" scripts/sign_bundle.sh …`, then `scripts/notarize_app.sh` with `NOTARY_KEYCHAIN_PROFILE` (via `xcrun notarytool store-credentials`).
- On the **first notarized build**: run the entitlement narrowing test — remove `com.apple.security.cs.allow-unsigned-executable-memory` from `packaging/entitlements.plist`, full dictation round-trip; drop it permanently if clean.
- Acceptance: `spctl -a -vvv -t install "Local Whisper.app"` reports `source=Notarized Developer ID`; **TCC grants persist across an update** (the whole point).

### 4. Sparkle keys
- Run Sparkle's `generate_keys` once (private key lands in the login keychain; export for CI).
- Set `SPARKLE_ED_PUBLIC_KEY` at bundle-build time (that's what activates the updater); private key → GitHub secret.

### 5. GitHub secrets (all optional; absence degrades to ad-hoc)
`MACOS_CERT_P12` (base64), `MACOS_CERT_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_P8` (base64), `SPARKLE_ED_PRIVATE_KEY`, `SPARKLE_ED_PUBLIC_KEY`.

### 6. First signed release + clean-machine E2E
- `./scripts/release.sh X.Y.Z` as usual → the published release triggers `release-app.yml` → notarized dmg + appcast entry.
- On a clean macOS VM (no dev tooling): download dmg → drag to /Applications → Gatekeeper accepts → grant permissions once → dictation works → publish N+1 → in-app update applies and service restarts on the new version → **no permission re-prompt**.
- Watch for: the appcast commit step hitting branch protection on `main` (fallbacks documented in the workflow/context doc).

### 7. Stage B — channel flip (separate PR, explicitly deferred)
Precondition: one verified over-the-air N→N+1 cycle on a clean machine.
- Rewrite README/installation.mdx to lead with the dmg.
- Deliberately rewrite `test_recommended_install_path_uses_homebrew_and_guided_setup`.
- Decide the brew tap's future; write the brew/source → app migration guide (old LaunchAgent/plist cleanup patterns exist in doctor check 11).

### 8. Known follow-ups (non-blocking)
- **Bundle size** (1.2 GB → 360 MB dmg): thin universal2 `.so` files to arm64 (`lipo`), prune `*.dist-info` docs and unused pyobjc frameworks.
- `os.execv` restart drops the `-s -E -B` interpreter flags (cosmetic isolation loss; noted in code).
- `wh update` under `INSTALL_APP` prints guidance; could trigger Sparkle over the socket once the updater is live.
- Pre-existing ruff import-order nit in `tests/test_update_mechanism.py` (CI only lints `src/`).

## Resume commands

```bash
./scripts/build_bundle.sh                             # assemble (use --skip-ui for runtime-only)
./scripts/sign_bundle.sh "build/Local Whisper.app"    # SIGN_IDENTITY env for real signing
./scripts/bundle_smoke_test.sh                        # the Stage-1 gate, still the fastest sanity check
./scripts/make_dmg.sh "build/Local Whisper.app"       # → build/LocalWhisper-<v>[-adhoc].dmg
./scripts/notarize_app.sh <app-or-dmg>                # self-skips without credentials
```

Tests: `pytest tests/ --ignore=tests/test_flow.py` (410 passing at handoff). The dev test venv recipe (uv + `numba>=0.60` pin) is in the context doc.
