# The CPU's power policy, the energy menu with its watcher, and the RAPL
# counters behind Waybar's power draw.
#
# THE CPU POLICY HAS ONE OWNER: tuned, through tuned-ppd. nixpkgs packages
# tuned 2.28.0, the version the Fedora laptop runs, with a NixOS module
# (services.tuned) that installs tuned-ppd as well, so tuned is the choice
# over power-profiles-daemon plus EPP writes of our own. Two reasons:
#   - It is the stack the Fedora power baseline was measured on (Task 0.1):
#     the same daemon, the same stock profiles and the three laptop profiles
#     below, so Task 3.7 compares configurations that do not differ here.
#   - A second writer is what Fedora retired on 2026-10-04: a udev script
#     that forced EPP on every change of the power source, also on every
#     resume, fought tuned and undid every power-saver choice. With
#     power-profiles-daemon the three profiles' EPP, boost and platform
#     profile values would need such a writer again. tuned writes them
#     itself, and tuned-ppd serves the power-profiles API
#     (net.hadess.PowerProfiles) that Waybar's power-profiles-daemon module
#     and `energy` speak.
# services.tuned refuses TLP, power-profiles-daemon, auto-cpufreq and
# system76-power beside it, so nothing else can take the policy over.
#
# THE MAPPING, every value distinct (tuned-ppd refuses a mapping that is not
# one-to-one, and an unknown profile name):
#   PPD profile    on AC                    on battery
#   power-saver    powersave                powersave (no battery entry)
#   balanced       laptop-ac                laptop-battery
#   performance    throughput-performance   laptop-performance-battery
# laptop-ac            balanced + EPP performance (the AC choice the old
#                      script made; plain balanced would quietly drop it to
#                      balance_performance)
# laptop-battery       balanced-battery + EPP balance_performance + boost:
#                      the 2026-10-04 choice, snappy on battery (AMD's own
#                      default) instead of tuned's balance_power
# laptop-performance-battery  balanced + governor powersave + EPP
#                      performance + boost + platform_profile performance.
#                      Without it, performance on battery keeps
#                      throughput-performance's governor=performance.
# The names and the values are Fedora's (scripts/laptop-tuned-profiles
# there). Its ppd.conf also says sysfs_acpi_monitor=true, which is
# tuned-ppd's default; services.tuned has no setting for it, and the
# default does the same.
#
# The balanced profiles also write the panel's ABM level ([video]
# panel_power_savings, 0 on AC and 1 on battery); ./panel.nix has why that
# write finds no device here.
{
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.ravnix) energy;
in
{
  services.tuned = {
    enable = true;
    ppdSupport = true;
    ppdSettings = {
      main = {
        default = "balanced";
        battery_detection = true;
      };
      profiles = {
        power-saver = "powersave";
        balanced = "laptop-ac";
        performance = "throughput-performance";
      };
      battery = {
        balanced = "laptop-battery";
        performance = "laptop-performance-battery";
      };
    };
    profiles = {
      laptop-ac = {
        main = {
          summary = "Laptop on AC, balanced: tuned balanced with EPP performance (ravnix)";
          include = "balanced";
        };
        cpu.energy_performance_preference = "performance";
      };
      laptop-battery = {
        main = {
          summary = "Laptop on battery, balanced: balanced-battery with EPP balance_performance (ravnix)";
          include = "balanced-battery";
        };
        cpu = {
          energy_performance_preference = "balance_performance";
          boost = 1;
        };
      };
      laptop-performance-battery = {
        main = {
          summary = "Laptop on battery, performance: EPP performance under the powersave governor (ravnix)";
          include = "balanced";
        };
        cpu = {
          governor = "powersave";
          energy_performance_preference = "performance";
          boost = 1;
        };
        acpi.platform_profile = "performance";
      };
    };
  };

  # The energy menu (Waybar's middle click, sway-settings) and the watcher
  # that applies its settings when the charger or the profile changes:
  # packages/energy has the script and its header the why. kanshi's profiles
  # run `energy refresh`, and keep-awake's swayidle `energy idle-suspend`.
  environment.systemPackages = [ energy ];

  # As on Fedora: started with the Sway session and stopped with it. The
  # unit sets no PATH, so it keeps the user manager's, from
  # /etc/environment.d: the setuid wrappers first (/run/wrappers/bin), then
  # the user's and the system's profiles, where the desktop installs
  # keep-awake and waybar-launch; the rest the package brings. A PATH of
  # the unit's own replaces that one whole, and NixOS gives a user unit one
  # even without `path` (systemd.defaultPath: coreutils and a few more),
  # hence enableDefaultPath = false. Without the wrappers, the Waybar that
  # the watcher relaunches on an unplug would find the store's sudo, which
  # is not setuid, and charge-mode would fail from its battery click.
  systemd.user.services.energy-watch = {
    description = "Energy settings watcher (refresh rate, keep-awake, focus bar)";
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "sway-session.target" ];
    enableDefaultPath = false;
    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe energy} watch";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # The CPU package's energy counter, readable by the user, for Waybar's
  # power draw (waybar-powerdraw). The kernel keeps energy_uj root-only
  # because of CVE-2020-8694 (PLATYPUS), a power side channel that can leak
  # secrets to a local unprivileged process. huginn is a single-user laptop,
  # so the trade-off is accepted, as on Fedora; the GPU half of the module
  # needs no such rule. RUN fires on the add event, which every powercap
  # device gets when udev starts at boot.
  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "rapl-readable-udev-rules";
      destination = "/lib/udev/rules.d/99-rapl-readable.rules";
      text = ''
        # The RAPL energy counters readable by the user, for Waybar's power
        # draw. Accepts CVE-2020-8694 (PLATYPUS) on a single-user laptop.
        SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", RUN+="${pkgs.coreutils}/bin/chmod 0444 /sys/class/powercap/%k/energy_uj"
      '';
    })
  ];
}
