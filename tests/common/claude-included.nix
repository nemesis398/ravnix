# homeModules.common brings Claude Code along: the package, its hooks and the
# skill framework, through its import of homeModules.claude-skills. The
# `claude` function of the shell (modules/common/bash/secrets.bash) starts
# that build, so a host that imports only common must have it.
#
# The home here is the helper's: homeModules.common, the options and the theme,
# and the template's me.nix, which sets no skill value. It must evaluate
# without one, so importing claude-skills makes no skill value mandatory for a
# user who has no reason to set one (the skills name the key they miss when
# they run).
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hm = import ./helpers/hm.nix {
    inherit
      self
      inputs
      pkgs
      lib
      ;
  };
  package = self.packages.${system}.claude-code;

  base = (hm [ ]).config;
  # The modules listed again, beside common, as a user or a host may.
  again =
    (hm [
      self.homeModules.claude-code
      self.homeModules.claude-skills
      self.homeModules.common
    ]).config;

  failed = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);
  onPath = c: lib.any (p: p.outPath == package.outPath) c.home.packages;

  failures = lib.flatten [
    (map (m: "homeModules.common alone fails: ${m}") (failed base))
    (lib.optional (!base.programs.claude-code.enable) "homeModules.common does not turn Claude Code on")
    (lib.optional (
      base.programs.claude-code.enable
      && base.programs.claude-code.finalPackage.outPath != package.outPath
    ) "homeModules.common does not install packages.claude-code")
    (lib.optional (!onPath base) "packages.claude-code is not on the PATH of homeModules.common")
    (lib.optional (
      (base.ravnix.claude.hookEntries or { }) == { }
    ) "homeModules.common wires no Claude Code hook (homeModules.claude-skills is not imported)")
    (lib.optional (
      !(base.home.sessionVariables ? RAVNIX_SKILL_VALUES)
    ) "homeModules.common does not name the skill values")
    (lib.optional (
      base.ravnix.claude.skillValues != { }
    ) "the template sets a skill value, which would hide a mandatory one")

    # Listed again, the modules add nothing a second time.
    (map (m: "common with claude-code and claude-skills listed again fails: ${m}") (failed again))
    (lib.optional (
      again.ravnix.claude.hookEntries != (base.ravnix.claude.hookEntries or { })
    ) "listing claude-skills again changes the hook entries")
    (lib.optional (
      again.programs.bash.initExtra != base.programs.bash.initExtra
    ) "listing claude-skills again changes the bashrc")
    (lib.optional (
      again.home.packages != base.home.packages
    ) "listing claude-code again changes the packages")
  ];
in
pkgs.runCommand "common-claude-included" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
