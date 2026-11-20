# ravnix-paperless-setup: puts a Paperless-ngx instance into the shape of the
# household design over its REST API: the group of the family, the household
# user, and one ownership workflow per inbox folder. Bash glue over curl and
# jq; the script's header says what it makes, README.md what it does not
# cover, and tests/services/paperless.nix runs it against a real Paperless
# in a VM.
{
  lib,
  writeShellApplication,
  coreutils,
  curl,
  jq,
}:
writeShellApplication {
  name = "ravnix-paperless-setup";
  runtimeInputs = [
    coreutils
    curl
    jq
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./ravnix-paperless-setup.sh);
  meta = {
    description = "Sets up the family group, the household user and the ownership workflows of a Paperless-ngx";
    license = lib.licenses.agpl3Plus;
    mainProgram = "ravnix-paperless-setup";
  };
}
