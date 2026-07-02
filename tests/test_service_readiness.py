# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Service readiness behavior when models are lazy-unloaded."""

import time
from types import SimpleNamespace

from whisper_voice.app_commands import CommandsMixin
from whisper_voice.app_pipeline import PipelineMixin


class _StatusApp(CommandsMixin):
    def __init__(self, *, ready=True, model_running=False, models_loaded=False):
        self._ready = ready
        self._busy = False
        self._models_loaded = models_loaded
        self.recorder = SimpleNamespace(recording=False)
        self.transcriber = SimpleNamespace(running=lambda: model_running)
        self.config = SimpleNamespace(
            transcription=SimpleNamespace(engine="parakeet_v3"),
        )


def test_status_reports_service_ready_when_idle_model_is_unloaded():
    from whisper_voice import __version__

    app = _StatusApp(ready=True, model_running=False, models_loaded=False)
    messages = []

    app._cmd_status(messages.append)

    assert messages == [{
        "type": "done",
        "success": True,
        "ready": True,
        "models_loaded": False,
        "busy": False,
        "recording": False,
        "engine": "parakeet_v3",
        "version": __version__,
    }]


def test_command_returns_error_when_model_reload_fails():
    class App(CommandsMixin):
        def _touch_model_activity(self):
            return False

    app = App()
    messages = []

    app._cmd_transcribe({"path": "/tmp/missing.wav"}, messages.append, None)

    assert messages == [{"type": "error", "message": "Model reload failed"}]


def test_retry_reloads_idle_model_before_transcribing(monkeypatch, tmp_path):
    class App(PipelineMixin):
        def __init__(self):
            import threading

            self._state_lock = threading.Lock()
            self._grammar_lock = threading.Lock()
            self._grammar_ready = False
            self._grammar_last_check = 0
            self._busy = False
            self._current_status = ""
            self.reloads = 0
            self.saved_history = []
            self.grammar = None
            self.backup = SimpleNamespace(
                get_audio=lambda: tmp_path / "last_recording.wav",
                save_text=lambda text: None,
                save_history=lambda raw, final: self.saved_history.append((raw, final)),
            )
            self.transcriber = SimpleNamespace(transcribe=lambda path: ("um hello", None))
            self.config = SimpleNamespace(
                grammar=SimpleNamespace(enabled=False),
                replacements=SimpleNamespace(enabled=False, rules={}),
                ui=SimpleNamespace(
                    auto_paste=False,
                    notifications_enabled=False,
                    sounds_enabled=False,
                ),
            )

        def _touch_model_activity(self):
            self.reloads += 1
            return True

        def _send_state_update(self, *args, **kwargs):
            pass

        def _send_state_done(self, *args, **kwargs):
            pass

        def _send_history_update(self):
            pass

        def _reset_to_idle(self):
            pass

    app = App()
    (tmp_path / "last_recording.wav").write_bytes(b"fake wav")

    monkeypatch.setattr("whisper_voice.app_pipeline.play_sound", lambda *args, **kwargs: None)
    monkeypatch.setattr("whisper_voice.app_pipeline.send_notification", lambda *args, **kwargs: None)
    monkeypatch.setattr("whisper_voice.app_pipeline.threading.Timer", lambda *args, **kwargs: SimpleNamespace(start=lambda: None))
    monkeypatch.setattr("whisper_voice.app_pipeline.apply_dictation_commands", lambda text: "hello")
    monkeypatch.setattr(app, "_deliver_transcription_text", lambda *args, **kwargs: True)

    app._retry(None)

    deadline = time.monotonic() + 2
    while app._busy and time.monotonic() < deadline:
        time.sleep(0.01)

    assert app.reloads == 1
    assert app.saved_history == [("um hello", "hello")]
