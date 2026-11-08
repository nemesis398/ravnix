#!/usr/bin/env python3
"""A stand-in for the lint of the ai-memory skill, for the tests of
claude-telemetry. The skill is not part of ravnix, so its lint.py cannot be
run here; claude-telemetry reads what the lint prints with --summary and how
it exits, and this prints the same shapes for the notes the tests plant in
AI/memory:

  ERROR AI/memory/NAME.md: <the line that does not parse>   quotes the line
  WARN  AI/memory/NAME.md: description under 15 characters
  AI/memory: N notes, ...                                   summary lines
  kinds in AI/memory: gotcha 2, feedback 1, preference 0, reference 1
  pinned: N note(s), ...

and exits 1 when it printed an ERROR, else 0. The vault is VAULT_DIR, else the
skill value vault.root; the tests run it under python3 -B, so it writes no
bytecode.
"""
import json
import os
import re
import sys

KINDS = ("gotcha", "feedback", "preference", "reference")


def vault():
    if os.environ.get("VAULT_DIR"):
        return os.environ["VAULT_DIR"]
    path = os.environ.get("RAVNIX_SKILL_VALUES") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "ravnix", "skill-values.json")
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)["vault"]["root"]


def frontmatter(text):
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None, ["no frontmatter"]
    fields, bad = {}, []
    for line in lines[1:]:
        if line == "---":
            return fields, bad
        m = re.fullmatch(r"([a-z]+): ?(.*)", line)
        if m:
            fields[m.group(1)] = m.group(2)
        else:
            bad.append(line)
    return fields, bad + ["frontmatter never closes"]


def main():
    root = vault()
    memory = os.path.join(root, "AI", "memory")
    out, errors = [], 0
    kinds = dict.fromkeys(KINDS, 0)
    notes = pinned = size = 0
    for name in sorted(os.listdir(memory)) if os.path.isdir(memory) else []:
        if not name.endswith(".md"):
            continue
        with open(os.path.join(memory, name), encoding="utf-8") as fh:
            text = fh.read()
        fields, bad = frontmatter(text)
        if bad:
            out.append(f"ERROR AI/memory/{name}: {bad[0]}")
            errors += 1
            continue
        notes += 1
        size += len(text)
        tags = [t.strip() for t in fields.get("tags", "").strip("[]").split(",")]
        for kind in KINDS:
            kinds[kind] += kind in tags
        pinned += "pinned" in tags
        if len(fields.get("description", "")) < 15:
            out.append(f"WARN AI/memory/{name}: description under 15 characters")
    out.append(f"AI/memory: {notes} notes, {size / 1024:.1f} KB")
    out.append("kinds in AI/memory: " + ", ".join(f"{k} {kinds[k]}" for k in KINDS))
    out.append(f"pinned: {pinned} note{'s' if pinned != 1 else ''}, cap 5")
    print("\n".join(out))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
