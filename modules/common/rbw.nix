# rbw, the vault client behind ai-unlock, and its agent, on both hosts: the
# laptop and the server alike, because Claude Code runs on both. The agent
# holds the vault's key in memory once it is unlocked, answers rbw's reads,
# and is the user's SSH agent too: rbw-agent serves every SSH key item of the
# vault on $XDG_RUNTIME_DIR/rbw/ssh-agent-socket (rbw 1.14 and later; the
# packaged one is used, no wrapper of ravnix's), and SSH_AUTH_SOCK points
# there in the shell and in the user manager, so git signs commits with
# ravnix.user.signingKey from a terminal, from Claude Code and from a user
# unit alike (Task 5.3's vault-commit is one).
#
# What it gives away, said plainly. The server's rbw logs in to the same
# account as the laptop's and sees the whole vault. Once someone has run
# ai-unlock there, every process of the user on the server, every agent and
# every session among them, can read every item of the vault (`rbw get`), and
# can sign with every SSH key in it, which logs in wherever those keys
# open: each host, guest and account they are authorized for. That is the
# maintainer's choice (2026-11-08), so that the server works with the lid
# shut; a separate account with fewer items would be the narrower one.
# And it lasts: rbw locks after lock_timeout (one hour, rbw's default) with
# no request, but every read and every SSH signature starts that hour again,
# so on the server, where the Nextcloud sync reads its password every five
# minutes, the vault stays unlocked from ai-unlock until a reboot, `rbw
# lock`, or the agent's restart (tests/workbench/rbw.nix shows a read
# renewing the timeout).
#
# The agent runs as a user unit, rbw-agent, from the start of the user's
# manager (at boot on the server, which lingers): locked, with its sockets
# there. rbw itself would start an agent of its own in the background,
# inside whatever started it (a herdr pane's server, say, whose restart
# would take it along); RBW_AGENT, in the shell and in the user manager,
# makes it start the unit instead, and the unit's agent is the only one.
# Where the user manager cannot be reached (no XDG_RUNTIME_DIR), rbw falls
# back to its own.
#
# A locked agent never asks a terminal nobody looks at. rbw-agent asks for
# the master password through the pinentry whenever a request finds it
# locked, an SSH signature included, and it asks on the terminal of the last
# rbw command it served: the pane ai-unlock last ran in, hours ago, where a
# prompt would wait until someone typed into it, and with it the commit that
# asked. The guard below runs the real pinentry only when an rbw command
# waits on that terminal, its standard input being that terminal: a person
# who just typed `ai-unlock` or `rbw get`. Every other request is cancelled
# at once, so a locked agent refuses an SSH request in a moment and a unit
# fails instead of hanging (tests/workbench/rbw.nix). A graphical pinentry,
# which needs no terminal, is therefore never asked either.
#
# After a reboot the vault is locked, and `ai-unlock` (in a terminal) is the
# way back; until then signing fails, and the units that need a secret stop
# with status 75 and run again at their next tick.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.ravnix) secrets;
  cfg = config.ravnix.rbw;
  rbw = config.programs.rbw.package;

  # The guard: the pinentry rbw-agent runs. It looks for an rbw command whose
  # standard input is the terminal it is told to prompt on.
  guard = pkgs.writeShellApplication {
    name = "ravnix-pinentry";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      args=("$@")
      tty=
      while (($#)); do
        case $1 in
          --ttyname)
            tty=''${2-}
            shift $(($# > 1 ? 2 : 1))
            ;;
          --ttyname=*)
            tty=''${1#*=}
            shift
            ;;
          *) shift ;;
        esac
      done

      waiting() {
        local p exe
        [[ -n $tty ]] || return 1
        for p in /proc/[0-9]*; do
          exe=$(readlink "$p/exe" 2>/dev/null) || continue
          case ''${exe##*/} in
            rbw | .rbw-wrapped) ;;
            *) continue ;;
          esac
          [[ $(readlink "$p/fd/0" 2>/dev/null) == "$tty" ]] && return 0
        done
        return 1
      }

      if waiting; then
        exec ${lib.getExe cfg.pinentry} "''${args[@]}"
      fi

      # Nobody waits at a terminal: answer as a pinentry whose user pressed
      # Cancel, so rbw-agent fails the request at once.
      echo "ravnix-pinentry: the vault is locked and no rbw command waits on a terminal for the master password; run ai-unlock in a terminal" >&2
      echo "OK ravnix-pinentry"
      while IFS= read -r line; do
        case $line in
          GETPIN*) echo "ERR 83886179 Operation cancelled <ravnix-pinentry>" ;;
          BYE*)
            echo "OK closing connection"
            exit 0
            ;;
          *) echo OK ;;
        esac
      done
    '';
  };

  # rbw's runtime directory as its unit sees it (no RBW_PROFILE).
  dir = "\${XDG_RUNTIME_DIR}/rbw";

  # Before the agent: the sockets a killed agent left behind, unless an
  # agent outside the unit holds the pid file and still serves them (the
  # unit's agent then fails, saying the pid file is locked).
  preStart = pkgs.writeShellScript "rbw-agent-pre" ''
    dir=${dir}
    ${pkgs.coreutils}/bin/mkdir -p -m 700 "$dir"
    exec ${pkgs.util-linux}/bin/flock -n -E 0 "$dir/pidfile" \
      ${pkgs.coreutils}/bin/rm -f "$dir/socket" "$dir/ssh-agent-socket"
  '';
  # After it: both sockets are there, so `systemctl start` returns when rbw
  # can talk to the agent.
  postStart = pkgs.writeShellScript "rbw-agent-post" ''
    dir=${dir}
    for _ in $(${pkgs.coreutils}/bin/seq 100); do
      [ -S "$dir/socket" ] && [ -S "$dir/ssh-agent-socket" ] && exit 0
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    echo "rbw-agent did not open its sockets in $dir within 10 s" >&2
    exit 1
  '';

  # What rbw runs when no agent answers: the unit.
  starter = pkgs.writeShellScript "rbw-agent-start" ''
    if ${pkgs.systemd}/bin/systemctl --user start rbw-agent.service 2>/dev/null; then
      exit 0
    fi
    exec ${rbw}/bin/rbw-agent "$@"
  '';
in
{
  options.ravnix.rbw.pinentry = lib.mkOption {
    type = lib.types.package;
    default = pkgs.pinentry-curses;
    defaultText = lib.literalExpression "pkgs.pinentry-curses";
    description = ''
      The pinentry that asks for the master password, when an rbw command
      waits on a terminal for it (see modules/common/rbw.nix). The terminal
      one by default, which works over ssh and in a herdr pane alike.
    '';
  };

  config = {
    # The server and the account are the user's. A host can say otherwise.
    programs.rbw = {
      enable = true;
      settings = {
        email = lib.mkDefault secrets.rbwEmail;
        base_url = lib.mkDefault secrets.rbwBaseUrl;
        pinentry = lib.mkDefault guard;
      };
    };

    systemd.user.services.rbw-agent = {
      Unit.Description = "rbw's agent: the vault's key while it is unlocked, and the SSH agent";
      Service = {
        ExecStartPre = "${preStart}";
        ExecStart = "${rbw}/bin/rbw-agent --no-daemonize";
        ExecStartPost = "${postStart}";
        # `rbw stop-agent` (ai-unlock's repair) exits 0 and is not undone:
        # the next rbw command starts the unit again.
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = [ "default.target" ];
    };

    home.sessionVariables = {
      SSH_AUTH_SOCK = "\${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rbw/ssh-agent-socket";
      RBW_AGENT = "${starter}";
    };
    systemd.user.sessionVariables = {
      SSH_AUTH_SOCK = "${dir}/ssh-agent-socket";
      RBW_AGENT = "${starter}";
    };
  };
}
