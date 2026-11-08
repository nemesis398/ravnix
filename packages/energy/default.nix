# energy: the laptop's energy settings in one fuzzel menu (power profile,
# refresh rate, keep-awake, idle suspend, charge mode, focus bar) and the
# watcher that applies them when the charger or the profile changes. Carried
# over from the Fedora laptop's bin-energy and still Bash (AGENTS.md, rule
# 4); README.md has what changed. The hardware module installs it and its
# user unit energy-watch.service
# (modules/hardware/ideapad-pro-5-16ahp9/power.nix).
#
# fuzzel, swaymsg, keep-awake and waybar-launch belong to the session and
# come from its PATH, which stays behind the tools listed here: fuzzel so
# that the menu wears the session's theme, swaymsg to talk to the running
# Sway, the other two from the desktop's scripts. charge-mode is the
# package's own, by its store path.
{
  lib,
  writeShellApplication,
  coreutils,
  gawk,
  glib,
  jq,
  libnotify,
  procps,
  ravnix,
  systemd,
  util-linux,
}:
writeShellApplication {
  name = "energy";
  # The script sets its own options (set -uo pipefail), as on Fedora: a
  # setting that fails must not stop the watcher.
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    gawk
    # gdbus, the watcher's bus monitor.
    glib
    jq
    libnotify
    procps
    # busctl and systemctl.
    systemd
    # setsid.
    util-linux
  ];
  text = builtins.replaceStrings [ "@chargeMode@" ] [ (lib.getExe ravnix.charge-mode) ] (
    lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./energy.sh)
  );
  meta = {
    description = "The laptop's energy settings in one menu, and their watcher";
    license = lib.licenses.agpl3Plus;
    mainProgram = "energy";
    platforms = lib.platforms.linux;
  };
}
