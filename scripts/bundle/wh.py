# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Soroush Yousefpour
"""Bundle launcher for the wh CLI.

A real script (not ``python -m whisper_voice``): the service restart path
re-execs ``os.execv(sys.executable, [sys.executable] + sys.argv)``, which
only works when sys.argv[0] is an absolute path python can run again.
"""

import sys

from whisper_voice import main

if __name__ == "__main__":
    sys.exit(main())
