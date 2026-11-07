# Where each service runs. A service names a host of ravnix.hosts, and
# clients read only its derived url, so moving a service is a change of one
# line.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  hosts = config.ravnix.hosts;

  unknownHost =
    name: host:
    "ravnix.services.${name}.host is \"${host}\", which is not a host in ravnix.hosts (declared: ${
      if hosts == { } then "none" else lib.concatStringsSep ", " (lib.attrNames hosts)
    }).";

  # An IPv6 address goes in brackets in a URL (RFC 3986).
  inUrl = address: if lib.hasInfix ":" address then "[${address}]" else address;
in
{
  options.ravnix.services = mkOption {
    default = { };
    description = "The services ravnix places on your hosts, by the name the service's module reads.";
    type = types.attrsOf (
      types.submodule (
        { name, config, ... }:
        {
          options = {
            enable = lib.mkEnableOption "the service ${name}";

            host = mkOption {
              type = types.nonEmptyStr;
              example = "nas";
              description = "The name of the host in ravnix.hosts that runs the service.";
            };

            port = mkOption {
              type = types.ints.between 1 65535;
              example = 8080;
              description = "The port the service listens on.";
            };

            url = mkOption {
              type = types.str;
              readOnly = true;
              default =
                if hosts ? ${config.host} then
                  "http://${inUrl hosts.${config.host}.address}:${toString config.port}"
                else
                  throw (unknownHost name config.host);
              defaultText = lib.literalExpression ''"http://''${ravnix.hosts.''${host}.address}:''${toString port}"'';
              description = "Where clients reach the service, derived from its host and port. Read-only.";
            };
          };
        }
      )
    );
  };

  config.assertions = lib.mapAttrsToList (name: service: {
    assertion = !service.enable || hosts ? ${service.host};
    message = unknownHost name service.host;
  }) config.ravnix.services;
}
