# GTK and Qt applications: Catppuccin Mocha in the accent, JetBrainsMono Nerd
# Font 11 (the style spec's UI font), Papirus-Dark with folders in the accent,
# the Catppuccin cursor in the accent at 24 px, and no animation. Qt goes
# through qt6ct with the Fusion style and Catppuccin's palette, and through a
# KDE color scheme in kdeglobals so Kirigami applications follow.
#
# It applies where the host turns gtk or qt on (gtk.enable, qt.enable); the
# desktop module does, and a host that draws nothing gets none of it.
#
# Exceptions (docs/style.md, rule 9), to be judged against a screenshot on
# huginn (Task 3.7): libadwaita draws its own corners and gtk-4.0/gtk.css only
# imports the Catppuccin GTK theme; and qt6ct as nixpkgs builds it reads
# palettes in its own .conf format, not KDE's .colors, so Qt widgets get
# Catppuccin's qt5ct palette and KDE applications get kdeglobals.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.theme;
  inherit (cfg)
    accent
    roles
    palette
    font
    fontSize
    ;

  fontPackage = pkgs.nerd-fonts.jetbrains-mono;
  uiFont = "${font} ${toString fontSize.ui}";
  # qt6ct reads a font as a quoted "family,size" string.
  qtFont = ''"${font},${toString fontSize.ui}"'';
  iconTheme = "Papirus-Dark";

  gtkTheme = {
    name = "catppuccin-mocha-${accent}-standard";
    package = pkgs.catppuccin-gtk.override {
      accents = [ accent ];
      variant = "mocha";
      size = "standard";
    };
  };

  qtctSettings = {
    Appearance = {
      style = "Fusion";
      icon_theme = iconTheme;
      standard_dialogs = "default";
    };
    Fonts = {
      general = qtFont;
      fixed = qtFont;
    };
  };

  # A KDE color scheme, as kdeglobals and a .colors file hold it: the same
  # groups as catppuccin/kde's Mocha, with the accent where that has Mauve.
  rgb =
    hex:
    let
      h = lib.removePrefix "#" hex;
      byte = i: toString (lib.fromHexString (builtins.substring i 2 h));
    in
    "${byte 0}, ${byte 2}, ${byte 4}";

  group =
    name: attrs:
    "[${name}]\n" + lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${v}\n") attrs) + "\n";

  colorSet =
    {
      alternate,
      normal,
      foreground ? { },
    }:
    {
      BackgroundAlternate = rgb alternate;
      BackgroundNormal = rgb normal;
      DecorationFocus = rgb roles.accent;
      DecorationHover = rgb roles.selected;
      ForegroundActive = rgb palette.peach;
      ForegroundInactive = rgb roles.secondary;
      ForegroundLink = rgb roles.accent;
      ForegroundNegative = rgb palette.red;
      ForegroundNeutral = rgb palette.yellow;
      ForegroundNormal = rgb roles.text;
      ForegroundPositive = rgb palette.green;
      ForegroundVisited = rgb roles.accent;
    }
    // foreground;

  frame = {
    alternate = roles.deepest;
    normal = roles.dock;
  };

  schemeName = "CatppuccinMocha${lib.toSentenceCase accent}";
  kdeglobals =
    group "ColorEffects:Disabled" {
      Color = rgb roles.canvas;
      ColorAmount = "0.3";
      ColorEffect = "2";
      ContrastAmount = "0.1";
      ContrastEffect = "0";
      IntensityAmount = "-1";
      IntensityEffect = "0";
    }
    + group "ColorEffects:Inactive" {
      ChangeSelectionColor = "false";
      Color = rgb roles.canvas;
      ColorAmount = "0.5";
      ColorEffect = "3";
      ContrastAmount = "0";
      ContrastEffect = "0";
      Enable = "true";
      IntensityAmount = "0";
      IntensityEffect = "0";
    }
    + group "Colors:Button" (colorSet {
      alternate = roles.accent;
      normal = roles.wash;
    })
    + group "Colors:Complementary" (colorSet frame)
    + group "Colors:Header" (colorSet frame)
    + group "Colors:Selection" (colorSet {
      alternate = roles.accent;
      normal = roles.accent;
      # Text on an accent fill is always Crust.
      foreground = lib.genAttrs [
        "ForegroundActive"
        "ForegroundInactive"
        "ForegroundLink"
        "ForegroundNegative"
        "ForegroundNeutral"
        "ForegroundNormal"
        "ForegroundPositive"
        "ForegroundVisited"
      ] (_: rgb roles.deepest);
    })
    + group "Colors:Tooltip" (colorSet {
      alternate = roles.deepest;
      normal = roles.canvas;
    })
    + group "Colors:View" (colorSet {
      alternate = roles.dock;
      normal = roles.canvas;
    })
    + group "Colors:Window" (colorSet frame)
    + group "General" {
      ColorScheme = schemeName;
      Name = "Catppuccin Mocha ${lib.toSentenceCase accent}";
      accentActiveTitlebar = "false";
      shadeSortColumn = "true";
    }
    + group "Icons" { Theme = iconTheme; }
    + group "KDE" { contrast = "4"; }
    + group "WM" {
      activeBackground = rgb roles.canvas;
      activeBlend = rgb roles.text;
      activeForeground = rgb roles.text;
      inactiveBackground = rgb roles.deepest;
      inactiveBlend = rgb roles.secondary;
      inactiveForeground = rgb roles.secondary;
    };
in
{
  config = lib.mkMerge [
    # What GTK and Qt share: the cursor and the Papirus icons.
    (lib.mkIf (config.gtk.enable || config.qt.enable) {
      catppuccin = {
        cursors.enable = true;
        gtk.icon.enable = true;
      };
      home.pointerCursor = {
        enable = true;
        size = 24;
        gtk.enable = true;
        x11.enable = true;
      };
    })

    (lib.mkIf config.gtk.enable {
      gtk = {
        font = {
          name = font;
          size = fontSize.ui;
          package = fontPackage;
        };
        theme = gtkTheme;
        # GTK 4 and libadwaita take the theme through gtk.css; say so for
        # every stateVersion.
        gtk4.theme = gtkTheme;
        colorScheme = "dark";
        gtk3.extraConfig.gtk-enable-animations = false;
        gtk4.extraConfig.gtk-enable-animations = false;
      };

      # libadwaita reads the interface settings, not settings.ini. The cursor
      # keys are home-manager's: its gtk module writes cursor-theme and
      # cursor-size from home.pointerCursor, so a second, fixed value here
      # would refuse every host that changes the cursor.
      dconf.settings."org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
        gtk-theme = gtkTheme.name;
        icon-theme = iconTheme;
        font-name = uiFont;
        monospace-font-name = uiFont;
        document-font-name = uiFont;
        enable-animations = false;
      };
    })

    (lib.mkIf config.qt.enable {
      catppuccin.qt5ct.enable = true;
      qt = {
        platformTheme.name = "qtct";
        qt5ctSettings = qtctSettings;
        qt6ctSettings = qtctSettings;
      };
      home.packages = [
        fontPackage
        config.gtk.iconTheme.package
      ];
      xdg.configFile."kdeglobals".text = kdeglobals;
    })
  ];
}
