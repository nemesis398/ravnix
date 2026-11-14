# deploy/compose/restic/docker-compose.yaml, without a container (common-
# backup runs rest-server with its flags and shows what they do):
#
# - one service, rest-server, started as the binary with --append-only,
#   --private-repos and the htpasswd file, and with no flag that turns the
#   login off (--no-auth) or lets a client delete;
# - the image is the version of nixpkgs' restic-rest-server, which the checks
#   run, by an exact tag;
# - the port is published on RESTIC_BIND_ADDRESS alone, not on every address
#   of the NAS;
# - it runs as RESTIC_UID with a read-only root, no capabilities and no new
#   privileges;
# - the file holds no address and no value of anyone's: every value comes
#   from .env, each variable it reads is described in its header, and each
#   required one stops `docker compose` with a message when it is missing.
{ pkgs, lib, ... }:
let
  compose = ../../deploy/compose/restic/docker-compose.yaml;
  version = pkgs.restic-rest-server.version;
  ports = "\${RESTIC_BIND_ADDRESS:?set RESTIC_BIND_ADDRESS in .env}:\${RESTIC_PORT:-8000}:8000";
  user = "\${RESTIC_UID:?set RESTIC_UID in .env}:\${RESTIC_GID:?set RESTIC_GID in .env}";
  volumes = "\${RESTIC_DATA_DIR:?set RESTIC_DATA_DIR in .env}:/data,./htpasswd:/etc/rest-server/htpasswd:ro";
in
pkgs.runCommand "deploy-restic-compose" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
  failed=0
  fail() { echo "FAIL: $*" >&2; failed=1; }
  is() { # EXPRESSION VALUE
    got=$(yq "$1" ${compose})
    [ "$got" = "$2" ] || fail "$1 is '$got', not '$2'"
  }
  s=.services.rest-server

  is '.services | keys | join(",")' rest-server
  is "$s.image" docker.io/restic/rest-server:${version}
  is "$s.entrypoint | join(\",\")" rest-server
  is "$s.command | join(\" \")" "--path=/data --listen=:8000 --append-only --private-repos --htpasswd-file=/etc/rest-server/htpasswd"
  is "$s.ports | length" 1
  is "$s.ports[0]" ${lib.escapeShellArg ports}
  is "$s.user" ${lib.escapeShellArg user}
  is "$s.volumes | join(\",\")" ${lib.escapeShellArg volumes}
  is "$s.read_only" true
  is "$s.cap_drop | join(\",\")" ALL
  is "$s.security_opt | join(\",\")" no-new-privileges:true
  for key in privileged network_mode cap_add devices pid environment env_file; do
    is "$s.$key // \"none\"" none
  done

  # No address and no value of anyone's in the file itself.
  if grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' ${compose}; then fail "the file holds an IPv4 address"; fi
  # Every variable the file reads is described in its header, and the
  # required ones stop compose with a message.
  for var in $(grep -oE '\$\{[A-Z_]+' ${compose} | cut -c3- | sort -u); do
    grep -qE "^#   $var( |$)" ${compose} || fail "$var is not described in the header"
    grep -qF "\''${$var:?set $var in .env}" ${compose} || grep -qF "\''${$var:-" ${compose} ||
      fail "$var has neither a message for when it is missing nor a default"
  done

  [ "$failed" = 0 ] || exit 1
  touch $out
''
