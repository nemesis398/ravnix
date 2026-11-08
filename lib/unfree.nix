# The unfree packages of the desktop, by name (nixpkgs' unfree check looks at
# lib.getName). One list for two readers:
#
#   - modules/desktop/apps.nix allows exactly these through
#     nixpkgs.config.allowUnfreePackages, on a host that owns its nixpkgs;
#   - whoever hands a NixOS VM test node a read-only pkgs (node.pkgs, see
#     packages/README.md) cannot set nixpkgs.config from a module, and builds
#     that pkgs with `config.allowUnfreePredicate = unfree.predicate { ... }`.
#
# Packet Tracer's names (the package and the .deb that nixpkgs asks the store
# for) are allowed for a host that installs it, and Widevine's for a host that
# gives Helium the library; the arguments are the values of
# ravnix.apps.packetTracer and ravnix.apps.widevine.
{ lib }:
let
  base = [
    "obsidian"
    "steam"
    "steam-unwrapped"
  ];
  packetTracer = [
    "CiscoPacketTracer_901_Ubuntu_64bit.deb"
    "cisco-packet-tracer"
  ];
  widevine = [ "widevine-cdm" ];

  allowed =
    args:
    base
    ++ lib.optionals (args.packetTracer or false) packetTracer
    ++ lib.optionals (args.widevine or false) widevine;
in
{
  inherit
    base
    packetTracer
    widevine
    allowed
    ;

  # For `config.allowUnfreePredicate` of a pkgs built by hand.
  predicate = args: pkg: lib.elem (lib.getName pkg) (allowed args);
}
