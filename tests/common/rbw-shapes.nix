# rbw's agent, the SSH socket and Claude Code's telemetry on both shapes,
# evaluated: the laptop and the server each run rbw-agent as a user unit
# from the start of the user's manager, point SSH_AUTH_SOCK at its socket in
# the shell and in the user manager, have rbw start that unit instead of an
# agent of its own (RBW_AGENT), ask the master password through the guard,
# and give Claude Code DISABLE_TELEMETRY and DISABLE_ERROR_REPORTING in its
# settings, the shell and the user manager. The token helper answers for the
# remotes of ravnix.secrets.gitTokens alone, with no other helper beside it;
# the Proxmox update key is a block of the server's ssh config; and the
# assertions that keep both from opening more are shown to fire.
# tests/workbench/rbw.nix runs the server's side in a VM.
{
  self,
  inputs,
  lib,
  system,
  pkgs,
  ...
}:
let
  me = ../../templates/default/me.nix;
  user = (import me).ravnix.user.username;
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
          warnings = lib.mkForce [ ];
          ravnix.editor.languages = lib.mkForce [ "nix" ];
        }
      ]
      ++ modules;
    };
  server =
    extra:
    build [
      self.nixosModules.server
      {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
      }
      extra
    ];
  shapes = {
    laptop = build [ self.nixosModules.laptop ];
    server = server { };
  };
  hm = s: s.config.home-manager.users.${user};
  failed = s: map (a: a.message) (lib.filter (a: !a.assertion) s.config.assertions);
  # A module that does not evaluate: its type is wrong.
  refused = s: !(builtins.tryEval (builtins.deepSeq (hm s).programs.git.settings true)).success;

  token = {
    url = "https://git.example.org/alice/private.git";
    username = "alice-admin";
    item = "Forge - API token (private, write)";
  };
  withToken = server { ravnix.secrets.gitTokens = lib.mkForce [ token ]; };
  credential = (hm withToken).programs.git.settings.credential;
  proxmox = {
    alias = "proxmox-update";
    hostName = "192.0.2.40";
    user = "root";
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyUpdate update@muninn";
  };
  withProxmox = server { ravnix.server.proxmoxUpdate = lib.mkForce proxmox; };
  block = (hm withProxmox).programs.ssh.matchBlocks.${proxmox.alias}.data or null;

  check = cond: msg: lib.optional (!cond) msg;
  perShape =
    name: s:
    let
      h = hm s;
      unit = h.systemd.user.services.rbw-agent or null;
      telemetry = [
        "DISABLE_TELEMETRY"
        "DISABLE_ERROR_REPORTING"
      ];
    in
    check (failed s == [ ]) "${name}: the shape fails its assertions: ${toString (failed s)}"
    ++ check (unit != null) "${name}: no rbw-agent user unit"
    ++ check (
      unit != null && lib.hasSuffix "/bin/rbw-agent --no-daemonize" (toString unit.Service.ExecStart)
    ) "${name}: rbw-agent does not run in the foreground under its unit"
    ++ check (
      unit != null && lib.elem "default.target" unit.Install.WantedBy
    ) "${name}: rbw-agent does not start with the user's manager"
    ++ check (
      h.home.sessionVariables.SSH_AUTH_SOCK or ""
      == "\${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rbw/ssh-agent-socket"
    ) "${name}: the shell's SSH_AUTH_SOCK is not rbw's socket"
    ++ check (
      h.systemd.user.sessionVariables.SSH_AUTH_SOCK or "" == "\${XDG_RUNTIME_DIR}/rbw/ssh-agent-socket"
    ) "${name}: the user manager's SSH_AUTH_SOCK is not rbw's socket"
    ++ check (
      (h.home.sessionVariables.RBW_AGENT or null) != null
      && h.home.sessionVariables.RBW_AGENT == h.systemd.user.sessionVariables.RBW_AGENT or null
    ) "${name}: rbw is not told to start the unit's agent, in the shell and the user manager alike"
    ++ check (lib.hasInfix "ravnix-pinentry" (
      h.programs.rbw.settings.pinentry or ""
    )) "${name}: rbw asks for the master password without the guard"
    ++ lib.concatMap (
      var:
      check (
        h.programs.claude-code.settings.env.${var} or null == "1"
      ) "${name}: Claude Code's settings lack ${var}=1"
      ++ check (h.home.sessionVariables.${var} or null == "1") "${name}: the shell lacks ${var}=1"
      ++ check (
        h.systemd.user.sessionVariables.${var} or null == "1"
      ) "${name}: the user manager lacks ${var}=1"
    ) telemetry
    # Without tokens, no helper of ravnix's is in git's configuration.
    ++ check (
      !lib.hasInfix "ravnix-git-token" (builtins.toJSON (h.programs.git.settings.credential or { }))
    ) "${name}: a token helper is configured without ravnix.secrets.gitTokens";

  breaks = {
    "a token for an http remote" = {
      s = server {
        ravnix.secrets.gitTokens = lib.mkForce [
          (token // { url = "http://git.example.org/alice/private.git"; })
        ];
      };
      type = true;
    };
    "a token for a host without a repository" = {
      s = server {
        ravnix.secrets.gitTokens = lib.mkForce [ (token // { url = "https://git.example.org/"; }) ];
      };
      type = true;
    };
    "a token whose URL holds a user" = {
      s = server {
        ravnix.secrets.gitTokens = lib.mkForce [
          (token // { url = "https://alice@git.example.org/alice/private.git"; })
        ];
      };
      type = true;
    };
    "two tokens for one remote" = {
      s = server {
        ravnix.secrets.gitTokens = lib.mkForce [
          token
          token
        ];
      };
      says = "more than one token";
    };
    "a deploy from the server's own NetBird address" = {
      s = server {
        ravnix.server.deployKeys = lib.mkForce [ proxmox.publicKey ];
        ravnix.server.deployFrom = lib.mkForce [ "198.51.100.20" ];
      };
      says = "the server's own";
    };
    "a deploy from loopback" = {
      s = server {
        ravnix.server.deployKeys = lib.mkForce [ proxmox.publicKey ];
        ravnix.server.deployFrom = lib.mkForce [ "127.0.0.1" ];
      };
      says = "the server's own";
    };
    "the Proxmox update key as a deploy key" = {
      s = server {
        ravnix.server.proxmoxUpdate = lib.mkForce proxmox;
        ravnix.server.deployKeys = lib.mkForce [ proxmox.publicKey ];
      };
      says = "proxmoxUpdate";
    };
  };
  notCaught = lib.filterAttrs (
    _: b: if b.type or false then !(refused b.s) else !(lib.any (m: lib.hasInfix b.says m) (failed b.s))
  ) breaks;

  helper = lib.last (credential.${token.url}.helper or [ "" ]);
  failures =
    lib.concatLists (lib.mapAttrsToList perShape shapes)
    # The token helper: for its remote alone, its helper list reset first,
    # so a helper that stores (store, cache) never sees the token, and with
    # the path in the request, which the helper compares.
    # gh's helper for GitHub (programs.gh) stays as it is.
    ++ check (
      lib.attrNames (
        removeAttrs credential [
          "https://github.com"
          "https://gist.github.com"
        ]
      ) == [ token.url ]
    ) "the token helper is configured for more than its remote: ${toString (lib.attrNames credential)}"
    ++ check (
      !lib.hasInfix "ravnix-git-token" (builtins.toJSON (removeAttrs credential [ token.url ]))
    ) "the token helper answers for another URL too"
    ++ check (
      lib.head (credential.${token.url}.helper or [ "x" ]) == ""
    ) "the remote's helper list is not reset before the token helper"
    ++ check (
      lib.length (credential.${token.url}.helper or [ ]) == 2
    ) "the remote has other helpers than the token helper"
    ++ check (
      lib.hasInfix "ravnix-git-token" helper
      && lib.hasSuffix " ${lib.escapeShellArgs [
         token.url
         token.username
         token.item
       ]}" helper
    ) "the token helper is not given the remote, the user and the item: ${helper}"
    ++ check (credential.${token.url}.useHttpPath or false
    ) "git does not send the token helper the path"
    # The Proxmox update key: a block of its own, with that key alone.
    ++ check (block != null) "no ssh block for the Proxmox update key"
    ++ check (
      block != null && block.hostname == proxmox.hostName && block.user == proxmox.user
    ) "the Proxmox block has the wrong host or user"
    ++ check (block != null && block.identitiesOnly) "the Proxmox block offers the agent's other keys"
    ++ check (
      block != null && lib.length block.identityFile == 1
    ) "the Proxmox block names more or less than the update key"
    ++ check (
      block != null && (block.forwardAgent or null) == false
    ) "the Proxmox block forwards the agent"
    ++ check (
      !((hm (server { })).programs.ssh.matchBlocks ? ${proxmox.alias})
    ) "a Proxmox block without ravnix.server.proxmoxUpdate"
    ++
      check (failed withToken == [ ] && failed withProxmox == [ ])
        "a host with a token or the Proxmox key fails: ${toString (failed withToken ++ failed withProxmox)}"
    ++ lib.mapAttrsToList (
      name: b:
      "nothing stops ${name}${lib.optionalString (b ? says) " (wanted a message with \"${b.says}\")"}"
    ) notCaught;
in
pkgs.runCommand "common-rbw-shapes" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
