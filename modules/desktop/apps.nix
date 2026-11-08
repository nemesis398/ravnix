# The graphical applications of huginn, and the terminal programs that control
# the laptop's own hardware. One row of the spec's "Apps on huginn" table each;
# the rows of Task 3.6 (printing and scanning, VPN, logiops and the udev rules
# of the peripherals) are not here, and the web apps are in webapps.nix.
#
#   Terminal       ghostty, and ghostty-float, the terminal that floats
#   Browser        Helium (packages/helium): default browser, PDF and image
#                  viewer; its policies install Stylus and the Bitwarden
#                  extension
#   Notes          Obsidian
#   Office         OnlyOffice
#   Passwords      Bitwarden desktop, which provides the SSH agent; rbw is in
#                  the common module
#   Dictation      Handy, pinned to the iGPU (packages/handy-launch), with its
#                  hold-to-talk driver (packages/handy-ptt) and wtype
#   Games          Steam, Prism Launcher, MangoHud, gamemode
#   Media          mpv, Blanket
#   Transfer       LocalSend, wl-mirror (presenting)
#   Study          Packet Tracer
#   Peripherals    Bazecor
#   Files, audio,  yazi, wiremix, bluetui, nmtui: run locally, in the floating
#   Bluetooth,     ghostty (`ghostty-float -e yazi`), because they control this
#   network        laptop and not the server the main terminal reaches
#   Sync           the Nextcloud client
#
# Nothing here is Flatpak: the spec drops it, and it stays off.
#
# The keys that start yazi, wiremix, bluetui and nmtui are the Sway
# configuration's (`bindsym ... exec ghostty-float -e yazi`); this module makes
# the commands exist.
#
# --- Packet Tracer: one manual step ------------------------------------------
# Off unless ravnix.apps.packetTracer is true, because a host that installs it
# does not build until this is done. Cisco's download needs a login, so no
# build can fetch it. nixpkgs' cisco-packet-tracer_9 asks the Nix store for the
# file by name and hash, and stops with a message naming both when it is not
# there. On the machine that builds the host, download "Packet
# Tracer 9.0.1 for Linux (Ubuntu)" from https://www.netacad.com/resources/lab-downloads
# (a Networking Academy login), then add the file once:
#
#   nix-store --add-fixed sha256 CiscoPacketTracer_901_Ubuntu_64bit.deb
#
# The name must be exactly that, and the hash is
# sha256-NoPdh+d5iFNyrpo1wabllNEvST5knnxpdAhynBRZR5s= (tests/desktop/apps.nix
# checks both against nixpkgs, and the .deb that the Fedora laptop holds has
# this hash). A newer Packet Tracer needs a newer nixpkgs, which knows its hash.
#
# --- Userstyles: one manual step ---------------------------------------------
# The web sites are themed by Catppuccin userstyles in Stylus (docs/style.md).
# The policy below installs Stylus into Helium. The styles cannot be declared:
# Stylus keeps them in the browser's own storage, offers no managed-storage
# schema (its manifest has no storage.managed_schema, so a policy cannot hand
# it data), and its only inputs are an import file, a sync service or an
# install click on a *.user.css address. So after the first start:
#
#   1. Open the bookmarks "ravnix > Catppuccin userstyles" and follow the
#      usage page: download the import.json of all userstyles, and import it in
#      Stylus, Manage, Backup, Import.
#   2. Open "ravnix > Your userstyles" (ravnix.apps.userstylesUrl in me.nix)
#      and click the install link of each style.
#   3. In Stylus, Manage, each style's settings hold the flavor and the
#      accent: Mocha and the accent of ravnix.theme.accent.
#
# The same goes for the browser's frame: ~/.local/share/helium/themes/ravnix is
# an unpacked Chromium theme in the colors of the roles (accent included). Load
# it once, at helium://extensions with developer mode on, "Load unpacked"; the
# path stays the same, so the choice survives a rebuild.
#
# --- Exceptions to the style (docs/style.md, rule 9) -------------------------
# These applications cannot be made to follow it, or only partly:
#   Obsidian          Electron, on purpose: it holds the vault. Its look is the
#                     vault's own setting (a community theme), which ravnix
#                     must not write into the synced vault.
#   OnlyOffice        Qt and CEF with a bundled Qt that has no Wayland plugin:
#                     it runs through XWayland, and draws its own interface.
#   Steam             draws its own skin; Big Picture and the store follow Valve.
#   Packet Tracer     a Qt application with its own look.
#   Bazecor           Electron, light/dark/system only. The keyboard's LEDs are
#                     the part that can follow the palette (dygma-catppuccin-leds).
#   Handy             a WebKit interface of its own, with a tray icon.
#   Blanket, LocalSend, Prism Launcher   follow the GTK or Qt theme of the
#                     desktop module as far as their toolkits allow (Blanket is
#                     libadwaita, LocalSend is Flutter and draws its own).
#   nmtui             newt's own color scheme (NEWT_COLORS below maps it onto the
#                     terminal's palette, so it carries the Catppuccin colors
#                     but keeps newt's boxes).
# Themed by catppuccin/nix in the accent: yazi, mpv. Generated from the roles:
# MangoHud, the Helium theme. wiremix and bluetui use the terminal's palette.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.ravnix) apps theme;
  inherit (theme) roles palette;
  user = config.ravnix.user.username;

  # Chromium extension ids, from the web store: Stylus, and the Bitwarden
  # password manager.
  extensions = {
    stylus = "clngdbkpkpeebahjckkjfobafhncgmne";
    bitwarden = "nngceckbapebfimnlniiiahkandclblb";
  };

  # Bitwarden, started with Electron's password store set to the Secret
  # Service. Electron picks its keyring from the desktop environment, and
  # Chromium does not know `sway`, so it would fall back to a store without
  # encryption, quietly. gnome-keyring serves the Secret Service
  # (services.gnome.gnome-keyring below).
  bitwarden = pkgs.symlinkJoin {
    name = "bitwarden-desktop-${pkgs.bitwarden-desktop.version}";
    paths = [ pkgs.bitwarden-desktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm $out/bin/bitwarden
      makeWrapper ${lib.getExe pkgs.bitwarden-desktop} $out/bin/bitwarden \
        --add-flags --password-store=gnome-libsecret
    '';
    inherit (pkgs.bitwarden-desktop) meta;
  };

  # "#rrggbb" as the three bytes of a Chromium theme color.
  rgb =
    hex:
    let
      h = lib.removePrefix "#" hex;
      byte = i: lib.fromHexString (builtins.substring i 2 h);
    in
    [
      (byte 0)
      (byte 2)
      (byte 4)
    ];
  # The Catppuccin theme of the browser, in the roles: the frame is Crust, the
  # toolbar Base, and the accent is on the icons and the address.
  heliumTheme = builtins.toJSON {
    manifest_version = 3;
    name = "Ravnix";
    description = "Catppuccin Mocha in the accent of ravnix";
    version = "1.0.0";
    theme.colors = lib.mapAttrs (_: rgb) {
      frame = roles.deepest;
      frame_inactive = roles.deepest;
      frame_incognito = roles.selected;
      frame_incognito_inactive = roles.selected;
      bookmark_text = roles.text;
      tab_background_text = roles.label;
      tab_background_text_inactive = roles.secondary;
      tab_background_text_incognito = roles.label;
      tab_background_text_incognito_inactive = roles.secondary;
      tab_text = roles.text;
      toolbar = roles.canvas;
      toolbar_button_icon = roles.accent;
      omnibox_text = roles.accent;
      omnibox_background = roles.deepest;
      ntp_background = roles.canvas;
      ntp_link = roles.accent;
      ntp_text = roles.text;
      button_background = roles.deepest;
    };
  };

  # MangoHud wants colors without the #.
  bare = lib.removePrefix "#";
in
{
  # The unfree packages of this module, allowed by name and nothing else.
  # steam-unwrapped is Steam's download. Packet Tracer's names are allowed for a
  # host that installs it (the .deb is its download, which nixpkgs asks the
  # store for by name), and widevine-cdm, the DRM library of Helium, for a host
  # that sets ravnix.apps.widevine: nothing unfree and not redistributable is
  # forced on every laptop.
  nixpkgs.config.allowUnfreePackages = [
    "obsidian"
    "steam"
    "steam-unwrapped"
  ]
  ++ lib.optionals apps.packetTracer [
    "CiscoPacketTracer_901_Ubuntu_64bit.deb"
    "cisco-packet-tracer"
  ]
  ++ lib.optional apps.widevine "widevine-cdm";

  # No Flatpak at all on NixOS.
  services.flatpak.enable = lib.mkDefault false;

  environment.systemPackages = [
    (pkgs.ravnix.helium.override { widevineCdm = if apps.widevine then pkgs.widevine-cdm else null; })
    pkgs.ravnix.ghostty-float
    pkgs.ravnix.handy-launch
    pkgs.ravnix.handy-ptt
    # The wtype of nixpkgs is 0.5, which has the fix for characters dropped in
    # long takes (tests/desktop/wtype.nix); handy-launch puts it first on PATH.
    pkgs.wtype
    pkgs.obsidian
    pkgs.onlyoffice-desktopeditors
    bitwarden
    pkgs.prismlauncher
    pkgs.blanket
    pkgs.wl-mirror
    pkgs.bazecor
    pkgs.wiremix
    pkgs.bluetui
    pkgs.nextcloud-client
  ]
  ++ lib.optional apps.packetTracer pkgs.cisco-packet-tracer_9;

  environment.sessionVariables = {
    # nixpkgs' Electron and Chromium wrappers start in native Wayland when
    # this is set (bitwarden, obsidian, bazecor, helium); otherwise they use
    # XWayland, with a blurred window at a fractional scale.
    NIXOS_OZONE_WL = "1";
    # nmtui's color scheme, in the colors of the terminal's palette: newt names
    # the 16 ANSI colors, which ghostty maps onto Catppuccin Mocha (black is
    # Surface1, white Subtext1, the bright magenta slot is the accent).
    NEWT_COLORS = lib.concatStringsSep " " [
      "root=white,black"
      "window=white,black"
      "border=brightmagenta,black"
      "title=brightmagenta,black"
      "button=black,brightmagenta"
      "actbutton=black,brightmagenta"
      "compactbutton=white,black"
      "checkbox=white,black"
      "actcheckbox=black,brightmagenta"
      "entry=white,black"
      "disentry=gray,black"
      "label=white,black"
      "listbox=white,black"
      "actlistbox=black,brightmagenta"
      "sellistbox=white,black"
      "actsellistbox=black,brightmagenta"
      "textbox=white,black"
      "acttextbox=black,brightmagenta"
      "helpline=white,black"
      "roottext=white,black"
      "emptyscale=white,black"
      "fullscale=brightmagenta,black"
      "shadow=black,black"
    ];
  };

  programs.steam = {
    enable = true;
    # MangoHud inside Steam's own file-system view, for `mangohud %command%`.
    # Games that should render on the RTX 4050 add `prime-run`:
    # `prime-run gamemoderun mangohud %command%`.
    extraPackages = [ pkgs.mangohud ];
  };
  programs.gamemode.enable = true;
  programs.localsend = {
    enable = true;
    # LocalSend finds the other devices by multicast on 53317, and receives on
    # the same port.
    openFirewall = true;
  };

  # What the terminal programs control. All three are defaults: a host that
  # configures its own stack wins.
  networking.networkmanager.enable = lib.mkDefault true;
  hardware.bluetooth.enable = lib.mkDefault true;
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };
  # The Secret Service, for Bitwarden's keyring (the greeter's PAM unlocks it).
  services.gnome.gnome-keyring.enable = lib.mkDefault true;

  # Helium reads the policies of Chromium: the extensions it installs itself,
  # the bookmarks of the userstyles step (see the header), and no nag about
  # being the default browser (the MIME defaults below make it one).
  programs.chromium = {
    enable = true;
    extensions = [
      extensions.stylus
      extensions.bitwarden
    ];
    extraOpts = {
      DefaultBrowserSettingEnabled = false;
      ManagedBookmarks = [
        { toplevel_name = "ravnix"; }
        {
          name = "Catppuccin userstyles";
          url = "https://userstyles.catppuccin.com/getting-started/usage/";
        }
      ]
      ++ lib.optional (apps.userstylesUrl != null) {
        name = "Your userstyles";
        url = apps.userstylesUrl;
      };
    };
  };

  home-manager.sharedModules = [
    {
      programs.ghostty = {
        enable = true;
        # Each window is its own process, as on Fedora: ghostty-float starts
        # one with a class of its own, and a shared service would ignore it.
        systemd.enable = lib.mkDefault false;
        # The prompt is starship's, and ghostty's own injection is off, so the
        # integration must not source it either.
        enableBashIntegration = false;
        # The look (fonts, colors, padding, cursor) is the theme module's; these
        # are the behavior of the Fedora terminal.
        settings = {
          term = "xterm-256color";
          shell-integration = "none";
          confirm-close-surface = false;
          copy-on-select = false;
          title = "ghostty";
          window-subtitle = "";
          keybind = [
            # sway routes these through the compositor; the same keys inside a
            # pane that is ssh'd into something and not under sway.
            "ctrl+insert=copy_to_clipboard"
            "shift+insert=paste_from_clipboard"
            # Shift+Enter inserts a newline in Claude Code, also in herdr: ESC
            # then CR, the sequence both apps read as Alt+Enter.
            "shift+enter=text:\\x1b\\r"
            # Ghostty's default makes Ctrl+Enter toggle fullscreen.
            "ctrl+enter=unbind"
          ];
        };
      };

      programs.mpv.enable = true;
      programs.yazi = {
        enable = true;
        # The shell is the common module's; yazi's `y` wrapper stays out of it.
        enableBashIntegration = false;
      };
      catppuccin.mpv.enable = true;
      catppuccin.yazi.enable = true;

      # Fedora's MangoHud.conf, from the roles. The only change from there is
      # the background: fully opaque (the style design, 2026-11-07). The per-metric colors
      # carry a meaning of their own (GPU green, CPU blue, RAM pink, the FPS
      # gradient red to green), and the frame-time graph is the accent. It is
      # switched on per title in Steam: `gamemoderun mangohud %command%`.
      programs.mangohud = {
        enable = true;
        settings = {
          legacy_layout = false;
          round_corners = 0;
          background_alpha = 1;
          background_color = bare roles.canvas;
          table_columns = 3;
          font_size = 24;
          text_color = bare roles.text;
          text_outline_color = bare roles.wash;
          gpu_text = "GPU";
          gpu_stats = true;
          gpu_temp = true;
          gpu_color = bare palette.green;
          gpu_load_change = true;
          gpu_load_color = [
            (bare roles.text)
            (bare palette.peach)
            (bare palette.red)
          ];
          cpu_text = "CPU";
          cpu_stats = true;
          cpu_temp = true;
          cpu_color = bare palette.blue;
          cpu_load_change = true;
          cpu_load_color = [
            (bare roles.text)
            (bare palette.peach)
            (bare palette.red)
          ];
          ram = true;
          ram_color = bare palette.pink;
          engine_color = bare palette.red;
          fps = true;
          fps_color_change = [
            (bare palette.red)
            (bare palette.yellow)
            (bare palette.green)
          ];
          wine = true;
          wine_color = bare palette.red;
          winesync = true;
          frame_timing = true;
          frametime_color = bare roles.accent;
          arch = true;
          fps_limit_method = "early";
          toggle_fps_limit = "Shift_L+F1";
        };
      };

      # Nextcloud's sync client starts with the session, in the tray.
      services.nextcloud-client = {
        enable = true;
        startInBackground = true;
      };

      # Helium opens web pages, PDFs and images; mpv opens video. A MIME type
      # without an entry here is opened by the first application that claims it.
      xdg.mimeApps = {
        enable = true;
        defaultApplications =
          lib.genAttrs [
            "x-scheme-handler/http"
            "x-scheme-handler/https"
            "x-scheme-handler/about"
            "x-scheme-handler/unknown"
            "text/html"
            "application/xhtml+xml"
            "application/pdf"
            "image/png"
            "image/jpeg"
            "image/gif"
            "image/webp"
            "image/svg+xml"
          ] (_: [ "helium.desktop" ])
          // lib.genAttrs [
            "video/mp4"
            "video/x-matroska"
            "video/webm"
            "video/quicktime"
            "video/x-msvideo"
            "video/mpeg"
          ] (_: [ "mpv.desktop" ]);
      };

      xdg.dataFile."helium/themes/ravnix/manifest.json".text = heliumTheme;
    }
  ];
}
