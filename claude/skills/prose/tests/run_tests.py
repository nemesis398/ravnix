#!/usr/bin/env python3
"""Regression test for the prose checker.

Asserts that every deterministic rule actually fires on the fixture, and that
the known false-positive sources stay silent. A rule that never fires is worse
than no rule, because it reads as a guarantee it is not making.

    python3 run_tests.py
"""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECK = HERE.parent / "scripts" / "check.py"
FIXTURE = HERE / "fixture.md"

MUST_FIRE = {
    "EM-DASH": "em dash in prose, German and English",
    "EM-DASH-CELL": "em dash used as an empty-cell placeholder",
    "EN-DASH-EN": "spaced en dash interrupting an English sentence",
    "EN-DASH-BUDGET": "German Gedankenstrich over the density budget",
    "EMOJI-POSITION": "emoji present in a heading but not leading it",
    "EMOJI-COUNT": "two emoji in one heading",
    "EMOJI-DUPLICATE": "same emoji labelling two headings",
    "EMOJI-BODY": "emoji in body text",
    "EMOJI-LEGEND": "repeated body emoji recognised as a legend, not flagged",
    "DE-UNIT-SPACE": "40% instead of 40 % in German",
    "DE-THOUSANDS": "5,000 instead of 5.000 in German",
    "DE-DECIMAL": "1.5 GB instead of 1,5 GB in German",
    "DE-ABBREV-SPACE": "z.B. instead of z. B.",
    "SPACE-BEFORE-PUNCT": "space before a comma",
    "QUOTE-MIX": "typographic and straight quotes in one document",
    "AI-PHRASE": "machine-shaped phrasing, German and English",
    "DE-GLUE": "additive connectives stacked up",
}

# (rule, substring that must NOT appear in any excerpt for that rule)
MUST_NOT_FIRE = [
    ("DE-DECIMAL", "3.1.0", "version number read as a German decimal"),
    ("EM-DASH", "Dieser Kommentar", "em dash inside a fenced code block"),
    ("EM-DASH", "example.com", "em dash inside a URL"),
    ("EMOJI-BODY", "echo", "emoji inside a fenced code block"),
    ("EMOJI-BODY", "→", "arrow misread as an emoji"),
    ("DOUBLE-SPACE", "Kriterium", "table cell padding read as double spacing"),
    ("DOUBLE-SPACE", "-------", "table delimiter row read as double spacing"),
]


def main() -> int:
    proc = subprocess.run(
        [sys.executable, str(CHECK), "--no-lt", "--json", str(FIXTURE)],
        capture_output=True, text=True,
    )
    if proc.returncode not in (0, 1):
        print("checker crashed:\n" + proc.stderr)
        return 2
    findings = json.loads(proc.stdout)[0]["findings"]
    by_rule: dict[str, list[dict]] = {}
    for f in findings:
        by_rule.setdefault(f["rule"], []).append(f)

    failures = 0
    print(f"{len(findings)} findings across {len(by_rule)} rules\n")

    print("rules that must fire")
    for rule, what in sorted(MUST_FIRE.items()):
        hits = len(by_rule.get(rule, []))
        ok = hits > 0
        failures += not ok
        print(f"  {'PASS' if ok else 'FAIL'}  {rule:<20} {hits:>2}x  {what}")

    print("\nfalse positives that must stay silent")
    for rule, needle, what in MUST_NOT_FIRE:
        bad = [f for f in by_rule.get(rule, []) if needle in f["excerpt"]]
        ok = not bad
        failures += not ok
        detail = f"  fired at line {bad[0]['line']}" if bad else ""
        print(f"  {'PASS' if ok else 'FAIL'}  {rule:<20} {what}{detail}")

    unexpected = set(by_rule) - set(MUST_FIRE) - {"DOUBLE-SPACE"}
    if unexpected:
        print(f"\nrules fired that the fixture did not plant: {sorted(unexpected)}")

    print(f"\n{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
