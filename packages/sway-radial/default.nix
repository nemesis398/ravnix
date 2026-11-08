# sway-radial: the radial menu behind the four-finger pinch on the trackpad.
# packages/sway-radial/README.md says what it does and what ravnix changed in
# it; modules/desktop/sway-radial.nix runs it as a user service and writes the
# two files it reads (the menu and the theme).
#
# It is Python (GTK 4 and gtk4-layer-shell through PyGObject, cairo, and
# libinput through ctypes) and stays so until its port (Phase 13). The tree is
# installed as it is in the source directory, which is also the layout that
# the daemon's fallback to the packaged menu expects: the package in
# lib/sway-radial/sway_radial, the default menu one level above it.
#
# Three libraries are not found through a typelib but opened by name with
# ctypes (libinput, libudev and gtk4-layer-shell), and Python has no search
# path for them in a Nix store. A LD_LIBRARY_PATH in the wrapper would reach
# every program the menu starts, so the three names become store paths in the
# installed copy instead (--replace-fail: a source that no longer holds the
# string stops the build). The tests run on that copy.
#
# The wrapper carries what the daemon runs:
#   - GI_TYPELIB_PATH for GTK 4, gtk4-layer-shell and what those need;
#   - gtk-launch (a menu entry of kind `desktop` is started with it, so that
#     the flags of the .desktop file stay in one place) and swaymsg (every
#     other entry goes through `swaymsg exec`), behind the PATH of the
#     session (--suffix), so the session's sway is the one that answers.
# `sway-unwrapped` is an argument so that a test can build the package with a
# stand-in and not pull a compositor into a check.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  glib,
  gobject-introspection,
  gtk4,
  gtk4-layer-shell,
  graphene,
  pango,
  harfbuzz,
  gdk-pixbuf,
  libinput,
  systemdLibs,
  gtk3,
  sway-unwrapped,
}:
let
  python = python3.withPackages (ps: [
    ps.pycairo
    ps.pygobject3
  ]);

  # The libraries whose typelibs the daemon imports (Gtk 4, Gdk 4, the layer
  # shell) and the ones those need (GLib, GObject, Gio, cairo, Pango,
  # GdkPixbuf, Graphene, HarfBuzz).
  typelibPath = lib.makeSearchPath "lib/girepository-1.0" (
    map lib.getLib [
      glib
      gobject-introspection
      gtk4
      gtk4-layer-shell
      graphene
      pango
      harfbuzz
      gdk-pixbuf
    ]
  );

  # The PATH the wrapper adds behind the session's.
  runtimePath = lib.makeBinPath [
    gtk3
    sway-unwrapped
  ];
in
stdenvNoCC.mkDerivation {
  pname = "sway-radial";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./menu.toml
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  postPatch = ''
    substituteInPlace src/sway_radial/libinput.py \
      --replace-fail 'LIBINPUT_SONAME = "libinput.so.10"' \
                     'LIBINPUT_SONAME = "${lib.getLib libinput}/lib/libinput.so.10"' \
      --replace-fail 'LIBUDEV_SONAME = "libudev.so.1"' \
                     'LIBUDEV_SONAME = "${lib.getLib systemdLibs}/lib/libudev.so.1"'
    substituteInPlace src/sway_radial/overlay.py \
      --replace-fail 'ctypes.CDLL("libgtk4-layer-shell.so.0")' \
                     'ctypes.CDLL("${lib.getLib gtk4-layer-shell}/lib/libgtk4-layer-shell.so.0")'
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/sway-radial
    cp -r src/sway_radial $out/lib/sway-radial/
    install -Dm644 menu.toml $out/lib/sway-radial/menu.toml

    makeWrapper ${python}/bin/python3 $out/bin/sway-radial \
      --add-flags "-m sway_radial" \
      --prefix PYTHONPATH : $out/lib/sway-radial \
      --set GI_TYPELIB_PATH ${typelibPath} \
      --set PYTHONDONTWRITEBYTECODE 1 \
      --suffix PATH : ${runtimePath}

    runHook postInstall
  '';

  passthru = {
    # What a test that imports the daemon's modules needs: the interpreter
    # with its Python packages, the typelibs, and the PATH the wrapper adds.
    inherit python typelibPath runtimePath;
  };

  meta = {
    description = "Radial menu for the four-finger pinch on the trackpad, for Sway";
    license = lib.licenses.agpl3Plus;
    mainProgram = "sway-radial";
    platforms = lib.platforms.linux;
  };
}
