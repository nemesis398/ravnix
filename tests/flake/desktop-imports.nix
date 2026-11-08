# The convention the desktop and glue modules rely on: every
# modules/desktop/NAME.nix and NAME/default.nix is imported by
# nixosModules.desktop, and the same in modules/glue for nixosModules.glue
# (lib/import-dir.nix), in sorted order, so a module is added without touching
# a shared file. This test runs the import function on the fixture trees in
# ./fixtures/desktop, evaluates what it finds, and checks that both
# directories use it.
{
  self,
  inputs,
  pkgs,
  lib,
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
  # Whether evaluating the value fails, deeply enough to reach everything.
  refused = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

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
      !refused (imports (fixtures + "/symlink-file"))
    ) "a symlink to a file was not refused"
    ++ lib.optional (
      !refused (imports (fixtures + "/symlink-dir"))
    ) "a symlink to a directory was not refused"
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
          lib.optional (
            self.nixosModules.${name}.key or null != "ravnix/nixosModules.${name}"
          ) "nixosModules.${name} has no key ravnix/nixosModules.${name}"
        )
        [
          "desktop"
          "glue"
        ];
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
