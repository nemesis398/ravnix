# huginn's only swap: zram, compressed memory, set up as the Fedora laptop
# has it from zram-generator's defaults there: the smaller of the RAM and
# 8 GiB, the kernel's lzo-rle, priority 100. There is no swap partition and
# no swap file (./disko.nix), so there is no hibernation either: at a
# critical battery the safety net powers off instead (the hardware module's
# battery.nix). The power baseline was measured on this swap, so it stays
# the same here.
{
  zramSwap = {
    enable = true;
    memoryPercent = 100;
    memoryMax = 8 * 1024 * 1024 * 1024;
    algorithm = "lzo-rle";
    priority = 100;
  };
}
