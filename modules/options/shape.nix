# Which shape a host is: the laptop, huginn (nixosModules.laptop), or the
# server, muninn (nixosModules.server). The shape sets it, never me.nix, so
# it is internal and the template does not list it. The glue reads it to
# pick its end of each connection between the two (modules/glue), which a
# guess from other options gets wrong: a laptop may import the workbench for
# its toolchains, and a server may run Sway in a test.
#
# null is a host without a shape, such as a test that imports one module
# alone. A host that imports the glue that way is refused, by one assertion
# that names this option (modules/glue/shape.nix). Two shapes in one host are
# two definitions of it, which the module system refuses.
{ lib, ... }:
{
  options.ravnix.shape = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.enum [
        "laptop"
        "server"
      ]
    );
    default = null;
    internal = true;
    description = ''
      The shape of the host, set by nixosModules.laptop ("laptop") and
      nixosModules.server ("server"); null on a host without one. Read by the
      glue to choose its end of each connection.
    '';
  };
}
