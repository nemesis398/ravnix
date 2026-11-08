# The Helium web apps (modules/desktop/webapps.nix): the app_id a window of
# `helium --app=URL` gets, which the .desktop file's StartupWMClass and sway's
# rules must match, derived from the URL (lib/webapp-app-id.nix); the six
# launchers and what is in each; and that a service the user did not name gets
# no launcher.
#
# Chromium builds the app_id of an --app window from the URL: "chrome-", the
# host, "_", the path with every "/" turned into "_", "-" and the profile's
# directory name. Three values were measured on the running Fedora desktop
# with `swaymsg -t get_tree` (stow/README.md there) and are the oracle here:
#
#   https://cooking.<host>/   chrome-cooking.<host>__-Default
#   https://claude.ai/new     chrome-claude.ai__new-Default
#
# The rest of the cases are the same rule on the shapes of URL a user can type
# into me.nix: no path, a port, a query, a deep path, capitals, a login in
# front of the host.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  appId = import ../../lib/webapp-app-id.nix { inherit lib; };

  cases = [
    # measured
    {
      url = "https://cooking.example.org/";
      id = "chrome-cooking.example.org__-Default";
    }
    {
      url = "https://claude.ai/new";
      id = "chrome-claude.ai__new-Default";
    }
    # the same URL without its root path is the same window
    {
      url = "https://cloud.example.org";
      id = "chrome-cloud.example.org__-Default";
    }
    # the port is not part of the host
    {
      url = "https://ai.example.org:8443/";
      id = "chrome-ai.example.org__-Default";
    }
    # every slash of the path
    {
      url = "https://x.example.org/a/b/";
      id = "chrome-x.example.org__a_b_-Default";
    }
    # the query and the fragment are no part of the path
    {
      url = "https://x.example.org/a?q=1#top";
      id = "chrome-x.example.org__a-Default";
    }
    {
      url = "https://x.example.org?q=1";
      id = "chrome-x.example.org__-Default";
    }
    # hosts are lower case in a URL
    {
      url = "https://Cloud.Example.ORG/Files";
      id = "chrome-cloud.example.org__Files-Default";
    }
    # a login in front of the host is no part of it
    {
      url = "https://user:secret@x.example.org/";
      id = "chrome-x.example.org__-Default";
    }
    # characters a file name cannot hold
    {
      url = "https://x.example.org/a:b*c|d";
      id = "chrome-x.example.org__a_b_c_d-Default";
    }
    # plain http
    {
      url = "http://x.example.org/";
      id = "chrome-x.example.org__-Default";
    }
  ];
  refused = [
    ""
    "x.example.org"
    "ftp://x.example.org/"
    "https://"
    "https:///path"
  ];

  idFailures =
    lib.concatMap (
      c:
      let
        got = builtins.tryEval (appId c.url);
      in
      lib.optional (!got.success || got.value != c.id)
        "${c.url}: expected ${c.id}, got ${if got.success then got.value else "an error"}"
    ) cases
    ++ lib.concatMap (
      u:
      lib.optional (builtins.tryEval (appId u)).success "${builtins.toJSON u} is accepted, it is no http(s) URL with a host"
    ) refused;

  urls = {
    # a query with &, and a percent sign: quoted, and written %%
    mealie = "https://recipes.example.org/?a=1&b=100%25";
    nextcloud = "https://cloud.example.org/";
    vaultwarden = "https://passwords.example.org/";
    openwebui = "https://ai.example.org/";
  };
  mkHost =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.desktop ] ++ extra;
    };
  full = mkHost [
    { ravnix.apps.webapps = lib.mapAttrs (_: url: { url = lib.mkForce url; }) urls; }
  ];
  # A user who runs none of the self-hosted services.
  bare = mkHost [
    {
      ravnix.apps.webapps = lib.mapAttrs (_: _: { url = lib.mkForce null; }) urls;
    }
  ];

  launcherNames =
    h:
    lib.sort lib.lessThan (
      map lib.getName (
        lib.filter (p: lib.hasPrefix "webapp-" (lib.getName p)) h.config.environment.systemPackages
      )
    );
  setFailures =
    lib.optional (
      launcherNames full != [
        "webapp-apple-music.desktop"
        "webapp-claude.desktop"
        "webapp-mealie.desktop"
        "webapp-nextcloud.desktop"
        "webapp-openwebui.desktop"
        "webapp-vaultwarden.desktop"
      ]
    ) "a host that names all four services has the launchers ${toString (launcherNames full)}"
    ++
      lib.optional
        (
          launcherNames bare != [
            "webapp-apple-music.desktop"
            "webapp-claude.desktop"
          ]
        )
        "a host that names none has the launchers ${toString (launcherNames bare)}; only Claude and Apple Music have public addresses";

  # An address that would need an escape in the Exec line is refused when the
  # option is read, and so is one that is no http(s) URL.
  refusedUrls = [
    "https://x.example.org/\"; rm"
    "https://x.example.org/$HOME"
    "https://x.example.org/`id`"
    "https://x.example.org/a\\b"
    "https://x.example.org/a b"
    "x.example.org"
    "ftp://x.example.org/"
  ];
  urlFailures = lib.concatMap (
    u:
    lib.optional
      (builtins.tryEval (
        (mkHost [ { ravnix.apps.webapps.mealie.url = lib.mkForce u; } ])
        .config.ravnix.apps.webapps.mealie.url
      )).success
      "${builtins.toJSON u} is accepted as the address of a web app"
  ) refusedUrls;

  # What each launcher holds: file, address, name and the words fuzzel finds it by.
  expected = {
    webapp-claude = {
      url = "https://claude.ai/new";
      name = "Claude";
      keywords = "claude;anthropic;ai;ki;chat;assistant";
    };
    webapp-apple-music = {
      url = "https://music.apple.com/";
      name = "Apple Music";
      keywords = "apple;music;musik;player;itunes;sidra";
    };
    webapp-mealie = {
      url = urls.mealie;
      exec = ''helium "--app=https://recipes.example.org/?a=1&b=100%%25"'';
      name = "Mealie";
      keywords = "mealie;recipe;recipes;rezept;rezepte;kochen;cooking;meal";
    };
    webapp-nextcloud = {
      url = urls.nextcloud;
      name = "Nextcloud";
      keywords = "nextcloud;cloud;dateien;files;kalender;calendar;deck;talk";
    };
    webapp-vaultwarden = {
      url = urls.vaultwarden;
      name = "Vaultwarden";
      keywords = "vaultwarden;bitwarden;password;passwort;passwörter;vault;tresor";
    };
    webapp-openwebui = {
      url = urls.openwebui;
      name = "Open WebUI";
      keywords = "open webui;ai;ki;chat;assistant";
    };
  };
  checks = lib.concatStrings (
    lib.mapAttrsToList (file: e: ''
      check ${lib.escapeShellArg file} ${lib.escapeShellArg e.name} ${
        lib.escapeShellArg (e.exec or "helium --app=${e.url}")
      } ${lib.escapeShellArg (appId e.url)} ${lib.escapeShellArg e.keywords}
    '') expected
  );
in
pkgs.runCommand "desktop-webapps"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
    applications = pkgs.buildEnv {
      name = "webapps";
      paths = lib.filter (
        p: lib.hasPrefix "webapp-" (lib.getName p)
      ) full.config.environment.systemPackages;
      pathsToLink = [ "/share/applications" ];
    };
    failures = lib.concatMapStrings (f: "${f}\n") (idFailures ++ setFailures ++ urlFailures);
    passAsFile = [ "failures" ];
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
    while IFS= read -r line; do [ -n "$line" ] && fail "$line"; done < "$failuresPath"

    check() {
      file=$applications/share/applications/$1.desktop
      if [ ! -e "$file" ]; then fail "$1.desktop does not exist"; return; fi
      want() { grep -qxF -- "$1" "$file" || fail "$1.desktop lacks the line $1"; }
      want "Type=Application"
      want "Name=$2"
      want "Exec=$3"
      want "StartupWMClass=$4"
      want "Terminal=false"
      want "StartupNotify=true"
      want "Categories=Network"
      want "Keywords=$5"
      grep -q 'Icon=.' "$file" || fail "$1.desktop has no icon"
      # No field code: fuzzel drops them and an app window takes no argument.
      # (%% is a literal percent sign, not a field code.)
      if grep '^Exec=' "$file" | sed 's/%%//g' | grep -q '%'; then fail "$1.desktop has a field code in Exec"; fi
    }
    ${checks}

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
