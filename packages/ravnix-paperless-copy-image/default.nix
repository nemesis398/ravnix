# The OCI image of ravnix-paperless-copy (packages/ravnix-paperless-copy), for
# the archive-copy service of the Paperless compose on the NAS. It holds the
# script (rsync, coreutils, findutils, grep and curl come with it), the time
# zone database and the CA bundle, and nothing else: no package manager, nothing
# beyond the script's closure. It sets no user, because the service runs as the
# UID and GID the compose gives it (the NAS account that owns the Archiv
# folders), which need not exist in the image; /tmp is open to every UID for the staging tree
# of a run. TZ defaults to Europe/Berlin, which the daily time is read on.
#
# Build and load (the tag is the one PAPERLESS_ARCHIVE_COPY_IMAGE names):
#   nix build .#ravnix-paperless-copy-image
#   docker load < result
{
  lib,
  dockerTools,
  tzdata,
  cacert,
  ravnix,
}:
dockerTools.buildLayeredImage {
  name = "ravnix-paperless-copy";
  tag = "1";
  contents = [
    ravnix.ravnix-paperless-copy
    tzdata
    cacert
  ];
  extraCommands = ''
    mkdir -p tmp
    chmod 1777 tmp
  '';
  config = {
    Entrypoint = [ (lib.getExe ravnix.ravnix-paperless-copy) ];
    Env = [
      "PATH=/bin"
      "TZ=Europe/Berlin"
      "TZDIR=${tzdata}/share/zoneinfo"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "TMPDIR=/tmp"
      "HOME=/tmp"
    ];
    Labels = {
      "org.opencontainers.image.title" = "ravnix-paperless-copy";
      "org.opencontainers.image.description" = "Copies each owner's filed Paperless documents into a read-only Archiv folder, nightly";
      "org.opencontainers.image.licenses" = "AGPL-3.0-or-later";
    };
  };
}
