# The tap's PAM and polkit lines on a running machine (modules/desktop/
# u2f.nix): the module alone, with the option on, so that the machine is
# small, plus sshd, a console login and polkit. A VM cannot touch a key and
# none is faked. What this shows is the rest:
#
#   - sudo works as before with the ravnix-tap-ask line in front of pam_u2f:
#     the password opens it, without a mapping and with one; a wrong one is
#     refused; without a terminal and without a password it fails. The line
#     names a program that is there, and it skips the tap here because no key
#     is plugged in;
#   - the line's control cannot grant: the same line pointed at `true`, which
#     always exits 0, in a stack of its own (pamtester), still refuses a wrong
#     password and takes the right one;
#   - a sudo over ssh is refused by the tool with one line in the journal,
#     and the password still works for it, as it does for any refused tap;
#   - polkit refuses pkexec and run0 from an ssh login at once, with no
#     authentication started (no polkit-agent-helper unit), while pkexec from
#     the console's local session reaches authentication.
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  keys = import "${inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
in
pkgs.testers.runNixOSTest {
  name = "desktop-u2f-vm";

  # The module reads pkgs.ravnix for the tool.
  node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [
        self.nixosModules.options
        ../../modules/desktop/u2f.nix
        ../../templates/default/me.nix
      ];
      warnings = lib.mkForce [ ];
      ravnix.security.u2f.enable = lib.mkForce true;
      users.users.${user} = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        password = "right";
        openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      };
      security.sudo.wheelNeedsPassword = true;
      security.polkit.enable = true;
      # As on the laptop, where a module of the desktop turns it on.
      security.polkit.enablePkexecWrapper = true;
      services.openssh.enable = true;
      # The local session: a console login on tty1, on seat0.
      services.getty.autologinUser = user;
      environment.systemPackages = [
        pkgs.pamtester
        pkgs.util-linux
      ];

      # sudo's line, pointed at a program that always says Allow.
      security.pam.services.tapstub.rules.auth.ravnix-tap-ask = {
        inherit (config.security.pam.services.sudo.rules.auth.ravnix-tap-ask) order control modulePath;
        args = [
          "quiet"
          "quiet_log"
          "seteuid"
          "${pkgs.coreutils}/bin/true"
        ];
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sshd.service")

    stack = machine.succeed("grep '^auth' /etc/pam.d/sudo")
    print(stack)
    lines = stack.splitlines()
    gate = [i for i, l in enumerate(lines) if "ravnix-tap-ask" in l]
    assert len(gate) == 1, stack
    assert "pam_u2f.so" in lines[gate[0] + 1], stack
    tool = [w for w in lines[gate[0]].split() if w.endswith("/bin/ravnix-tap-ask")][0]
    machine.succeed(f"test -x {tool}")

    machine.succeed(
        "install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/key",
        "ssh-keyscan localhost > /root/known_hosts 2>/dev/null",
    )
    ssh = "ssh -i /root/key -o UserKnownHostsFile=/root/known_hosts -o BatchMode=yes ${user}@localhost"

    def sudo(password):
        return f"su - ${user} -c 'echo {password} | sudo -S -k true'"

    with subtest("the password opens sudo, without a mapping and with one"):
        machine.succeed(sudo("right"))
        machine.succeed(
            "su - ${user} -c 'mkdir -p ~/.config/Yubico"
            " && echo ${user}:kh,pk,es256,+presence > ~/.config/Yubico/u2f_keys"
            " && chmod 600 ~/.config/Yubico/u2f_keys'"
        )
        machine.succeed(sudo("right"))

    with subtest("a wrong password is refused, and no password without a terminal too"):
        machine.fail(sudo("wrong"))
        machine.fail("su - ${user} -c 'sudo -k true < /dev/null'")

    with subtest("the tool runs as root and skips the tap: no key is plugged in"):
        out = machine.succeed(f"{tool} --dry-run --user ${user} --parent 1")
        assert out.strip() == "skip: No_Key", out
        machine.fail(f"PAM_USER=${user} PAM_TYPE=auth {tool}")

    with subtest("the line grants nothing when its program says Allow"):
        stub = machine.succeed("grep '^auth' /etc/pam.d/tapstub")
        print(stub)
        stub_lines = stub.splitlines()
        at = [i for i, l in enumerate(stub_lines) if "/bin/true" in l]
        assert len(at) == 1 and "[success=ignore default=1]" in stub_lines[at[0]], stub
        assert "pam_u2f.so" in stub_lines[at[0] + 1], stub
        machine.fail("echo wrong | pamtester tapstub ${user} authenticate")
        machine.succeed("echo right | pamtester tapstub ${user} authenticate")

    with subtest("a sudo over ssh is refused and logged once, and the password still works"):
        machine.succeed(f"{ssh} 'echo right | sudo -S -k true'")
        machine.wait_until_succeeds(
            "journalctl -t ravnix-tap-ask -o cat | grep -F 'refused a sudo over ssh by ${user} from'",
            timeout=30,
        )
        refused = machine.succeed("journalctl -t ravnix-tap-ask -o cat | grep -cF 'refused a sudo over ssh'")
        assert refused.strip() == "1", refused

    def helpers():
        return int(machine.succeed("journalctl -o cat | grep -c 'polkit-agent-helper' || true").strip())

    with subtest("polkit refuses pkexec from an ssh login before any authentication"):
        before = helpers()
        status, out = machine.execute(f"timeout 60 {ssh} \"script -qec 'pkexec true' /dev/null\" < /dev/null")
        print(out)
        assert status != 0, out
        assert "AUTHENTICATING" not in out, out
        assert "Not authorized" in out, out
        assert helpers() == before, "an ssh pkexec started polkit's helper"
        # run0 asks polkit the same way, through its own terminal agent.
        status, out = machine.execute(f"timeout 60 {ssh} \"script -qec 'run0 true' /dev/null\" < /dev/null")
        print(out)
        assert status != 0, out
        assert "AUTHENTICATING" not in out, out
        assert helpers() == before, "an ssh run0 started polkit's helper"

    # Reaching authentication is what the rule must allow, and all this shows:
    # in this nixpkgs, pkexec's own text agent fails afterwards on any
    # machine, ravnix or not ("No session for cookie" from the helper), which
    # a VM of NixOS's polkit and pkexec alone shows the same.
    with subtest("pkexec from the console's local session reaches authentication"):
        machine.wait_until_tty_matches("1", "${user}@machine")
        before = helpers()
        machine.send_chars("pkexec touch /tmp/pkexec-local\n")
        machine.wait_until_tty_matches("1", "AUTHENTICATING FOR org.freedesktop.policykit.exec")
        machine.wait_until_tty_matches("1", "Password: ")
        machine.wait_until_succeeds(f"test $(journalctl -o cat | grep -c 'polkit-agent-helper') -gt {before}", timeout=30)
        machine.send_chars("right\n")
  '';
}
