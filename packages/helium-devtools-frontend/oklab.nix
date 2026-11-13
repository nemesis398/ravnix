# Mixing two colors in OKLab (Björn Ottosson's matrices), in Nix, for the
# tone ramps of stylesheet.nix. A color is a list of three bytes [ r g b ] in
# sRGB. Nix has no power function, so the roots are Newton's method from above
# (monotone, it stops when a step no longer shrinks the value), and the sRGB
# curve uses x^2.4 = x^2 * (x^2)^(1/5) and x^(1/2.4) = (x^5)^(1/12).
# tests/desktop/helium-devtools-stylesheet.nix checks the result against the
# ramps of the Fedora stylesheet, which a floating-point OKLab mix in Python
# made: every byte is the same.
{ lib }:
let
  ipow = x: n: if n == 0 then 1.0 else x * ipow x (n - 1);

  # The n-th root of x; 0 for x <= 0.
  root =
    n: x:
    let
      step = y: ((n - 1) * y + x / ipow y (n - 1)) / n;
      go =
        y:
        let
          next = step y;
        in
        if next >= y then y else go next;
    in
    if x <= 0.0 then 0.0 else go (if x > 1.0 then x else 1.0);

  toLinear =
    byte:
    let
      v = byte / 255.0;
      u = (v + 0.055) / 1.055;
    in
    if v <= 0.04045 then v / 12.92 else ipow u 2 * root 5 (ipow u 2);

  toByte =
    x:
    let
      c = if x <= 0.0031308 then 12.92 * x else 1.055 * root 12 (ipow x 5) - 0.055;
      b = builtins.floor (c * 255 + 0.5);
    in
    if b < 0 then
      0
    else if b > 255 then
      255
    else
      b;

  toOklab =
    rgb:
    let
      r = toLinear (builtins.elemAt rgb 0);
      g = toLinear (builtins.elemAt rgb 1);
      b = toLinear (builtins.elemAt rgb 2);
      l = root 3 (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
      m = root 3 (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
      s = root 3 (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    in
    [
      (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s)
      (1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s)
      (0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    ];

  fromOklab =
    lab:
    let
      L = builtins.elemAt lab 0;
      a = builtins.elemAt lab 1;
      b = builtins.elemAt lab 2;
      l = ipow (L + 0.3963377774 * a + 0.2158037573 * b) 3;
      m = ipow (L - 0.1055613458 * a - 0.0638541728 * b) 3;
      s = ipow (L - 0.0894841775 * a - 1.2914855480 * b) 3;
    in
    map toByte [
      (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
      (-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
      (-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    ];
in
{
  # "#rrggbb" as [ r g b ].
  bytes =
    hex:
    let
      h = lib.removePrefix "#" hex;
    in
    map (i: lib.fromHexString (builtins.substring i 2 h)) [
      0
      2
      4
    ];

  # t of the first color and 1 - t of the second, mixed in OKLab.
  mix =
    first: second: t:
    fromOklab (lib.zipListsWith (x: y: x * t + y * (1 - t)) (toOklab first) (toOklab second));
}
