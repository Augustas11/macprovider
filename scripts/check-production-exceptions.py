#!/usr/bin/env python3
"""CLI entrypoint for the #615 production exception register.

Thin wrapper around scripts/production_exceptions.py so deploy tooling and
Makefile targets share one discoverable check-* name.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from production_exceptions import main  # noqa: E402


if __name__ == "__main__":
    raise SystemExit(main())
