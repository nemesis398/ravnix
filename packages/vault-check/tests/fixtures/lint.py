#!/usr/bin/env python3
"""A stand-in for the AI memory lint of the ai-memory skill, for the tests of
vault-check. The skill is not part of ravnix, so its lint.py cannot be run
here; vault-check only reads what the lint prints and how it exits, and this
prints the same shapes for the two defects the tests plant:

  ERROR AI/memory/NAME.md: over 6 KB (N bytes)   a memory note past the hard cap
  ERROR domains.json: not valid JSON             the domains file is broken

and exits 1 when it printed an ERROR, else 0. The vault is --vault, the
domains file AI_MEMORY_DOMAINS (no file means no domains).
"""
import argparse
import json
import os
import sys

CAP = 6 * 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", required=True)
    ap.add_argument("--summary", action="store_true")
    args = ap.parse_args()
    errors = 0
    domains = os.environ.get("AI_MEMORY_DOMAINS")
    if domains and os.path.isfile(domains):
        try:
            with open(domains, encoding="utf-8") as fh:
                json.load(fh)
        except ValueError:
            print("ERROR domains.json: not valid JSON")
            errors += 1
    memory = os.path.join(args.vault, "AI", "memory")
    if os.path.isdir(memory):
        for name in sorted(os.listdir(memory)):
            path = os.path.join(memory, name)
            if name.endswith(".md") and os.path.getsize(path) > CAP:
                print(f"ERROR AI/memory/{name}: over 6 KB ({os.path.getsize(path)} bytes)")
                errors += 1
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
