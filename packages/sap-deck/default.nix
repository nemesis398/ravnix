# sap-deck: builds the SAP Anki deck from the vault's own SAP notes.
# Carried over from Fedora's bin-sap-deck and still Python (AGENTS.md, rule
# 4); README.md has what changed. The script declared genanki as a PEP 723
# dependency for `uv run`; here genanki is nixpkgs' and uv is not involved.
# The embedded fonts are the package's data, where the script looks for them:
# ../share/sap-deck.
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
  pname = "sap-deck";
  version = "0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./sap-deck.py
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
    #   E501  lines past 79 characters (36 of them)
    #   E306  one nested definition without a blank line before it
    #   W503  line breaks before binary operators (13), which flake8's
    #         defaults ignore; giving an ignore list replaces the defaults
    flake8 --ignore=E501,E306,W503 sap-deck.py
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 sap-deck.py $out/bin/sap-deck
    substituteInPlace $out/bin/sap-deck \
      --replace-fail '#!/usr/bin/env -S uv run --script' '#!${python}/bin/python3'
    install -Dm644 -t $out/share/sap-deck fonts/*.woff2
    runHook postInstall
  '';
  meta = {
    description = "Builds the SAP Anki deck from a vault's SAP notes";
    license = lib.licenses.agpl3Plus;
    mainProgram = "sap-deck";
  };
}
