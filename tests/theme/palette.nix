# The theme module's data: the Mocha palette, the roles that name its rungs,
# the accent and what it refuses, the line widths, the font, and the shared
# Mermaid theme of the diagrams. The colors are written out here on purpose:
# this is the test that pins them.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
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
  themeOf = modules: (hm modules).config.ravnix.theme;
  default = themeOf [ ];
  accentOf = name: themeOf [ { ravnix.theme.accent = name; } ];

  # Whether reading every theme option of a configuration fails.
  fails = modules: !(builtins.tryEval (builtins.deepSeq (themeOf modules) true)).success;

  accents = [
    "mauve"
    "lavender"
    "pink"
    "flamingo"
    "rosewater"
    "teal"
    "sky"
    "sapphire"
  ];
  stateHues = [
    "red"
    "maroon"
    "peach"
    "yellow"
    "green"
    "blue"
  ];

  # The style spec's role table: role -> Catppuccin name.
  roleNames = {
    deepest = "crust";
    dock = "mantle";
    canvas = "base";
    wash = "surface0";
    selected = "surface1";
    line = "surface2";
    muted = "overlay0";
    placeholder = "overlay1";
    secondary = "subtext0";
    label = "subtext1";
    text = "text";
  };

  # The NixOS side: the same options, the font as the monospace default, and
  # the font package only with a desktop.
  nixosOf =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.theme
        { system.stateVersion = "26.05"; }
      ]
      ++ modules;
    }).config;
  server = nixosOf [ { ravnix.theme.accent = "teal"; } ];
  desktop = nixosOf [ { programs.sway.enable = true; } ];
  hasFont = c: lib.any (p: lib.hasPrefix "nerd-fonts-jetbrains-mono" p.name) c.fonts.packages;

  mermaid = builtins.fromJSON (builtins.readFile ../../docs/mermaid-theme.json);
  mermaidInSpec =
    let
      afterInit = lib.elemAt (lib.splitString "%%{init:" (builtins.readFile ../../docs/style.md)) 1;
    in
    builtins.fromJSON (lib.head (lib.splitString "}%%" afterInit));

  failures =
    lib.optional (default.palette.base != "#1e1e2e") "palette.base is ${default.palette.base}"
    ++ lib.optional (default.palette.mauve != "#cba6f7") "palette.mauve is ${default.palette.mauve}"
    ++ lib.optional (default.palette.crust != "#11111b") "palette.crust is ${default.palette.crust}"
    ++ lib.optional (lib.length (lib.attrNames default.palette) != 26) "the palette has no 26 colors"
    ++ lib.optional (lib.any (c: builtins.match "#[0-9a-f]{6}" c == null) (
      lib.attrValues default.palette
    )) "a palette color is not #rrggbb in lower case"
    ++ lib.optional (default.roles.accent != "#cba6f7") "the default accent is ${default.roles.accent}"
    ++ lib.optional (
      (accentOf "teal").roles.accent != "#94e2d5"
    ) "accent teal gives ${(accentOf "teal").roles.accent}"
    ++ lib.optional (
      lib.attrNames default.roles != lib.sort lib.lessThan (lib.attrNames roleNames ++ [ "accent" ])
    ) "the roles are ${toString (lib.attrNames default.roles)}"
    ++ lib.concatLists (
      lib.mapAttrsToList (
        role: name:
        lib.optional (
          default.roles.${role} != default.palette.${name}
        ) "role ${role} is ${default.roles.${role}}, not ${name}"
      ) roleNames
    )
    ++ lib.concatMap (
      name:
      let
        t = accentOf name;
      in
      lib.optional (
        t.roles.accent != t.palette.${name}
      ) "accent ${name} gives ${t.roles.accent}, not ${t.palette.${name}}"
      ++ lib.optional (
        lib.removeAttrs t.roles [ "accent" ] != lib.removeAttrs default.roles [ "accent" ]
      ) "accent ${name} moves a role other than accent"
    ) accents
    ++ map (name: "accent ${name} is accepted; it carries a state") (
      lib.filter (name: !(fails [ { ravnix.theme.accent = name; } ])) (
        stateHues
        ++ [
          "purple"
          ""
          "Mauve"
        ]
      )
    )
    ++ lib.concatMap (
      name:
      let
        description = (hm [ ]).options.ravnix.theme.accent.type.description;
      in
      lib.optional (!(lib.hasInfix ''"${name}"'' description)) "the accent type does not list ${name}"
    ) accents
    ++ map (name: "the accent type lists ${name}, a state hue") (
      lib.filter (
        name: lib.hasInfix ''"${name}"'' (hm [ ]).options.ravnix.theme.accent.type.description
      ) stateHues
    )
    ++ lib.optional (
      !lib.hasInfix "Red" (hm [ ]).options.ravnix.theme.accent.type.description
    ) "the accent type does not say why Red and the other state hues are refused"
    ++ lib.optional (
      default.lineWidth != {
        frame = 1;
        marker = 2;
      }
    ) "lineWidth is not { frame = 1; marker = 2; }"
    ++ lib.optional (default.font != "JetBrainsMono Nerd Font") "the font is ${default.font}"
    ++ lib.optional (
      default.fontSize != {
        terminal = 9;
        launcher = 11;
        bar = 14;
        ui = 11;
      }
    ) "the font sizes are not terminal 9, launcher 11, bar 14, ui 11"
    ++ lib.concatLists (
      lib.mapAttrsToList
        (
          what: value:
          lib.optional (
            !(fails [ { ravnix.theme.${what} = value; } ])
          ) "${what} can be set by the user; it is read-only"
        )
        {
          palette = { };
          roles = { };
          lineWidth = { };
          font = "Other Font";
          fontSize = { };
        }
    )
    ++ lib.optional (
      server.ravnix.theme.roles.accent != "#94e2d5"
    ) "the NixOS module does not take the accent option"
    ++ lib.optional (
      server.ravnix.theme.palette != default.palette || server.ravnix.theme.roles.canvas != "#1e1e2e"
    ) "the NixOS module has another palette"
    ++ lib.optional (
      !lib.elem "JetBrainsMono Nerd Font" server.fonts.fontconfig.defaultFonts.monospace
    ) "the NixOS module does not make the font the monospace default"
    ++ lib.optional (hasFont server) "a NixOS host without a desktop installs the font"
    ++ lib.optional (!hasFont desktop) "a NixOS host with Sway does not install the font"
    ++ lib.optional (
      mermaid != {
        theme = "base";
        themeVariables = {
          background = "#1e1e2e";
          primaryColor = "#313244";
          primaryTextColor = "#cdd6f4";
          primaryBorderColor = "#cba6f7";
          lineColor = "#7f849c";
          secondaryColor = "#181825";
          tertiaryColor = "#181825";
          fontFamily = "JetBrainsMono Nerd Font, ui-monospace, monospace";
        };
      }
    ) "docs/mermaid-theme.json is not the style spec's init block"
    ++ lib.optional (
      mermaid != mermaidInSpec
    ) "docs/mermaid-theme.json and the init block of docs/style.md differ";

  # The palette against Catppuccin's own, so a mistyped digit cannot pass for
  # a color: both sides are built into files and compared.
  upstream = inputs.catppuccin.packages.${system}.palette;
in
pkgs.runCommand "theme-palette" { nativeBuildInputs = [ pkgs.jq ]; } (
  if failures == [ ] then
    ''
      jq -S '.mocha.colors | map_values(.hex)' ${upstream}/palette.json > upstream.json
      echo '${builtins.toJSON default.palette}' | jq -S . > ours.json
      diff upstream.json ours.json
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
