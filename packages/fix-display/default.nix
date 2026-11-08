# fix-display and panel-crtc: bring the Sway session back when the panel stays
# dark after a resume, and keep the panel on the CRTC the kernel console uses.
# Carried over from Fedora's bin-fix-display: fix-display is Bash and
# panel-crtc is Python (AGENTS.md, rule 4); README.md has what changed. sway's
# own tools (swaymsg, kanshi, kanshictl), systemd's (loginctl, journalctl) and
# sudo are the session's and are looked up on the PATH; sudo has to be the
# setuid wrapper.
{
  lib,
  writeShellApplication,
  writers,
  symlinkJoin,
  coreutils,
  gawk,
  gnused,
  jq,
  kbd,
  procps,
}:
let
  panel-crtc =
    writers.writePython3Bin "panel-crtc"
      {
        # The original fails flake8 on these and is left as it was:
        #   E501  lines past 79 characters (24 of them)
        flakeIgnore = [ "E501" ];
      }
      (builtins.readFile ./panel-crtc.py);
  fix-display = writeShellApplication {
    name = "fix-display";
    # The script sets its own options (set -uo pipefail); errexit would end
    # a rescue at its first failing step.
    bashOptions = [ ];
    runtimeInputs = [
      panel-crtc
      coreutils
      gawk
      gnused
      jq
      kbd
      procps
    ];
    # SC2024 (sudo does not affect redirects) is off for the whole script, as
    # the script's own directive has it: the reads as root redirect into files
    # of the user's, which is what is wanted. The directive in the file cannot
    # do it here, because writeShellApplication puts its own lines before it.
    excludeShellChecks = [ "SC2024" ];
    text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./fix-display.sh);
    meta.mainProgram = "fix-display";
  };
in
symlinkJoin {
  name = "fix-display";
  paths = [
    fix-display
    panel-crtc
  ];
  meta = {
    description = "Brings the Sway session back when the panel stays dark";
    license = lib.licenses.agpl3Plus;
    mainProgram = "fix-display";
  };
}
