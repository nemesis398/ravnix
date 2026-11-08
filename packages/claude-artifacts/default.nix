# claude-artifacts: starts Claude Code with the Artifact tool switched on.
# Carried over from Fedora's bin-claude-artifacts and still Bash (AGENTS.md,
# rule 4); README.md has what changed. claude is the user's profile's and is
# looked up on the PATH. The launcher loads the secrets of
# ravnix.shell.secretEnv through with-secret-env, because on Fedora every shell
# held them and here only the `claude` function of the interactive shell adds
# them, which a command is not.
{
  lib,
  writeShellApplication,
  coreutils,
  ravnix,
}:
writeShellApplication {
  name = "claude-artifacts";
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    ravnix.with-secret-env
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./claude-artifacts.sh);
  meta = {
    description = "Starts Claude Code with the Artifact tool switched on";
    license = lib.licenses.agpl3Plus;
    mainProgram = "claude-artifacts";
  };
}
