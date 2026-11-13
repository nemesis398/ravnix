# The graphical applications of huginn, and the terminal programs that control
# the laptop's own hardware. One row of the spec's "Apps on huginn" table each;
# the rows of Task 3.6 (printing and scanning, VPN, logiops and the udev rules
# of the peripherals) are not here, and the web apps are in webapps.nix.
#
#   Terminal       ghostty, and ghostty-float, the terminal that floats
#   Browser        Helium (packages/helium): default browser, PDF and image
#                  viewer; its policies install Stylus and the Bitwarden
#                  extension; its DevTools are in the theme
#                  (packages/helium-devtools-frontend)
#   Notes          Obsidian
#   Office         OnlyOffice
#   Passwords      Bitwarden desktop; rbw, in the common module, is the
#                  session's SSH agent; bitwarden-menu (bitwarden-menu.nix),
#                  when ravnix.apps.bitwardenMenu.enable is true, is a menu
#                  to the same vault
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
# --- GTK and Qt: the switch is here ------------------------------------------
# The theme module (modules/theme/gtk-qt.nix) styles GTK and Qt where
# home-manager's gtk.enable and qt.enable are on. This module installs the
# first GTK and Qt applications, so it turns both on (and the dconf service the
# GTK settings go through): the Catppuccin GTK theme, Papirus-Dark with folders
# in the accent, the Catppuccin cursor, and qt6ct with the Fusion style and
# Catppuccin's palette. tests/theme/apps.nix asserts what the theme module sets
# once the switch is on (the cursor, the accent folders, qt6ct's style and
# palette); tests/desktop/apps.nix asserts that the switch is on on a host with
# this module (gtk, qt, the qtct platform theme, the GTK theme, the icon theme in
# dconf, the dconf service). The variables that point Qt at qt6ct
# (QT_QPA_PLATFORMTHEME, with QT_PLUGIN_PATH and QML2_IMPORT_PATH) and the
# cursor's (XCURSOR_THEME, XCURSOR_SIZE) are home-manager session variables, in
# /etc/profiles/per-user/USER/etc/profile.d/hm-session-vars.sh. They reach
# systemd units, not what Sway starts, so the Sway session has to source that
# file whole before it execs Sway (Task 3.2a), and Sway's own cursor needs
# `seat * xcursor_theme` in its configuration.
#
# --- Exceptions to the style (docs/style.md, rule 9) -------------------------
# These applications cannot be made to follow it, or only partly. None was seen
# on screen yet; Task 3.7 judges them on huginn.
#   Obsidian          Electron, on purpose: it holds the vault. Its look is the
#                     vault's own setting (a community theme), which ravnix
#                     must not write into the synced vault.
#   Bitwarden         Electron with a theme setting of its own (light, dark or
#                     system) and no way to load a palette. It follows the
#                     system's dark preference at best, and keeps its own blue
#                     and its rounded controls.
#   OnlyOffice        Qt and CEF with a bundled Qt that has no Wayland plugin:
#                     it runs through XWayland, takes no qt6ct palette, and
#                     draws its own interface.
#   Steam             draws its own skin; Big Picture and the store follow Valve.
#   Packet Tracer     a Qt application with its own look (and its own Qt).
#   Bazecor           Electron, light/dark/system only. The keyboard's LEDs are
#                     the part that can follow the palette (dygma-catppuccin-leds).
#   Handy             a WebKit interface of its own, with a tray icon.
#   Nextcloud client  Qt: the widgets follow the qt6ct palette, but the tray and
#                     status icons are Nextcloud's own colors and the dialogs
#                     use its blue; it offers no setting for either.
#   Blanket           libadwaita: follows the GTK theme's colors, and draws its
#                     own rounded corners (the same exception as in the theme
#                     module).
#   Prism Launcher    Qt: follows the qt6ct palette; the instance icons and the
#                     news art are the games' own.
#   LocalSend         Flutter: draws its own interface, follows only the
#                     light/dark preference.
#   nmtui             newt's own color scheme (NEWT_COLORS below maps it onto the
#                     terminal's palette, so it carries the Catppuccin colors
#                     but keeps newt's boxes). Its background is palette slot 0
#                     (Surface1), not Base. Open for Task 3.7: slang may take a
#                     `default` color, which would give Text on Base.
#   Helium DevTools   in the theme in dark mode only; light mode stays stock.
#                     Three legacy tokens stay translucent, as the stock ones
#                     are: --color-background-opacity-50 and -80 and
#                     --app-color-strokestyle, which DevTools draws over its
#                     own Network, Performance and Profiler canvases, so an
#                     opaque value would hide the data beneath.
# Themed by catppuccin/nix in the accent: yazi, mpv. Generated from the roles:
# MangoHud, the Helium theme, Helium's DevTools. wiremix and bluetui use the terminal's palette.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  inherit (config.ravnix) apps theme;
  unfree = import ../../lib/unfree.nix { inherit lib; };

  # Read-only pkgs (nixos/modules/misc/nixpkgs/read-only.nix, as a NixOS VM
  # test node has it) declares nixpkgs.config as an option that no module may
  # define, and says so by the file that declares it. The probe asks for that
  # file and no other, as nixosModules.common does for the overlay, so a rename
  # upstream shows as the error of defining the option (tests/desktop/vm-node.nix),
  # not as unfree names that go missing quietly.
  readOnlyPkgs = lib.any (lib.hasSuffix "/misc/nixpkgs/read-only.nix") (
    map toString options.nixpkgs.config.declarations
  );
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
  # The Catppuccin theme of the browser, in the roles: the strip that frames the
  # work (the frame, the address bar and the buttons) is Mantle (style rule 1),
  # the toolbar Base, and the accent is on the icons and the address.
  heliumTheme = builtins.toJSON {
    manifest_version = 3;
    name = "Ravnix";
    description = "Catppuccin Mocha in the accent of ravnix";
    version = "1.0.0";
    theme.colors = lib.mapAttrs (_: rgb) {
      frame = roles.dock;
      frame_inactive = roles.dock;
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
      omnibox_background = roles.dock;
      ntp_background = roles.canvas;
      ntp_link = roles.accent;
      ntp_text = roles.text;
      button_background = roles.dock;
    };
  };

  # Helium's DevTools in the theme (packages/helium-devtools-frontend): the
  # wrapper of the Helium on the PATH passes it, so helium.desktop and every
  # web app (webapps.nix runs `helium`) open DevTools in the roles and the
  # accent. The Chrome DevTools MCP server's headless Helium is
  # pkgs.ravnix.helium itself and keeps the stock DevTools.
  devtoolsFrontend = pkgs.ravnix.helium-devtools-frontend.override {
    theme = { inherit (theme) palette roles font; };
  };

  # MangoHud wants colors without the #.
  bare = lib.removePrefix "#";
in
{
  # The unfree packages of this module, allowed by name and nothing else
  # (lib/unfree.nix). steam-unwrapped is Steam's download. Packet Tracer's names
  # are allowed for a host that installs it (the .deb is its download, which
  # nixpkgs asks the store for by name), and widevine-cdm, the DRM library of
  # Helium, for a host that sets ravnix.apps.widevine: nothing unfree and not
  # redistributable is forced on every laptop. A host with a read-only pkgs (a
  # VM test node) takes no nixpkgs.config from a module; whoever hands it the
  # pkgs allows the same names, with `unfree.predicate` of lib/unfree.nix.
  nixpkgs.config = lib.mkIf (!readOnlyPkgs) {
    allowUnfreePackages = unfree.allowed apps;
  };

  # The dconf service, which home-manager's dconf settings (the GTK theme for
  # libadwaita, see the header) go through.
  programs.dconf.enable = lib.mkDefault true;

  # No Flatpak at all on NixOS.
  services.flatpak.enable = lib.mkDefault false;

  environment.systemPackages = [
    (pkgs.ravnix.helium.override {
      widevineCdm = if apps.widevine then pkgs.widevine-cdm else null;
      inherit devtoolsFrontend;
    })
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
    # the 16 ANSI slots, which ghostty maps onto Catppuccin Mocha (the theme
    # module's palette). black is slot 0, Surface1, so the background is that
    # and not Base: newt is given palette slots. slang, which draws it, may know
    # a `default` color name (root=default,default would then be Text on Base);
    # that is to be tried on screen in Task 3.7, not guessed here. lightgray
    # is slot 7, Subtext1, the nearest slot to Text (white is slot 15, which is
    # Subtext0, and dimmer); gray is slot 8, Surface2; brightmagenta is slot 13,
    # the accent. Not seen on screen.
    NEWT_COLORS = lib.concatStringsSep " " [
      "root=lightgray,black"
      "window=lightgray,black"
      "border=brightmagenta,black"
      "title=brightmagenta,black"
      "button=black,brightmagenta"
      "actbutton=black,brightmagenta"
      "compactbutton=lightgray,black"
      "checkbox=lightgray,black"
      "actcheckbox=black,brightmagenta"
      "entry=lightgray,black"
      "disentry=gray,black"
      "label=lightgray,black"
      "listbox=lightgray,black"
      "actlistbox=black,brightmagenta"
      "sellistbox=lightgray,black"
      "actsellistbox=black,brightmagenta"
      "textbox=lightgray,black"
      "acttextbox=black,brightmagenta"
      "helpline=lightgray,black"
      "roottext=lightgray,black"
      "emptyscale=lightgray,black"
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
      # The theme module's GTK and Qt part applies where these are on.
      gtk.enable = true;
      qt.enable = true;

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
          # Each window its own process (see above), also without the
          # service: with ghostty's default a second `ghostty` hands its
          # window to the one that runs, which drops its command line and
          # its environment (`env NO_MUX=1`, `-e`), and opened no window at
          # all in tests/glue/reconnect.nix.
          gtk-single-instance = false;
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
          engine_color = bare roles.label;
          fps = true;
          fps_color_change = [
            (bare palette.red)
            (bare palette.yellow)
            (bare palette.green)
          ];
          wine = true;
          wine_color = bare roles.label;
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
