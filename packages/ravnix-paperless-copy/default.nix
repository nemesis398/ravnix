# ravnix-paperless-copy: the nightly one-way copy of each owner's filed
# Paperless documents into that person's read-only Archiv folder. The script's
# header says how, README.md what it does not cover, and the image around it is
# packages/ravnix-paperless-copy-image. The notice it writes into every folder
# is LIESMICH.txt of this directory.
{
  lib,
  writeShellApplication,
  coreutils,
  findutils,
  gnugrep,
  rsync,
  curl,
}:
writeShellApplication {
  name = "ravnix-paperless-copy";
  # The script sets its own options (set -uo pipefail): errexit would end a
  # run at the first owner that fails, which is a case it handles.
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
    rsync
    curl
  ];
  text = builtins.replaceStrings [ "@notice@" ] [ "${./LIESMICH.txt}" ] (
    lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./ravnix-paperless-copy.sh)
  );
  meta = {
    description = "Copies each owner's filed Paperless documents into a read-only Archiv folder, nightly";
    license = lib.licenses.agpl3Plus;
    mainProgram = "ravnix-paperless-copy";
  };
}
