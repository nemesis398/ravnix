# helium

Helium 0.21.1.1 (Chromium 157.0.8103.38), the browser from
[imputnet](https://github.com/imputnet/helium-linux), from the release tarball.
nixpkgs has no Helium (checked at the revision `flake.lock` pins, Task 3.3). It
is the default browser of the laptop shape, its PDF and image viewer, and the
window of every web app (`modules/desktop/webapps.nix`).

## What the package does

- Unpacks the tarball, patches the three ELF files (`helium`,
  `helium_crashpad_handler`, `chromedriver`) the way nixpkgs' `google-chrome`
  does (that package is the same Chromium version, so its list of libraries is
  the one used here) and wraps `helium` with the libraries on `LD_LIBRARY_PATH`.
- Replaces the bundled `libvulkan.so.1` by the system's loader.
- Starts Helium with `--ozone-platform=wayland` when `NIXOS_OZONE_WL` and
  `WAYLAND_DISPLAY` are set, and with **one** `--enable-features` list that
  turns on hardware video decoding. Chromium honors only the last
  `--enable-features` it is given, so no launcher adds one of its own; a flag
  you add on the command line replaces ours as a whole.
- `devtoolsFrontend`: with a directory passed in, the wrapper starts Helium
  with `--custom-devtools-frontend=file://DIR/`. The desktop module passes
  `packages/helium-devtools-frontend`, DevTools in the theme, for the Helium on
  the PATH; the Chrome DevTools MCP server runs this package without it. Left
  unset, the wrapper is the same derivation as before the option existed.
- Writes `helium.desktop` (English only), with the MIME types for web pages,
  PDFs and images, and the icon.
- `widevineCdm`: with the unfree `widevine-cdm` of nixpkgs passed in, Helium
  offers the Widevine key system. Chromium looks for a library it did not bundle
  through a hint file, `WidevineCdm/latest-component-updated-widevine-cdm` in
  the profile, naming the directory; the wrapper writes it at every start, into
  `${XDG_CONFIG_HOME:-~/.config}/net.imput.helium`, which is where Helium keeps
  its profile. Apple Music in a web app streams full tracks only under DRM
  (30-second previews otherwise), and Sidra, the Electron client it replaces,
  existed for that reason. `tests/desktop/helium.nix` proves both halves: a
  page asks for `com.widevine.alpha`, the build without the library is refused,
  the build with it is served. The module (`modules/desktop/apps.nix`) passes
  the library in and allows it by name.

## Updating

1. Find the release: <https://github.com/imputnet/helium-linux/releases>.
2. Set `version` in `default.nix`.
3. `nix store prefetch-file --json URL-OF-helium-VERSION-x86_64_linux.tar.xz`,
   and put the `hash` it prints into `default.nix`.
4. Verify the signature: import the key from the README of the release's
   repository (fingerprint `BE67 7C19 89D3 5EAB 2C5F 26C9 3516 01AD 01D6 378E`),
   and `gpg --verify helium-VERSION-x86_64_linux.tar.xz.asc helium-VERSION-x86_64_linux.tar.xz`.
   0.21.1.1 verified as a good signature from that key.
5. `nix build .#checks.x86_64-linux.desktop-helium`, which starts the browser.
6. When Chromium's major version moves, compare `google-chrome`'s version in
   nixpkgs: the list of libraries follows it.

## Findings that are not fixed

- There is no `chrome-sandbox` in the tarball, so Helium uses the user-namespace
  sandbox. NixOS allows unprivileged user namespaces by default; a host that
  turns them off (`security.unprivilegedUsernsClone = false`) gets a browser
  that does not start without `--no-sandbox`.
- `libqt5_shim.so` and `libqt6_shim.so` (the "use Qt" appearance and file
  dialogs) are patched but their Qt libraries are not provided, so Helium never
  draws with Qt here; it uses GTK. Nothing in ravnix needs the other.
- The tarball is not byte-for-byte the binary of Fedora's `helium-bin` RPM
  (the repack differs), so the version, not the hash, is what both share.
- The profile directory is the browser's default. A launcher that passes
  `--user-data-dir` hides the Widevine hint the wrapper writes; web apps and the
  menu entry pass none.
- The tarball is not rebuilt from source: it is imputnet's binary build,
  trusted as the signing key says. `sourceProvenance` says so.
