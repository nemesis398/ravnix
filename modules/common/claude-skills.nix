# The public skill framework of Claude Code, as a home-manager module: the
# skill values, the hooks and the status line (claude/README.md).
#
# The skill values are ravnix.claude.skillValues, rendered to
# ~/.config/ravnix/skill-values.json and named by RAVNIX_SKILL_VALUES, in
# the session variables and in Claude Code's settings env, so the skills,
# the hooks and the status line all read the one file. They are personal
# values, never secrets: the file is in the world-readable store.
#
# Each hook is a small wrapper that puts the tools it needs first on PATH
# and execs bash on the script in claude/, the very file its tests run. The
# exec keeps the process: the status line reads its parent's environment,
# and worktree-subagent-stop.sh starts itself again by its own path. The
# user's PATH stays behind the tools, for what ravnix does not install
# (netbird, searx, pnpm, npm, uv).
#
# The wrappers are linked at fixed paths, <configDir>/ravnix/hooks/<name>
# and <configDir>/ravnix/statusline, and the settings name those paths
# rather than the store: a session that outlives a switch or a garbage
# collection still finds every hook.
#
# The skills of claude/skills/ are rendered with the skill values
# (lib/claude-skills.nix) into one tree and linked, a directory each, at
# <configDir>/skills/NAME, beside whatever ravnix.claude.skills adds. The
# hook adapters of handoff, journal and ai-memory join the hooks below, each
# behind a wrapper at <configDir>/ravnix/hooks/NAME, and only while its skill
# is installed.
#
# Without programs.claude-code enabled this module does nothing.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
  valuesFile = "${config.xdg.configHome}/ravnix/skill-values.json";
  dir = "${cfg.configDir}/ravnix";

  ravnixPackages = import ../../lib/ravnix-packages.nix { inherit lib; } {
    packagesDir = ../../packages;
    toolsDir = ../../tools;
  };
  # pkgs.ravnix comes from the overlay that nixosModules.common applies; a
  # home-manager configuration without it (the tests') gets the same tools
  # from the same overlay here, as modules/common/scripts.nix does.
  ravnix = pkgs.ravnix or (pkgs.extend ravnixPackages.overlay).ravnix;

  skillLib = import ../../lib/claude-skills.nix { inherit lib; };
  skillsDir = "${cfg.configDir}/skills";
  python = lib.getExe pkgs.python3;
  # ravnix's skills, rendered with the values. The tree is one directory, so
  # journal finds ai-memory's scripts beside its own.
  rendered = skillLib.render {
    inherit pkgs python skillsDir;
    src = ../../claude/skills;
    values = config.ravnix.claude.skillValues;
  };
  # ravnix's own, and over them the user's: a name of the user's replaces
  # ravnix's skill, null leaves it out. Merged here rather than as defaults of
  # the option, so a definition of the user's at any priority, forwarded from
  # NixOS or plain in home-manager, adds to ravnix's skills instead of
  # replacing all of them.
  own = lib.genAttrs rendered.names (name: "${rendered}/${name}");
  installed = lib.filterAttrs (_: path: path != null) (own // config.ravnix.claude.skills);

  # A hook adapter of a skill: python3 on the script of the installed skill,
  # which ends 0 whatever happens, as Fedora's `|| true` did. A skill left
  # out leaves its hooks out, and a skill replaced by one without the
  # adapter makes the hook a no-op.
  adapter =
    name: skill: script: tools:
    pkgs.writeShellScript "ravnix-claude-${name}" ''
      export PATH=${lib.makeBinPath tools}''${PATH:+:$PATH}
      script=${lib.escapeShellArg "${skillsDir}/${skill}/adapters/claude/${script}"}
      [ -f "$script" ] || exit 0
      ${python} -B "$script" || true
    '';
  skillHooks = {
    handoff = {
      handoff-sessionstart = {
        event = "SessionStart";
        timeout = 30;
        script = "sessionstart.py";
        tools = [ git ];
      };
      handoff-stop = {
        event = "Stop";
        timeout = 30;
        script = "stop.py";
        tools = [
          git
          pkgs.libnotify
        ];
      };
      handoff-precompact = {
        event = "PreCompact";
        timeout = 30;
        script = "precompact.py";
        tools = [ git ];
      };
    };
    journal.journal-stop = {
      event = "Stop";
      timeout = 30;
      script = "stop.py";
      tools = [ git ];
    };
    ai-memory = {
      ai-memory-sessionstart = {
        event = "SessionStart";
        timeout = 5;
        script = "sessionstart.py";
        tools = [ ];
      };
      ai-memory-userpromptsubmit = {
        event = "UserPromptSubmit";
        timeout = 5;
        script = "userpromptsubmit.py";
        tools = [ ];
      };
      ai-memory-posttoolfailure = {
        event = "PostToolUseFailure";
        timeout = 5;
        script = "posttoolfailure.py";
        tools = [ ];
      };
    };
  };
  activeHooks = lib.concatMapAttrs (
    skill: hooks:
    lib.optionalAttrs (installed ? ${skill}) (lib.mapAttrs (_: h: h // { inherit skill; }) hooks)
  ) skillHooks;

  wrap =
    name: script: tools:
    pkgs.writeShellScript "ravnix-claude-${name}" ''
      export PATH=${lib.makeBinPath tools}''${PATH:+:$PATH}
      exec ${lib.getExe pkgs.bash} ${script} "$@"
    '';

  inherit (pkgs)
    coreutils
    curl
    findutils
    git
    jq
    util-linux
    ;
  hooks = {
    prune-claude-tmp = wrap "prune-claude-tmp" ../../claude/hooks/prune-claude-tmp.sh [
      coreutils
      findutils
      jq
    ];
    session-preflight = wrap "session-preflight" ../../claude/hooks/session-preflight.sh [
      coreutils
      findutils
      jq
    ];
    web-route = wrap "web-route" ../../claude/hooks/web-route.sh [
      coreutils
      curl
      jq
    ];
    worktree-create = wrap "worktree-create" ../../claude/hooks/worktree-create.sh [
      coreutils
      findutils
      git
      jq
    ];
    worktree-remove = wrap "worktree-remove" ../../claude/hooks/worktree-remove.sh [
      coreutils
      git
      jq
    ];
    worktree-subagent-stop =
      wrap "worktree-subagent-stop" ../../claude/hooks/worktree-subagent-stop.sh
        [
          coreutils
          findutils
          git
          jq
          util-linux
        ];
    # busy or idle per session, claude-roll's second signal beside herdr's
    # state (tools/claude-roll).
    busy-state = wrap "busy-state" ../../claude/hooks/busy-state.sh [
      coreutils
      jq
    ];
    # The session and launch flags of the herdr pane a session starts in,
    # which claude-roll passes again when it resumes the session.
    claude-pane = pkgs.writeShellScript "ravnix-claude-claude-pane" ''
      exec ${ravnix.claude-roll}/bin/claude-roll record
    '';
  };
  statusline = wrap "statusline" ../../claude/statusline/statusline.sh [ jq ];

  # One hook entry of the settings: a command and its timeout in seconds.
  run = name: timeout: {
    type = "command";
    command = lib.escapeShellArg "${dir}/hooks/${name}";
    inherit timeout;
  };
in
{
  # claude-code.nix declares ravnix.claude.hookEntries and puts them into the
  # settings file.
  imports = [
    ../options/claude.nix
    ./claude-code.nix
  ];

  config = lib.mkIf cfg.enable {
    xdg.configFile."ravnix/skill-values.json".source =
      (pkgs.formats.json { }).generate "skill-values.json"
        config.ravnix.claude.skillValues;

    home.sessionVariables.RAVNIX_SKILL_VALUES = valuesFile;

    home.file =
      lib.mapAttrs' (name: wrapper: lib.nameValuePair "${dir}/hooks/${name}" { source = wrapper; }) hooks
      // lib.mapAttrs' (
        name: h:
        lib.nameValuePair "${dir}/hooks/${name}" { source = adapter name h.skill h.script h.tools; }
      ) activeHooks
      // lib.mapAttrs' (name: path: lib.nameValuePair "${skillsDir}/${name}" { source = path; }) installed
      // {
        "${dir}/statusline".source = statusline;
      };

    ravnix.claude.hookEntries = lib.mkMerge [
      {
      SessionStart = [
        {
          hooks = [
            (run "prune-claude-tmp" 30)
            (run "session-preflight" 10)
            (run "busy-state" 5)
            (run "claude-pane" 5)
          ];
        }
      ];
      UserPromptSubmit = [ { hooks = [ (run "busy-state" 5) ]; } ];
      Stop = [ { hooks = [ (run "busy-state" 5) ]; } ];
      StopFailure = [ { hooks = [ (run "busy-state" 5) ]; } ];
      SessionEnd = [ { hooks = [ (run "busy-state" 5) ]; } ];
      PreToolUse = [
        {
          matcher = "WebSearch";
          hooks = [ (run "web-route" 5) ];
        }
      ];
      WorktreeCreate = [ { hooks = [ (run "worktree-create" 600) ]; } ];
      WorktreeRemove = [ { hooks = [ (run "worktree-remove" 60) ]; } ];
      SubagentStop = [ { hooks = [ (run "worktree-subagent-stop" 30) ]; } ];
      }
      # The adapters of the installed skills, a group each, after ravnix's own.
      (lib.zipAttrsWith (_: groups: groups) (
        lib.mapAttrsToList (name: h: {
          ${h.event} = {
            hooks = [ (run name h.timeout) ];
          };
        }) activeHooks
      ))
    ];

    programs.claude-code.settings = {
      env.RAVNIX_SKILL_VALUES = valuesFile;
      # Only for immutable settings, where the activation step does not run
      # (claude-code.nix).
      hooks = lib.mkIf (!cfg.mutableSettings) config.ravnix.claude.hookEntries;
      # One status line only: a user's own replaces this one whole.
      statusLine = lib.mkDefault {
        type = "command";
        command = lib.escapeShellArg "${dir}/statusline";
        padding = 0;
        refreshInterval = 60;
      };
    };
  };
}
