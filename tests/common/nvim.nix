# Neovim with LazyVim, reproducible: the editor starts offline from the Nix
# store alone. A NixOS machine with no way out gets three users (the default
# Mauve accent, Teal, and one whose own plugin spec names a plugin that is not
# in the store) and runs the real editor as each of them:
#
#   - `nvim --headless "+checkhealth lazy" +qa` exits 0 and its report holds
#     no error or warning, alone and four editors at once;
#   - every plugin lazy.nvim knows lives in /nix/store, nothing was cloned or
#     installed into the user's own directories, Mason is gone, and a plugin
#     that is not in the store is an error and never a download;
#   - the first file of a language starts that language's server within
#     10 s, and the server's binary is a Nix one (nil for Nix, ols for Odin,
#     and the servers of the other languages the setup edits);
#   - treesitter highlights from the Nix-built parsers, none missing;
#   - the style spec holds: Catppuccin Mocha with the accent of the option,
#     single-line borders on every float (lazy.nvim's ui.border and Neovim's
#     winborder);
#   - the editing options and the LanguageTool dictionary and credentials
#     (missing, malformed and conflicting input included) behave;
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

  # The user's home-manager configuration: ravnix's options with the
  # template's values (the fixtures of every test that evaluates them), and
  # the module under test.
  user = extra: {
    imports = [
      self.homeModules.options
      (self + "/templates/default/me.nix")
      ../../modules/common/nvim.nix
      extra
    ];
    home.stateVersion = "26.05";
    # The template's values are placeholders and say so in a warning, for
    # each user and on every evaluation; here that is the fixture.
    warnings = lib.mkForce [ ];
  };

  probe = ./helpers/nvim-probe.lua;

  # rbw as the vault would answer: the entry's password and user name, or
  # nothing at all while the vault is locked.
  fakeRbw = pkgs.writeShellScriptBin "rbw" ''
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
in
pkgs.testers.runNixOSTest {
  name = "common-nvim";

  nodes.machine =
    { ... }:
    {
      imports = [ inputs.home-manager.nixosModules.home-manager ];
      # lua_ls and pyright index on start.
      virtualisation.memorySize = 4096;
      users.users = {
        alice.isNormalUser = true;
        bob.isNormalUser = true;
        carol.isNormalUser = true;
      };
      home-manager = {
        useGlobalPkgs = true;
        users.alice = user { };
        users.bob = user { ravnix.theme.accent = "teal"; };
        # A spec of her own beside the generated config, for a plugin the store
        # does not have.
        users.carol = user {
          xdg.configFile."nvim/lua/plugins/bogus.lua".text = "return { { 'someone/not-in-the-store.nvim' } }";
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

    def lsp(user, name, source, server, binary):
        directory = f"/home/{user}/proj-{server}"
        machine.succeed(f"install -d -o {user} {directory} && install -o {user} {source} {directory}/{name}")
        machine.succeed(f"install -d -o {user} {directory}/.git")
        probe(user, "lsp", f"PROBE_FILE={directory}/{name} PROBE_SERVER={server} PROBE_BINARY={binary}")

    machine.wait_for_unit("multi-user.target")
    for user in ["alice", "bob", "carol"]:
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

    with subtest("the plugins come from the store, and Mason is gone"):
        probe("alice", "store")

    with subtest("a plugin that is not in the store is an error, never a download"):
        status, out = run("carol", "PROBE=store timeout 60 nvim --headless -c 'luafile ${probe}'")
        assert status != 0, out
        assert "not-in-the-store.nvim" in out, out
        print(out)
        machine.fail("test -e /home/carol/.local/share/nvim/lazy/not-in-the-store.nvim")

    with subtest("the style: Mocha in the accent, single borders"):
        probe("alice", "style", "PROBE_ACCENT=${palette.mauve} PROBE_BASE=${palette.base}")
        probe("bob", "style", "PROBE_ACCENT=${palette.teal} PROBE_BASE=${palette.base}")

    with subtest("each language server starts within 10 s from the store"):
        ${lspSteps}

    with subtest("treesitter highlights from the Nix-built parsers"):
        probe("alice", "treesitter", "PROBE_FILES='${treesitterFiles}'")

    with subtest("the editing options and the Markdown links are the configured ones"):
        probe("alice", "options", "PROBE_FILE=/home/alice/proj-marksman/note.md")

    with subtest("the LanguageTool dictionary and credentials, with rbw as the vault answers"):
        probe("alice", "languagetool", "PATH=${fakeRbw}/bin:$PATH")

    with subtest("an empty file, a binary file and one 10 MB line open and close"):
        machine.succeed("su - alice -c 'mkdir -p edge && cd edge && : > empty.nix && head -c 100000 /dev/urandom > binary.dat && yes x | head -c 10000000 | tr -d \"\\n\" > long.json'")
        for name in ["empty.nix", "binary.dat", "long.json"]:
            status, out = run("alice", f"cd edge && timeout 60 nvim --headless {name} '+sleep 500m' +qa")
            assert status == 0, f"{name}: nvim exited {status}:\n{out}"
  '';
}
