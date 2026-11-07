# What the theme module writes into the applications it styles: the ghostty,
# fuzzel and dunst configs (built and read as files), and the GTK and Qt
# settings. The colors in the files are the palette's and nothing else, the
# accent spots follow the accent option, and the rows of the style spec's
# table that belong to the theme module hold: dunst frame 1 px, fuzzel opaque
# with the Surface1 selection, ghostty selection text in Crust, JetBrainsMono
# Nerd Font 11 in GTK and Qt.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  hm = import ./helpers/hm.nix {
    inherit
      self
      inputs
      pkgs
      lib
      ;
  };

  appsOf =
    accent:
    (hm [
      { ravnix.theme.accent = accent; }
      {
        programs.ghostty.enable = true;
        programs.fuzzel.enable = true;
        services.dunst.enable = true;
        gtk.enable = true;
        qt.enable = true;
      }
    ]).config;

  mauve = appsOf "mauve";
  teal = appsOf "teal";
  palette = mauve.ravnix.theme.palette;

  # The generated files, by name.
  filesOf = c: {
    ghostty = c.xdg.configFile."ghostty/config".source;
    fuzzel = c.xdg.configFile."fuzzel/fuzzel.ini".source;
    dunst = c.xdg.configFile."dunst/dunstrc".source;
  };

  # Lines a file must hold, as `<file> <line>` pairs, for an accent given by
  # its hex color (with and without the #).
  expectedLines =
    accent:
    let
      bare = lib.removePrefix "#" accent;
    in
    {
      ghostty = [
        "font-family = JetBrainsMono Nerd Font"
        "font-size = 9"
        "window-padding-x = 14"
        "window-padding-y = 14"
        "window-decoration = false"
        "cursor-style = block"
        "cursor-style-blink = false"
        "background = ${palette.base}"
        "foreground = ${palette.text}"
        "cursor-color = ${accent}"
        "cursor-text = ${palette.crust}"
        "selection-background = ${accent}"
        # A row of the style spec's table: Crust, not Text.
        "selection-foreground = ${palette.crust}"
        "palette = 0=${palette.surface1}"
        "palette = 1=${palette.red}"
        "palette = 2=${palette.green}"
        "palette = 3=${palette.yellow}"
        "palette = 4=${palette.blue}"
        "palette = 5=${palette.pink}"
        "palette = 6=${palette.teal}"
        "palette = 7=${palette.subtext1}"
        "palette = 8=${palette.surface2}"
        "palette = 9=${palette.red}"
        "palette = 10=${palette.green}"
        "palette = 11=${palette.yellow}"
        "palette = 12=${palette.blue}"
        "palette = 13=${accent}"
        "palette = 14=${palette.teal}"
        "palette = 15=${palette.subtext0}"
      ];
      fuzzel = [
        "font=JetBrainsMono Nerd Font:size=11"
        "width=50"
        "icon-theme=Papirus-Dark"
        "[border]"
        "width=1"
        "radius=0"
        "[colors]"
        # Rows of the style spec's table: opaque, and Surface1 for the selection.
        "background=${lib.removePrefix "#" palette.base}ff"
        "text=${lib.removePrefix "#" palette.text}ff"
        "prompt=${lib.removePrefix "#" palette.subtext1}ff"
        "placeholder=${lib.removePrefix "#" palette.overlay1}ff"
        "input=${lib.removePrefix "#" palette.text}ff"
        "match=${bare}ff"
        "selection=${lib.removePrefix "#" palette.surface1}ff"
        "selection-text=${lib.removePrefix "#" palette.text}ff"
        "selection-match=${bare}ff"
        "counter=${lib.removePrefix "#" palette.overlay1}ff"
        "border=${bare}ff"
      ];
      # home-manager writes dunst's ini as key="value", integers bare.
      dunst = [
        "[global]"
        ''font="JetBrainsMono Nerd Font 9"''
        # A row of the style spec's table: 1 px, not 2.
        "frame_width=1"
        ''frame_color="${accent}"''
        ''separator_color="frame"''
        ''highlight="${accent}"''
        "[urgency_low]"
        "[urgency_normal]"
        "[urgency_critical]"
        ''background="${palette.base}"''
        ''foreground="${palette.text}"''
        # A critical notification is Peach whatever the accent is.
        ''frame_color="${palette.peach}"''
      ];
    };

  checkFiles =
    name: c: accent:
    let
      files = filesOf c;
    in
    lib.concatStrings (
      lib.mapAttrsToList (
        app: lines:
        lib.concatMapStrings (line: ''
          grep -qxF ${lib.escapeShellArg line} ${files.${app}} || {
            echo ${lib.escapeShellArg "${name}: ${app} lacks the line: ${line}"} >&2
            status=1
          }
        '') lines
      ) (expectedLines accent)
    );

  # The Qt and GTK settings, read from the evaluated configuration.
  fontName = "JetBrainsMono Nerd Font";
  evalFailures =
    lib.concatMap
      (
        t:
        let
          c = t.config;
          accent = t.accent;
          gtk3 = c.xdg.configFile."gtk-3.0/settings.ini".text;
          gtk4 = c.xdg.configFile."gtk-4.0/settings.ini".text;
          kde = c.xdg.configFile."kdeglobals".text;
          dconf = c.dconf.settings."org/gnome/desktop/interface";
          rgb = lib.concatStringsSep ", " (
            map (i: toString (lib.fromHexString (builtins.substring i 2 t.hex))) [
              0
              2
              4
            ]
          );
          qt6 = c.qt.qt6ctSettings;
          qt5 = c.qt.qt5ctSettings;
        in
        lib.optional (
          c.gtk.font.name != fontName || c.gtk.font.size != 11
        ) "${accent}: the GTK font is not ${fontName} 11"
        ++ lib.optional (
          c.gtk.theme.name != "catppuccin-mocha-${accent}-standard"
        ) "${accent}: the GTK theme is ${c.gtk.theme.name}"
        ++ lib.optional (
          c.gtk.gtk4.theme.name != c.gtk.theme.name
        ) "${accent}: GTK 4 does not use the GTK theme"
        ++ lib.optional (
          c.gtk.iconTheme.name != "Papirus-Dark"
        ) "${accent}: the icon theme is ${c.gtk.iconTheme.name}"
        ++ lib.optional (
          c.gtk.cursorTheme.name != "catppuccin-mocha-${accent}-cursors" || c.gtk.cursorTheme.size != 24
        ) "${accent}: the GTK cursor is not catppuccin-mocha-${accent}-cursors at 24"
        ++ lib.optional (
          c.home.pointerCursor.name != "catppuccin-mocha-${accent}-cursors" || c.home.pointerCursor.size != 24
        ) "${accent}: the pointer cursor is not catppuccin-mocha-${accent}-cursors at 24"
        ++ lib.optional (c.gtk.colorScheme != "dark") "${accent}: GTK is not dark"
        ++
          lib.concatMap
            (
              settings:
              lib.optional (
                !lib.hasInfix "gtk-font-name=${fontName} 11" settings
              ) "${accent}: a GTK settings.ini lacks the font"
              ++ lib.optional (
                !lib.hasInfix "gtk-enable-animations=false" settings
              ) "${accent}: a GTK settings.ini allows animations"
            )
            [
              gtk3
              gtk4
            ]
        ++ lib.optional (
          dconf.font-name != "${fontName} 11"
          || dconf.monospace-font-name != "${fontName} 11"
          || dconf.color-scheme != "prefer-dark"
          || dconf.icon-theme != "Papirus-Dark"
          || dconf.gtk-theme != c.gtk.theme.name
          || dconf.enable-animations != false
        ) "${accent}: dconf does not carry the font, the dark scheme, the themes and no animations"
        ++ lib.optional (
          c.qt.platformTheme.name != "qtct"
        ) "${accent}: Qt does not use qt6ct (qt.platformTheme.name is ${toString c.qt.platformTheme.name})"
        ++
          lib.concatMap
            (
              s:
              lib.optional (s.Appearance.style != "Fusion") "${accent}: a qtct config does not use Fusion"
              ++ lib.optional (!s.Appearance.custom_palette) "${accent}: a qtct config has no custom palette"
              ++ lib.optional (
                !lib.hasSuffix "/catppuccin-mocha-${accent}.conf" s.Appearance.color_scheme_path
              ) "${accent}: a qtct palette is ${s.Appearance.color_scheme_path}"
              ++ lib.optional (
                s.Appearance.icon_theme != "Papirus-Dark"
              ) "${accent}: a qtct config has another icon theme"
              ++ lib.optional (
                s.Fonts.general != ''"${fontName},11"'' || s.Fonts.fixed != ''"${fontName},11"''
              ) "${accent}: a qtct config does not use ${fontName} 11"
            )
            [
              qt6
              qt5
            ]
        ++ lib.optional (
          !lib.hasInfix "[General]\nColorScheme=CatppuccinMocha${t.name}\n" kde
        ) "${accent}: kdeglobals names no scheme CatppuccinMocha${t.name}"
        ++ lib.optional (
          !lib.hasInfix "[Colors:Selection]\nBackgroundAlternate=${rgb}\nBackgroundNormal=${rgb}\n" kde
        ) "${accent}: the Selection colors of kdeglobals are not ${rgb}"
        ++ lib.optional (
          !lib.hasInfix "[Colors:View]\nBackgroundAlternate=24, 24, 37\nBackgroundNormal=30, 30, 46\nDecorationFocus=${rgb}\n" kde
        ) "${accent}: the View colors of kdeglobals are wrong"
        ++ lib.optional (
          !lib.hasInfix "[Icons]\nTheme=Papirus-Dark\n" kde
        ) "${accent}: kdeglobals has another icon theme"
      )
      [
        {
          config = mauve;
          accent = "mauve";
          name = "Mauve";
          hex = "cba6f7";
        }
        {
          config = teal;
          accent = "teal";
          name = "Teal";
          hex = "94e2d5";
        }
      ];

  # Without graphical apps nothing is pulled in: a server evaluates the theme
  # for its roles and gets no font, theme, cursor or Qt package.
  headless = (hm [ ]).config;
  themed = lib.filter (
    p: builtins.match ".*(nerd-fonts|catppuccin|papirus|qt[56]ct).*" (p.name or "") != null
  ) headless.home.packages;
  headlessFailures =
    map (p: "a headless configuration installs ${p.name}") themed
    ++ lib.optional (
      headless.gtk.enable || headless.qt.enable
    ) "a headless configuration turns GTK or Qt on"
    ++ lib.optional (headless.fonts.fontconfig.enable) "a headless configuration turns fontconfig on";
in
pkgs.runCommand "theme-apps"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.ripgrep
    ];
    allowed = lib.concatStringsSep "\n" (lib.attrValues palette) + "\n";
    passAsFile = [ "allowed" ];
  }
  ''
    status=0
    ${lib.concatMapStrings (e: "echo ${lib.escapeShellArg e} >&2; status=1\n") (
      evalFailures ++ headlessFailures
    )}
    ${checkFiles "mauve" mauve palette.mauve}
    ${checkFiles "teal" teal palette.teal}

    # No color outside the palette, and no leftover of another accent.
    scan() {
      name="$1"; shift
      { grep -ohiE '#[0-9a-f]+' "$@"; } > hex.txt || true
      while read -r token; do
        grep -qixF "$token" "$allowedPath" || {
          echo "$name: $token is not a color of the palette" >&2
          status=1
        }
      done < <(sort -u hex.txt)
      # fuzzel writes colors as rrggbbaa without a #.
      { grep -ohE '^[a-z-]+=[0-9a-f]{8}$' "$@"; } | cut -d= -f2 | sort -u > bare.txt || true
      while read -r token; do
        grep -qixF "#''${token:0:6}" "$allowedPath" || {
          echo "$name: $token is not a color of the palette" >&2
          status=1
        }
        [ "''${token:6:2}" = ff ] || {
          echo "$name: $token is not fully opaque" >&2
          status=1
        }
      done < bare.txt
    }
    scan mauve ${lib.concatStringsSep " " (lib.attrValues (filesOf mauve))}
    scan teal ${lib.concatStringsSep " " (lib.attrValues (filesOf teal))}
    if grep -qi ${lib.removePrefix "#" palette.mauve} ${lib.concatStringsSep " " (lib.attrValues (filesOf teal))}; then
      echo "teal: a config still holds Mauve" >&2
      status=1
    fi

    # The generated files pass the style check. Hex colors are what they
    # are made of, so they lie where the check allows them; the radius,
    # opacity and motion rules judge them all the same.
    mkdir -p gen/modules/theme
    cp ${(filesOf mauve).ghostty} gen/modules/theme/ghostty-config
    cp ${(filesOf mauve).fuzzel} gen/modules/theme/fuzzel.ini
    cp ${(filesOf mauve).dunst} gen/modules/theme/dunstrc
    cp ${
      pkgs.writeText "kdeglobals" mauve.xdg.configFile."kdeglobals".text
    } gen/modules/theme/kdeglobals
    (cd gen && bash ${self}/scripts/check-style.sh .) || status=1

    [ "$status" = 0 ]
    touch $out
  ''
