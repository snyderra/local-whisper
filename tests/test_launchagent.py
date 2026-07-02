# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""LaunchAgent plist generation and lifecycle for app-bundle installs."""

import plistlib
from pathlib import Path
from types import SimpleNamespace

from whisper_voice import _launchagent

BUNDLE = Path("/Applications/Local Whisper.app")


def test_render_plist_round_trip(tmp_path):
    payload = plistlib.loads(_launchagent.render_plist(BUNDLE, home=tmp_path))

    assert payload["Label"] == "com.local-whisper"
    assert payload["ProgramArguments"] == [
        "/Applications/Local Whisper.app/Contents/MacOS/LocalWhisperUI"
    ]
    assert payload["RunAtLoad"] is True
    assert payload["KeepAlive"] == {"SuccessfulExit": False}
    assert payload["ThrottleInterval"] == 10
    assert payload["StandardOutPath"] == str(tmp_path / ".whisper" / "ui.log")
    assert payload["StandardErrorPath"] == str(tmp_path / ".whisper" / "ui.err.log")


def test_install_writes_plist_and_bootstraps(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    plist_path = tmp_path / "Library" / "LaunchAgents" / "com.local-whisper.plist"
    monkeypatch.setattr(_launchagent, "LAUNCHAGENT_PLIST", plist_path)

    calls = []
    monkeypatch.setattr(
        _launchagent.subprocess,
        "run",
        lambda cmd, **kwargs: calls.append(cmd) or SimpleNamespace(returncode=0),
    )

    _launchagent.install(BUNDLE)

    payload = plistlib.loads(plist_path.read_bytes())
    assert payload["ProgramArguments"][0].endswith("Contents/MacOS/LocalWhisperUI")
    assert [c[1].split("/")[0] if len(c) > 1 else "" for c in calls[:1]]  # launchctl called
    verbs = [c[1] for c in calls]
    assert verbs == ["bootout", "bootstrap", "kickstart"]
    assert all(c[0] == "launchctl" for c in calls)
    # No leftover temp file from the atomic write
    assert list(plist_path.parent.glob("*.tmp")) == []


def test_uninstall_boots_out_and_removes(tmp_path, monkeypatch):
    plist_path = tmp_path / "com.local-whisper.plist"
    plist_path.write_bytes(_launchagent.render_plist(BUNDLE, home=tmp_path))
    monkeypatch.setattr(_launchagent, "LAUNCHAGENT_PLIST", plist_path)

    calls = []
    monkeypatch.setattr(
        _launchagent.subprocess,
        "run",
        lambda cmd, **kwargs: calls.append(cmd) or SimpleNamespace(returncode=0),
    )

    _launchagent.uninstall()
    assert not plist_path.exists()
    assert calls[0][1] == "bootout"

    # Idempotent when the plist is already gone
    _launchagent.uninstall()


def test_status_detects_stale_program(tmp_path, monkeypatch):
    plist_path = tmp_path / "com.local-whisper.plist"
    plist_path.write_bytes(_launchagent.render_plist(Path("/Applications/Old.app"), home=tmp_path))
    monkeypatch.setattr(_launchagent, "LAUNCHAGENT_PLIST", plist_path)
    monkeypatch.setattr(_launchagent, "get_app_bundle_root", lambda: BUNDLE)
    monkeypatch.setattr(
        _launchagent.subprocess,
        "run",
        lambda cmd, **kwargs: SimpleNamespace(returncode=0),
    )

    agent = _launchagent.status()
    assert agent.plist_exists
    assert agent.program == "/Applications/Old.app/Contents/MacOS/LocalWhisperUI"
    assert not agent.program_is_current_bundle
    assert agent.loaded


def test_status_current_when_program_matches(tmp_path, monkeypatch):
    plist_path = tmp_path / "com.local-whisper.plist"
    plist_path.write_bytes(_launchagent.render_plist(BUNDLE, home=tmp_path))
    monkeypatch.setattr(_launchagent, "LAUNCHAGENT_PLIST", plist_path)
    monkeypatch.setattr(_launchagent, "get_app_bundle_root", lambda: BUNDLE)
    monkeypatch.setattr(
        _launchagent.subprocess,
        "run",
        lambda cmd, **kwargs: SimpleNamespace(returncode=1),
    )

    agent = _launchagent.status()
    assert agent.program_is_current_bundle
    assert not agent.loaded
