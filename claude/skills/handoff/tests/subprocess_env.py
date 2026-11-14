"""Shared environment for tests that drive a subprocess.

Every test in this suite that runs handoff_state.py or a Claude Code adapter
as a subprocess needs the same thing: the child process must never silently
inherit HANDOFF_DISABLED from the ambient shell. That variable is set
machine-wide, deliberately, for the whole duration of this build (see
settings.json's env block), and a subprocess that inherits "1" takes the
kill-switch path instead of the one a test means to exercise: an adapter that
correctly emits nothing, asserted against as if it should have emitted
something. That is the exact shape of the failure this module exists to
prevent: "AssertionError: 'No handoff exists yet' not found in ''".

A second variable joined it on 2026-08-25 for the same reason. stop.py now
raises a desktop notification when a threshold is crossed, and the tests that
drive it at 250,000 tokens were inheriting the real session bus, so every run
of the suite put two notifications on the user's screen. Blanking
DBUS_SESSION_BUS_ADDRESS here is the one-line version of that fix, and it
belongs here rather than in one test's setUp because any driven adapter can
learn to notify, not only the one that has.

HANDOFF_STATE_ROOT already avoids the equivalent problem by being pinned
explicitly in every test's setUp rather than left to whatever the ambient
shell happens to have. subprocess_env gives HANDOFF_DISABLED the same
treatment, in one place, so every subprocess call site gets it by
construction instead of by each test remembering to.
"""
from __future__ import annotations

import os


def subprocess_env(disabled: bool = False, **overrides: str) -> dict:
    """The environment to hand to subprocess.run for a driven process.

    Starts as a copy of the real environment, the same as the ad hoc
    dict(os.environ) calls this replaces, so HANDOFF_STATE_ROOT and anything
    else a test's setUp already placed in os.environ still comes through
    unchanged. HANDOFF_DISABLED is the one variable never left to
    inheritance: "0" unless the caller is deliberately exercising the kill
    switch, in which case it passes disabled=True and gets "1" instead.
    Further one-off overrides, such as HANDOFF_PRECOMPACT_RAW, are applied
    last and win over both.
    """
    env = dict(os.environ)
    env["HANDOFF_DISABLED"] = "1" if disabled else "0"
    # Empty rather than deleted: notify() reads it with .get() and treats an
    # empty string as no bus, and a test that deliberately wants one can still
    # pass it through overrides below.
    env["DBUS_SESSION_BUS_ADDRESS"] = ""
    # No skill values but the ones a test hands in: the real file would make
    # a driven adapter read the developer's own board layout.
    env["RAVNIX_SKILL_VALUES"] = os.devnull + ".absent"
    env.update(overrides)
    return env
