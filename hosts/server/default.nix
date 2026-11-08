# The server shape, muninn: what every ravnix server is, whatever it runs on.
# The common module (shell, user, home-manager), the workbench and the glue
# on top (the glue takes its server end from ravnix.shape, set here), an
# ssh daemon that takes keys only, and Nix with flakes, so the host can build
# and switch itself. How it boots is the business of its form: as a virtual
# machine, nixosModules.server-vm beside this one (./images.nix: the disk
# layout and the qcow2, VMDK and OVA images). Another form is a new module
# and not a new shape:
#
#   modules = [
#     ravnix.nixosModules.server
#     ravnix.nixosModules.server-vm
#     ./muninn-vm.nix
#     ./me.nix
#   ];
#
# It is a function of the flake, `import ./hosts/server { inherit self; }`
# (flake.nix, where it also gets a key), for the modules it brings along.
#
# How a deploy logs in (./deploy.nix): as root, over ssh, with a key of
# ravnix.server.deployKeys, from an address of ravnix.server.deployFrom.
# `nixos-rebuild switch --target-host root@HOST` and `nix copy
# --no-check-sigs --to ssh-ng://root@HOST` then need nothing else, because
# root is the one user Nix trusts and the one who may switch the system.
# With no deploy key, root takes no key at all, and sshd never takes a
# password from anyone.
#
# Why not the account with sudo and a place among Nix's trusted users: both
# would make the account root, and with it every program that runs as the
# account, which on the server are the agents and their sessions. A trusted
# Nix user can have the daemon run a hook as root, and sudo for
# nixos-rebuild's commands takes a store path the user chooses. Root's login
# needs a deploy key instead. So the account keeps no password, wheel keeps
# needing one, Nix trusts root alone, and ./deploy.nix asserts these and the
# rest of what it can see. from= on each deploy key closes the way from the
# server itself, and from and through every host outside deployFrom; it
# cannot keep the key's holder from deploying from an allowed address, so
# the key stays off the server.
#
# Still the host's to decide: who logs in as the account (its keys go in
# users.users.<user>.openssh), who deploys, and the time zone.
{ self }:
{ ... }:
{
  # The shape is a module a function returns, so without this its
  # definitions would carry the file of the caller, nixpkgs' flake.nix, and an
  # error such as the conflict of two shapes would name that file.
  _file = ./default.nix;

  imports = [
    self.nixosModules.common
    self.nixosModules.workbench
    self.nixosModules.glue
    ./deploy.nix
  ];

  ravnix.shape = "server";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
