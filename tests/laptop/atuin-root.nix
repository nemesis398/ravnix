# root's atuin on huginn (hosts/laptop/atuin-root.nix): root's shell history
# in the same shared timeline as the user's. Evaluated: root's config and where
# it goes, the shell init that root's bash reads and nobody else's, atuin and
# the login helper on the PATH, and none of it on the server. Run: the init
# file in a real interactive bash, which must bind atuin and hook bash-preexec,
# and a second bash that reads /etc/bashrc as a user and must not. The login
# to the account is state with secrets, and not tested here
# (tests/bin/atuin-root-login.nix).
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        ../../templates/default/me.nix
        { system.stateVersion = "26.05"; }
      ]
      ++ modules;
    };
  laptop = [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  huginn = build laptop;
  # huginn with an atuin service, as the private flake places it.
  synced = huginn.extendModules {
    modules = [
      {
        ravnix.services.atuin = {
          enable = true;
          host = "nas";
          port = 8888;
        };
      }
    ];
  };
  muninn = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = (import ../flake/helpers/host-modules.nix { inherit lib; }) ++ [ self.nixosModules.server ];
  };

  check = cond: msg: lib.optional (!cond) msg;
  rules = s: s.config.systemd.tmpfiles.settings."10-ravnix-atuin-root" or { };
  configOf =
    s:
    let
      link = (rules s)."/root/.config/atuin/config.toml"."L+" or { };
    in
    if link ? argument then builtins.fromTOML (builtins.readFile link.argument) else null;
  helperOf = s: lib.findFirst (p: (p.pname or p.name or "") == "atuin-root-login") null s.config.environment.systemPackages;
  hasPackage = s: name: lib.any (p: (p.pname or p.name or "") == name) s.config.environment.systemPackages;

  failures =
    # The directories are root's alone, and the config is linked into them.
    check (
      lib.all (
        d:
        lib.getAttrs [ "mode" "user" "group" ] ((rules huginn).${d}.d or { mode = null; user = null; group = null; }) == {
          mode = "0700";
          user = "root";
          group = "root";
        }
      ) [
        "/root/.config"
        "/root/.config/atuin"
      ]
    ) "root's .config and .config/atuin are not made 0700 root:root"
    # root's config: no update check; sync only where the service is placed,
    # at its address, as the user's atuin does.
    ++ check (configOf huginn != null) "root has no atuin config linked at /root/.config/atuin/config.toml"
    ++ check ((configOf huginn).update_check or true == false) "root's atuin checks for updates, which the Nix package leaves to the flake"
    ++ check (!((configOf huginn).auto_sync or true)) "root's atuin syncs with no service placed"
    ++ check (!((configOf huginn) ? sync_address)) "root's atuin names a sync server with no service placed"
    ++ check ((configOf synced).auto_sync or false) "root's atuin does not sync where the service is placed"
    ++ check (
      (configOf synced).sync_address or null == synced.config.ravnix.services.atuin.url
    ) "root's sync_address is not the service's URL"
    # atuin and the login helper are on the PATH, for `sudo atuin ...`.
    ++ check (hasPackage huginn "atuin") "atuin is not on huginn's PATH, so root's shell cannot run it"
    ++ check (hasPackage huginn "atuin-root-login") "atuin-root-login is not installed"
    # The init is read by a shell of uid 0 and by no other.
    ++ check (
      lib.hasInfix ''if [ "$EUID" -eq 0 ]; then'' huginn.config.environment.etc.bashrc.text
    ) "/etc/bashrc does not gate root's atuin init on EUID 0"
    ++ check (
      lib.hasInfix "atuin-root-init.bash" huginn.config.environment.etc.bashrc.text
    ) "/etc/bashrc does not read root's atuin init"
    # Not on the server.
    ++ check ((rules muninn) == { }) "the server links an atuin config for root"
    ++ check (!(lib.hasInfix "atuin-root-init" muninn.config.environment.etc.bashrc.text)) "the server's /etc/bashrc reads root's atuin init"
    ++ check (!(hasPackage muninn "atuin-root-login")) "the server installs atuin-root-login";

  # The init file, as /etc/bashrc reads it.
  initFile =
    let
      text = huginn.config.environment.etc.bashrc.text;
      m = builtins.match ".*(/nix/store/[a-z0-9]+-atuin-root-init.bash).*" (builtins.replaceStrings [ "\n" ] [ " " ] text);
    in
    if m == null then null else builtins.head m;
in
pkgs.runCommand "laptop-atuin-root"
  {
    # atuin on the PATH, as environment.systemPackages puts it on huginn's.
    nativeBuildInputs = [
      pkgs.atuin
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
    ];
    INIT = initFile;
    # The helper as each host gets it: with the service's URL written in, and
    # without one where no service is placed (it refuses then).
    HELPER_SYNCED = lib.getExe (helperOf synced);
    HELPER_BARE = lib.getExe (helperOf huginn);
    SYNC_URL = synced.config.ravnix.services.atuin.url;
    BASHRC = huginn.config.environment.etc.bashrc.source;
  }
  (
    if failures != [ ] then
      ''
        printf '%s\n' ${lib.escapeShellArgs failures} >&2
        exit 1
      ''
    else
      ''
        export HOME="$TMPDIR/home" TERM=xterm
        mkdir -p "$HOME"
        fail() { echo "FAIL: $*" >&2; exit 1; }
        [ -n "$INIT" ] && [ -r "$INIT" ] || fail "no readable init file: $INIT"

        # The helper knows the server it logs in to: the service's URL where
        # one is placed, and none (so it refuses) where not.
        grep -qxF "sync_address=$SYNC_URL" "$HELPER_SYNCED" || fail "the helper on a host with the service does not have $SYNC_URL written in"
        grep -qx "sync_address='''" "$HELPER_BARE" || fail "the helper on a host without the service has an address written in"

        # As root's shell reads it: bash-preexec is loaded, atuin's hooks are
        # in, Ctrl-R is atuin's and the up arrow is left to bash (--disable-up-arrow).
        probe=$(bash --norc --noprofile -i -c '
          . "$INIT"
          declare -F __bp_precmd_invoke_cmd >/dev/null || echo "NO-PREEXEC"
          [[ -n ''${ATUIN_SESSION:-} ]] || echo "NO-SESSION"
          declare -F __atuin_preexec >/dev/null || echo "NO-ATUIN-HOOK"
          [[ ''${__atuin_bind_ctrl_r:-} == true ]] || echo "NO-CTRL-R"
          [[ ''${__atuin_bind_up_arrow:-} == false ]] || echo "UP-ARROW-BOUND"
          echo done
        ' 2>&1) || true
        echo "$probe"
        case "$probe" in *NO-[A-Z]*|*UP-ARROW-BOUND*) fail "root's init does not set up atuin as described";; esac
        case "$probe" in *done*) ;; *) fail "the probe did not finish";; esac

        # As a user's shell reads /etc/bashrc: no atuin at all. The gate is on
        # EUID, which a shell cannot be made to lie about, so the same file
        # with the gate opened shows that it is the gate that keeps atuin out.
        [ "$(id -u)" != 0 ] || fail "the build runs as root; the gate cannot be shown"
        sed 's/"\$EUID" -eq 0/0 -eq 0/' "$BASHRC" > "$TMPDIR/bashrc-open"
        grep -q '0 -eq 0' "$TMPDIR/bashrc-open" || fail "the gate is not in /etc/bashrc as the test expects"
        probe_rc() {
          env -i PATH="$PATH" HOME="$HOME" TERM=xterm __ETC_PROFILE_DONE=1 RC="$1" \
            bash --norc --noprofile -i -c '
              . "$RC"
              [[ -n ''${ATUIN_SESSION:-} ]] && echo "ATUIN-LOADED" || echo "NO-ATUIN"
            ' 2>&1 || true
        }
        probe=$(probe_rc "$BASHRC")
        echo "$probe"
        case "$probe" in *NO-ATUIN*) ;; *) fail "a user shell that read /etc/bashrc got atuin: $probe";; esac
        probe=$(probe_rc "$TMPDIR/bashrc-open")
        echo "$probe"
        case "$probe" in *ATUIN-LOADED*) ;; *) fail "with the gate open, /etc/bashrc does not load atuin: $probe";; esac
        touch $out
      ''
  )
