# The two shapes name themselves and bring the glue: nixosModules.laptop sets
# ravnix.shape to "laptop" and nixosModules.server to "server", each imports
# nixosModules.glue (found by its key in the module tree, since the glue's
# directory may still be empty), and home-manager sees the same shape. A host
# with the glue and no shape has null, which a glue module refuses by name,
# and a host with both shapes does not evaluate.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  # The server and the bare glue get a boot loader and a root file system
  # from the helper; the laptop brings its own (disko and systemd-boot), so it
  # gets only the template's values, as tests/laptop/shape.nix builds it.
  hostModules = import ./helpers/host-modules.nix { inherit lib; };
  quiet = {
    system.stateVersion = "26.05";
    warnings = lib.mkForce [ ];
  };
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = hostModules ++ [ { nixpkgs.hostPlatform = lib.mkDefault system; } ] ++ modules;
    };
  buildLaptop =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        ../../templates/default/me.nix
        quiet
      ]
      ++ modules;
    };

  laptop = buildLaptop [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  server = build [ self.nixosModules.server ];
  glueOnly = build [ self.nixosModules.glue ];
  both = buildLaptop [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
    self.nixosModules.server
  ];

  # The key of every module in a host's tree that the module system reaches
  # (tests/laptop/shape.nix walks it the same way).
  keys =
    s:
    let
      walk = lib.concatMap (m: lib.optionals (!m.disabled) ([ m.key ] ++ walk m.imports));
    in
    walk s.graph;
  hasGlue = s: lib.elem "ravnix/nixosModules.glue" (keys s);
  shapeOf = s: s.config.ravnix.shape;
  homeShapeOf =
    s: s.config.home-manager.users.${s.config.ravnix.user.username}.ravnix.shape;
  evaluates = s: (builtins.tryEval (builtins.unsafeDiscardStringContext s.config.system.build.toplevel.drvPath)).success;
  shapeEvaluates = s: (builtins.tryEval (builtins.deepSeq (shapeOf s) true)).success;

  check = cond: msg: lib.optional (!cond) msg;
  failures =
    check (shapeOf laptop == "laptop") "nixosModules.laptop does not set ravnix.shape to \"laptop\""
    ++ check (shapeOf server == "server") "nixosModules.server does not set ravnix.shape to \"server\""
    ++ check (hasGlue laptop) "nixosModules.laptop does not import nixosModules.glue"
    ++ check (hasGlue server) "nixosModules.server does not import nixosModules.glue"
    ++ check (homeShapeOf laptop == "laptop") "home-manager on the laptop does not see ravnix.shape = \"laptop\""
    ++ check (homeShapeOf server == "server") "home-manager on the server does not see ravnix.shape = \"server\""
    ++ check (evaluates laptop) "the laptop shape with its hardware module does not evaluate"
    ++ check (evaluates server) "the server shape does not evaluate"
    ++ check (shapeOf glueOnly == null) "a host with the glue and no shape has a shape"
    ++ check (!(shapeEvaluates both)) "a host with both shapes evaluates ravnix.shape";
in
pkgs.runCommand "flake-shapes" { } (
  if failures == [ ] then
    ''
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
