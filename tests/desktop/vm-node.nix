# A NixOS VM test node that imports nixosModules.desktop evaluates.
#
# A node of pkgs.testers.runNixOSTest gets a read-only pkgs (node.pkgs): no
# module may define nixpkgs.config or nixpkgs.overlays, and one that does is an
# evaluation error ("nixpkgs.config is set to read-only"). modules/desktop/apps.nix
# allows its unfree packages through nixpkgs.config.allowUnfreePackages, so it
# must leave that alone there, as nixosModules.common does for the overlay. The
# one who hands over the pkgs allows the same names (lib/unfree.nix) and applies
# the overlay, as packages/README.md describes.
#
# The node is evaluated down to its system derivation, not built or booted.
# It also imports the hardware module of the laptop, which allows the NVIDIA
# driver by name and so has the same obligation. Three controls keep the check
# honest: a module that does define nixpkgs.config on the node, a pkgs that allows nothing unfree, and a pkgs
# that allows the names of the default host for a node that sets the options
# for Packet Tracer and Widevine. Each must fail to evaluate.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  unfree = import ../../lib/unfree.nix { inherit lib; };

  # The pkgs of a node: the names of lib/unfree.nix, and the ones a module that
  # the node imports names itself (the hardware module's NVIDIA driver).
  nodePkgs =
    allowed: others:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfreePredicate =
        pkg: unfree.predicate allowed pkg || lib.elem (lib.getName pkg) others;
      overlays = [ self.overlays.default ];
    };

  node =
    {
      allowed ? { },
      others ? [ ],
      extra ? [ ],
    }:
    pkgs.testers.runNixOSTest {
      name = "desktop-vm-node";
      node.pkgs = lib.mkForce (nodePkgs allowed others);
      nodes.machine = {
        imports = [
          self.nixosModules.desktop
          ../../templates/default/me.nix
        ]
        ++ extra;
        # The template's values are placeholders and warn about it.
        warnings = lib.mkForce [ ];
      };
      testScript = "machine.succeed('true')";
    };

  evaluates =
    t:
    (builtins.tryEval (
      builtins.unsafeDiscardStringContext t.config.nodes.machine.system.build.toplevel.drvPath
    )).success;

  both = {
    ravnix.apps.packetTracer = lib.mkForce true;
    ravnix.apps.widevine = lib.mkForce true;
  };

  failures =
    lib.optional (!evaluates (node { })) "a VM node with nixosModules.desktop does not evaluate"
    ++ lib.optional (
      !evaluates (node {
        allowed = {
          packetTracer = true;
          widevine = true;
        };
        extra = [ both ];
      })
    ) "a VM node with nixosModules.desktop, Packet Tracer and Widevine does not evaluate"
    # The hardware module names its own unfree package (the NVIDIA driver) and
    # has to leave nixpkgs.config alone on a read-only pkgs as well.
    ++ lib.optional (
      !evaluates (node {
        others = [ "nvidia-x11" ];
        extra = [ self.nixosModules.hardware-ideapad-pro-5-16ahp9 ];
      })
    ) "a VM node with nixosModules.desktop and the hardware module does not evaluate"
    # The controls.
    ++
      lib.optional
        (evaluates (node {
          extra = [ { nixpkgs.config.allowUnfreePackages = [ "obsidian" ]; } ];
        }))
        "control: defining nixpkgs.config on a read-only node evaluates, so the node is not read-only and the check proves nothing"
    ++
      lib.optional
        (evaluates (
          pkgs.testers.runNixOSTest {
            name = "desktop-vm-node-unfree";
            node.pkgs = lib.mkForce (
              import inputs.nixpkgs {
                inherit system;
                config.allowUnfreePredicate = _: false;
                overlays = [ self.overlays.default ];
              }
            );
            nodes.machine = {
              imports = [
                self.nixosModules.desktop
                ../../templates/default/me.nix
              ];
              warnings = lib.mkForce [ ];
            };
            testScript = "machine.succeed('true')";
          }
        ))
        "control: a node whose pkgs allows nothing unfree evaluates, so the names in lib/unfree.nix are not what lets the node through"
    ++
      lib.optional
        (evaluates (node {
          extra = [ both ];
        }))
        "control: a node that sets the options for Packet Tracer and Widevine evaluates with a pkgs that allows only the default names";
in
pkgs.runCommand "desktop-vm-node" { } (
  if failures != [ ] then
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
  else
    "touch $out"
)
