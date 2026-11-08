# The terminal glue (modules/glue/terminal.nix) on the two shapes, evaluated
# as the private flake builds them, with the template's values and with the
# values a user may leave null. tests/glue/reconnect.nix runs both ends in
# VMs; this checks what a VM cannot vary:
#
#   - the laptop's main key runs ravnix-terminal, the main connection is a
#     unit of the graphical session that restarts forever and forwards both
#     sockets, and the laptop's herdr reads the server's settings;
#   - what ssh makes of the generated block (`ssh -G`, which connects
#     nowhere): the NetBird address and the account, the key of its own and
#     no agent, the pinned host key or the first one remembered, the
#     keepalive, no prompt; with herdr's own configuration in front, as
#     `herdr --remote` runs ssh, the block's keepalive still wins; without
#     an identity file, ssh's defaults and the agent stay;
#   - ghostty writes OSC 52 into the clipboard and does not let a pane read
#     it, and each ghostty is its own process;
#   - the server takes the key for a shell and forwarding and nothing more,
#     and drops a client that has gone quiet; without the key, none.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  me = ../../templates/default/me.nix;
  template = (import me).ravnix;
  user = template.user.username;
  build =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
        }
      ]
      ++ modules;
    }).config;
  laptop =
    modules:
    build (
      [
        self.nixosModules.laptop
        self.nixosModules.hardware-ideapad-pro-5-16ahp9
      ]
      ++ modules
    );
  server = modules: build ([ self.nixosModules.server ] ++ modules);

  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealHostKeyExampleOnlyNotAReal";
  h = laptop [ ];
  pinned = laptop [ { ravnix.serverAccess.hostKey = lib.mkForce hostKey; } ];
  noKey = laptop [ { ravnix.serverAccess.identityFile = lib.mkForce null; } ];
  m = server [ ];
  mNoKey = server [ { ravnix.serverAccess.publicKey = lib.mkForce null; } ];

  hm = c: c.home-manager.users.${user};
  units = c: (hm c).systemd.user.services;
  homeNamed = name: c: lib.filter (p: lib.getName p == name) (hm c).home.packages;
  text = p: p.text or "";
  plain = builtins.unsafeDiscardStringContext;
  infix = a: b: lib.hasInfix (plain a) (plain b);
  execOf = u: lib.concatStringsSep " " (lib.toList u.Service.ExecStart);
  check = cond: msg: lib.optional (!cond) msg;

  connection = (units h).ravnix-connection or null;
  connectionText = lib.concatMapStrings text (homeNamed "ravnix-connection" h);
  terminalText = lib.concatMapStrings text (homeNamed "ravnix-terminal" h);
  ghostty = (hm h).programs.ghostty.settings;
  keyLine = "restrict,port-forwarding,pty ${template.serverAccess.publicKey}";
  forwardingKeys =
    c:
    lib.filter (k: lib.hasInfix "port-forwarding" k) c.users.users.${user}.openssh.authorizedKeys.keys;

  failures =
    # The laptop.
    check (
      infix "/bin/ravnix-terminal" h.ravnix.desktop.terminal.main
      && lib.hasPrefix "ghostty -e " h.ravnix.desktop.terminal.main
    ) "the main key does not run ravnix-terminal in ghostty: ${h.ravnix.desktop.terminal.main}"
    ++ check (
      h.ravnix.desktop.terminal.plain == "env NO_MUX=1 ghostty"
    ) "the second key is not the desktop's local shell: ${h.ravnix.desktop.terminal.plain}"
    # What the two commands do is tests/glue/terminal-scripts.nix's; here,
    # that the laptop's are built for the alias and with the real programs.
    ++ check (
      infix "alias='ravnix-server'" terminalText && infix "herdr='${lib.getExe pkgs.herdr}'" terminalText
    ) "ravnix-terminal does not run herdr for ravnix-server"
    ++ check (
      infix "alias='ravnix-server'" connectionText && infix "ssh='${lib.getExe' pkgs.openssh "ssh"}'" connectionText
    ) "ravnix-connection does not run ssh for ravnix-server"
    ++ check (connection != null) "the laptop has no ravnix-connection unit"
    ++ check (
      connection != null && connection.Install.WantedBy == [ "graphical-session.target" ]
    ) "the main connection is not part of the graphical session"
    ++ check (
      connection != null
      && connection.Service.Restart == "always"
      && connection.Unit.StartLimitIntervalSec == 0
    ) "the main connection gives up"
    ++ check (
      connection != null && lib.hasSuffix "/bin/ravnix-connection" (plain (execOf connection))
    ) "the main connection does not run ravnix-connection"
    ++ lib.concatMap (s: check (infix s connectionText) "the main connection does not forward ${s}") [
      h.ravnix.link.socket
      h.ravnix.skAgent.socket
      "ExitOnForwardFailure=yes"
      "ControlMaster=no"
    ]
    ++ check (
      h.ravnix.link.socket == "ravnix-link.sock" && h.ravnix.skAgent.socket == "sk-agent.sock"
    ) "a socket's name changed: ${h.ravnix.link.socket}, ${h.ravnix.skAgent.socket}"
    ++ check (
      (hm h).programs.herdr.settings == builtins.removeAttrs (hm m).programs.herdr.settings [ "terminal" ]
    ) "the laptop's herdr settings are not the server's"
    ++ check (
      (hm m).programs.herdr.settings.terminal.default_shell or null != null
    ) "the server's herdr has no shell of its panes"
    ++ check (
      lib.toList (ghostty.clipboard-write or [ ]) == [ "allow" ]
    ) "ghostty does not write OSC 52 into the clipboard"
    ++ check (
      lib.toList (ghostty.clipboard-read or [ ]) == [ "deny" ]
    ) "ghostty lets a pane read the clipboard"
    ++ check (
      lib.toList (ghostty.gtk-single-instance or [ ]) == [ false ]
    ) "ghostty hands a second window to the first process"
    ++ check (forwardingKeys h == [ ]) "the laptop takes the server's key"
    ++ check ((units m) ? ravnix-connection == false) "the server runs the main connection"
    ++ check (homeNamed "ravnix-terminal" m == [ ]) "the server has ravnix-terminal"

    # The server.
    ++ check (
      forwardingKeys m == [ keyLine ]
    ) "the server does not take the laptop's key as ${keyLine}: ${toString (forwardingKeys m)}"
    ++ check (forwardingKeys mNoKey == [ ]) "a server without serverAccess.publicKey takes a key for it"
    ++ check (
      m.services.openssh.settings.ClientAliveInterval == 10
      && m.services.openssh.settings.ClientAliveCountMax == 3
    ) "the server's sshd keeps a vanished client"
    ++ check (m.services.openssh.settings.StreamLocalBindUnlink or false
    ) "the server's sshd keeps a stale forwarded socket";

  sshConfig = c: (hm c).home.file.".ssh/config".source;
  ssh = lib.getExe' pkgs.openssh "ssh";
in
pkgs.runCommand "glue-terminal-shapes" { } (
  if failures != [ ] then
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
  else
    ''
      set -euo pipefail
      fail() { echo "$*" >&2; exit 1; }
      export HOME=$TMPDIR
      # ssh -G prints what it would use, and connects nowhere. It refuses a
      # file that is neither root's nor the user's, as the store's files are
      # in the sandbox, so it reads copies, each Include pointed at its copy.
      n=0
      local_copy() {
        n=$((n + 1))
        local out=$PWD/copy-$n line inc
        : >"$out"
        while IFS= read -r line; do
          if [[ $line == Include\ * ]]; then
            inc=$(local_copy "''${line#Include }")
            line="Include $inc"
          fi
          printf '%s\n' "$line" >>"$out"
        done <"$1"
        chmod 600 "$out"
        echo "$out"
      }
      effective() { ${ssh} -F "$(local_copy "$1")" -G ravnix-server; }
      has() { grep -qxF -- "$2" <<<"$1" || fail "$3: no '$2' in: $1"; }
      hasnt() { ! grep -qxF -- "$2" <<<"$1" || fail "$3: '$2' in: $1"; }

      g=$(effective ${sshConfig h})
      has "$g" "hostname ${template.server.netbirdAddress}" "the server's NetBird address"
      has "$g" "user ${user}" "the account"
      has "$g" "identityfile ${template.serverAccess.identityFile}" "the key of its own"
      has "$g" "identitiesonly yes" "only that key"
      has "$g" "identityagent none" "no agent"
      has "$g" "hostkeyalias ravnix-server" "the host key's name"
      has "$g" "stricthostkeychecking accept-new" "the first host key remembered"
      has "$g" "batchmode yes" "no prompt"
      has "$g" "serveraliveinterval 1" "the keepalive"
      has "$g" "serveralivecountmax 3" "the keepalive's count"
      has "$g" "forwardagent no" "no agent forwarding"
      hasnt "$g" "remoteforward" "the terminal's connection forwards a socket"

      # As herdr --remote runs ssh: its configuration includes the user's
      # first and adds its own keepalive behind it.
      printf 'Include %s\nServerAliveInterval 15\nServerAliveCountMax 4\n' ${sshConfig h} >herdr-config
      g=$(effective herdr-config)
      has "$g" "serveraliveinterval 1" "herdr's keepalive wins over the block's"
      has "$g" "identityagent none" "herdr's ssh asks an agent"

      g=$(effective ${sshConfig pinned})
      has "$g" "stricthostkeychecking true" "the pinned host key"
      grep -qx 'userknownhostsfile /nix/store/[^ ]*-ravnix-server-known-hosts' <<<"$g" || fail "no pinned known_hosts: $g"
      known=$(sed -n 's/^userknownhostsfile //p' <<<"$g")
      grep -qxF "ravnix-server ${hostKey}" "$known" || fail "the pinned file is not the host key: $(cat "$known")"

      g=$(effective ${sshConfig noKey})
      hasnt "$g" "identityagent none" "without an identity file, the agent is refused"
      hasnt "$g" "identitiesonly yes" "without an identity file, ssh's own keys are refused"
      has "$g" "hostname ${template.server.netbirdAddress}" "the server's address without an identity file"

      touch $out
    ''
)
