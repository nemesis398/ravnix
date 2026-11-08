# The convention the desktop and glue modules rely on: every
# modules/desktop/NAME.nix and NAME/default.nix is imported by
# nixosModules.desktop, and the same in modules/glue for nixosModules.glue
# (lib/import-dir.nix), in sorted order, so a module is added without touching
# a shared file. This test runs the import function on the fixture trees in
# ./fixtures/desktop, evaluates what it finds, and checks that both
# directories use it, and that a host with either module alone has what the
# modules read.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  importDir = import ../../lib/import-dir.nix { inherit lib; };
  importDirFile = ../../lib/import-dir.nix;
  fixtures = ./fixtures/desktop;
  refusals = import ./helpers/refusals.nix { inherit lib; };

  imports = importDir "modules/desktop";
  tree = imports (fixtures + "/tree");
  evaluated = lib.evalModules { modules = [ { imports = tree; } ]; };

  expression = label: dir: ''
    let
      lib = import ${inputs.nixpkgs}/lib;
    in
    map toString (import ${importDirFile} { inherit lib; } "${label}" ${fixtures}/${dir})
  '';

  # modules/desktop/default.nix and modules/glue/default.nix are modules that
  # import their own directory, whatever is in it. While both directories are
  # empty this compares two empty lists, so a default.nix that names the wrong
  # directory is caught from the first module on.
  desktop = import ../../modules/desktop/default.nix { inherit lib; };
  glue = import ../../modules/glue/default.nix { inherit lib; };

  # A host with one of the modules and nothing else of ravnix's: both bring
  # nixosModules.common, whose home-manager, options and overlay the files of
  # their directories read (home-manager.sharedModules, pkgs.ravnix.NAME), and
  # the key of common keeps a second import from adding anything. A summary is
  # whether the host evaluates, how many copies of the common and theme home
  # modules it loads (counted by key in home-manager.sharedModules, which gets
  # one more for each copy of the module that is loaded), how many overlays it
  # has, and whether pkgs.ravnix exists. The files of the directories add home
  # modules of their own, so the length of sharedModules says nothing about
  # copies of common.
  hostModules = import ./helpers/host-modules.nix { inherit lib; };
  summary =
    modules:
    let
      h = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        modules = hostModules ++ modules;
      };
      copies =
        key:
        lib.count (m: builtins.isAttrs m && (m.key or null) == key) h.config.home-manager.sharedModules;
      facts = {
        common = copies "ravnix/homeModules.common";
        theme = copies "ravnix/homeModules.theme";
        overlays = lib.length h.config.nixpkgs.overlays;
        ravnix = h.pkgs ? ravnix;
      };
    in
    builtins.tryEval (builtins.deepSeq facts facts);
  commonOnly = summary [ self.nixosModules.common ];
  together = summary [
    self.nixosModules.common
    self.nixosModules.desktop
    self.nixosModules.glue
  ];
  alone = name: summary [ self.nixosModules.${name} ];
  # Common's inner module loaded once more without its key, as a common whose
  # key stopped working would be: the count has to see the second copy, or the
  # comparisons below cannot fail.
  unkeyed = summary [
    self.nixosModules.common
    (import ../../modules/common/nixos.nix { inherit self; })
  ];

  failures =
    lib.optional
      (
        tree != [
          (fixtures + "/tree/alpha.nix")
          (fixtures + "/tree/beta.nix")
          (fixtures + "/tree/delta")
        ]
      )
      "expected alpha.nix, beta.nix and delta in that order (not default.nix, README.md or data/), found: ${toString tree}"
    ++
      lib.optional
        (
          evaluated.config.fixture or null != {
            alpha = "alpha.nix";
            beta = "beta.nix";
            delta = "delta/default.nix";
          }
        )
        "evaluating the imports did not set the option of each module: ${
          builtins.toJSON (evaluated.config.fixture or null)
        }"
    ++ lib.optional (
      imports (fixtures + "/empty") != [ ]
    ) "a directory with only default.nix and a README gave imports"
    ++ lib.optional (
      desktop.imports != imports ../../modules/desktop
    ) "modules/desktop/default.nix does not import the modules of its own directory"
    ++ lib.optional (
      glue.imports != importDir "modules/glue" ../../modules/glue
    ) "modules/glue/default.nix does not import the modules of its own directory"
    ++
      lib.concatMap
        (
          name:
          let
            # One evaluation of the host per module, not one per use.
            a = alone name;
          in
          lib.optional (
            self.nixosModules.${name}.key or null != "ravnix/nixosModules.${name}"
          ) "nixosModules.${name} has no key ravnix/nixosModules.${name}"
          ++
            lib.optional (!a.success || a.value != commonOnly.value)
              "a host with nixosModules.${name} alone does not have what nixosModules.common gives it (home-manager.sharedModules, the overlay, pkgs.ravnix)"
        )
        [
          "desktop"
          "glue"
        ]
    ++
      lib.optional
        (
          !commonOnly.success
          || !commonOnly.value.ravnix
          || commonOnly.value.common != 1
          || commonOnly.value.theme != 1
        )
        "a host with nixosModules.common does not load the common and theme home modules once each, or has no pkgs.ravnix"
    ++ lib.optional (
      !unkeyed.success || unkeyed.value.common != 2
    ) "a second, unkeyed copy of the common module does not count 2 (the count above cannot fail)"
    ++ lib.optional (
      !together.success || together.value != commonOnly.value
    ) "importing nixosModules.common, desktop and glue together adds to what common alone gives";
in
pkgs.runCommand "flake-desktop-imports"
  {
    nativeBuildInputs = [
      pkgs.nix
      pkgs.gnugrep
    ];
  }
  (
    if failures != [ ] then
      ''
        printf '%s\n' ${lib.escapeShellArgs failures} >&2
        exit 1
      ''
    else
      ''
        ${refusals [
          {
            name = "a symlink to a file in modules/desktop/";
            expression = expression "modules/desktop" "symlink-file";
            messages = [
              "modules/desktop/: link.nix is a symlink"
              "a file modules/desktop/NAME.nix"
            ];
          }
          {
            name = "a symlink to a directory in modules/desktop/";
            expression = expression "modules/desktop" "symlink-dir";
            messages = [ "modules/desktop/: beta is a symlink" ];
          }
          {
            name = "a symlink in modules/glue/";
            expression = expression "modules/glue" "symlink-file";
            messages = [
              "modules/glue/: link.nix is a symlink"
              "a file modules/glue/NAME.nix"
            ];
          }
        ]}
        touch $out
      ''
  )
