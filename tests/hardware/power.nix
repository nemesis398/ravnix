# The power parts of the IdeaPad Pro 5 16AHP9 module and the laptop shape's
# swap, in a VM: power.nix (tuned and its three laptop profiles behind the
# power-profiles API, the energy menu and its watcher, the RAPL rule),
# battery.nix (both layers of the battery safety net, the charge mode's boot
# unit, its saved mode and its sudo rule), panel.nix (the ABM level on the
# kernel command line) and hosts/laptop/zram.nix. nvidia.nix is left out:
# the VM has no NVIDIA GPU, so its settings would do nothing here, and
# laptop-shape checks them on huginn's evaluated configuration.
#
# The VM has no battery, so the kernel's test_power module stands in for
# one: a battery and a charger whose state the test sets. With it the test
# unplugs the charger and sees tuned-ppd move to the battery profiles, picks
# each profile in the real `energy menu` (fuzzel is a stand-in that picks a
# row), lets UPower power the VM off at 2 %, boots again, and lets the
# emergency poweroff do it at 3 % with UPower masked, then once more while
# logind refuses every poweroff (a suspend held back by a delay lock, as in
# the incident's suspend loop), so the helper must ask systemd itself.
# The fake battery is test_battery, not BAT0, so the emergency poweroff
# runs by hand against it, and the unit is checked for what it runs and
# when.
#
# What only the real laptop can show (Task 3.7, and Task 3.5's first boot):
#   - the CPU policy itself: amd-pstate's EPP, the boost and the ACPI
#     platform profile that each tuned profile writes (a VM has no cpufreq
#     driver and no platform profile), and the power draw against Fedora's;
#   - charge_types on BAT0: the boot unit restoring the saved mode, and
#     charge-mode switching it through the sudo rule;
#   - the emergency poweroff and UPower on the real BAT0 and ADP0, and
#     energy-watch's unplug handling, which reads ADP0 (the VM's charger is
#     test_ac);
#   - the RAPL counters readable by the user (the VM has no RAPL);
#   - the panel's ABM level (no amdgpu here), and everything in nvidia.nix:
#     the dGPU at D3cold when idle and a suspend that completes.
# The hardware module's header lists them as "Task 3.7 checks".
{
  self,
  pkgs,
  lib,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  hw = ../../modules/hardware/ideapad-pro-5-16ahp9;
  ravnixPkgs = pkgs.extend self.overlays.default;
  helper = lib.getExe ravnixPkgs.ravnix.battery-emergency-poweroff;
  apply = "${ravnixPkgs.ravnix.charge-mode.apply}/bin/charge-mode-apply";

  # fuzzel --dmenu, as `energy menu` calls it: on the main menu it picks the
  # power profile row, in the profile list the row of ENERGY_PROFILE.
  fakeFuzzel = pkgs.writeShellScriptBin "fuzzel" ''
    prompt=""
    while [ $# -gt 0 ]; do
      [ "$1" = --prompt ] && prompt=$2
      shift
    done
    rows=$(cat)
    case "$prompt" in
      *Energy*) pattern="Power profile" ;;
      *"Power profile"*) pattern=$ENERGY_PROFILE ;;
      *) exit 1 ;;
    esac
    printf '%s\n' "$rows" | ${pkgs.gnugrep}/bin/grep -F -m 1 -- "$pattern"
  '';
in
pkgs.testers.runNixOSTest {
  name = "hardware-power";
  node.pkgs = lib.mkForce ravnixPkgs;

  nodes.machine = {
    imports = [
      self.nixosModules.options
      ../../templates/default/me.nix
      ../../hosts/laptop/zram.nix
      (hw + "/power.nix")
      (hw + "/battery.nix")
      (hw + "/panel.nix")
    ];

    # What nixosModules.common gives on huginn: the user's account.
    users.users.${user}.isNormalUser = true;
    # An active session for the user, as greetd's is on huginn: tuned-ppd
    # lets an active session's user switch the profile (polkit).
    services.getty.autologinUser = user;
    # greetd makes graphical.target the default on huginn, and tuned-ppd is
    # wanted by it.
    systemd.defaultUnit = "graphical.target";

    virtualisation.memorySize = 2048;
  };

  testScript = ''
    import shlex

    user = "${user}"
    battery_dir = "/sys/class/power_supply/test_battery"

    def as_user(command):
        return machine.succeed(f"su -l {user} -c {shlex.quote(command)}")

    # su opens no session, so the user's manager is found by its runtime
    # directory.
    def user_systemctl(arguments):
        return as_user(f"XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user {arguments}")

    def battery(**values):
        for name, value in values.items():
            machine.succeed(f"echo {value} > /sys/module/test_power/parameters/{name}")

    def tuned_is(profile):
        machine.wait_until_succeeds(
            f"tuned-adm active | grep -qx 'Current active profile: {profile}'", timeout=60
        )

    # Types `energy menu` into the user's shell on tty1: tuned-ppd lets only
    # a process of an active session switch the profile, and su opens none.
    picks = 0

    def pick(profile):
        global picks
        picks += 1
        done = f"/tmp/energy-pick-{picks}"
        machine.send_chars(
            f"PATH=${fakeFuzzel}/bin:$PATH ENERGY_PROFILE={profile} energy menu; echo $? > {done}\n"
        )
        machine.wait_for_file(done)
        status = machine.succeed(f"cat {done}").strip()
        assert status == "0", f"energy menu exited {status} picking {profile}"

    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("zram is the only swap"):
        machine.wait_for_unit("dev-zram0.swap")
        swaps = machine.succeed("swapon --noheadings --raw --show=NAME,TYPE").strip()
        assert swaps == "/dev/zram0 partition", f"the swap is {swaps!r}, not zram alone"
        algorithm = machine.succeed("cat /sys/block/zram0/comp_algorithm")
        assert "[lzo-rle]" in algorithm, f"zram compresses with {algorithm!r}, not lzo-rle"
        machine.fail("grep -Ew 'swap|none' /etc/fstab | grep -v '^#'")

    with subtest("the battery units are enabled"):
        machine.succeed("systemctl is-enabled battery-emergency-poweroff.timer")
        machine.succeed("systemctl is-enabled charge-mode-restore.service")
        machine.succeed("systemctl --global is-enabled energy-watch.service")
        machine.wait_for_unit("battery-emergency-poweroff.timer")

    with subtest("the emergency poweroff checks BAT0 every 2 minutes"):
        timers = machine.succeed(
            "systemctl show -p TimersMonotonic --value battery-emergency-poweroff.timer"
        )
        assert "OnBootUSec=2min" in timers and "OnUnitActiveUSec=2min" in timers, timers
        accuracy = machine.succeed(
            "systemctl show -p AccuracyUSec --value battery-emergency-poweroff.timer"
        ).strip()
        assert accuracy == "30s", f"the timer's accuracy is {accuracy}"
        unit = machine.succeed("systemctl cat battery-emergency-poweroff.service")
        assert "ConditionPathExists=/sys/class/power_supply/BAT0" in unit, unit
        assert "Type=oneshot" in unit, unit
        exec_start = machine.succeed(
            "systemctl show -p ExecStart --value battery-emergency-poweroff.service"
        )
        assert "argv[]=${helper} ;" in exec_start, f"the unit runs {exec_start}"

    with subtest("UPower's critical action is PowerOff"):
        conf = machine.succeed("cat /etc/UPower/UPower.conf").splitlines()
        for line in [
            "CriticalPowerAction=PowerOff",
            "AllowRiskyCriticalPowerAction=false",
            "UsePercentageForPolicy=true",
            "PercentageLow=20",
            "PercentageCritical=5",
            "PercentageAction=2",
        ]:
            assert line in conf, f"UPower.conf lacks {line}: {conf}"
        machine.wait_until_succeeds("upower -d | grep -Eq '^ +critical-action: +PowerOff$'")

    with subtest("the RAPL counters' rule is in place"):
        rule = machine.succeed("grep -v '^#' /etc/udev/rules.d/99-rapl-readable.rules").strip()
        assert rule.startswith('SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", RUN+="/nix/store/'), rule
        assert rule.endswith('/bin/chmod 0444 /sys/class/powercap/%k/energy_uj"'), rule
        chmod = rule.split('RUN+="')[1].split(" ")[0]
        machine.succeed(f"test -x {chmod}")
        machine.succeed("udevadm verify --resolve-names=never /etc/udev/rules.d/99-rapl-readable.rules")

    with subtest("the panel's ABM level is on the kernel command line"):
        machine.succeed("grep -qw amdgpu.abmlevel=2 /proc/cmdline")

    with subtest("charge mode: the saved mode, the boot unit and the sudo rule"):
        saved = machine.succeed("cat /var/lib/charge-mode")
        assert saved == "Long_Life\n", f"the saved mode is {saved!r}"
        machine.wait_until_succeeds(
            "journalctl -b -u charge-mode-restore.service | grep -q 'charge_types never appeared'"
        )
        result = machine.succeed(
            "systemctl show -p Result --value charge-mode-restore.service"
        ).strip()
        assert result == "success", f"charge-mode-restore ended with {result}"
        # sudo runs the helper for the user without a password, and it
        # refuses because there is no charge_types; nothing else runs.
        said = machine.fail(f"su -l {user} -c 'sudo -n ${apply} Long_Life 2>&1'")
        assert "charge-mode-apply: no /sys/class/power_supply/BAT0/charge_types" in said, said
        machine.fail(f"su -l {user} -c 'sudo -n true'")
        machine.fail(f"su -l {user} -c 'sudo -n /run/current-system/sw/bin/bash -c true'")
        said = as_user("charge-mode 2>&1; charge-mode set Fast 2>&1")
        assert said.count("nothing to do") == 2, said

    with subtest("tuned owns the CPU policy, with the three laptop profiles"):
        machine.wait_for_unit("tuned.service")
        machine.wait_for_unit("tuned-ppd.service")
        listed = machine.succeed("tuned-adm list")
        for profile in ["laptop-ac", "laptop-battery", "laptop-performance-battery"]:
            assert f"- {profile} " in listed, f"tuned has no {profile}: {listed}"
        tuned_is("laptop-ac")

    with subtest("energy-watch runs in the user's session"):
        machine.wait_for_unit("default.target", user)
        user_systemctl("start energy-watch.service")
        machine.wait_until_succeeds(f"pgrep -u {user} -f 'gdbus monitor --system --dest org.freedesktop.UPower'")
        machine.wait_until_succeeds(f"pgrep -u {user} -f 'gdbus monitor --system --dest net.hadess.PowerProfiles'")
        # Its PATH is the user manager's, from environment.d, which puts the
        # setuid wrappers first: a Waybar the watcher relaunches finds the
        # setuid sudo that charge-mode needs, and the session's tools.
        pid = user_systemctl("show -p MainPID --value energy-watch.service").strip()
        environ = machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ").splitlines()
        path = next((line[5:] for line in environ if line.startswith("PATH=")), "")
        for directory in ["/run/wrappers/bin", f"/etc/profiles/per-user/{user}/bin", "/run/current-system/sw/bin"]:
            assert directory in path.split(":"), f"energy-watch's PATH lacks {directory}: {path}"
        sudo = machine.succeed(f"env -i PATH={shlex.quote(path)} sh -c 'command -v sudo'").strip()
        assert sudo == "/run/wrappers/bin/sudo", f"energy-watch's PATH finds {sudo}, not the setuid sudo"

    with subtest("energy picks the profiles on the charger"):
        machine.wait_until_tty_matches("1", f"{user}@machine")
        pick("performance")
        tuned_is("throughput-performance")
        pick("power-saver")
        tuned_is("powersave")
        pick("balanced")
        tuned_is("laptop-ac")

    with subtest("unplugged, tuned-ppd moves to the battery profiles"):
        machine.succeed("modprobe test_power")
        battery(ac_online="off", usb_online="off", battery_status="discharging")
        machine.wait_until_succeeds(
            "busctl get-property org.freedesktop.UPower /org/freedesktop/UPower"
            " org.freedesktop.UPower OnBattery | grep -qx 'b true'"
        )
        tuned_is("laptop-battery")
        pick("performance")
        tuned_is("laptop-performance-battery")
        pick("power-saver")
        tuned_is("powersave")
        pick("balanced")
        tuned_is("laptop-battery")

    with subtest("plugged in again, back to laptop-ac"):
        battery(ac_online="on", battery_status="charging")
        tuned_is("laptop-ac")
        battery(ac_online="off", battery_status="discharging")
        tuned_is("laptop-battery")

    with subtest("energy-watch lived through the events"):
        user_systemctl("is-active energy-watch.service")
        restarts = user_systemctl("show -p NRestarts --value energy-watch.service").strip()
        assert restarts == "0", f"energy-watch restarted {restarts} times"

    with subtest("the emergency poweroff leaves 4 % alone"):
        battery(battery_capacity=4)
        machine.succeed(f"${helper} {battery_dir}")
        machine.fail("journalctl -b -t battery-emergency-poweroff | grep -q powering")

    with subtest("at 3 %, plugging in during the warning aborts the poweroff"):
        battery(battery_capacity=3)
        machine.succeed(
            f"systemd-run --unit=emergency-abort -p RemainAfterExit=yes ${helper} {battery_dir}"
        )
        machine.wait_until_succeeds(
            "journalctl -b -t battery-emergency-poweroff"
            " | grep -q 'battery at 3% and discharging, powering off in 10s'"
        )
        battery(ac_online="on", battery_status="charging")
        machine.wait_until_succeeds(
            "systemctl show -p SubState --value emergency-abort.service | grep -qx exited",
            timeout=30,
        )
        status = machine.succeed(
            "systemctl show -p ExecMainStatus --value emergency-abort.service"
        ).strip()
        assert status == "0", f"the aborted run exited {status}"

    with subtest("at 2 %, UPower powers the machine off"):
        battery(ac_online="off", battery_status="discharging", battery_capacity=2)
        machine.wait_until_succeeds(
            "upower -i /org/freedesktop/UPower/devices/DisplayDevice"
            " | grep -Eq 'warning-level: +action'"
        )
        # logind names who asked; the emergency poweroff's unit is skipped
        # without BAT0, so it can only be upowerd.
        machine.wait_for_console_text(r"poweroff requested from client PID [0-9]+ \('upowerd'\)")
        machine.wait_for_shutdown()

    with subtest("at 3 %, with UPower masked, the emergency poweroff powers off"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("systemctl mask --runtime --now upower.service")
        machine.succeed("modprobe test_power")
        battery(
            ac_online="off", usb_online="off", battery_status="discharging", battery_capacity=3
        )
        machine.succeed(f"systemd-run --unit=emergency-poweroff ${helper} {battery_dir}")
        machine.wait_for_console_text("battery at 3% and discharging, powering off in 10s")
        machine.wait_for_console_text("System is powering down")
        machine.wait_for_shutdown()

    with subtest("when logind refuses, the emergency poweroff asks systemd itself"):
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("systemctl mask --runtime --now upower.service")
        # A suspend that a delay lock holds back, as the failing suspend loop
        # of the incident kept logind busy: until it ends, logind refuses
        # every other action, and systemctl poweroff gives up on that.
        machine.succeed(
            "mkdir -p /run/systemd/logind.conf.d"
            " && printf '[Login]\\nInhibitDelayMaxSec=600\\n' > /run/systemd/logind.conf.d/50-hold.conf"
            " && systemctl reload systemd-logind"
        )
        # PID 1's PATH has no coreutils, so sleep is named by its path.
        machine.succeed(
            "systemd-run --unit=hold-sleep systemd-inhibit --what=sleep --mode=delay"
            " --who=hold-sleep /run/current-system/sw/bin/sleep infinity"
        )
        machine.wait_until_succeeds(
            "systemd-inhibit --list --no-legend | grep -q hold-sleep", timeout=30
        )
        machine.succeed("systemctl suspend")
        refused = machine.fail("systemctl poweroff 2>&1")
        assert "already in progress" in refused, f"logind did not refuse the poweroff: {refused}"
        machine.succeed("modprobe test_power")
        battery(
            ac_online="off", usb_online="off", battery_status="discharging", battery_capacity=3
        )
        machine.succeed(f"systemd-run --unit=emergency-fallback ${helper} {battery_dir}")
        machine.wait_for_console_text("battery at 3% and discharging, powering off in 10s")
        machine.wait_for_console_text(
            "logind refused the poweroff; starting poweroff.target directly", timeout=60
        )
        machine.wait_for_console_text("reboot: Power down", timeout=120)
        machine.wait_for_shutdown()
  '';
}
