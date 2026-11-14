# The login keyring after a login that gave PAM no password
# (modules/desktop/keyring.nix, ravnix.desktop.keyring.autoUnlock).
#
# Four stages, all part of this check:
#
#   eval     the evaluated hosts: off by default, and with it on the user
#            service, its credential by name, its target and the ordering
#            against the graphical session, the tray autostart and the login
#            layout; no password in the store; the setup command in the
#            option and the install doc names the credential the tool reads.
#   gate     the wrapper Sway puts before the login layout: it starts the
#            target, waits, and runs the layout with its arguments as given,
#            also when the start fails.
#   daemons  ravnix-keyring-unlock against a private dbus-daemon and the real
#            gnome-keyring-daemon 50, started as pam_gnome_keyring starts it
#            after a tap and after a password (helpers/keyring-daemon-test.sh).
#   vm       a login through greetd that gives PAM no password, with an
#            encrypted keyring and the credential made by the setup command:
#            the keyring is unlocked before Helium starts, without a prompt;
#            no credential and a wrong one leave it locked with one line.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };

  huginnOf =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        { system.stateVersion = "26.05"; }
        self.nixosModules.laptop
        self.nixosModules.hardware-ideapad-pro-5-16ahp9
      ]
      ++ modules;
    };
  # The template sets it off, as a user who has not set it up yet does.
  on = {
    ravnix.desktop.keyring.autoUnlock.enable = lib.mkForce true;
  };
  huginnOff = huginnOf [ ];
  huginn = huginnOf [ on ];
  desktop = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = hostModules ++ [
      self.nixosModules.desktop
      on
    ];
  };
  # With the Secret Service switched off, the option is an error that says why.
  noKeyring = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = hostModules ++ [
      self.nixosModules.desktop
      on
      { services.gnome.gnome-keyring.enable = lib.mkForce false; }
    ];
  };

  tool = self.packages.${system}.ravnix-keyring-unlock;
  credential = "ravnix-keyring-login";
  # The name the tool reads, from its source, so the module and the tool
  # cannot drift apart.
  toolCredential =
    let
      m = builtins.match ''.*CREDENTIAL_NAME :: "([^"]+)".*'' (
        builtins.readFile ../../tools/ravnix-keyring-unlock/main.odin
      );
    in
    if m == null then "" else lib.head m;
  setupLine = "systemd-creds --user encrypt --name=${credential} - \\";
  storePath = "~/.config/credstore.encrypted/${credential}";
  installDoc = builtins.readFile ../../docs/install-from-another-distro.md;

  units = host: host.config.systemd.user;
  serviceOf = host: (units host).services.ravnix-keyring-unlock or null;
  targetOf = host: (units host).targets.ravnix-keyring or null;
  unitText = host: name: (units host).units.${name}.text or "";

  hostChecks =
    name: host:
    let
      s = serviceOf host;
      t = targetOf host;
      sc = s.serviceConfig;
      text = unitText host "ravnix-keyring-unlock.service";
      has = l: x: lib.elem x l;
    in
    if s == null || t == null then
      [ "${name}: the service or the target is missing" ]
    else
      lib.optional (sc.Type or "" != "oneshot") "${name}: the service is not a oneshot"
      ++ lib.optional (
        sc.LoadCredentialEncrypted or "" != credential
      ) "${name}: the service does not load the credential ${credential} by name"
      # Active after its run, the service would keep the decrypted password
      # in its credentials directory for the whole session.
      ++ lib.optional (
        sc.RemainAfterExit or false != false
      ) "${name}: the service stays active, and with it the decrypted password"
      ++ lib.optional (
        sc.ExecStart or "" != "${tool}/bin/ravnix-keyring-unlock"
      ) "${name}: the service does not run the tool (${sc.ExecStart or "nothing"})"
      ++ lib.optional (
        s.wantedBy != [ ]
      ) "${name}: the service is wanted by something else than its target"
      ++ lib.optional (
        !(has t.wants "ravnix-keyring-unlock.service" && has t.after "ravnix-keyring-unlock.service")
      ) "${name}: the target does not wait for the service"
      ++
        lib.concatMap
          (
            u:
            lib.optional (
              !(has t.wantedBy u && has t.before u)
            ) "${name}: the target is not wanted by and before ${u}"
          )
          [
            "graphical-session-pre.target"
            "xdg-desktop-autostart.target"
          ]
      ++ lib.optional (
        !has t.partOf "graphical-session.target"
      ) "${name}: the target outlives the graphical session, so the next login would not unlock"
      # PartOf a target implies After it unless the unit says otherwise, and
      # after graphical-session.target is a cycle with before its pre target.
      ++
        lib.optional (!has t.before "graphical-session.target")
          "${name}: the target does not say it comes before graphical-session.target, so PartOf orders it after and makes a cycle"
      ++ lib.optional (
        host.config.ravnix.desktop.sessionLayout.after != [ "ravnix-keyring.target" ]
      ) "${name}: the login layout does not wait for the target"
      ++ lib.optional (!host.config.services.gnome.gnome-keyring.enable) "${name}: gnome-keyring is off"
      # No secret in the store: the unit loads the credential by name, from
      # the user's credstore, and sets none itself.
      ++ lib.optional (
        !lib.hasInfix "LoadCredentialEncrypted=${credential}\n" text
      ) "${name}: the unit file does not load the credential by name"
      ++ lib.optional (lib.any (k: lib.hasInfix k text) [
        "SetCredential"
        "ImportCredential"
        "LoadCredential="
        "EnvironmentFile"
        "/nix/store/${credential}"
      ]) "${name}: the unit file sets a credential of its own"
      # The environment is NixOS's default for every unit and nothing more.
      ++ map (l: "${name}: the unit sets ${l}") (
        lib.filter (
          l:
          lib.hasPrefix "Environment=" l
          && builtins.match ''Environment="(LOCALE_ARCHIVE|PATH|TZDIR)=/nix/store/[^"]*"'' l == null
        ) (lib.splitString "\n" text)
      );

  failures =
    lib.optional (
      serviceOf huginnOff != null || targetOf huginnOff != null
    ) "off: the service or the target exists"
    ++ lib.optional (
      huginnOff.config.ravnix.desktop.sessionLayout.after != [ ]
    ) "off: the login layout waits for something"
    ++ hostChecks "laptop" huginn
    ++ hostChecks "desktop" desktop
    ++ lib.optional (
      !lib.any (a: !a.assertion && lib.hasInfix "autoUnlock" a.message) noKeyring.config.assertions
    ) "without gnome-keyring the option is no error"
    ++ lib.optional (
      toolCredential != credential
    ) "the tool reads the credential ${toolCredential}, the module loads ${credential}"
    ++
      lib.concatMap
        (
          { what, text }:
          lib.optional (
            !(
              lib.hasInfix setupLine text
              && lib.hasInfix storePath text
              && lib.hasInfix "systemd-ask-password -n" text
            )
          ) "${what} lacks the setup command for ${storePath}"
        )
        [
          {
            what = "the option's description";
            text = huginn.options.ravnix.desktop.keyring.autoUnlock.enable.description;
          }
          {
            what = "docs/install-from-another-distro.md";
            text = installDoc;
          }
        ];

  evalChecks = pkgs.runCommand "desktop-keyring-autounlock-eval" { } (
    if failures == [ ] then
      "echo 'eval: off by default; the service, its credential, the target and the order hold on the laptop and the desktop' > $out"
    else
      ''
        cat >&2 <<'EOT'
        ${lib.concatStringsSep "\n" failures}
        EOT
        exit 1
      ''
  );

  homeOf = host: host.config.home-manager.users.${user};
  swayConfig = host: "${(homeOf host).xdg.configFile."sway/config".source}";

  gate = pkgs.runCommand "desktop-keyring-autounlock-gate" { } ''
    set -euo pipefail
    fail() { echo "FAIL $*" >&2; exit 1; }
    off=${swayConfig huginnOff}
    on=${swayConfig huginn}
    grep -q '^exec sway-session-layout --focus 2 ' "$off" || fail "off: the layout line changed"
    ! grep -q 'session-layout-after' "$off" || fail "off: the layout waits"
    line=$(grep '^exec .*sway-session-layout --focus 2 ' "$on") || fail "on: no layout line"
    wrapper=$(echo "$line" | sed -n 's|^exec \(/nix/store/[^ ]*-session-layout-after\) sway-session-layout .*|\1|p')
    [[ -n $wrapper ]] || fail "on: the layout line does not start with the wrapper: $line"

    # The wrapper with a stand-in for systemctl, which records its arguments
    # and fails when told to.
    mkdir bin
    cat >bin/systemctl <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$@" >"$PWD/systemctl.args"
    exit "''${STUB_RC:-0}"
    EOF
    cat >bin/layout <<'EOF'
    #!${pkgs.runtimeShell}
    printf '[%s]\n' "$@" >"$PWD/layout.args"
    exit 7
    EOF
    chmod +x bin/*
    systemctl=$(grep -o '/nix/store/[^ ]*/bin/systemctl' "$wrapper" | head -1)
    [[ -n $systemctl ]] || fail "the wrapper runs no systemctl of the store"
    sed "s|$systemctl|$PWD/bin/systemctl|" "$wrapper" >wrapper
    chmod +x wrapper

    rc=0
    ./wrapper bin/layout --focus 2 'a b' "c'd" "" >out 2>err || rc=$?
    [[ $rc == 7 ]] || fail "the layout's exit status is not passed on ($rc)"
    [[ $(cat systemctl.args) == $'--user\nstart\n--\nravnix-keyring.target' ]] || fail "systemctl got: $(cat systemctl.args)"
    [[ $(cat layout.args) == $'[--focus]\n[2]\n[a b]\n[c\'d]\n[]' ]] || fail "the layout got: $(cat layout.args)"
    [[ ! -s err ]] || fail "a start that worked printed: $(cat err)"

    rm layout.args
    rc=0
    STUB_RC=1 ./wrapper bin/layout x >out 2>err || rc=$?
    [[ $rc == 7 && -e layout.args ]] || fail "a failed start keeps the layout from running"
    grep -q 'did not start' err || fail "a failed start is not said"
    echo "gate: the layout waits for ravnix-keyring.target, gets its arguments as given, and runs when the start fails" > $out
  '';

  daemons =
    pkgs.runCommand "desktop-keyring-autounlock-daemons"
      {
        nativeBuildInputs = [
          pkgs.dbus
          pkgs.gnome-keyring
          pkgs.libsecret
          pkgs.systemd
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
        ];
        TOOL = "${tool}/bin/ravnix-keyring-unlock";
      }
      ''
        bash ${./helpers/keyring-daemon-test.sh} | tee $out
      '';

  gpuAddress = "0000:00:10.0";
  vm = pkgs.testers.runNixOSTest {
    name = "desktop-keyring-autounlock";
    # As in tests/desktop/sway.nix: the overlay and the unfree names of the
    # desktop's apps on the node's package set.
    node.pkgs = lib.mkForce (
      import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate = (import ../../lib/unfree.nix { inherit lib; }).predicate { };
        overlays = [ self.overlays.default ];
      }
    );
    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          self.nixosModules.desktop
          ../../templates/default/me.nix
          on
        ];
        warnings = lib.mkForce [ ];
        system.stateVersion = "26.05";

        # A login that gives PAM no password: greetd's initial session logs
        # the user in without authenticating, as a YubiKey tap leaves PAM
        # without a password. greetd starts when the test has set up the
        # keyring and the credential, and once per login after that.
        services.greetd.settings.initial_session = {
          command = "sway";
          inherit user;
        };
        # greetd is the display manager, which graphical.target wants; the
        # boot stops at multi-user.target so that no login comes before the
        # setup. greetd runs initial_session once per boot, which its runfile
        # records, so the test removes the file before each login.
        systemd.defaultUnit = lib.mkForce "multi-user.target";
        services.greetd.settings.general.runfile = "/run/greetd.run";

        # A TPM2 that the firmware reports, as huginn's fTPM under UEFI, so
        # that systemd-creds binds the credential to it (without UEFI,
        # systemd-analyze has-tpm2 says "partial": no firmware support).
        virtualisation.tpm.enable = true;
        virtualisation.useEFIBoot = true;

        # Software rendering, as in tests/desktop/sway.nix.
        environment.sessionVariables = {
          WLR_RENDERER = "pixman";
          WLR_NO_HARDWARE_CURSORS = "1";
        };
        ravnix.desktop.gpu.primary = gpuAddress;
        virtualisation = {
          qemu.options = [ "-vga none -device virtio-gpu-pci,bus=pcie.0,addr=0x10" ];
          memorySize = 3072;
          cores = 2;
        };
        environment.systemPackages = [ pkgs.libsecret ];
      };
    testScript = ''
      USER = "${user}"
      KEYRING_PASSWORD = "Pferd Batterie ü 42"
      SECRET = "cookie-key-0123456789"
    ''
    + builtins.readFile ./helpers/keyring-vm-test.py;
  };
in
pkgs.runCommand "desktop-keyring-autounlock"
  {
    # The stages are attributes too, so that one can be built alone:
    # nix build .#checks.SYSTEM.desktop-keyring-autounlock.daemons
    passthru = {
      inherit
        evalChecks
        gate
        daemons
        vm
        ;
    };
  }
  ''
    cat ${evalChecks} ${gate} ${daemons} > $out
    : ${vm}
  ''
