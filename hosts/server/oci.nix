# Root in this container is root on the Docker host. The container needs
# SYS_ADMIN, and Docker's AppArmor profile off (the compose file says why), and
# in the host's own user namespace those make root here the host's root: it can
# remount the paths Docker masks or mounts read-only and write the kernel's
# host-wide settings. So this module closes what it can: no root login over ssh
# whatever the shape allows, and no way for the account to steer root. Run the
# image only where that is acceptable.
#
# muninn as an OCI image: the server shape (default.nix, beside this module in
# a private flake) in a container that runs systemd as PID 1, so the user
# units of the workbench (herdr's server above all), sshd and the lingering
# user manager work as they do on the Proxmox VM (Task 4.2). A private flake
# imports `ravnix.nixosModules.server-oci` next to `nixosModules.server` and
# its own me.nix, and builds `system.build.ociImage`, a tarball for
# `docker load` (and `podman load`, `skopeo`, `ctr images import`).
#
#   modules = [
#     ravnix.nixosModules.server
#     ravnix.nixosModules.server-oci
#     ./me.nix
#   ];
#
# deploy/compose/muninn and deploy/k8s run the image and say which
# privileges systemd needs there.
#
# What the container form is not: it does not update itself. Everything that
# is in the image is its own, and the way to a newer muninn is a newer image,
# started in place of the old container; `nixos-rebuild switch` inside it
# would last until the container is made again. What outlives the swap is
# /home, which is a volume (root's, mode 0755), and it holds what must outlive
# it:
#   - the user's home in it: the files, Podman's storage and the login of
#     every program (not the keys that may log in: sshd takes those from the
#     configuration alone, ./deploy.nix);
#   - the host key of sshd, beside the home in a directory of root's
#     (/home/.muninn-ssh, the key itself root's and mode 0600), so a swap does
#     not change the host's identity and nobody has to accept a new key. It is
#     not in the home, because the account owns its home and could replace a
#     directory in it by a link, which root's sshd-keygen would then follow;
#   - nothing else: the Nix database is made again from the image at the
#     first boot of every container (register-nix-paths), the journal is in
#     memory, and /etc is built by the system as it boots.
# The user's id is pinned, because the files in the volume belong to a number,
# and an id that depended on the order in which accounts are made could
# change hands with an image.
#
# Not set here, because they are the host's to decide: who may log in
# (users.users.<user>.openssh.authorizedKeys.keys; sshd reads no
# ~/.ssh/authorized_keys, so a key in the volume does not log in) and the time
# zone. The host name is "muninn" unless the host
# sets another; the compose file's hostname should agree with it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.ravnix.user.username;
  toplevel = config.system.build.toplevel;
  uid = config.users.users.${user}.uid;
  gid = config.users.groups.${config.users.users.${user}.group}.gid;

  # Every store path of the system, as `nix-store --load-db` reads it.
  closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };

  # The entrypoint: what runs before the system's init, in the image's own
  # words. Docker mounts the container's cgroup tree read-only, even when the
  # container has a cgroup namespace of its own, and systemd cannot make its
  # first cgroup (/init.scope) in it ("Failed to create /init.scope control
  # group: Read-only file system"; it does not remount). With the capability
  # the compose file grants, the namespace's own tree can be made writable,
  # and in a namespace of the container's own that is the container's
  # subtree and no other container's.
  #
  # The remount is made only there. In a cgroup namespace of the container's
  # own, the container's cgroup is the root of what it sees and
  # /proc/self/cgroup says `0::/`. In any other (the host's, when the
  # launcher gave the container no namespace of its own, or one that is
  # below the root) the mount is the host's hierarchy, or a part of it that
  # the container does not own, and making that writable is not this
  # image's to do: the entrypoint says so and refuses to start. It refuses as
  # well when it cannot read the file, when the file says more than that one
  # line (cgroup v1 shows one line per controller), and when the remount
  # fails; systemd would exit at once in the last case anyway.
  #
  # The paths are arguments so that the test can run the guard against
  # stand-ins (tests/workbench/oci.nix).
  mkEntrypoint =
    {
      cgroupFile ? "/proc/self/cgroup",
      mount ? "${pkgs.util-linux}/bin/mount",
      init,
    }:
    pkgs.writeShellScript "muninn-entrypoint" ''
      cgroup=$(< ${cgroupFile}) || cgroup=
      if [ "$cgroup" != "0::/" ]; then
        echo "muninn: ${cgroupFile} says '$cgroup', not '0::/': this container has no cgroup namespace of its own, and the entrypoint will not make a cgroup tree writable that may be the host's. Start it with cgroup: private (docker run --cgroupns=private), a cgroup v2 host and SYS_ADMIN. Refusing to start." >&2
        exit 1
      fi
      ${mount} -o remount,rw /sys/fs/cgroup || {
        echo "muninn: could not make /sys/fs/cgroup writable, which systemd needs to make its first cgroup. It needs SYS_ADMIN and AppArmor off for this container. Refusing to start." >&2
        exit 1
      }
      exec ${init} "$@"
    '';
in
{
  boot.isContainer = true;

  networking = {
    hostName = lib.mkDefault "muninn";
    # Docker made the network, and a DHCP client would flush it.
    useDHCP = lib.mkDefault false;
    dhcpcd.enable = lib.mkDefault false;
    # iptables does not work in a container; the ports that matter are the
    # ones Docker publishes, and the host's firewall governs those.
    firewall.enable = false;
    # Docker puts its own resolv.conf, hosts and hostname into the container
    # as mounts of single files, and a symlink cannot replace those. They
    # stay Docker's: it knows the resolver and the container's name, and the
    # hostname of the compose file is the one set here.
    resolvconf.enable = false;
  };
  environment.etc = {
    hostname.enable = false;
    hosts.enable = false;
  };

  # nixos' container module makes sshd socket-activated, "to be light", which
  # does not work under Docker, and muninn's sshd should be up when the
  # container is.
  services.openssh = {
    startWhenNeeded = false;
    # In the volume, beside the home and not in it: see the header.
    hostKeys = lib.mkDefault [
      {
        type = "ed25519";
        path = "/home/.muninn-ssh/ssh_host_ed25519_key";
      }
    ];
    # Root in the container is root on the Docker host (the top of this file),
    # and the container is updated by an image swap and never by a login, so
    # a root login has no use here and every use against the host. The shape
    # may let root in with a key, for the deploy of a machine (Task 4.2); the
    # container form does not, whatever the shape says.
    settings.PermitRootLogin = lib.mkForce "no";
  };

  # Rootless Podman inside Docker, with what Docker's default seccomp profile
  # leaves it: crun must not join a session keyring (keyctl is blocked) and
  # must not pivot_root (blocked too; it changes root instead). The rest of
  # what nested containers need, an unmasked /proc, is the compose file's to
  # grant, and only for those who run containers in this one
  # (docker-compose.podman.yaml). Without it Podman starts and fails to mount
  # /proc for the first container, and says so.
  #
  # What it costs: a container that Podman runs in muninn changes root
  # instead of pivoting it, and can leave that root and reach muninn's file
  # system with the account's rights (rootless Podman maps the container's
  # root to the account). That is a fair trade against switching the
  # container's seccomp profile off, but in this form run only images you
  # trust.
  virtualisation.containers.containersConf.settings = {
    containers.keyring = false;
    engine.no_pivot_root = true;
  };

  users.users.${user} = {
    uid = lib.mkDefault 1000;
    # Pinned for the same reason as the id: rootless Podman's storage in the
    # volume is owned by numbers out of this range.
    subUidRanges = lib.mkDefault [
      {
        startUid = 100000;
        count = 65536;
      }
    ];
    subGidRanges = lib.mkDefault [
      {
        startGid = 100000;
        count = 65536;
      }
    ];
  };

  # The store of the image is in the container, but the Nix database that
  # says so is not: this is the database of a system installed from a
  # tarball, which registers its paths from a list on its first boot.
  systemd.services.register-nix-paths = {
    description = "Register the store paths of the image with Nix";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = "/nix-path-registration";
    };
    wantedBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "shutdown.target"
      "nix-daemon.socket"
      "nix-daemon.service"
    ];
    after = [ "local-fs.target" ];
    conflicts = [ "shutdown.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix-path-registration
      rm /nix-path-registration
      ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
    '';
  };

  # The entrypoint of the image, and the function that makes it, for a test.
  system.build.ociMkEntrypoint = mkEntrypoint;
  system.build.ociEntrypoint = mkEntrypoint { init = "${toplevel}/init"; };

  system.build.ociImage = pkgs.dockerTools.buildLayeredImage {
    name = "ravnix/muninn";
    # The tag is the hash of the image, so two images never share one and a
    # swap is a new tag in the compose file's environment.
    config = {
      # The guard above, then the system's own init: it activates the
      # configuration (users, /etc, the wrappers) and then execs systemd,
      # which is PID 1 from there on.
      Entrypoint = [ "${config.system.build.ociEntrypoint}" ];
      Env = [
        # Stage 2 tells a container from a machine by this, and does not try
        # to remount / or to bind the store with the rights of a machine.
        "container=docker"
        # What `docker exec` finds, the wrappers first as on a NixOS machine
        # (a plain user gets su and the other setuid programs from them). A
        # user's shell gets the PATH of the user (su -), which has the
        # profile on it.
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
      ];
      # systemd shuts the system down on this one, and not on SIGTERM.
      StopSignal = "SIGRTMIN+3";
      ExposedPorts."22/tcp" = { };
      Volumes."/home" = { };
      Labels = {
        "org.opencontainers.image.title" = "muninn";
        "org.opencontainers.image.description" = "The ravnix server shape, with systemd as PID 1";
        "org.opencontainers.image.source" = "https://github.com/nemesis398/ravnix";
        "org.opencontainers.image.licenses" = "AGPL-3.0-or-later";
      };
    };

    # The image brings the store paths of its closure by itself; this is
    # what is not in the store. No /etc: the system makes it, and Docker
    # puts its own files (hosts, hostname, resolv.conf) in it as mounts.
    extraCommands = ''
      mkdir -p tmp home/${user}
      cp ${closure}/registration nix-path-registration
    '';
    fakeRootCommands = ''
      chmod 1777 tmp
      chmod 0755 home
      chown ${toString uid}:${toString gid} home/${user}
      chmod 0700 home/${user}
    '';
  };
}
