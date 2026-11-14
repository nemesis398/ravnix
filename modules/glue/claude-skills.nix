# The Claude Code skills by shape. The laptop skill is the manual for
# changing and switching the laptop, huginn; on any other shape it is left
# out, so a session on the server is never offered a switch to the laptop's
# system. On the laptop its switch step compares the host it runs on with
# the skill value laptop.hostName, which is the laptop's own
# networking.hostName, and refuses on any other (claude/skills/laptop/
# SKILL.md). Both NixOS definitions reach home-manager through the
# forwarding of modules/common/nixos.nix, beside the private flake's own.
{ config, lib, ... }:
let
  shape = config.ravnix.shape;
in
{
  config = lib.mkMerge [
    (lib.mkIf (shape != null && shape != "laptop") {
      ravnix.claude.skills.laptop = null;
    })
    (lib.mkIf (shape == "laptop") {
      ravnix.claude.skillValues.laptop.hostName = lib.mkDefault config.networking.hostName;
    })
  ];
}
