# The applications of huginn (modules/desktop/apps.nix): every app of the spec's
# "Apps on huginn" table that this task owns resolves on PATH or as a .desktop
# file in the profile of the laptop shape; none of the dropped apps is in the
# system's closure; Flatpak is off; the only unfree packages are the ones the
# module names; the wtype is 0.5 or later; Handy is pinned to the iGPU; MangoHud
# has no transparent background; and Helium gets its policies.
#
# The rows of the table that belong to other tasks (CUPS, scanning, NetBird,
# NordVPN, logiops and the udev rules) are Task 3.6's checks (desktop-printing).
#
# Packet Tracer cannot be built without Cisco's download, which no build can
# fetch. The system under test gets an empty package of the same name for it, so
# the closure can be built; the real package is checked for the file name and
# hash it asks the user to add to the store (see "packet tracer" below).
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

  stubPacketTracer = _final: prev: {
    cisco-packet-tracer_9 = prev.runCommand "cisco-packet-tracer-stub" { } ''
      mkdir -p $out/bin $out/share/applications
      printf '#!/bin/sh\n' > $out/bin/packettracer9
      chmod +x $out/bin/packettracer9
      printf '[Desktop Entry]\nType=Application\nName=Packet Tracer\nExec=packettracer9\n' \
        > $out/share/applications/cisco-packet-tracer-9.desktop
    '';
  };

  mkHost =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.desktop ] ++ extra;
    };
  host = mkHost [
    {
      nixpkgs.overlays = [ stubPacketTracer ];
      ravnix.apps.packetTracer = lib.mkForce true;
    }
  ];
  # The default: Packet Tracer is not asked for, so the host builds without
  # Cisco's download.
  withoutPacketTracer = mkHost [ ];
  config = host.config;
  user = config.ravnix.user.username;
  hm = config.home-manager.users.${user};
  roles = config.ravnix.theme.roles;

  # Everything a user of the laptop shape has on PATH or in the application
  # menu: the system profile and the user's.
  profile = pkgs.buildEnv {
    name = "huginn-apps";
    paths = config.environment.systemPackages ++ config.users.users.${user}.packages;
    pathsToLink = [
      "/bin"
      "/share/applications"
    ];
    ignoreCollisions = true;
  };

  closure = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };

  # The rows of the table, with what proves each one is there.
  apps = [
    {
      app = "ghostty";
      bins = [
        "ghostty"
        "ghostty-float"
      ];
    }
    {
      app = "helium";
      bins = [ "helium" ];
      desktops = [ "helium" ];
    }
    {
      app = "obsidian";
      bins = [ "obsidian" ];
      desktops = [ "md.obsidian.Obsidian" ];
    }
    {
      app = "onlyoffice";
      bins = [ "onlyoffice-desktopeditors" ];
      desktops = [ "onlyoffice-desktopeditors" ];
    }
    {
      app = "bitwarden";
      bins = [
        "bitwarden"
        "rbw"
      ];
      desktops = [ "bitwarden" ];
    }
    {
      app = "handy";
      bins = [
        "handy-launch"
        "handy-ptt"
      ];
      desktops = [ "Handy" ];
    }
    {
      app = "steam";
      bins = [ "steam" ];
      desktops = [ "steam" ];
    }
    {
      app = "prismlauncher";
      bins = [ "prismlauncher" ];
    }
    {
      app = "mangohud";
      bins = [ "mangohud" ];
    }
    {
      app = "gamemode";
      bins = [ "gamemoderun" ];
    }
    {
      app = "mpv";
      bins = [ "mpv" ];
      desktops = [ "mpv" ];
    }
    {
      app = "blanket";
      bins = [ "blanket" ];
    }
    {
      app = "localsend";
      bins = [ "localsend_app" ];
    }
    {
      app = "wl-mirror";
      bins = [ "wl-mirror" ];
    }
    {
      app = "packet tracer";
      bins = [ "packettracer9" ];
    }
    {
      app = "bazecor";
      bins = [ "bazecor" ];
    }
    {
      app = "yazi";
      bins = [ "yazi" ];
    }
    {
      app = "wiremix";
      bins = [ "wiremix" ];
    }
    {
      app = "bluetui";
      bins = [ "bluetui" ];
    }
    {
      app = "nmtui";
      bins = [ "nmtui" ];
    }
    {
      app = "nextcloud client";
      bins = [ "nextcloud" ];
    }
    {
      app = "wtype";
      bins = [ "wtype" ];
    }
  ];
  appLine =
    a:
    lib.concatStringsSep " " (
      [ (lib.escapeShellArg a.app) ]
      ++ map (b: "bin:${b}") (a.bins or [ ])
      ++ map (d: "desktop:${d}") (a.desktops or [ ])
    );

  # The five web apps, by the file name of their launcher. The Vaultwarden web
  # app is on the spec's list of dropped apps: Bitwarden desktop and the browser
  # extension take its place, so no launcher and no option for it may exist.
  webapps = [
    "webapp-claude"
    "webapp-apple-music"
    "webapp-mealie"
    "webapp-nextcloud"
    "webapp-openwebui"
  ];
  droppedWebapps = [ "webapp-vaultwarden" ];

  # The dropped apps, as the brief lists them. Each is the start of the
  # package name in a store path, followed by a version.
  dropped = {
    Chromium = [
      "chromium"
      "ungoogled-chromium"
    ];
    Joplin = [
      "joplin"
      "joplin-desktop"
    ];
    Anki = [
      "anki"
      "anki-bin"
    ];
    Element = [ "element-desktop" ];
    Sidra = [ "sidra" ];
    Thunderbird = [
      "thunderbird"
      "thunderbird-bin"
    ];
    Thunar = [ "thunar" ];
    pavucontrol = [ "pavucontrol" ];
    blueman = [ "blueman" ];
    nm-connection-editor = [
      "nm-connection-editor"
      "network-manager-applet"
    ];
    foot = [ "foot" ];
    tmux = [ "tmux" ];
    zathura = [ "zathura" ];
    httpie = [ "httpie" ];
    opencode = [ "opencode" ];
    MakeMKV = [ "makemkv" ];
    FreeRDP = [ "freerdp" ];
    Flatpak = [ "flatpak" ];
  };
  droppedPatterns = lib.concatStringsSep "\n" (
    lib.concatLists (lib.mapAttrsToList (label: names: map (n: "${label}\t${n}") names) dropped)
  );

  unfree = [
    "CiscoPacketTracer_901_Ubuntu_64bit.deb"
    "cisco-packet-tracer"
    "obsidian"
    "steam"
    "steam-unwrapped"
    "widevine-cdm"
  ];

  # Failures that need no build, found while evaluating.
  policy = builtins.fromJSON (
    (config.environment.etc."chromium/policies/managed/default.json" or { text = "{}"; }).text
  );
  mango = (hm.xdg.configFile."MangoHud/MangoHud.conf" or { text = ""; }).text;
  mangoColor = hex: lib.removePrefix "#" hex;
  handyLaunch =
    if self.packages.${system} ? handy-launch then
      builtins.readFile "${self.packages.${system}.handy-launch}/bin/handy-launch"
    else
      "";

  evalFailures =
    lib.optional config.services.flatpak.enable "Flatpak is enabled"
    ++ lib.optional (
      host.options.ravnix.apps.webapps ? vaultwarden
    ) "ravnix.apps.webapps.vaultwarden exists, but the Vaultwarden web app is dropped"
    ++ lib.optional (lib.any (
      p: lib.hasPrefix "webapp-vaultwarden" (lib.getName p)
    ) config.environment.systemPackages) "a webapp-vaultwarden launcher is installed"
    ++ lib.optional (lib.any (p: lib.getName p == "cisco-packet-tracer")
      withoutPacketTracer.config.environment.systemPackages
    ) "Packet Tracer is installed although ravnix.apps.packetTracer is not set"
    ++ lib.optional (
      !lib.any (p: lib.getName p == "cisco-packet-tracer-stub") config.environment.systemPackages
    ) "Packet Tracer is not installed although ravnix.apps.packetTracer is set"
    ++ lib.optional (
      (config.nixpkgs.config.allowUnfree or false) != false
    ) "nixpkgs.config.allowUnfree is set; the module names the unfree packages it needs"
    ++
      lib.optional (lib.sort lib.lessThan (config.nixpkgs.config.allowUnfreePackages or [ ]) != unfree)
        "allowUnfreePackages is ${
          builtins.toJSON (config.nixpkgs.config.allowUnfreePackages or [ ])
        }, expected ${builtins.toJSON unfree}"
    ++
      lib.optional (!lib.versionAtLeast host.pkgs.wtype.version "0.5")
        "wtype ${host.pkgs.wtype.version} is older than 0.5, which holds atx/wtype 82bca82 (printable keycodes for literal text)"
    ++ lib.optional (
      !(lib.hasInfix "background_alpha=1\n" (mango + "\n"))
    ) "MangoHud background_alpha is not 1"
    ++ lib.optional (
      !(lib.hasInfix "background_color=${mangoColor roles.canvas}" mango)
    ) "MangoHud background is not the canvas role"
    ++ lib.optional (
      !(lib.hasInfix "frametime_color=${mangoColor roles.accent}" mango)
    ) "MangoHud frametime graph is not the accent"
    ++ lib.optional (
      builtins.match ".*card[0-9].*" handyLaunch != null
    ) "handy-launch names a GPU by cardN"
    ++ lib.optional (
      builtins.match ".*50_mesa[.]json.*" handyLaunch == null
    ) "handy-launch does not pin the EGL vendor to Mesa"
    ++ lib.optional (
      builtins.match ".*radeon_icd[.]x86_64[.]json.*" handyLaunch == null
    ) "handy-launch does not pin Vulkan to RADV"
    ++ lib.optional (
      !lib.elem "clngdbkpkpeebahjckkjfobafhncgmne" (policy.ExtensionInstallForcelist or [ ])
    ) "Stylus is not force-installed in Helium"
    ++ lib.optional (
      !lib.elem "nngceckbapebfimnlniiiahkandclblb" (policy.ExtensionInstallForcelist or [ ])
    ) "the Bitwarden extension is not force-installed in Helium"
    ++ lib.optional (
      hm.xdg.mimeApps.defaultApplications."x-scheme-handler/https" or null != [ "helium.desktop" ]
    ) "Helium is not the default browser"
    ++ lib.optional (
      hm.xdg.mimeApps.defaultApplications."application/pdf" or null != [ "helium.desktop" ]
    ) "Helium is not the default PDF viewer"
    ++ lib.optional (
      hm.xdg.mimeApps.defaultApplications."image/png" or null != [ "helium.desktop" ]
    ) "Helium is not the default image viewer";

  # A user with no userstyles repository, and another accent. The browser's
  # theme follows the accent, and the bookmark to the repository is there only
  # when the repository is.
  other = mkHost [
    {
      nixpkgs.overlays = [ stubPacketTracer ];
      ravnix.apps.packetTracer = lib.mkForce true;
    }
    {
      ravnix.apps.userstylesUrl = lib.mkForce null;
      ravnix.theme.accent = lib.mkForce "teal";
    }
  ];
  themeOf =
    h:
    (builtins.fromJSON
      h.config.home-manager.users.${user}.xdg.dataFile."helium/themes/ravnix/manifest.json".text
    ).theme.colors;
  bookmarkUrls =
    h:
    map (b: b.url or "") (
      # extraOpts go to extra.json; Chromium reads every file of the directory.
      (builtins.fromJSON h.config.environment.etc."chromium/policies/managed/extra.json".text)
      .ManagedBookmarks or [ ]
    );
  themeFailures =
    lib.optional
      (
        (themeOf host).toolbar_button_icon or null != [
          203
          166
          247
        ]
      )
      "the browser theme's icons are not Mauve, the default accent: ${
        builtins.toJSON ((themeOf host).toolbar_button_icon or null)
      }"
    ++
      lib.optional
        (
          (themeOf other).toolbar_button_icon or null != [
            148
            226
            213
          ]
        )
        "the browser theme's icons do not follow the accent (teal): ${
          builtins.toJSON ((themeOf other).toolbar_button_icon or null)
        }"
    ++ lib.optional (
      (themeOf other).toolbar or null != (themeOf host).toolbar
    ) "the accent changed the browser theme's toolbar"
    ++ lib.optional (
      !lib.elem config.ravnix.apps.userstylesUrl (bookmarkUrls host)
    ) "the bookmark to the user's userstyles repository is missing"
    ++ lib.optional (lib.any (u: lib.hasPrefix "https://git" u) (
      bookmarkUrls other
    )) "a bookmark to a userstyles repository is there for a user with none"
    ++
      lib.optional (lib.length (bookmarkUrls other) != 2)
        "the bookmarks of a user with no repository are ${builtins.toJSON (bookmarkUrls other)}, not the folder and the official page";

  # Packet Tracer as nixpkgs has it: a requireFile of Cisco's .deb. The name and
  # hash are what the user adds to the store by hand.
  realPacketTracer = pkgs.cisco-packet-tracer_9.src.src;
in
pkgs.runCommand "desktop-apps"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.coreutils
      pkgs.gnused
    ];
    passAsFile = [
      "evalFailures"
      "droppedPatterns"
    ];
    evalFailures = lib.concatMapStrings (f: "${f}\n") (
      evalFailures
      ++ themeFailures
      ++ lib.optional (
        realPacketTracer.name != "CiscoPacketTracer_901_Ubuntu_64bit.deb"
      ) "Packet Tracer asks for ${realPacketTracer.name}"
      ++ lib.optional (
        (realPacketTracer.outputHash or "") != "sha256-NoPdh+d5iFNyrpo1wabllNEvST5knnxpdAhynBRZR5s="
      ) "Packet Tracer's hash changed: ${realPacketTracer.outputHash or "none"}"
    );
    inherit droppedPatterns;
    inherit profile;
    closureStorePaths = "${closure}/store-paths";
    appLines = lib.concatMapStrings (a: "${appLine a}\n") apps;
    webappFiles = lib.concatStringsSep " " webapps;
    droppedWebappFiles = lib.concatStringsSep " " droppedWebapps;
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

    # --- what the evaluation found
    while IFS= read -r line; do
      [ -n "$line" ] && fail "$line"
    done < "$evalFailuresPath"

    # --- every app resolves on PATH or as a .desktop file
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      eval "set -- $line"
      app=$1; shift
      for item in "$@"; do
        case $item in
          bin:*)     f="$profile/bin/''${item#bin:}";;
          desktop:*) f="$profile/share/applications/''${item#desktop:}.desktop";;
        esac
        if [ ! -e "$f" ]; then
          fail "$app: $item not found"
        else
          case $item in bin:*) [ -x "$f" ] || fail "$app: $item is not executable";; esac
        fi
      done
    done < <(printf '%s' "$appLines")

    # NixOS's offload command is prime-run (the hardware module); a second one
    # from here would collide with it.
    [ ! -e "$profile/bin/prime-run" ] || fail "this module installs a prime-run"

    for w in $webappFiles; do
      [ -e "$profile/share/applications/$w.desktop" ] || fail "webapp: $w.desktop not found"
    done
    for w in $droppedWebappFiles; do
      [ ! -e "$profile/share/applications/$w.desktop" ] || fail "webapp: $w.desktop exists, but that web app is dropped"
    done

    # --- the matcher for the dropped apps, tried on made-up store paths first
    # so that a wrong pattern cannot pass by finding nothing
    names() { sed 's|^/nix/store/[a-z0-9]\{32\}-||' "$1"; }
    hits() {
      # $1: file of store paths. Prints "label name" for each dropped app found.
      names "$1" > names.txt
      while IFS=$'\t' read -r label name; do
        [ -n "$label" ] || continue
        if grep -Eq "^$name(-[A-Za-z][A-Za-z0-9_]*)*-[0-9]" names.txt; then
          printf '%s\n' "$label ($name)"
        fi
      done < "$droppedPatternsPath"
    }
    : > probe-paths
    while IFS=$'\t' read -r label name; do
      [ -n "$label" ] || continue
      printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-%s-1.2.3\n' "$name" >> probe-paths
    done < "$droppedPatternsPath"
    printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foot-terminfo-1.2.3-man\n' >> probe-paths
    expected=$(wc -l < "$droppedPatternsPath")
    found=$(hits probe-paths | wc -l)
    [ "$found" -ge "$expected" ] || fail "the dropped-app matcher found $found of $expected made-up paths"
    : > clean-paths
    printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-footprint-1.0\n/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-tmuxinator-1.0\n/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-chromium-codecs-x\n' >> clean-paths
    [ -z "$(hits clean-paths | grep -v '^$' || true)" ] || fail "the dropped-app matcher flags names that only start alike: $(hits clean-paths)"

    # --- the system's closure, which must be a real one
    names "$closureStorePaths" > closure-names.txt
    for must in ghostty helium obsidian steam; do
      grep -Eq "^$must(-[A-Za-z][A-Za-z0-9_]*)*-[0-9]" closure-names.txt || fail "closure: $must is not in the system's closure"
    done
    for h in $(hits "$closureStorePaths" | tr ' ' '_'); do
      fail "closure: dropped app $h is in the system's closure"
    done
    for w in $droppedWebappFiles; do
      ! grep -q "^$w" closure-names.txt || fail "closure: $w is in the system's closure"
    done

    if [ "$failed" = 0 ]; then
      echo "all apps resolve; no dropped app in $(wc -l < "$closureStorePaths") store paths"
      touch $out
    else
      exit 1
    fi
  ''
