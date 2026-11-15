# lazygit's colors, from the roles, written into lazygit's own config.yml: the
# look of Fedora's hand-set theme, each hex mapped to its role. The
# catppuccin/nix port is off, so no LG_CONFIG_FILE has to reach the program
# through the shell and a lazygit started with a bare environment (sudo, a
# unit, an editor) is themed too. Rendered with the Mauve and the Teal accent,
# the file holds only palette colors and only the focus slots move.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  hm = import ../common/helpers/hm.nix { inherit self inputs pkgs lib; };
  colors = import ./helpers/colors.nix { inherit pkgs lib; };

  configOf = accent: (hm [ { ravnix.theme.accent = lib.mkForce accent; } ]).config;
  mauve = configOf "mauve";
  teal = configOf "teal";
  sky = configOf "sky";
  inherit (mauve.ravnix.theme) palette roles;

  fileOf = c: c.home.file."${c.xdg.configHome}/lazygit/config.yml".source;
  textOf = c: builtins.readFile (fileOf c);
  parsed =
    c:
    builtins.fromJSON (
      builtins.readFile (
        pkgs.runCommand "lazygit-config.json" { nativeBuildInputs = [ pkgs.remarshal ]; } ''
          remarshal -if yaml -of json < ${fileOf c} > $out
        ''
      )
    );
  t = (parsed mauve).gui.theme;
  tt = (parsed teal).gui.theme;
  first = x: lib.head x;

  # Fedora's twelve fields (lazygit's ThemeConfig) and the role of each.
  want = {
    activeBorderColor = roles.accent;
    inactiveBorderColor = roles.line;
    searchingActiveBorderColor = roles.accent;
    optionsTextColor = roles.text;
    selectedLineBgColor = roles.selected;
    inactiveViewSelectedLineBgColor = roles.wash;
    cherryPickedCommitBgColor = palette.teal;
    cherryPickedCommitFgColor = roles.canvas;
    markedBaseCommitBgColor = palette.yellow;
    markedBaseCommitFgColor = roles.canvas;
    unstagedChangesColor = palette.red;
    defaultFgColor = roles.text;
  };
  accentFields = [
    "activeBorderColor"
    "searchingActiveBorderColor"
  ];

  extra =
    lib.optional (lib.sort (a: b: a < b) (lib.attrNames t) != lib.sort (a: b: a < b) (lib.attrNames want)) "gui.theme does not hold exactly Fedora's twelve fields: ${toString (lib.attrNames t)}"
    ++ lib.concatMap (
      k: lib.optional (first (t.${k} or [ "" ]) != want.${k}) "${k} is ${toString (t.${k} or null)}, want ${want.${k}}"
    ) (lib.attrNames want)
    ++ lib.concatMap (
      k:
      lib.optional (
        first (tt.${k} or [ "" ]) != teal.ravnix.theme.roles.accent
      ) "${k} does not follow the accent"
    ) accentFields
    # The focused pane's border is bold, as in Fedora's.
    ++ lib.concatMap (
      k: lib.optional (!(lib.elem "bold" t.${k})) "${k} is not bold"
    ) accentFields
    # The port's LG_CONFIG_FILE is gone: nothing depends on the environment.
    ++ lib.optional (mauve.home.sessionVariables ? LG_CONFIG_FILE) "LG_CONFIG_FILE is still set"
    ++ lib.optional mauve.catppuccin.lazygit.enable "the catppuccin port of lazygit is still on"
    # What the audit found in the port: the inactive border is Surface2 and
    # no state hue decorates the options line or the search.
    ++ lib.optional (
      first t.inactiveBorderColor != roles.line
    ) "the inactive border is not Surface2"
    # The rest of the file is Fedora's settings, kept.
    ++ lib.optional ((parsed mauve).gui.border != "single") "gui.border is not single"
    ++ lib.optional ((parsed mauve).gui.nerdFontsVersion != "3") "gui.nerdFontsVersion is not 3";
in
colors.check "theme-lazygit" {
  inherit palette extra;
  mauve = textOf mauve;
  teal = textOf teal;
  sky = textOf sky;
}
