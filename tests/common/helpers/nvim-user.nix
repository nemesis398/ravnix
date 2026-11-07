# The home-manager configuration of a user of the editor module, for the tests
# that evaluate it: ravnix's options with the values of the template (the
# fixtures of every test that evaluates them), the module under test, and
# whatever the test adds. Being in a subdirectory of an area, this file is no
# check itself (lib/discover-checks.nix).
#
#   nvimUser = import ./helpers/nvim-user.nix { inherit self lib; };
#   nvimUser extra              a module; extra is another module
#
# The template's values are placeholders and say so in a warning, for each
# user and on every evaluation, so the warnings are dropped here. A warning
# of the module itself would go with them; tests/common/nvim.nix evaluates the
# module once more, with no placeholder, and refuses any warning there.
{ self, lib }:
extra: {
  imports = [
    self.homeModules.options
    (self + "/templates/default/me.nix")
    ../../../modules/common/nvim.nix
    extra
  ];
  home.stateVersion = "26.05";
  warnings = lib.mkForce [ ];
}
