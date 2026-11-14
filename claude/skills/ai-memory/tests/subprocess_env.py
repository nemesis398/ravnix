"""The environment for a test that drives a hook adapter as a subprocess.

A driven adapter must never read or write the real state in
`~/.local/state/ai-memory/`, and must never take the kill-switch path because
the shell that runs the suite happens to have `AI_MEMORY_DISABLED=1` set: an
adapter that rightly prints nothing then passes or fails for the wrong
reason. So every subprocess gets its environment from here, and the
variables that decide where state goes and whether the hook runs are pinned
by construction instead of each test remembering them.

Same pattern as the handoff skill's `tests/subprocess_env.py`.
"""
from __future__ import annotations

import os
from pathlib import Path


def subprocess_env(tmp: str | Path, disabled: bool = False, **overrides: str) -> dict:
    """The environment for `subprocess.run`, with everything pinned under `tmp`.

    Starts from the real environment minus every inherited `AI_MEMORY_*`
    variable, so no ambient vault, domain file or state root leaks in. Then
    the state root is `tmp/state`, `HOME` is `tmp/home` (where every default
    path falls back to), and the kill switch is "0" unless `disabled` asks for
    "1". The `overrides` apply last and win over all of it.
    """
    tmp = Path(tmp)
    env = {k: v for k, v in os.environ.items() if not k.startswith("AI_MEMORY_")}
    env["AI_MEMORY_DISABLED"] = "1" if disabled else "0"
    env["AI_MEMORY_STATE_ROOT"] = str(tmp / "state")
    env["HOME"] = str(tmp / "home")
    # No skill values but the ones a test hands in.
    env["RAVNIX_SKILL_VALUES"] = str(tmp / "skill-values.json")
    env.update(overrides)
    return env
