# ccna-deck: builds the CCNA Anki deck from the vault's own card notes.
# Carried over from Fedora's bin-ccna-deck and still Python (AGENTS.md, rule
# 4); README.md has what changed. The script declared genanki as a PEP 723
# dependency for `uv run`; here genanki is nixpkgs' and uv is not involved.
# The embedded fonts and diagrams.py (which draws the deck's SVG diagrams) are
# the package's data, where the script looks for them: ../share/ccna-deck.
{
  lib,
  stdenvNoCC,
  python3,
  python3Packages,
}:
let
  python = python3.withPackages (ps: [ ps.genanki ]);
in
stdenvNoCC.mkDerivation {
  pname = "ccna-deck";
  version = "0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./ccna-deck.py
      ./diagrams.py
      ./fonts
    ];
  };
  nativeBuildInputs = [ python3Packages.flake8 ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    # The original fails flake8 on these and is left as it was:
    #   E501  lines past 79 characters (46 of them)
    #   W503  line breaks before binary operators (15), which flake8's
    #         defaults ignore; giving an ignore list replaces the defaults
    # diagrams.py is data, not a command, and fails E501, E741 and F841; it is
    # checked to compile.
    flake8 --ignore=E501,W503 ccna-deck.py
    python -m py_compile diagrams.py
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 ccna-deck.py $out/bin/ccna-deck
    substituteInPlace $out/bin/ccna-deck \
      --replace-fail '#!/usr/bin/env -S uv run --script' '#!${python}/bin/python3'
    install -Dm644 -t $out/share/ccna-deck fonts/*.woff2 diagrams.py
    runHook postInstall
  '';
  meta = {
    description = "Builds the CCNA Anki deck from a vault's card notes";
    license = lib.licenses.agpl3Plus;
    mainProgram = "ccna-deck";
  };
}
