# Claude Code, as a home-manager module: the claude command on PATH, the
# auto-updater off, and the settings file writable.
#
# The package is ravnix's packages.claude-code: the claude-code input's
# build, with the download it was made from attached (lib/claude-code.nix).
# This file cannot name it, being a path; the flake's homeModules.claude-code
# imports it and sets the package. Import that one. An import of this file
# alone would install nixpkgs' claude-code, which carries no download to
# check, so an assertion refuses a package without one.
#
# What is verified, and where: the full gate of this repository runs
# claude-code-verify on the download of the version in ravnix's own
# flake.lock. A private flake that makes ravnix's claude-code input follow
# its own, as templates/default/flake.nix does, installs the version of its
# own lock, which that gate never sees; the private flake checks that one
# itself, on its own evaluation's packages.claude-code.download (Task 6.1's
# update timer).
#
# Why the auto-updater is off: Nix installs Claude Code, and a binary that
# replaced itself would be one the gate never checked. The package's wrapper
# sets DISABLE_AUTOUPDATER=1 already. The settings' env and the session
# variables set it too, so a claude started some other way gets it as well.
#
# Why the settings are mutable: Claude Code writes its own settings file,
# from /config, the model picker and the permission prompts, and a store
# link would make every such write fail. With mutableSettings,
# home-manager merges the declared settings into the file at activation:
# a declared key replaces the file's value, whole arrays included, and an
# undeclared one keeps it.
#
# Why ravnix's hooks do not go through that merge: declared there, a hook
# list would replace the file's whole list for its event at every switch,
# dropping the entries other tools write (herdr's SessionStart entry among
# them), and a hook ravnix stops declaring would stay behind. So
# ravnix.claude.hookEntries, which claude-skills.nix sets, goes in through an
# activation step of its own after that merge, claude/settings/sync-hooks.sh:
# it replaces only the hooks whose command starts with <configDir>/ravnix/,
# and keeps every other one. The step runs whenever the settings are
# mutable, with claude-skills or Claude Code turned off too, so that turning
# them off removes ravnix's entries at the next switch. With immutable
# settings the file is a store link that home-manager writes whole, and
# claude-skills.nix declares the hooks in it instead.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
  json = pkgs.formats.json { };
  settingsFile = "${cfg.configDir}/settings.json";
  sync = pkgs.writeShellScript "ravnix-claude-hooks-sync" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.jq
      ]
    }''${PATH:+:$PATH}
    exec ${lib.getExe pkgs.bash} ${../../claude/settings/sync-hooks.sh} "$@"
  '';
  entries = json.generate "ravnix-claude-hooks.json" config.ravnix.claude.hookEntries;

  # The step tells ravnix's hooks by this prefix, so it can only take out
  # again what starts with it: any other hook in hookEntries would be added
  # once more at every switch. The step refuses such entries too; this
  # names them at evaluation, before a switch.
  prefix = "${cfg.configDir}/ravnix/";
  ours =
    h:
    builtins.isAttrs h
    && (h.type or null) == "command"
    && builtins.isString (h.command or null)
    && lib.hasPrefix prefix (lib.removePrefix "'" h.command);
  # A group that is no object or holds no hook counts whole.
  foreign = lib.concatMap (
    g:
    if builtins.isAttrs g && builtins.isList (g.hooks or null) && g.hooks != [ ] then
      lib.filter (h: !ours h) g.hooks
    else
      [ g ]
  ) (lib.concatLists (lib.attrValues config.ravnix.claude.hookEntries));
in
{
  options.ravnix.claude.hookEntries = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf json.type);
    default = { };
    description = ''
      ravnix's own Claude Code hook entries, by event, which the activation
      step puts into the settings file. claude-skills.nix sets them; to drop
      one, set its event with lib.mkForce, as in
      `ravnix.claude.hookEntries.PreToolUse = lib.mkForce [ ];`.
    '';
  };

  config.home.activation.ravnixClaudeHooks = lib.mkIf cfg.mutableSettings (
    lib.hm.dag.entryAfter [ "linkGeneration" "claudeCodeSettings" ] ''
      if [[ -v DRY_RUN ]]; then
        echo ${lib.escapeShellArg "Would put ravnix's hook entries into ${settingsFile}"}
      else
        ${sync} ${lib.escapeShellArg settingsFile} ${lib.escapeShellArg prefix} ${entries} ${builtins.storeDir}
      fi
    ''
  );

  config.programs.claude-code = {
    enable = lib.mkDefault true;
    mutableSettings = lib.mkDefault true;
    # Upstream's place, and home-manager's default before state version
    # 26.11; set here so the default does not move under a user.
    configDir = lib.mkDefault "${config.home.homeDirectory}/.claude";
    settings.env.DISABLE_AUTOUPDATER = "1";
  };

  config.home.sessionVariables.DISABLE_AUTOUPDATER = "1";

  config.assertions = [
    {
      assertion = foreign == [ ];
      message = "ravnix.claude.hookEntries holds ${toString (lib.length foreign)} hook(s) that are not ravnix's own: ${builtins.toJSON foreign}. Every hook there must be a command hook whose command starts with ${prefix}, the only ones the activation step can take out again; declare any other in programs.claude-code.settings.hooks.";
    }
    {
      assertion = !cfg.enable || cfg.package == null || cfg.package ? download;
      message = "programs.claude-code.package is not ravnix's packages.claude-code, the build with its download attached, which claude-code-verify checks. Import homeModules.claude-code from the ravnix flake, which sets it, instead of modules/common/claude-code.nix alone.";
    }
  ];
}
