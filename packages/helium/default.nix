# Helium, the Chromium-based browser from imputnet (ungoogled, with uBlock
# Origin built in), from the release tarball of github.com/imputnet/helium-linux.
# nixpkgs has no Helium. See README.md for the update steps and what was checked.
#
# The tarball holds a Chromium build: patchelf'd like nixpkgs' google-chrome,
# which is the same Chromium version at the time of writing (157.0.8103.38),
# so its list of libraries is the one to start from. Helium's own
# `helium-wrapper` is replaced by one that sets what NixOS needs.
#
# The command line the wrapper starts it with (before the user's own, so a
# later flag wins):
#
#   --ozone-platform=wayland        when NIXOS_OZONE_WL and WAYLAND_DISPLAY are set
#                                   (the desktop module sets the first);
#   --enable-features=...           ONE list, because Chromium honors only the
#                                   last --enable-features it is given. The list
#                                   is hardware video decoding: without it Helium
#                                   decoded in software on the 780M (measured on
#                                   Fedora 2026-10-04). A flag the user adds
#                                   replaces it as a whole.
#
# With `widevineCdm` set, Helium plays DRM-protected media (Apple Music in a
# web app streams full tracks only under DRM). Chromium looks for the library
# through a hint file in the profile, which the wrapper writes at every start;
# see README.md.
{
  lib,
  stdenvNoCC,
  fetchurl,
  bintools,
  makeWrapper,
  makeDesktopItem,
  copyDesktopItems,
  patchelf,

  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  bzip2,
  cairo,
  coreutils,
  cups,
  curl,
  dbus,
  expat,
  flac,
  fontconfig,
  freetype,
  gcc-unwrapped,
  gdk-pixbuf,
  glib,
  gtk3,
  gtk4,
  harfbuzz,
  icu,
  libcap,
  libdrm,
  liberation_ttf,
  libexif,
  libglvnd,
  libkrb5,
  libopus,
  libpng,
  libx11,
  libxcb,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxkbcommon,
  libxrandr,
  libxrender,
  libxscrnsaver,
  libxshmfence,
  libxtst,
  libgbm,
  nspr,
  nss,
  pango,
  pciutils,
  pipewire,
  snappy,
  speechd-minimal,
  systemdLibs,
  util-linux,
  vulkan-loader,
  wayland,
  wget,
  libpulseaudio,
  libva,
  adwaita-icon-theme,
  gsettings-desktop-schemas,
  xdg-utils,
  addDriverRunpath,

  # The unfree Widevine library, or null for a Helium that plays no DRM media.
  widevineCdm ? null,
  # Command line arguments that are always set.
  commandLineArgs ? "",
}:
let
  opusWithCustomModes = libopus.override { withCustomModes = true; };

  deps = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    bzip2
    cairo
    coreutils
    cups
    curl
    dbus
    expat
    flac
    fontconfig
    freetype
    gcc-unwrapped.lib
    gdk-pixbuf
    glib
    gtk3
    gtk4
    harfbuzz
    icu
    libcap
    libdrm
    liberation_ttf
    libexif
    libglvnd
    libkrb5
    libpng
    libpulseaudio
    libva
    libx11
    libxcb
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxkbcommon
    libxrandr
    libxrender
    libxscrnsaver
    libxshmfence
    libxtst
    libgbm
    nspr
    nss
    opusWithCustomModes
    pango
    pciutils
    pipewire
    snappy
    speechd-minimal
    systemdLibs
    util-linux
    vulkan-loader
    wayland
    wget
  ];

  # Hardware video decoding, the one --enable-features list (see above).
  features = "UseOzonePlatform,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL";

  # Where Chromium looks for a Widevine library it did not bundle: a hint file
  # in the profile, naming the directory.
  widevineHint = lib.optionalString (widevineCdm != null) ''
    --run 'hint="''${XDG_CONFIG_HOME:-$HOME/.config}/net.imput.helium/WidevineCdm"; mkdir -p "$hint" && printf "{\"Path\":\"%s\"}" "${widevineCdm}/share/google/chrome/WidevineCdm" > "$hint/latest-component-updated-widevine-cdm"' \
  '';
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "helium";
  version = "0.21.1.1";

  src = fetchurl {
    url = "https://github.com/imputnet/helium-linux/releases/download/${finalAttrs.version}/helium-${finalAttrs.version}-x86_64_linux.tar.xz";
    hash = "sha256-bNfyQBU8ucDN+ie/GmZR3crnOomK/ESak90Q2oO0vUU=";
  };

  # Some shebangs are not patched correctly with strictDeps on.
  strictDeps = false;

  nativeBuildInputs = [
    makeWrapper
    copyDesktopItems
    patchelf
  ];

  buildInputs = [
    # for XDG_ICON_DIRS
    adwaita-icon-theme
    glib
    gtk3
    gtk4
    # for GSETTINGS_SCHEMAS_PATH
    gsettings-desktop-schemas
  ];

  rpath = lib.makeLibraryPath deps + ":" + lib.makeSearchPathOutput "lib" "lib64" deps;
  binpath = lib.makeBinPath deps;

  desktopItems = [
    (makeDesktopItem {
      name = "helium";
      desktopName = "Helium";
      genericName = "Web Browser";
      comment = "Access the Internet";
      exec = "helium %U";
      icon = "helium";
      terminal = false;
      startupNotify = true;
      categories = [
        "Network"
        "WebBrowser"
      ];
      mimeTypes = [
        "application/pdf"
        "application/rdf+xml"
        "application/rss+xml"
        "application/xhtml+xml"
        "application/xhtml_xml"
        "application/xml"
        "image/gif"
        "image/jpeg"
        "image/png"
        "image/webp"
        "text/html"
        "text/xml"
        "x-scheme-handler/http"
        "x-scheme-handler/https"
      ];
      actions = {
        new-window = {
          name = "New Window";
          exec = "helium";
        };
        new-private-window = {
          name = "New Incognito Window";
          exec = "helium --incognito";
        };
      };
    })
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/helium
    cp -a . $out/share/helium

    # Replace the bundled vulkan-loader, and the wrapper (below).
    rm -f $out/share/helium/libvulkan.so.1 $out/share/helium/helium-wrapper $out/share/helium/helium.desktop
    ln -s ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $out/share/helium/libvulkan.so.1

    install -Dm444 $out/share/helium/product_logo_256.png \
      $out/share/icons/hicolor/256x256/apps/helium.png

    for elf in helium helium_crashpad_handler chromedriver; do
      patchelf --set-rpath "$rpath" "$out/share/helium/$elf"
      patchelf --set-interpreter ${bintools.dynamicLinker} "$out/share/helium/$elf"
    done

    makeWrapper $out/share/helium/helium $out/bin/helium \
      --prefix LD_LIBRARY_PATH : "$rpath" \
      --prefix PATH            : "$binpath" \
      --suffix PATH            : "${lib.makeBinPath [ xdg-utils ]}" \
      --prefix XDG_DATA_DIRS   : "$XDG_ICON_DIRS:$GSETTINGS_SCHEMAS_PATH:${addDriverRunpath.driverLink}/share" \
      --set CHROME_WRAPPER helium \
      --set CHROME_VERSION_EXTRA nixos \
      ${widevineHint} \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland}}" \
      --add-flags "--enable-features=${features}" \
      --add-flags ${lib.escapeShellArg commandLineArgs}

    runHook postInstall
  '';

  passthru = {
    # The tarball is signed (helium-VERSION-x86_64_linux.tar.xz.asc); the hash
    # above is of the tarball as fetched over TLS from the release page.
    inherit features;
    # Whether this build plays DRM-protected media (the module's option reads it).
    withWidevine = widevineCdm != null;
  };

  meta = {
    description = "Chromium-based web browser from imputnet, with uBlock Origin built in";
    homepage = "https://helium.computer";
    changelog = "https://github.com/imputnet/helium-linux/releases/tag/${finalAttrs.version}";
    license = lib.licenses.gpl3Only;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "helium";
  };
})
