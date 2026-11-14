# The Claude Code skills on the two shapes (modules/glue/claude-skills.nix),
# evaluated as the private flake builds them, with the template's values:
# the laptop skill, the manual for changing and switching the laptop, is
# linked on the laptop only, so a session on the server is never offered a
# switch to the laptop's system; every other skill is linked on both, and a
# skill of the private flake's still reaches the server. The laptop's own
# networking.hostName is the skill value laptop.hostName, which the skill's
# switch step compares with the host it runs on.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  me = ../../templates/default/me.nix;
  user = (import me).ravnix.user.username;
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
        }
      ]
      ++ modules;
    };
  server = [ self.nixosModules.server ];
  laptop = [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  own = { ravnix.claude.skills.own-skill = ../claude/fixtures/own-skill; };
  m = (build (server ++ [ own ])).config;
  h = (build (laptop ++ [ own ])).config;
  hNamed = (build (laptop ++ [ { networking.hostName = "raven"; } ])).config;
  hostValue = c: (hm c).ravnix.claude.skillValues.laptop.hostName or null;

  hm = c: c.home-manager.users.${user};
  linked =
    c: name:
    (hm c).home.file ? "${(hm c).programs.claude-code.configDir}/skills/${name}";

  check = cond: msg: lib.optional (!cond) msg;
  failures =
    check (!linked m "laptop") "the server links the laptop skill: its switch would put the laptop's system on the server"
    ++ check (linked h "laptop") "the laptop does not link the laptop skill"
    ++ check (lib.all (linked m) [ "handoff" "journal" "prose" ]) "the server lost a skill other than laptop"
    ++ check (lib.all (linked h) [ "handoff" "journal" "prose" ]) "the laptop lost a skill other than laptop"
    ++ check (linked m "own-skill" && linked h "own-skill") "a skill of the private flake's does not reach both shapes"
    ++ check (hostValue h == h.networking.hostName) "the laptop skill's laptop.hostName is ${toString (hostValue h)}, not the host's name ${h.networking.hostName}"
    ++ check (hostValue hNamed == "raven") "a laptop named raven renders laptop.hostName ${toString (hostValue hNamed)}";
in
pkgs.runCommand "glue-claude-skills-shapes" { } (
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
