# try-huginn: boots the installed laptop in a QEMU window, from its real disk,
# after the disk guard has said the disk is free (Task 3.5, step 5). The script
# is scripts/try-huginn.sh, where its tests are too (scripts/tests/
# try-huginn.test.sh, run by the check scripts-tests); this package only gives
# it its tools and its firmware as store paths, so nothing depends on what the
# host that runs it has installed. README.md has how to run it.
{
  lib,
  writeShellApplication,
  coreutils,
  util-linux,
  qemu_kvm,
  OVMF,
  ravnix,
}:
writeShellApplication {
  name = "try-huginn";
  # The script sets its own options and checks its tools itself.
  bashOptions = [ ];
  # Root runs it, so it finds its tools in the store and never on the PATH
  # that sudo or the user hands it.
  inheritPath = false;
  runtimeInputs = [
    coreutils
    util-linux
    qemu_kvm
    ravnix.ravnix-disk-guard
  ];
  text =
    builtins.replaceStrings
      [ "@ovmfCode@" "@ovmfVars@" ]
      [ "${OVMF.fd}/FV/OVMF_CODE.fd" "${OVMF.fd}/FV/OVMF_VARS.fd" ]
      (lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ../../scripts/try-huginn.sh));
  meta = {
    description = "Boots the installed laptop from its raw disk in QEMU, after the disk guard allows it";
    license = lib.licenses.agpl3Plus;
    mainProgram = "try-huginn";
    platforms = [ "x86_64-linux" ];
  };
}
