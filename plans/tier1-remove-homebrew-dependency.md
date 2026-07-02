# Tier 1 — Make Local Whisper installable, runnable, and updatable without Homebrew

> **Status:** Ready for implementation handoff.
> **Companion:** [`tier2-standalone-signed-app.md`](./tier2-standalone-signed-app.md) covers the larger effort of replacing Homebrew as the *primary* distribution channel with a signed, notarized app. Tier 1 does **not** depend on Tier 2 and can ship on its own.

## Objective

A user on Apple Silicon macOS can **install, run, and update** Local Whisper via the source/pip path without Homebrew ever being required. Homebrew remains *supported* (the `brew install` tap channel keeps working) but is no longer a *dependency* of the source path.

**In scope:** `setup.sh`, `doctor.py`, ffmpeg vendoring, espeak-ng gating, Python provisioning, brew-worded messaging on non-brew installs, docs, tests.

**Out of scope (Tier 2):** signed/notarized `.app`/`.dmg`, PyInstaller/py2app bundling, Sparkle-style updater, replacing the brew tap as the *recommended* channel.

## Guiding principle

**Add a fully brew-free path without breaking the existing brew install.** The brew tap channel and its tests must keep working; Tier 1 only removes brew from the *source* path and adds brew-free fallbacks. This keeps `tests/test_update_mechanism.py` and `tests/test_cli_setup.py` (which assert brew behavior for `INSTALL_BREW`) green and minimizes risk.

## Architecture context (read before touching code)

- **Install-method detection** lives in `src/whisper_voice/_install.py`. `INSTALL_BREW` is inferred from `/Cellar/` in `sys.prefix`; otherwise `INSTALL_SOURCE` (a `.git` dir exists two levels up) or `INSTALL_PIP`. **The brew-free path is `INSTALL_SOURCE`/`INSTALL_PIP` and it already exists** — it uses a plain LaunchAgent via `launchctl` (`src/whisper_voice/cli/lifecycle.py:392`) and `git pull` for updates (`src/whisper_voice/cli/doctor.py:654+`). Most lifecycle plumbing is already brew-free; the gaps are dependency provisioning and messaging.
- **The service finds native binaries via a hardcoded PATH** in the LaunchAgent plist: `setup.sh:79` sets `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`. Parakeet-mlx shells out to a bare `ffmpeg` (PATH lookup) on every transcription — so any vendored ffmpeg must be resolvable on the **service's** PATH, not just the installing shell's.
- **Native binary dependencies:**
  - `ffmpeg` — **hard requirement** for the default Parakeet engine (`setup.sh:388`, `doctor.py:197`).
  - `espeak-ng` — TTS only, and **TTS is off by default** (`doctor.py:215`, `src/whisper_voice/config/schema.py:253`).
  - Python 3.11–3.12 — misaki caps at `<3.13` (`pyproject.toml:11`); `setup.sh` falls back to `brew install python@3.12`.
  - `whisperkit-cli` — **optional** engine, off the default path (`src/whisper_voice/engines/whisperkit_runtime.py:75`).

---

## Task 1 — Provision Python without Homebrew (`uv`)

**File:** `setup.sh`, Python section (~lines 179–202) and the Homebrew block (~lines 165–173).

**Current:** finds system `python3.12/3.11/3`; if none, runs `brew install python@3.12`. Separately, lines 165–173 install Homebrew unconditionally.

**Change:**
1. Delete the "Checking Homebrew / Installing Homebrew" block (165–173) entirely.
2. Keep the existing "find a compatible system Python 3.11/3.12" loop unchanged.
3. Replace the `brew install python@3.12` fallback with `uv`:
   - If `uv` is not on PATH, bootstrap it via its official standalone installer (`curl -LsSf https://astral.sh/uv/install.sh | sh`), then add `$HOME/.local/bin` to PATH for the current shell. No brew.
   - `uv python install 3.12`, then resolve the interpreter with `uv python find 3.12` and set `PYTHON_BIN` to it.
4. The venv creation below (~line 222, `"$PYTHON_BIN" -m venv`) works unchanged with a uv-provisioned interpreter. (Optional: `uv venv --python "$PYTHON_BIN"`; not required.)

**Acceptance:** On a machine with no Homebrew and no system Python 3.11/3.12, `./setup.sh` provisions Python and creates the venv without invoking `brew`.

---

## Task 2 — Vendor ffmpeg (the one hard runtime dependency)

**Approach:** ship a static ffmpeg via the `imageio-ffmpeg` pip wheel (prebuilt arm64, no compilation), materialize it at a stable path, and put that path on the **service's** PATH.

**Files:** `pyproject.toml`, `setup.sh` (`write_plist` at line 79, ffmpeg install section ~388), `src/whisper_voice/cli/doctor.py` (check #4, lines 197–213), and a small new helper.

**Changes:**
1. **`pyproject.toml`:** add `imageio-ffmpeg` to core dependencies.
2. **New helper** — add `ensure_vendored_ffmpeg()` (suggest `src/whisper_voice/_ffmpeg.py`, or extend `_install.py`):
   - Call `imageio_ffmpeg.get_ffmpeg_exe()` to get the bundled binary path.
   - Symlink (or copy) it to `~/.whisper/bin/ffmpeg`, creating `~/.whisper/bin` if needed. Return that path.
   - Rationale for the stable symlink: parakeet-mlx looks up a bare `ffmpeg` on PATH, and the imageio binary has a versioned filename buried in site-packages. A stable `~/.whisper/bin/ffmpeg` decouples the plist PATH from the wheel version.
3. **`setup.sh`:**
   - Replace the `brew install ffmpeg` block (~388) with: run the venv Python to call `ensure_vendored_ffmpeg()` (or a `wh` subcommand that does the same). Prefer a system `ffmpeg` if already on PATH.
   - In `write_plist` (line 79), prepend `$HOME/.whisper/bin` to the plist `PATH` string so the service resolves the vendored ffmpeg. Keep `/opt/homebrew/bin:/usr/local/bin` in the string as a harmless fallback for brew installs.
4. **`doctor.py` check #4 (197–213):** detect ffmpeg via `shutil.which("ffmpeg")` **or** the vendored `~/.whisper/bin/ffmpeg`. On `--fix`, call `ensure_vendored_ffmpeg()` instead of `brew install ffmpeg`. Update the non-fix hint away from `brew install ffmpeg` for non-brew installs.

**Acceptance:** On a brew-free machine, a fresh `./setup.sh` produces a working transcription (Parakeet default) — verify `~/.whisper/bin/ffmpeg` exists, is on the plist PATH, and a dictation round-trip succeeds. `wh doctor` passes the ffmpeg check; `wh doctor --fix` repairs a missing ffmpeg without brew.

---

## Task 3 — Make espeak-ng optional and brew-free

**Context:** espeak-ng is only used by misaki for Kokoro TTS phonemization, and **TTS is off by default**. There is no clean pip wheel, so treat it as an optional, documented manual step rather than a hard dep.

**Files:** `setup.sh` (~395–397), `src/whisper_voice/cli/doctor.py` (check #5, lines 215–238), `src/whisper_voice/config/schema.py:253` (comment).

**Changes:**
1. **`setup.sh`:** remove the unconditional `brew install espeak-ng`. Only when `TTS_ENABLED=true`, check `command -v espeak-ng`; if missing, `log_warn` with a manual-install note (no brew invocation). Do not fail setup.
2. **`doctor.py` check #5:** keep the presence check, but drop the `brew install espeak-ng` from `--fix`. When TTS is enabled and espeak-ng is missing, emit a warning (not a brew-driven `core_ok = False`) with a manual-install hint. When TTS is disabled, skip like the spaCy/Kokoro checks already do (`doctor.py:275`). Remove the `brew list espeak-ng` fallback probe, or guard it behind `INSTALL_BREW`.
3. Update the schema comment at `schema.py:253` so it no longer implies `./setup.sh` installs espeak-ng via brew.

**Acceptance:** With TTS off (default), setup and `wh doctor` never mention espeak-ng or brew. With TTS on and espeak-ng absent, the user gets a clear non-brew manual note and setup still completes.

---

## Task 4 — Soften brew-worded messaging on non-brew installs

**Files:** `src/whisper_voice/cli/main.py`, `src/whisper_voice/engines/whisperkit_runtime.py`, `src/whisper_voice/backends/apple_intelligence/backend.py:65`.

**Changes:**
1. `main.py` `cmd_setup`/`_run_homebrew_setup` (~114–132) and the uninstall path (~246–261): the code already branches on install method — audit the printed hints so a source/pip user is never told to run `brew ...`. The "Install with Homebrew for the guided setup path" message (~123) should present the brew-free `git clone && ./setup.sh` path as an equal option.
2. `whisperkit_runtime.py` `ensure_whisperkit_cli_installed()` (75–116): WhisperKit is optional and off the default path. Keep brew as one route, but change the "Homebrew is not available" error (83–86) to also point at the direct prebuilt-binary download from argmax's GitHub releases. Full auto-download is a stretch goal; the minimum is honest messaging that doesn't dead-end on brew.
3. `apple_intelligence/backend.py:65`: the `brew reinstall` hint is only reached under `INSTALL_BREW` — confirm it stays gated; no change expected.

**Acceptance:** `grep -rn "brew " src/` shows every remaining user-facing brew string is reachable only when `get_install_method() == INSTALL_BREW`.

---

## Task 5 — Provide a brew-free one-command entry point

**Files:** `install.sh`, `README.md`, `doc/` installation pages.

**Decision:** leave the existing brew `install.sh` tap flow intact as one channel. Add a documented brew-free path: `git clone … && ./setup.sh` (now fully brew-free after Tasks 1–3). Optionally add a `--source` flag to `install.sh` that clones the repo and runs `setup.sh` instead of the brew formula.

**Acceptance:** README documents a brew-free install that works end-to-end on a machine without Homebrew.

---

## Task 6 — Tests & docs

**Files:** `tests/test_product_contracts.py` (74–87), plus new coverage; `README.md`, `doc/`, `CHANGELOG.md`.

**Changes:**
1. `test_product_contracts.py::test_recommended_install_path_uses_homebrew_and_guided_setup` (74–87) asserts the recommended path uses brew. If Task 5 keeps brew as the *recommended* channel, this test can stay; if the recommended path changes, update it. **This is the one product-facing judgment call in Tier 1 — confirm with the maintainer which channel is "recommended."**
2. Add tests: `ensure_vendored_ffmpeg()` returns a runnable path and creates `~/.whisper/bin/ffmpeg`; `doctor` ffmpeg `--fix` on a non-brew install calls the vendoring helper (not `brew`); espeak-ng check is skipped when TTS disabled.
3. Confirm `tests/test_update_mechanism.py` and `tests/test_cli_setup.py` (brew branches) still pass unchanged — they must, since brew support is retained.
4. Update README/`doc/` install + troubleshooting sections and add a `CHANGELOG.md` entry under `[Unreleased]`.

**Acceptance:** `pytest` green (existing brew tests + new brew-free tests).

---

## Suggested order

1. **Task 2 (ffmpeg)** and **Task 1 (Python)** first — together they make a brew-free `setup.sh` actually produce a working transcription.
2. **Tasks 3, 4** (gating + messaging).
3. **Tasks 5, 6** (entry point, tests, docs).

## End-to-end verification

Do this on a machine/VM with Homebrew absent (or with `brew` shimmed off PATH):

1. `git clone` → `./setup.sh` completes with **zero** `brew` invocations.
2. `wh doctor` — all core checks pass.
3. Double-tap Right Option, speak, confirm transcribed text (use the `/verify` skill to drive the dictation round-trip; don't trust `doctor` alone).
4. `wh update` (git-pull path) succeeds.

## Known gotchas

- **Service PATH, not shell PATH:** the failure mode for Task 2 is "works in Terminal, fails in the background service" because the vendored ffmpeg isn't on the *plist* PATH. The `write_plist` edit (Task 2, step 3) is essential.
- **`uv` PATH bootstrap:** after `curl | sh`, `uv` lands in `~/.local/bin`, which may not be on PATH in the current shell — add it before use.
- **Pip-install-without-git updates:** `cmd_update`'s non-brew branch runs `git pull`, which fails for an `INSTALL_PIP` install with no repo. Pre-existing edge, not introduced here — note it, leave for Tier 2.
- **espeak-ng has no pip wheel** — don't burn time hunting for one; the optional-manual-step approach is the intended Tier 1 answer.
