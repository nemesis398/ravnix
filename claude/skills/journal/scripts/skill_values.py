"""The personal values of a ravnix skill, read from skill-values.json.

ravnix renders `ravnix.claude.skillValues` to one JSON file and names it in
RAVNIX_SKILL_VALUES (claude/README.md). Without the variable the file is
`${XDG_CONFIG_HOME:-~/.config}/ravnix/skill-values.json`. It holds values
only, never a secret: it sits in the world-readable Nix store.

Each skill with scripts carries a byte-identical copy of this module, so a
skill keeps working when another is removed; the check claude-skills holds
the copies together. Its tests live in the handoff skill.

A key that is missing, of another type, or an empty string counts as not
set. A file that is missing or is not a JSON object reads as no values at
all. Nothing here raises except `require`, whose message is the one sentence
every skill stops with.

Stdlib only and no work at import time: hooks import it on every turn.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

MISSING = "set `{key}` in your ravnix skill values"


class Missing(LookupError):
    """A value the skill needs is not set."""

    def __init__(self, key: str) -> None:
        super().__init__(MISSING.format(key=key))
        self.key = key

    def __str__(self) -> str:
        return MISSING.format(key=self.key)


def path() -> Path:
    named = os.environ.get("RAVNIX_SKILL_VALUES")
    if named:
        return Path(named)
    config = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(config) / "ravnix" / "skill-values.json"


def load() -> dict:
    try:
        loaded = json.loads(path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def get(key: str, kind: type = str, values: dict | None = None):
    """The value at the dotted `key`, or None when it is not set as `kind`."""
    node = load() if values is None else values
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    if kind is not bool and isinstance(node, bool):
        return None
    if not isinstance(node, kind):
        return None
    if isinstance(node, str) and not node.strip():
        return None
    return node


def require(key: str, kind: type = str, values: dict | None = None):
    """The value at `key`, or raise Missing naming it."""
    value = get(key, kind, values)
    if value is None:
        raise Missing(key)
    return value
