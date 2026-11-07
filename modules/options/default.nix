# The typed options of ravnix: every personal value a user sets, in the
# private flake's me.nix, and the only way such a value reaches a module.
# ravnix itself sets none of them, and none has a default that could pass
# for a real value. The same module serves NixOS and home-manager
# (nixosModules.options, homeModules.options); templates/default/me.nix
# lists every option with a comment.
{ lib, options, ... }:
let
  # A value without a default is one the user must set. Reading it unset
  # fails anyway, but only once something reads it; an assertion fails every
  # host build at once and names each missing value, so a new user sees the
  # whole list at the first build instead of one value per attempt.
  # Known gap: this sees the options outside submodules only. A value missing
  # inside an entry (a host without its address, a service without its port)
  # fails, naming the option, only when something reads it.
  missing = lib.filter (opt: !(opt ? default) && !opt.isDefined) (
    lib.collect lib.isOption options.ravnix
  );
in
{
  imports = [
    ./user.nix
    ./hosts.nix
    ./services.nix
    ./laptop.nix
    ./server.nix
    ./secrets.nix
    ./matrix.nix
    ./backup.nix
    ./dictionary.nix
    ./claude.nix
  ];

  config.assertions = map (opt: {
    assertion = false;
    message = "${lib.showOption opt.loc} is not set. Set it in me.nix in your private flake; templates/default/me.nix in ravnix lists every value.";
  }) missing;
}
