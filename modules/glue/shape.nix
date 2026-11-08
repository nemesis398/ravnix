# The glue joins a laptop and a server, so a host that imports it must be
# one of the two. Both shapes import the glue and set ravnix.shape
# (modules/options/shape.nix); a host that imports nixosModules.glue alone
# has no end to take and is refused here, once, so the glue's modules read
# the shape and never refuse a null of their own.
{ config, ... }:
{
  assertions = [
    {
      assertion = config.ravnix.shape != null;
      message = "ravnix.shape is not set: the glue needs to know which end this host is. Import nixosModules.laptop or nixosModules.server, which set it, instead of nixosModules.glue alone.";
    }
  ];
}
