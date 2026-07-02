# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""INSTALL_APP detection, the shared service matcher, and app CLI branches."""

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from whisper_voice import _install
from whisper_voice._service_identity import is_service_command
from whisper_voice.cli import build, doctor, lifecycle


@pytest.fixture(autouse=True)
def _clear_detection_caches():
    _install.get_install_method.cache_clear()
    _install.get_app_bundle_root.cache_clear()
    yield
    _install.get_install_method.cache_clear()
    _install.get_app_bundle_root.cache_clear()


# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

def test_app_bundle_root_positional_match():
    prefix = Path("/Applications/Local Whisper.app/Contents/Resources/python")
    assert _install._app_bundle_root(prefix) == Path("/Applications/Local Whisper.app")


def test_app_bundle_root_survives_translocation_and_rename():
    prefix = Path(
        "/private/var/folders/xy/T/AppTranslocation/AB-12/d/Renamed Thing.app/Contents/Resources/python"
    )
    assert _install._app_bundle_root(prefix) == Path(
        "/private/var/folders/xy/T/AppTranslocation/AB-12/d/Renamed Thing.app"
    )


def test_app_bundle_root_rejects_non_bundle_prefixes():
    for prefix in [
        Path("/opt/homebrew/Cellar/local-whisper/1.6.14/libexec"),
        Path("/Users/u/projects/local-whisper/.venv"),
        Path("/Applications/Contents/Resources"),  # no .app component
    ]:
        assert _install._app_bundle_root(prefix) is None


def test_get_install_method_prefers_app_over_others(monkeypatch):
    monkeypatch.setattr(
        sys, "prefix", "/Applications/Local Whisper.app/Contents/Resources/python"
    )
    assert _install.get_install_method() == _install.INSTALL_APP
    assert _install.get_app_bundle_root() == Path("/Applications/Local Whisper.app")


def test_get_install_method_brew_unchanged(monkeypatch):
    monkeypatch.setattr(sys, "prefix", "/opt/homebrew/Cellar/local-whisper/1.6.14/libexec")
    assert _install.get_install_method() == _install.INSTALL_BREW
    assert _install.get_app_bundle_root() is None


# ---------------------------------------------------------------------------
# Shared service matcher
# ---------------------------------------------------------------------------

SERVICE_COMMANDS = [
    "/Users/u/projects/local-whisper/.venv/bin/python3.12 /Users/u/projects/local-whisper/.venv/bin/wh _run",
    "/opt/homebrew/Cellar/local-whisper/1.6.14/libexec/bin/python3.12 "
    "/opt/homebrew/Cellar/local-whisper/1.6.14/libexec/bin/wh _run",
    "/Applications/Local Whisper.app/Contents/Resources/python/bin/python3.12 -s -E -B "
    "/Applications/Local Whisper.app/Contents/Resources/bin/wh.py _run",
]

NON_SERVICE_COMMANDS = [
    # The UI process must never match — stop would kill the supervisor.
    "/Applications/Local Whisper.app/Contents/MacOS/LocalWhisperUI",
    "grep wh _run",
    "/Users/u/projects/local-whisper/.venv/bin/wh status",
    "vim /Users/u/local-whisper/notes.md",
    "/usr/bin/python3 /tmp/other-tool/wh.py _run",
    # A shell that merely MENTIONS the service strings (grep patterns, paths)
    # must never match — the duplicate sweep SIGTERMs matches. Regression:
    # this exact shape killed the invoking shell during integration testing.
    'bash -c WH="build/Local Whisper.app/Contents/Resources/bin/wh" && ps | grep "wh.py _run" | grep -v grep',
    "tail -f /Users/u/projects/local-whisper/service.log wh _run extra",
]


@pytest.mark.parametrize("command", SERVICE_COMMANDS)
def test_matcher_accepts_service_processes(command):
    assert is_service_command(command)


@pytest.mark.parametrize("command", NON_SERVICE_COMMANDS)
def test_matcher_rejects_non_service_processes(command):
    assert not is_service_command(command)


def test_lifecycle_matcher_delegates_to_shared_implementation():
    for command in SERVICE_COMMANDS + NON_SERVICE_COMMANDS:
        assert lifecycle._is_service_command(command) == is_service_command(command)


# ---------------------------------------------------------------------------
# CLI branches under INSTALL_APP
# ---------------------------------------------------------------------------

def test_cmd_update_under_app_is_message_only(monkeypatch, capsys):
    monkeypatch.setattr(doctor, "get_install_method", lambda: doctor.INSTALL_APP)

    def forbid(cmd, *args, **kwargs):
        raise AssertionError(f"app update must not shell out: {cmd}")

    monkeypatch.setattr(doctor.subprocess, "run", forbid)

    assert doctor.cmd_update() is True
    out = capsys.readouterr().out
    assert "managed by the app" in out
    assert "brew" not in out
    assert "git pull" not in out


def test_cmd_build_under_app_is_noop(monkeypatch, capsys):
    monkeypatch.setattr(build, "get_install_method", lambda: build.INSTALL_APP)

    def forbid(*args, **kwargs):
        raise AssertionError("app build must not run subprocesses")

    monkeypatch.setattr(build.subprocess, "run", forbid)

    build.cmd_build()
    assert "bundled inside Local Whisper.app" in capsys.readouterr().out


def test_spawn_swift_ui_skipped_when_ui_is_parent(monkeypatch):
    from whisper_voice import app as app_module

    monkeypatch.setenv("LOCAL_WHISPER_UI_PARENT", "1")
    logged = []
    monkeypatch.setattr(app_module, "log", lambda msg, *a, **k: logged.append(msg))

    def forbid(*args, **kwargs):
        raise AssertionError("UI must not be spawned when the app is the parent")

    monkeypatch.setattr(app_module.subprocess, "Popen", forbid)

    fake_self = SimpleNamespace(_swift_process=None)
    app_module.App._spawn_swift_ui(fake_self)
    assert any("parent app" in msg for msg in logged)
