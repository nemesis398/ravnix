# The internal panel: its Adaptive Backlight Management level, pinned.
#
# THE SYMPTOM, on the Fedora laptop: the panel visibly dimmed the moment the
# charger went in and brightened when it came out, with the brightness
# slider at 100 %. The cause, diagnosed live there: the BOE eDP panel hangs
# off the 780M, its slider is the EC's (nvidia_wmi_ec_backlight; amdgpu
# skips its own backlight), and amdgpu's ABM dims or boosts the panel apart
# from that slider. Its level is the connector's amdgpu/panel_power_savings
# (0 off, 1 to 4), and on this panel a higher level looks brighter, since
# the pixel boost outweighs the backlight cut. tuned switches profiles with
# the power source, and the stock balanced profile writes 0 while
# balanced-battery writes 1, so every plug-in dimmed the panel.
#
# STILL NEEDED HERE: huginn runs the same tuned and the same profiles
# (./power.nix: laptop-ac includes balanced, laptop-battery
# balanced-battery), so the cause is the same.
#
# THE FIX, as on Fedora: amdgpu.abmlevel on the kernel command line. With
# the parameter set, amdgpu does not create panel_power_savings at all
# (kernel 7.2.15 on Fedora: no amdgpu/ directory under card1-eDP-1, and
# tuned logs "instance video: no matching devices available"), so tuned's
# writes find nothing and the level stays the same on the charger and off
# it. Level 2 is the look chosen on Fedora. ABM saves little here, because
# the EC drives the backlight; the battery savings come from the brightness
# and the refresh rate (the energy menu). The panel has no PSR (the kernel
# reports PSR support 0), so no PSR workaround applies either.
{
  boot.kernelParams = [ "amdgpu.abmlevel=2" ];
}
