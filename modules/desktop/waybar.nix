# Waybar, the bar of the Sway session: three layouts (full, focus, none), the
# raven mark at the left end, the modules that show the laptop (battery, power
# draw, peripherals, network, volume, load and temperatures), and the scripts
# behind them. NixOS provides
# the package, the scripts and the daemons the modules talk to; home-manager
# writes the four files of ~/.config/waybar:
#
#   config.jsonc        the full bar: layout and geometry
#   config-focus.jsonc  the focus bar: no workspaces, no right cluster
#   modules.jsonc       what each module does, shared by both
#   style.css           how it looks, from the theme
#
# Both bars are 32 px high with a spacing of 2, so the bar has the same height
# in every mode and cycling it (Super+Ctrl+Space, waybar-mode) never moves a
# window. The colors are the theme's: style.css gets one @define-color per
# palette color and for the accent, and the Pango spans of modules.jsonc and
# the waybar-* scripts get the accent from the same option, so a new accent
# reaches all three.
#
# SEAMS
#   The calendar a click on the clock opens lives on the server: a floating
#   terminal runs `khal interactive` there over ssh, to ravnix.server.sshTarget.
#   The tooltip shows an agenda when khal is on the PATH and a month otherwise.
#
# WHAT THIS MODULE TURNS ON, because a module of the bar shows nothing without
# it (each with mkDefault, so that a hardware or energy module sets its own):
#   NetworkManager        the network click (Wi-Fi menu, nmtui)
#   power-profiles-daemon the profile switch
#   Bluetooth             the bluetooth module and bluetui
#   PipeWire              the volume module and the volume keys (sway.nix)
#
# EXCEPTIONS (docs/style.md, rule 9). Four parts of the bar have no fixed
# width, or no fixed place. Three are lists that grow: the workspace strip (a
# workspace above ten adds a button), the mode pill (it is only there while a
# mode is on) and the tray (16 px per icon). The fourth is custom/peripherals,
# the battery of a mouse, a keyboard or a trackpad: it is there only while one
# of them is low or charging, and a bar that kept its cell all day for it would
# spend 80 px on a blank that shows a few times a month. When it shows it has
# its floor, so it appears at one fixed width, and the modules after it in the
# left group (power draw, profile, workspaces) move right by that width, once,
# as the tray's neighbours do for a new icon. Everything else
# that changes value has a floor (min-width) as wide as its widest value; see
# the table in style.css, and tests/desktop/sway.nix, which lays every floor
# out with GTK and fails when a module's width depends on its value.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.ravnix.theme)
    palette
    roles
    font
    fontSize
    ;
  helpers = import ./sway/lib.nix { inherit lib pkgs; };

  # The accent and the state hues, as the Pango spans of the modules and the
  # scripts write them. Pango takes #rrggbb.
  colorTokens = {
    accent = roles.accent;
    inherit (palette) red;
    overlay0 = palette.overlay0;
  };

  # ── the scripts ─────────────────────────────────────────────────────────────
  # A script finds the tools of other modules by name on the PATH of the
  # session (energy, charge-mode, nord, magic-trackpad-battery, khal,
  # nvidia-smi) and is silent when one is missing.
  bin = ./waybar/bin;
  bash =
    name: runtimeInputs: tokens:
    helpers.bash {
      inherit name runtimeInputs tokens;
      src = bin + "/${name}";
    };
  scripts = with pkgs; {
    waybar-battery = bash "waybar-battery" [ coreutils gawk jq ] { inherit (colorTokens) accent; };
    waybar-clock = bash "waybar-clock" [ coreutils findutils jq procps util-linux ] { };
    waybar-gpu = bash "waybar-gpu" [ coreutils findutils jq ] { inherit (colorTokens) accent; };
    waybar-gputemp = bash "waybar-gputemp" [ coreutils jq ] { inherit (colorTokens) accent; };
    waybar-launch = bash "waybar-launch" [ coreutils procps waybar ] { };
    waybar-mode = bash "waybar-mode" [ coreutils ] { };
    waybar-netmenu = bash "waybar-netmenu" [ coreutils fuzzel gawk gnugrep libnotify networkmanager ] { };
    waybar-peripherals = bash "waybar-peripherals" [ coreutils ] { };
    waybar-powerdraw = bash "waybar-powerdraw" [ coreutils gawk jq ] { inherit (colorTokens) accent; };
  };

  # ── the widths ──────────────────────────────────────────────────────────────
  # min-width in px, the content box of each module (padding of 4 px a side
  # comes on top). Each is the width of the module's widest value in the
  # bar's font at 14 px, which is 8 px a character: measured by laying the
  # modules out with GTK on this Waybar and this font (tests/desktop/helpers/
  # measure-widths.py), and checked again by tests/desktop/sway.nix. The
  # widest values:
  #   percent      "󰻠 100%"               6 characters (battery, CPU, memory, GPU)
  #   peripherals  "󰂃 15% (9)"            9
  #   powerdraw    "󱐋 123W+dGPU"          11
  #   window       the 28 characters of its max-length
  #   clock        "W36 30. September 2026"  22
  #   network      "󰖩 ↑ 1023.9MB/s ↓ 1023.9MB/s"  27
  #   volume       "󰕾 100%"               6
  #   temperature  "󰔏 100°C"              7
  #   icon         one glyph, 16 px so that the cell is a comfortable target
  characters = n: n * 8;
  widths = {
    percent = characters 6;
    peripherals = characters 9;
    powerdraw = characters 11;
    window = characters 28;
    clock = characters 22;
    network = characters 27;
    volume = characters 6;
    temperature = characters 7;
    icon = 16;
    bluetooth = 16;
    profile = 16;
  };

  defineColors = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: hex: "@define-color ${name} ${hex};") palette
    ++ [ "@define-color accent ${roles.accent};" ]
  );

  khalCommand = "ghostty-float -e ssh -t ${config.ravnix.server.sshTarget} khal interactive";

  # The raven mark at the left end of the bar: the one-color mark, whose fills
  # are Text, with Text made the accent. Made here and not in a build step, so
  # the bar's mark follows the accent like the spans and the stylesheet.
  markSvg = builtins.readFile ../../assets/ravnix-mark.svg;
  mark =
    if lib.hasInfix palette.text markSvg then
      pkgs.writeText "ravnix-mark-accent.svg" (
        builtins.replaceStrings [ palette.text ] [ roles.accent ] markSvg
      )
    else
      throw "modules/desktop/waybar.nix: assets/ravnix-mark.svg has no fill in Text (${palette.text}) to make the accent";

  style = helpers.fill (
    {
      inherit defineColors font;
      fontSize = toString fontSize.bar;
    }
    // lib.mapAttrs' (n: v: lib.nameValuePair "w.${n}" (toString v)) widths
  ) (builtins.readFile ./waybar/style.css);

  modules = helpers.fill (colorTokens // { inherit khalCommand; mark = "${mark}"; }) (
    builtins.readFile ./waybar/modules.jsonc
  );
in
{
  assertions = [
    {
      # The floors were measured at this size; a bigger or smaller font needs
      # them measured again.
      assertion = fontSize.bar == 14;
      message = "modules/desktop/waybar.nix: the Waybar min-width floors are measured for a bar font of 14 px, and ravnix.theme.fontSize.bar is ${toString fontSize.bar}. Measure them again with tests/desktop/helpers/measure-widths.py and update `widths`.";
    }
  ];

  environment.systemPackages = [ pkgs.waybar ] ++ lib.attrValues scripts;

  # The daemons the modules talk to.
  networking.networkmanager.enable = lib.mkDefault true;
  services.power-profiles-daemon.enable = lib.mkDefault true;
  hardware.bluetooth.enable = lib.mkDefault true;
  services.pipewire = {
    enable = lib.mkDefault true;
    alsa.enable = lib.mkDefault true;
    pulse.enable = lib.mkDefault true;
  };
  security.rtkit.enable = lib.mkDefault true;
  # PipeWire's X11 bell module connects to the display it finds in its
  # environment, and PipeWire 1.6 segfaults when that display goes away. Sway
  # starts Xwayland on demand and ends it ten seconds after the last X11
  # window closes, and imports DISPLAY into the user manager at login, so
  # without this PipeWire crashes (and the portal that records the screen with
  # it) each time the last X11 application closes. The only thing lost is the
  # sound of the X11 bell.
  systemd.user.services.pipewire.environment.DISPLAY = lib.mkIf config.services.pipewire.enable "";

  home-manager.sharedModules = [
    {
      xdg.configFile = {
        "waybar/config.jsonc".source = ./waybar/config.jsonc;
        "waybar/config-focus.jsonc".source = ./waybar/config-focus.jsonc;
        "waybar/modules.jsonc".text = modules;
        "waybar/style.css".text = style;
      };
    }
  ];
}
