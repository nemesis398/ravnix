# How a deploy logs in to the server (hosts/server/deploy.nix), on running
# machines. muninn is the server shape with one deploy key, allowed from
# huginn's address alone; huginn deploys; other is a second machine that
# holds the same key and lets it in as root, as a host the key also opens
# would.
#
# From huginn the key opens root, without a terminal and without any
# forwarding (`restrict`), and a deploy goes through as nixos-rebuild makes
# it: `nixos-rebuild switch --store-path ... --target-host` to a Host entry
# that logs in as root, so muninn runs the new system, and `nix copy` and
# `nix-copy-closure` bring a path muninn did not have. The test counts the
# root logins of a deploy, each a touch with a security key: one with
# nixos-rebuild's own ControlMaster, six when NIX_SSHOPTS turns it off
# (ControlMaster=no or ControlPath=none), which works because nixos-rebuild
# puts NIX_SSHOPTS before its own options and ssh takes the first value of
# an option. sshd reads root's keys from the
# configuration only, so a key planted in /root/.ssh opens nothing. The
# same key is refused from other, through a
# hop over other (`ssh -J`), and from muninn itself, where the account holds
# it; each refusal is the one sshd logs for a key that is right but comes
# from the wrong address, so it is from= that refuses and not something
# else. The hop itself works: through it the account logs in with its own
# key. The account's key does not open root. Root's key file holds the
# deploy keys and nothing else, a security key's line among them.
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
  # The test's deploy key as a security key would hold it: the same public
  # key in sk-ssh-ed25519's form, for the application "ssh:". No device
  # signs with it here; it shows that root's key file takes such a line.
  skKey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIDPQXmEVMVLmeFRyafKMVWgPDkv8/uRBTwmcEDatZzMDAAAABHNzaDo= snakeoil-sk";
  # Paths that only huginn has, for the copies to bring.
  copied = pkgs.writeText "deploy-copied" "by nix copy";
  closureCopied = pkgs.writeText "deploy-closure-copied" "by nix-copy-closure";

  # Both clients: no host key prompts in a test, and only the key a command
  # names.
  clientSsh = ''
    Host *
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      IdentitiesOnly yes
      BatchMode yes
      ConnectTimeout 10
      LogLevel ERROR
  '';
in
pkgs.testers.runNixOSTest (
  { nodes, ... }:
  {
    name = "server-deploy-login-vm";

    # nixosModules.server brings the glue, whose server end reads pkgs.ravnix,
    # so the nodes' pkgs get the overlay, as modules/common/nixos.nix says for
    # a VM test.
    node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

    nodes.muninn =
      { nodes, ... }:
      {
        imports = [
          self.nixosModules.server
          ../../templates/default/me.nix
        ];
        warnings = lib.mkForce [ ];
        ravnix.editor.languages = lib.mkForce [ "nix" ];
        ravnix.server.deployKeys = lib.mkForce [
          keys.snakeOilEd25519PublicKey
          skKey
        ];
        ravnix.server.deployFrom = lib.mkForce [
          nodes.huginn.networking.primaryIPAddress
          "2001:db8::10"
        ];
        users.users.${user}.openssh.authorizedKeys.keys = [ keys.snakeOilPublicKey ];
        # What the deploy switches to: the same system with one file more.
        specialisation.deployed.configuration.environment.etc."deploy-probe".text = "deployed";
        # The test framework gives root an empty password, for a console
        # login when the test runs interactively (test-instrumentation.nix);
        # the server shape refuses a root password, and the driver needs
        # none.
        users.users.root.hashedPasswordFile = lib.mkForce null;
        # The VM boots its kernel directly; a switch installs no boot loader.
        boot.loader.grub.enable = false;
        virtualisation = {
          cores = 2;
          memorySize = 2048;
          diskSize = 4096;
        };
        system.stateVersion = "26.11";
      };

    nodes.huginn =
      { nodes, ... }:
      {
        programs.ssh.extraConfig = ''
          Host muninn-deploy
            HostName ${nodes.muninn.networking.primaryIPAddress}
            User root
            IdentityFile /root/.ssh/deploy
          Host other-hop
            HostName ${nodes.other.networking.primaryIPAddress}
            User root
            IdentityFile /root/.ssh/deploy
          ${clientSsh}
        '';
        nix.settings.experimental-features = [ "nix-command" ];
        virtualisation.additionalPaths = [
          nodes.muninn.system.build.toplevel
          copied
          closureCopied
        ];
      };

    nodes.other = {
      services.openssh.enable = true;
      users.users.root.openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      programs.ssh.extraConfig = clientSsh;
    };

    testScript =
      { nodes, ... }:
      let
        deployed = "${nodes.muninn.system.build.toplevel}/specialisation/deployed";
      in
      ''
        USER = "${user}"
        MUNINN = "${nodes.muninn.networking.primaryIPAddress}"
        HUGINN = "${nodes.huginn.networking.primaryIPAddress}"
        OTHER = "${nodes.other.networking.primaryIPAddress}"
        # On muninn, ssh reads none of the account's or the system's
        # configuration, so only these options and the key it is given count.
        BARE_SSH = (
            "ssh -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            " -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10"
        )

        start_all()
        muninn.wait_for_unit("sshd.service")
        other.wait_for_unit("sshd.service")
        huginn.wait_for_unit("multi-user.target")
        for machine in (huginn, other):
            machine.succeed("install -D -m 600 ${keys.snakeOilEd25519PrivateKey} /root/.ssh/deploy")
        huginn.succeed("install -D -m 600 ${keys.snakeOilPrivateKey} /root/.ssh/account")

        def refusals(ip):
            """How often sshd refused root a right key because of where it came from."""
            return int(muninn.succeed(
                "journalctl --no-pager -o cat"
                " | grep -F 'Authentication tried for root with correct key but not from a permitted host'"
                f" | grep -cF 'ip={ip}, ' || true"
            ).strip())

        def refused_by_from(ip, machine, command):
            before = refusals(ip)
            machine.fail(command)
            muninn.wait_until_succeeds(
                "[ \"$(journalctl --no-pager -o cat"
                " | grep -F 'Authentication tried for root with correct key but not from a permitted host'"
                f" | grep -cF 'ip={ip}, ')\" -gt {before} ]",
                timeout=30,
            )

        with subtest("root's key file holds the deploy keys, limited to deployFrom and restricted, a security key's wanting its PIN"):
            lines = muninn.succeed("cat /etc/ssh/authorized_keys.d/root").strip().splitlines()
            prefix = f'from="{HUGINN},2001:db8::10",restrict '
            assert lines == [
                prefix + "${keys.snakeOilEd25519PublicKey}",
                prefix.rstrip() + ",verify-required ${skKey}",
            ], lines
            listed = muninn.succeed("ssh-keygen -lf /etc/ssh/authorized_keys.d/root")
            assert "(ED25519)" in listed and "(ED25519-SK)" in listed, listed

        with subtest("the deploy key opens root from an address in deployFrom, without a terminal"):
            huginn.succeed("ssh muninn-deploy true")
            out = huginn.fail("ssh -tt muninn-deploy true 2>&1")
            assert "PTY allocation request failed" in out, out
            # The account's own login, which is not restricted, gets one.
            out = huginn.succeed(f"ssh -tt -i /root/.ssh/account {USER}@{MUNINN} tty 2>&1")
            assert "/dev/pts/" in out, out

        with subtest("the deploy login forwards nothing"):
            # -o LogLevel=INFO comes first, so it wins over the client's ERROR
            # and ssh prints why the channel was refused.
            out = huginn.fail("ssh -o LogLevel=INFO -W 127.0.0.1:22 muninn-deploy </dev/null 2>&1")
            assert "administratively prohibited" in out, out
            out = huginn.fail("ssh -o ExitOnForwardFailure=yes -R 0:127.0.0.1:22 muninn-deploy true 2>&1")
            assert "remote port forwarding failed" in out, out
            # The account's own login, which is not restricted, may forward.
            out = huginn.succeed(
                f"timeout 10 ssh -i /root/.ssh/account -W 127.0.0.1:22 {USER}@{MUNINN} </dev/null | head -c 8"
            )
            assert out == "SSH-2.0-", out

        with subtest("sshd reads root's keys from the configuration only"):
            spec = f"user=root,host={HUGINN},addr={HUGINN}"
            # sshd -T spells some keywords in capitals and some not.
            files = muninn.succeed(f"sshd -T -C {spec} | grep -i '^authorizedkeysfile '").split()
            assert files[1:] == ["/etc/ssh/authorized_keys.d/%u"], files
            command = muninn.succeed(f"sshd -T -C {spec} | grep -i '^authorizedkeyscommand '").split()
            assert command[1:] == ["none"], command
            muninn.succeed(
                "install -d -m 700 /root/.ssh"
                " && echo '${keys.snakeOilPublicKey}' > /root/.ssh/authorized_keys"
                " && chmod 600 /root/.ssh/authorized_keys"
            )
            huginn.fail(f"ssh -i /root/.ssh/account root@{MUNINN} true")
            muninn.succeed("rm -r /root/.ssh")

        def root_logins():
            """How many ssh connections have logged in to muninn as root so far."""
            muninn.succeed("journalctl --sync")
            return int(muninn.succeed(
                "journalctl --no-pager -o cat | grep -cF 'Accepted publickey for root from' || true"
            ).strip())

        def deploy(target, sshopts=None):
            """nixos-rebuild switch to target from huginn; the root logins it took."""
            before = root_logins()
            env = "" if sshopts is None else f"NIX_SSHOPTS='{sshopts}' "
            huginn.succeed(
                f"{env}nixos-rebuild switch --store-path {target} --target-host muninn-deploy >&2"
            )
            muninn.succeed(f"[ \"$(readlink -f /run/current-system)\" = {target} ]")
            muninn.succeed(f"[ \"$(readlink -f /nix/var/nix/profiles/system)\" = {target} ]")
            return root_logins() - before

        target = huginn.succeed("readlink -f ${deployed}").strip()
        base = "${nodes.muninn.system.build.toplevel}"

        with subtest("nixos-rebuild switch deploys as root through the restricted key"):
            logins = deploy(target)
            muninn.succeed("[ \"$(cat /etc/deploy-probe)\" = deployed ]")
            print(f"a deploy over nixos-rebuild's ControlMaster: {logins} root login(s)")
            assert logins == 1, logins

        with subtest("NIX_SSHOPTS turns nixos-rebuild's ControlMaster off"):
            without_master = deploy(base, "-o ControlMaster=no")
            muninn.fail("test -e /etc/deploy-probe")
            without_path = deploy(target, "-o ControlPath=none")
            muninn.succeed("[ \"$(cat /etc/deploy-probe)\" = deployed ]")
            print(
                f"a deploy without the master: {without_master} root logins with"
                f" ControlMaster=no, {without_path} with ControlPath=none"
            )
            # One for the copy and one for each command on muninn: the number
            # deploy/proxmox/muninn.md quotes, as touches of a security key.
            assert without_master == without_path == 6, (without_master, without_path)

        with subtest("nix copy and nix-copy-closure bring a path muninn did not have"):
            muninn.fail("nix-store --check-validity ${copied}")
            muninn.fail("nix-store --check-validity ${closureCopied}")
            # Built here, so signed by no key muninn trusts: root, whom Nix
            # trusts, may waive the check.
            huginn.succeed("nix copy --no-check-sigs --to ssh-ng://muninn-deploy ${copied}")
            huginn.succeed("nix-copy-closure --to muninn-deploy ${closureCopied}")
            muninn.succeed("nix-store --check-validity ${copied} ${closureCopied}")

        with subtest("the account's key does not open root"):
            huginn.succeed(f"ssh -i /root/.ssh/account {USER}@{MUNINN} true")
            huginn.fail(f"ssh -i /root/.ssh/account root@{MUNINN} true")

        with subtest("the same key from an address outside deployFrom is refused"):
            refused_by_from(OTHER, other, f"ssh -i /root/.ssh/deploy root@{MUNINN} true")

        with subtest("a hop through another host the key opens does not get it in"):
            huginn.succeed("ssh other-hop true")
            huginn.succeed(f"ssh -J other-hop -i /root/.ssh/account {USER}@{MUNINN} true")
            refused_by_from(OTHER, huginn, f"ssh -J other-hop -i /root/.ssh/deploy root@{MUNINN} true")

        with subtest("the key does not open root from the server itself"):
            muninn.succeed(f"install -D -m 600 -o {USER} ${keys.snakeOilEd25519PrivateKey} /home/{USER}/.ssh/deploy")
            for address in ("127.0.0.1", MUNINN):
                refused_by_from(
                    address,
                    muninn,
                    f"runuser -u {USER} -- {BARE_SSH} -i /home/{USER}/.ssh/deploy root@{address} true",
                )
      '';
  }
)
