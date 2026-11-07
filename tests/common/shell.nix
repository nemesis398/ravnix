# The common module on a host, in a VM: the user's account with bash, the
# tools of the shell on the user's PATH, git with the identity of
# ravnix.user, the Fedora aliases and functions, the prompt as starship draws
# it, signing through an agent, the dev checkout's git hooks, the secrets that
# only `claude` gets, and the start of an interactive bash, which is gated at
# a median of 150 ms. The user and every personal value come from
# templates/default/me.nix, forwarded to home-manager by nixosModules.common.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user;
  palette = import ../../modules/theme/palette.nix;

  # Signs a commit through an ssh-agent that holds a throwaway key, then
  # verifies it against an allowed_signers file that names that key.
  signScript = pkgs.writeShellScript "sign.sh" ''
    set -eu
    eval "$(ssh-agent -s)" >/dev/null
    trap 'kill $SSH_AGENT_PID' EXIT
    key=$(mktemp -u)
    ssh-keygen -q -t ed25519 -N "" -f "$key"
    ssh-add -q "$key"
    dir=$(mktemp -d)
    cd "$dir"
    git init -q
    git -c user.signingkey="key::$(cat "$key.pub")" commit -q --allow-empty -m signed
    echo "$(git config user.email) $(cat "$key.pub")" > "$dir/signers"
    git -c gpg.ssh.allowedSignersFile="$dir/signers" verify-commit HEAD
    git -c gpg.ssh.allowedSignersFile="$dir/signers" log -1 --format=%G? | grep -qx G
  '';

  secretNames = [
    "FIRST_API_TOKEN"
    "SECOND_API_TOKEN"
    "THIRD_API_KEY"
    "FOURTH_PAT"
    "FIFTH_SECRET"
    "SIXTH_TOKEN"
  ];

  # Stand-ins in ~/.local/bin, which comes first on the user's PATH: an rbw
  # whose vault is unlocked and holds a value per item, and a claude that
  # writes the secrets it was given to a file. The values are made up.
  fakeRbw = pkgs.writeShellScript "rbw" ''
    case "$1" in
      unlocked) exit 0 ;;
      get) shift; [ "$1" = -- ] && shift; printf 'vm-secret-for:%s' "$1" ;;
      *) exit 1 ;;
    esac
  '';
  fakeClaude = pkgs.writeShellScript "claude" ''
    env | grep -c 'vm-secret-for:' >"$HOME/claude.count"
    env | sort | grep 'vm-secret-for:' >"$HOME/claude.env" || true
  '';

  # Times an interactive bash on a terminal, first prompt drawn: it forks bash
  # on a pty, types `exit` at once, and stops the clock when bash is gone. The
  # input waits in the pty until readline reads it, which happens after the
  # startup files and the prompt command (starship) have run and the prompt is
  # drawn. Prints the sorted times in seconds as JSON. (hyperfine cannot do
  # this: it has no terminal to give, and `script` adds a quarter second of
  # its own.)
  promptStart = pkgs.writeText "prompt-start.py" ''
    import fcntl, json, os, pty, struct, sys, termios, time

    def once():
        start = time.monotonic()
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            os.execvp("bash", ["bash", "-i"])
        os.write(fd, b"exit\n")
        while True:
            try:
                if not os.read(fd, 65536):
                    break
            except OSError:  # EIO: bash has gone
                break
        os.waitpid(pid, 0)
        return time.monotonic() - start

    once()
    once()
    print(json.dumps(sorted(once() for _ in range(int(sys.argv[1])))))
  '';

  # "#rrggbb" as the ANSI truecolor parameters starship prints.
  ansi =
    hex:
    "38;2;${
      lib.concatMapStringsSep ";" (i: toString (lib.fromHexString (builtins.substring i 2 hex))) [
        1
        3
        5
      ]
    }";
in
pkgs.testers.runNixOSTest {
  name = "common-shell";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.common
        ../../templates/default/me.nix
      ];

      # The template's values are placeholders and warn about it (the options
      # tests check that they do); here the warnings would only be noise.
      warnings = lib.mkForce [ ];

      # Six secrets, as the laptop has them: the start of a shell is measured
      # with the real table, and the values reach `claude` from a stand-in rbw.
      ravnix.shell.secretEnv = lib.genAttrs secretNames (n: "Item for ${n}");

      # What the seam sees: it runs first in every interactive bash, and
      # writes what `cd`, `zd` and `claude` are at that point.
      ravnix.shell.autoAttach = ''
        { type -t cd; type -t zd; type -t claude; alias cd; } >/tmp/seam-probe 2>&1
      '';

      # This host works on ravnix, so the activation turns its hooks on. The
      # checkout does not exist yet when the system starts.
      ravnix.dev = {
        checkout = lib.mkForce "/home/${user.username}/ravnix";
        denyList = lib.mkForce "/home/${user.username}/deny-list.txt";
      };

      # The gate's measuring tools; the module itself does not install them.
      environment.systemPackages = [
        pkgs.hyperfine
        pkgs.python3
      ];
      virtualisation.cores = 2;
      system.stateVersion = "26.05";
    };

  testScript = ''
    import json
    import shlex

    USER = "${user.username}"
    EMAIL = "${user.email}"
    NAME = "${user.name}"
    SECRETS = ${builtins.toJSON secretNames}
    MAUVE = "${ansi palette.mauve}"
    RED = "${ansi palette.red}"

    def as_user(cmd, check=True):
        # A real terminal type: with TERM=dumb, which the driver's shell has,
        # the module's init skips starship, and the start would be measured
        # without it.
        script = "su - " + USER + " -c " + shlex.quote("export TERM=xterm-256color; " + cmd)
        return machine.succeed(script) if check else machine.execute(script)

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("home-manager-" + USER + ".service")

    with subtest("the account has bash and the user's name"):
        passwd = machine.succeed("getent passwd " + USER).strip().split(":")
        assert passwd[4].split(",")[0] == NAME, passwd
        assert passwd[6].endswith("/bash"), passwd
        assert "wheel" in machine.succeed("id -nG " + USER).split(), "not in wheel"

    with subtest("the tools of the shell are on the user's PATH"):
        as_user(" && ".join(
            t + " --version" for t in [
                "starship", "atuin", "zoxide", "rg", "eza", "bat", "lazygit", "gh",
                "fd", "fzf", "btop", "fastfetch", "delta", "jq", "rbw", "tldr",
                "chafa", "git",
            ]
        ))

    with subtest("git has the identity of ravnix.user and signs with ssh"):
        assert as_user("git config user.email").strip() == EMAIL
        assert as_user("git config user.name").strip() == NAME
        assert as_user("git config gpg.format").strip() == "ssh"
        assert as_user("git config commit.gpgsign").strip() == "true"
        assert as_user("git config user.signingkey").strip().startswith("key::ssh-ed25519 ")
        signers = as_user("cat ~/.config/git/allowed_signers")
        assert signers.startswith(EMAIL + " ssh-ed25519 "), signers

    with subtest("a commit is signed through an agent and verifies"):
        as_user("bash ${signScript}")

    with subtest("the Fedora aliases and functions are there"):
        aliases = as_user("bash -ic alias 2>/dev/null")
        for line in [
            "alias cd='zd'",
            "alias ls='eza -lh --group-directories-first --icons=auto'",
            "alias lt='eza --tree --level=2 --long --icons --git'",
            "alias g='git'",
            "alias gp='git push'",
            "alias ..='cd ..'",
            "alias hl='rg --passthru'",
            "alias or='odin run'",
        ]:
            assert line in aliases, line + " is missing from:\n" + aliases
        missing = as_user(
            "bash -ic 'for f in zd gr gmb gbd gsm gmm gho over open ob ot sudo cat ai-unlock sff; "
            "do [[ $(type -t $f) == function ]] || echo MISSING $f; done' 2>/dev/null"
        )
        assert "MISSING" not in missing, missing

    with subtest("the seam runs before any alias or function of the module"):
        # Code that a module puts in ravnix.shell.autoAttach (an `exec` into a
        # session, say) finds `cd` as the builtin: the zd alias and the
        # functions it needs come later. The host's value reached the shell.
        as_user("rm -f /tmp/seam-probe; bash -ic exit")
        probe = as_user("cat /tmp/seam-probe").splitlines()
        assert probe[0] == "builtin", probe
        assert "function" not in probe and "alias" not in probe, probe
        assert any("not found" in l for l in probe), probe

    with subtest("a shell no login started still has the session variables and ~/.local/bin"):
        out = as_user(
            "env -i HOME=$HOME PATH=/run/current-system/sw/bin TERM=xterm-256color "
            "bash -ic 'echo EDITOR=$EDITOR; echo PATH=$PATH' 2>/dev/null"
        )
        assert "EDITOR=nvim" in out, out
        path = [l for l in out.splitlines() if l.startswith("PATH=")][0]
        assert path.split("=", 1)[1].split(":")[0] == "/home/" + USER + "/.local/bin", path

    with subtest("an interactive bash starts without an error"):
        output = as_user("bash -ic exit 2>&1")
        for bad in ["command not found", "No such file", "syntax error", "unbound variable", "Permission denied"]:
            assert bad not in output, bad + " in:\n" + output

    with subtest("starship, zoxide, fzf and atuin are hooked in, and Ctrl-R is atuin's"):
        # readline needs a terminal for `bind`, so the shell runs in script.
        # atuin binds Ctrl-R to a macro that runs its widget; fzf's own
        # binding, which came first, is gone.
        inner = "bash -ic 'type -t z; type -t starship_precmd; type -t __fzf_history__; bind -s; echo ==; bind -X'"
        out = as_user("script -qec " + shlex.quote(inner) + " /dev/null").replace("\r", "")
        # `bind -s` comes before the marker and `bind -X` after it.
        before, _, after = out.partition("\n==\n")
        lines = before.splitlines()
        assert lines[:3] == ["function"] * 3, out
        ctrl_r = [l for l in lines[3:] if l.startswith('"\\C-r"')]
        assert len(ctrl_r) == 1 and "A1" in ctrl_r[0], (ctrl_r, out)
        assert "__atuin_widget_run 0" in after, out
        assert not [l for l in after.splitlines() if l.startswith('"\\C-r"')], out

    with subtest("the prompt is drawn as starship draws it"):
        import re
        as_user("rm -rf ~/p ~/plain && mkdir ~/plain && mkdir ~/p && cd ~/p && git init -q -b main && touch new")
        # In a repository: the directory and the branch, the untracked mark,
        # all in the accent. (The ❯ after them adds only "bold": starship
        # leaves a color on that has not changed.)
        prompt = as_user("cd ~/p && starship prompt")
        assert "main" in prompt and "? " in prompt and "❯" in prompt, prompt
        assert prompt.count(MAUVE) >= 3, "the accent is missing from: " + prompt
        # Away from one, the character stands after an unstyled space and
        # carries its own color.
        ok = as_user("cd ~/plain && starship prompt")
        assert re.search(re.escape(MAUVE) + r"m(\\\])?❯", ok), "the character is not the accent: " + ascii(ok)
        # A failed command shows ✗ in Red and no ❯, whatever the accent is.
        failed = as_user("cd ~/plain && starship prompt --status=1")
        assert re.search(re.escape(RED) + r"m(\\\])?✗", failed), "the error symbol is not Red: " + ascii(failed)
        assert "❯" not in failed, failed
        toml = as_user("cat ~/.config/starship.toml")
        assert 'error_symbol = "[✗](bold red)"' in toml, toml

    with subtest("g completes like git, loaded on first use"):
        out = as_user("bash -ic '_g_complete_load; echo status=$?; complete -p g' 2>/dev/null")
        assert "status=124" in out and "__git_wrap__git_main" in out, out

    with subtest("the other tools read their configuration"):
        as_user("fastfetch --pipe >/dev/null")
        as_user("bat --list-themes | grep -qx 'Catppuccin Mocha'")
        as_user("eza -lh /etc >/dev/null")
        as_user("btop --version >/dev/null")
        as_user("rbw config show | jq -e '.email == \"${me.ravnix.secrets.rbwEmail}\"'")
        # atuin reads its settings (an invalid file is "could not load client settings").
        as_user("ATUIN_SESSION=$(atuin uuid) atuin history list")
        # delta reads the [delta] section of git's configuration, and a wrong
        # attribute in it makes it abort.
        as_user("cd ~/p && git add new && echo more >> new && git diff | delta | grep -q more")

    with subtest("claude gets the secrets of the vault, and nothing else does"):
        # The table is ravnix.shell.secretEnv of the host, forwarded to the
        # user's shell. rbw and claude are stand-ins first on PATH.
        table = as_user("bash -ic 'declare -p _ravnix_secrets' 2>/dev/null")
        for n in SECRETS:
            assert '"' + n + "=Item for " + n + '"' in table, table
        as_user("mkdir -p ~/.local/bin && install -m755 ${fakeRbw} ~/.local/bin/rbw "
                "&& install -m755 ${fakeClaude} ~/.local/bin/claude")
        out = as_user("bash -ic 'claude; echo SHELL-HAS=$(env | grep -c vm-secret-for:); "
                      "echo FIRST=''${FIRST_API_TOKEN-unset}; sh -c \"echo CHILD=\\''${FIRST_API_TOKEN-unset}\"' 2>&1")
        assert "SHELL-HAS=0" in out and "FIRST=unset" in out and "CHILD=unset" in out, out
        assert as_user("cat ~/claude.count").strip() == str(len(SECRETS))
        got = as_user("cat ~/claude.env")
        for n in SECRETS:
            assert n + "=vm-secret-for:Item for " + n in got, got
        # Inside Claude Code the function adds nothing.
        as_user("CLAUDECODE=1 bash -ic claude 2>&1")
        assert as_user("cat ~/claude.count").strip() == "0"
        as_user("rm -f ~/.local/bin/rbw ~/.local/bin/claude ~/claude.count ~/claude.env")

    with subtest("a stale SWAYSOCK is repaired to the newest sway socket, whatever the aliases"):
        # The aliases of the shell must come after the repair: with `ls`
        # being eza, the repair finds nothing. Real sockets, made by agents.
        uid = machine.succeed("id -u " + USER).strip()
        run = "/run/user/" + uid
        machine.succeed(f"mkdir -p {run} && chown {USER} {run} && chmod 700 {run}")
        for n, age in [("111", "10 minutes ago"), ("222", "1 minute ago")]:
            sock = f"{run}/sway-ipc.{uid}.{n}.sock"
            as_user(f"ssh-agent -a {sock} >/dev/null && touch -d '{age}' {sock}")
        newest = f"{run}/sway-ipc.{uid}.222.sock"
        stale = f"{run}/sway-ipc.{uid}.999.sock"
        out = as_user(f"SWAYSOCK={stale} bash -ic 'echo SWAY=$SWAYSOCK; type -t ls' 2>/dev/null")
        assert "SWAY=" + newest in out, out
        # The interactive shell has the alias after all, and a socket that is
        # still there is left alone.
        assert "alias" in out, out
        live = f"{run}/sway-ipc.{uid}.111.sock"
        out = as_user(f"SWAYSOCK={live} bash -ic 'echo SWAY=$SWAYSOCK' 2>/dev/null")
        assert "SWAY=" + live in out, out
        machine.succeed("pkill -u " + USER + " ssh-agent || true")

    with subtest("the dev checkout is configured by the activation, when it exists"):
        # The system started without the checkout, and the activation did not fail.
        machine.succeed("systemctl is-active home-manager-" + USER + ".service")
        as_user("git init -q -b main ~/ravnix")
        machine.succeed("systemctl restart home-manager-" + USER + ".service")
        assert as_user("git -C ~/ravnix config core.hooksPath").strip() == ".githooks"
        assert as_user("git -C ~/ravnix config ravnix.denyList").strip() == "/home/" + USER + "/deny-list.txt"

    with subtest("an interactive bash starts in under 150 ms"):
        def start(home, command="bash -i -c exit", options=""):
            """The wall-clock median in seconds of 10 interactive starts with HOME=home."""
            as_user("HOME=" + home + " hyperfine -N --warmup 2 --runs 10 " + options
                    + " --export-json /tmp/hyperfine.json " + shlex.quote(command) + " >&2")
            # hyperfine 2.0's report: one measurement per run, each with
            # several metrics.
            report = json.loads(machine.succeed("cat /tmp/hyperfine.json"))
            runs = report["results"][0]["measurements"]
            assert len(runs) == 10, len(runs)
            wall = sorted(m["time_wall_clock"]["value"] for m in runs)
            instructions = sorted(m["instructions"]["value"] for m in runs if "instructions" in m)
            return (wall[4] + wall[5]) / 2, wall, instructions

        # What the system's own /etc/bashrc costs, for the report.
        as_user("mkdir -p ~/empty && touch ~/empty/.bashrc")
        floor, _, _ = start("~/empty")
        print(f"interactive bash start with an empty ~/.bashrc: median {floor * 1000:.1f} ms")

        # With the six secrets of the host in the table (nothing is read at
        # the start: `claude` reads them when it runs).
        median, wall, instructions = start("~")
        print(f"interactive bash start: median {median * 1000:.1f} ms, min {wall[0] * 1000:.1f} ms, max {wall[-1] * 1000:.1f} ms")
        if instructions:
            count = instructions[len(instructions) // 2] / 1e6
            print(f"interactive bash start: median {count:.0f} M instructions")
            # The instruction count does not move with a busy builder, so it is
            # the steadier of the two gates: 274 M measured, with room for a
            # tool's version to change.
            assert count < 400, f"{count:.0f} M instructions is not below 400 M"
        assert median < 0.150, f"median {median * 1000:.1f} ms is not below 150 ms"

        # The same on a terminal, with the first prompt drawn: readline starts
        # and starship renders.
        def on_a_terminal(home):
            times = json.loads(as_user("HOME=" + home + " python3 ${promptStart} 10"))
            assert len(times) == 10, times
            return (times[4] + times[5]) / 2, times

        pty_floor, _ = on_a_terminal("~/empty")
        pty_median, pty_wall = on_a_terminal("~")
        print(f"interactive bash on a terminal, first prompt drawn: median {pty_median * 1000:.1f} ms "
              f"(min {pty_wall[0] * 1000:.1f}, max {pty_wall[-1] * 1000:.1f}); with an empty ~/.bashrc {pty_floor * 1000:.1f} ms")
        assert pty_median < 0.150, f"median {pty_median * 1000:.1f} ms with the prompt is not below 150 ms"
  '';
}
