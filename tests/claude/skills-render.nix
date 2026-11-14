# The public skills as a home has them (claude/skills/README.md): rendered
# with the skill values by lib/claude-skills.nix, linked at
# ~/.claude/skills/NAME, their hook adapters wired, a skill of the user's own
# beside them, one replaced and one left out. The evaluated home is checked
# here, the rendered trees in the sandbox: no placeholder left with every
# value set, a stop line for each key that is not, frontmatter that still
# parses as YAML, and the adapters run from the tree.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  user = {
    home = {
      username = "alice";
      homeDirectory = "/home/alice";
      stateVersion = "26.05";
    };
  };
  full = {
    user.name = "Alice";
    vault.root = "/home/alice/Notes";
    journal = {
      protectedSection = "## 🗒️ Logbook";
      # Two lines, and a placeholder that must stay as it is.
      languageRule = "German for the client and the law.\nEnglish for tooling, {{user.name}} literal.";
    };
    memory.domains.homelab = [
      "docker"
      "caddy"
    ];
    handoff.workspaces.home = {
      default = true;
      projects.NOTES = {
        id = "00000000-0000-0000-0000-000000000000";
        name = "Notes";
        dirs = [ "/home/alice/Notes" ];
      };
    };
    plane.mcpUrl = "https://plane.example.org/mcp";
    prose = {
      languageRule = "- Alice's own notes are **English** by default.";
      languagetool.item = "LanguageTool";
      languagetool.username = "alice@example.org";
      ignoreWords = [ "Zettelkasten" ];
    };
    laptop = {
      model = "Example Book 14, one GPU";
      checkout = "/home/alice/Git/ravnix";
      privateFlake = "/home/alice/Git/private";
      note = "/home/alice/Notes/Laptop.md";
      # Not huginn, so the guard is seen to compare with the value.
      hostName = "corvid";
    };
  };

  hm =
    modules:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.claude-skills
        user
      ]
      ++ modules;
    };
  withValues = values: (hm [ { ravnix.claude.skillValues = values; } ]).config;
  fullHome = withValues full;
  emptyHome = withValues { };
  custom =
    (hm [
      {
        ravnix.claude.skillValues = full;
        ravnix.claude.skills = {
          laptop = null;
          handoff = ./fixtures/own-skill;
          own-skill = ./fixtures/own-skill;
        };
      }
    ]).config;
  # As the NixOS module forwards a definition of the private flake's
  # (modules/common/nixos.nix): at lib.mkDefault, the whole set at once.
  forwarded =
    (hm [
      {
        ravnix.claude.skillValues = full;
        ravnix.claude.skills = lib.mkDefault { own-skill = ./fixtures/own-skill; };
      }
    ]).config;

  overrides = {
    json-canvas = "off";
    tutor = "user-invocable-only";
    handoff = "name-only";
    prose = "on";
  };
  withOverrides = (hm [ { ravnix.claude.skillOverrides = overrides; } ]).config;
  # As NixOS forwards it, at lib.mkDefault.
  forwardedOverrides = (hm [ { ravnix.claude.skillOverrides = lib.mkDefault overrides; } ]).config;
  rejects =
    value:
    !(builtins.tryEval (
      builtins.deepSeq (hm [ { ravnix.claude.skillOverrides.x = value; } ])
        .config.programs.claude-code.settings.skillOverrides
        null
    )).success;

  skillLib = import ../../lib/claude-skills.nix { inherit lib; };
  skillMd =
    name: values:
    (skillLib.renderSkill {
      inherit name values;
      dir = ../../claude/skills + "/${name}";
      python = "python3";
      skillsDir = "/s";
    }).md."SKILL.md";
  noLanguageTool = lib.recursiveUpdate full { prose.languagetool = { item = ""; username = ""; }; };
  names = skillLib.names ../../claude/skills;
  expected = [
    "ai-memory"
    "conscience"
    "conventional-commits"
    "handoff"
    "journal"
    "laptop"
    "prose"
    "simplify-changes"
  ];
  skillsAt = "/home/alice/.claude/skills";
  hooksAt = "/home/alice/.claude/ravnix/hooks";
  linked = config: lib.filter (p: lib.hasPrefix "${skillsAt}/" p) (lib.attrNames config.home.file);
  sourceOf = config: name: toString config.home.file."${skillsAt}/${name}".source;
  rendered = config: lib.head (lib.splitString "/" (lib.removePrefix "/nix/store/" (sourceOf config "handoff")));
  commands =
    config: event:
    map (h: h.command) (lib.concatMap (g: g.hooks) (config.ravnix.claude.hookEntries.${event} or [ ]));
  hook = name: "${hooksAt}/${name}";
  adapters = {
    SessionStart = [
      "handoff-sessionstart"
      "ai-memory-sessionstart"
    ];
    Stop = [
      "handoff-stop"
      "journal-stop"
    ];
    PreCompact = [ "handoff-precompact" ];
    UserPromptSubmit = [ "ai-memory-userpromptsubmit" ];
    PostToolUseFailure = [ "ai-memory-posttoolfailure" ];
  };
  hasAll = config: event: wanted: lib.all (n: lib.elem (hook n) (commands config event)) wanted;
  hasNone = config: event: lib.all (n: !(lib.elem (hook n) (commands config event)));
  timeoutOf =
    config: event: name:
    (lib.findFirst (h: h.command == hook name) { timeout = null; } (
      lib.concatMap (g: g.hooks) config.ravnix.claude.hookEntries.${event}
    )).timeout;

  render = values: skillLib.render {
    inherit pkgs values;
    src = ../../claude/skills;
    skillsDir = skillsAt;
  };
  text =
    values: t:
    (skillLib.renderText {
      inherit values;
      internal = { };
    } t).text;
  missing = values: t: (skillLib.renderText { inherit values; internal = { }; } t).missing;
  frontText =
    values: t:
    (skillLib.renderText {
      inherit values;
      internal = { };
      inFrontmatter = true;
    } t).text;

  checks = [
    {
      name = "claude/skills holds the eight skills";
      ok = names == expected;
    }
    {
      name = "every skill is linked at ~/.claude/skills/NAME, from one rendered tree";
      ok =
        lib.sort lib.lessThan (linked fullHome) == map (n: "${skillsAt}/${n}") expected
        && lib.all (n: sourceOf fullHome n == "/nix/store/${rendered fullHome}/${n}") expected;
    }
    {
      name = "with every value set no skill misses one";
      ok = lib.all (m: m == [ ]) (lib.attrValues (render full).passthru.missing);
    }
    {
      name = "without values each skill names the keys it misses, and conscience none";
      ok = (render { }).passthru.missing == {
        ai-memory = [
          "user.name"
          "vault.root"
        ];
        conscience = [ ];
        conventional-commits = [ "user.name" ];
        handoff = [
          "user.name"
          "handoff.workspaces"
          "plane.mcpUrl"
        ];
        journal = [
          "user.name"
          "journal.protectedSection"
          "journal.languageRule"
          "vault.root"
        ];
        laptop = [
          "user.name"
          "laptop.model"
          "laptop.checkout"
          "laptop.privateFlake"
          "laptop.note"
          "laptop.hostName"
        ];
        prose = [
          "user.name"
          "prose.languageRule"
          "prose.languagetool.item"
          "prose.languagetool.username"
        ];
        simplify-changes = [ "user.name" ];
      };
    }
    {
      name = "a key the scripts read must be of its type: an empty layout or a list is not set";
      ok =
        lib.elem "handoff.workspaces" (render (full // { handoff.workspaces = { }; })).passthru.missing.handoff
        && lib.elem "plane.mcpUrl" (render (full // { plane.mcpUrl = [ "x" ]; })).passthru.missing.handoff;
    }
    {
      name = "prose without the LanguageTool account names it, and nothing else";
      ok =
        (render (lib.recursiveUpdate full { prose.languagetool.username = ""; })).passthru.missing.prose
        == [ "prose.languagetool.username" ];
    }
    {
      name = "an account left at a documentation placeholder warns like any value";
      ok =
        let
          eval = import ../options/helpers/eval.nix { inherit lib self; };
          # The template gives every option a value, as the walk reads them all.
          warned = (eval [ ../../templates/default/me.nix { ravnix.claude.skillValues = full; } ]).config.warnings;
        in
        lib.any (w: lib.hasPrefix "ravnix.claude.skillValues.prose.languagetool.username is " w) warned;
    }
    {
      name = "prose without the LanguageTool values stops LanguageTool only: --no-lt, and the rest holds";
      ok =
        let
          md = skillMd "prose" noLanguageTool;
        in
        lib.hasInfix "LanguageTool is not set up" md
        && lib.hasInfix "--no-lt" md
        && lib.hasInfix "set `prose.languagetool.item` in your ravnix skill values" md
        && lib.hasInfix "set `prose.languagetool.username` in your ravnix skill values" md
        && !(lib.hasInfix "this skill is not set up" md);
    }
    {
      name = "prose without a value its text needs still stops whole, and names the LanguageTool values too";
      ok =
        let
          md = skillMd "prose" (lib.recursiveUpdate noLanguageTool { user.name = ""; });
        in
        lib.hasInfix "this skill is not set up" md
        && lib.hasInfix "set `user.name` in your ravnix skill values" md
        && lib.hasInfix "set `prose.languagetool.username` in your ravnix skill values" md;
    }
    {
      name = "journal's prose gate passes on --no-lt when LanguageTool is not set up";
      ok =
        let
          md = skillMd "journal" full;
          gate = lib.elemAt (lib.splitString "## Writing it" (lib.elemAt (lib.splitString "## The prose gate" md) 1)) 0;
        in
        lib.hasInfix "--no-lt" gate && lib.hasInfix "in your ravnix skill values" gate;
    }
    {
      name = "a value goes in once: a placeholder inside it stays literal";
      ok = text { a = "{{b}}"; b = "no"; } "x {{a}} y" == "x {{b}} y";
    }
    {
      name = "a number is a value, a blank string, a list and a set are not";
      ok =
        text { n = 3; } "{{n}}" == "3"
        && missing { s = "  "; } "{{s}}" == [ "s" ]
        && missing { l = [ "x" ]; } "{{l}}" == [ "l" ]
        && missing { a.b = "c"; } "{{a}}" == [ "a" ]
        && text { } "{{a.b}}" == "`a.b`";
    }
    {
      name = "in the frontmatter a value's line breaks run together";
      ok = frontText { v = "one\n  two\n"; } "d: {{v}}" == "d: one   two";
    }
    {
      name = "text that only looks like a placeholder stays as it is";
      ok = text { } "{{ spaced }} {single} {{}} {{a b}}" == "{{ spaced }} {single} {{}} {{a b}}";
    }
    {
      name = "a ravnix.* name ravnix does not know fails the build";
      ok = !(builtins.tryEval (builtins.deepSeq (text { } "{{ravnix.nothing}}") true)).success;
    }
    {
      name = "the adapters are wired at ~/.claude/ravnix/hooks/NAME, each under its event";
      ok = lib.all (event: hasAll fullHome event adapters.${event}) (lib.attrNames adapters);
    }
    {
      name = "ravnix's other hooks stay beside the adapters";
      ok =
        lib.elem (hook "busy-state") (commands fullHome "Stop")
        && lib.elem (hook "prune-claude-tmp") (commands fullHome "SessionStart");
    }
    {
      name = "handoff and journal get 30 s, ai-memory 5 s";
      ok =
        timeoutOf fullHome "Stop" "handoff-stop" == 30
        && timeoutOf fullHome "Stop" "journal-stop" == 30
        && timeoutOf fullHome "UserPromptSubmit" "ai-memory-userpromptsubmit" == 5;
    }
    {
      name = "each adapter's wrapper is linked beside the other hooks";
      ok = lib.all (n: fullHome.home.file ? "${hooksAt}/${n}") (lib.concatLists (lib.attrValues adapters));
    }
    {
      name = "without values the skills and their hooks are still there (the skill says what to set)";
      ok =
        lib.length (linked emptyHome) == 8
        && lib.all (event: hasAll emptyHome event adapters.${event}) (lib.attrNames adapters);
    }
    {
      name = "a skill left out is not linked";
      ok = !(lib.elem "${skillsAt}/laptop" (linked custom));
    }
    {
      name = "a skill of the user's own is linked as it is";
      ok = sourceOf custom "own-skill" == toString ./fixtures/own-skill;
    }
    {
      name = "a skill of the user's own replaces ravnix's of that name";
      ok = sourceOf custom "handoff" == toString ./fixtures/own-skill;
    }
    {
      name = "a definition at lib.mkDefault, as NixOS forwards it, adds to ravnix's skills";
      ok =
        sourceOf forwarded "own-skill" == toString ./fixtures/own-skill
        && lib.all (n: lib.elem "${skillsAt}/${n}" (linked forwarded)) expected;
    }
    {
      name = "skillOverrides go into the settings as Claude Code's skillOverrides, by name";
      ok =
        withOverrides.programs.claude-code.settings.skillOverrides == overrides
        && forwardedOverrides.programs.claude-code.settings.skillOverrides == overrides;
    }
    {
      name = "without skillOverrides the settings have no skillOverrides key";
      ok = !(fullHome.programs.claude-code.settings ? skillOverrides);
    }
    {
      name = "a skillOverrides value Claude Code does not know is refused";
      ok = rejects "disabled" && rejects "Off" && rejects true && rejects "";
    }
    {
      name = "the others stay ravnix's";
      ok = lib.hasSuffix "/journal" (sourceOf custom "journal") && lib.hasPrefix "/nix/store/" (sourceOf custom "journal");
    }
    {
      name = "a replaced skill's hooks stay wired and do nothing without its adapter; a skill left out has none";
      ok = hasAll custom "Stop" [ "handoff-stop" "journal-stop" ];
    }
    {
      name = "with Claude Code off no skill is linked and no adapter wired";
      ok =
        let
          off = (hm [ { programs.claude-code.enable = false; } ]).config;
        in
        linked off == [ ] && hasNone off "Stop" [ "handoff-stop" "journal-stop" ];
    }
  ];
  failed = lib.filter (c: !c.ok) checks;

  fullTree = render full;
  emptyTree = render { };
  ownTree = render (full // { handoff.workspaces = { }; });
  yaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  wrapper = fullHome.home.file."${hooksAt}/handoff-stop".source;
in
if failed != [ ] then
  throw "claude-skills-render:\n${lib.concatMapStrings (c: "- ${c.name}\n") failed}"
else
  pkgs.runCommand "claude-skills-render"
    {
      nativeBuildInputs = [
        yaml
        pkgs.ripgrep
        pkgs.git
      ];
    }
    ''
      status=0
      check() { if [ "$2" = 0 ]; then echo "ok: $1"; else echo "FAIL: $1"; status=1; fi; }
      cd ${fullTree}

      ! rg -n --glob '*.md' '[{][{][A-Za-z0-9_.-]+[}][}]' . | rg -v 'journal/SKILL.md:.*English for tooling, [{][{]user.name[}][}] literal'
      check "with every value set no placeholder is left, but the one inside a value" $?
      ! rg -l 'this skill is not set up' .
      check "and no skill tells to stop" $?
      rg -q 'when Alice says handoff' handoff/SKILL.md
      check "the user's name is in the handoff description" $?
      rg -qF '${lib.getExe pkgs.python3} -B ${skillsAt}/handoff/scripts/handoff_state.py projects' handoff/SKILL.md
      check "the scripts are run by the store path of python3 and the installed path" $?
      rg -qF '${skillsAt}/prose/scripts/check.py' journal/SKILL.md
      check "journal runs prose's checker from beside it" $?
      rg -q '^German for the client and the law.$' journal/SKILL.md
      check "a value of two lines goes into the body as two lines" $?
      [ ! -e handoff/projects.json ] && [ ! -e ai-memory/domains.json ]
      check "no layout and no domain list ship with the skills" $?
      [ ! -e README.md ]
      check "the README of claude/skills is no skill and is not installed" $?

      python3 - <<'PY' || status=1
      import pathlib, sys, yaml
      bad = 0
      for tree in ("${fullTree}", "${emptyTree}"):
          for skill in sorted(pathlib.Path(tree).iterdir()):
              text = (skill / "SKILL.md").read_text(encoding="utf-8")
              front = text.split("\n---\n", 1)[0].removeprefix("---\n")
              meta = yaml.safe_load(front)
              desc = meta.get("description", "")
              ok = meta.get("name") == skill.name and isinstance(desc, str) and 0 < len(desc) <= 1024
              print(("ok" if ok else "FAIL") + f": {tree[-40:]} {skill.name}: the frontmatter parses, {len(desc)} characters of description")
              bad += not ok
      sys.exit(1 if bad else 0)
      PY

      for skill in ${emptyTree}/*/; do
        name=$(basename "$skill")
        if [ "$name" = conscience ]; then
          ! rg -q 'this skill is not set up' "$skill/SKILL.md"
          check "without values conscience, which needs none, does not stop" $?
        else
          rg -q 'set `user.name` in your ravnix skill values' "$skill/SKILL.md"
          check "without values $name says to set user.name" $?
        fi
      done
      rg -A12 'this skill is not set up' ${emptyTree}/handoff/SKILL.md | rg -q 'set `plane.mcpUrl` in your ravnix skill values'
      check "the stop lines name the keys the scripts read too, right below the frontmatter" $?
      rg -q 'set `handoff.workspaces` in your ravnix skill values' ${ownTree}/handoff/SKILL.md
      check "an empty board layout is no layout" $?

      export HOME=$TMPDIR/home RAVNIX_SKILL_VALUES=$TMPDIR/none.json HANDOFF_STATE_ROOT=$TMPDIR/state
      mkdir -p "$HOME"
      got=$(echo '{}' | python3 -B ${fullTree}/handoff/adapters/claude/stop.py) && rc=0 || rc=$?
      [ "$rc" = 0 ] && [ -z "$got" ]
      check "an adapter runs from the rendered tree and stays quiet on an empty payload" $?
      got=$(echo '{}' | ${pkgs.bash}/bin/bash ${wrapper}) && rc=0 || rc=$?
      [ "$rc" = 0 ] && [ -z "$got" ]
      check "a wrapper whose skill is not installed ends 0 and prints nothing" $?
      got=$(python3 -B ${fullTree}/handoff/scripts/handoff_state.py projects --cwd /tmp 2>&1) && rc=0 || rc=$?
      [ "$rc" = 2 ] && [ "$got" = 'handoff_state: set `handoff.workspaces` in your ravnix skill values' ]
      check "a script of the tree without the value names it" $?

      # The laptop skill's build-and-switch block, as an agent would run it,
      # with nix, sudo and hostname stubbed: on a host other than the
      # configured laptop.hostName (here corvid, even on one called huginn)
      # it stops before sudo, and on corvid it switches.
      work=$TMPDIR/laptop; mkdir -p "$work/stub" "$work/checkout"
      for c in nix sudo; do
        printf '#!/bin/sh\necho "%s $*" >> %s\n' "$c" "$work/calls" > "$work/stub/$c"
      done
      printf '#!/bin/sh\necho "$FAKE_HOST"\n' > "$work/stub/hostname"
      chmod +x "$work"/stub/*
      block=$(awk '/^[*][*]Changing the desktop[*][*]/ { f = 1 } f && /^```bash$/ { b = 1; next } b && /^```$/ { exit } b' ${fullTree}/laptop/SKILL.md)
      block=''${block//\/home\/alice\/Git\/ravnix/$work\/checkout}
      for other in muninn huginn; do
        rm -f "$work/calls"
        FAKE_HOST=$other PATH=$work/stub:$PATH ${pkgs.bash}/bin/bash -c "$block" >/dev/null 2>&1 && rc=0 || rc=$?
        [ "$rc" != 0 ] && ! grep -q '^sudo' "$work/calls" 2>/dev/null
        check "on $other, not the configured laptop, the switch step stops before sudo" $?
      done
      rm -f "$work/calls"
      FAKE_HOST=corvid PATH=$work/stub:$PATH ${pkgs.bash}/bin/bash -c "$block" >/dev/null 2>&1 && rc=0 || rc=$?
      [ "$rc" = 0 ] && grep -qx 'sudo nixos-rebuild switch --flake /home/alice/Git/private#huginn --override-input ravnix git+file:.' "$work/calls"
      check "on the configured laptop the switch step switches" $?
      awk '/^## Start here/,/^## Which/' ${fullTree}/laptop/SKILL.md | rg -q 'hostname' && rc=0 || rc=$?
      check "the laptop skill's first steps check the host" $rc

      # journal's prose gate without the LanguageTool values: the check names
      # them and stops, and --no-lt passes a clean note.
      printf 'A plain sentence, nothing more.\n' > "$TMPDIR/note.md"
      got=$(RAVNIX_SKILL_VALUES=$TMPDIR/none.json python3 -B ${fullTree}/prose/scripts/check.py "$TMPDIR/note.md" 2>&1) && rc=0 || rc=$?
      [ "$rc" = 2 ] && printf '%s\n' "$got" | grep -qF 'set `prose.languagetool.username` in your ravnix skill values'
      check "without the LanguageTool values the checker names them and exits 2" $?
      RAVNIX_SKILL_VALUES=$TMPDIR/none.json python3 -B ${fullTree}/prose/scripts/check.py --no-lt "$TMPDIR/note.md" >/dev/null 2>&1 && rc=0 || rc=$?
      [ "$rc" = 0 ]
      check "and with --no-lt a clean note passes the gate" $?

      [ "$status" = 0 ] || exit 1
      touch "$out"
    ''
