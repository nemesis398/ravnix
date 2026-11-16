# The Copilot key's filter on a running machine (modules/hardware/
# ideapad-pro-5-16ahp9/keys.nix), under the unit huginn gets, hardening and
# all. QEMU's PS/2 keyboard is an "AT Translated Set 2 keyboard" behind
# atkbd, as the laptop's is, and QEMU's sendkey presses a chord's keys in
# order and lets them go in reverse, as the key's firmware does: so
# `meta_l-shift-f23` is the Copilot key. The VM's virtio keyboard is off, so
# sendkey reaches the PS/2 one. evtest watches both devices.
#
#   - The service runs as a dynamic user, not root, and makes the virtual
#     keyboard 1:1:copilot-key-super on the keyboard's own bus (i8042), which
#     libinput takes for an internal keyboard.
#   - The raw keyboard is grabbed: evtest on it says so.
#   - The Copilot chord reaches the virtual keyboard as Super alone: Meta
#     down, the Shift that rode in released before anything else, no F23;
#     a plain Shift+a after it is Shift+a.
#   - A stop gives the keyboard back at once, and a killed daemon is
#     restarted and grabs again.
#   - A keyboard that goes away (atkbd unbound from its serio port) ends the
#     daemon with an error, systemd gives up after 5 starts, and with the
#     keyboard bound again the service comes back.
#
# What only the laptop can show: the real macro's timing (about 1 ms between
# its keys, against QEMU's few microseconds), its key repeat, and that
# touchpad disable-while-typing pairs with the virtual keyboard
# (tools/copilot-key-super/README.md).
{
  self,
  pkgs,
  lib,
  ...
}:
let
  ravnixPkgs = pkgs.extend self.overlays.default;
in
pkgs.testers.runNixOSTest {
  name = "hardware-copilot-key-vm";
  node.pkgs = lib.mkForce ravnixPkgs;

  nodes.machine = {
    imports = [ ../../modules/hardware/ideapad-pro-5-16ahp9/keys.nix ];
    virtualisation.qemu.virtioKeyboard = false;
    environment.systemPackages = [
      pkgs.evtest
      pkgs.libinput
    ];
  };

  testScript = ''
    import re

    def node(name):
        return machine.succeed(
            "for d in /sys/class/input/event*; do "
            f"[ \"$(cat $d/device/name)\" = '{name}' ] && basename $d; done; true"
        ).strip()

    def watch(unit, dev, log):
        machine.succeed(
            f"systemd-run --unit={unit} --property=StandardOutput=file:{log} "
            f"stdbuf -oL ${pkgs.evtest}/bin/evtest /dev/input/{dev}"
        )
        machine.wait_until_succeeds(f"grep -q 'Testing ... (interrupt to exit)' {log}")

    def keys(log):
        # (code, value) of every key event, repeats left out.
        text = machine.succeed(f"cat {log}")
        return [
            (int(c), int(v))
            for c, v in re.findall(r"type 1 \(EV_KEY\), code (\d+) \([^)]*\), value (\d+)", text)
            if v != "2"
        ]

    META, SHIFT, F23, A = 125, 42, 193, 30

    machine.wait_for_unit("copilot-key-super.service")
    machine.wait_until_succeeds("grep -qx copilot-key-super /sys/class/input/event*/device/name")
    raw = node("AT Translated Set 2 keyboard")
    virtual = node("copilot-key-super")
    assert raw and virtual, f"raw {raw!r}, virtual {virtual!r}"
    print(machine.succeed("journalctl -u copilot-key-super --no-pager"))

    with subtest("the daemon runs as a dynamic user"):
        pid = machine.succeed("systemctl show -P MainPID copilot-key-super").strip()
        uid = machine.succeed(f"awk '/^Uid:/ {{print $2}}' /proc/{pid}/status").strip()
        assert uid != "0", "copilot-key-super runs as root"
        print(machine.succeed("systemd-analyze security copilot-key-super.service --no-pager | tail -3"))

    with subtest("the virtual keyboard is what Sway and libinput look for"):
        ident = f"/sys/class/input/{virtual}/device/id"
        assert machine.succeed(f"cat {ident}/vendor").strip() == "0001"
        assert machine.succeed(f"cat {ident}/product").strip() == "0001"
        assert machine.succeed(f"cat {ident}/bustype").strip() == "0011"
        machine.succeed(
            f"libinput quirks list /dev/input/{virtual} | grep -x AttrKeyboardIntegration=internal"
        )
        # No EV_REP: the kernel does not repeat keys on its own there.
        ev = int(machine.succeed(f"cat /sys/class/input/{virtual}/device/capabilities/ev").strip(), 16)
        assert not ev & (1 << 0x14), f"the virtual keyboard has EV_REP: {ev:x}"

    with subtest("the raw keyboard is grabbed"):
        watch("watch-raw", raw, "/tmp/raw.log")
        machine.succeed("grep -q 'grabbed by another process' /tmp/raw.log")
        machine.succeed("systemctl stop watch-raw")

    with subtest("the Copilot chord is a plain Super"):
        watch("watch-virtual", virtual, "/tmp/virtual.log")
        machine.send_key("meta_l-shift-f23")
        machine.send_key("shift-a")
        want = [(META, 1), (SHIFT, 1), (SHIFT, 0), (META, 0), (SHIFT, 1), (A, 1), (A, 0), (SHIFT, 0)]
        machine.wait_until_succeeds(f"[ $(grep -c 'EV_KEY' /tmp/virtual.log) -ge {len(want)} ]")
        got = keys("/tmp/virtual.log")
        assert got == want, f"the virtual keyboard got {got}, not {want}"
        machine.succeed("systemctl stop watch-virtual")

    with subtest("a stop gives the keyboard back, a kill restarts the daemon"):
        machine.succeed("systemctl stop copilot-key-super")
        machine.wait_until_fails("grep -qx copilot-key-super /sys/class/input/event*/device/name")
        watch("watch-free", raw, "/tmp/free.log")
        machine.fail("grep -q 'grabbed by another process' /tmp/free.log")
        machine.send_key("meta_l-shift-f23")
        # Stock: the raw keyboard's macro, F23 and all.
        machine.wait_until_succeeds(f"grep -q 'code {F23} ' /tmp/free.log")
        machine.succeed("systemctl stop watch-free")
        machine.succeed("systemctl start copilot-key-super")
        machine.wait_until_succeeds("grep -qx copilot-key-super /sys/class/input/event*/device/name")
        before = machine.succeed("systemctl show -P MainPID copilot-key-super").strip()
        machine.succeed("systemctl kill -s KILL copilot-key-super")
        machine.wait_until_succeeds(
            f"p=$(systemctl show -P MainPID copilot-key-super); [ \"$p\" != 0 ] && [ \"$p\" != {before} ]"
        )
        machine.wait_until_succeeds("grep -qx copilot-key-super /sys/class/input/event*/device/name")

    with subtest("a keyboard that goes away ends the daemon, and systemd gives up"):
        machine.succeed("systemctl reset-failed copilot-key-super")
        port = machine.succeed(f"basename $(readlink -f /sys/class/input/{raw}/device/device)").strip()
        machine.succeed(f"echo -n {port} > /sys/bus/serio/drivers/atkbd/unbind")
        machine.wait_until_succeeds("journalctl -u copilot-key-super | grep -q 'is gone'")
        machine.wait_until_succeeds(
            "journalctl -u copilot-key-super | grep -q 'no input device named'"
        )
        machine.wait_until_succeeds("systemctl is-failed copilot-key-super", timeout=60)
        result = machine.succeed("systemctl show -P Result copilot-key-super").strip()
        assert result == "start-limit-hit", f"the unit failed with {result}"
        machine.succeed(f"echo -n {port} > /sys/bus/serio/drivers/atkbd/bind")
        machine.wait_until_succeeds("grep -qx 'AT Translated Set 2 keyboard' /sys/class/input/event*/device/name")
        machine.succeed("systemctl reset-failed copilot-key-super")
        machine.succeed("systemctl start copilot-key-super")
        machine.wait_until_succeeds("grep -qx copilot-key-super /sys/class/input/event*/device/name")
        print(machine.succeed("journalctl -u copilot-key-super --no-pager | tail -20"))
  '';
}
