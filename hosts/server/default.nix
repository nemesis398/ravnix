# The server shape, muninn: what every ravnix server is, whatever it runs on.
# The common module (shell, user, home-manager), the workbench and the glue
# on top (the glue takes its server end from ravnix.shape, set here), an
# ssh daemon that takes keys only, and Nix with flakes, so the host can build
# and switch itself. How it boots is the business of its image (a Proxmox VM,
# an OCI image), which the private flake or Task 4.2 and 4.4 add beside this
# one, so a second form is a new module and not a new shape:
#
#   modules = [
#     ravnix.nixosModules.server
#     ./muninn-vm.nix
#     ./me.nix
#   ];
#
# It is a function of the flake, `import ./hosts/server { inherit self; }`
# (flake.nix, where it also gets a key), for the modules it brings along.
#
# Not set here, because they are the host's to decide: who may log in (the
# account has no password, so keys go in users.users.<user>.openssh), whether
# wheel may use sudo, which users Nix trusts, and the time zone.
{ self }:
{ ... }:
{
  imports = [
    self.nixosModules.common
    self.nixosModules.workbench
    self.nixosModules.glue
  ];

  ravnix.shape = "server";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
}
