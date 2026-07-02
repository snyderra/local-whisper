# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""LaunchAgent management for app-bundle installs.

App installs keep the same label and plist path as source installs
(com.local-whisper), so existing start/stop/doctor/uninstall paths keep
working. The plist runs the app's main executable — LocalWhisperUI — which
makes the signed bundle the TCC "responsible process" and supervises the
bundled Python service as its child. No EnvironmentVariables here: the app
sets the child environment explicitly.
"""

import os
import plistlib
import subprocess
from dataclasses import dataclass
from pathlib import Path

from ._install import get_app_bundle_root
from .cli.constants import LAUNCHAGENT_LABEL, LAUNCHAGENT_PLIST


@dataclass
class AgentStatus:
    plist_exists: bool
    program: "str | None"
    program_is_current_bundle: bool
    loaded: bool


def _agent_program(bundle_root: Path) -> Path:
    return bundle_root / "Contents" / "MacOS" / "LocalWhisperUI"


def _gui_domain() -> str:
    return f"gui/{os.getuid()}"


def render_plist(bundle_root: Path, home: "Path | None" = None) -> bytes:
    """Render the LaunchAgent plist for a bundle at the given root."""
    home = home or Path.home()
    payload = {
        "Label": LAUNCHAGENT_LABEL,
        "ProgramArguments": [str(_agent_program(bundle_root))],
        "RunAtLoad": True,
        # Restart on crash but honor a clean quit (menu quit exits 0).
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "ExitTimeOut": 30,
        "ProcessType": "Interactive",
        "StandardOutPath": str(home / ".whisper" / "ui.log"),
        "StandardErrorPath": str(home / ".whisper" / "ui.err.log"),
    }
    return plistlib.dumps(payload)


def install(bundle_root: Path) -> None:
    """Write the plist atomically and (re)bootstrap the agent."""
    LAUNCHAGENT_PLIST.parent.mkdir(parents=True, exist_ok=True)
    (Path.home() / ".whisper").mkdir(parents=True, exist_ok=True)
    tmp = LAUNCHAGENT_PLIST.with_suffix(".tmp")
    tmp.write_bytes(render_plist(bundle_root))
    tmp.replace(LAUNCHAGENT_PLIST)
    subprocess.run(
        ["launchctl", "bootout", f"{_gui_domain()}/{LAUNCHAGENT_LABEL}"], capture_output=True
    )
    subprocess.run(
        ["launchctl", "bootstrap", _gui_domain(), str(LAUNCHAGENT_PLIST)], capture_output=True
    )
    subprocess.run(
        ["launchctl", "kickstart", f"{_gui_domain()}/{LAUNCHAGENT_LABEL}"], capture_output=True
    )


def uninstall() -> None:
    """Bootout the agent and remove the plist."""
    subprocess.run(
        ["launchctl", "bootout", f"{_gui_domain()}/{LAUNCHAGENT_LABEL}"], capture_output=True
    )
    try:
        LAUNCHAGENT_PLIST.unlink()
    except FileNotFoundError:
        pass


def status() -> AgentStatus:
    """Report plist presence, its program, staleness, and load state."""
    program = None
    exists = LAUNCHAGENT_PLIST.exists()
    if exists:
        try:
            payload = plistlib.loads(LAUNCHAGENT_PLIST.read_bytes())
            args = payload.get("ProgramArguments") or []
            program = args[0] if args else None
        except Exception:
            program = None
    bundle = get_app_bundle_root()
    current = bool(program and bundle and Path(program) == _agent_program(bundle))
    loaded = (
        subprocess.run(
            ["launchctl", "print", f"{_gui_domain()}/{LAUNCHAGENT_LABEL}"], capture_output=True
        ).returncode
        == 0
    )
    return AgentStatus(exists, program, current, loaded)
