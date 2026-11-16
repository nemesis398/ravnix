# ravnix-nas-credential: the root helper behind the NAS mounts of
# modules/desktop/nas.nix. It reads an SMB account's password from the
# login's vault, with rbw run as the login, and writes the root-only
# credentials file that mount.cifs reads; the script's header says how, and
# README.md what it does not cover. rbw is nixpkgs' here; the module passes
# the login's own (programs.rbw.package of home-manager) with override.
{
  lib,
  writeShellApplication,
  coreutils,
  util-linux,
  rbw,
}:
writeShellApplication {
  name = "ravnix-nas-credential";
  # The script sets its own options (set -uo pipefail): errexit would end it
  # at the first rbw that fails, which is a case it handles.
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    util-linux
    rbw
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./ravnix-nas-credential.sh);
  meta = {
    description = "Writes a NAS share's root-only SMB credentials file from the login's vault";
    license = lib.licenses.agpl3Plus;
    mainProgram = "ravnix-nas-credential";
  };
}
