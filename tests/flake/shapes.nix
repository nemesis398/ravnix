# The two shapes name themselves and bring the glue: nixosModules.laptop sets
# ravnix.shape to "laptop" and nixosModules.server to "server", each imports
# nixosModules.glue (found by its key in the module tree, since the glue's
# directory may still be empty), and home-manager sees the same shape. A
# laptop that also imports the workbench stays a laptop. A host with both
# shapes, or with a me.nix that sets another shape or null on top of one, is
# refused, and the refusal is the two definitions of ravnix.shape, each named
# by its shape's file: the same host with one value forced evaluates. The
# server, like the laptop, loads the common home module once.
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
  # The same host with one shape forced: what refuses `both` is the two
  # definitions and nothing else the shapes bring together.
  forced = buildLaptop [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
    self.nixosModules.server
    { ravnix.shape = lib.mkForce "laptop"; }
  ];
  laptopWorkbench = buildLaptop [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
    self.nixosModules.workbench
  ];
  # A me.nix that sets the shape on top of a shape.
  laptopSaying =
    value:
    buildLaptop [
      self.nixosModules.laptop
      self.nixosModules.hardware-ideapad-pro-5-16ahp9
      { ravnix.shape = value; }
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
  homeShapeOf = s: s.config.home-manager.users.${s.config.ravnix.user.username}.ravnix.shape;
  evaluates =
    s:
    (builtins.tryEval (builtins.unsafeDiscardStringContext s.config.system.build.toplevel.drvPath))
    .success;
  shapeEvaluates = s: (builtins.tryEval (builtins.seq (shapeOf s) true)).success;
  # The values ravnix.shape is given, and the files that give them; both can
  # be read while the merged value throws.
  definedShapes = s: lib.sort lib.lessThan s.options.ravnix.shape.definitions;
  definingFiles =
    s: lib.sort lib.lessThan (map (d: toString d.file) s.options.ravnix.shape.definitionsWithLocations);
  shapeFiles = lib.sort lib.lessThan [
    (toString ../../hosts/laptop/default.nix)
    (toString ../../hosts/server/default.nix)
  ];
  # How many copies of the common home module a host loads
  # (tests/laptop/shape.nix counts them the same way).
  copies =
    s:
    lib.count (
      m: builtins.isAttrs m && (m.key or null) == "ravnix/homeModules.common"
    ) s.config.home-manager.sharedModules;

  check = cond: msg: lib.optional (!cond) msg;
  failures =
    check (shapeOf laptop == "laptop") "nixosModules.laptop does not set ravnix.shape to \"laptop\""
    ++ check (shapeOf server == "server") "nixosModules.server does not set ravnix.shape to \"server\""
    ++ check (hasGlue laptop) "nixosModules.laptop does not import nixosModules.glue"
    ++ check (hasGlue server) "nixosModules.server does not import nixosModules.glue"
    ++ check (
      homeShapeOf laptop == "laptop"
    ) "home-manager on the laptop does not see ravnix.shape = \"laptop\""
    ++ check (
      homeShapeOf server == "server"
    ) "home-manager on the server does not see ravnix.shape = \"server\""
    ++ check (evaluates laptop) "the laptop shape with its hardware module does not evaluate"
    ++ check (evaluates server) "the server shape does not evaluate"
    ++ check (shapeOf glueOnly == null) "a host with the glue and no shape has a shape"
    ++ check (!(shapeEvaluates both)) "a host with both shapes evaluates ravnix.shape"
    ++ check (
      definedShapes both == [
        "laptop"
        "server"
      ]
    ) "a host with both shapes does not hold both definitions of ravnix.shape"
    ++
      check (definingFiles both == shapeFiles)
        "the definitions of a host with both shapes are not named by the shapes' files: ${builtins.toJSON (definingFiles both)}"
    ++
      check (shapeEvaluates forced && shapeOf forced == "laptop")
        "a host with both shapes and one forced does not evaluate its shape, so the refusal of both may be another error"
    ++ check (
      shapeOf laptopWorkbench == "laptop"
    ) "a laptop that also imports the workbench is not a laptop"
    ++ check (
      !(shapeEvaluates (laptopSaying "server"))
    ) "a me.nix that sets \"server\" on the laptop is not refused"
    ++ check (
      !(shapeEvaluates (laptopSaying null))
    ) "a me.nix that sets null on the laptop is not refused"
    ++ check (
      shapeOf (laptopSaying "laptop") == "laptop"
    ) "a me.nix that sets the laptop's own shape is refused"
    ++ check (
      copies server == 1
    ) "the server loads the common home module ${toString (copies server)} times, not once";
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
