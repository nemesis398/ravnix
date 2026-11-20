# deploy/compose/paperless/docker-compose.yaml and its .env.example,
# without a container:
#
# - the project `paperless` (Kuma's container push names its containers)
#   with five services, webserver, db, broker, exporter and archive-copy,
#   and no Tika or Gotenberg;
# - exact image tags: the webserver's and the exporter's are nixpkgs'
#   paperless-ngx (the version the VM test of Task 9.5.2 runs), Postgres 18
#   and Redis 8 by their full version, archive-copy's from .env;
# - only the webserver publishes a port, on PAPERLESS_BIND_ADDRESS alone;
#   db and broker sit on an internal network;
# - the settings of the design: OCR deu+eng with no extra languages (they
#   would install packages at every start), the filename format, the
#   recursive consumer without folder tags, the time zone, and the URLs
#   from .env;
# - OIDC through Authelia: the provider JSON names `authelia`, client
#   `paperless`, the server and the secret from .env, PKCE (for the
#   provider and the app) with client_secret_basic, and `groups` in the
#   scope; OIDC sign-up on, `family` for new accounts and no group sync
#   (it replaces the groups at every login), local sign-up off, the
#   password login kept, and no group that makes an account staff or
#   superuser;
# - the exporter runs document_exporter without --delete and without
#   --passphrase, daily at 02:30 Europe/Berlin, once the webserver is healthy
#   (migrated), and pushes to Kuma only after a good run, with the push URL
#   never on a command line (its loop is run here, against stubs);
# - archive-copy runs ravnix-paperless-copy in loop mode and reads the media
#   read-only, from an image that compose never pulls (`docker load` puts it
#   there, and no registry has it, so `pull` would fail on it);
# - every service runs as PAPERLESS_UID with no capabilities and no new
#   privileges, reads no env_file (the .env names collide with Paperless's
#   own variables), and has no host network, devices or extra privileges;
# - no address and no value of anyone's: every variable is described in the
#   header and in .env.example, which holds no secret, and every required
#   one stops `docker compose` with a message (docker-compose config proves
#   it, with each one left out in turn).
{ pkgs, lib, ... }:
let
  dir = ../../deploy/compose/paperless;
  compose = dir + "/docker-compose.yaml";
  envExample = dir + "/.env.example";
  version = pkgs.paperless-ngx.version;

  req = var: "\${${var}:?set ${var} in .env}";
  user = "${req "PAPERLESS_UID"}:${req "PAPERLESS_GID"}";
  data = req "PAPERLESS_DATA_DIR";
  ports = "${req "PAPERLESS_BIND_ADDRESS"}:\${PAPERLESS_PORT:-8010}:8000";
  webserverVolumes = lib.concatStringsSep "," [
    "${data}/data:/usr/src/paperless/data"
    "${data}/media:/usr/src/paperless/media"
    "${data}/export:/usr/src/paperless/export"
    "${data}/consume:/usr/src/paperless/consume"
  ];
  exporterVolumes = lib.concatStringsSep "," [
    "${data}/data:/usr/src/paperless/data"
    "${data}/media:/usr/src/paperless/media"
    "${data}/export:/usr/src/paperless/export"
  ];

  # The settings of the design, each to be exactly this in the webserver.
  webserverEnv = {
    PAPERLESS_DBENGINE = "postgresql";
    PAPERLESS_DBHOST = "db";
    PAPERLESS_DBNAME = "paperless";
    PAPERLESS_DBUSER = "paperless";
    PAPERLESS_DBPASS = req "PAPERLESS_DB_PASSWORD";
    PAPERLESS_REDIS = "redis://broker:6379";
    PAPERLESS_SECRET_KEY = req "PAPERLESS_SECRET_KEY";
    PAPERLESS_TIME_ZONE = "Europe/Berlin";
    PAPERLESS_URL = req "PAPERLESS_URL";
    PAPERLESS_OCR_LANGUAGE = "deu+eng";
    PAPERLESS_FILENAME_FORMAT = "{{ owner_username }}/{{ created_year }}/{{ correspondent }}/{{ created }} {{ title }}";
    PAPERLESS_CONSUMER_RECURSIVE = "true";
    PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = "false";
    PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
    PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
    PAPERLESS_ACCOUNT_ALLOW_SIGNUPS = "false";
    PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS = "family";
  };
  # What the exporter needs to reach the database, and nothing of OIDC.
  exporterEnv = {
    inherit (webserverEnv)
      PAPERLESS_DBENGINE PAPERLESS_DBHOST PAPERLESS_DBNAME PAPERLESS_DBUSER
      PAPERLESS_DBPASS PAPERLESS_REDIS PAPERLESS_SECRET_KEY PAPERLESS_TIME_ZONE;
    TZ = "Europe/Berlin";
    KUMA_PUSH_URL = "\${KUMA_PUSH_URL_PAPERLESS_EXPORT:-}";
  };
  envChecks = svc: env: lib.concatStrings (lib.mapAttrsToList (k: v: ''
    is ${lib.escapeShellArg "${svc}.environment.${k}"} ${lib.escapeShellArg v}
  '') env);

  # Values for docker-compose config; none of them is anyone's.
  testEnv = {
    PAPERLESS_BIND_ADDRESS = "192.0.2.10";
    PAPERLESS_DATA_DIR = "/srv/paperless";
    PAPERLESS_UID = "2001";
    PAPERLESS_GID = "2002";
    PAPERLESS_URL = "https://paperless.example.org";
    PAPERLESS_OIDC_SERVER_URL = "https://auth.example.org";
    PAPERLESS_SECRET_KEY = "test-secret-key";
    PAPERLESS_DB_PASSWORD = "test-db-password";
    PAPERLESS_OIDC_CLIENT_SECRET = "test-client-secret";
    PAPERLESS_ARCHIVE_COPY_IMAGE = "ravnix-paperless-copy:test";
  };
  envFile = lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${v}\n") testEnv);
in
pkgs.runCommand "deploy-paperless-compose"
  { nativeBuildInputs = [ pkgs.yq-go pkgs.jq pkgs.docker-compose ]; }
  ''
    failed=0
    fail() { echo "FAIL: $*" >&2; failed=1; }
    # The file with its anchors and merge keys resolved, as compose reads it.
    yq --yaml-fix-merge-anchor-to-spec=true 'explode(.)' ${compose} > flat.yaml
    is() { # EXPRESSION VALUE, on the services of the flat file
      got=$(yq ".services.$1" flat.yaml)
      [ "$got" = "$2" ] || fail ".services.$1 is '$got', not '$2'"
    }
    matches() { # EXPRESSION ERE
      got=$(yq ".services.$1" flat.yaml)
      [[ $got =~ $2 ]] || fail ".services.$1 is '$got', which does not match $2"
    }

    # The project name, which the container names (paperless-webserver-1 and
    # so on) and Kuma's container-scope push hang on.
    got=$(yq '.name' flat.yaml)
    [ "$got" = paperless ] || fail "the project is named '$got', not paperless"

    # The services, and no Tika or Gotenberg anywhere.
    got=$(yq '.services | keys | sort | join(",")' flat.yaml)
    [ "$got" = archive-copy,broker,db,exporter,webserver ] || fail "the services are $got"
    if yq '.services | to_entries | .[] | .key + " " + (.value.image // "")' flat.yaml | grep -iE 'tika|gotenberg'; then
      fail "a Tika or Gotenberg service"
    fi
    if yq '.services[].environment // {} | keys | .[]' flat.yaml | grep -E '^PAPERLESS_(TIKA|GOTENBERG)'; then
      fail "a Tika or Gotenberg setting"
    fi

    # Images, by exact tags.
    is webserver.image ghcr.io/paperless-ngx/paperless-ngx:${version}
    is exporter.image ghcr.io/paperless-ngx/paperless-ngx:${version}
    matches db.image '^docker\.io/library/postgres:18\.[0-9]+$'
    matches broker.image '^docker\.io/library/redis:8\.[0-9]+\.[0-9]+$'
    is archive-copy.image ${lib.escapeShellArg (req "PAPERLESS_ARCHIVE_COPY_IMAGE")}

    # Ports and networks.
    is 'webserver.ports | length' 1
    is 'webserver.ports[0]' ${lib.escapeShellArg ports}
    for s in db broker exporter archive-copy; do
      is "$s.ports // \"none\"" none
    done
    is 'db.networks | join(",")' backend
    is 'broker.networks | join(",")' backend
    got=$(yq '.networks.backend.internal' flat.yaml)
    [ "$got" = true ] || fail "the network backend is not internal"

    # Every service: the Paperless account, no capabilities, no new
    # privileges, nothing of the host's, and no env_file.
    for s in webserver db broker exporter archive-copy; do
      is "$s.user" ${lib.escapeShellArg user}
      is "$s.cap_drop | join(\",\")" ALL
      is "$s.security_opt | join(\",\")" no-new-privileges:true
      for key in cap_add privileged network_mode pid ipc devices env_file volumes_from userns_mode; do
        is "$s.$key // \"none\"" none
      done
    done

    # The webserver.
    ${envChecks "webserver" webserverEnv}
    for key in PAPERLESS_OCR_LANGUAGES USERMAP_UID USERMAP_GID \
      PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP PAPERLESS_SOCIAL_ACCOUNT_SYNC_STAFF_GROUP \
      PAPERLESS_ADMIN_USER PAPERLESS_ADMIN_PASSWORD; do
      is "webserver.environment.$key // \"none\"" none
    done
    got=$(yq '.services.webserver.environment.PAPERLESS_DISABLE_REGULAR_LOGIN // "false"' flat.yaml)
    [ "$got" = false ] || fail "PAPERLESS_DISABLE_REGULAR_LOGIN is '$got'"
    # No group sync: it replaces an account's groups at every login,
    # `family` included.
    got=$(yq '.services.webserver.environment.PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS // "false"' flat.yaml)
    [ "$got" = false ] || fail "PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS is '$got'"
    is 'webserver.volumes | join(",")' ${lib.escapeShellArg webserverVolumes}
    is 'webserver.healthcheck.test | join(" ")' 'CMD curl -fsS -L --max-time 2 http://localhost:8000'

    # The OIDC provider.
    yq '.services.webserver.environment.PAPERLESS_SOCIALACCOUNT_PROVIDERS' flat.yaml > providers.json
    if jq -e . providers.json > /dev/null; then
      oidc() { # JQ VALUE
        got=$(jq -r "$1" providers.json)
        [ "$got" = "$2" ] || fail "the provider JSON's $1 is '$got', not '$2'"
      }
      oidc 'keys | join(",")' openid_connect
      oidc '.openid_connect.APPS | length' 1
      oidc '.openid_connect.APPS[0].provider_id' authelia
      oidc '.openid_connect.APPS[0].client_id' paperless
      oidc '.openid_connect.APPS[0].secret' ${lib.escapeShellArg (req "PAPERLESS_OIDC_CLIENT_SECRET")}
      oidc '.openid_connect.APPS[0].settings.server_url' ${lib.escapeShellArg (req "PAPERLESS_OIDC_SERVER_URL")}
      oidc '.openid_connect.APPS[0].settings.token_auth_method' client_secret_basic
      oidc '.openid_connect.OAUTH_PKCE_ENABLED' true
      oidc '.openid_connect.APPS[0].settings.oauth_pkce_enabled' true
      oidc '.openid_connect.SCOPE | index("groups") != null' true
      oidc '.openid_connect.SCOPE | index("openid") != null' true
    else
      fail "PAPERLESS_SOCIALACCOUNT_PROVIDERS is not JSON"
    fi

    # The exporter.
    ${envChecks "exporter" exporterEnv}
    is 'exporter.volumes | join(",")' ${lib.escapeShellArg exporterVolumes}
    # It waits for a migrated database: the webserver healthy.
    is 'exporter.depends_on.webserver.condition' service_healthy
    is 'exporter.entrypoint | join(" ")' '/usr/bin/bash -c'
    is 'exporter.command | length' 1
    yq '.services.exporter.command[0]' flat.yaml > exporter.sh
    grep -qF 'manage.py document_exporter /usr/src/paperless/export --no-progress-bar' exporter.sh ||
      fail "the exporter does not run document_exporter /usr/src/paperless/export --no-progress-bar"
    if grep -nE -- '--delete|--passphrase|--zip|--data-only' exporter.sh; then
      fail "the exporter passes a flag that deletes, encrypts or narrows the export"
    fi

    # archive-copy.
    is 'archive-copy.pull_policy' never
    for s in webserver db broker exporter; do
      is "$s.pull_policy // \"none\"" none
    done
    is 'archive-copy.entrypoint | join(" ")' ravnix-paperless-copy
    is 'archive-copy.command | join(" ")' '--media /media --targets /targets'
    is 'archive-copy.volumes | join(",")' ${lib.escapeShellArg "${data}/media:/media:ro"}
    is 'archive-copy.environment | keys | sort | join(",")' KUMA_PUSH_URL,TZ
    is 'archive-copy.environment.KUMA_PUSH_URL' '${"$"}{KUMA_PUSH_URL_PAPERLESS_COPY:-}'
    is 'archive-copy.environment.TZ' Europe/Berlin

    # No address, no URL and no value of anyone's in the file itself.
    if grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' ${compose}; then fail "the file holds an IPv4 address"; fi
    if grep -vE '^\s*#' ${compose} | grep -E 'https?://' | grep -vF '"http://localhost:8000"'; then
      fail "the file holds a URL outside a comment"
    fi
    # Every variable the file reads ($$ is compose's escape for a literal
    # dollar, which the exporter's loop uses) is described in its header and
    # in .env.example, and the required ones stop compose with a message.
    vars=$(sed 's/\$\$//g' ${compose} | grep -oE '\$\{[A-Z_]+' | cut -c3- | sort -u)
    [ -n "$vars" ] || fail "the file reads no variable"
    for var in $vars; do
      grep -qE "^#   $var( |$)" ${compose} || fail "$var is not described in the header"
      grep -qF "\''${$var:?set $var in .env}" ${compose} || grep -qF "\''${$var:-" ${compose} ||
        fail "$var has neither a message for when it is missing nor a default"
      grep -qE "^#? ?$var=" ${envExample} || fail "$var is not in .env.example"
    done
    for var in $(grep -oE '^#? ?[A-Z_]+=' ${envExample} | tr -d '# =' | sort -u); do
      grep -qxF "$var" <<< "$vars" || fail ".env.example sets $var, which the file does not read"
    done
    # .env.example holds no secret, and no address.
    for var in PAPERLESS_SECRET_KEY PAPERLESS_DB_PASSWORD PAPERLESS_OIDC_CLIENT_SECRET \
      PAPERLESS_BIND_ADDRESS KUMA_PUSH_URL_PAPERLESS_EXPORT KUMA_PUSH_URL_PAPERLESS_COPY; do
      grep -qxE "#? ?$var=" ${envExample} || fail ".env.example gives $var a value"
    done

    # docker-compose itself: the file is valid with every variable set, and
    # leaving out a required one stops it with that variable's message.
    export HOME=$PWD
    mkdir project
    cp ${compose} project/docker-compose.yaml
    printf '%s' ${lib.escapeShellArg envFile} > project/.env
    if docker-compose --project-directory project -f project/docker-compose.yaml config --format json > resolved.json 2> config.err; then
      r() { jq -r "$1" resolved.json; }
      [ "$(r '.services.webserver.ports | length')" = 1 ] || fail "the resolved webserver publishes $(r '.services.webserver.ports | length') ports"
      [ "$(r '.services.webserver.ports[0] | "\(.host_ip) \(.published) \(.target)"')" = "192.0.2.10 8010 8000" ] ||
        fail "the resolved port is $(r '.services.webserver.ports[0]')"
      [ "$(r '.services."archive-copy".pull_policy')" = never ] ||
        fail "compose reads archive-copy's pull_policy as $(r '.services."archive-copy".pull_policy')"
      r '.services.webserver.environment.PAPERLESS_SOCIALACCOUNT_PROVIDERS' > resolved-providers.json
      [ "$(jq -r '.openid_connect.APPS[0] | "\(.secret) \(.settings.server_url)"' resolved-providers.json)" = \
        "test-client-secret https://auth.example.org" ] || fail "the resolved provider JSON is $(cat resolved-providers.json)"
      # config keeps compose's $$ escape in what it prints; the container
      # gets a single $.
      r '.services.exporter.command[0]' | sed 's/\$\$/$/g' > exporter-resolved.sh
    else
      cat config.err >&2
      fail "docker-compose config fails with every variable set"
    fi
    cp project/.env full.env
    for var in ${lib.concatStringsSep " " (lib.attrNames testEnv)}; do
      grep -v "^$var=" full.env > project/.env
      if docker-compose --project-directory project -f project/docker-compose.yaml config > /dev/null 2> config.err; then
        fail "docker-compose config passes without $var"
      elif ! grep -qF "set $var in .env" config.err; then
        cat config.err >&2
        fail "docker-compose config without $var does not say to set it"
      fi
    done

    # The exporter's loop, against stubs.
    if [ -s exporter-resolved.sh ]; then
      bash ${./helpers/paperless-exporter-loop.sh} exporter-resolved.sh || fail "the exporter's loop"
    else
      fail "no resolved exporter loop to run"
    fi

    [ "$failed" = 0 ] || exit 1
    touch $out
  ''
