# The typed options of ravnix: every personal value a user sets, in the
# private flake's me.nix, and the only way such a value reaches a module.
# ravnix itself sets none of them, and none has a default that could pass
# for a real value. The same module serves NixOS and home-manager
# (nixosModules.options, homeModules.options); templates/default/me.nix
# lists every option with a comment.
#
# An option that me.nix or a host sets and that a home-manager module reads
# belongs here, in this directory (or in ../theme/options.nix, which it
# imports): nixosModules.common hands on to home-manager only the options
# declared in these files, so an option that NixOS alone declares can never
# make the user's home-manager evaluation fail.
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
    ./nix.nix
    ./laptop.nix
    ./peripherals.nix
    ./server.nix
    ./secrets.nix
    ./matrix.nix
    ./workbench.nix
    ./backup.nix
    ./dictionary.nix
    ./editor.nix
    ./claude.nix
    ./shell.nix
    ./placeholders.nix
    # The accent is a value the user sets in me.nix, so the option is here too;
    # nixosModules.theme imports the same file and the module system keeps one.
    ../theme/options.nix
  ];

  config.assertions = map (opt: {
    assertion = false;
    message = "${lib.showOption opt.loc} is not set. Set it in me.nix in your private flake; templates/default/me.nix in ravnix lists every value.";
  }) missing;
}
