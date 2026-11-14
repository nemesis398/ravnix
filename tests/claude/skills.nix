# The scripts of the public skills (claude/skills/), carried over in Python
# and staying Python (AGENTS.md, rule 4): each skill's own suite, run in the
# build sandbox with the tools the scripts use and nothing else, HOME a
# throwaway directory and no skill values but the ones a test writes.
#
# Besides the suites:
#   - every copy of skill_values.py is the one in handoff, whose suite tests
#     it, so no skill drifts off the one reader of the values;
#   - every value a skill's Markdown names ({{KEY}}) is a row of the key
#     table in claude/skills/README.md, and every row is named by a skill or
#     read by a script, so the table and the skills cannot drift apart;
#   - no skill ships a list of words, a board layout or a domain list of its
#     own: those are values (prose/dictionary.txt holds comments only).
{ pkgs, lib, ... }:
let
  src = lib.fileset.toSource {
    root = ../../claude/skills;
    fileset = ../../claude/skills;
  };
  python = pkgs.python3;
in
pkgs.runCommand "claude-skills"
  {
    inherit src;
    nativeBuildInputs = [
      python
      pkgs.coreutils
      pkgs.diffutils
      pkgs.findutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.ripgrep
    ];
  }
  ''
    cp -r "$src" skills
    chmod -R u+w skills
    export HOME="$TMPDIR/home" XDG_CONFIG_HOME="$TMPDIR/home/.config"
    export XDG_STATE_HOME="$TMPDIR/home/.local/state" PYTHONDONTWRITEBYTECODE=1
    mkdir -p "$HOME"
    export RAVNIX_SKILL_VALUES="$TMPDIR/no-skill-values.json"
    git config --global user.email test@example.org
    git config --global user.name test
    git config --global init.defaultBranch main
    status=0
    fail() { echo "FAIL: $*"; status=1; }

    for skill in handoff journal ai-memory; do
      echo "==> $skill"
      (cd "skills/$skill/tests" && python3 -B -m unittest discover -s . -p 'test_*.py') || fail "$skill suite"
    done
    echo "==> prose"
    (cd skills/prose/tests && python3 -B -m unittest test_values && python3 -B run_tests.py) || fail "prose suite"

    echo "==> one reader of the skill values"
    for copy in skills/*/scripts/skill_values.py; do
      cmp -s skills/handoff/scripts/skill_values.py "$copy" || fail "$copy differs from handoff's"
    done
    for skill in journal ai-memory prose; do
      [ -f "skills/$skill/scripts/skill_values.py" ] || fail "$skill has no skill_values.py"
    done

    echo "==> the key table of claude/skills/README.md"
    rg -o --no-filename '[{][{]([A-Za-z0-9_.-]+)[}][}]' -r '$1' skills/*/ --glob '*.md' \
      | grep -v '^ravnix\.' | sort -u > named
    # What the scripts read: every NAME_KEY = "a.b" constant of a script.
    rg -o --no-filename '[A-Z]+_KEY = "([a-z][A-Za-z0-9]*([.][A-Za-z0-9]+)+)"' -r '$1' skills \
      --glob '*.py' --glob '!**/tests/**' | sort -u > read
    sort -u named read > used
    # The table's rows: a line that starts with | `KEY` |, KEY a dotted path.
    sed -n 's/^| `\([A-Za-z0-9_]*[.][A-Za-z0-9_.]*\)` |.*/\1/p' skills/README.md | sort -u > table
    while read -r key; do
      grep -qxF "$key" table || fail "{{$key}} or a script reads $key, and the README's table has no row for it"
    done < used
    while read -r key; do
      grep -qxF "$key" used || fail "the README's table lists $key, which no skill names or reads"
    done < table

    echo "==> no personal lists in the skills"
    [ -z "$(grep -v '^[[:space:]]*\(#.*\)\?$' skills/prose/dictionary.txt)" ] \
      || fail "prose/dictionary.txt holds words; the user's list is ~/.config/prose/dictionary.txt"
    for f in handoff/projects.json ai-memory/domains.json; do
      [ ! -e "skills/$f" ] || fail "$f is back; it is a skill value"
    done

    echo "==> names"
    for skill in skills/*/; do
      name=$(basename "$skill")
      head -5 "$skill/SKILL.md" | grep -qx "name: $name" || fail "$skill/SKILL.md is not named $name"
    done

    [ "$status" = 0 ]
    touch "$out"
  ''
