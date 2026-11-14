# sudo's stack with the tap's lines, on a running machine (modules/desktop/
# u2f.nix): the module alone, with the option on, so that the machine is
# small. A VM cannot touch a key and none is faked, so what this shows is the
# other half: with the ravnix-tap-ask line in front of pam_u2f, sudo works as
# it did. The password opens it, without a mapping and with one; a wrong one
# is refused; sudo without a terminal and without a password still fails. The
# line names a program that is there and runs as root, and that program skips
# the tap here because no key is plugged in, which is what the jump in the
# line acts on. tests/desktop/u2f.nix checks the evaluated files, and the
# tool's own tests check what it decides.
{
  self,
  lib,
  pkgs,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
in
pkgs.testers.runNixOSTest {
  name = "desktop-u2f-vm";

  # The module reads pkgs.ravnix for the tool.
  node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

  nodes.machine = {
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
    };
    security.sudo.wheelNeedsPassword = true;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    stack = machine.succeed("grep '^auth' /etc/pam.d/sudo")
    print(stack)
    lines = stack.splitlines()
    gate = [i for i, l in enumerate(lines) if "ravnix-tap-ask" in l]
    assert len(gate) == 1, stack
    assert "pam_u2f.so" in lines[gate[0] + 1], stack
    tool = [w for w in lines[gate[0]].split() if w.endswith("/bin/ravnix-tap-ask")][0]
    machine.succeed(f"test -x {tool}")

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
  '';
}
