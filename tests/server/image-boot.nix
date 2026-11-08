# The server's VM images (hosts/server/images.nix) boot. Each image is built
# from a small host, the VM module and nothing of the workbench, and started
# in QEMU with UEFI firmware whose NVRAM has no boot entry, on two SCSI disks
# as Proxmox gives them (the image, and the home volume), each made larger
# than the image first. Inside, a check runs at the end of the boot and
# reports on the serial port: started by EFI from the fallback path; root and
# /home found by label and grown to their disks; the account's home directory
# on the home volume and the account's own.
#
# The qcow2, which Proxmox runs, then takes a deploy as `nixos-rebuild switch`
# makes one: the host's own toplevel, without the image's module, is set as
# the system profile and its boot loader installed, and the VM reboots. The
# check runs again in that system, and the test wants the toplevel it booted
# to be the host's. That is what tests/server/images.nix shows from the
# configuration, here on a running VM.
#
# The VMDK, and the disks inside the OVA (unpacked from it, its home volume
# included), are started once each. All of them on virtio-scsi, as Proxmox
# runs them: VMware's controllers and VirtualBox's SATA, and the initrd
# drivers the images add for them, are not exercised here.
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  # What runs at the end of every boot: the checks, then on the image's first
  # boot the deploy and a reboot, and otherwise a power-off.
  checkModule =
    { config, pkgs, ... }:
    {
      networking.hostName = "image-test";
      system.stateVersion = "26.11";
      users.users.tester.isNormalUser = true;
      boot.loader.timeout = 0;
      systemd.services.image-check = {
        wantedBy = [ "multi-user.target" ];
        after = [ "multi-user.target" ];
        path = [
          config.nix.package
          pkgs.util-linux
          pkgs.coreutils
          pkgs.systemd
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          say() { echo "IMAGE-CHECK: $*" >/dev/ttyS0; }
          failed=0
          check() {
            if ! eval "$2"; then
              say "FAIL $1"
              failed=1
            fi
          }
          check "started by EFI" '[ -d /sys/firmware/efi ]'
          check "systemd-boot on the fallback path" '[ -e /boot/EFI/BOOT/BOOTX64.EFI ] && [ -e /boot/loader/loader.conf ]'
          check "root is the file system labelled nixos" '[ "$(findmnt -no LABEL /)" = nixos ]'
          check "root grew to its disk" '[ "$(df -B1M --output=size / | tail -n 1)" -gt 5000 ]'
          check "/home is the volume labelled home" '[ "$(findmnt -no LABEL /home)" = home ]'
          check "/home grew to its disk" '[ "$(df -B1M --output=size /home | tail -n 1)" -gt 1800 ]'
          check "the home directory is on the home volume" '[ "$(findmnt -no TARGET -T /home/tester)" = /home ]'
          check "the home directory is the account's" '[ "$(stat -c %U /home/tester)" = tester ]'
          if [ "$failed" != 0 ]; then
            say "FAILED"
          elif [ -e /etc/image-check/deploy ]; then
            next=$(cat /etc/image-check/deploy)
            say "BOOT-OK first $(readlink -f /run/booted-system)"
            nix-env -p /nix/var/nix/profiles/system --set "$next"
            "$next/bin/switch-to-configuration" boot
            say "DEPLOYED $next"
            systemctl reboot
            exit 0
          else
            say "BOOT-OK final $(readlink -f /run/booted-system)"
          fi
          systemctl poweroff
        '';
      };
    };

  hostOf =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.server-vm
        checkModule
        extra
      ];
    };
  # The host as a deploy installs it, and the host that carries that toplevel
  # in its image, so the first boot can deploy it.
  host = hostOf { };
  deploying = hostOf {
    system.extraDependencies = [ host.config.system.build.toplevel ];
    environment.etc."image-check/deploy".text = "${host.config.system.build.toplevel}";
  };

  ovmf = pkgs.OVMF.fd;
  boot =
    {
      name,
      prepare,
      want,
    }:
    pkgs.runCommand "server-image-boot-${name}"
      {
        nativeBuildInputs = [
          pkgs.qemu_kvm
          pkgs.qemu-utils
          pkgs.gnutar
        ];
        requiredSystemFeatures = [ "kvm" ];
      }
      ''
        ${prepare}
        qemu-img resize -f qcow2 disk.qcow2 6G
        qemu-img resize -f qcow2 home.qcow2 2G
        cp ${ovmf}/FV/OVMF_VARS.fd vars.fd
        chmod u+w vars.fd
        timeout 1200 qemu-kvm -machine q35 -m 2048 -smp 2 -display none -no-user-config -nodefaults \
          -serial file:serial.log \
          -drive if=pflash,format=raw,unit=0,readonly=on,file=${ovmf}/FV/OVMF_CODE.fd \
          -drive if=pflash,format=raw,unit=1,file=vars.fd \
          -device virtio-scsi-pci,id=scsi \
          -drive if=none,id=system,format=qcow2,file=disk.qcow2 -device scsi-hd,drive=system,bus=scsi.0 \
          -drive if=none,id=home,format=qcow2,file=home.qcow2 -device scsi-hd,drive=home,bus=scsi.0 \
          || { echo "QEMU did not end by itself"; tail -n 60 serial.log; exit 1; }
        grep 'IMAGE-CHECK' serial.log || true
        for line in ${lib.escapeShellArgs want}; do
          grep -qF "IMAGE-CHECK: $line" serial.log || {
            echo "the serial log lacks: $line"
            tail -n 80 serial.log
            exit 1
          }
        done
        ! grep -q 'IMAGE-CHECK: FAIL' serial.log || exit 1
        cp serial.log $out
      '';

  qcow2 = deploying.config.system.build.images.qemu-efi;
  vmdk = host.config.system.build.images.vmware;
  ova = host.config.system.build.images.virtualbox;
  home = host.config.system.build.homeVolume;
  toplevel = host.config.system.build.toplevel;
in
pkgs.runCommand "server-image-boot"
  {
    runs = [
      (boot {
        name = "qcow2";
        prepare = ''
          cp ${qcow2}/${qcow2.passthru.filePath} disk.qcow2
          cp ${home}/home.qcow2 home.qcow2
          chmod u+w disk.qcow2 home.qcow2
        '';
        want = [
          "BOOT-OK first"
          "DEPLOYED ${toplevel}"
          "BOOT-OK final ${toplevel}"
        ];
      })
      (boot {
        name = "vmdk";
        prepare = ''
          qemu-img convert -f vmdk -O qcow2 ${vmdk}/${vmdk.passthru.filePath} disk.qcow2
          qemu-img convert -f vmdk -O qcow2 ${home}/home.vmdk home.qcow2
        '';
        want = [ "BOOT-OK final" ];
      })
      (boot {
        name = "ova";
        prepare = ''
          tar -xf ${ova}/${ova.passthru.filePath}
          ls -l
          disks=( *-disk*.vmdk )
          [ "''${#disks[@]}" = 2 ] || { echo "the OVA holds ''${#disks[@]} disks, not 2"; exit 1; }
          qemu-img convert -f vmdk -O qcow2 "''${disks[0]}" disk.qcow2
          qemu-img convert -f vmdk -O qcow2 "''${disks[1]}" home.qcow2
          # VirtualBox's own element for the machine's firmware, not any EFI
          # in the file.
          grep -qF '<Firmware type="EFI"/>' *.ovf || { echo "the OVA's machine does not start by EFI"; exit 1; }
        '';
        want = [ "BOOT-OK final" ];
      })
    ];
  }
  ''
    for run in $runs; do
      echo "== $run"
      grep 'IMAGE-CHECK' "$run"
    done
    touch $out
  ''
