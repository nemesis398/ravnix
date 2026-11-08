# btop-gpu and btop-auto: btop with both GPUs shown, and the launcher that
# chooses between that and plain btop by the dGPU's power state. Carried over
# from Fedora's bin-btop-gpu and still POSIX sh (AGENTS.md, rule 4); README.md
# has what changed. btop is the user's profile's (programs.btop) and is looked
# up on the PATH, so it is the btop with the user's configuration and build.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  coreutils,
  gnugrep,
  gnused,
}:
let
  btop-gpu = writeShellApplication {
    name = "btop-gpu";
    # The script sets its own options (set -eu).
    bashOptions = [ ];
    runtimeInputs = [
      coreutils
      gnugrep
      gnused
    ];
    text = lib.removePrefix "#!/bin/sh\n" (builtins.readFile ./btop-gpu.sh);
    meta.mainProgram = "btop-gpu";
  };
  btop-auto = writeShellApplication {
    name = "btop-auto";
    bashOptions = [ ];
    # btop-gpu is this package's own, so the launcher finds it without
    # relying on the profile.
    runtimeInputs = [
      btop-gpu
      coreutils
    ];
    text = lib.removePrefix "#!/bin/sh\n" (builtins.readFile ./btop-auto.sh);
    meta.mainProgram = "btop-auto";
  };
in
symlinkJoin {
  name = "btop-gpu";
  paths = [
    btop-gpu
    btop-auto
  ];
  meta = {
    description = "btop with both GPUs shown, and the launcher that picks it";
    license = lib.licenses.agpl3Plus;
    mainProgram = "btop-gpu";
  };
}
