# The server side of ravnix, for NixOS: what muninn runs for you while the
# laptop is shut. herdr's server, aerc for mail, iamb for Matrix, khal and
# vdirsyncer for the calendar, Podman and the toolchains for development, a
# copy of your Nextcloud, and Claude Code's Remote Control for the phone.
#
# It builds on the common module (shell, git, Claude Code, the account),
# which it imports under its key, so a host that lists both gets one copy; it
# repeats nothing of it. Each file here is a NixOS module that also adds to
# the user's home-manager configuration. The program is the host's package,
# and the user units run it through the user's profile
# (/etc/profiles/per-user/<user>/bin), so a new package reaches a unit when it
# restarts and the unit's text does not change with it.
#
# Everything personal is a typed option of modules/options (ravnix.nextcloud,
# ravnix.mail, ravnix.calendar, ravnix.matrix, ravnix.server). A password is
# never one: an option names the Bitwarden item, and rbw reads it when the
# unit runs. See README.md for the steps that cannot be declared (the first
# login of iamb and of Claude Code, and unlocking the vault).
{ self }:
{ config, ... }:
let
  user = config.ravnix.user.username;
in
{
  imports = [
    self.nixosModules.common
    ./calendar.nix
    ./dev.nix
    ./herdr.nix
    ./mail.nix
    ./matrix.nix
    ./nextcloud-sync.nix
    ./remote-control.nix
    ./ssh-agent.nix
  ];

  # The units below are the server's work, and it does it with nobody logged
  # in: the user's manager starts at boot and keeps running.
  users.users.${user}.linger = true;
}
