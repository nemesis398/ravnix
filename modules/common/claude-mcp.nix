# The MCP servers of ravnix.claude.mcpServers, put into Claude Code's
# user-scope config by an activation step. claude-code.nix imports this
# file; the flake's homeModules.claude-code is the way in.
#
# Why not programs.claude-code.mcpServers: home-manager renders those into a
# plugin of its own, which Claude Code reports in the scope "plugin" as
# plugin:hm:NAME, and whose tools are called mcp__plugin_hm_NAME__TOOL
# instead of mcp__NAME__TOOL. Every permission rule and skill that names a
# server's tools would stop matching, `claude mcp remove` could not take a
# server out, and the servers would not be in the user scope. A server in
# ~/.claude.json, which is where `claude mcp add --scope user` puts one, has
# none of these problems. Task 2.5 recorded the choice; the check
# claude-mcp builds both and reads the scope from the real claude.
#
# Why the merge keeps what Claude Code wrote: ~/.claude.json is Claude
# Code's own file, with its history, its account and every project's
# settings in it, and Claude Code writes it all the time. The step
# (claude/settings/sync-mcp.sh) changes the mcpServers key only: it puts
# ravnix's servers in, takes out the ones it put in before and no longer
# declares, and keeps every other server and key. It writes with
# compare-and-swap, as the hook step does for settings.json
# (claude-code.nix).
#
# Which servers are ravnix's: the step records their names in
# <stateHome>/ravnix/claude-mcp-servers.json. Claude Code may drop a marker
# inside a server's entry, so the record sits beside the file and not in it.
#
# Where the file is: ~/.claude.json, and <configDir>/.claude.json when the
# config directory is not ~/.claude, where home-manager sets
# CLAUDE_CONFIG_DIR and Claude Code moves the file along.
#
# The step runs when Claude Code is turned off too, with no servers, so that
# turning it off takes ravnix's servers out at the next switch.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
  json = pkgs.formats.json { };
  home = config.home.homeDirectory;
  claudeJson = if cfg.configDir == "${home}/.claude" then "${home}/.claude.json" else "${cfg.configDir}/.claude.json";
  stateFile = "${config.xdg.stateHome}/ravnix/claude-mcp-servers.json";
  servers = json.generate "ravnix-claude-mcp-servers.json" (
    lib.optionalAttrs cfg.enable config.ravnix.claude.mcpServers
  );
  sync = pkgs.writeShellScript "ravnix-claude-mcp-sync" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.jq
      ]
    }''${PATH:+:$PATH}
    exec ${lib.getExe pkgs.bash} ${../../claude/settings/sync-mcp.sh} "$@"
  '';
in
{
  imports = [ ../options/claude.nix ];

  config.home.activation.ravnixClaudeMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [[ -v DRY_RUN ]]; then
      echo ${lib.escapeShellArg "Would put ravnix's MCP servers into ${claudeJson}"}
    else
      ${sync} ${lib.escapeShellArg claudeJson} ${lib.escapeShellArg stateFile} ${servers} ${builtins.storeDir}
    fi
  '';
}
