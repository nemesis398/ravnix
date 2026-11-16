# atuin-root-login: logs root in to the user's atuin account, from the
# Bitwarden item of the account, so root's history joins the shared timeline.
# hosts/laptop/atuin-root.nix puts it on the laptop's PATH; README.md
# has what it keeps out of reach. rbw is the user's profile's and is looked up
# on the PATH; atuin is the one that root's shell runs.
{
  lib,
  writeShellApplication,
  atuin,
  # The atuin service's URL (ravnix.services.atuin.url), or null where none is
  # placed: then the helper refuses, since atuin would log in to its public
  # server and the password would go there.
  syncAddress ? null,
}:
writeShellApplication {
  name = "atuin-root-login";
  # The script sets its own options (set -uo pipefail) and turns tracing off;
  # errexit would end it at the first command that fails, which it handles.
  bashOptions = [ ];
  runtimeInputs = [ atuin ];
  text = lib.replaceStrings [ "@self@" "@syncAddress@" ] [ "${placeholder "out"}/bin/atuin-root-login" (lib.escapeShellArg (toString syncAddress)) ] (
    lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./atuin-root-login.bash)
  );
  meta = {
    description = "Log root in to the user's atuin account from a Bitwarden item";
    license = lib.licenses.agpl3Plus;
    mainProgram = "atuin-root-login";
  };
}
