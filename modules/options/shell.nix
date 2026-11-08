# What the shell reads from the user: which Bitwarden items `claude` gets as
# environment variables, and the seam that ravnix's own modules use to start a
# persistent session in a new terminal. Both are read by modules/common
# (bash.nix); they sit here, with the other options, so that a private flake's
# me.nix can set them and its `me` check accepts them.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.ravnix.shell;

  # The names go into generated shell code and into the environment of one
  # process, so they must be names a shell accepts for a variable, written the
  # way environment variables are: capital letters, digits and underscores.
  identifier = "[A-Z_][A-Z0-9_]*";

  # What a secret must not overwrite, in claude's environment or anywhere: the
  # variables a shell, the dynamic loader or Claude Code read to know where
  # they are and what to run, those bash keeps read-only, and those that
  # ravnix's own tools read or hand to one another.
  reservedNames = [
    "PATH"
    "HOME"
    "USER"
    "LOGNAME"
    "SHELL"
    "PWD"
    "OLDPWD"
    "TERM"
    "IFS"
    "ENV"
    "CDPATH"
    "GLOBIGNORE"
    "SHELLOPTS"
    "PROMPT_COMMAND"
    "PS0"
    "PS1"
    "PS2"
    "PS4"
    "UID"
    "EUID"
    "PPID"
    "HISTFILE"
    "XDG_RUNTIME_DIR"
    "CLAUDECODE"
    # What ravnix's own tools (packages/NAME) read from their environment for
    # themselves and are not part of a family below. A secret under one of
    # these would change where a tool looks for its notes, its vault or its
    # state. tests/options/secret-env-reserved.nix reads the sources of
    # packages/ and fails when a tool reads one that is missing here.
    "VAULT_DIR"
    "MACHINE_NOTE"
    "AI_MEMORY_LINT"
    "SEARXNG_URL"
    "SEARX_TIMEOUT"
    "XDG_CONFIG_HOME"
    "XDG_STATE_HOME"
    "TMPDIR"
    "DBUS_SESSION_BUS_ADDRESS"
  ];
  # A name that starts with BASH or LD_ is one of the families bash and the
  # loader own. The others are the families of ravnix's tools: with-secret-env
  # hands its reason on in WITH_SECRET_ENV_WHY and claude-bg prints its own
  # CLAUDE_BG_WHY, so a secret exported under either would be printed.
  reservedPrefixes = [
    "BASH"
    "LD_"
    "RAVNIX_"
    "WITH_SECRET_ENV_"
    "CLAUDE_BG_"
    "CCNA_DECK_"
    "SAP_DECK_"
    "AGENT_DOCTOR_"
    "CLAUDE_TELEMETRY_"
    "VAULT_CHECK_"
    # The browser the Chrome DevTools MCP wrapper runs, and where it puts its
    # launch (CHROME_DEVTOOLS_HELIUM, CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP).
    "CHROME_DEVTOOLS_HELIUM"
  ];
  reserved = name: lib.elem name reservedNames || lib.any (p: lib.hasPrefix p name) reservedPrefixes;
in
{
  options.ravnix.shell = {
    secretEnv = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        SERVICE_API_TOKEN = "Service - API token";
      };
      description = ''
        Environment variables that `claude` gets from your Bitwarden through
        rbw: the variable's name (capital letters, digits and underscores; not
        one the shell, the loader or a ravnix tool reads, such as PATH,
        BASH_ENV or CLAUDE_BG_WHY), and the
        name or id of the Bitwarden item whose password is its value (rbw
        takes either; an id is the safer one, because renaming the item
        never breaks it). When you run `claude` in an interactive bash, a
        function reads the items and starts Claude Code with them in its
        environment, so Claude Code and the programs it starts see them and
        nothing else does. `ai-unlock` unlocks the vault first. Only the item
        names or ids are in your flake; the values come from rbw at the
        moment `claude` starts and are never written down.
      '';
    };

    autoAttach = mkOption {
      type = types.lines;
      default = "";
      internal = true;
      example = ''
        [[ -z $SSH_CONNECTION ]] && exec some-multiplexer attach
      '';
      description = ''
        Shell code that runs first in every interactive bash, before
        anything else is set up. It is the seam for the module that drops a
        new terminal into a persistent session (an `exec` belongs here, so
        a shell that is about to be replaced does not pay for the rest of
        its start). Empty when no such module is in use.

        Run as the first thing, it finds the shell as bash starts it: the
        aliases of ravnix's shell module (`cd` among them) and its functions
        (`zd`, `claude`) are not defined yet, and the history, the prompt and
        the completion are not set up. An alias that another module adds
        through `programs.bash.shellAliases` is already live, and a
        function is not, so a seam that calls a function of its own must
        define it first.
      '';
    };
  };

  # One assertion per name, so each wrong one is named in a message of its own.
  config.assertions = lib.concatMap (name: [
    {
      assertion = builtins.match identifier name != null;
      message = "ravnix.shell.secretEnv has the name \"${name}\", which is not an environment variable name in capital letters ([A-Z_][A-Z0-9_]*).";
    }
    {
      assertion = !reserved name;
      message = "ravnix.shell.secretEnv has the name \"${name}\", which the shell, the loader or Claude Code read themselves (${lib.concatStringsSep ", " (reservedNames ++ map (p: "${p}*") reservedPrefixes)}); a secret under that name would break claude's start.";
    }
  ]) (lib.attrNames cfg.secretEnv);
}
