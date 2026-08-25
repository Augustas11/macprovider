#!/usr/bin/env python3
"""Validate or consume a SPEC-043 PoolPromotionTransitionV1 artifact."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from pool_promotion_transition import main


if __name__ == "__main__":
    raise SystemExit(main())
