# battery-emergency-poweroff: the second layer of the battery safety net, a
# root helper that powers off when the battery discharges at 3 % or less
# (the script's header has why). Carried over from the Fedora laptop's
# battery-critical-safety-net and still Bash (AGENTS.md, rule 4); README.md
# has what changed. The hardware module's battery-emergency-poweroff.timer
# runs it (modules/hardware/ideapad-pro-5-16ahp9/battery.nix).
{
  lib,
  writeShellApplication,
  coreutils,
  systemd,
  util-linux,
}:
writeShellApplication {
  name = "battery-emergency-poweroff";
  # The script sets no options, as on Fedora: a failing warning must never
  # stop the poweroff.
  bashOptions = [ ];
  # It runs as root, so it finds its tools in the store and nowhere else.
  inheritPath = false;
  runtimeInputs = [
    coreutils
    systemd
    util-linux
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./battery-emergency-poweroff.sh);
  meta = {
    description = "Power off when the laptop battery discharges at 3 % or less";
    license = lib.licenses.agpl3Plus;
    mainProgram = "battery-emergency-poweroff";
    platforms = lib.platforms.linux;
  };
}
