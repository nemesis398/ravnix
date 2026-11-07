# What development on the server needs: Podman, which runs the dev containers
# as the user (rootless, no daemon), and the toolchains: uv for Python, node,
# cargo with rustc and a C compiler to link with, and odin. lazygit comes with
# the common module. Nothing of the laptop's graphical side is installed.
#
# There is one Odin: the one lib/odin.nix builds ravnix's tools with, so the
# compiler the user types is the compiler the tools were tested with.
#
# Podman keeps its images and containers in the user's home directory, so on
# the OCI form they live on the home volume. There is no `docker` command on
# purpose; a tool that wants one is a reason to add dockerCompat, not a
# default.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.ravnix.user.username;
  inherit (import ../../lib/odin.nix { inherit pkgs lib; }) odin;
in
{
  virtualisation.podman.enable = true;

  home-manager.users.${user}.home.packages = [
    pkgs.uv
    pkgs.nodejs
    pkgs.cargo
    pkgs.rustc
    pkgs.gcc
    odin
  ];
}
