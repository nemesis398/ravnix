# huginn's only swap: zram, compressed memory. Its size and algorithm are the
# maintainer's decision of 2026-11-16: the smaller of the RAM and 16 GiB (all
# 16 GiB on huginn, whose RAM is 27 GiB), zstd, priority 100. The Fedora
# laptop had zram-generator's defaults, the smaller of the RAM and 8 GiB with
# the kernel's lzo-rle, and the power baseline was measured on those, so the
# larger zram and zstd's heavier compression may move it: measure it again
# before comparing against that baseline. There is no swap partition and no
# swap file (./disko.nix), so there is no hibernation either: at a critical
# battery the safety net powers off instead (the hardware module's
# battery.nix).
{
  zramSwap = {
    enable = true;
    # zram-generator's size is min(memoryPercent of the RAM, memoryMax), so
    # 100 % with a 16 GiB cap is 16 GiB exactly on any machine with at least
    # 16 GiB of RAM, and never more than the RAM on a smaller one.
    memoryPercent = 100;
    memoryMax = 16 * 1024 * 1024 * 1024;
    algorithm = "zstd";
    priority = 100;
  };
}
