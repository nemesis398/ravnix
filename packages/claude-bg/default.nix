# claude-bg: starts a background Claude Code session that has its MCP tokens,
# carried over from Fedora's bin-claude-bg and still Bash (AGENTS.md, rule 4);
# README.md has what changed. claude and rbw belong to the user's profile and
# are looked up on the PATH (the first claude on it, which is the profile's
# unless something precedes it), and a missing rbw is a message, not an error.
# The tokens are loaded by with-secret-env, the helper claude-artifacts uses too.
{
  lib,
  writeShellApplication,
  coreutils,
  ravnix,
}:
writeShellApplication {
  name = "claude-bg";
  # The script sets its own options (set -uo pipefail); errexit would change
  # what it does.
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    ravnix.with-secret-env
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./claude-bg.sh);
  meta = {
    description = "Starts a background Claude Code session with its MCP tokens";
    license = lib.licenses.agpl3Plus;
    mainProgram = "claude-bg";
  };
}
