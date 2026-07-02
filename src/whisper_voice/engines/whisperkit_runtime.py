# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""WhisperKit CLI discovery and installation helpers."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

WHISPERKIT_CLI = "whisperkit-cli"
BREW_INSTALL_TIMEOUT_SECONDS = 1800


def _brew_path() -> str | None:
    found = shutil.which("brew")
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew"):
        path = Path(candidate)
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def _candidate_paths(binary: str) -> list[Path]:
    """Return common Homebrew binary paths even when LaunchAgent PATH is sparse."""
    candidates: list[Path] = []
    found = shutil.which(binary)
    if found:
        candidates.append(Path(found))

    for prefix in ("/opt/homebrew", "/usr/local"):
        candidates.append(Path(prefix) / "bin" / binary)

    brew = _brew_path()
    if brew:
        try:
            result = subprocess.run(
                [brew, "--prefix", binary],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if result.returncode == 0:
                prefix = result.stdout.strip()
                if prefix:
                    candidates.append(Path(prefix) / "bin" / binary)
        except Exception:
            pass

    seen: set[Path] = set()
    unique: list[Path] = []
    for path in candidates:
        try:
            resolved = path.expanduser().resolve()
        except OSError:
            resolved = path.expanduser()
        if resolved in seen:
            continue
        seen.add(resolved)
        unique.append(path)
    return unique


def whisperkit_cli_path() -> str | None:
    """Return a runnable WhisperKit CLI path, or None if it is unavailable."""
    for candidate in _candidate_paths(WHISPERKIT_CLI):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def ensure_whisperkit_cli_installed() -> str:
    """Install WhisperKit CLI with Homebrew if needed and return its path."""
    existing = whisperkit_cli_path()
    if existing:
        return existing

    brew = _brew_path()
    if not brew:
        raise RuntimeError(
            "WhisperKit CLI is required, but Homebrew is not available. "
            "Download a prebuilt whisperkit-cli from "
            "https://github.com/argmaxinc/WhisperKit/releases and put it on "
            "your PATH, or install Homebrew and run: brew install whisperkit-cli"
        )

    try:
        result = subprocess.run(
            [brew, "install", WHISPERKIT_CLI],
            capture_output=True,
            text=True,
            timeout=BREW_INSTALL_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"brew install {WHISPERKIT_CLI} timed out after "
            f"{BREW_INSTALL_TIMEOUT_SECONDS}s"
        ) from exc

    if result.returncode != 0:
        details = (result.stderr or result.stdout or "").strip()
        if len(details) > 600:
            details = details[-600:]
        raise RuntimeError(
            f"brew install {WHISPERKIT_CLI} failed"
            + (f": {details}" if details else "")
        )

    installed = whisperkit_cli_path()
    if not installed:
        raise RuntimeError(
            f"brew install {WHISPERKIT_CLI} completed, but {WHISPERKIT_CLI} "
            "is still not on a runnable path"
        )
    return installed


def require_whisperkit_cli() -> str:
    """Return WhisperKit CLI path or raise without installing packages."""
    existing = whisperkit_cli_path()
    if existing:
        return existing
    raise RuntimeError(
        "WhisperKit CLI is not installed. Run: wh doctor --fix"
    )
