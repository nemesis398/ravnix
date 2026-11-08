# with-secret-env: runs a command with the secrets of ravnix.shell.secretEnv
# in its environment and in nobody else's. It is the one loader of the
# launchers (claude-artifacts, claude-bg), written for ravnix; README.md has
# what it keeps out of reach. rbw is the user's profile's and is looked up on
# the PATH, so a missing one is a message and not an error. Not installed for
# the user: the launchers that use it carry it.
{
  lib,
  writeShellApplication,
}:
writeShellApplication {
  name = "with-secret-env";
  # The script sets its own options (set -uo pipefail) and turns tracing off;
  # errexit would end it at the first rbw that fails, which is a case it handles.
  bashOptions = [ ];
  runtimeInputs = [ ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./with-secret-env.sh);
  meta = {
    description = "Runs a command with the secrets of ravnix.shell.secretEnv in its environment";
    license = lib.licenses.agpl3Plus;
    mainProgram = "with-secret-env";
  };
}
