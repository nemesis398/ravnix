# The web apps: sites that open in a Helium window of their own, without the
# browser's address bar and tabs, and are found by the launcher and bound to
# keys like any other application. Claude and Apple Music are public sites;
# Mealie, Nextcloud and Open WebUI are the user's own services, and each gets a
# launcher only when its address is set (ravnix.apps.webapps.NAME.url in
# me.nix), so no address of a user is in this repository. The password vault has
# no web app: the spec drops it, and Bitwarden desktop and the browser extension
# are its clients (tests/desktop/apps.nix checks that none exists).
#
# Each launcher is a file webapp-NAME.desktop in the system profile, so
# `gtk-launch webapp-NAME` starts it. The window shares the browser's default
# profile, so a login in the browser is a login in the app. The launcher holds
# no %U or other field code (the launcher drops them, and an app window takes
# no argument).
#
# StartupWMClass is the app_id of the window, which Chromium derives from the
# address (lib/webapp-app-id.nix), so a window rule in the compositor can match
# it. All of them end in -Default, the profile's directory: a rule for them
# all is `^chrome-.*-Default$`.
#
# Apple Music replaces Sidra, an Electron client. A Helium window plays full
# tracks only when Helium has a Widevine library, which is ravnix.apps.widevine
# (packages/helium, modules/desktop/apps.nix); without it the site plays
# 30-second previews. Sidra also answered the media keys through MPRIS under
# its own name; Helium answers them as a Chromium browser, so playerctl bindings
# that named `sidra` need `chromium` or the generic player instead.
#
# Icons are Papirus-Dark's where it has one; Claude, Mealie and Open WebUI have
# none there, and get a generic icon of the theme.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  appId = import ../../lib/webapp-app-id.nix { inherit lib; };
  cfg = config.ravnix.apps.webapps;

  apps = {
    claude = {
      url = "https://claude.ai/new";
      name = "Claude";
      genericName = "AI Chat";
      comment = "Claude in a window of its own";
      icon = "internet-chat";
      keywords = [
        "claude"
        "anthropic"
        "ai"
        "ki"
        "chat"
        "assistant"
      ];
    };
    apple-music = {
      url = "https://music.apple.com/";
      name = "Apple Music";
      genericName = "Music Player";
      comment =
        "Apple Music in a window of its own"
        + lib.optionalString (!config.ravnix.apps.widevine) " (full tracks need ravnix.apps.widevine)";
      icon = "apple-music";
      keywords = [
        "apple"
        "music"
        "musik"
        "player"
        "itunes"
        "sidra"
      ];
    };
    mealie = {
      url = cfg.mealie.url;
      name = "Mealie";
      genericName = "Recipe Manager";
      comment = "Recipes and meal planning";
      icon = "org.gnome.Recipes";
      keywords = [
        "mealie"
        "recipe"
        "recipes"
        "rezept"
        "rezepte"
        "kochen"
        "cooking"
        "meal"
      ];
    };
    nextcloud = {
      url = cfg.nextcloud.url;
      name = "Nextcloud";
      genericName = "Cloud Web Interface";
      comment = "Your Nextcloud in the browser (the sync client is Nextcloud Desktop)";
      icon = "nextcloud";
      keywords = [
        "nextcloud"
        "cloud"
        "dateien"
        "files"
        "kalender"
        "calendar"
        "deck"
        "talk"
      ];
    };
    openwebui = {
      url = cfg.openwebui.url;
      name = "Open WebUI";
      genericName = "AI Chat";
      comment = "Your Open WebUI in a window of its own";
      icon = "internet-chat";
      keywords = [
        "open webui"
        "ai"
        "ki"
        "chat"
        "assistant"
      ];
    };
  };

  # The Exec line's argument. A field code starts with %, so a % in an address
  # is written %%; an address with one of the characters the Desktop Entry
  # specification reserves is quoted. The option type refuses the characters
  # that would need an escape inside the quotes (" \ $ and the backtick).
  execArg =
    url:
    let
      arg = "--app=${lib.replaceStrings [ "%" ] [ "%%" ] url}";
      reserved = builtins.match ".*[]'><~|&;*?#()[].*" arg != null;
    in
    if reserved then ''"${arg}"'' else arg;

  launcher =
    id: a:
    pkgs.makeDesktopItem {
      name = "webapp-${id}";
      desktopName = a.name;
      genericName = a.genericName;
      comment = a.comment;
      exec = "helium ${execArg a.url}";
      icon = a.icon;
      terminal = false;
      startupNotify = true;
      startupWMClass = appId a.url;
      categories = [ "Network" ];
      keywords = a.keywords;
    };
in
{
  environment.systemPackages = lib.mapAttrsToList launcher (
    lib.filterAttrs (_: a: a.url != null) apps
  );
}
