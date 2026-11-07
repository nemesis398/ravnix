# ravnix-dev-checkout, what the home-manager activation runs for
# ravnix.dev.checkout: it turns the git hooks on in the checkout and points
# them at the deny list. The scenarios are in helpers/dev-checkout.test.bash.
{
  self,
  pkgs,
  ...
}:
let
  dev-checkout = pkgs.callPackage ../../modules/common/dev-checkout.nix { };
in
pkgs.runCommand "common-dev-checkout"
  {
    nativeBuildInputs = [
      dev-checkout
      pkgs.git
    ];
  }
  ''
    export HOME="$TMPDIR"
    bash ${self}/tests/common/helpers/dev-checkout.test.bash
    touch $out
  ''
