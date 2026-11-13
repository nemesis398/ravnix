# Handy, the offline speech-to-text app (ravnix's 0.10.0, packages/handy),
# started on the iGPU only. Every launcher goes through `handy-launch`: the
# application menu entry, the autostart entry, and the dictation key's
# fallback.
#
# Without the two variables below, Handy's WebKitWebProcess opens /dev/nvidia*
# through the NVIDIA EGL vendor and the RTX 4050 stays `active` for as long as
# Handy runs, which drains the battery. Measured on Fedora 2026-11-04: unpinned,
# two WebKitWebProcess children held the card; pinned, nothing held it and it
# suspended within about 2 s.
#
#   __EGL_VENDOR_LIBRARY_FILENAMES  WebKit's EGL goes to Mesa (radeonsi, the 780M).
#   VK_DRIVER_FILES                 the speech models' Vulkan backend sees RADV
#                                   only, so they run on the 780M.
#
# Neither names a GPU, so nothing here depends on how the kernel numbers them
# (card0 and card1 can trade places). The files are the ones of the host's
# graphics driver (/run/opengl-driver).
#
# Handy types every take with `wtype -- TEXT` through whichever wtype is first
# on PATH. The autostart runs under the systemd user manager, whose PATH may
# not hold the wtype of this system, so the launcher puts it first. nixpkgs'
# wtype is 0.5, which has the printable-keycode fix (tests/desktop/apps.nix).
{
  lib,
  writeShellApplication,
  symlinkJoin,
  makeDesktopItem,
  addDriverRunpath,
  wtype,
  # The packages of ravnix: handy is one (0.10.0, where nixpkgs has 0.9.8).
  ravnix,
}:
let
  inherit (ravnix) handy;
  launcher = writeShellApplication {
    name = "handy-launch";
    runtimeInputs = [ wtype ];
    text = ''
      export __EGL_VENDOR_LIBRARY_FILENAMES=${addDriverRunpath.driverLink}/share/glvnd/egl_vendor.d/50_mesa.json
      export VK_DRIVER_FILES=${addDriverRunpath.driverLink}/share/vulkan/icd.d/radeon_icd.x86_64.json
      exec ${lib.getExe handy} "$@"
    '';
  };

  entry = {
    name = "Handy";
    desktopName = "Handy";
    comment = "Offline speech-to-text";
    exec = "handy-launch";
    tryExec = "handy-launch";
    icon = "handy";
    categories = [
      "Utility"
      "Accessibility"
    ];
    extraConfig.StartupWMClass = "handy";
  };
  menu = makeDesktopItem entry;
  # Started by the session's XDG autostart, hidden in the tray.
  autostart = makeDesktopItem (
    entry
    // {
      name = "handy";
      comment = "Offline speech-to-text, in the tray";
      exec = "handy-launch --start-hidden";
      destination = "/etc/xdg/autostart";
    }
  );
in
symlinkJoin {
  name = "handy-launch";
  paths = [
    launcher
    menu
    autostart
  ];
  # The icon is Handy's own.
  postBuild = ''
    mkdir -p $out/share
    ln -s ${handy}/share/icons $out/share/icons
  '';
  meta = {
    description = "Handy, pinned to the iGPU, with its menu and autostart entries";
    mainProgram = "handy-launch";
    platforms = lib.platforms.linux;
  };
}
