# The Copilot key's filter in huginn's configuration, evaluated as the private
# flake builds huginn, with the template's values (keys.nix): the service
# runs the copilot-key-super package as Fedora's unit did (restart on
# failure after 2 s, at most 5 starts in 60 s, wanted by multi-user.target),
# hardened, with the input nodes and /dev/uinput still open to it; the
# uinput module, its group and its udev rule; and the virtual device's
# vendor, product and name in the tool the same as in Sway's config, which
# finds the device by them. tests/hardware/copilot-key-vm.nix runs it.
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  huginn = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ../../templates/default/me.nix
      { system.stateVersion = "26.05"; }
      self.nixosModules.laptop
      self.nixosModules.hardware-ideapad-pro-5-16ahp9
    ];
  };
  c = huginn.config;
  unit = c.systemd.services.copilot-key-super or null;
  sc = if unit == null then { } else unit.serviceConfig;
  text = c.systemd.units."copilot-key-super.service".text or "";
  lines = lib.splitString "\n" text;
  has = line: lib.elem line lines;
  check = cond: msg: lib.optional (!cond) msg;

  keysImported = lib.any (m: lib.hasSuffix "/modules/hardware/ideapad-pro-5-16ahp9/keys.nix" (toString m.key)) (
    let
      walk = lib.concatMap (m: lib.optionals (!m.disabled) ([ m ] ++ walk m.imports));
    in
    walk huginn.graph
  );
  ravnixPkgs = pkgs.extend self.overlays.default;
  tool = ravnixPkgs.ravnix.copilot-key-super;
  rules = c.services.udev.extraRules;
  source = builtins.readFile ../../tools/copilot-key-super/device.odin;
  sway = builtins.readFile ../../modules/desktop/sway/config;

  failures =
    check keysImported "huginn does not import the IdeaPad's keys.nix"
    ++ check (unit != null) "huginn has no copilot-key-super service"
    ++ check (lib.elem "multi-user.target" (unit.wantedBy or [ ])) "copilot-key-super is not wanted by multi-user.target"
    ++ check (
      builtins.unsafeDiscardStringContext (sc.ExecStart or "")
      == builtins.unsafeDiscardStringContext (lib.getExe tool)
    ) "copilot-key-super runs ${sc.ExecStart or "nothing"}, not the copilot-key-super package"
    ++ check (has "Restart=on-failure") "copilot-key-super does not restart on failure"
    ++ check (has "RestartSec=2") "copilot-key-super does not wait 2 s before a restart"
    ++ check (has "StartLimitBurst=5") "copilot-key-super may start more than 5 times"
    ++ check (has "StartLimitIntervalSec=60") "copilot-key-super's start limit is not over 60 s"
    ++ check (has "Type=simple") "copilot-key-super is not Type=simple"

    # The hardening, and the holes it must keep: the input nodes to read and
    # grab, /dev/uinput to write. PrivateDevices would hide both.
    ++ check (has "DynamicUser=true") "copilot-key-super runs as root, not as a dynamic user"
    ++ check (has "SupplementaryGroups=input" && has "SupplementaryGroups=uinput") "copilot-key-super is not in the input and uinput groups"
    ++ check (has "DevicePolicy=closed") "copilot-key-super's device policy is not closed"
    ++ check (has "DeviceAllow=char-input r") "copilot-key-super cannot read the input nodes"
    ++ check (has "DeviceAllow=/dev/uinput w") "copilot-key-super cannot write /dev/uinput"
    ++ check (!(sc.PrivateDevices or false)) "PrivateDevices hides /dev/input and /dev/uinput from copilot-key-super"
    ++ check (has "CapabilityBoundingSet=") "copilot-key-super keeps capabilities"
    ++ check (has "PrivateNetwork=true") "copilot-key-super has the network"
    ++ check (has "ProtectSystem=strict") "copilot-key-super can write the system"
    ++ check (has "NoNewPrivileges=true") "copilot-key-super can gain privileges"

    # The uinput module, and /dev/uinput for its group.
    ++ check c.hardware.uinput.enable "hardware.uinput is off"
    ++ check (lib.elem "uinput" c.boot.kernelModules) "the uinput module is not loaded at boot"
    ++ check (c.users.groups ? uinput) "there is no uinput group"
    ++ check (lib.hasInfix ''KERNEL=="uinput", MODE="0660", GROUP="uinput"'' rules) "no udev rule gives /dev/uinput to the uinput group"

    # Sway finds the virtual device as 1:1:copilot-key-super.
    ++ check (lib.hasInfix ''input "1:1:copilot-key-super"'' sway) "Sway's config has no block for 1:1:copilot-key-super"
    ++ check (lib.hasInfix ''VIRTUAL_NAME :: "copilot-key-super"'' source) "the tool's virtual device is not named copilot-key-super"
    ++ check (lib.hasInfix "VIRTUAL_VENDOR :: 1\n" source) "the tool's virtual device's vendor is not 1"
    ++ check (lib.hasInfix "VIRTUAL_PRODUCT :: 1\n" source) "the tool's virtual device's product is not 1";
in
pkgs.runCommand "hardware-copilot-key" { } (
  if failures == [ ] then
    ''
      echo "huginn runs copilot-key-super, hardened, with uinput" > $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
