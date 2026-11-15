# energy: the laptop's energy settings in one fuzzel menu (power profile,
# refresh rate, keep-awake, idle suspend, charge mode, focus bar) and the
# watcher that applies them when the charger or the profile changes. Carried
# over from the Fedora laptop's bin-energy, ported from Bash to Odin in
# Phase 13; README.md has what changed. The hardware module installs it and
# its user unit energy-watch.service
# (modules/hardware/ideapad-pro-5-16ahp9/power.nix).
#
# fuzzel, swaymsg, keep-awake and waybar-launch belong to the session and
# come from its PATH, which stays behind the directories listed here: fuzzel
# so that the menu wears the session's theme, swaymsg to talk to the running
# Sway, the other two from the desktop's scripts. charge-mode is the
# package's own, by its store path.
{
  buildOdinTool,
  pkgs,
  lib,
  ...
}:
let
  # charge-mode is a package, and a tool must not read pkgs.ravnix
  # (packages/README.md), so it is built from its file with the same pkgs,
  # which is the derivation pkgs.ravnix.charge-mode is.
  chargeMode = pkgs.callPackage ../../packages/charge-mode { };
in
buildOdinTool {
  name = "energy";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  odinFlags = [
    "-define:CHARGE_MODE=${lib.getExe chargeMode}"
    # busctl and systemctl (systemd), gdbus (glib), notify-send (libnotify),
    # pgrep (procps) and setsid (util-linux): the programs it starts.
    "-define:TOOLS_PATH=${
      lib.makeBinPath [
        pkgs.systemd
        pkgs.glib
        pkgs.libnotify
        pkgs.procps
        pkgs.util-linux
      ]
    }"
  ];
  # The bench reads a setting. It cannot run a program: the bench has no PATH
  # (tools/README.md, Known gaps).
  benchArgs = [
    "get"
    "refresh"
  ];
  meta = {
    description = "The laptop's energy settings in one menu, and their watcher";
    license = lib.licenses.agpl3Plus;
    mainProgram = "energy";
  };
}
