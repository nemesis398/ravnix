# The peripherals of huginn, as the Fedora laptop has them set up: the Dygma
# keyboard, the Apple Magic Trackpad and the Logitech MX Master 3S mouse.
# The Bazecor application that configures the Dygma is an app, not a rule
# (Task 3.3); what is here is the access it needs.
#
# Dygma and Magic Trackpad: udev rules that give the user on the active seat
# access to the devices, through logind's `uaccess` ACL. A group would give
# more: `input` reaches every input device on the machine, a keylogging
# surface. The rules are packages of their own, named 60-*.rules, because the
# tag is only honored when it is set before systemd's 73-seat-late.rules runs;
# services.udev.extraRules writes 99-local.rules, which is too late.
#
# This file owns 60-dygma.rules and 60-magic-trackpad.rules, with every line
# the Fedora laptop's two files hold: the hidraw lines and the evdev lines
# that sway-radial needs (it reads the pad's gestures from libinput, which
# skips a device it cannot open and says nothing). NixOS assembles the rules
# directory by file name, so a second package that ships a rule file of the
# same name silently replaces one of the two. Nothing else may ship them; the
# VM test compares the built files line by line.
#
# MX Master: the mouse needs no udev rule. logid runs as root, and what it is
# for is two things only (the file it replaces says so at length):
#   - the gesture button under the thumb rest becomes F14 (a press) and F15
#     to F18 (up, down, left, right). What a gesture does is decided by
#     sway-mouse, which can see the focused window; logid cannot. Function
#     keys carry no layout, so logid's US-QWERTY key names cannot misfire on
#     a German layout.
#   - the SmartShift clutch of the wheel, which no host-side setting reaches.
# Left alone on purpose: DPI (a device register, shared with another machine
# over Easy-Switch; pointer speed is Sway's), hi-res scrolling (the kernel's
# hid-logitech-hidpp does it; logid writing to the same register breaks it),
# the thumb wheel and the side buttons. Never run Solaar beside logid.
# The libinput quirk is the other half: libinput inverts this mouse's thumb
# wheel to match Logitech's inconsistent configuration of its two wheels,
# which suits one machine and not a mouse that switches between two. It is
# matched on the Bluetooth product id, so it does nothing on the Bolt
# receiver, which reports another.
#
# Bluetooth, for the trackpad and the mouse. The trackpad's battery is read by
# magic-trackpad-battery (Task 3.2b) from its hidraw node, which the rule
# below makes readable; the kernel's own value over Bluetooth is wrong.
{
  lib,
  pkgs,
  ...
}:
let
  libconfig = pkgs.formats.libconfig { };

  gesture = direction: key: {
    inherit direction;
    mode = "OnRelease";
    action = {
      type = "Keypress";
      keys = libconfig.lib.mkArray [ key ];
    };
  };

  udevRules =
    name: text:
    pkgs.writeTextFile {
      name = "ravnix-udev-${name}";
      destination = "/etc/udev/rules.d/60-${name}.rules";
      inherit text;
    };
in
{
  services.logiops = {
    enable = true;
    config.devices = [
      {
        name = "MX Master 3S";
        # Lower threshold, sooner free spin; 1 to 255. 20 is a light touch.
        smartshift = {
          on = true;
          threshold = 20;
        };
        buttons = [
          {
            # The gesture button. Gestures freeze the pointer while it is
            # held, which is what makes the four directions measurable.
            # "None" fires on release without passing the threshold.
            cid = libconfig.lib.mkHex "0xc3";
            action = {
              type = "Gestures";
              gestures = [
                (gesture "None" "KEY_F14")
                (gesture "Up" "KEY_F15")
                (gesture "Down" "KEY_F16")
                (gesture "Left" "KEY_F17")
                (gesture "Right" "KEY_F18")
              ];
            };
          }
        ];
      }
    ];
  };

  # The unit of the package is wanted by graphical.target only. logid waits
  # for the mouse to appear and costs nothing until then, so it starts with
  # the system, whatever the default target is.
  systemd.services.logid.wantedBy = [ "multi-user.target" ];

  environment.etc."libinput/local-overrides.quirks".text = ''
    [Logitech MX Master 3S Bluetooth]
    MatchVendor=0x46D
    MatchProduct=0xB034
    ModelInvertHorizontalScrolling=0
  '';

  services.udev.packages = [
    (udevRules "dygma" ''
      # Dygma keyboards: raw access for Bazecor over the Focus protocol (a
      # serial node, /dev/ttyACM*, and a hidraw node), for the user on the
      # active seat.
      # The Raise, on the pid.codes vendor id, and its bootloader.
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="2200", MODE="0660", TAG+="uaccess"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="2201", MODE="0660", TAG+="uaccess"
      # Dygma's own vendor id, for the Defy, the Raise 2 and their bootloaders.
      # SUBSYSTEMS walks up the parents, so this tags the usb node and its tty
      # and hidraw children.
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="35ef", MODE="0660", TAG+="uaccess"
      # The hidraw nodes of that vendor, as Dygma's own installer writes it.
      KERNEL=="hidraw*", ATTRS{idVendor}=="35ef", MODE="0660", TAG+="uaccess"
    '')

    (udevRules "magic-trackpad" ''
      # Apple Magic Trackpad. The kernel's hid_magicmouse reports a battery
      # level over USB only; over Bluetooth the value in power_supply is the
      # status byte read as the capacity (4 % on a full battery). The device
      # reports the truth as HID input report 0x90 on its hidraw node, which
      # is root-only until this rule.
      # A Bluetooth uhid device has no idVendor to match, so the driver is the
      # match, which covers Bluetooth (0005:004C:0324) and USB
      # (0003:05AC:0324) at once. The two explicit lines are for the case that
      # a kernel renames or re-parents the driver.
      KERNEL=="hidraw*", SUBSYSTEM=="hidraw", DRIVERS=="magicmouse", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", KERNELS=="0005:004C:0324.*", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", KERNELS=="0003:05AC:0324.*", MODE="0660", TAG+="uaccess"
      # The evdev node, for sway-radial, which reads this pad's gestures from
      # libinput in its own context. libinput does not grab the device, so
      # reading it beside Sway changes nothing for the session. When this is
      # missing nothing says so: libinput skips a device it cannot open, and
      # the menu never opens.
      SUBSYSTEM=="input", DRIVERS=="magicmouse", MODE="0660", TAG+="uaccess"
      SUBSYSTEM=="input", KERNELS=="0005:004C:0324.*", MODE="0660", TAG+="uaccess"
      SUBSYSTEM=="input", KERNELS=="0003:05AC:0324.*", MODE="0660", TAG+="uaccess"
    '')
  ];

  hardware.bluetooth.enable = lib.mkDefault true;
}
