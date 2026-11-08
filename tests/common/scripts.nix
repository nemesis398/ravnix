# The bin-* scripts as packages (packages/NAME, installed by
# modules/common/scripts.nix and modules/desktop/scripts.nix):
#
#   - a host with nixosModules.common has exactly the common commands in its
#     user's profile, and a host with nixosModules.desktop on top of it has
#     exactly the common and the desktop ones;
#   - every package builds, which for Bash is shellcheck passing at build
#     time (writeShellApplication), and has exactly the commands listed here
#     in its bin/;
#   - every command starts, with --help or the cheapest harmless invocation
#     it has, in a sandbox with no network and no home directory, and says so
#     in its output. A command that needs a tool of the session (claude, btop)
#     gets a stand-in from this file, which also proves that it is looked up
#     on the PATH and not built in.
#
# with-secret-env, the helper that claude-artifacts and claude-bg carry, is a
# package too but no command of the user's: it builds and starts here, and is
# in neither profile.
#
# The behavior of the scripts is in the tests of their own (checks bin-*).
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  # package -> the commands its bin/ holds.
  commonScripts = {
    agent-doctor = [ "agent-doctor" ];
    ccna-deck = [ "ccna-deck" ];
    claude-artifacts = [ "claude-artifacts" ];
    claude-bg = [ "claude-bg" ];
    claude-telemetry = [ "claude-telemetry" ];
    dl-video = [ "dl-video" ];
    sap-deck = [ "sap-deck" ];
    searx = [ "searx" ];
    vault-check = [ "vault-check" ];
  };
  desktopScripts = {
    bt-game-codec = [ "bt-game-codec" ];
    btop-gpu = [
      "btop-auto"
      "btop-gpu"
    ];
    fix-display = [
      "fix-display"
      "panel-crtc"
    ];
    machine-facts = [ "machine-facts" ];
    magic-trackpad-battery = [ "magic-trackpad-battery" ];
  };
  allScripts = commonScripts // desktopScripts;
  sorted = lib.sort lib.lessThan;

  # A host with the module(s) and the template's me.nix, and the scripts the
  # user's profile holds.
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  scriptsOf =
    modules:
    let
      host = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        modules = hostModules ++ modules;
      };
      user = host.config.ravnix.user.username;
    in
    sorted (
      lib.filter (name: allScripts ? ${name}) (
        map lib.getName host.config.home-manager.users.${user}.home.packages
      )
    );
  # Every package of the user's profile, by name.
  profileOf =
    modules:
    let
      host = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        modules = hostModules ++ modules;
      };
    in
    map lib.getName host.config.home-manager.users.${host.config.ravnix.user.username}.home.packages;
  onCommon = scriptsOf [ self.nixosModules.common ];
  onDesktop = scriptsOf [
    self.nixosModules.common
    self.nixosModules.desktop
  ];

  failures =
    lib.optional (
      onCommon != sorted (lib.attrNames commonScripts)
    ) "a host with common has the scripts [${toString onCommon}], expected [${toString (sorted (lib.attrNames commonScripts))}]"
    ++ lib.optional (lib.elem "with-secret-env" (
      profileOf [
        self.nixosModules.common
        self.nixosModules.desktop
      ]
    )) "with-secret-env is in the user's profile; it belongs to the launchers that carry it"
    ++ lib.optional (
      onDesktop != sorted (lib.attrNames allScripts)
    ) "a host with desktop has the scripts [${toString onDesktop}], expected [${toString (sorted (lib.attrNames allScripts))}]";

  package = name: self.packages.${system}.${name};

  # What each command is run with, and what its output must hold. Stand-ins
  # for the tools of the session are the two scripts below.
  claude = pkgs.writeShellScriptBin "claude" ''
    echo "claude-stand-in $*"
  '';
  invocations = [
    {
      cmd = "agent-doctor --help";
      says = "usage: agent-doctor";
    }
    {
      cmd = "bt-game-codec";
      says = "usage: bt-game-codec on|off";
    }
    {
      cmd = "btop-auto --version";
      says = "btop version";
    }
    {
      cmd = "btop-gpu --version";
      says = "btop version";
    }
    {
      cmd = "ccna-deck --help";
      says = "usage: ccna-deck";
    }
    {
      cmd = "claude-artifacts --version";
      says = "claude-stand-in --settings";
    }
    {
      cmd = "claude-bg --version";
      says = "claude-stand-in --bg --version";
    }
    {
      cmd = "claude-telemetry --help";
      says = "usage: claude-telemetry";
    }
    {
      cmd = "dl-video --help";
      says = "usage: dl-video";
    }
    {
      cmd = "fix-display --status";
      says = "sway pid:";
    }
    {
      cmd = "machine-facts --help";
      says = "machine-facts: print the volatile state";
    }
    {
      cmd = "magic-trackpad-battery --tsv";
      says = "";
    }
    {
      # An argument it does not know prints its usage and exits 2.
      cmd = "panel-crtc --help";
      says = "report where the panel is";
      rc = 2;
    }
    {
      cmd = "sap-deck --help";
      says = "usage: sap-deck";
    }
    {
      cmd = "searx --help";
      says = "usage: searx";
    }
    {
      cmd = "vault-check";
      says = "SUMMARY";
    }
    {
      cmd = "with-secret-env --help";
      says = "usage: with-secret-env";
    }
  ];
in
pkgs.runCommand "common-scripts"
  {
    nativeBuildInputs = [
      pkgs.btop
      pkgs.coreutils
      pkgs.gnugrep
      claude
    ]
    ++ map package (lib.attrNames allScripts)
    ++ [ (package "with-secret-env") ];
  }
  (
    if failures != [ ] then
      ''
        printf '%s\n' ${lib.escapeShellArgs failures} >&2
        exit 1
      ''
    else
      ''
        status=0

        # Each package has exactly its commands.
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: commands: ''
            got=$(ls ${package name}/bin | tr '\n' ' ')
            [ "$got" = ${lib.escapeShellArg (lib.concatStringsSep " " (sorted commands) + " ")} ] || {
              echo "${name}: bin/ holds [$got], expected [${toString (sorted commands)}]" >&2
              status=1
            }
          '') allScripts
        )}

        # Each command starts and says what it is, with no network and no
        # home directory, from an empty environment but its PATH.
        mkdir vault
        start() {
          local out rc=0
          out=$(env -i PATH="$PATH" HOME=/nonexistent USER=nobody VAULT_DIR="$PWD/vault" \
              CLAUDE_BG_PROC="$PWD/vault" bash -c "$1" 2>&1 </dev/null) || rc=$?
          if [ "$rc" != "$3" ]; then
            echo "$1 exits $rc, expected $3:" >&2
            printf '%s\n' "$out" | sed 's/^/    /' >&2
            status=1
          elif ! printf '%s\n' "$out" | grep -qF -- "$2"; then
            echo "$1 does not say [$2]; it says:" >&2
            printf '%s\n' "$out" | sed 's/^/    /' >&2
            status=1
          else
            echo "ok: $1"
          fi
        }
        ${lib.concatMapStringsSep "\n" (i: "start ${lib.escapeShellArg i.cmd} ${lib.escapeShellArg i.says} ${toString (i.rc or 0)}") invocations}

        [ "$status" = 0 ]
        touch "$out"
      ''
  )
