# A value reserved for documentation reaches no real machine: the addresses
# of RFC 5737 (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and RFC 3849
# (2001:db8::/32), and the names under example.org, example.com and
# example.net (RFC 2606). The template is made of them, so one left in a
# private flake is a placeholder nobody replaced. Each gets a warning that
# names its option; it does not stop the build.
{ config, lib, ... }:
let
  documentation =
    value:
    let
      v = lib.toLower value;
      match = re: builtins.match re v != null;
    in
    match "(.*[^0-9])?(192[.]0[.]2|198[.]51[.]100|203[.]0[.]113)[.][0-9].*"
    || match "(.*[^0-9a-f:])?2001:0*db8:.*"
    || match "(.*[^a-z0-9-])?example[.](org|com|net)([^a-z0-9.].*|[.])?";

  # Every string under config.ravnix, with where it is. A service's url and
  # authority are derived from its host's address, which is reported already. The walk
  # enters plain attribute sets and lists only: a package is a derivation,
  # which contains itself (its `out` is the derivation again) and would never
  # end, and a value marked with _type (an override, an option, a literal
  # expression) is not a value the user wrote. Functions, paths and numbers
  # hold no string.
  strings =
    where: value:
    if lib.isDerivation value || (builtins.isAttrs value && value ? _type) then
      [ ]
    else if builtins.isAttrs value then
      lib.concatLists (
        lib.mapAttrsToList (
          name: v:
          lib.optionals (
            !(
              lib.hasPrefix "ravnix.services." where
              && lib.elem name [
                "url"
                "authority"
              ]
            )
          ) (
            strings "${where}.${name}" v
          )
        ) value
      )
    else if builtins.isList value then
      lib.concatLists (lib.imap0 (i: strings "${where}[${toString i}]") value)
    else if builtins.isString value then
      lib.optional (documentation value) { inherit where value; }
    else
      [ ];
in
{
  config.warnings = map (
    found:
    "${found.where} is \"${found.value}\", a value reserved for documentation that reaches no real machine. Replace it in me.nix."
  ) (strings "ravnix" config.ravnix);
}
