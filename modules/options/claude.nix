# The personal values of the public Claude Code skills: names, destinations
# and ids that the skills read from one generated JSON file instead of
# carrying them in their text.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  # What JSON can hold. No Nix paths: a path would be copied into the store
  # and rendered as its store path.
  json =
    types.nullOr (
      types.oneOf [
        types.bool
        types.int
        types.float
        types.str
        (types.attrsOf json)
        (types.listOf json)
      ]
    )
    // {
      description = "JSON value";
    };
in
{
  options.ravnix.claude.skillValues = mkOption {
    type = types.attrsOf json;
    default = { };
    example = {
      vault.root = "/home/alice/notes";
    };
    description = ''
      The values the public skills read, rendered to JSON. A skill whose
      value is missing stops and names the key to set.
    '';
  };
}
