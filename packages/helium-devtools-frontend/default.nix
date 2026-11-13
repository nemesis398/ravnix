# Helium's own DevTools frontend in the theme, for Helium's
# --custom-devtools-frontend (packages/helium, `devtoolsFrontend`). Carried
# over from the Fedora setup (its repository's commit bc31106,
# stow/helium/.local/share/helium-devtools-theme); README.md says what changed.
#
# build-frontend.py reads the frontend's path table from the unpatched helium
# binary of Helium's tarball, extracts the files from resources.pak, links the
# two theme files into every HTML entry point and writes .complete last. The
# theme files are square-shadow-roots.js, as on Fedora, and the stylesheet that
# stylesheet.nix makes from `theme`. They sit beside the script in one store
# path, `themeDir`, which the frontend links to.
#
#   theme   { palette, roles, font } of config.ravnix.theme. The desktop module
#           passes the host's (modules/desktop/apps.nix); the default is the
#           theme module's own default, Mocha with the Mauve accent.
{
  lib,
  stdenvNoCC,
  runCommand,
  writeText,
  python3,
  ravnix,
  theme ? null,
}:
let
  # The theme module evaluated alone: its options and their defaults. It sets
  # `assertions`, which only NixOS and home-manager declare.
  defaultTheme =
    (lib.evalModules {
      modules = [
        ../../modules/theme/options.nix
        {
          options.assertions = lib.mkOption {
            type = lib.types.listOf lib.types.unspecified;
            default = [ ];
          };
        }
      ];
    }).config.ravnix.theme;

  stylesheet = writeText "catppuccin-mocha.css" (
    import ./stylesheet.nix {
      inherit lib;
      theme = if theme == null then defaultTheme else theme;
    }
  );

  # The script and the two theme files in one directory: the script links
  # the theme files from its own directory into the frontend.
  themeDir = runCommand "helium-devtools-theme" { } ''
    mkdir -p $out
    cp ${./build-frontend.py} $out/build-frontend.py
    cp ${./square-shadow-roots.js} $out/square-shadow-roots.js
    cp ${stylesheet} $out/catppuccin-mocha.css
  '';

  python = python3.withPackages (ps: [ ps.brotli ]);
in
stdenvNoCC.mkDerivation {
  pname = "helium-devtools-frontend";
  inherit (ravnix.helium) version src;

  nativeBuildInputs = [ python ];

  # Only the two files the script reads, from the tarball as it is: the
  # helium package runs patchelf on the binary, and the table is read here
  # from the original.
  unpackPhase = ''
    runHook preUnpack
    mkdir helium
    tar -xJf $src -C helium --strip-components=1 --wildcards '*/helium' '*/resources.pak'
    runHook postUnpack
  '';

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    python3 -I ${themeDir}/build-frontend.py helium/helium helium/resources.pak "$PWD/frontend"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mv frontend $out
    runHook postInstall
  '';

  dontFixup = true;

  passthru = {
    inherit stylesheet themeDir;
  };

  meta = {
    description = "Helium's DevTools frontend in the ravnix theme, for --custom-devtools-frontend";
    # The frontend is Chromium's (BSD-3-Clause); the theme files and the
    # script are ravnix's.
    license = with lib.licenses; [
      bsd3
      agpl3Plus
    ];
    platforms = [ "x86_64-linux" ];
  };
}
