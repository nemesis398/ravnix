# The scripts that need the desktop, as the laptop shape installs them: the
# display rescue (fix-display, panel-crtc), the Bluetooth codec switch for
# games, btop with both GPUs, the Magic Trackpad's battery and the laptop's
# machine facts. They come from packages/NAME (README.md in each), which this
# module reads as pkgs.ravnix.NAME. The scripts both hosts need are installed
# by modules/common/scripts.nix.
#
# magic-trackpad-battery opens the pad's hidraw node. The udev rule that lets
# the user on the active seat read it (the uaccess tag) is not here: the
# peripherals module (modules/desktop/peripherals.nix) owns it, with the hidraw
# lines of Fedora's 60-magic-trackpad.rules and the evdev ones. Without that
# rule the script exits quietly.
#
# The tools of the session that the scripts call (swaymsg, kanshictl, sway,
# btop, sudo, loginctl, journalctl, nmcli, resolvectl) are looked up on the
# PATH, not built into the packages; the packages say which in their README.
{ config, lib, ... }:
let
  cfg = config.ravnix.scripts;

  scripts = [
    "bt-game-codec"
    "btop-gpu"
    "fix-display"
    "machine-facts"
    "magic-trackpad-battery"
  ];
in
{
  home-manager.sharedModules = [
    (
      { pkgs, ... }:
      {
        home.packages = map (name: pkgs.ravnix.${name}) scripts;
        home.sessionVariables = lib.optionalAttrs (cfg.machineFacts.note != null) {
          MACHINE_NOTE = cfg.machineFacts.note;
        };
      }
    )
  ];
}
