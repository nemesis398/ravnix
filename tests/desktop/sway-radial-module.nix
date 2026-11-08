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
  # The file that home-manager links to ~/.config/TARGET, or null when it links
  # none. sourceStorePath is what its files.nix links, after a path of the flake
  # has been copied into the store, so this is the file a program reads. Reading
  # it is also what fails in a pure evaluation for a string that names a file
  # outside the store.
  linked =
    h: target:
    let
      entry = lib.findFirst (f: f.target == ".config/${target}") null (lib.attrValues (homeOf h).home.file);
    in
    if entry == null then null else (homeOf h).lib.file.sourceStorePath entry;
  linkedMenu = h: linked h "sway-radial/menu.toml";
  # What the host refuses to build, by the option it names.
  refusals =
    h:
    map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasInfix "ravnix.desktop.radial.menu" a.message) h.config.assertions
    );
  inStore = path: lib.hasPrefix "/nix/store/" path;
  hash = builtins.hashFile "sha256";

  package = self.packages.${system}.sway-radial;
  ownMenu = ./fixtures/sway-radial/menu.toml;

  plain = host [ ];
  themed = host [ { ravnix.theme.accent = lib.mkForce "teal"; } ];
  mine = host [ { ravnix.desktop.radial.menu = lib.mkForce ownMenu; } ];
  # A file outside the store, named by a string: a flake evaluates purely and
  # cannot read it, and home-manager would stop at the copy with a message about
  # an absolute path.
  outside = host [ { ravnix.desktop.radial.menu = lib.mkForce "/home/alice/radial/menu.toml"; } ];
  # A store path typed out as plain text: the string has no context, so Nix does
  # not know it is a store path, and home-manager copies it with builtins.path,
  # which a pure evaluation refuses. (`nix store add-file` prints such a string.)
  typedStore = host [
    {
      ravnix.desktop.radial.menu = lib.mkForce (
        builtins.unsafeDiscardStringContext "${package}/lib/sway-radial/menu.toml"
      );
    }
  ];
  # An absolute path literal outside the flake is a Nix path, but not one in the
  # store, so the same copy fails the same way.
  literal = host [ { ravnix.desktop.radial.menu = lib.mkForce /home/alice/radial/menu.toml; } ];
  # A path in the store that comes from a derivation, as a string with context:
  # nothing to copy, so it is fine.
  inTheStore = host [ { ravnix.desktop.radial.menu = lib.mkForce "${package}/lib/sway-radial/menu.toml"; } ];
  # A store path typed out as a path literal: it is a Nix path under the store,
  # but not one of the flake's source, and the same copy fails the same way.
  storeLiteral = host [
    { ravnix.desktop.radial.menu = lib.mkForce /nix/store/00000000000000000000000000000000-menu.toml; }
  ];
  # The same under a store object called "source", the name of a flake's tree:
  # the name does not make it a path the evaluation may read. That
  # builtins.pathExists answers false here, and does not stop the evaluation,
  # is the evaluator's behavior in pure mode, which this case pins.
  sourceLiteral = host [
    {
      ravnix.desktop.radial.menu = lib.mkForce /nix/store/00000000000000000000000000000000-source/menu.toml;
    }
  ];
  # A path value under a store object of another name: ./menu.toml in a file
  # imported from a copy called "radial" (builtins.path, as a private flake can
  # make one), which the evaluation reads like a path of the flake.
  namedCopy = host [
    {
      ravnix.desktop.radial.menu = lib.mkForce (
        import "${
          builtins.path {
            name = "radial";
            path = ./fixtures/sway-radial;
          }
        }/menu-path.nix"
      );
    }
  ];
  # A path of the flake to a file that is not there, a typo in the name.
  missing = host [ { ravnix.desktop.radial.menu = lib.mkForce ./fixtures/sway-radial/menu.tom; } ];
  # A derivation, as a module of the user's flake can give one (it has pkgs).
  # Its value is an attribute set, not a string.
  drvMenu = pkgs.writeText "menu.toml" (builtins.readFile ownMenu);
  drv = host [ { ravnix.desktop.radial.menu = lib.mkForce drvMenu; } ];
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
    # The file the unit reads, not an intermediate value: for ravnix's menu it
    # is the package's file, for a path of the flake (this check is itself
    # evaluated purely, as a flake output, and ownMenu is such a path) the copy
    # in the store with the same content, and nothing is refused.
    ++ lib.optional (
      linkedMenu plain != "${package}/lib/sway-radial/menu.toml"
    ) "the menu the unit reads by default is not the package's: ${linkedMenu plain}"
    ++ lib.optional (!inStore (linkedMenu mine)) "the menu the unit reads is not in the store: ${linkedMenu mine}"
    ++ lib.optional (
      inStore (linkedMenu mine) && builtins.readFile (linkedMenu mine) != builtins.readFile ownMenu
    ) "the menu the unit reads is not the user's file"
    ++ lib.optional (refusals mine != [ ]) "a path of the flake is refused: ${toString (refusals mine)}"
    ++ lib.optional (refusals plain != [ ]) "the default menu is refused: ${toString (refusals plain)}"
    # A string that names a path in the store is the store's file.
    ++ lib.optional (
      linkedMenu inTheStore != "${package}/lib/sway-radial/menu.toml"
    ) "a store path as a string changed: ${linkedMenu inTheStore}"
    ++ lib.optional (refusals inTheStore != [ ]) "a store path as a string is refused: ${toString (refusals inTheStore)}"
    # A string that names a file outside the store is refused by name, before
    # home-manager reaches for it.
    ++ lib.optional (
      lib.length (refusals outside) != 1
    ) "a menu outside the store is not refused once: ${toString (refusals outside)}"
    ++ lib.optional (
      lib.length (refusals typedStore) != 1
    ) "a store path typed out as text is not refused once: ${toString (refusals typedStore)}"
    ++ lib.optional (
      lib.length (refusals literal) != 1
    ) "an absolute path literal outside the flake is not refused once: ${toString (refusals literal)}"
    ++ lib.optional (
      lib.length (refusals storeLiteral) != 1
    ) "a store path typed out as a path literal is not refused once: ${toString (refusals storeLiteral)}"
    ++ lib.optional (
      lib.length (refusals sourceLiteral) != 1
    ) "a store path of a source tree typed out as a path literal is not refused once: ${toString (refusals sourceLiteral)}"
    ++ lib.optional (
      lib.length (refusals missing) != 1
    ) "a path of the flake to a missing file is not refused once: ${toString (refusals missing)}"
    # A path under a copy of another name is read and linked like a path of
    # the flake: nothing refused, and the file the unit reads is the user's.
    ++ lib.optional (
      refusals namedCopy != [ ]
    ) "a path under a store copy of another name is refused: ${toString (refusals namedCopy)}"
    # (that the case is what it says: a path value, under the copy)
    ++ lib.optional (
      !builtins.isPath namedCopy.config.ravnix.desktop.radial.menu
      || !lib.hasSuffix "-radial/menu.toml" (menuOf namedCopy)
    ) "the case of a store copy does not give a path under the copy: ${menuOf namedCopy}"
    ++ lib.optional (
      !inStore (linkedMenu namedCopy) || builtins.readFile (linkedMenu namedCopy) != builtins.readFile ownMenu
    ) "the menu the unit reads for a path under a store copy is not the user's file: ${linkedMenu namedCopy}"
    # A derivation is linked as it is: nothing to refuse, and the file the unit
    # reads is the derivation's.
    ++ lib.optional (refusals drv != [ ]) "a derivation as the menu is refused: ${toString (refusals drv)}"
    ++ lib.optional (
      toString (linkedMenu drv) != toString drvMenu
    ) "the file the unit reads is not the derivation's: ${toString (linkedMenu drv)}"
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
    # The theme file in the place the program reads without the variable (a
    # manual run, `sway-radial -v`), the very file the unit names.
    ++ lib.optional (linked plain "sway-radial/theme.json" == null) "no ~/.config/sway-radial/theme.json for a run by hand"
    ++ lib.optional (
      linked plain "sway-radial/theme.json" != null
      && toString (linked plain "sway-radial/theme.json") != themeFileOf plain
    ) "~/.config/sway-radial/theme.json is not the theme file of the unit"
    ++ lib.optional (
      linked themed "sway-radial/theme.json" != null
      && toString (linked themed "sway-radial/theme.json") != themeFileOf themed
    ) "the theme.json of a themed host is not the theme file of its unit"
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
