# How many backups each target keeps, in one file a person can read
# without knowing Nix.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.ravnix.backup.retentionFile = mkOption {
    type = types.path;
    example = lib.literalExpression "./backups.toml";
    description = ''
      A TOML file with the snapshots each target keeps: `[targets.nas]` and
      `[targets.internxt]`, each with `daily`, `weekly`, `monthly` and
      `yearly`, and optional `[targets.<target>.hosts.<host>]` tables for a
      host that keeps a different number. Whatever falls outside it is
      pruned.
    '';
  };
}
