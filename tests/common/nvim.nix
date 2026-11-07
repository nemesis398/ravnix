# Neovim with LazyVim, reproducible: the editor starts offline from the Nix
# store alone. A NixOS machine with no way out gets five users and runs the
# real editor as each of them:
#
#   alice  the defaults (Mauve, every language)
#   bob    the Teal accent
#   carol  a spec of her own that names a plugin that is not in the store
#   dave   a spec of his own whose setup fails when VeryLazy comes
#   erin   only some of the languages (ravnix.editor.languages)
#
# What the probes of tests/common/helpers/nvim-probe.lua check, in the editor
# itself, after VeryLazy: the plugins that wait for it are set up, and the
# editor said nothing wrong, in :messages or in the notifications that noice
# and snacks keep.
#
#   - `nvim --headless "+checkhealth lazy" +qa` exits 0 and its report holds
#     no error or warning, alone and four editors at once;
#   - every plugin lazy.nvim knows lives in /nix/store, nothing was cloned or
#     installed into the user's own directories, Mason is gone, and a plugin
#     that is not in the store is an error and never a download;
#   - the editor starts clean under a real terminal as well (a pty), and an
#     error that only comes when VeryLazy does fails the probe;
#   - the first file of a language starts that language's server within
#     10 s, and the server's binary is a Nix one (nil for Nix, ols for Odin,
#     and the servers of the other languages the setup edits);
#   - treesitter highlights from the Nix-built parsers, none missing;
#   - the style spec holds: Catppuccin Mocha with the accent of the option,
#     single-line borders on every float, and everything opaque: no blend, no
#     dimmed backdrop, in the configuration and in the windows that open;
#   - the editing options behave;
#   - the LanguageTool checks: dictionary and credentials (missing, malformed,
#     conflicting and unwritable input, a vault that does not answer), and the
#     toggle against ltex-ls-plus itself and a stand-in server, with the API
#     key found in no setting, command line, environment, message or file;
#   - a host that leaves languages out gets an editor that does not start
#     what they would have started;
#   - an empty file, a binary file and a 10 MB line open without a hang.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  palette = import ../../modules/theme/palette.nix;
  nvimUser = import ./helpers/nvim-user.nix { inherit self lib; };
  user = nvimUser;

  # The module's own warnings are not hidden by the fixture, which drops the
  # placeholder warnings of the template: evaluated alone, with the one value
  # it needs, the module warns about nothing.
  warnings =
    (inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        ../../modules/common/nvim.nix
        {
          home = {
            username = "alice";
            homeDirectory = "/home/alice";
            stateVersion = "26.05";
          };
          ravnix.dictionary.file = "/home/alice/dictionary.txt";
        }
      ];
    }).config.warnings;

  probe = ./helpers/nvim-probe.lua;
  ltServer = ./helpers/lt-server.py;

  # The API key of the LanguageTool checks, which must be found nowhere but at
  # the server.
  secret = "SECRETKEY-ravnix-test-4f2a9c";

  # rbw as the vault would answer: the entry's password and user name; nothing
  # at all while the vault is locked (FAKE_RBW_LOCKED); and no answer in time
  # (FAKE_RBW_HANG names the command that hangs).
  fakeRbw = pkgs.writeShellScriptBin "rbw" ''
    if [ "$FAKE_RBW_HANG" = "$1" ]; then
      exec sleep 30
    fi
    case "$1" in
      unlocked) [ -z "$FAKE_RBW_LOCKED" ] ;;
      get)
        shift
        field=password
        while [ $# -gt 0 ]; do
          case "$1" in
            --field) field="$2"; shift 2 ;;
            *) item="$1"; shift ;;
          esac
        done
        echo "$field of $item"
        ;;
      *) exit 1 ;;
    esac
  '';

  # One server per language, by the file that opens it.
  servers = [
    {
      file = "flake.nix";
      content = "{ pkgs }: pkgs.hello\n";
      server = "nil_ls";
      binary = "nil";
    }
    {
      file = "main.odin";
      content = "package main\n\nmain :: proc() {}\n";
      server = "ols";
      binary = "ols";
    }
    {
      file = "init.lua";
      content = "local x = 1\n";
      server = "lua_ls";
      binary = "lua-language-server";
    }
    {
      file = "run.sh";
      content = "#!/usr/bin/env bash\necho hi\n";
      server = "bashls";
      binary = "bash-language-server";
    }
    {
      file = "note.md";
      content = "# Title\n\nText.\n";
      server = "marksman";
      binary = "marksman";
    }
    {
      file = "data.json";
      content = ''{ "a": 1 }'' + "\n";
      server = "jsonls";
      binary = "vscode-json-language-server";
    }
    {
      file = "tool.py";
      content = "x = 1\n";
      server = "pyright";
      binary = "pyright-langserver";
    }
    {
      file = "tool.py";
      content = "x = 1\n";
      server = "ruff";
      binary = "ruff";
    }
  ];

  # Python statements, each on a line of its own at the indent of the block.
  lspSteps = lib.concatMapStringsSep "\n    " (
    s: ''lsp("alice", "${s.file}", "${pkgs.writeText s.file s.content}", "${s.server}", "${s.binary}")''
  ) servers;

  treesitterFiles = lib.concatMapStringsSep " " (s: "/home/alice/proj-${s.server}/${s.file}") (
    lib.filter (
      s:
      lib.elem s.server [
        "nil_ls"
        "ols"
        "lua_ls"
        "marksman"
      ]
    ) servers
  );

  # A note with a mistake in it, for the LanguageTool checks to send.
  note = pkgs.writeText "note.md" "# Title\n\nThis is a sentense.\n";
in
lib.throwIf (warnings != [ ])
  "home-manager warns about the editor module: ${lib.concatStringsSep "; " warnings}"
  (
    pkgs.testers.runNixOSTest {
      name = "common-nvim";

      nodes.machine =
        { ... }:
        {
          imports = [ inputs.home-manager.nixosModules.home-manager ];
          # lua_ls, pyright and ltex-ls-plus (a JVM) start in here.
          virtualisation.memorySize = 4096;
          users.users = {
            alice.isNormalUser = true;
            bob.isNormalUser = true;
            carol.isNormalUser = true;
            dave.isNormalUser = true;
            erin.isNormalUser = true;
          };
          home-manager = {
            useGlobalPkgs = true;
            users.alice = user { };
            # The template's me.nix says mauve; a user's own value replaces it.
            users.bob = user { ravnix.theme.accent = lib.mkForce "teal"; };
            # A spec of her own beside the generated config, for a plugin the
            # store does not have.
            users.carol = user {
              xdg.configFile."nvim/lua/plugins/bogus.lua".text = "return { { 'someone/not-in-the-store.nvim' } }";
            };
            # A spec of his own whose setup fails only when VeryLazy comes.
            users.dave = user {
              xdg.configFile."nvim/lua/plugins/boom.lua".text =
                "return { { 'folke/flash.nvim', config = function() error('boom at VeryLazy') end } }";
            };
            # A host that needs a few languages.
            users.erin = user {
              ravnix.editor.languages = [
                "lua"
                "nix"
              ];
            };
          };
        };

      testScript = ''
        import shlex

        def run(user, command):
            return machine.execute(f"su - {user} -c {shlex.quote(command)} 2>&1")

        def probe(user, name, env=""):
            status, out = run(user, f"{env} PROBE={name} nvim --headless -c 'luafile ${probe}'")
            assert status == 0, f"{user}: probe {name} failed:\n{out}"
            print(out)

        def must_fail(user, name, mentions, env=""):
            status, out = run(user, f"{env} PROBE_EXPECT_FAILURE=1 PROBE={name} timeout 60 nvim --headless -c 'luafile ${probe}'")
            assert status != 0, f"{user}: probe {name} passed, and it must fail:\n{out}"
            assert mentions in out, f"{user}: probe {name} failed, but not because of {mentions}:\n{out}"
            print(f"(expected) {user}: probe {name} failed because of {mentions}:\n{out}")

        def project(user, server, name, source):
            directory = f"/home/{user}/proj-{server}"
            machine.succeed(f"install -d -o {user} {directory}/.git && install -o {user} {source} {directory}/{name}")
            return directory

        def lsp(user, name, source, server, binary):
            directory = project(user, server, name, source)
            probe(user, "lsp", f"PROBE_FILE={directory}/{name} PROBE_SERVER={server} PROBE_BINARY={binary}")

        machine.wait_for_unit("multi-user.target")
        for user in ["alice", "bob", "carol", "dave", "erin"]:
            machine.wait_for_unit(f"home-manager-{user}.service")

        with subtest("the machine has no way out, so nothing can be fetched"):
            machine.fail("getent hosts github.com")
            machine.fail("timeout 5 bash -c '</dev/tcp/1.1.1.1/443'")

        with subtest("the health check of lazy.nvim passes without network"):
            for user in ["alice", "bob"]:
                status, out = run(user, f"nvim --headless '+checkhealth lazy' '+w! /tmp/health-{user}.txt' +qa")
                assert status == 0, f"{user}: nvim exited {status}:\n{out}"
                report = machine.succeed(f"cat /tmp/health-{user}.txt")
                print(report)
                assert "ERROR" not in report and "WARNING" not in report, report
                assert "lazy.nvim" in report, report

        with subtest("four editors at once do not trip over each other"):
            status, out = run("alice", "pids=; for i in 1 2 3 4; do nvim --headless '+checkhealth lazy' \"+w! /tmp/parallel-$i.txt\" +qa & pids=\"$pids $!\"; done; rc=0; for pid in $pids; do wait $pid || rc=1; done; exit $rc")
            assert status == 0, out
            for i in range(1, 5):
                report = machine.succeed(f"cat /tmp/parallel-{i}.txt")
                assert "ERROR" not in report and "WARNING" not in report, report

        with subtest("the editor starts clean, with everything set up that waits for VeryLazy"):
            probe("alice", "clean")
            probe("bob", "clean")

        with subtest("it does under a real terminal too (a pty, which attaches a UI by itself)"):
            # Nothing answers the terminal queries Neovim sends into a pty.
            for name in ["clean", "opaque"]:
                status, out = run("alice", f"TERM=xterm-256color PROBE_ALLOW=E1568 PROBE={name} script -qec \"nvim -c 'luafile ${probe}'\" /dev/null")
                assert status == 0, f"{name} under a pty:\n{out}"
                assert f"PROBE {name} OK" in out, out

        with subtest("an error that only comes with VeryLazy fails the probe"):
            must_fail("dave", "clean", "boom at VeryLazy")

        with subtest("the plugins come from the store, and Mason is gone"):
            probe("alice", "store")

        with subtest("a plugin that is not in the store is an error, never a download"):
            must_fail("carol", "store", "not-in-the-store.nvim")
            machine.fail("test -e /home/carol/.local/share/nvim/lazy/not-in-the-store.nvim")

        with subtest("the style: Mocha in the accent, single borders"):
            probe("alice", "style", "PROBE_ACCENT=${palette.mauve} PROBE_BASE=${palette.base}")
            probe("bob", "style", "PROBE_ACCENT=${palette.teal} PROBE_BASE=${palette.base}")

        with subtest("nothing is see-through, nothing dims what is behind it"):
            probe("alice", "opaque")
            probe("bob", "opaque")

        with subtest("each language server starts within 10 s from the store"):
            ${lspSteps}

        with subtest("treesitter highlights from the Nix-built parsers"):
            probe("alice", "treesitter", "PROBE_FILES='${treesitterFiles}'")

        with subtest("the editing options and the Markdown links are the configured ones"):
            probe("alice", "options", "PROBE_FILE=/home/alice/proj-marksman/note.md")

        with subtest("the LanguageTool dictionary and credentials, with rbw as the vault answers"):
            probe("alice", "languagetool", "PATH=${fakeRbw}/bin:$PATH")

        with subtest("the LanguageTool toggle, against ltex-ls-plus and a stand-in server"):
            machine.succeed("systemd-run --unit=lt-server ${pkgs.python3}/bin/python3 ${ltServer} 8081 /tmp/lt-server.log")
            machine.wait_for_open_port(8081)
            directory = project("alice", "lt", "note.md", "${note}")
            probe(
                "alice",
                "toggle",
                f"LANGUAGETOOL_API_KEY=${secret} LANGUAGETOOL_USERNAME=alice@lt.test LANGUAGETOOL_SERVER=http://127.0.0.1:8081 PROBE_SECRET=${secret} PROBE_USER=alice%40lt.test PROBE_SERVER_LOG=/tmp/lt-server.log PROBE_FILE={directory}/note.md",
            )
            # The stand-in is the one place that has the key; nothing the
            # editor wrote to the user's home has it.
            machine.succeed("grep -F 'apiKey=${secret}' /tmp/lt-server.log")
            machine.fail("grep -rF '${secret}' /home/alice /var/tmp")
            machine.succeed("systemctl stop lt-server")

        with subtest("without credentials the toggle says so and starts nothing"):
            directory = "/home/alice/proj-lt"
            probe("alice", "toggle_missing", f"FAKE_RBW_LOCKED=1 PATH=${fakeRbw}/bin:$PATH PROBE_FILE={directory}/note.md")

        with subtest("a host that leaves languages out gets an editor that does not start their tools"):
            odin = project("erin", "odin", "main.odin", "${pkgs.writeText "main.odin" "package main\n"}")
            python = project("erin", "py", "tool.py", "${pkgs.writeText "tool.py" "x = 1\n"}")
            nix = project("erin", "nix", "flake.nix", "${pkgs.writeText "flake.nix" "{ pkgs }: pkgs.hello\n"}")
            probe("erin", "clean")
            probe(
                "erin",
                "scoped",
                f"PROBE_FILES='{odin}/main.odin {python}/tool.py' PROBE_ABSENT='ols odinfmt pyright-langserver ruff ltex-ls-plus marksman bash-language-server shfmt vscode-json-language-server prettier markdownlint-cli2' PROBE_SERVERS_OFF='ols pyright ruff bashls marksman jsonls ltex_plus' PROBE_FORMATTER_FT_OFF='odin markdown sh' PROBE_FILE_KEPT={nix}/flake.nix PROBE_SERVER_KEPT=nil_ls",
            )

        with subtest("an empty file, a binary file and one 10 MB line open and close"):
            machine.succeed("su - alice -c 'mkdir -p edge && cd edge && : > empty.nix && head -c 100000 /dev/urandom > binary.dat && yes x | head -c 10000000 | tr -d \"\\n\" > long.json'")
            for name in ["empty.nix", "binary.dat", "long.json"]:
                status, out = run("alice", f"cd edge && timeout 60 nvim --headless {name} '+sleep 500m' +qa")
                assert status == 0, f"{name}: nvim exited {status}:\n{out}"
      '';
    }
  )
