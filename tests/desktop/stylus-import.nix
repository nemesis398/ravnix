# The Stylus import file (lib/stylus-import.nix), run on a stand-in for the
# official import.json: this checkout has no copy of the real file, so the
# stand-in has the shape the transform relies on (a JSON array of styles, each
# UserCSS style with select variables lightFlavor, darkFlavor and accentColor
# under usercssData.vars, each holding its options and a value), and the check
# says what it proves and what it does not.
#
#   - Every flavor becomes mocha, the accent becomes the given one, in every
#     style that has the variables; entries without them, other variables,
#     and everything else in a style (the source, the digest) stay as they are.
#   - A style that has no accentColor of its own still gets its flavors.
#   - A variable that does not offer the option, a file that is no array, and
#     a file in which no style has an accentColor (the shape is not the one
#     assumed) each stop the build.
#   - A desktop host with ravnix.apps.userstylesImport puts the result at
#     ~/.local/share/ravnix/stylus-import.json in its accent; a host without
#     the option installs nothing there.
#
# NOT proved: that Stylus reads `value` the way this sets it, and that the real
# import.json is shaped like the stand-in. Import the file on huginn once and
# look at a style's settings.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  make = pkgs.callPackage ../../lib/stylus-import.nix { };

  select = default: names: {
    type = "select";
    inherit default;
    value = null;
    options = map (n: {
      name = n;
      label = n;
      value = n;
    }) names;
  };
  flavors = [
    "latte"
    "frappe"
    "macchiato"
    "mocha"
  ];
  accents = [
    "rosewater"
    "mauve"
    "teal"
  ];
  style = name: vars: {
    enabled = true;
    inherit name;
    sourceCode = "/* ==UserStyle== */ body { color: red; }";
    originalDigest = "abc123";
    usercssData = {
      inherit name vars;
      preprocessor = "stylus";
    };
  };
  full = style "github" {
    lightFlavor = select "latte" flavors;
    darkFlavor = select "mocha" flavors;
    accentColor = select "mauve" accents;
    other = select "x" [ "x" "y" ];
  };
  noAccent = style "plain" { darkFlavor = select "mocha" flavors; };
  notUserCss = {
    enabled = true;
    name = "hand-written";
    sections = [ { code = "a {}"; } ];
  };
  file = entries: pkgs.writeText "import.json" (builtins.toJSON entries);

  good = make {
    src = file [
      full
      noAccent
      notUserCss
    ];
    accent = "teal";
  };
  failing = name: entries: accent: pkgs.testers.testBuildFailure (make { src = file entries; inherit accent; });

  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  mkHost =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.desktop ] ++ extra;
    };
  withImport = mkHost [
    {
      ravnix.apps.userstylesImport = lib.mkForce (file [ full ]);
      ravnix.theme.accent = lib.mkForce "teal";
    }
  ];
  withoutImport = mkHost [ ];
  dataOf = h: h.config.home-manager.users.${h.config.ravnix.user.username}.xdg.dataFile;
in
assert
  !(dataOf withoutImport ? "ravnix/stylus-import.json") || throw "a host without the option installs an import file";
assert
  (dataOf withImport)."ravnix/stylus-import.json".source.name == "stylus-import.json"
  || throw "the host with the option does not install the import file";
pkgs.runCommand "desktop-stylus-import"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.gnugrep
    ];
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
    j() { jq -r "$1" ${good}; }

    [ "$(j '.[0].usercssData.vars | [.lightFlavor.value, .darkFlavor.value, .accentColor.value] | join(",")')" = "mocha,mocha,teal" ] \
      || fail "the full style is not mocha, mocha, teal"
    [ "$(j '.[1].usercssData.vars.darkFlavor.value')" = mocha ] || fail "the style without an accent keeps its flavor"
    [ "$(j '.[1].usercssData.vars | has("accentColor")')" = false ] || fail "the style without an accent got one"
    [ "$(j '.[0].usercssData.vars.other.value')" = null ] || fail "another variable was changed"

    # Everything but the three values is as it was.
    rest='del(.[].usercssData.vars.lightFlavor.value, .[].usercssData.vars.darkFlavor.value, .[].usercssData.vars.accentColor.value)'
    diff <(jq -S "$rest" ${good}) <(jq -S "$rest" ${file [ full noAccent notUserCss ]}) \
      || fail "something besides the three values changed"
    [ "$(j '.[2] == {enabled: true, name: "hand-written", sections: [{code: "a {}"}]}')" = true ] || fail "an entry that is no UserCSS style was changed"
    [ "$(j '.[0].sourceCode')" = "/* ==UserStyle== */ body { color: red; }" ] || fail "the source code was changed"

    # The stops.
    grep -rq 'has no option nope' ${failing "bad-accent" [ full ] "nope"} \
      || fail "an accent the variable does not offer did not stop the build with its name"
    grep -rq 'no style has an accentColor' ${failing "no-accent" [ noAccent notUserCss ] "teal"} \
      || fail "a file without an accentColor did not stop the build"
    grep -rq 'not a JSON array' ${failing "not-array" { a = 1; } "teal"} \
      || fail "a file that is no array did not stop the build"

    # The host.
    jq -e '.[0].usercssData.vars.accentColor.value == "teal"' ${(dataOf withImport)."ravnix/stylus-import.json".source} >/dev/null \
      || fail "the host's file is not in the host's accent"

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
