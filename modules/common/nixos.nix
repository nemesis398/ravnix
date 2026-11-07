# What both hosts share, for NixOS: the user's account, with bash, and the
# user's home-manager configuration, which is homeModules.common (./default.nix).
#
# It is a function of the flake, `import ./nixos.nix { inherit self; }`
# (flake.nix, where it also gets a key, so that a host and a private flake can
# both import it and get one copy), so that it can name the home-manager
# module and the other ravnix modules it brings along:
#
#   - home-manager's NixOS module, with the packages of the system;
#   - nixosModules.options and nixosModules.theme, for the values this module
#     reads, so a host imports one module and the user's me.nix;
#   - homeModules.options, homeModules.theme and homeModules.common in every
#     home-manager configuration. Each carries a key or is a path, so another
#     module that adds one of them to the user's home-manager configuration
#     adds nothing the second time.
#
# The user's values reach home-manager from here. me.nix is evaluated once, by
# NixOS, and every ravnix option that it sets (or that a host module sets) is
# handed on to home-manager at a default priority, so the private flake gives
# its values once and the user's own home-manager settings still win.
#
# The contract for the modules that follow: an option that me.nix or a host
# module sets, and that a home-manager module reads as config.ravnix.*, is
# declared in modules/options (or in modules/theme/options.nix, which that
# module imports), for NixOS and home-manager both. Only those options are
# handed on. A ravnix.* option that a module declares anywhere else is its
# own business and is not forwarded: a NixOS-only option stays on NixOS, and
# a home-manager-only one is set in the home-manager configuration.
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
  # defaults, as one module per definition: the options that modules/options
  # declares (home-manager declares them as well; see the header), other than
  # the read-only ones (the theme's palette and roles, which home-manager
  # computes itself). The definitions as written are handed on, not the merged
  # values: a merged value holds what only the declaring module may set (a
  # service's url). A module carries the file the value was written in, so a
  # type error names me.nix and not this file.
  # An option's loc is its whole path, which inside a test node or a
  # container starts with where the system is; ravnix.user.name is always
  # there, and shows how much to cut off.
  prefix = lib.length options.ravnix.user.name.loc - 3;
  onlyDefault = (lib.mkOptionDefault null).priority;
  sharedDeclarations = [
    (toString ../options)
    (toString ../theme/options.nix)
  ];
  inSharedFile =
    opt:
    lib.any (
      decl: lib.any (shared: decl == shared || lib.hasPrefix "${shared}/" decl) sharedDeclarations
    ) (map toString opt.declarations);
  forwarded =
    lib.concatMap
      (
        opt:
        map (def: {
          _file = def.file;
          config = lib.setAttrByPath (lib.drop prefix opt.loc) (lib.mkDefault def.value);
        }) opt.definitionsWithLocations
      )
      (
        lib.filter (opt: !(opt.readOnly or false) && opt.highestPrio < onlyDefault && inSharedFile opt) (
          lib.collect lib.isOption options.ravnix
        )
      );
in
{
  imports = [
    self.inputs.home-manager.nixosModules.home-manager
    self.nixosModules.options
    self.nixosModules.theme
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
