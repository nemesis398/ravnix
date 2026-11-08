# backdrop and lock-screen: the wallpaper and the lock image of the desktop.
# packages/backdrop/README.md says what they draw and how they are called;
# modules/desktop/backdrop.nix installs them and writes the config they read.
#
# `backdrop` is Python (cairo, Pango and librsvg through PyGObject) and stays
# so until the Odin port of the bin-* scripts. Both commands keep the names
# they have on Fedora, because the kanshi profiles and the lock binding call
# them by name.
#
# The wrappers carry what the scripts run:
#   - GI_TYPELIB_PATH for the typelibs, and BACKDROP_ASSETS for the marks;
#   - fastfetch, and bash and coreutils for the way it is started, behind the
#     PATH of the session (--suffix), so the user's own fastfetch is the one
#     that runs when there is one;
#   - swaymsg and swaylock the same way. The session's sway and swaylock come
#     first, and these are the fallback, so a swaylock from the sway module
#     with extra options is the one that locks.
# `sway` and `swaylock` are arguments so that the tests can build the package
# with stand-ins and not pull a compositor into a check.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  glib,
  gobject-introspection,
  pango,
  harfbuzz,
  gdk-pixbuf,
  librsvg,
  fastfetch,
  bash,
  coreutils,
  procps,
  util-linux,
  sway-unwrapped,
  swaylock,
}:
let
  python = python3.withPackages (ps: [
    ps.pycairo
    ps.pygobject3
  ]);

  # The libraries whose typelibs backdrop imports (Rsvg, Pango, PangoCairo,
  # GdkPixbuf) and the ones those need (GLib, GObject, Gio, cairo, HarfBuzz).
  typelibPath = lib.makeSearchPath "lib/girepository-1.0" (
    map lib.getLib [
      glib
      gobject-introspection
      pango
      harfbuzz
      gdk-pixbuf
      librsvg
    ]
  );
in
stdenvNoCC.mkDerivation {
  pname = "backdrop";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./backdrop
      ./lock-screen
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bash ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 backdrop $out/libexec/backdrop/backdrop
    install -Dm755 lock-screen $out/libexec/backdrop/lock-screen
    # The marks the scripts draw: the phyllon mark today, and the ravnix mark
    # when it ships (README.md here says what the scripts do with it).
    install -Dm644 ${../../assets/phyllon-mark.svg} $out/share/backdrop/phyllon-mark.svg
    patchShebangs $out/libexec/backdrop/lock-screen

    makeWrapper ${python}/bin/python3 $out/bin/backdrop \
      --add-flags $out/libexec/backdrop/backdrop \
      --set GI_TYPELIB_PATH ${typelibPath} \
      --set-default BACKDROP_ASSETS $out/share/backdrop \
      --set PYTHONDONTWRITEBYTECODE 1 \
      --suffix PATH : ${
        lib.makeBinPath [
          fastfetch
          bash
          coreutils
          sway-unwrapped
        ]
      }

    makeWrapper $out/libexec/backdrop/lock-screen $out/bin/lock-screen \
      --prefix PATH : $out/bin \
      --suffix PATH : ${
        lib.makeBinPath [
          swaylock
          coreutils
          procps
          util-linux
        ]
      }

    runHook postInstall
  '';

  passthru = {
    # What a test that imports backdrop's modules needs: the interpreter with
    # its Python packages, and the typelibs.
    inherit python typelibPath;
  };

  meta = {
    description = "The wallpaper and the lock image of the desktop, in the theme";
    license = lib.licenses.agpl3Plus;
    mainProgram = "backdrop";
    platforms = lib.platforms.linux;
  };
}
