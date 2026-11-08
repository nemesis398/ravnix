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
  # they are and what to run, and those bash keeps read-only. A name that
  # starts with BASH or LD_ is one of the families bash and the loader own.
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
  ];
  reservedPrefixes = [
    "BASH"
    "LD_"
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
        one the shell or the loader reads, such as PATH or BASH_ENV), and the
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
      message = "ravnix.shell.secretEnv has the name \"${name}\", which the shell, the loader or Claude Code read themselves (${lib.concatStringsSep ", " reservedNames}, BASH*, LD_*); a secret under that name would break claude's start.";
    }
  ]) (lib.attrNames cfg.secretEnv);
}
