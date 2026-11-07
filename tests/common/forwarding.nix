# nixosModules.common on a NixOS configuration: the user's account, and the
# values of ravnix.* that reach the user's home-manager configuration from the
# one me.nix the host gets. No VM: the configuration is evaluated and read.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  me = ../../templates/default/me.nix;
  user = (import me).ravnix.user;

  host =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.common
        me
        {
          system.stateVersion = "26.05";
          # A host sets these; they are not what the test is about.
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
        }
      ]
      ++ modules;
    }).config;

  plain = host [ ];
  forwarded = host [
    {
      ravnix.theme.accent = "teal";
      ravnix.shell = {
        autoAttach = "echo FROM-THE-HOST";
        secretEnv.A_TOKEN = "An item";
      };
      ravnix.services.atuin = {
        enable = true;
        host = "nas";
        port = 8888;
      };
    }
  ];
  overridden = host [
    { ravnix.shell.autoAttach = "echo FROM-THE-HOST"; }
    { home-manager.users.${user.username}.ravnix.shell.autoAttach = "echo FROM-THE-USER"; }
  ];

  homeOf = c: c.home-manager.users.${user.username};
  hm = homeOf forwarded;

  failures = lib.flatten [
    # The account.
    (lib.optional (!plain.users.users.${user.username}.isNormalUser) "the account is not a normal user")
    (lib.optional (
      plain.users.users.${user.username}.description != user.name
    ) "the account's full name is not ravnix.user.name")
    (lib.optional (
      plain.users.users.${user.username}.shell != pkgs.bashInteractive
    ) "the account's shell is not bash")
    (lib.optional (
      !lib.elem "wheel" plain.users.users.${user.username}.extraGroups
    ) "the account is not in wheel")
    # What me.nix sets reaches home-manager.
    (lib.optional (
      (homeOf plain).ravnix.user.email != user.email
    ) "ravnix.user.email did not reach home-manager")
    (lib.optional (
      (homeOf plain).ravnix.user.signingKey != user.signingKey
    ) "ravnix.user.signingKey did not reach home-manager")
    (lib.optional (
      (homeOf plain).ravnix.secrets.rbwEmail != plain.ravnix.secrets.rbwEmail
    ) "ravnix.secrets did not reach home-manager")
    (lib.optional ((homeOf plain).home.stateVersion != "26.05") "home.stateVersion is not the system's")
    (lib.optional ((homeOf plain).home.username != user.username) "home.username is not the account's")
    # What a host module sets reaches it too, whichever option it is.
    (lib.optional (hm.ravnix.theme.accent != "teal") "the accent did not reach home-manager")
    (lib.optional (
      hm.ravnix.shell.autoAttach != "echo FROM-THE-HOST"
    ) "ravnix.shell.autoAttach did not reach home-manager")
    (lib.optional (
      hm.ravnix.shell.secretEnv != { A_TOKEN = "An item"; }
    ) "ravnix.shell.secretEnv did not reach home-manager")
    (lib.optional (
      hm.ravnix.services.atuin.url != forwarded.ravnix.services.atuin.url
    ) "a service's url differs between NixOS and home-manager")
    (lib.optional (
      hm.programs.atuin.settings.sync_address != "http://192.0.2.30:8888"
    ) "atuin does not sync with the service the host placed")
    # The roles are computed on both sides, from the accent.
    (lib.optional (
      hm.ravnix.theme.roles.accent != hm.ravnix.theme.palette.teal
    ) "the roles in home-manager do not follow the accent")
    # A value the user sets in their own home-manager configuration wins.
    (lib.optional (
      (homeOf overridden).ravnix.shell.autoAttach != "echo FROM-THE-USER"
    ) "the user's own home-manager value does not win over the host's")
    # The default is not forwarded as a definition: what nobody set stays default.
    (lib.optional (
      (homeOf plain).ravnix.theme.accent != "mauve"
    ) "the default accent changed on the way")
    (lib.optional ((homeOf plain).ravnix.shell.secretEnv != { }) "a secret appeared from nowhere")
  ];
in
pkgs.runCommand "common-forwarding" { } ''
  ${lib.concatMapStrings (m: "echo ${lib.escapeShellArg m} >&2\n") failures}
  ${lib.optionalString (failures != [ ]) "exit 1"}
  touch $out
''
