# The Claude Code skills by shape. The laptop skill is the manual for
# changing and switching the laptop, huginn; on any other shape it is left
# out, so a session on the server is never offered a switch to the laptop's
# system. Its own switch step refuses on a host that is not huginn as well
# (claude/skills/laptop/SKILL.md). The NixOS definition reaches
# home-manager through the forwarding of modules/common/nixos.nix, beside
# the private flake's own skills.
{ config, lib, ... }:
{
  config = lib.mkIf (config.ravnix.shape != null && config.ravnix.shape != "laptop") {
    ravnix.claude.skills.laptop = null;
  };
}
