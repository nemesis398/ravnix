#!/usr/bin/env bash
# vault-check — deterministic health check for the Obsidian vault.
# Companion to `machine-facts`: this finds, an agent judges.
# ERROR (exit 1): breaks the linking model. WARN: worth a look. INFO: expected.
#
# Tests: tests/vault-check.test.sh in this package (the check bin-vault-check).
# They stub the Obsidian CLI and date(1), so the unresolved-link check can be
# exercised without the desktop app and without waiting a week.
#
# The vault is VAULT_DIR, else the skill value vault.root, read from
# RAVNIX_SKILL_VALUES or ${XDG_CONFIG_HOME:-~/.config}/ravnix/skill-values.json
# (claude/README.md). The baseline is VAULT_CHECK_BASELINE, else
# ${XDG_CONFIG_HOME:-~/.config}/ravnix/vault-check.baseline, which the ravnix
# module writes from ravnix.scripts.vaultCheck.baseline. Neither is built in.
set -uo pipefail

BASELINE="${VAULT_CHECK_BASELINE:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/ravnix/vault-check.baseline}"

VAULT="${VAULT_DIR:-}"
if [ -z "$VAULT" ]; then
  values="${RAVNIX_SKILL_VALUES:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/ravnix/skill-values.json}"
  [ -f "$values" ] && [ -r "$values" ] &&
    VAULT=$(jq -r '(.vault.root)? | strings' "$values" 2>/dev/null </dev/null)
fi
if [ -z "$VAULT" ]; then
  echo "vault-check: no vault: set VAULT_DIR, or vault.root in ravnix.claude.skillValues" >&2
  exit 2
fi
cd "$VAULT" || { echo "vault-check: no vault at $VAULT" >&2; exit 2; }

errors=0
warns=0
say()  { printf '%-6s %s\n' "$1" "$2"; }
err()  { say ERROR "$1"; errors=$((errors+1)); }
warn() { say WARN  "$1"; warns=$((warns+1)); }

baseline_get() {
  # Everything after the first run of whitespace is the value, so a value may
  # contain spaces — link text like "../Some Server" does.
  [ -f "$BASELINE" ] || return 0
  awk -v k="$1" '
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 == k { sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, ""); print }
  ' "$BASELINE"
}
# Without the file, baseline_get() returns nothing for every key. The
# note-count check goes quiet (no reference to compare against, so it can't
# fire). The unresolved-link check does NOT go quiet: an empty accept-list
# means every unresolved link is unexpected, so it still runs and turns all
# three normally-accepted links into ERRORs. That's fail-loud and correct,
# not a no-op — say so, instead of claiming a check silently skipped when it
# actually red-gates the vault.
[ -f "$BASELINE" ] || \
  warn "baseline missing: $BASELINE — note-count check cannot run, and every accepted unresolved link becomes an ERROR"

note_files() {
  # BUGFIX (not in the brief): the original body never referenced "$@", so
  # every extra find-predicate passed by a caller (note_files -printf '%f\n',
  # note_files -size -1c) was silently discarded. That made the duplicate-
  # basename check compare full paths instead of basenames (which can never
  # collide, so the load-bearing check could never fire — Step 4 proved this
  # empirically) and made the empty-note check scan every note in the vault
  # instead of only the zero-byte ones (82 warnings instead of 2). "$@" is
  # the fix: forward whatever predicates the caller appended.
  #
  # BUGFIX (review round 2, not in the brief): a growing enumeration of
  # individual dot-directories (.obsidian, .git, .spec, .agents, .claude, ...)
  # is a losing game — Phase 3 adds .opencode/.planner/.scribe/.tutor, none
  # of which a fixed list could have anticipated, and the duplicate-basename
  # check would then fire on tool config it was never meant to see. Replaced
  # with one predicate that excludes any file inside any dot-directory at any
  # depth. This also fixes an inconsistency the list had: './.agents/*' was
  # root-anchored while '*/.claude/*' was not, so a nested .agents/ would
  # have slipped through either way.
  #
  # BUGFIX (final review, finding I6): AGENTS.md and CLAUDE.md used to be
  # excluded here, which quietly took them out of EVERY check. They are not
  # in a dot-directory, so Obsidian indexes them and renders their wikilinks —
  # a path-qualified or dangling link in the root AGENTS.md that Phase 3
  # writes would have been invisible to the gate. The exclusion belongs to
  # the duplicate-basename check alone (a root AGENTS.md and a subfolder's
  # AGENTS.md are two tool manifests, not an ambiguous bare link), so that
  # check now passes it itself.
  find . -name '*.md' -not -path '*/.*/*' -not -path '*/node_modules/*' "$@"
}

# --- ERROR: duplicate basenames -------------------------------------------
# Bare wikilinks resolve by filename. The day two notes share a basename,
# every bare link to either becomes ambiguous. This is the load-bearing invariant.
# Tool manifests are exempt: nothing links to them by name.
dupes=$(note_files -not -name 'AGENTS.md' -not -name 'CLAUDE.md' -printf '%f\n' | sort | uniq -d)
if [ -n "$dupes" ]; then
  while IFS= read -r d; do err "duplicate basename: $d"; done <<< "$dupes"
fi

# --- the link checks skip AI/specs/ and AI/plans/ ---------------------------
# Plans quote forbidden forms and placeholder links as examples, and they are
# dated records. So the path-qualified, legacy-Markdown and unresolved-link
# checks, and the stub check's search for inbound links, skip both folders,
# matched from the vault root; every other check, duplicate basenames above
# all, still counts their notes.
link_exempt=(AI/specs AI/plans)
link_exempt_find=()
for d in "${link_exempt[@]}"; do link_exempt_find+=( -not -path "./$d/*" ); done

# --- ERROR: path-qualified wikilinks --------------------------------------
# All links must be bare so folder structure stays free to change.
#
# BUGFIX (review round 2, not in the brief): this used to run grep -r over
# the whole tree with its own ad hoc exclusion list (only .obsidian and
# .spec, applied by post-filtering grep's output), which disagreed with
# note_files()'s six-pattern list. A file note_files() had just declared
# "not a note" — e.g. a subfolder's .claude/skills/NAME/SKILL.md,
# which contains a literal [[target]] documenting the bare-link rule itself
# — was still inside this check's scan set. Routing through note_files()
# gives both checks one, single source of truth for what counts as a note,
# so a future exclusion added in one place cannot leave the other stale.
# -H forces a filename prefix even when xargs hands grep a single file;
# -r on xargs avoids invoking grep with zero file operands (which would
# otherwise read stdin and hang) if the vault ever had zero notes.
#
# BUGFIX (final review, finding M2): the first path segment used to have to
# start with [A-Za-z0-9], which cannot match [[/computer/Sway]] or the
# Templater convention [[_templates/Daily]]. Neither exists today; Phase 2
# adds folders. The class is now "anything that is not a link delimiter, a
# slash, a dot or a space" (the slash and ../ cases have their own branch).
qualified=$(note_files "${link_exempt_find[@]}" -print0 \
            | xargs -0 -r grep -noHE '\[\[(\.\./|/|[^]|#/. ][^]|#]*/)[^]]+\]\]' 2>/dev/null || true)
if [ -n "$qualified" ]; then
  n=$(printf '%s\n' "$qualified" | wc -l)
  err "path-qualified wikilinks: $n (must be bare)"
  printf '%s\n' "$qualified" | head -5 | sed 's/^/       /'
fi

# --- ERROR: legacy markdown links to notes --------------------------------
# BUGFIX (final review, finding I3): '\]\([^)]*\.md\)' reported 1 of 3 cases,
# and the one it reported was not a defect —
#   [text](Other%20Note.md#anchor)  missed, the anchor sits after .md
#   [x](<Some Note.md>)             missed, the angle-bracket form
#   [y](https://example.com/README.md)  flagged, an external URL is not a link
#                                       to a note
# The pattern below allows an optional <…> wrapper and an optional #anchor;
# the second stage drops external URLs. A PCRE lookahead would fold that into
# one expression, but the two-stage form is exactly equivalent (grep -o emits
# one match per line, so the filter is per-match, not per-line), needs no
# PCRE, and leaves no fallback branch that never runs on this machine.
legacy=$(note_files "${link_exempt_find[@]}" -print0 \
         | xargs -0 -r grep -noHE '\]\(<?[^)>]*\.md(#[^)>]*)?>?\)' 2>/dev/null \
         | grep -vE '\]\(<?https?:' || true)
if [ -n "$legacy" ]; then
  n=$(printf '%s\n' "$legacy" | wc -l)
  err "legacy markdown links to .md: $n (convert to wikilinks)"
  printf '%s\n' "$legacy" | head -5 | sed 's/^/       /'
fi

# --- WARN: stub notes that something links to ------------------------------
# BUGFIX (final review): three defects at once.
#   (a) the inbound test grepped "[[$base" — an unanchored prefix, so an empty
#       Git.md counted as linked because [[Git – View history]] exists. The
#       three fixed strings below are the only three ways a bare wikilink to
#       $base can end: ]] , | (alias) , # (heading).
#   (b) that grep was a bare `grep -r .` with no exclusions at all, so it read
#       .spec/ (now AI/specs/ and AI/plans/), whose plan documents are full
#       of example wikilinks — the warning fired on plan prose rather than
#       on a real vault link. It now runs over note_files(), like every
#       other check, and skips the two folders as sources, like the link
#       checks: they are notes again since the move.
#   (c) -size -1c means exactly zero bytes, so a note holding one newline or a
#       bare "#" was missed although it is just as much a stub. "Stub" is now
#       defined by content, not by a byte threshold nobody could justify.
while IFS= read -r -d '' f; do
  [ -n "$(tr -d '[:space:]#' < "$f")" ] && continue
  base=$(basename "$f" .md)
  hit=$(note_files "${link_exempt_find[@]}" -print0 \
        | xargs -0 -r grep -lF -e "[[$base]]" -e "[[$base|" -e "[[$base#" 2>/dev/null | head -1)
  [ -n "$hit" ] && warn "stub note with inbound links: $f"
done < <(note_files -print0)

# --- WARN: note count far below the recorded reference ---------------------
# Wholesale note loss (a bad rewrite, a sync collision, a mis-aimed script)
# would otherwise sail through, because fewer notes means fewer findings.
# WARN and not ERROR by decision: notes are deleted routinely — 17 daily
# notes during Phase 1 alone — and an ERROR here would red-gate the vault
# constantly and train everyone to ignore it.
note_count=$(note_files -printf '.\n' | wc -l)
ref_count=$(baseline_get notes | head -1)
# Only check for a malformed value if the baseline exists at all — a missing
# file already warned above, and warning twice for one cause is noise. A bad
# edit ("notes ninety-six", a bare "notes" key) or sync truncation (a
# zero-byte file under ~/Nextcloud is a real scenario) used to make
# `[ "$ref_count" -gt 0 ] 2>/dev/null` fail silently, switching this check off
# without a trace. WARN just as loudly as the missing-file case does.
if [ -f "$BASELINE" ]; then
  if ! [[ "$ref_count" =~ ^[1-9][0-9]*$ ]]; then
    warn "baseline 'notes' value is not a positive integer: '${ref_count:-<empty>}' — note-count check cannot run"
  # Integer form of "live < 0.9 x reference" — no bc, no rounding argument.
  elif [ $((note_count * 10)) -lt $((ref_count * 9)) ]; then
    warn "note count $note_count is more than 10% below the baseline $ref_count — note loss, or raise 'notes' in the baseline"
  fi
fi

# --- INFO + graph checks via the Obsidian CLI ------------------------------
# FIX (final review, finding I2): the CLI answers about whatever vault the
# desktop app has open. It cannot be pointed at $VAULT_DIR, so a run against a
# copy used to print the live vault's orphans/dead-ends/aliases/unresolved
# right next to the copy's filesystem findings, with nothing saying they came
# from different trees. Refuse the mix rather than label it: for a pre-verify
# run against a copy the filesystem checks are the useful part anyway, and a
# WARN keeps a sandbox run from red-gating while still being impossible to
# miss. The unresolved-link ERROR below rides on the same CLI and is therefore
# skipped too — the gate run has VAULT_DIR unset, where it always applies.
app_vault=""
command -v obsidian >/dev/null && app_vault=$(obsidian vault info=path 2>/dev/null)
if [ -z "$app_vault" ]; then
  warn "Obsidian CLI unavailable (is the app running?) — graph checks and the unresolved-link ERROR skipped"
elif [ "$(readlink -f "$app_vault")" != "$(readlink -f "$VAULT")" ]; then
  warn "app has '$app_vault' open, not $VAULT — graph checks and the unresolved-link ERROR skipped (they cannot follow VAULT_DIR)"
else
  say INFO "orphans (no incoming):  $(obsidian orphans total)"
  say INFO "dead ends (no outgoing): $(obsidian deadends total)"
  say INFO "aliases in vault:        $(obsidian aliases total)"

  # --- ERROR: unresolved links that are not in the baseline ----------------
  # This is the only thing between the gate and a Phase 2 rewrite that turns
  # [[../learning/GIT|Git]] into a dangling [[Git|Git]]: the path-qualified
  # ERROR would clear, the gate would go green, and a dangling link would
  # merely bump a counter. The baseline is the source of truth and is never
  # written from here — dropping an accepted link has to be a deliberate edit.
  accepted=$(baseline_get unresolved)
  n_ok=$(printf '%s' "$accepted" | grep -c . || true)
  unres=$(obsidian unresolved verbose 2>/dev/null)
  rc=$?
  # BUGFIX (not in the brief): a failing `obsidian unresolved` used to leave
  # $unres empty, which is indistinguishable from "zero unresolved links" —
  # the gate went green on a vault whose links were never checked. WARN, not
  # ERROR: an unavailable CLI is an environment problem, not a vault defect.
  if [ "$rc" -ne 0 ]; then
    warn "obsidian unresolved failed (exit $rc) — unresolved-link check did not run"
  else
    n_unres=0
    n_week=0
    n_exempt=0
    if [ -n "$unres" ]; then
      n_unres=$(printf '%s\n' "$unres" | wc -l)
      # verbose prints link<TAB>count<TAB>sources, the sources joined by ", ".
      # A note name may hold ", " itself (every daily note does), so split
      # after ".md". A link is checked unless every piece is one path in
      # link_exempt. Both doubtful cases stay checked, so they fail loud: a
      # piece that still holds ", " may be a non-.md source glued to the
      # next one (no spec or plan name has a comma), and a line without
      # sources may be the CLI's "Error:" line, printed with exit 0.
      checked=$(printf '%s\n' "$unres" | awk -F'\t' '
        NR == FNR { ex[FNR] = $0 "/"; next }
        {
          n = split($3, src, /\.md, /)
          keep = (n == 0)
          for (i = 1; i <= n && !keep; i++) {
            inside = 0
            if (index(src[i], ", ") == 0)
              for (j in ex) if (index(src[i], ex[j]) == 1) inside = 1
            if (!inside) keep = 1
          }
          if (keep) print $1
        }' <(printf '%s\n' "${link_exempt[@]}") -)
      n_exempt=$((n_unres - $(printf '%s' "$checked" | grep -c . || true)))
      # -Fx: link text is data, not a regex, and must match a whole line.
      unexpected=$(printf '%s\n' "$checked" | grep -Fxv -f <(printf '%s\n' "$accepted") || true)

      # The weekly-note exemption, by pattern rather than a line per week.
      #
      # The daily-note template ends with a link to that note's own ISO week,
      # and the week note is written at harvest, through the calendar's week
      # number rather than through this link. So the link
      # dangles from a week's first daily note until its harvest, which
      # red-gated the vault every single week. It was being silenced with a
      # baseline line per week (2026-W33, added 2026-08-12), which bought seven
      # days and then needed doing again.
      #
      # Split three ways, because a missing week note means different things at
      # different times:
      #   the running week   expected, and silent. It cannot have been
      #                      harvested yet, so there is nothing to report.
      #   any other week     WARN. The user harvests irregularly, and two weeks
      #                      may be written on one day, so an ERROR would
      #                      red-gate for days at a stretch
      #                      and be learned as noise, which is the same
      #                      reasoning that makes the note-count check a WARN.
      #   anything else      unchanged: still an ERROR.
      #
      # A future week counts as "any other week" deliberately: a daily note
      # written ahead links a week that legitimately does not exist yet, and
      # gating on that would punish working ahead.
      #
      # The cost, stated plainly: a week note that is deleted or renamed lands
      # in the WARN branch instead of the ERROR one. This rule is the only
      # place where a dangling link stops gating, and it is that narrow on
      # purpose. The baseline is still consulted first and still wins, so
      # 2026-W29 stays silent rather than warning forever.
      current_week=$(date +%G-W%V)
      if [ -n "$unexpected" ]; then
        while IFS= read -r u; do
          if [[ ! "$u" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
            err "unresolved link not in baseline: $u"
          elif [ "$u" = "$current_week" ]; then
            n_week=$((n_week+1))
          else
            warn "weekly note missing: $u — harvest that week, or the link stays dangling"
          fi
        done <<< "$unexpected"
      fi
    fi
    week_note=""
    [ "$n_week" -gt 0 ] && week_note=", $n_week current week"
    exempt_note=""
    if [ "$n_exempt" -gt 0 ]; then
      printf -v ex_list '%s or ' "${link_exempt[@]}"
      exempt_note=", $n_exempt only from ${ex_list% or }"
    fi
    say INFO "unresolved links:        $n_unres ($n_ok accepted in the baseline$week_note$exempt_note)"
  fi

  # --- WARN: bases that error, or return zero rows --------------------------
  # Phase 2 added Computer.base and Runbooks.base. note_files() is a find for
  # '*.md', so a '.base' file sits outside every check above it: rename a
  # view and ![[Computer.base#All]] renders nothing in Obsidian, silently;
  # break the YAML and nothing goes red either. Query each base once, as a
  # whole (no view= here, so a renamed view needs no matching edit in this
  # script). path=, not file=: file= answers "Base file not found" for a
  # root-level base; path= is the one that actually works.
  # </dev/null on the obsidian call is load-bearing, not defensive styling:
  # without it, obsidian reads from the same fd the outer read -d '' is
  # consuming from (both inherit it from the process substitution below),
  # and the loop silently stops after Computer.base alone, one call short of
  # ever reaching Runbooks.base. Caught by actually making this fire, same
  # as the two bugs upstream of it in this file.
  #
  # BUGFIX (not in the brief): `obsidian base:query` reports a broken base
  # (missing file, unparsable YAML, an unknown view=) with an "Error: ..."
  # line on stdout and exit 0 — 2>/dev/null and an exit-code check both miss
  # it, and the row count then counted that error line as one data row, so
  # `rows -eq 0` was false and nothing ever fired. Backwards in exactly the
  # case this block exists for: silent on the base that is actually broken.
  # Detect the failure before counting rows, by matching the CLI's "Error:"
  # prefix. That is a heuristic, not a real exit code — it holds only as
  # long as the CLI keeps prefixing failures this way, not on any contract
  # it promises.
  # Kept as two distinctly-worded WARNs, not folded into one: zero rows can
  # be a perfectly good state (Computer.base's Stale view, right now, when
  # nothing is stale), while an error means the base itself cannot be read.
  # A reader needs to tell those apart at a glance. Both stay WARN, not
  # ERROR, same as before.
  while IFS= read -r -d '' b; do
    out=$(obsidian base:query path="${b#./}" format=paths </dev/null 2>/dev/null)
    if [[ "$out" == Error:* ]]; then
      warn "base:query failed for $b: $out"
    else
      rows=$(printf '%s' "$out" | grep -c .)
      [ "$rows" -eq 0 ] && warn "base returns zero rows: $b"
    fi
  done < <(find . -name '*.base' -not -path '*/.*/*' -print0)
fi

# --- ERROR/WARN: the AI memory lint ----------------------------------------
# AI/memory, AI/archive and AI/sessions feed the memory hooks, and a note the
# hooks cannot read drops out of every session without a word. The ai-memory
# skill's lint.py knows their rules; this runs it and takes its findings as
# its own: an ERROR line is a vault-check ERROR, a WARN line a WARN, each
# printed with the lint's text after vault-check's prefix.
#
# It sits outside the Obsidian CLI branch above on purpose. The lint reads
# files only, so it must still gate when the app is closed or VAULT_DIR names
# a copy. It runs only once AI/ exists, which leaves a vault without the area
# alone.
#
# Two failures must not pass for a clean AI/ folder:
#   the lint is missing   WARN. The skill is not installed or its link
#                         broke: an environment problem, not a vault defect,
#                         the same call as the unavailable Obsidian CLI.
#   the lint crashes      ERROR. A non-zero exit with no ERROR line is a
#                         traceback or a usage error, so the notes went
#                         unchecked, possibly because one of them trips the
#                         reader. The end of its output is shown, because
#                         the last traceback lines name the fault.
# --vault "$PWD": the cd above made the vault the working directory, and $PWD
# is absolute even when VAULT_DIR is relative.
ai_lint="${AI_MEMORY_LINT:-$HOME/.claude/skills/ai-memory/scripts/lint.py}"
if [ -d AI ]; then
  if [ ! -f "$ai_lint" ]; then
    warn "AI memory lint not found at $ai_lint, so AI/ went unchecked"
  else
    lint_out=$(python3 -B "$ai_lint" --vault "$PWD" 2>&1)
    lint_rc=$?
    lint_errors=0
    lint_other=()
    while IFS= read -r l; do
      case "$l" in
        "ERROR "*) err "${l#ERROR }"; lint_errors=$((lint_errors+1)) ;;
        "WARN "*)  warn "${l#WARN }" ;;
        ?*)        lint_other+=("$l") ;;
      esac
    done <<< "$lint_out"
    if [ "$lint_rc" -ne 0 ] && [ "$lint_errors" -eq 0 ]; then
      err "AI memory lint failed (exit $lint_rc), so AI/ went unchecked"
      [ "${#lint_other[@]}" -gt 0 ] && \
        printf '%s\n' "${lint_other[@]}" | tail -5 | sed 's/^/       /'
    fi
  fi
fi

# --- metric that actually matters: links per note, per folder -------------
# FIX (final review, finding M4): the folder list used to be hardcoded, with
# one folder that never existed and several that were silently absent, and the
# loop bypassed note_files() — counting 44 files in one folder where the note
# set has 35. Both the folder list and the files are now the
# note set's own, so a folder added in Phase 2 shows up without an edit here.
say INFO "--- average links per note ---"
while IFS= read -r d; do
  if [ "$d" = "." ]; then
    sel=( ! -path './*/*' ); label="(root)"
  else
    sel=( -path "./$d/*" ); label="$d"
  fi
  count=$(note_files "${sel[@]}" -printf '.\n' | wc -l)
  [ "$count" -eq 0 ] && continue
  links=$(note_files "${sel[@]}" -print0 \
          | xargs -0 -r grep -oE '\[\[[^]]+\]\]' 2>/dev/null | wc -l)
  printf '       %-24s %3d notes  %4d links  %5.1f/note\n' \
    "$label" "$count" "$links" "$(echo "scale=2; $links/$count" | bc)"
done < <(note_files -printf '%h\n' | sed -E 's|^\./||; s|/.*||' | sort -u)

echo
say SUMMARY "$errors error(s), $warns warning(s)"
[ "$errors" -gt 0 ] && exit 1
exit 0
