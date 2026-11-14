# The Claude Code modules in a home-manager configuration built from the
# template's me.nix: homeModules.claude-code puts packages.claude-code on
# PATH with the auto-updater off, and homeModules.claude-skills renders the
# skill values and wires the hooks and the status line at fixed paths. The
# hooks go into the settings file through an activation step of their own,
# which keeps every entry ravnix did not write. The evaluated settings are
# checked here; the built home is checked in the sandbox, down to running the
# wrappers and the activation's two settings steps on a file of herdr's.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
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
  values = {
    web.searxngUrl = "https://search.example.org";
    statusline.quietHosts = [ "huginn" ];
  };

  # home-manager checks the assertions, and prints the warnings, as soon as
  # anything reads config.
  hmWith =
    base: modules:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = base ++ modules;
    };
  # A home as a host has it: every ravnix option, from the template's me.nix.
  # Its warnings are the template's own, about its example values; its test
  # (tests/options) covers them, and here they would only fill the log.
  hm = hmWith [
    self.homeModules.options
    ../../templates/default/me.nix
    user
    { warnings = lib.mkForce [ ]; }
  ];
  # A home with nothing of ravnix but what a module brings itself.
  plain = hmWith [ user ];
  evaluates = home: (builtins.tryEval (builtins.deepSeq home.config.home.username true)).success;

  home = hm [
    self.homeModules.claude-code
    self.homeModules.claude-skills
    { ravnix.claude.skillValues = values; }
  ];
  inherit (home) config;
  cc = config.programs.claude-code;
  inherit (cc) settings;
  package = self.packages.${system}.claude-code;

  hooksAt = "/home/alice/.claude/ravnix/hooks";
  hook = name: timeout: {
    type = "command";
    command = "${hooksAt}/${name}";
    inherit timeout;
  };

  # The modules imported twice: the hooks must not be wired twice.
  twice = hm [
    self.homeModules.claude-code
    self.homeModules.claude-skills
    self.homeModules.claude-code
    self.homeModules.claude-skills
  ];
  # A hook of the user's own, next to ravnix's.
  own = hm [
    self.homeModules.claude-code
    self.homeModules.claude-skills
    {
      programs.claude-code.settings.hooks.SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "my-hook";
            }
          ];
        }
      ];
    }
  ];
  # The bare file, without the flake's package: refused, and with which
  # message, read from the module itself.
  bare = plain [ ../../modules/common/claude-code.nix ];
  assertionsOf =
    {
      pkg ? package,
      hookEntries ? { },
    }:
    (import ../../modules/common/claude-code.nix {
      inherit lib pkgs;
      config = {
        programs.claude-code = {
          enable = true;
          package = pkg;
          configDir = "/home/alice/.claude";
          mutableSettings = true;
        };
        home.homeDirectory = "/home/alice";
        ravnix.claude.hookEntries = hookEntries;
      };
    }).config.assertions;
  bareWith = pkg: assertionsOf { inherit pkg; };
  # A hook entry of one group with these hooks, under Stop.
  stopWith = hooks: { Stop = [ { inherit hooks; } ]; };
  refusedEntries =
    assertions:
    lib.any (a: !a.assertion && lib.hasInfix "that are not ravnix's own" a.message) assertions;
  # A hook that is not ravnix's, in a whole home: it does not evaluate.
  foreignHome = hm [
    self.homeModules.claude-code
    self.homeModules.claude-skills
    {
      ravnix.claude.hookEntries.Stop = [
        {
          hooks = [
            {
              type = "command";
              command = "python3 -B x.py";
            }
          ];
        }
      ];
    }
  ];
  # Claude Code turned off.
  off = hm [
    self.homeModules.claude-code
    self.homeModules.claude-skills
    { programs.claude-code.enable = false; }
  ];
  # Settings home-manager links whole from the store.
  immutable = hm [
    self.homeModules.claude-code
    self.homeModules.claude-skills
    { programs.claude-code.mutableSettings = false; }
  ];
  ours = config.ravnix.claude.hookEntries;
  # One of ravnix's hooks dropped.
  dropped = hm [
    self.homeModules.claude-code
    self.homeModules.claude-skills
    { ravnix.claude.hookEntries.PreToolUse = lib.mkForce [ ]; }
  ];

  checks = [
    {
      name = "no assertion fails";
      ok = evaluates home;
    }
    {
      name = "home-manager has no warning for the modules, configDir's default among them";
      ok =
        (plain [
          self.homeModules.claude-code
          self.homeModules.claude-skills
        ]).config.warnings == [ ];
    }
    {
      name = "claude-skills needs no other ravnix module, and brings claude-code along";
      ok =
        let
          alone = plain [
            self.homeModules.claude-skills
            { ravnix.claude.skillValues = values; }
          ];
        in
        evaluates alone
        && alone.config.ravnix.claude.hookEntries == ours
        && alone.config.programs.claude-code.package.outPath == package.outPath;
    }
    {
      name = "the package is ravnix's packages.claude-code, the build with its download attached";
      ok = cc.package.outPath == package.outPath && cc.finalPackage.outPath == package.outPath;
    }
    {
      name = "the package is on PATH";
      ok = lib.any (p: p.outPath == package.outPath) config.home.packages;
    }
    {
      name = "the settings are mutable and live in ~/.claude";
      ok = cc.mutableSettings && cc.configDir == "/home/alice/.claude";
    }
    {
      name = "the settings env turns the auto-updater, the telemetry and the error reports off and names the skill values";
      ok =
        settings.env == {
          DISABLE_AUTOUPDATER = "1";
          DISABLE_TELEMETRY = "1";
          DISABLE_ERROR_REPORTING = "1";
          RAVNIX_SKILL_VALUES = "/home/alice/.config/ravnix/skill-values.json";
        };
    }
    {
      name = "so do the session variables, and the user manager's for the three switches";
      ok =
        lib.all
          (
            v:
            config.home.sessionVariables.${v} or null == "1"
            && config.systemd.user.sessionVariables.${v} or null == "1"
          )
          [
            "DISABLE_AUTOUPDATER"
            "DISABLE_TELEMETRY"
            "DISABLE_ERROR_REPORTING"
          ]
        &&
          config.home.sessionVariables.RAVNIX_SKILL_VALUES == "/home/alice/.config/ravnix/skill-values.json";
    }
    {
      name = "the Artifact tool is off for every session (login shell and user manager), and not through the settings, which a launcher cannot undo";
      ok =
        config.home.sessionVariables.CLAUDE_CODE_DISABLE_ARTIFACT == "1"
        && config.systemd.user.sessionVariables.CLAUDE_CODE_DISABLE_ARTIFACT == "1"
        && !(settings.env ? CLAUDE_CODE_DISABLE_ARTIFACT);
    }
    {
      # The skills' adapters come after ravnix's own, a group each
      # (claude/skills/README.md; tests/claude/skills-render.nix).
      name = "the hooks are wired at their fixed paths, with their timeouts";
      ok =
        ours == {
          SessionStart = [
            {
              hooks = [
                (hook "prune-claude-tmp" 30)
                (hook "session-preflight" 10)
                (hook "busy-state" 5)
                (hook "claude-pane" 5)
              ];
            }
            { hooks = [ (hook "ai-memory-sessionstart" 5) ]; }
            { hooks = [ (hook "handoff-sessionstart" 30) ]; }
          ];
          UserPromptSubmit = [
            { hooks = [ (hook "busy-state" 5) ]; }
            { hooks = [ (hook "ai-memory-userpromptsubmit" 5) ]; }
          ];
          PostToolUseFailure = [ { hooks = [ (hook "ai-memory-posttoolfailure" 5) ]; } ];
          PreCompact = [ { hooks = [ (hook "handoff-precompact" 30) ]; } ];
          Stop = [
            { hooks = [ (hook "busy-state" 5) ]; }
            { hooks = [ (hook "handoff-stop" 30) ]; }
            { hooks = [ (hook "journal-stop" 30) ]; }
          ];
          StopFailure = [ { hooks = [ (hook "busy-state" 5) ]; } ];
          SessionEnd = [ { hooks = [ (hook "busy-state" 5) ]; } ];
          PreToolUse = [
            {
              matcher = "WebSearch";
              hooks = [ (hook "web-route" 5) ];
            }
          ];
          WorktreeCreate = [ { hooks = [ (hook "worktree-create" 600) ]; } ];
          WorktreeRemove = [ { hooks = [ (hook "worktree-remove" 60) ]; } ];
          SubagentStop = [ { hooks = [ (hook "worktree-subagent-stop" 30) ]; } ];
        };
    }
    {
      name = "they stay out of home-manager's merge, which would replace other tools' entries";
      ok = !(settings ? hooks);
    }
    {
      name = "ravnix's own activation step puts them in, after home-manager's merge";
      ok =
        let
          step = config.home.activation.ravnixClaudeHooks or { after = [ ]; };
        in
        lib.elem "claudeCodeSettings" step.after && lib.elem "linkGeneration" step.after;
    }
    {
      name = "with immutable settings the hooks are declared in the file instead, and the step is gone";
      ok =
        immutable.config.programs.claude-code.settings.hooks == ours
        && !(immutable.config.home.activation ? ravnixClaudeHooks);
    }
    {
      name = "the status line is wired at its fixed path";
      ok =
        settings.statusLine == {
          type = "command";
          command = "/home/alice/.claude/ravnix/statusline";
          padding = 0;
          refreshInterval = 60;
        };
    }
    {
      name = "the modules imported twice wire each hook once";
      ok =
        twice.config.ravnix.claude.hookEntries == ours
        && twice.config.programs.claude-code.settings.env == settings.env;
    }
    {
      name = "a hook of the user's own goes through home-manager's merge, and ravnix's stay its own";
      ok =
        own.config.programs.claude-code.settings.hooks == {
          SessionStart = [
            {
              hooks = [
                {
                  type = "command";
                  command = "my-hook";
                }
              ];
            }
          ];
        }
        && own.config.ravnix.claude.hookEntries == ours;
    }
    {
      name = "one of ravnix's hooks is dropped by its event, with mkForce";
      ok = dropped.config.ravnix.claude.hookEntries == ours // { PreToolUse = [ ]; };
    }
    {
      name = "a status line of the user's own replaces ravnix's, without mkForce";
      ok =
        let
          tried =
            builtins.tryEval
              (plain [
                self.homeModules.claude-code
                self.homeModules.claude-skills
                {
                  programs.claude-code.settings.statusLine = {
                    type = "command";
                    command = "my-statusline";
                  };
                }
              ]).config.programs.claude-code.settings.statusLine.command;
        in
        tried.success && tried.value == "my-statusline";
    }
    {
      name = "a hook in hookEntries that is not ravnix's own is refused, before any switch";
      ok =
        !(evaluates foreignHome)
        && lib.all (a: a.assertion) (assertionsOf {
          hookEntries = ours;
        })
        && lib.all (a: a.assertion) (assertionsOf {
          hookEntries = stopWith [
            {
              type = "command";
              command = "'/home/alice/.claude/ravnix/hooks/x'";
            }
          ];
        })
        &&
          lib.all
            (
              hookEntries:
              refusedEntries (assertionsOf {
                inherit hookEntries;
              })
            )
            [
              (stopWith [
                {
                  type = "command";
                  command = "python3 -B x.py";
                }
              ])
              (stopWith [
                {
                  type = "command";
                  command = "/home/alice/.claude/ravnix-old/x";
                }
              ])
              (stopWith [
                {
                  type = "prompt";
                  prompt = "/home/alice/.claude/ravnix/x";
                }
              ])
              (stopWith [ ])
              { Stop = [ "x" ]; }
            ];
    }
    {
      name = "the bare module without packages.claude-code is refused, by name";
      ok =
        !(evaluates bare)
        && lib.any (a: !a.assertion && lib.hasInfix "Import homeModules.claude-code" a.message) (
          bareWith pkgs.claude-code
        )
        && lib.all (a: a.assertion) (bareWith package)
        && lib.all (a: a.assertion) (bareWith null);
    }
    {
      name = "with Claude Code off there are no skill values, hooks or status line";
      ok =
        evaluates off
        && off.config.ravnix.claude.hookEntries == { }
        && off.config.home.activation ? ravnixClaudeHooks
        && !(off.config.xdg.configFile ? "ravnix/skill-values.json")
        && lib.all (f: !(lib.hasInfix "/ravnix/" f.target)) (lib.attrValues off.config.home.file);
    }
  ];

  activation = home.activationPackage;
  ownActivation = own.activationPackage;
  offActivation = off.activationPackage;
in
pkgs.runCommand "claude-home"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.jq
    ];
    hooksSrc = ../../claude/hooks;
    statuslineSrc = ../../claude/statusline;
    expectedValues = builtins.toJSON values;
  }
  ''
    # Every check reports, failed or not; the build fails at the end.
    set +e
    fail=0
    check() {
      if [ "$2" = 0 ]; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi
    }
    ${lib.concatMapStrings (c: ''
      check ${lib.escapeShellArg c.name} ${if c.ok then "0" else "1"}
    '') checks}

    hf=$(readlink -f ${activation}/home-files)
    hp=$(readlink -f ${activation}/home-path)

    # The skill values, as the module renders them.
    jq -S . "$hf/.config/ravnix/skill-values.json" >values.json 2>/dev/null
    printf '%s' "$expectedValues" | jq -S . >expected.json
    cmp -s values.json expected.json
    check "skill-values.json holds ravnix.claude.skillValues" $?

    # Every hook and the status line: an executable wrapper whose script is
    # the file in claude/.
    for name in prune-claude-tmp session-preflight web-route worktree-create worktree-remove worktree-subagent-stop busy-state; do
      w=$hf/.claude/ravnix/hooks/$name
      script=$(grep -o '/nix/store/[^ ]*-'"$name"'\.sh' "$w" 2>/dev/null | head -n 1)
      [ -x "$w" ] && [ -n "$script" ] && cmp -s "$script" "$hooksSrc/$name.sh"
      check "hooks/$name runs claude/hooks/$name.sh" $?
    done
    w=$hf/.claude/ravnix/statusline
    script=$(grep -o '/nix/store/[^ ]*-statusline\.sh' "$w" 2>/dev/null | head -n 1)
    [ -x "$w" ] && [ -n "$script" ] && cmp -s "$script" "$statuslineSrc/statusline.sh"
    check "statusline runs claude/statusline/statusline.sh" $?

    # The wrappers work with an empty environment: their tools come along.
    got=$(env -i HOSTNAME=huginn RAVNIX_SKILL_VALUES="$hf/.config/ravnix/skill-values.json" \
      "$hf/.claude/ravnix/statusline" <<<'{"session_id":"abcdefgh-1234"}' 2>&1)
    [ "$got" = abcdefgh ]
    check "the status line runs with no PATH, and huginn is quiet ($got)" $?
    got=$(env -i HOSTNAME=muninn NO_COLOR=1 RAVNIX_SKILL_VALUES="$hf/.config/ravnix/skill-values.json" \
      "$hf/.claude/ravnix/statusline" <<<'{"session_id":"abcdefgh-1234"}' 2>&1)
    [ "$got" = "muninn · abcdefgh" ]
    check "and muninn gets its tag ($got)" $?
    # Claude Code leaves the session kind in its own environment only, and
    # the status line reads it from its parent's: the wrapper must exec, or
    # it would be that parent.
    got=$(env -i CLAUDE_CODE_SESSION_KIND=bg ${lib.getExe pkgs.bash} -c '"$@"; exit $?' parent \
      "$(command -v env)" -i HOSTNAME=huginn RAVNIX_SKILL_VALUES="$hf/.config/ravnix/skill-values.json" \
      "$hf/.claude/ravnix/statusline" <<<'{"session_id":"abcdefgh-1234"}' 2>&1)
    [ "$got" = "bg · abcdefgh" ]
    check "the status line still sees its parent's session kind through the wrapper ($got)" $?
    # A root it refuses, in a dry run: the refusal needs the wrapper's id and
    # jq, and nothing is pruned either way.
    mkdir -p home
    got=$(env -i HOME="$PWD/home" PRUNE_TMP_ROOT=/ PRUNE_TMP_DRY_RUN=1 \
      "$hf/.claude/ravnix/hooks/prune-claude-tmp" <<<'{}' 2>&1)
    rc=$?
    [[ $rc = 0 && $got == '{"systemMessage":"prune-claude-tmp pruned nothing: PRUNE_TMP_ROOT=/ is not /tmp/claude-'* ]]
    check "prune-claude-tmp runs with no PATH ($got)" $?
    got=$(env -i HOME="$PWD/home" RAVNIX_SKILL_VALUES=/nonexistent \
      "$hf/.claude/ravnix/hooks/session-preflight" <<<'{}' 2>&1)
    check "session-preflight runs with no PATH" $([ $? = 0 ] && [ -z "$got" ] && echo 0 || echo 1)
    got=$(env -i HOME="$PWD/home" "$hf/.claude/ravnix/hooks/web-route" \
      <<<'{"tool_name":"WebSearch","tool_input":{"query":"q"}}' 2>&1)
    check "web-route runs with no PATH" $([ $? = 0 ] && [ -z "$got" ] && echo 0 || echo 1)
    sid=0a1b2c3d-1111-4222-8333-444455556666
    got=$(env -i HOME="$PWD/home" "$hf/.claude/ravnix/hooks/busy-state" \
      <<<"{\"session_id\":\"$sid\",\"hook_event_name\":\"UserPromptSubmit\"}" 2>&1)
    [ $? = 0 ] && [ -z "$got" ] && [ "$(cat "$PWD/home/.local/state/ravnix/claude-busy/$sid")" = busy ]
    check "busy-state runs with no PATH" $?
    # claude-pane is claude-roll's record, from the tool's package.
    grep -q -E '^exec /nix/store/[a-z0-9]+-claude-roll[^ ]*/bin/claude-roll record$' "$hf/.claude/ravnix/hooks/claude-pane"
    check "hooks/claude-pane runs claude-roll record" $?
    got=$(env -i HOME="$PWD/home" "$hf/.claude/ravnix/hooks/claude-pane" <<<'{}' 2>&1)
    check "claude-pane runs with no PATH, outside herdr" $([ $? = 0 ] && [ -z "$got" ] && echo 0 || echo 1)
    got=$(env -i HOME="$PWD/home" HERDR_PANE_ID=w1:p1 "$hf/.claude/ravnix/hooks/claude-pane" 2>/dev/null <<<"{\"session_id\":\"$sid\"}")
    [ $? = 0 ] && [ -z "$got" ] && [ ! -e "$PWD/home/.local/state/ravnix/claude-panes/w1:p1.json" ]
    check "claude-pane exits 0 and writes nothing without a Claude Code above it" $?

    # The settings file home-manager merges into ~/.claude/settings.json:
    # no hooks, which would replace the file's own.
    sf=$(grep -o '/nix/store/[a-z0-9]*-claude-code-settings.json' ${activation}/activate | head -n 1)
    [ -n "$sf" ] &&
      [ "$(jq 'has("hooks")' "$sf")" = false ] &&
      [ "$(jq -r '.env.DISABLE_AUTOUPDATER' "$sf")" = 1 ] &&
      [ "$(jq -r '.statusLine.command' "$sf")" = /home/alice/.claude/ravnix/statusline ]
    check "home-manager merges env and the status line into ~/.claude/settings.json, and no hooks" $?

    # The activation's two settings steps, as the activate script runs them,
    # on a settings file here instead of /home/alice's: home-manager's merge,
    # then ravnix's step.
    # steps <activation> <name>...: the named steps of its activate script.
    steps() {
      local activate=$1/activate name
      shift
      echo 'errorEcho() { echo "$@" >&2; }'
      for name; do
        awk -v s="$name" '
          $0 == "_iNote \"Activating %s\" \"" s "\"" { on = 1; next }
          on && /^_iNote "Activating %s"/ { exit }
          on' "$activate"
      done
    }
    # switch <activation> <name>...: runs those steps on ./settings.json,
    # with the shell options of the activate script.
    switch() {
      local script
      script=$(steps "$@")
      [ -n "$script" ] || return 1
      ${lib.getExe pkgs.bash} -eu -o pipefail -c "''${script//\/home\/alice\/.claude\/settings.json/$PWD/settings.json}"
    }
    # commands <event>: the commands of an event's hooks, in order.
    commands() { jq -c --arg e "$1" '[.hooks[$e] // [] | .[].hooks[].command]' settings.json; }
    herdr="bash '/home/alice/.config/herdr/integrations/claude/herdr-agent-state.sh' session"
    jq -n --arg herdr "$herdr" '{
      model: "opus",
      hooks: {
        SessionStart: [{matcher: "startup", hooks: [{type: "command", command: $herdr, timeout: 10}]}],
        PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "my-check"}]}],
        Stop: [{hooks: [{type: "command", command: "/home/alice/.claude/ravnix/hooks/old-hook"}]}]
      }
    }' >settings.json
    switch ${activation} claudeCodeSettings ravnixClaudeHooks
    rc=$?
    [ "$rc" = 0 ] &&
      [ "$(commands SessionStart)" = "$(jq -cn --arg h "$herdr" '[$h, "/home/alice/.claude/ravnix/hooks/prune-claude-tmp", "/home/alice/.claude/ravnix/hooks/session-preflight", "/home/alice/.claude/ravnix/hooks/busy-state", "/home/alice/.claude/ravnix/hooks/claude-pane", "/home/alice/.claude/ravnix/hooks/ai-memory-sessionstart", "/home/alice/.claude/ravnix/hooks/handoff-sessionstart"]')" ] &&
      [ "$(commands PreToolUse)" = '["my-check","/home/alice/.claude/ravnix/hooks/web-route"]' ] &&
      [ "$(commands Stop)" = '["/home/alice/.claude/ravnix/hooks/busy-state","/home/alice/.claude/ravnix/hooks/handoff-stop","/home/alice/.claude/ravnix/hooks/journal-stop"]' ] &&
      [ "$(jq -r '.model + " " + .env.DISABLE_AUTOUPDATER + " " + .statusLine.command' settings.json)" = "opus 1 /home/alice/.claude/ravnix/statusline" ]
    check "a switch keeps herdr's and a hand-wired entry, adds ravnix's, and drops a stale one of ravnix's" $?
    cp settings.json first.json
    switch ${activation} claudeCodeSettings ravnixClaudeHooks
    [ $? = 0 ] && cmp -s settings.json first.json
    check "a second switch changes nothing" $?
    cp first.json settings.json
    switch ${ownActivation} claudeCodeSettings ravnixClaudeHooks
    [ $? = 0 ] &&
      [ "$(commands SessionStart)" = '["my-hook","/home/alice/.claude/ravnix/hooks/prune-claude-tmp","/home/alice/.claude/ravnix/hooks/session-preflight","/home/alice/.claude/ravnix/hooks/busy-state","/home/alice/.claude/ravnix/hooks/claude-pane","/home/alice/.claude/ravnix/hooks/ai-memory-sessionstart","/home/alice/.claude/ravnix/hooks/handoff-sessionstart"]' ]
    check "a SessionStart hook declared in Nix replaces the file's list, herdr's too, and ravnix's join it" $?
    cp first.json settings.json
    switch ${offActivation} ravnixClaudeHooks
    [ $? = 0 ] &&
      [ "$(jq -c '[.hooks[][].hooks[].command]' settings.json)" = "$(jq -cn --arg h "$herdr" '[$h, "my-check"]')" ]
    check "with Claude Code off the next switch removes ravnix's entries and keeps the others" $?

    # claude on PATH: packages.claude-code, with the auto-updater off in its
    # wrapper, and it runs.
    claude=$(readlink -f "$hp/bin/claude")
    [ "$claude" = "$(readlink -f ${package}/bin/claude)" ]
    check "claude on PATH is packages.claude-code" $?
    # The wrapper's environment entry, a whole NUL-terminated string, so a
    # wrapper that sets it to anything else fails.
    tr '\0' '\n' <"$claude" | grep -q -x 'DISABLE_AUTOUPDATER=1'
    check "its wrapper sets DISABLE_AUTOUPDATER=1" $?
    version=$(HOME="$PWD/home" "$hp/bin/claude" --version 2>&1)
    [ "''${version%% *}" = ${lib.escapeShellArg package.version} ]
    check "claude --version prints ${package.version} ($version)" $?

    [ "$fail" = 0 ] || exit 1
    touch "$out"
  ''
