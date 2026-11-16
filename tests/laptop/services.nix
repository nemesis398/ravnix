# The system services huginn runs, evaluated as the private flake will build
# it, with the template's values and no build: what Fedora runs that a
# NixOS laptop does not run by itself. The shape alone gets each of them, with
# or without a hardware module (they are the laptop's, not one model's).
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        ../../templates/default/me.nix
        { system.stateVersion = "26.05"; }
      ]
      ++ modules;
    };
  huginn = build [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  # The shape without a hardware module, as a second laptop model would use it.
  bare = build [
    self.nixosModules.laptop
    { nixpkgs.hostPlatform = system; }
  ];
  check = cond: msg: lib.optional (!cond) msg;

  # What each system must have, said once for both.
  each =
    name: s:
    let
      c = s.config;
    in
    # systemd-oomd on the root slice and on the user slices, as Fedora has
    # it, so a runaway build is killed before the machine thrashes.
    check c.systemd.oomd.enable "${name}: systemd-oomd is off"
    ++ check c.systemd.oomd.enableRootSlice "${name}: systemd-oomd does not watch the root slice"
    ++ check c.systemd.oomd.enableUserSlices "${name}: systemd-oomd does not watch the user slices";

  failures = each "huginn" huginn ++ each "the shape without a hardware module" bare;
in
pkgs.runCommand "laptop-services" { } (
  if failures == [ ] then
    ''
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
