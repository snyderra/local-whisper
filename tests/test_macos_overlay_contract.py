# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Static contracts for the macOS overlay reliability path."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_overlay_repairs_visibility_on_repeated_recording_updates():
    app_state = _read("LocalWhisperUI/Sources/LocalWhisperUI/AppState.swift")
    controller = _read("LocalWhisperUI/Sources/LocalWhisperUI/OverlayWindowController.swift")

    assert "var onStateUpdate: ((AppPhase) -> Void)?" in app_state
    assert "onStateUpdate?(phase)" in app_state
    assert "appState.onStateUpdate" in controller
    assert "repairLiveOverlay(for: phase)" in controller
    assert "ensurePanelVisible()" in controller
    assert "panel.orderFrontRegardless()" in controller
