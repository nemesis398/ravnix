# F4 (mic mute) and F8 (airplane), each reported once.
#
# Every press of either key reaches the "Ideapad extra buttons" device twice:
# the ideapad-laptop driver reports it for the EC's VPC event (scancode 0x08
# for F4, 0x0d for F8) and again, 3 to 5 ms later, for the WMI fn-key event
# (0x13e and 0x13f, that is 0x100 | 0x3e and 0x3f). Measured with evtest's
# MSC_SCAN on this laptop, on Fedora (kernel 7.3) and on huginn (7.2); the
# driver's two paths are the same in both. Without this:
#   F4  the session toggles the mic twice, so it stays as it was and the
#       notification shows the old state;
#   F8  the kernel's rfkill-input (RFKILL_INPUT=y) blocks every radio and
#       unblocks it again within ~250 ms, before Sway runs its binding.
# Mapping the WMI copies to `reserved` makes the input core drop them, so the
# VPC copy is the only one: one mic toggle, and one rfkill toggle that also
# works on the lock screen and at the login screen. 0x0d stays systemd's
# `rfkill` (its entry for every IdeaPad); 0x08 is KEY_MICMUTE in the driver.
# systemd does the same for F4 on the ThinkBook 14 G7 ARP, and Fedora's setup
# for this laptop carried the F8 half since 2026-10-06.
#
# If a key stops working after a kernel update, the driver may have stopped
# reporting the VPC copy itself: measure again (evtest on the device, both
# scancodes or one?) before changing this, since this entry would then eat
# the last copy. tests/hardware/keys.nix checks the compiled hwdb.
{ ... }:
{
  services.udev.extraHwdb = ''
    evdev:name:Ideapad extra buttons:dmi:*:svnLENOVO:pn83D5:*
     KEYBOARD_KEY_13e=reserved
     KEYBOARD_KEY_13f=reserved
  '';
}
