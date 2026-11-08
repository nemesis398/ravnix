# Helium (packages/helium): the tarball's Chromium starts on this system's
# libraries, answers with the version of the package, and, built with the
# Widevine library, offers the Widevine key system to a page; built without
# it, it does not. The browser runs headless, with its sandbox off (the build
# sandbox has no user namespaces) and a profile of its own in a scratch
# directory. The page is a file: URL, which is a secure context, as
# requestMediaKeySystemAccess needs.
#
# widevine-cdm is the one unfree package this check builds, and is allowed by
# name and nothing else.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  upkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfreePredicate = p: lib.getName p == "widevine-cdm";
    overlays = [ self.overlays.default ];
  };
  plain = upkgs.ravnix.helium;
  withDrm = plain.override { widevineCdm = upkgs.widevine-cdm; };

  page = pkgs.writeText "eme.html" ''
    <!doctype html><title>start</title><body><script>
    const cfg = [{
      initDataTypes: ['cenc'],
      audioCapabilities: [{ contentType: 'audio/mp4;codecs="mp4a.40.2"', robustness: 'SW_SECURE_CRYPTO' }],
      videoCapabilities: [{ contentType: 'video/mp4;codecs="avc1.42E01E"', robustness: 'SW_SECURE_CRYPTO' }],
    }];
    navigator.requestMediaKeySystemAccess('com.widevine.alpha', cfg)
      .then(a => { document.body.textContent = 'WIDEVINE-YES ' + a.keySystem; })
      .catch(e => { document.body.textContent = 'WIDEVINE-NO ' + e.name; });
    </script></body>
  '';
in
pkgs.runCommand "desktop-helium"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gnused
    ];
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

    ${plain}/bin/helium --version | grep -qx 'Helium ${plain.version} (Chromium 157[.].*)' \
      || fail "helium --version is not ${plain.version}: $(${plain}/bin/helium --version 2>&1 | head -1)"

    # What the wrapper passes: the ozone hint is conditional, and there is
    # exactly one --enable-features list.
    wrapper=${plain}/bin/helium
    [ "$(grep -o -- '--enable-features=' "$wrapper" | wc -l)" = 1 ] || fail "the wrapper does not carry exactly one --enable-features"
    grep -q 'AcceleratedVideoDecodeLinuxGL' "$wrapper" || fail "no hardware video decoding in the wrapper"
    grep -q 'NIXOS_OZONE_WL' "$wrapper" || fail "the wayland hint does not depend on NIXOS_OZONE_WL"

    # The menu entry.
    d=${plain}/share/applications/helium.desktop
    grep -qx 'Exec=helium %U' "$d" || fail "the menu entry does not run helium %U"
    grep -q '^MimeType=.*x-scheme-handler/https;*$' "$d" || fail "the menu entry does not take https links"
    grep -q '^MimeType=.*application/pdf;' "$d" || fail "the menu entry does not take PDFs"
    [ -e ${plain}/share/icons/hicolor/256x256/apps/helium.png ] || fail "no icon"

    run() { # run PACKAGE -> the page's text
      export HOME=$TMPDIR/home-$1 XDG_CONFIG_HOME=$TMPDIR/config-$1
      mkdir -p "$HOME" "$XDG_CONFIG_HOME"
      # Headless uses a temporary profile unless it is told one; the browser's
      # own default, which the wrapper writes the hint to, is this directory
      # (the Fedora profile of the same browser is ~/.config/net.imput.helium).
      "$2/bin/helium" --headless=new --no-sandbox --disable-gpu --virtual-time-budget=8000 \
        --user-data-dir="$XDG_CONFIG_HOME/net.imput.helium" \
        --dump-dom file://${page} 2>/dev/null | grep -o 'WIDEVINE-[A-Z]* *[A-Za-z.]*' || true
    }
    got=$(run plain ${plain})
    case $got in WIDEVINE-NO*) ;; *) fail "Helium without the library offers Widevine, or does not answer: '$got'";; esac
    got=$(run drm ${withDrm})
    case $got in WIDEVINE-YES*) ;; *) fail "Helium with the library does not offer Widevine: '$got'";; esac

    # The hint is written to the profile the browser really uses, and a second
    # start rewrites it without complaint.
    h=$TMPDIR/config-drm/net.imput.helium/WidevineCdm/latest-component-updated-widevine-cdm
    [ -e "$h" ] || fail "the wrapper wrote no hint file at $h"
    grep -q '"Path":"/nix/store/.*-widevine-cdm-.*/share/google/chrome/WidevineCdm"' "$h" || fail "the hint file names no library: $(cat "$h" 2>/dev/null)"

    # The hint is an optimization, not a precondition: a configuration
    # directory that cannot be written (read-only, or full) must not stop the
    # browser from starting. The wrapper runs under `set -e`.
    mkdir -p "$TMPDIR/ro"; chmod a-w "$TMPDIR/ro"
    got=$(XDG_CONFIG_HOME=$TMPDIR/ro HOME=$TMPDIR/ro ${withDrm}/bin/helium --version 2>&1 | head -1)
    [ "$got" = "Helium ${plain.version} (Chromium $(${plain}/bin/helium --version | sed -n 's/.*Chromium \([0-9.]*\))/\1/p'))" ] \
      || fail "Helium with the library does not start when its configuration directory cannot be written: '$got'"
    chmod u+w "$TMPDIR/ro"

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
