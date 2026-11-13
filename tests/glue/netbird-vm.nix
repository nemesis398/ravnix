# The server's NetBird client (modules/glue/netbird.nix) on a running
# machine: the server shape's setting, with the glue module and the options
# alone (the rest of the shape needs no VM for this). A nixosTest has no
# network to a management server, so the client is never enrolled. What runs
# is what muninn runs before its setup key is entered: netbird.service starts
# and stays up, `netbird status` answers (disconnected here, because the
# management server cannot be reached) instead of failing, the config has the
# management URL of the option and the routes of the mesh switched off, no port
# is open or listened on, and NetBird adds no route. `netbird up` offers
# --setup-key-file. Not checked: an enrollment (and so the key on stdin), and
# the NeedsLogin state of a client that reaches an unenrolled management
# server.
{
  self,
  lib,
  pkgs,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "glue-netbird-vm";

  nodes.machine = {
    imports = [
      self.nixosModules.options
      ../../templates/default/me.nix
      ../../modules/glue/netbird.nix
    ];
    ravnix.shape = "server";
    warnings = lib.mkForce [ ];
    environment.systemPackages = [ pkgs.jq ];
    system.stateVersion = "26.05";
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("netbird.service")

    with subtest("the client answers"):
      # The management server does not answer here (the name does not
      # resolve), so the client is disconnected.
      out = machine.wait_until_succeeds("netbird status 2>&1 | grep -q 'Management: Disconnected' && netbird status 2>&1", timeout=60)
      assert "Daemon version" in out and "NetBird IP: N/A" in out, out

    with subtest("the config holds the option's management URL and no routes"):
      machine.wait_until_succeeds("jq -e '.ManagementURL.Host == \"netbird.example.org:443\" and .ManagementURL.Scheme == \"https\"' /var/lib/netbird/config.json", timeout=60)
      machine.succeed("jq -e '.DisableClientRoutes == true' /var/lib/netbird/config.json")

    with subtest("no port is open, and nothing listens for the mesh"):
      rules = machine.succeed("iptables -S; ip6tables -S")
      for port in ["51820", "22054", "5353"]:
        assert port not in rules, port + " is open:\n" + rules
      assert not [l for l in rules.splitlines() if "-i wt0" in l and "ACCEPT" in l], rules
      listening = machine.succeed("ss -H -ulnp")
      assert "51820" not in listening, listening

    with subtest("the server's own routes and resolver are untouched"):
      machine.fail("ip route show table all | grep -q 'dev wt0'")
      machine.succeed("getent hosts machine")

    with subtest("the enrollment command takes a key file"):
      assert "--setup-key-file" in machine.succeed("netbird up --help 2>&1")
  '';
}
