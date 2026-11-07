# What both hosts share, for NixOS: the user's account, with bash, and the
# user's home-manager configuration, which is homeModules.common (./default.nix).
#
# It is a function of the flake, `import ./nixos.nix { inherit self; }`
# (flake.nix), so that it can name the home-manager module and the other
# ravnix modules it brings along:
#
#   - home-manager's NixOS module, with the packages of the system;
#   - nixosModules.options and nixosModules.theme, for the values this module
#     reads, so a host imports one module and the user's me.nix;
#   - homeModules.options, homeModules.theme and homeModules.common in every
#     home-manager configuration. Another module that adds to the user's
#     home-manager configuration must not list homeModules.theme again:
#     home-manager would declare the catppuccin options twice.
#
# The user's values reach home-manager from here. me.nix is evaluated once, by
# NixOS, and every ravnix option that it sets (or that a host module sets) is
# handed on to home-manager at a default priority, so the private flake gives
# its values once and the user's own home-manager settings still win.
{ self }:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  user = config.ravnix.user.username;

  # What was defined for the options of ravnix above the priority of their
  # defaults, other than the read-only options (the theme's palette and roles,
  # which home-manager computes itself), as one module per definition. The
  # definitions as written are handed on, not the merged values: a merged
  # value holds what only the declaring module may set (a service's url).
  # An option's loc is its whole path, which inside a test node or a
  # container starts with where the system is; ravnix.user.name is always
  # there, and shows how much to cut off.
  prefix = lib.length options.ravnix.user.name.loc - 3;
  onlyDefault = (lib.mkOptionDefault null).priority;
  forwarded =
    lib.concatMap
      (
        opt: map (value: lib.setAttrByPath (lib.drop prefix opt.loc) (lib.mkDefault value)) opt.definitions
      )
      (
        lib.filter (opt: !(opt.readOnly or false) && opt.highestPrio < onlyDefault) (
          lib.collect lib.isOption options.ravnix
        )
      );
in
{
  imports = [
    self.inputs.home-manager.nixosModules.home-manager
    self.nixosModules.options
    self.nixosModules.theme
    ./options.nix
  ];

  users.users.${user} = {
    isNormalUser = true;
    description = config.ravnix.user.name;
    shell = pkgs.bashInteractive;
    # Administration of the machine; the account has no password here, which
    # the host or the installer decides.
    extraGroups = [ "wheel" ];
  };

  home-manager = {
    # The packages of the system, so a home-manager package is the system's
    # build and nixpkgs is evaluated once; and installed into the user's
    # profile in the store, not into ~/.nix-profile.
    useGlobalPkgs = true;
    useUserPackages = true;
    sharedModules = [
      self.homeModules.options
      self.homeModules.theme
      self.homeModules.common
    ]
    ++ forwarded;
    users.${user}.home.stateVersion = lib.mkDefault config.system.stateVersion;
  };
}
