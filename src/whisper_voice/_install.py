# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Install-method detection (app bundle vs brew vs source vs pip)."""

import sys
from functools import lru_cache
from pathlib import Path

INSTALL_SOURCE = "source"
INSTALL_BREW = "brew"
INSTALL_PIP = "pip"
INSTALL_APP = "app"


def _app_bundle_root(prefix: Path) -> "Path | None":
    """Return the .app root when prefix lies inside <bundle>/Contents/Resources.

    Positional (not prefix-anchored) so it survives app renames, arbitrary
    install locations, and Gatekeeper app translocation
    (/private/var/folders/.../AppTranslocation/<uuid>/d/Name.app/...).
    """
    parts = prefix.parts
    for i in range(len(parts) - 2):
        if parts[i].endswith(".app") and parts[i + 1] == "Contents" and parts[i + 2] == "Resources":
            return Path(*parts[: i + 1])
    return None


@lru_cache(maxsize=1)
def get_app_bundle_root() -> "Path | None":
    """Return the enclosing .app bundle root, or None outside a bundle."""
    try:
        return _app_bundle_root(Path(sys.prefix).resolve())
    except OSError:
        return None


@lru_cache(maxsize=1)
def get_install_method() -> str:
    """Return INSTALL_APP, INSTALL_BREW, INSTALL_SOURCE, or INSTALL_PIP."""
    if get_app_bundle_root() is not None:
        return INSTALL_APP
    if "/Cellar/" in sys.prefix:
        return INSTALL_BREW
    try:
        project_root = Path(__file__).resolve().parents[2]
        if (project_root / ".git").is_dir():
            return INSTALL_SOURCE
    except (IndexError, OSError):
        pass
    return INSTALL_PIP
