"""One place that pins JOURNAL_DISABLED for driven subprocesses.

A child that inherits JOURNAL_DISABLED=1 from the ambient shell takes the
kill-switch path and emits nothing, which a test then asserts against as if
the adapter had misbehaved. handoff hit exactly this and shipped the same
helper; the failure reads as "'...' not found in ''".
"""
from __future__ import annotations

import os


def subprocess_env(disabled: bool = False, **overrides: str) -> dict:
    env = dict(os.environ)
    env["JOURNAL_DISABLED"] = "1" if disabled else "0"
    # No skill values but the ones a test hands in.
    env["RAVNIX_SKILL_VALUES"] = os.devnull + ".absent"
    env.update(overrides)
    return env
