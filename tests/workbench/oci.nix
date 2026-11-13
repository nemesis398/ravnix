# The server shape, muninn, as an OCI image (hosts/server/oci.nix), with the
# template's placeholder values. Nothing here runs the image: Task 4.4's
# record, tests/workbench/oci.md, has the run on a Docker host. What this
# check can show without one is what the image is made of, and how its
# entrypoint and its deploy files behave:
#
#   - its entrypoint is a guard that execs the system's own init, which ends in
#     systemd, so systemd is PID 1. The guard is run here against stand-ins: it
#     remounts the cgroup tree only in a cgroup namespace of the container's
#     own (/proc/self/cgroup says 0::/), and refuses to start in any other, on
#     any other content of the file, with no file, and when the remount fails.
#     Its stop signal is the one systemd shuts down on, and the environment
#     tells stage 2 that it runs in a container;
#   - the volume is /home, which is root's, and in it the home of the user,
#     with everything the user's data needs to survive an image swap: the
#     host key of sshd, in a directory the account cannot rename, and a user
#     id that does not depend on the order of boot;
#   - the image holds the system's closure, a record of it for the Nix
#     database, the mount point of the home, and nothing of /etc, which the
#     system builds itself when it boots;
#   - Docker's files stay Docker's (resolv.conf, hosts, hostname), root cannot
#     log in over ssh whatever the shape allows, and Podman is set up for what
#     Docker's default seccomp profile allows;
#   - what a container does without is off: no kernel, no initrd, no firmware,
#     no boot loader, no udev, no networkd, no DHCP, no firewall, and none of
#     the laptop's programs in the closure of the system;
#   - the deploy files never pull the image, and hold the privileges they say
#     they hold and no more.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  host = import ./oci/config.nix {
    inherit
      self
      inputs
      lib
      system
      ;
  };
  # The shape as Task 4.2 sets it for the deploy: root takes a key. (A
  # priority between a module's plain value and mkForce, so that this is the
  # shape's value whatever the shape in the tree sets, and the module of the
  # container is what has to beat it.)
  hostWithDeploy = import ./oci/config.nix {
    inherit
      self
      inputs
      lib
      system
      ;
    extraModules = [
      { services.openssh.settings.PermitRootLogin = lib.mkOverride 90 "prohibit-password"; }
    ];
  };
  c = host.config;
  user = c.ravnix.user.username;
  toplevel = c.system.build.toplevel;
  image = c.system.build.ociImage;
  entrypoint = c.system.build.ociEntrypoint;
  closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };
  check = cond: msg: lib.optional (!cond) msg;

  # The programs of the laptop (modules/desktop, the graphical applications):
  # none of them is on the server, in any form. Helium is not in the list: the
  # server carries one, for the Chrome DevTools MCP server, which drives it
  # headless (modules/common/chrome-devtools-mcp.nix); the checks of that
  # module and the VM test desktop-chrome-devtools-mcp hold that it is only
  # that.
  laptopOnly = [
    "sway"
    "swaylock"
    "swayidle"
    "waybar"
    "fuzzel"
    "dunst"
    "kanshi"
    "greetd"
    "tuigreet"
    "obsidian"
    "ghostty"
    "onlyoffice-desktopeditors"
    "steam"
  ];
  # What docker-checks.sh refuses on the PATH of a running container: the
  # laptop's programs, and Helium, which the server reaches only by its store
  # path, through the wrapper, and never on a PATH. This check holds the two
  # lists together.
  notOnPath = laptopOnly ++ [ "helium" ];

  # The entrypoint, built with stand-ins: a cgroup file that is a file of the
  # store, a mount that records what it was asked, an init that says it ran.
  mkEntry = c.system.build.ociMkEntrypoint;
  fakeMount =
    ok:
    pkgs.writeShellScript "fake-mount" ''
      echo "mount $*" >> "$MOUNT_LOG"
      ${if ok then "exit 0" else "exit 1"}
    '';
  fakeInit = pkgs.writeShellScript "fake-init" ''
    echo "init $*"
  '';
  entry =
    {
      cgroup ? "0::/\n",
      cgroupFile ? pkgs.writeText "cgroup" cgroup,
      mountOk ? true,
    }:
    mkEntry {
      inherit cgroupFile;
      mount = fakeMount mountOk;
      init = fakeInit;
    };
  entryOk = entry { };
  entryHostNamespace = entry { cgroup = "0::/system.slice/docker-0123456789ab.scope\n"; };
  entryNamespaceBelowRoot = entry { cgroup = "0::/muninn\n"; };
  entryV1AndV2 = entry { cgroup = "12:cpu,cpuacct:/\n0::/\n"; };
  entryEmpty = entry { cgroup = ""; };
  entryMissing = entry { cgroupFile = "/nonexistent/cgroup"; };
  entryMountFails = entry { mountOk = false; };

  home = "/home/${user}";
  # The one file the image's sshd reads the user's keys from.
  keysFile = lib.replaceStrings [ "%u" ] [ user ] (lib.head c.services.openssh.authorizedKeysFiles);
  # The same, as docker-checks.sh writes it.
  keysFileInScript = lib.replaceStrings [ "%u" ] [ "$user" ] (lib.head c.services.openssh.authorizedKeysFiles);
  hostKey = "/home/.muninn-ssh/ssh_host_ed25519_key";
  failures =
    check c.boot.isContainer "the system is not a container (boot.isContainer)"
    ++ check (
      !c.networking.firewall.enable
    ) "the firewall is on: iptables does not work in a container, and Docker publishes the ports"
    ++ check (
      !c.networking.useDHCP && !c.networking.dhcpcd.enable
    ) "the system asks for DHCP: it would reconfigure the network that Docker made"
    ++ check (
      !c.services.openssh.startWhenNeeded
    ) "sshd is socket-activated, which does not work in a container"
    ++ check (
      !c.networking.resolvconf.enable
      && !c.environment.etc.hostname.enable
      && !c.environment.etc.hosts.enable
    ) "the system tries to own /etc/resolv.conf, hostname or hosts, which Docker mounts as single files"
    ++ check (
      !lib.hasInfix "remount" c.boot.postBootCommands
    ) "stage 2 remounts the cgroup tree without the guard of the entrypoint"
    ++ check (
      c.virtualisation.containers.containersConf.settings.containers.keyring == false
      && c.virtualisation.containers.containersConf.settings.engine.no_pivot_root == true
    ) "Podman is not set up for Docker's default seccomp profile (no keyring, no pivot_root)"
    ++
      check (map (k: k.path) c.services.openssh.hostKeys == [ hostKey ])
        "sshd's host keys are not the one in the volume, beside the home and not in it: ${
          builtins.toJSON (map (k: k.path) c.services.openssh.hostKeys)
        }"
    ++
      check (c.users.users.${user}.uid == 1000)
        "the user's id is ${
          toString c.users.users.${user}.uid
        }, not 1000: the home volume would change hands with an image swap"
    ++ check (c.users.users.${user}.subUidRanges != [ ]) "the user has no subordinate ids pinned"
    ++ check (
      c.services.openssh.settings.PasswordAuthentication == false
    ) "the shape's sshd takes a password"
    # The way a key gets in that the compose file and docker-checks.sh name:
    # the configuration's, and no file in the volume.
    ++ check (
      !c.services.openssh.authorizedKeysInHomedir
      && c.services.openssh.authorizedKeysFiles == [ "/etc/ssh/authorized_keys.d/%u" ]
    ) "sshd reads keys from more than the configuration: ${builtins.toJSON c.services.openssh.authorizedKeysFiles}, in the home: ${lib.boolToString c.services.openssh.authorizedKeysInHomedir}"
    # Root in the container is root on the Docker host, and the container only
    # updates by an image swap, so a root login has no use there. The shape
    # may allow root with a key (Task 4.2, for the deploy); the container form
    # does not, whatever the shape says.
    ++ check (
      c.services.openssh.settings.PermitRootLogin == "no"
    ) "root can log in over ssh: ${toString c.services.openssh.settings.PermitRootLogin}"
    ++
      check (hostWithDeploy.config.services.openssh.settings.PermitRootLogin == "no")
        "a shape that lets root log in with a key makes the container form let root log in: ${toString hostWithDeploy.config.services.openssh.settings.PermitRootLogin}"
    ++ check (
      c.systemd.services ? register-nix-paths
    ) "nothing registers the image's store paths with Nix"
    # What a container turns off. (The kernel, the initrd, the firmware and
    # the kernel modules are checked in the build below, in the system's
    # directory.)
    ++ check (c.boot.loader.grub.enable == false) "GRUB is on"
    ++ check (c.boot.loader.systemd-boot.enable == false) "systemd-boot is on"
    ++ check (c.boot.loader.efi.canTouchEfiVariables == false) "the system may write EFI variables"
    ++ check (!c.boot.kernel.enable) "the system has a kernel"
    ++ check (!c.services.udev.enable) "udev is on"
    ++ check (!c.systemd.network.enable) "systemd-networkd is on"
    ++ check (!c.services.lvm.enable) "LVM is on"
    ++ check (!c.console.enable) "the console (gettys) is on"
    ++ check (!c.security.audit.enable) "audit is on"
    ++ check (!c.powerManagement.enable) "power management is on"
    ++ check (image.imageName == "ravnix/muninn") "the image is ${image.imageName}, not ravnix/muninn";
in
pkgs.runCommand "workbench-oci"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.gnutar
      pkgs.yq-go
    ];
    # The image, so that `nix build .#checks.SYSTEM.workbench-oci.image`
    # builds what the test inspects.
    passthru = { inherit image; };
    conf = image.stream.conf;
  }
  ''
    status=0
    fail() {
      echo "FAIL: $*" >&2
      status=1
    }
    top=${toplevel}
    entry=${entrypoint}

    # The entrypoint is the guard, and the guard ends in the system's init,
    # which ends in systemd.
    [ "$(jq -c '.config.Entrypoint' "$conf")" = '["'"$entry"'"]' ] ||
      fail "the entrypoint is $(jq -c '.config.Entrypoint' "$conf"), not $entry"
    grep -qxF "exec $top/init \"\$@\"" "$entry" || fail "$entry does not exec $top/init"
    # PID 1 is systemd: /run/current-system is the toplevel once the system
    # is activated, and its systemd directory is the systemd of the system.
    grep -Eq '^ *exec /run/current-system/systemd/lib/systemd/systemd ' "$top/init" ||
      fail "$top/init does not exec systemd"
    [ -x "$top/systemd/lib/systemd/systemd" ] || fail "$top has no systemd to exec"
    [ "$(jq -r '.config.StopSignal' "$conf")" = SIGRTMIN+3 ] ||
      fail "the stop signal is $(jq -r '.config.StopSignal' "$conf"), not SIGRTMIN+3, which systemd shuts down on"
    jq -e '.config.Env | index("container=docker")' "$conf" >/dev/null ||
      fail "the environment does not say container=docker, so stage 2 would try to remount /"
    jq -e '.config.Volumes | has("/home")' "$conf" >/dev/null || fail "/home is no volume"
    jq -e '.config.Volumes | length == 1' "$conf" >/dev/null || fail "the image has more volumes than /home"
    jq -e '.config.ExposedPorts | has("22/tcp")' "$conf" >/dev/null || fail "port 22 is not exposed"
    # docker exec finds the programs of the system, and the wrappers (su, the
    # setuid ones) come first, as they do on a NixOS machine.
    [ "$(jq -r '.config.Env | map(select(startswith("PATH="))) | .[0]' "$conf")" = "PATH=/run/wrappers/bin:/run/current-system/sw/bin" ] ||
      fail "the PATH of the image is not the wrappers, then the system's: $(jq -r '.config.Env' "$conf")"

    # The guard, run against stand-ins. It remounts only in a cgroup namespace
    # of the container's own, whose cgroup file says 0::/, and then execs the
    # init with the arguments it was given.
    export MOUNT_LOG=$PWD/mount.log
    entry_case() { # NAME ENTRYPOINT: runs it with the arguments a and b
      rm -f "$MOUNT_LOG"
      if "$2" a b >"out.$1" 2>"err.$1"; then echo 0 >"code.$1"; else echo $? >"code.$1"; fi
    }
    entry_case ok ${entryOk}
    [ "$(cat code.ok)" = 0 ] || fail "the guard refused a cgroup namespace of the container's own: $(cat err.ok)"
    [ "$(cat "$MOUNT_LOG" 2>/dev/null)" = "mount -o remount,rw /sys/fs/cgroup" ] ||
      fail "the guard did not remount /sys/fs/cgroup read-write exactly once: $(cat "$MOUNT_LOG" 2>/dev/null)"
    [ "$(cat out.ok)" = "init a b" ] || fail "the guard did not exec the init with its arguments: $(cat out.ok)"
    refuses() { # NAME ENTRYPOINT WHAT: must exit 1, say why, mount nothing, run no init
      entry_case "$1" "$2"
      [ "$(cat "code.$1")" = 1 ] || fail "the guard did not refuse $3 (status $(cat "code.$1"))"
      grep -q 'muninn' "err.$1" || fail "the guard did not say why it refused $3: $(cat "err.$1")"
      [ ! -s "out.$1" ] || fail "the init ran after the guard refused $3"
    }
    refuses host ${entryHostNamespace} "a cgroup namespace that is the host's (0::/system.slice/...)"
    [ ! -e "$MOUNT_LOG" ] || fail "the guard remounted in the host's cgroup namespace"
    refuses below ${entryNamespaceBelowRoot} "a cgroup that is not the namespace root (0::/muninn)"
    [ ! -e "$MOUNT_LOG" ] || fail "the guard remounted below the namespace root"
    refuses v1 ${entryV1AndV2} "a file with more than one line"
    [ ! -e "$MOUNT_LOG" ] || fail "the guard remounted with a cgroup v1 line in the file"
    refuses empty ${entryEmpty} "an empty cgroup file"
    [ ! -e "$MOUNT_LOG" ] || fail "the guard remounted with an empty cgroup file"
    refuses missing ${entryMissing} "a missing cgroup file"
    [ ! -e "$MOUNT_LOG" ] || fail "the guard remounted with no cgroup file"
    refuses mount ${entryMountFails} "a failed remount"
    [ "$(cat "$MOUNT_LOG")" = "mount -o remount,rw /sys/fs/cgroup" ] || fail "the failing mount was not asked"

    # The image holds the system: its store layers name the toplevel and the
    # entrypoint.
    jq -e --arg top "$top" '[.store_layers[][]] | index($top)' "$conf" >/dev/null ||
      fail "no layer of the image holds $top"
    jq -e --arg entry "$entry" '[.store_layers[][]] | index($entry)' "$conf" >/dev/null ||
      fail "no layer of the image holds $entry"

    # What the customisation layer adds to the store: the record for the Nix
    # database, the mount point of the volume, the home in it, a /tmp, and no
    # /etc.
    layer=$(jq -r '.customisation_layer' "$conf")/layer.tar
    tar -tf "$layer" | sort >layer.txt
    for want in ./nix-path-registration ./home/ ./home/${user}/ ./tmp/; do
      grep -qxF "$want" layer.txt || fail "the customisation layer has no $want ($(tr '\n' ' ' <layer.txt))"
    done
    if grep -q '^\./etc' layer.txt; then fail "the customisation layer has an /etc, which the system builds itself"; fi
    # The record lists the system, so the database knows what the image holds.
    # (Files and not pipes: grep -q would end a pipe early, and the build's
    # pipefail would call that a failure.)
    tar -xOf "$layer" ./nix-path-registration >registration.txt
    grep -qxF "$top" registration.txt || fail "nix-path-registration does not list $top"
    # The volume is root's, and the home in it is the user's: id 1000, mode
    # 0700. The account owns its home and cannot rename what is beside it.
    tar -tvf "$layer" ./home/ >volume.txt
    grep -Eq '^drwxr-xr-x 0/0 ' volume.txt || fail "/home is not root's with mode 0755: $(cat volume.txt)"
    tar -tvf "$layer" ./home/${user}/ >home.txt
    grep -Eq '^drwx------ 1000/100 ' home.txt || fail "${home} is not the user's with mode 0700: $(cat home.txt)"

    # A system of a container has no kernel, no initrd, no firmware.
    for f in kernel initrd firmware kernel-modules; do
      [ ! -e "$top/$f" ] || fail "the system has a $f"
    done

    # The closure of the system holds none of the laptop's programs, and does
    # hold what the server is for, so the test cannot pass on an empty list.
    sed 's|^/nix/store/[a-z0-9]*-||' ${closure}/store-paths >names.txt
    for name in $(cat names.txt); do
      case "$name" in
        ${lib.concatStringsSep "|" (map (n: "${n}-[0-9]*") laptopOnly)})
          fail "the closure of the system holds $name" ;;
      esac
    done
    for want in herdr aerc systemd openssh podman; do
      grep -Eq "^$want-[0-9]" names.txt ||
        fail "the closure of the system lacks $want"
    done
    # The script that looks for them in a running container looks for these,
    # and for Helium.
    grep -qF '^(${lib.concatStringsSep "|" notOnPath})$' ${./oci/docker-checks.sh} ||
      fail "docker-checks.sh does not look for the laptop's programs the check does, and Helium"
    # sshd reads keys from the configuration alone (hosts/server/deploy.nix):
    # the one file it reads, and never the home's. The script logs in with a
    # key it puts into that file, and checks that the home's is refused.
    grep -qxF 'keys=${keysFileInScript}' ${./oci/docker-checks.sh} ||
      fail "docker-checks.sh does not put its login key into ${keysFile}, the file the image's sshd reads keys from"

    # The deploy files. Never pull: the image is loaded by hand, and a missing
    # tag must stop the start and not fetch a stranger's image from a registry
    # that runs with the rights below.
    compose=${../../deploy/compose/muninn/docker-compose.yaml}
    podman=${../../deploy/compose/muninn/docker-compose.podman.yaml}
    sts=${../../deploy/k8s/statefulset.yaml}
    yq_is() { # FILE EXPRESSION VALUE
      [ "$(yq "$2" "$1")" = "$3" ] || fail "$(basename "$1"): $2 is $(yq "$2" "$1"), not $3"
    }
    yq_is "$compose" '.services.muninn.pull_policy' never
    yq_is "$sts" 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].imagePullPolicy' Never
    yq_is "$sts" 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].securityContext.seccompProfile.type' RuntimeDefault
    yq_is "$sts" 'select(.kind == "StatefulSet") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "home") | .mountPath' /home
    # What the base file grants: SYS_ADMIN and no AppArmor, in a private cgroup
    # namespace, and nothing else.
    yq_is "$compose" '.services.muninn.cgroup' private
    yq_is "$compose" '.services.muninn.cap_add | join(",")' SYS_ADMIN
    yq_is "$compose" '.services.muninn.security_opt | join(",")' apparmor=unconfined
    yq_is "$compose" '.services.muninn.volumes[0]' home:/home
    for key in privileged network_mode devices pid ipc userns_mode; do
      yq_is "$compose" ".services.muninn.$key // \"none\"" none
    done
    yq_is "$podman" '.services.muninn.security_opt | join(",")' systempaths=unconfined
    yq_is "$podman" '.services.muninn.devices | join(",")' /dev/net/tun:/dev/net/tun
    # The files say what the grants add up to, at the top.
    for f in "$compose" "$podman"; do
      head -3 "$f" >top.txt
      grep -qF 'Root in this container is root on the Docker host' top.txt ||
        fail "$(basename "$f") does not say, at its top, that root in the container is root on the host"
    done

    ${lib.optionalString (failures != [ ]) ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      status=1
    ''}
    [ "$status" = 0 ]
    touch "$out"
  ''
