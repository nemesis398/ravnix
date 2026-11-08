# The battery: the safety net that keeps it from running to 0 %, and the
# charge mode, the one charge ceiling this firmware offers.
#
# THE SAFETY NET has two layers that do not depend on each other, because
# on the Fedora laptop the first one failed to act. The battery ran from
# over 50 % to 0 % twice, on 2026-07-13 and 2026-07-14, while a broken
# suspend looped all night with the lid closed (./nvidia.nix has that root
# cause). Both layers and their thresholds are Fedora's
# (scripts/battery-critical-safety-net there), and neither is ever dropped.
#   1. UPower's critical action is PowerOff. Fedora's default, Auto, came
#      down to a suspend on this laptop, which has no hibernation (zram is
#      the only swap), so at the critical level UPower asked for the very
#      suspend that was failing; NixOS's default, HybridSleep, needs the
#      hibernation that is not there either. PowerOff is the only action
#      that saves the machine. UPower acts at 2 % and warns at 5 % and 20 %,
#      by the percentage, as in Fedora's UPower.conf; every value is set
#      here, so a change of the NixOS defaults changes nothing.
#   2. battery-emergency-poweroff.timer, every 2 minutes, apart from
#      upowerd, D-Bus and logind: on a discharging BAT0 at 3 % or less, a
#      10 second warning, then the poweroff; plugging in aborts it. It
#      exists because upowerd was alive on both nights and took no action
#      through 3 h 12 min of discharge (its one log line: an inhibitor lock
#      that failed with OperationInProgress as the loop began).
#      packages/battery-emergency-poweroff has the script.
#
# THE CHARGE MODE. This IdeaPad has no charge_control_end_threshold, only
# BAT0/charge_types with three modes: Fast, Standard and Long_Life, which
# parks the cell and refills it to 80 % (packages/charge-mode has the
# measurements). The thresholds are the firmware's, not a setting. Waybar's
# battery click and the energy menu set the mode with charge-mode, without a
# password, through one sudo rule for one command: charge-mode-apply, which
# validates the mode against the kernel's list before it writes, so the
# rule cannot become an arbitrary root write. Every write saves the mode in
# /var/lib/charge-mode too, and charge-mode-restore.service puts it back at
# each boot. A new install starts from Long_Life, the boot default since
# 2026-10-03; an existing saved mode is left as it is.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.ravnix.user.username;
  inherit (pkgs.ravnix) battery-emergency-poweroff charge-mode;
in
{
  # Layer 1.
  services.upower = {
    enable = true;
    criticalPowerAction = "PowerOff";
    allowRiskyCriticalPowerAction = false;
    usePercentageForPolicy = true;
    percentageLow = 20;
    percentageCritical = 5;
    percentageAction = 2;
    # Read only with usePercentageForPolicy off; Fedora's values all the same.
    timeLow = 1200;
    timeCritical = 300;
    timeAction = 120;
  };

  # Layer 2. Inert without BAT0. The unit names no battery, so the script's
  # own default, BAT0, is the one it reads, the same as the condition's.
  systemd.services.battery-emergency-poweroff = {
    description = "Emergency poweroff when battery is nearly empty (last-resort net)";
    unitConfig.ConditionPathExists = "/sys/class/power_supply/BAT0";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe battery-emergency-poweroff;
    };
  };
  systemd.timers.battery-emergency-poweroff = {
    description = "Periodic emergency-poweroff battery check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
      AccuracySec = "30s";
    };
  };

  # The charge mode.
  environment.systemPackages = [ charge-mode ];

  assertions = [
    {
      assertion = config.security.sudo.enable;
      message = "The IdeaPad module lets the user set the battery's charge mode through a sudo rule (battery.nix), and security.sudo is off; charge-mode could only fail.";
    }
  ];
  security.sudo.extraRules = [
    {
      users = [ user ];
      runAs = "root";
      commands = [
        {
          command = "${charge-mode.apply}/bin/charge-mode-apply";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.services.charge-mode-restore = {
    description = "Restore the saved battery charge mode (BAT0/charge_types)";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/var/lib/charge-mode";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${charge-mode.restore}/bin/charge-mode-restore";
    };
  };

  # The first boot's saved mode: tmpfiles' f writes it only when the file
  # does not exist yet.
  systemd.tmpfiles.settings."10-charge-mode"."/var/lib/charge-mode".f = {
    mode = "0644";
    user = "root";
    group = "root";
    argument = "Long_Life\n";
  };
}
