# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Vendored ffmpeg provisioning and brew-free doctor checks."""

import os
import stat
import subprocess
import sys
import types
from pathlib import Path
from types import SimpleNamespace

from whisper_voice import _ffmpeg
from whisper_voice.cli import doctor


def _fake_wheel_binary(tmp_path: Path) -> Path:
    """A stand-in for the versioned binary imageio-ffmpeg buries in site-packages."""
    binary = tmp_path / "wheel" / "ffmpeg-osx-arm64-v7.1"
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text("#!/bin/sh\nexit 0\n")
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return binary


def _stub_imageio(monkeypatch, exe: str):
    monkeypatch.setitem(
        sys.modules, "imageio_ffmpeg",
        types.SimpleNamespace(get_ffmpeg_exe=lambda: exe),
    )


def test_ensure_vendored_ffmpeg_links_runnable_stable_path(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    source = _fake_wheel_binary(tmp_path)
    _stub_imageio(monkeypatch, str(source))

    result = Path(_ffmpeg.ensure_vendored_ffmpeg())

    assert result == tmp_path / ".whisper" / "bin" / "ffmpeg"
    assert result.exists()
    assert os.access(result, os.X_OK)
    assert result.resolve() == source.resolve()
    assert subprocess.run([str(result)]).returncode == 0


def test_ensure_vendored_ffmpeg_replaces_stale_link(tmp_path, monkeypatch):
    """A dangling symlink from an old wheel version gets relinked, not left broken."""
    monkeypatch.setenv("HOME", str(tmp_path))
    target = tmp_path / ".whisper" / "bin" / "ffmpeg"
    target.parent.mkdir(parents=True)
    target.symlink_to(tmp_path / "wheel" / "ffmpeg-osx-arm64-v6.0-gone")

    source = _fake_wheel_binary(tmp_path)
    _stub_imageio(monkeypatch, str(source))

    result = Path(_ffmpeg.ensure_vendored_ffmpeg())
    assert result.resolve() == source.resolve()


def test_find_ffmpeg_falls_back_to_vendored_copy(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(_ffmpeg.shutil, "which", lambda name: None)
    assert _ffmpeg.find_ffmpeg() is None

    source = _fake_wheel_binary(tmp_path)
    _stub_imageio(monkeypatch, str(source))
    vendored = _ffmpeg.ensure_vendored_ffmpeg()

    assert _ffmpeg.find_ffmpeg() == vendored


def test_doctor_ffmpeg_fix_uses_vendoring_helper_on_source_install(monkeypatch, capsys):
    calls = []
    monkeypatch.setattr("whisper_voice._ffmpeg.find_ffmpeg", lambda: None)
    monkeypatch.setattr(
        "whisper_voice._ffmpeg.ensure_vendored_ffmpeg",
        lambda: calls.append("vendored") or "/home/u/.whisper/bin/ffmpeg",
    )

    def forbid_subprocess(cmd, *args, **kwargs):
        raise AssertionError(f"non-brew ffmpeg fix must not shell out: {cmd}")

    monkeypatch.setattr(doctor.subprocess, "run", forbid_subprocess)

    assert doctor._check_ffmpeg(fix=True, install_method=doctor.INSTALL_SOURCE)
    assert calls == ["vendored"]
    assert "brew" not in capsys.readouterr().out


def test_doctor_ffmpeg_fix_keeps_brew_on_brew_install(monkeypatch):
    calls = []
    monkeypatch.setattr("whisper_voice._ffmpeg.find_ffmpeg", lambda: None)
    monkeypatch.setattr(
        doctor.subprocess, "run",
        lambda cmd, **kwargs: calls.append(cmd) or SimpleNamespace(returncode=0),
    )

    assert doctor._check_ffmpeg(fix=True, install_method=doctor.INSTALL_BREW)
    assert calls == [["brew", "install", "ffmpeg"]]


def test_doctor_espeak_check_skipped_when_tts_disabled(monkeypatch, capsys):
    def forbid(*args, **kwargs):
        raise AssertionError("espeak-ng must not be probed while TTS is disabled")

    monkeypatch.setattr(doctor.shutil, "which", forbid)
    monkeypatch.setattr(doctor.subprocess, "run", forbid)

    doctor._check_espeak(doctor.INSTALL_SOURCE, tts_enabled=False)

    out = capsys.readouterr().out
    assert "TTS disabled" in out
    assert "brew" not in out


def test_doctor_espeak_warns_without_brew_on_source_install(monkeypatch, capsys):
    monkeypatch.setattr(doctor.shutil, "which", lambda name: None)

    def forbid_brew(cmd, *args, **kwargs):
        raise AssertionError(f"source install must not probe brew: {cmd}")

    monkeypatch.setattr(doctor.subprocess, "run", forbid_brew)

    doctor._check_espeak(doctor.INSTALL_SOURCE, tts_enabled=True)

    out = capsys.readouterr().out
    assert "espeak-ng not installed" in out
    assert "brew" not in out
