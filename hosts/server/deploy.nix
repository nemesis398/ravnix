# How a deploy logs in to the server: as root, over ssh, with a key from
# ravnix.server.deployKeys, and only from an address in
# ravnix.server.deployFrom. Each deploy key becomes a line of root's
# authorized keys with `from="ADDRESSES",restrict` in front of it: sshd
# takes the key only from those addresses, and the session gets no
# terminal and no forwarding of ports, agent or X11, which nixos-rebuild
# and nix copy do not need (tests/server/deploy-login-vm.nix, where a
# terminal and port forwarding are refused). A security key's line (sk-)
# also gets `verify-required`: sshd then takes only a signature made after
# the key's PIN, one PIN per login, and a security key made without
# `ssh-keygen -O verify-required` does not log in. With no deploy key, root
# takes no key at all.
#
# from= compares the address a connection comes from and nothing else. So
# the key does not get in from the server itself, from another host, or
# through a hop over another host (ssh -J), unless that host is one of
# deployFrom. It does not keep whoever holds the key from deploying from an
# allowed address, and whoever holds it is every process that runs as the
# deploying user on the deploying machine: whatever can read a key file or
# ask an agent there, and, with a security key, whatever rides a connection
# the user touched for. nixos-rebuild keeps one connection open for a whole
# deploy (its ControlMaster, a socket in the user's temporary directory)
# unless NIX_SSHOPTS="-o ControlPath=none" turns it off, at one touch per
# connection. So if the server may run commands as that user on the
# deploying machine, a login on the laptop for the server's agents for
# example, the server's agents can deploy too, and the deploy login no
# longer keeps them from root. The key has to stay off the server, and the
# best key is one a person has to unlock for every login: on a security
# key, with its PIN as well (ssh-keygen -t ed25519-sk -O verify-required),
# and no agent session in the deploying user's shell while a deploy runs.
# Where the private half lives is beyond what the configuration sees.
#
# What the configuration does see, it asserts, so that a host cannot open
# another way to root by accident: no deploy key is one the account logs in
# or signs with; root's keys are the deploy keys and no others, and sshd
# reads keys from the configuration alone (no ~/.ssh/authorized_keys, no
# other key file, no key command, no user CA for certificates and no
# included file, neither in the options nor in sshd's settings or extra
# configuration); neither the account nor root has a
# password in the configuration (one set by hand with passwd stays in
# /etc/shadow, since users.mutableUsers stays on: set none); Nix trusts root
# alone and checks signatures (trusted-users, extra-trusted-users,
# require-sigs, and nix.extraOptions with no such line and no file it
# includes); no sudo, sudo-rs or doas rule lets anyone in without a
# password; sudo takes no signature from an ssh agent for one; and the
# account is in no group that is root by another door.
{ config, lib, ... }:
let
  cfg = config.ravnix.server;
  user = config.ravnix.user.username;
  account = config.users.users.${user};
  root = config.users.users.root.openssh.authorizedKeys;

  # A security key's line also wants the PIN: with verify-required, sshd
  # takes only a signature the authenticator made after the PIN, so a key
  # made without `ssh-keygen -O verify-required` does not log in at all.
  lines = map (
    key:
    "from=\"${lib.concatStringsSep "," cfg.deployFrom}\",restrict${
      lib.optionalString (lib.hasPrefix "sk-" key) ",verify-required"
    } ${key}"
  ) cfg.deployKeys;

  # The key itself, the second word of a public key line: what makes two
  # lines the same key, whatever their comments.
  blob = line: lib.elemAt (lib.splitString " " line) 1;
  # Every word of the account's own key lines, options or not, and of its
  # signing key: a deploy key whose blob is among them is a key the account
  # logs in or signs with. (Key files the account names are not read.)
  accountWords = lib.concatMap (lib.splitString " ") (
    account.openssh.authorizedKeys.keys ++ [ config.ravnix.user.signingKey ]
  );
  accountsKeys = lib.filter (key: lib.elem (blob key) accountWords) cfg.deployKeys;

  # Groups whose members are root by another door: the disk devices, a
  # container or VM daemon that runs what they ask as root, and root's own
  # group.
  rootEquivalent = [
    "root"
    "disk"
    "docker"
    "lxd"
    "incus-admin"
    "libvirtd"
  ];
  groups = lib.unique (
    [ account.group ]
    ++ account.extraGroups
    ++ lib.attrNames (lib.filterAttrs (_: g: lib.elem user g.members) config.users.groups)
  );
  badGroups = lib.intersectLists rootEquivalent groups;

  # A user's ways to a password, each null on the server, for the account
  # and for root. A password set by hand (passwd) lives in /etc/shadow,
  # which users.mutableUsers keeps across deploys and no assertion sees.
  passwordsOf =
    u:
    lib.filter (option: u.${option} != null) [
      "hashedPassword"
      "password"
      "hashedPasswordFile"
      "initialPassword"
      "initialHashedPassword"
    ];
  passwords = passwordsOf account;
  rootPasswords = passwordsOf config.users.users.root;

  # Every way nix.conf can name a user Nix trusts or turn signatures off, and
  # a file it includes, which could do either out of sight.
  trustedUsers = config.nix.settings.trusted-users;
  extraTrustedUsers = config.nix.settings.extra-trusted-users or [ ];
  trustedLine = lib.hasInfix "trusted-users" config.nix.extraOptions;
  sigsLine = lib.hasInfix "require-sigs" config.nix.extraOptions;
  includes = lib.filter (line: builtins.match "[[:space:]]*!?include([[:space:]].*)?" line != null) (
    lib.splitString "\n" config.nix.extraOptions
  );

  sshd = config.services.openssh;
  # sshd takes the first value of a keyword, case-insensitively, and reads
  # services.openssh.settings before extraConfig, which starts with the
  # module's own AuthorizedKeysFile line: a key source anywhere else wins
  # over it, a Match block included. TrustedUserCAKeys lets in any
  # certificate of that CA naming root, without from= or restrict; an
  # Include brings in lines no assertion sees.
  keySourceKeywords = [
    "authorizedkeysfile"
    "authorizedkeyscommand"
    "trustedusercakeys"
    "include"
  ];
  keySourceSettings = lib.filter (name: lib.elem (lib.toLower name) keySourceKeywords) (
    lib.attrNames (lib.filterAttrs (_: value: value != null) sshd.settings)
  );
  keySourceLines = lib.filter (
    line:
    builtins.match "[[:space:]]*(authorizedkeysfile|authorizedkeyscommand|trustedusercakeys|include)([[:space:]=].*)?" (lib.toLower line)
    != null
  ) (lib.splitString "\n" sshd.extraConfig);

  # A sudoers text that lets someone in without a password: a NOPASSWD tag,
  # or authentication turned off.
  passwordless = text: lib.hasInfix "NOPASSWD" text || lib.hasInfix "!authenticate" text;
  sudo = config.security.sudo;
  sudoRs = config.security.sudo-rs;
  doas = config.security.doas;
in
{
  services.openssh.settings.PermitRootLogin = "prohibit-password";
  # Keys come from the configuration alone: a key in ~/.ssh/authorized_keys
  # would take no from= and no restrict, and an agent could plant one for
  # the account.
  services.openssh.authorizedKeysInHomedir = false;
  users.users.root.openssh.authorizedKeys.keys = lines;

  assertions = [
    {
      assertion = accountsKeys == [ ];
      message = "ravnix.server.deployKeys holds a key of the account (one it logs in with, or ravnix.user.signingKey): ${toString accountsKeys}. A deploy key is root's; give it a key of its own that the account and its agent never hold.";
    }
    {
      assertion =
        lib.subtractLists lines root.keys == [ ]
        && root.keyFiles == [ ]
        && sshd.authorizedKeysFiles == [ "/etc/ssh/authorized_keys.d/%u" ]
        && sshd.authorizedKeysCommand == "none"
        && keySourceSettings == [ ]
        && keySourceLines == [ "AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u" ];
      message = "root takes a key that is not in ravnix.server.deployKeys: through users.users.root.openssh.authorizedKeys, a key file sshd reads besides /etc/ssh/authorized_keys.d (services.openssh.authorizedKeysInHomedir or authorizedKeysFiles), services.openssh.authorizedKeysCommand, or AuthorizedKeysFile, AuthorizedKeysCommand, TrustedUserCAKeys (certificates, which take no from= or restrict) or an Include in services.openssh.settings or extraConfig (a Match block included). Put deploy keys in ravnix.server.deployKeys, which limits each to ravnix.server.deployFrom.";
    }
    {
      assertion = passwords == [ ];
      message = "the account ${user} has a password (users.users.${user}.${lib.concatStringsSep ", " passwords}). With one, wheel's sudo opens with it, and an agent that runs as the account can catch it the first time it is typed. Leave the account without; the way into a server that refuses every key is the hypervisor's guest agent.";
    }
    {
      assertion = rootPasswords == [ ];
      message = "root has a password (users.users.root.${lib.concatStringsSep ", " rootPasswords}). Typed into su in a session of the account, an agent can catch it, as it can the account's. Leave root without; the way into a server that refuses every key is the hypervisor's guest agent. In a NixOS test, the test framework sets users.users.root.hashedPasswordFile to an empty password: set it to lib.mkForce null there.";
    }
    {
      assertion = config.nix.settings.require-sigs != false && !sigsLine;
      message = "require-sigs is off (nix.settings.require-sigs, or a require-sigs line in nix.extraOptions). Nix then takes unsigned store paths from every user, the right that makes a trusted user root: an agent on the server could put a path of its own into the next system. Keep it on; root, whom Nix trusts, copies unsigned paths with --no-check-sigs.";
    }
    {
      assertion = includes == [ ];
      message = "nix.extraOptions includes another file (${lib.concatStringsSep "; " includes}), which could name trusted users or turn require-sigs off where the server's assertions cannot see it. Put trusted-users and require-sigs in nix.settings; a secret such as access-tokens goes outside the store, in root's ~/.config/nix/nix.conf or the NIX_CONFIG of the unit that needs it, never in nix.settings or nix.extraOptions, which end up in the world-readable store.";
    }
    {
      assertion = trustedUsers == [ "root" ] && extraTrustedUsers == [ ] && !trustedLine;
      message = "Nix trusts more users than root: trusted-users is ${toString trustedUsers}${
        lib.optionalString (extraTrustedUsers != [ ]) ", extra-trusted-users is ${toString extraTrustedUsers}"
      }${
        lib.optionalString trustedLine ", and nix.extraOptions has a trusted-users line"
      }. A trusted Nix user can have the daemon run code as root; deploy as root instead (ravnix.server.deployKeys).";
    }
    {
      assertion = !(sudo.enable && (!sudo.wheelNeedsPassword || passwordless sudo.configFile));
      message = "sudo lets someone in without a password (wheelNeedsPassword, a NOPASSWD rule, or !authenticate). On the server that makes the account root, and with it every agent; deploy as root instead (ravnix.server.deployKeys).";
    }
    {
      assertion = !(sudoRs.enable && (!sudoRs.wheelNeedsPassword || passwordless sudoRs.configFile));
      message = "sudo-rs lets someone in without a password (wheelNeedsPassword, a NOPASSWD rule, or !authenticate). On the server that makes the account root; deploy as root instead (ravnix.server.deployKeys).";
    }
    {
      assertion =
        !(
          doas.enable
          && (
            !doas.wheelNeedsPassword
            || lib.any (r: r.noPass or false) doas.extraRules
            || lib.hasInfix "nopass" doas.extraConfig
          )
        );
      message = "doas lets someone in without a password (wheelNeedsPassword, noPass, or nopass). On the server that makes the account root; deploy as root instead (ravnix.server.deployKeys).";
    }
    {
      assertion = !config.security.pam.sshAgentAuth.enable && !config.security.pam.rssh.enable;
      message = "security.pam.sshAgentAuth or security.pam.rssh lets sudo take a signature from the ssh agent instead of a password. On the server the agent is the account's, so that makes the account root.";
    }
    {
      assertion = badGroups == [ ];
      message = "the account ${user} is in ${toString badGroups}, which is root by another door. Leave it out of the group on the server.";
    }
  ];
}
