# What modules/desktop/sway-radial.nix hands to the user's home-manager
# configuration: the sway-radial package in the profile, the menu it reads
# (~/.config/sway-radial/menu.toml, the file of ravnix.desktop.radial.menu or
# ravnix's own), and the user service with the theme file it names. The
# program's own behavior is checks.desktop-sway-radial.
{
  self,
  inputs,
  lib,
  system,
  ...
}:
let
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  host =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [
        self.nixosModules.common
        ../../modules/desktop/sway-radial.nix
      ] ++ extra;
    };

  user = (import ../../templates/default/me.nix).ravnix.user.username;
  homeOf = h: h.config.home-manager.users.${user};
  unitOf = h: (homeOf h).systemd.user.services.sway-radial;
  menuOf = h: toString (homeOf h).xdg.configFile."sway-radial/menu.toml".source;
  inStore = path: lib.hasPrefix "/nix/store/" path;
  hash = builtins.hashFile "sha256";

  package = self.packages.${system}.sway-radial;
  ownMenu = ./fixtures/sway-radial/menu.toml;

  plain = host [ ];
  themed = host [ { ravnix.theme.accent = lib.mkForce "teal"; } ];
  mine = host [ { ravnix.desktop.radial.menu = lib.mkForce ownMenu; } ];
  asString = host [ { ravnix.desktop.radial.menu = lib.mkForce "/home/alice/radial/menu.toml"; } ];
  bad =
    value:
    (builtins.tryEval (
      builtins.deepSeq (host [
        { ravnix.desktop.radial = lib.mapAttrs (_: lib.mkForce) value; }
      ]).config.ravnix.desktop.radial true
    )).success;

  env = h: (unitOf h).Service.Environment;
  has = h: prefix: lib.any (lib.hasPrefix prefix) (env h);
  themeFileOf =
    h:
    lib.removePrefix "SWAY_RADIAL_THEME=" (
      lib.findFirst (lib.hasPrefix "SWAY_RADIAL_THEME=") "" (env h)
    );
  # What theme.py reads, made from the options of the theme module.
  expectedTheme =
    h: pkgs.writeText "expected-theme.json" (builtins.toJSON { inherit (h.config.ravnix.theme) roles font lineWidth; });
  profile = (homeOf plain).home.profileDirectory;
  failures =
    lib.optional (plain.config.ravnix.desktop.radial.menu != null) "menu is not null by default"
    ++ lib.optional (
      !lib.any (p: p.outPath == package.outPath) (homeOf plain).home.packages
    ) "the package in the profile is not packages.sway-radial"
    # The default: ravnix's own menu, the one in the package.
    ++ lib.optional (
      menuOf plain != "${package}/lib/sway-radial/menu.toml"
    ) "the default menu is not the package's: ${menuOf plain}"
    # A path of the flake is copied into the store, whole and by name.
    ++ lib.optional (!inStore (menuOf mine)) "a path menu is not in the store: ${menuOf mine}"
    ++ lib.optional (
      inStore (menuOf mine) && hash (menuOf mine) != hash ownMenu
    ) "the menu in the store is another file"
    ++ lib.optional (
      inStore (menuOf mine) && !lib.hasSuffix "menu.toml" (menuOf mine)
    ) "the menu lost its name: ${menuOf mine}"
    # An absolute path as a string stays one: the file is the user's, outside the flake.
    ++ lib.optional (
      menuOf asString != "/home/alice/radial/menu.toml"
    ) "a string menu path changed: ${menuOf asString}"
    ++ lib.optional (bad { menu = "menu.toml"; }) "a relative menu path is accepted"
    ++ lib.optional (bad { menu = 5; }) "a number is accepted as the menu"
    ++ lib.optional (bad { menu = [ ownMenu ]; }) "a list is accepted as the menu"
    ++ lib.optional (bad { unknown = 1; }) "an unknown option is accepted"
    # The unit.
    ++ lib.optional (
      lib.toList (unitOf plain).Service.ExecStart != [ (lib.getExe package) ]
    ) "the unit does not run the package: ${toString (unitOf plain).Service.ExecStart}"
    ++ lib.optional (
      (unitOf plain).Install.WantedBy != [ "sway-session.target" ]
    ) "the unit is not wanted by sway-session.target"
    ++ lib.optional (
      (unitOf plain).Unit.PartOf != [ "graphical-session.target" ]
    ) "the unit is not part of graphical-session.target"
    ++ lib.optional (
      lib.toList (unitOf plain).Service.Restart != [ "on-failure" ]
    ) "the unit does not restart on failure"
    # Apps are started by Sway, so the unit keeps the session's PATH (NixOS's
    # environment.d file, with /run/wrappers/bin) and narrows nothing.
    ++ lib.optional (has plain "PATH=") "the unit sets a PATH and narrows the session's"
    ++ lib.optional (!has plain "XDG_DATA_DIRS=${profile}/share:") "the unit's XDG_DATA_DIRS does not start with the profile"
    ++ lib.optional (
      (unitOf plain).Unit.X-Restart-Triggers != [ (menuOf plain) ]
    ) "a new menu does not restart the unit"
    # (the same file, by content: a path of the flake is a store path of its own
    # once it is interpolated, and the link points at the flake's copy)
    ++ lib.optional (
      map hash (unitOf mine).Unit.X-Restart-Triggers != [ (hash ownMenu) ]
    ) "a new menu of the user's does not restart the unit"
    # The theme: a store path that is a new one when the accent is.
    ++ lib.optional (!inStore (themeFileOf plain)) "the unit does not name a theme file in the store"
    ++ lib.optional (
      themeFileOf plain == themeFileOf themed
    ) "the accent does not change the theme file, so it would not restart the unit"
    ++ lib.optional (
      themed.config.ravnix.theme.roles.accent != themed.config.ravnix.theme.palette.teal
    ) "the accent option does not reach the roles";
in
pkgs.runCommand "desktop-sway-radial-module"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    status=0
    ${lib.optionalString (failures != [ ]) ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      status=1
    ''}

    # The theme file is the roles, the font and the line widths of the theme
    # module, as the program reads them (theme.py), and nothing it would have to
    # guess.
    ${lib.concatMapStrings (h: ''
      diff <(jq -S . ${themeFileOf h}) <(jq -S . ${expectedTheme h}) > /dev/null \
        || { echo "the theme file of the unit differs from the theme module's roles, font and line widths" >&2; status=1; }
    '') [ plain themed ]}
    [ "$(jq -r .roles.accent ${themeFileOf themed})" != "$(jq -r .roles.accent ${themeFileOf plain})" ] \
      || { echo "the accent is the same in both theme files" >&2; status=1; }

    # ravnix's own menu is the file of the package, and the package's is the source's.
    cmp ${package}/lib/sway-radial/menu.toml ${../../packages/sway-radial/menu.toml} \
      || { echo "the package's menu is not packages/sway-radial/menu.toml" >&2; status=1; }

    [ $status = 0 ] || exit 1
    touch $out
  ''
