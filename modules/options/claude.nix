# The personal values of the public Claude Code skills: names, destinations
# and ids that the skills read from one generated JSON file instead of
# carrying them in their text. And the MCP servers Claude Code starts with.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.ravnix.claude;

  # What JSON can hold. No Nix paths: a path would be copied into the store
  # and rendered as its store path.
  json =
    types.nullOr (
      types.oneOf [
        types.bool
        types.int
        types.float
        types.str
        (types.attrsOf json)
        (types.listOf json)
      ]
    )
    // {
      description = "JSON value";
    };

  # What a header or an environment value of a server may be. Claude Code
  # resolves ${NAME} in its own environment when it reads the config, so the
  # value in the Nix store is the reference, and the token is in the
  # environment of the one process that needs it (ravnix.shell.secretEnv puts
  # it there). The reference may follow an authorization scheme, because that
  # is what a header looks like (`Bearer ${NAME}`); nothing else may stand
  # beside it, and a default (`${NAME:-x}`) is a place for a token to hide.
  reference = "([$][{][A-Za-z_][A-Za-z0-9_]*[}])";
  isReference = v: builtins.isString v && builtins.match "((Bearer|Basic|Token) )?${reference}" v != null;

  # The fields of a server that carry values to the server, by what the
  # message calls them. Both are sets of values, or absent.
  valueFields = [
    "headers"
    "env"
  ];

  # One message per fault, naming the server, the field and the key, and
  # never the value: it may be a token pasted by mistake, and the message
  # goes to the terminal and the log.
  faults = lib.concatMap (
    name:
    let
      server = cfg.mcpServers.${name};
      where = "ravnix.claude.mcpServers.${name}";
      field =
        f:
        let
          v = server.${f};
        in
        if v == null || !builtins.isAttrs v then
          [ "${where}.${f} must be a set of strings, each a reference such as \"Bearer \${NAME}\" or \"\${NAME}\"." ]
        else
          map (
            key:
            "${where}.${f}.${key} is not a reference such as \"Bearer \${NAME}\" or \"\${NAME}\": a header or an environment value holds a variable of Claude Code's environment (a secret reaches it through ravnix.shell.secretEnv), never the value itself, so that no token enters the Nix store."
          ) (lib.filter (key: !isReference v.${key}) (lib.attrNames v));
    in
    if !builtins.isAttrs server then
      [ "${where} must be a set, the JSON of one server as Claude Code's mcpServers holds it." ]
    else
      lib.concatMap field (lib.filter (f: server ? ${f}) valueFields)
  ) (lib.attrNames cfg.mcpServers);
in
{
  options.ravnix.claude.skillValues = mkOption {
    type = types.attrsOf json;
    default = { };
    example = {
      vault.root = "/home/alice/notes";
    };
    description = ''
      The values the public skills read, rendered to JSON. A skill whose
      value is missing stops and names the key to set.
    '';
  };

  options.ravnix.claude.skills = mkOption {
    type = types.attrsOf (types.nullOr types.path);
    default = { };
    example = lib.literalExpression ''
      {
        # A skill of your own, or one pinned from upstream in your flake.
        my-skill = ./claude/skills/my-skill;
        # One of ravnix's own, left out.
        laptop = null;
      }
    '';
    description = ''
      Claude Code skills to link into the user's skills directory
      (~/.claude/skills/NAME) beside ravnix's own (claude/skills/README.md,
      rendered with `skillValues`), by name: each a directory with a
      SKILL.md. A name of ravnix's set here replaces ravnix's skill, and
      null leaves it out.
    '';
  };

  options.ravnix.claude.skillOverrides = mkOption {
    # The states Claude Code 2.1 knows for its skillOverrides setting.
    type = types.attrsOf (
      types.enum [
        "on"
        "name-only"
        "user-invocable-only"
        "off"
      ]
    );
    default = { };
    example = {
      json-canvas = "off";
      tutor = "user-invocable-only";
    };
    description = ''
      How Claude Code lists a skill to the model, by the skill's name as
      Claude Code shows it (a plugin's skill as PLUGIN:NAME): "name-only"
      lists it without its description, "user-invocable-only" hides it
      from the model but keeps /NAME, "off" hides it from both, and "on"
      is what an absent name means. Written to the settings'
      skillOverrides, where a name set here replaces the file's state and
      every other name keeps the one Claude Code wrote (/skills, /config).
      A name taken out here keeps its last state in the file.
    '';
  };

  options.ravnix.claude.mcpServers = mkOption {
    type = types.attrsOf json;
    default = { };
    example = {
      docs = {
        type = "http";
        url = "https://mcp.example.org/mcp";
        headers.Authorization = "Bearer \${DOCS_API_TOKEN}";
      };
      browser = {
        type = "stdio";
        command = "example-mcp";
        args = [ "--headless" ];
      };
    };
    description = ''
      The MCP servers Claude Code knows in every project (its user scope), by
      name, each the JSON that Claude Code's `mcpServers` holds for a server.
      The servers of this option are put into Claude Code's config
      (~/.claude.json) at every switch. A server you add yourself with
      `claude mcp add --scope user` stays, and a server you stop declaring
      here is taken out at the next switch.

      A header or an environment value must be a reference to a variable of
      Claude Code's environment: `''${NAME}`, or `Bearer ''${NAME}` (also
      `Basic` and `Token`). Anything else is refused at evaluation, so that
      no token can enter the Nix store. The variable gets its value from
      `ravnix.shell.secretEnv`, which the `claude` function reads from your
      Bitwarden when Claude Code starts.
    '';
  };

  config.assertions = map (message: {
    assertion = false;
    inherit message;
  }) faults;
}
