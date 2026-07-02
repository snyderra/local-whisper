# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Shared predicate for recognizing the running service process.

Single source of truth for lifecycle stop/duplicate detection. Two
hard-won rules encoded here:

- The old inline checks required the literal substring ``local-whisper``,
  which the app bundle path ("Local Whisper.app" — space, capitals) never
  contains.
- Matching must be positional, not substring-anywhere: the service's
  duplicate sweep SIGTERMs matches, and a shell one-liner that merely
  *mentions* these strings (a grep pattern, an editor opening wh.py) must
  never qualify. A real service command line always ends with the ``_run``
  argument, and the identity marker lives in the program/script path — not
  in trailing arguments.
"""

_IDENTITY_MARKERS = ("local-whisper", "local whisper.app", "whisper_voice")


def is_service_command(command: str) -> bool:
    """True when a ps command line belongs to the Local Whisper service."""
    tokens = command.lower().split()
    if not tokens or tokens[-1] != "_run":
        return False
    head = " ".join(tokens[:-1])
    return any(marker in head for marker in _IDENTITY_MARKERS)
