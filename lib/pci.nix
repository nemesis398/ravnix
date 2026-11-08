# PCI addresses. NixOS names a device's bus the way the X server does, as
# "PCI:bus:device:function" in decimal and without a PCI domain
# (hardware.nvidia.prime.amdgpuBusId = "PCI:54:0:0"). The kernel, sysfs, udev
# and `lspci -D` spell the same address in hexadecimal with the domain:
# "0000:36:00.0". A udev rule has to match the second form.
{ lib }:
let
  # Decimal digits to an integer; a leading zero is read as decimal ("054" is 54),
  # which lib.toInt refuses.
  decimal = s: lib.foldl' (acc: c: acc * 10 + lib.toInt c) 0 (lib.stringToCharacters s);

  # An integer as lower-case hexadecimal, at least `width` digits (udev and sysfs
  # print "0a", where lib.toHexString prints "A").
  hex =
    width: n:
    let
      s = lib.toLower (lib.toHexString n);
    in
    lib.fixedWidthString width "0" s;
in
{
  # "PCI:54:0:0" -> "0000:36:00.0". null when the string is not of that form, or
  # a number is out of range (a bus is 0..255, a device 0..31, a function 0..7),
  # so that a caller can tell "no address" from a wrong one.
  fromBusId =
    busId:
    let
      m = builtins.match "[Pp][Cc][Ii]:([0-9]{1,3}):([0-9]{1,2}):([0-9])" busId;
      bus = decimal (lib.elemAt m 0);
      device = decimal (lib.elemAt m 1);
      function = decimal (lib.elemAt m 2);
    in
    if m == null || bus > 255 || device > 31 || function > 7 then
      null
    else
      "0000:${hex 2 bus}:${hex 2 device}.${hex 1 function}";
}
