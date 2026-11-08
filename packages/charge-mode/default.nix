# charge-mode: the battery's charge ceiling (BAT0/charge_types: Fast,
# Standard or Long_Life), read and set from the desktop without a password.
# Carried over from the Fedora laptop's bin-charge-mode and
# scripts/laptop-charge-mode, and still Bash (AGENTS.md, rule 4); README.md
# has what changed. Three commands in one package:
#
#   charge-mode          the user's command (Waybar's battery click, the
#                        energy menu); writes go through the helper, with
#                        sudo -n
#   charge-mode-apply    the one root writer, which validates the mode
#                        against the kernel's list; the hardware module's
#                        sudo rule names it by its store path
#   charge-mode-restore  the saved mode at boot (charge-mode-restore.service)
#
# The other two call the helper by its store path, the one the sudo rule
# names (passthru.apply).
{
  lib,
  writeShellApplication,
  symlinkJoin,
  coreutils,
  gnused,
  libnotify,
  procps,
}:
let
  script = name: lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./${name}.sh);
  withApply =
    name: builtins.replaceStrings [ "@apply@" ] [ "${apply}/bin/charge-mode-apply" ] (script name);

  apply = writeShellApplication {
    name = "charge-mode-apply";
    # The scripts set their own options, as on Fedora.
    bashOptions = [ ];
    # It runs as root through sudo, so it finds its tools in the store and
    # never on the caller's PATH.
    inheritPath = false;
    runtimeInputs = [ coreutils ];
    text = script "charge-mode-apply";
  };

  restore = writeShellApplication {
    name = "charge-mode-restore";
    bashOptions = [ ];
    # It runs as root at boot.
    inheritPath = false;
    runtimeInputs = [ coreutils ];
    text = withApply "charge-mode-restore";
  };

  charge-mode = writeShellApplication {
    name = "charge-mode";
    bashOptions = [ ];
    # The caller's PATH stays behind these: sudo is the setuid wrapper there
    # (/run/wrappers/bin on NixOS), never a copy from the store.
    runtimeInputs = [
      coreutils
      gnused
      libnotify
      procps
    ];
    text = withApply "charge-mode";
  };
in
symlinkJoin {
  name = "charge-mode";
  paths = [
    charge-mode
    apply
    restore
  ];
  passthru = { inherit apply restore; };
  meta = {
    description = "Read and set the IdeaPad battery's charge mode without a password";
    license = lib.licenses.agpl3Plus;
    mainProgram = "charge-mode";
    platforms = lib.platforms.linux;
  };
}
