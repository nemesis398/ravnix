# charge-mode: the battery's charge ceiling (BAT0/charge_types: Fast,
# Standard or Long_Life), read and set from the desktop without a password
# (README.md). One Odin package, built as three programs, each with the code
# of its own role only (CHARGE_MODE_ROLE):
#
#   charge-mode          the user's command (Waybar's battery click, the
#                        energy menu); writes go through the helper, with
#                        sudo -n
#   charge-mode-apply    the one root writer, which validates the mode
#                        against the kernel's list; the hardware module's
#                        sudo rule names it by its store path
#   charge-mode-restore  the saved mode at boot (charge-mode-restore.service)
#
# The other two run the helper by its store path, the one the sudo rule
# names (passthru.apply), which the build puts into their binaries; so do
# notify-send's. sudo is the caller's, the setuid wrapper on PATH. The tests
# and the bench are the user's command's: the bench runs it as on a machine
# without charge_types, since its fixed environment cannot point it at a
# fake one (README.md).
{
  buildOdinTool,
  pkgs,
  lib,
  ...
}:
let
  role =
    name: role: flags:
    buildOdinTool {
      inherit name;
      src = ./.;
      tests = ./tests;
      bench = ./bench;
      benchArgs = [ "show" ];
      odinFlags = [ "-define:CHARGE_MODE_ROLE=${role}" ] ++ flags;
      meta.description = "Read and set the IdeaPad battery's charge mode without a password";
    };
  helperFlag = "-define:CHARGE_MODE_HELPER=${apply.package}/bin/charge-mode-apply";

  apply = role "charge-mode-apply" "apply" [ ];
  restore = role "charge-mode-restore" "restore" [ helperFlag ];
  user = role "charge-mode" "user" [
    helperFlag
    "-define:CHARGE_MODE_NOTIFY_SEND=${lib.getExe' pkgs.libnotify "notify-send"}"
  ];
in
user
// {
  package = pkgs.symlinkJoin {
    name = "charge-mode";
    paths = [
      user.package
      apply.package
      restore.package
    ];
    passthru = {
      apply = apply.package;
      restore = restore.package;
    };
    meta = user.package.meta // {
      mainProgram = "charge-mode";
      license = lib.licenses.agpl3Plus;
    };
  };
}
