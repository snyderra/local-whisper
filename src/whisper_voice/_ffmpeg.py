# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Vendored ffmpeg provisioning for brew-free installs.

parakeet-mlx (the default engine) shells out to a bare ``ffmpeg`` PATH
lookup on every transcription. The imageio-ffmpeg wheel ships a static
arm64 binary, but under a versioned filename buried in site-packages.
Linking it to a stable ``~/.whisper/bin/ffmpeg`` decouples the service's
LaunchAgent PATH from the wheel version.
"""

import os
import shutil
from pathlib import Path


def vendor_bin_dir() -> Path:
    return Path.home() / ".whisper" / "bin"


def vendored_ffmpeg_path() -> Path:
    return vendor_bin_dir() / "ffmpeg"


def find_ffmpeg() -> str | None:
    """Return a runnable ffmpeg: PATH, then the app bundle, then ~/.whisper/bin."""
    found = shutil.which("ffmpeg")
    if found:
        return found
    from ._install import get_app_bundle_root
    bundle_root = get_app_bundle_root()
    if bundle_root is not None:
        bundled = bundle_root / "Contents" / "Resources" / "bin" / "ffmpeg"
        if bundled.exists() and os.access(bundled, os.X_OK):
            return str(bundled)
    vendored = vendored_ffmpeg_path()
    if vendored.exists() and os.access(vendored, os.X_OK):
        return str(vendored)
    return None


def ensure_vendored_ffmpeg() -> str:
    """Materialize the bundled imageio-ffmpeg binary at ~/.whisper/bin/ffmpeg."""
    import imageio_ffmpeg

    source = Path(imageio_ffmpeg.get_ffmpeg_exe())
    if not source.is_absolute():
        # imageio-ffmpeg falls back to a bare "ffmpeg" PATH lookup when the
        # wheel has no bundled binary; resolve it before linking.
        resolved = shutil.which(str(source))
        if resolved is None:
            raise RuntimeError(f"imageio-ffmpeg returned a non-runnable path: {source}")
        source = Path(resolved)

    target = vendored_ffmpeg_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink() or target.exists():
        target.unlink()
    target.symlink_to(source)
    return str(target)
