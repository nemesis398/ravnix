# obsidian-open-daily (modules/desktop/sway/bin/obsidian-open-daily) starts
# Obsidian for the login layout and opens the vault's newest daily note through
# the Obsidian CLI. It is run against stand-ins for the CLI and gtk-launch on
# the vaults the layout may meet, and on the answers Obsidian gives while it
# starts. Besides, the Sway module's own wiring: the command is installed, the
# layout names the vault's folder name for its tabs, and a host without a vault
# gets a layout without a tab.
#
# Carried over from Fedora's script (rule 4: it stays Python until its port),
# with four changes the tests pin: the vault is ravnix.link.vault and not a
# path in the script, no vault means a plain start, the CLI and gtk-launch are
# found on the PATH (OBSIDIAN_CLI and GTK_LAUNCH are the test seams), and the
# desktop id is the Flatpak-style one the system installs.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  helpers = import ../../modules/desktop/sway/lib.nix { inherit lib pkgs; };
  build =
    vault: cli:
    helpers.python {
      name = "obsidian-open-daily";
      src = ../../modules/desktop/sway/bin/obsidian-open-daily;
      tokens = {
        vault = helpers.pyString vault;
        cli = helpers.pyString cli;
      };
      flakeIgnore = [
        "E501"
        "W503"
        "W504"
      ];
    };

  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  hostOf =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.desktop ] ++ modules;
    };
  withVault = hostOf [ { ravnix.link.vault = lib.mkForce "/home/alice/My Notes"; } ];
  noVault = hostOf [ { ravnix.link.vault = lib.mkForce null; } ];
  hostileVault = hostOf [ { ravnix.link.vault = lib.mkForce ''/home/alice/a"b$c''; } ];
  layoutOf =
    host:
    let
      user = (import ../../templates/default/me.nix).ravnix.user.username;
    in
    builtins.readFile host.config.home-manager.users.${user}.xdg.configFile."sway/config".source;
  # The exec line of the layout, where the tab is decided (the comments above
  # it talk about --tab as well).
  execLine =
    host:
    lib.concatStringsSep "\n" (
      lib.filter (l: lib.hasPrefix "exec " l && lib.hasInfix "sway-session-layout" l) (lib.splitString "\n" (layoutOf host))
    );
  installedScript = host: lib.findFirst (p: p.name == "obsidian-open-daily") (throw "obsidian-open-daily is not installed") host.config.environment.systemPackages;
  installed = host: map lib.getName host.config.environment.systemPackages;
  refuses = host: lib.any (a: !a.assertion && lib.hasInfix "ravnix.link.vault" a.message) host.config.assertions;
  asserts = [
    {
      ok = lib.elem "obsidian-open-daily" (installed withVault);
      msg = "obsidian-open-daily is not in the system profile, so the login layout's notes slot runs a command that is not found";
    }
    {
      ok = lib.elem "obsidian-open-daily" (installed noVault);
      msg = "without a vault obsidian-open-daily is missing; the layout still runs it, to start Obsidian plainly";
    }
    {
      ok = lib.hasInfix ''--tab 3 "My Notes" '' (execLine withVault);
      msg = "the login layout does not tab workspace 3 with the vault's folder name as the window to keep on top";
    }
    {
      ok = execLine noVault != "" && !(lib.hasInfix "--tab" (execLine noVault));
      msg = "a host without a vault still tabs workspace 3";
    }
    {
      ok = !(lib.hasInfix "@" (execLine withVault));
      msg = "a token is left in the layout's exec line";
    }
    {
      ok = refuses hostileVault && !refuses withVault && !refuses noVault;
      msg = "a vault folder name with a quote or a dollar sign is not refused, and would end the quote in the Sway config or expand as a variable";
    }
  ];
  failedAsserts = map (a: a.msg) (lib.filter (a: !a.ok) asserts);
in
assert lib.assertMsg (failedAsserts == [ ]) (lib.concatStringsSep "; " failedAsserts);
pkgs.runCommand "desktop-obsidian-open-daily"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.coreutils
    ];
    # The sandbox's /tmp is private; the test makes the vault there.
    script = "${build "/tmp/ood/My Notes" "obsidian-cli"}/bin/obsidian-open-daily";
    scriptNoVault = "${build "" "obsidian-cli"}/bin/obsidian-open-daily";
    # Built with a default CLI that the test provides, to see the default used.
    scriptDefaultCli = "${build "/tmp/ood/My Notes" "/tmp/ood-cli"}/bin/obsidian-open-daily";
    # The script a host installs: its default CLI is the CLI client of the
    # Obsidian package (bin/obsidian is the Electron launcher, which would start
    # a whole second Obsidian at every poll).
    installedScript = "${installedScript withVault}/bin/obsidian-open-daily";
    expectedCli = lib.getExe' withVault.pkgs.obsidian "obsidian-cli";
    testScript = ./helpers/obsidian-open-daily.test.sh;
  }
  ''
    grep -qF "CLI = os.environ.get(\"OBSIDIAN_CLI\", \"$expectedCli\")" "$installedScript" || {
      echo "the installed obsidian-open-daily does not default to $expectedCli:" >&2
      grep -n 'OBSIDIAN_CLI' "$installedScript" >&2
      exit 1
    }
    bash "$testScript" > $out
  ''
