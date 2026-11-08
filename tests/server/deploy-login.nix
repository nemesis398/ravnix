# How a deploy logs in to the server (hosts/server/deploy.nix), evaluated: as
# root over ssh, only with a key from ravnix.server.deployKeys and only from
# an address in ravnix.server.deployFrom, never with a password; a security
# key's line also wants the PIN (verify-required). With no deploy key, root
# takes no key at all. And what the shape promises around it holds by
# assertion, so a host cannot quietly undo it: no key the account logs in or
# signs with is a deploy key; root takes no other key, and sshd reads keys
# from the configuration alone (no ~/.ssh/authorized_keys, no other key
# file, key command, user CA or included file, in the options, in sshd's
# settings or in its extra configuration); neither the account nor root has a password; Nix trusts
# root alone and checks signatures (trusted-users, extra-trusted-users,
# require-sigs, nix.extraOptions and no file it includes); no sudo, sudo-rs
# or doas rule lets the account in without a password; sudo takes no
# signature from the ssh agent; and the account is in no group that is
# root by another door. Each assertion is shown to fire on a host that
# breaks it. tests/server/deploy-login-vm.nix shows the same login on
# running machines.
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  host =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.server
        ../../templates/default/me.nix
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "26.11";
          warnings = lib.mkForce [ ];
          ravnix.editor.languages = lib.mkForce [ "nix" ];
        }
        extra
      ];
    };
  config = extra: (host extra).config;
  failed =
    extra: map (a: a.message) (lib.filter (a: !a.assertion) (host extra).config.assertions);

  deployKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyDeploy deploy@huginn";
  skKey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tExampleOnlyDeploy deploy@yubikey";
  accountKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyAccount alice@huginn";
  deploys = {
    ravnix.server.deployKeys = lib.mkForce [
      deployKey
      skKey
    ];
    ravnix.server.deployFrom = lib.mkForce [
      "192.0.2.10"
      "2001:db8::10"
    ];
  };

  shape = config { };
  withKeys = config deploys;
  ssh = c: c.services.openssh.settings;
  rootKeys = c: c.users.users.root.openssh.authorizedKeys;
  prefix = ''from="192.0.2.10,2001:db8::10",restrict'';
  skPrefix = "${prefix},verify-required";

  # A host that breaks one promise, and the words its message must hold.
  breaks = {
    "deploy keys with no address to come from" = {
      module.ravnix.server = {
        deployKeys = lib.mkForce [ deployKey ];
        deployFrom = lib.mkForce [ ];
      };
      says = "names no address to deploy from";
    };
    "the account's own key as a deploy key" = {
      module = lib.recursiveUpdate deploys {
        users.users.${user}.openssh.authorizedKeys.keys = [ accountKey ];
        ravnix.server.deployKeys = lib.mkForce [ "${accountKey} other comment" ];
      };
      says = "holds a key of the account";
    };
    "the account's signing key as a deploy key" = {
      module = lib.recursiveUpdate deploys {
        ravnix.server.deployKeys = lib.mkForce [ me.ravnix.user.signingKey ];
      };
      says = "holds a key of the account";
    };
    "a root key set around deployKeys" = {
      module.users.users.root.openssh.authorizedKeys.keys = [ deployKey ];
      says = "root takes a key that is not in";
    };
    "a root key file" = {
      module.users.users.root.openssh.authorizedKeys.keyFiles = [ (pkgs.writeText "k" deployKey) ];
      says = "root takes a key that is not in";
    };
    "keys in the home directories again" = {
      module.services.openssh.authorizedKeysInHomedir = lib.mkForce true;
      says = "root takes a key that is not in";
    };
    "one more key file for sshd" = {
      module.services.openssh.authorizedKeysFiles = [ "/etc/ssh/more_keys/%u" ];
      says = "root takes a key that is not in";
    };
    "a program that hands sshd keys" = {
      module.services.openssh.authorizedKeysCommand = "/run/current-system/sw/bin/true";
      says = "root takes a key that is not in";
    };
    "AuthorizedKeysFile in sshd's settings" = {
      module.services.openssh.settings.AuthorizedKeysFile = "%h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u";
      says = "root takes a key that is not in";
    };
    "authorizedkeyscommand in sshd's settings, in lower case" = {
      module.services.openssh.settings.authorizedkeyscommand = "/run/current-system/sw/bin/true";
      says = "root takes a key that is not in";
    };
    "a Match block with AuthorizedKeysFile in sshd's extra configuration" = {
      module.services.openssh.extraConfig = ''
        Match User root
          AuthorizedKeysFile /root/.ssh/authorized_keys
      '';
      says = "root takes a key that is not in";
    };
    "a user CA in sshd's settings" = {
      module.services.openssh.settings.TrustedUserCAKeys = "/etc/ssh/user_ca.pub";
      says = "root takes a key that is not in";
    };
    "an Include in sshd's extra configuration" = {
      module.services.openssh.extraConfig = "Include /etc/ssh/sshd_config.d/*.conf";
      says = "root takes a key that is not in";
    };
    "signatures off" = {
      module.nix.settings.require-sigs = false;
      says = "require-sigs is off";
    };
    "signatures off in nix.extraOptions" = {
      module.nix.extraOptions = "require-sigs = false";
      says = "require-sigs is off";
    };
    "an include in nix.extraOptions" = {
      module.nix.extraOptions = "include /etc/nix/more.conf";
      says = "includes another file";
    };
    "a !include in nix.extraOptions" = {
      module.nix.extraOptions = "  !include /run/secrets/nix.conf";
      says = "includes another file";
    };
    "a second user Nix trusts" = {
      module.nix.settings.trusted-users = [ user ];
      says = "Nix trusts more users than root";
    };
    "a user Nix trusts by extra-trusted-users" = {
      module.nix.settings.extra-trusted-users = [ user ];
      says = "Nix trusts more users than root";
    };
    "a trusted-users line in nix.extraOptions" = {
      module.nix.extraOptions = "trusted-users = root ${user}";
      says = "Nix trusts more users than root";
    };
    "wheel without a password" = {
      module.security.sudo.wheelNeedsPassword = false;
      says = "sudo lets someone in";
    };
    "a NOPASSWD sudo rule" = {
      module.security.sudo.extraRules = [
        {
          users = [ user ];
          commands = [
            {
              command = "/run/current-system/sw/bin/nixos-rebuild";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
      says = "sudo lets someone in";
    };
    "NOPASSWD in sudo's extra configuration" = {
      module.security.sudo.extraConfig = "${user} ALL=(ALL) NOPASSWD: ALL";
      says = "sudo lets someone in";
    };
    "sudo with authentication turned off" = {
      module.security.sudo.extraConfig = "Defaults !authenticate";
      says = "sudo lets someone in";
    };
    "a NOPASSWD sudo-rs rule" = {
      module.security.sudo-rs = {
        enable = true;
        extraRules = [
          {
            users = [ user ];
            commands = [
              {
                command = "ALL";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];
      };
      says = "sudo-rs lets someone in";
    };
    "sudo-rs without a password" = {
      module.security.sudo-rs = {
        enable = true;
        wheelNeedsPassword = false;
      };
      says = "sudo-rs lets someone in";
    };
    "a doas rule without a password" = {
      module.security.doas = {
        enable = true;
        extraRules = [
          {
            users = [ user ];
            noPass = true;
          }
        ];
      };
      says = "doas lets someone in";
    };
    "doas for wheel without a password" = {
      module.security.doas = {
        enable = true;
        wheelNeedsPassword = false;
      };
      says = "doas lets someone in";
    };
    "nopass in doas's extra configuration" = {
      module.security.doas = {
        enable = true;
        extraConfig = "permit nopass ${user}";
      };
      says = "doas lets someone in";
    };
    "sudo that takes a signature from the ssh agent" = {
      module.security.pam.sshAgentAuth.enable = true;
      says = "security.pam.sshAgentAuth";
    };
    "sudo that takes a signature from the ssh agent, through pam_rssh" = {
      module.security.pam.rssh.enable = true;
      says = "security.pam.rssh";
    };
    "the account in docker" = {
      module.users.users.${user}.extraGroups = [ "docker" ];
      says = "is in docker";
    };
    "the account in libvirtd, as a member of the group" = {
      module.users.groups.libvirtd.members = [ user ];
      says = "is in libvirtd";
    };
    "the account with disk as its own group" = {
      module.users.users.${user}.group = lib.mkForce "disk";
      says = "is in disk";
    };
  }
  // lib.genAttrs' [ "root" "lxd" "incus-admin" ] (group: {
    name = "the account in ${group}";
    value = {
      module.users.users.${user}.extraGroups = [ group ];
      says = "is in ${group}";
    };
  })
  // lib.genAttrs' [
    "hashedPassword"
    "password"
    "hashedPasswordFile"
    "initialPassword"
    "initialHashedPassword"
  ] (option: {
    name = "the account with ${option}";
    value = {
      module.users.users.${user}.${option} =
        if option == "hashedPasswordFile" then "/run/secrets/account" else "$y$j9T$example$example";
      says = "the account ${user} has a password";
    };
  })
  // lib.genAttrs' [
    "hashedPassword"
    "password"
    "hashedPasswordFile"
    "initialPassword"
    "initialHashedPassword"
  ] (option: {
    name = "root with ${option}";
    value = {
      module.users.users.root.${option} =
        if option == "hashedPasswordFile" then "/run/secrets/root" else "$y$j9T$example$example";
      says = "root has a password";
    };
  });
  notCaught = lib.filterAttrs (
    _: b: !(lib.any (lib.hasInfix b.says) (failed b.module))
  ) breaks;

  failures =
    lib.optional (
      (ssh shape).PermitRootLogin != "prohibit-password"
    ) "root may not log in with a key, so nixos-rebuild --target-host has no way in: PermitRootLogin = ${(ssh shape).PermitRootLogin}"
    ++ lib.optional ((ssh shape).PasswordAuthentication != false) "sshd takes a password"
    ++ lib.optional ((ssh shape).KbdInteractiveAuthentication != false) "sshd asks keyboard-interactively"
    ++ lib.optional (
      (rootKeys shape).keys != [ ] || (rootKeys shape).keyFiles != [ ]
    ) "the shape alone lets a key in as root"
    ++ lib.optional shape.services.openssh.authorizedKeysInHomedir "sshd reads keys from ~/.ssh/authorized_keys"
    ++ lib.optional (failed { } != [ ]) "the shape alone fails its own assertions: ${toString (failed { })}"
    ++ lib.optional (failed deploys != [ ]) "a host with deploy keys and addresses fails: ${toString (failed deploys)}"
    ++ lib.optional ((rootKeys withKeys).keys != [
      "${prefix} ${deployKey}"
      "${skPrefix} ${skKey}"
    ]) "root's keys are not the deploy keys, each limited to deployFrom and restricted: ${builtins.toJSON (rootKeys withKeys).keys}"
    ++ lib.optional (
      shape.nix.settings.trusted-users != [ "root" ]
    ) "Nix trusts more than root: ${toString shape.nix.settings.trusted-users}"
    ++ lib.optional (!shape.security.sudo.wheelNeedsPassword) "wheel uses sudo without a password"
    ++ lib.optional (
      shape.users.users.${user}.hashedPassword != null
      || shape.users.users.${user}.password != null
      || shape.users.users.${user}.hashedPasswordFile != null
      || shape.users.users.${user}.initialPassword != null
      || shape.users.users.${user}.initialHashedPassword != null
    ) "the account has a password, so wheel's sudo opens"
    ++ lib.mapAttrsToList (
      name: b: "no assertion stops ${name} (wanted a message with \"${b.says}\")"
    ) notCaught;
in
pkgs.runCommand "server-deploy-login" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
