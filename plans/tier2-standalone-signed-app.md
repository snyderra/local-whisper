# Tier 2 — Standalone signed, notarized app that replaces Homebrew as the primary channel

> **Status:** Design / planning. Larger, multi-week effort with hard external prerequisites (Apple Developer account, signing certs, CI secrets).
> **Companion:** [`tier1-remove-homebrew-dependency.md`](./tier1-remove-homebrew-dependency.md). Tier 2 builds on Tier 1's brew-free provisioning (uv, vendored ffmpeg) but is a distinct product decision about *distribution*, not a dependency cleanup. **Do Tier 1 first** — its `ensure_vendored_ffmpeg()` and uv-based Python provisioning are reused here.

## Objective

Ship Local Whisper as a downloadable, **Developer ID–signed and notarized** macOS app bundle (`.dmg` or `.pkg`) that embeds everything it needs — the Python runtime, all pip dependencies (including MLX and pyobjc), a vendored ffmpeg, and the Swift menu-bar UI — installs its background service via a plain LaunchAgent, and self-updates through a Sparkle-style feed. No Homebrew, no git, no pip, no Xcode/Swift toolchain on the end user's machine.

## Why this is a separate, larger effort than Tier 1

Tier 1 removes brew as a *dependency*; the user still runs a shell installer against a source checkout. Tier 2 removes the *developer-grade UX* entirely and gives a consumer download-and-drag experience. It requires code signing, notarization, an update-feed infrastructure, and CI changes that Tier 1 does not.

## Prerequisites (secure these before writing code)

- **Apple Developer Program** membership ($99/yr) with a **Developer ID Application** certificate (for the app) and, if using a `.pkg`, a **Developer ID Installer** certificate.
- An **App Store Connect API key** (or app-specific password) for `notarytool`.
- A **Sparkle EdDSA key pair** for signing the appcast (if Sparkle is chosen — see Task 6).
- A **macOS CI runner** (GitHub Actions `macos-14`/arm64) with signing identity + notary credentials stored as encrypted secrets.
- Confirm the target: **arm64-only** (the product already requires Apple Silicon), so no universal2 fattening needed.

## Current distribution reality (context)

- **Two channels today:** the brew tap (formula builds from the source tarball, pulls Python deps as brew `resource` wheels, builds the Swift UI) and the source path (`setup.sh` + pip venv + LaunchAgent). Release automation is `scripts/release.sh` (cuts a GitHub release, bumps the brew formula in `../homebrew-local-whisper`).
- **The Swift menu-bar app already exists.** `setup.sh` builds `LocalWhisperUI` (SwiftPM, `swift build -c release`) into an `LSUIElement` bundle at `~/.whisper/LocalWhisperUI.app` (`setup.sh:~430–490`). Version strings live in `setup.sh` and `src/whisper_voice/cli/build.py` and are bumped by `release.sh`.
- **The Python service runs separately** from the UI, launched by the LaunchAgent (`com.local-whisper`, plist written by `setup.sh:write_plist`, started via `launchctl`). The UI talks to the service over a Unix socket (`CMD_SOCKET_PATH`).
- **Update mechanism today:** brew → `brew upgrade` (`doctor.py:612`); source → `git pull` + `pip install -e . --upgrade` (`doctor.py:654+`).
- **A real, known pain point Tier 2 fixes:** `CHANGELOG.md:28` records "source/Homebrew LaunchAgent conflicts that could make macOS ask for permissions on multiple Python runtime identities." A single signed bundle with a **stable code-signing identity** makes TCC (Microphone, Accessibility) permissions persist across updates — a major UX win.

---

## Task 1 — Choose and prototype the Python bundling strategy

This is the highest-risk decision; prototype it before committing to the rest.

**Options:**
- **(Recommended) Embed a relocatable `python-build-standalone` interpreter + a prebuilt site-packages.** Use `uv` (from Tier 1) to install a standalone 3.12 and `pip install` the project into a relocatable prefix, then copy that tree into the app bundle. Keeps MLX's Metal libraries and all `.so`/`.dylib` files intact and avoids PyInstaller/py2app import-hook fragility with native extensions.
- **PyInstaller** — mature, but MLX (Metal shader libraries), `pyobjc`, `sounddevice` (PortAudio dylib), and `soundfile` (libsndfile) frequently need custom hooks and binary-collection tweaks. Higher ongoing maintenance.
- **py2app** — macOS-native, but similar native-extension pain and slower iteration.

**Deliverable:** a prototype that assembles a self-contained Python tree, runs `wh _run` from it with **no** system Python / venv / brew on PATH, and successfully transcribes with Parakeet (exercises MLX + vendored ffmpeg). Reuse Tier 1's `ensure_vendored_ffmpeg()` to place ffmpeg inside the bundle.

**Acceptance:** the isolated Python tree transcribes end-to-end on a machine with no dev tooling.

---

## Task 2 — Define the app bundle layout

Make the Swift `LocalWhisperUI.app` the top-level bundle and nest the runtime inside it. Everything must be **relocatable** (no absolute paths baked into the interpreter or site-packages — `python-build-standalone` is relocatable; verify with `otool -l` / `install_name_tool` audits).

Proposed layout:

```
Local Whisper.app/
  Contents/
    Info.plist                      # bundle id com.local-whisper, LSUIElement, NSMicrophoneUsageDescription, version
    MacOS/
      LocalWhisperUI                # existing Swift menu-bar binary (main executable)
    Resources/
      python/                       # relocatable python-build-standalone runtime
      site-packages/                # or a full venv; the installed whisper_voice + deps
      bin/
        ffmpeg                      # vendored static ffmpeg (from Tier 1)
        wh                          # launcher shim -> python -m whisper_voice ...
      LocalWhisper.icns
```

**Acceptance:** `Contents/Resources/bin/wh _run` starts the service using only bundle-internal paths; `Contents/Resources/bin/wh --version` works with the bundle moved to an arbitrary directory.

---

## Task 3 — Code signing (inside-out) with hardened runtime

Sign every nested Mach-O **before** the outer bundle: MLX Metal libraries, all `.so` extension modules, `pyobjc` dylibs, the PortAudio/libsndfile dylibs, the standalone `python` binary, `ffmpeg`, then `LocalWhisperUI`, then the `.app`.

- Use `codesign --force --options runtime --timestamp` with the **Developer ID Application** identity.
- **Hardened-runtime entitlements** likely required for embedded Python + MLX JIT:
  - `com.apple.security.cs.allow-jit`
  - `com.apple.security.cs.allow-unsigned-executable-memory` (verify whether MLX needs it; prefer the narrowest set that passes notarization + runs)
  - `com.apple.security.device.audio-input` (microphone)
- `Info.plist` must include `NSMicrophoneUsageDescription`. **Accessibility** is a TCC grant at runtime (not an entitlement) — the app already prompts/checks it (`whisper_voice.utils.check_accessibility_trusted`).

**Acceptance:** `codesign --verify --deep --strict --verbose=2 "Local Whisper.app"` passes; the signed app launches and records audio.

---

## Task 4 — Notarization and stapling

- Submit with `xcrun notarytool submit --wait` using the App Store Connect API key.
- On success, `xcrun stapler staple` the app (and the `.dmg`/`.pkg`).
- Read and resolve any notary-log rejections (unsigned nested binaries are the usual culprit — loop back to Task 3).

**Acceptance:** `spctl -a -vvv -t install "Local Whisper.app"` reports `accepted` / `source=Notarized Developer ID`; the stapled artifact opens on a clean machine with no Gatekeeper prompt.

---

## Task 5 — Packaging + LaunchAgent install from the bundle

**Packaging decision (pick one):**
- **`.dmg`** with a drag-to-`/Applications` layout. First launch installs the LaunchAgent. Simpler signing (just the app + dmg).
- **`.pkg`** with a `postinstall` script that writes the LaunchAgent. Cleaner for enterprise/MDM; needs the Developer ID **Installer** cert.

Recommendation: **`.dmg`** + first-run LaunchAgent install, to match the app's self-contained model.

**LaunchAgent from the bundle:** the plist's `ProgramArguments` point at `/Applications/Local Whisper.app/Contents/Resources/bin/wh _run`. On first run the app writes the plist and `launchctl bootstrap`s it (reuse the existing plist logic in `setup.sh:write_plist` / `lifecycle.py`, retargeted at the bundle path). Because the bundle's code-signing identity is stable, TCC permissions persist across updates — fixing the multi-identity permission churn noted in `CHANGELOG.md:28`.

**Acceptance:** dragging the app to `/Applications` and launching it installs and starts the service; `wh status` (from the bundle) reports running; quitting and relaunching does not re-prompt for Microphone/Accessibility.

---

## Task 6 — In-app updater (replace `brew upgrade` / `git pull`)

**Options:**
- **(Recommended) Sparkle** — the standard non-App-Store macOS updater. Integrate via SwiftPM into `LocalWhisperUI`, host an **appcast XML** feed (GitHub Pages or the releases bucket), sign updates with the EdDSA key, support delta updates. Wire the existing "check for updates" menu action to Sparkle instead of shelling out to `wh update`.
- **Custom updater** — download the notarized `.dmg` from GitHub releases, verify signature, swap the bundle in place. More code, no framework dependency, but you reimplement what Sparkle already solves (delta updates, staged rollout, signature verification).

**Acceptance:** with the app at version N installed, publishing N+1 to the appcast causes the app to detect, download, verify, and apply the update, and the service restarts on the new version — no brew, no git, no terminal.

---

## Task 7 — New install method `INSTALL_APP` in the Python layer

**Files:** `src/whisper_voice/_install.py`, `src/whisper_voice/cli/lifecycle.py`, `src/whisper_voice/cli/doctor.py`, `src/whisper_voice/cli/main.py`.

- Add `INSTALL_APP` to `_install.py` and detect it (e.g. `sys.prefix` resolves inside a `.app/Contents` bundle). Order the checks so `INSTALL_APP` wins over `INSTALL_SOURCE`/`INSTALL_PIP`.
- `lifecycle.py` `cmd_start`/`cmd_stop`: use the bundle LaunchAgent path via `launchctl` (no `brew services`). Largely reuses the existing non-brew branch.
- `doctor.py` `cmd_update`: for `INSTALL_APP`, updates are owned by Sparkle — make `wh update` a no-op that points the user at the menu-bar "Check for Updates", or have it trigger the Sparkle flow via the UI over the existing socket.
- `doctor.py` checks: ffmpeg / espeak / model checks should look inside the bundle first; drop brew hints for `INSTALL_APP`.
- `main.py`: setup/uninstall messaging for `INSTALL_APP` (uninstall = quit + remove LaunchAgent + drag app to Trash).

**Acceptance:** `wh doctor` on a bundled install shows `Install: app`, passes all core checks, and prints no brew/git guidance.

---

## Task 8 — Release automation for the signed app

**Files:** `scripts/release.sh` (or a new `scripts/release-app.sh`) + GitHub Actions.

- Add a **macOS CI job** that: builds `LocalWhisperUI`, assembles the Python runtime (Task 1), vendors ffmpeg, signs inside-out (Task 3), notarizes + staples (Task 4), builds the `.dmg` (Task 5), uploads it to the GitHub release, and updates the Sparkle appcast (Task 6).
- Keep the existing brew formula bump (`release.sh` step 8) if the tap remains a supported legacy channel; otherwise schedule its deprecation (Task 9).
- Store signing identity, notary API key, and Sparkle EdDSA key as encrypted CI secrets.

**Acceptance:** a tagged release produces a downloadable, notarized `.dmg` and a valid appcast entry with no manual signing steps.

---

## Task 9 — Docs, channel strategy, and migration

**Files:** `README.md`, `doc/` (Mintlify), `CHANGELOG.md`.

- Make the `.dmg` download the **primary** documented install path.
- Decide the fate of the brew tap and source install: keep as supported alternatives, or deprecate with a migration note. Update `tests/test_product_contracts.py` to match whichever path is "recommended."
- Provide a migration path for existing brew/source users to the app (stop the old service + LaunchAgent, remove the old plist, install the app). The existing plist-conflict cleanup in `setup.sh` and `doctor.py` (checks #11) is a useful reference for detecting and removing the old runtimes.

**Acceptance:** README leads with the signed-app download; existing users have a clear, tested migration path.

---

## Suggested order

1. **Task 1** (bundling prototype) — de-risk first; everything depends on a working isolated Python + MLX + ffmpeg.
2. **Tasks 2–5** (layout → sign → notarize → package + LaunchAgent) — the distributable artifact.
3. **Task 7** (`INSTALL_APP` in the Python layer) — can proceed in parallel once the bundle layout (Task 2) is fixed.
4. **Task 6** (updater) — needs a signed baseline (Tasks 3–5) to test upgrades against.
5. **Tasks 8–9** (CI automation, docs, channel strategy) — last.

## End-to-end verification

On a clean macOS arm64 VM with **no** Homebrew, Xcode, Python, or dev tooling:

1. Download the `.dmg`, drag to `/Applications`, launch — Gatekeeper accepts (`spctl` notarized).
2. Grant Microphone + Accessibility once; dictation round-trip works (drive via the `/verify` skill, not just `wh doctor`).
3. Quit and relaunch — **no** permission re-prompt (stable signing identity).
4. Publish version N+1; confirm the in-app updater upgrades and the service restarts on the new version.
5. `codesign --verify --deep --strict` and `spctl -a -vvv` both pass on the installed bundle.

## Known gotchas

- **Inside-out signing:** every nested MLX Metal lib, `.so`, and dylib must be signed before the outer bundle, or notarization rejects it. This is the most common time sink — automate it in CI from day one.
- **JIT entitlements:** embedded Python and MLX may need `allow-jit` / `allow-unsigned-executable-memory`. Grant the narrowest set that both notarizes and runs; test the *notarized, hardened-runtime* build, not just a local ad-hoc-signed one (behavior differs).
- **Relocatable interpreter:** absolute paths baked into a venv/`python` break when the bundle is moved. Use `python-build-standalone` (relocatable) and audit `install_name`s.
- **App Store is likely not viable:** the background LaunchAgent + Accessibility (TCC) usage generally disqualifies MAS distribution. Plan for Developer ID / notarization only.
- **TCC identity is the whole point:** the payoff over the current multi-runtime setup (`CHANGELOG.md:28`) only materializes if the signing identity is stable across releases — keep the same Team ID and bundle identifier for the life of the app.
- **Bundle size:** embedding Python + MLX + models tooling produces a large `.dmg`. Consider excluding models (download on first run, as today) to keep the download reasonable.
