# What modules/desktop/backdrop.nix hands to the user's home-manager
# configuration: the backdrop package in the profile, and the config the
# command reads (~/.config/backdrop/config.json), made from the theme and from
# ravnix.desktop.backdrop.image and .tools. The pictures the command draws are
# checks.desktop-backdrop.
{
  self,
  inputs,
  lib,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  host =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [
        self.nixosModules.common
        ../../modules/desktop/backdrop.nix
      ] ++ extra;
    };

  user = (import ../../templates/default/me.nix).ravnix.user.username;
  homeOf = h: h.config.home-manager.users.${user};
  # The store paths in the config carry a string context, which fromJSON
  # refuses; they exist by then, the paths having been copied to evaluate them.
  configOf =
    h:
    builtins.fromJSON (
      builtins.unsafeDiscardStringContext (homeOf h).xdg.configFile."backdrop/config.json".text
    );

  fixtures = ./fixtures/backdrop;
  hash = builtins.hashFile "sha256";
  inStore = path: lib.hasPrefix "/nix/store/" path;

  plain = host [ ];
  themed = host [ { ravnix.theme.accent = lib.mkForce "teal"; } ];
  mine = host [
    {
      ravnix.desktop.backdrop = {
        # The template sets image = null; two plain values of an option that
        # takes one value conflict.
        image = lib.mkForce (fixtures + "/wall.png");
        tools = [
          (fixtures + "/one.svg")
          (fixtures + "/two.svg")
        ];
      };
    }
  ];
  asStrings = host [
    {
      ravnix.desktop.backdrop = {
        image = lib.mkForce "/home/alice/Pictures/wall.jpg";
        tools = [ "/home/alice/logos/odin.svg" ];
      };
    }
  ];
  bad =
    value:
    (builtins.tryEval (
      builtins.deepSeq (host [
        { ravnix.desktop.backdrop = lib.mapAttrs (_: lib.mkForce) value; }
      ]).config.ravnix.desktop.backdrop true
    )).success;

  c = configOf plain;
  m = configOf mine;
  palette = plain.config.ravnix.theme.palette;

  failures =
    lib.optional (plain.config.ravnix.desktop.backdrop.image != null) "image is not null by default"
    ++ lib.optional (plain.config.ravnix.desktop.backdrop.tools != [ ]) "tools is not empty by default"
    ++ lib.optional (c.image != null) "the default config has an image"
    ++ lib.optional (c.tools != [ ]) "the default config has tools"
    ++ lib.optional (c.palette != palette) "the config's palette is not the theme's"
    ++ lib.optional (lib.attrNames c.palette == [ ] || !(c.palette ? sapphire)) "the palette is incomplete"
    ++ lib.optional (c.accent != "mauve") "the default accent is ${c.accent}, not mauve"
    ++ lib.optional (c.font != plain.config.ravnix.theme.font) "the font is not the theme's"
    ++ lib.optional ((configOf themed).accent != "teal") "the accent option does not reach the config"
    ++ lib.optional (
      !lib.any (p: lib.getName p == "backdrop") (homeOf plain).home.packages
    ) "the backdrop package is not in the user's profile"
    ++ lib.optional (
      !lib.any (p: p.outPath == self.packages.${system}.backdrop.outPath) (homeOf plain).home.packages
    ) "the package in the profile is not packages.backdrop"
    # A path of the flake is copied into the store, whole and by name.
    ++ lib.optional (!inStore m.image) "a path image is not in the store: ${m.image}"
    ++ lib.optional (
      inStore m.image && (builtins.baseNameOf m.image != "wall.png" && !lib.hasSuffix "-wall.png" m.image)
    ) "the image lost its name: ${m.image}"
    ++ lib.optional (
      inStore m.image && hash m.image != hash (fixtures + "/wall.png")
    ) "the image in the store is another file"
    ++ lib.optional (lib.length m.tools != 2) "the tools are ${toString (lib.length m.tools)}, not two"
    ++ lib.optional (
      lib.length m.tools == 2
      && (
        hash (lib.elemAt m.tools 0) != hash (fixtures + "/one.svg")
        || hash (lib.elemAt m.tools 1) != hash (fixtures + "/two.svg")
      )
    ) "the tools are not the files given, in order"
    # An absolute path as a string stays one: it names a file the user keeps
    # outside the flake.
    ++ lib.optional (
      (configOf asStrings).image != "/home/alice/Pictures/wall.jpg"
    ) "a string image path changed"
    ++ lib.optional (
      (configOf asStrings).tools != [ "/home/alice/logos/odin.svg" ]
    ) "a string tool path changed"
    ++ lib.optional (bad { image = "wall.jpg"; }) "a relative image path is accepted"
    ++ lib.optional (bad { tools = [ "odin.svg" ]; }) "a relative tool path is accepted"
    ++ lib.optional (bad { image = 5; }) "a number is accepted as an image"
    ++ lib.optional (bad { tools = "odin.svg"; }) "a string is accepted as the tools list"
    ++ lib.optional (bad { unknown = 1; }) "an unknown option is accepted";
in
inputs.nixpkgs.legacyPackages.${system}.runCommand "desktop-backdrop-module" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
