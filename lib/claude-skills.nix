# The public skills of claude/skills/, rendered with the user's skill values
# (claude/skills/README.md).
#
#   import ./claude-skills.nix { inherit lib; }
#   => { names; requires; steps; renderText; renderSkill; render; }
#
# A skill's Markdown names a personal value as {{KEY}}, KEY a dotted path
# into ravnix.claude.skillValues (`{{user.name}}`). Claude Code reads a
# skill's description before any script runs, so the values go into the
# text when the home is built, from the same values that skill-values.json
# holds; the scripts read that file at run time. A value is set when it is
# a string that is not blank, or a number. Three names are ravnix's own and
# need no value: {{ravnix.python}}, the python3 the scripts run with;
# {{ravnix.skillDir}}, this skill's directory as installed; and
# {{ravnix.skillsDir}}, the directory of all of them. Any other ravnix.* is
# a mistake in the skill and fails the build.
#
# A value is put in as written, once: a {{...}} inside it stays literal. In
# the frontmatter a value's white space runs together, so a value with a
# line break cannot break the YAML around it.
#
# A key the skill needs that is not set leaves its name in the text, in
# backticks, and puts one line per such key right below the SKILL.md
# frontmatter: "set `KEY` in your ravnix skill values", under an
# instruction to stop. So the skill still loads, and says what is missing
# instead of acting on a hole. A skill needs the keys its Markdown names
# and the ones `requires` lists for it, which its scripts read; those must
# also be of the type given there. A key that `steps` lists stops one step
# only: the notice then names that step and how to go on without it, and
# the rest of the skill holds.
#
# Only *.md files are rendered. Everything else is copied as it is, and the
# scripts read their values from skill-values.json themselves.
{ lib }:
let
  placeholder = "[{][{]([A-Za-z0-9_.-]+)[}][}]";

  # The keys a skill's scripts read, with the type each must have.
  requires = {
    handoff = {
      "handoff.workspaces" = "set";
      "plane.mcpUrl" = "string";
    };
    journal = {
      "vault.root" = "string";
    };
    ai-memory = {
      "vault.root" = "string";
    };
  };

  # Keys whose absence stops one step of a skill, not the skill: the
  # rendered SKILL.md names the step, the keys and how to go on without it,
  # and everything else the skill describes still holds. Typed as in
  # `requires`. A key the whole skill needs as well still stops it whole.
  steps = {
    # LanguageTool Premium or say so: check.py never drops to the free tier
    # on its own, and --no-lt runs every other check.
    prose = {
      keys = {
        "prose.languagetool.item" = "string";
        "prose.languagetool.username" = "string";
      };
      step = "LanguageTool";
      what = "the second pass of `scripts/check.py`";
      without = "run the checker with `--no-lt` and say that LanguageTool did not run";
    };
  };

  isSet =
    type: v:
    if type == "set" then
      builtins.isAttrs v && v != { }
    else if type == "string" then
      builtins.isString v && lib.trim v != ""
    else
      throw "lib/claude-skills.nix: unknown type ${type}";

  # The text a value is put in as, or null when it is not set.
  asText =
    v:
    if builtins.isString v then
      (if lib.trim v == "" then null else v)
    else if builtins.isInt v || builtins.isFloat v then
      toString v
    else
      null;

  lookup = values: key: lib.attrByPath (lib.splitString "." key) null values;

  # One text: the rendered string and the keys it named that are not set.
  renderText =
    {
      values,
      internal,
      inFrontmatter ? false,
    }:
    text:
    let
      parts = builtins.split placeholder text;
      one =
        part:
        if builtins.isString part then
          {
            text = part;
            missing = [ ];
          }
        else
          let
            key = builtins.head part;
            isInternal = lib.hasPrefix "ravnix." key;
            value =
              if isInternal then
                internal.${key} or (throw "claude/skills: {{${key}}} is no placeholder ravnix knows")
              else
                asText (lookup values key);
            shown = if inFrontmatter then lib.concatStringsSep " " (lib.filter (w: w != "") (lib.splitString "\n" value)) else value;
          in
          if value == null then
            {
              text = "`${key}`";
              missing = [ key ];
            }
          else
            {
              text = shown;
              missing = [ ];
            };
      done = map one parts;
    in
    {
      text = lib.concatMapStrings (d: d.text) done;
      missing = lib.unique (lib.concatMap (d: d.missing) done);
    };

  # SKILL.md: the frontmatter, up to and with its closing ---, and the body.
  splitFrontmatter =
    text:
    let
      lines = lib.splitString "\n" text;
      close = lib.lists.findFirstIndex (l: l == "---") null (lib.drop 1 lines);
    in
    if lines != [ ] && builtins.head lines == "---" && close != null then
      {
        front = lib.concatStringsSep "\n" (lib.take (close + 2) lines) + "\n";
        body = lib.concatStringsSep "\n" (lib.drop (close + 2) lines);
      }
    else
      {
        front = "";
        body = text;
      };

  stopNotice =
    keys:
    "\n> **Stop: this skill is not set up.** Tell the user what follows, and do\n"
    + "> nothing else that this skill describes until it is done and the home is\n"
    + "> switched again (`ravnix.claude.skillValues` in the private flake):\n"
    + lib.concatMapStrings (k: ">\n> - set `${k}` in your ravnix skill values\n") keys;

  stepNotice =
    s: keys:
    "\n> **${s.step} is not set up.** It is ${s.what}. Until it is\n"
    + "> (`ravnix.claude.skillValues` in the private flake, then switch the home\n"
    + "> again), ${s.without}. Everything else this skill describes still applies.\n"
    + lib.concatMapStrings (k: ">\n> - set `${k}` in your ravnix skill values\n") keys;

  # One skill: { dir; md = { RELPATH = TEXT; }; missing = [ KEY ]; }
  renderSkill =
    {
      name,
      dir,
      values,
      python,
      skillsDir,
    }:
    let
      internal = {
        "ravnix.python" = python;
        "ravnix.skillDir" = "${skillsDir}/${name}";
        "ravnix.skillsDir" = skillsDir;
      };
      root = toString dir;
      rel = f: lib.removePrefix "${root}/" (toString f);
      all = lib.filesystem.listFilesRecursive dir;
      isMd = f: lib.hasSuffix ".md" (toString f);
      rendered = map (
        f:
        let
          text = builtins.readFile f;
          isSkill = rel f == "SKILL.md";
          parts = if isSkill then splitFrontmatter text else { front = ""; body = text; };
          front = renderText {
            inherit values internal;
            inFrontmatter = true;
          } parts.front;
          body = renderText { inherit values internal; } parts.body;
        in
        {
          path = rel f;
          inherit isSkill;
          front = front.text;
          body = body.text;
          missing = front.missing ++ body.missing;
        }
      ) (lib.filter isMd all);
      required = lib.filter (k: !(isSet requires.${name}.${k} (lookup values k))) (
        lib.attrNames (requires.${name} or { })
      );
      step = steps.${name} or null;
      stepMissing =
        if step == null then
          [ ]
        else
          lib.filter (k: !(isSet step.keys.${k} (lookup values k))) (lib.attrNames step.keys);
      stops = lib.unique (lib.concatMap (r: r.missing) rendered ++ required);
      missing = lib.unique (stops ++ stepMissing);
      notice =
        if stops != [ ] then
          stopNotice missing
        else if stepMissing != [ ] then
          stepNotice step stepMissing
        else
          "";
      md = lib.listToAttrs (
        map (r: lib.nameValuePair r.path (if r.isSkill then r.front + notice + r.body else r.front + r.body)) rendered
      );
    in
    {
      inherit dir md missing;
    };

  # The skills of claude/skills/: each directory there that holds a SKILL.md.
  names =
    src:
    lib.attrNames (
      lib.filterAttrs (n: t: t == "directory" && builtins.pathExists (src + "/${n}/SKILL.md")) (
        builtins.readDir src
      )
    );

  # Every skill as one tree, a directory per skill, so a skill finds a
  # sibling's scripts as journal finds ai-memory's (../ai-memory/scripts).
  render =
    {
      pkgs,
      src,
      values,
      skillsDir,
      python ? lib.getExe pkgs.python3,
    }:
    let
      skills = lib.genAttrs (names src) (
        name:
        renderSkill {
          inherit
            name
            values
            python
            skillsDir
            ;
          dir = src + "/${name}";
        }
      );
      # The skill's files as they are, then each Markdown file rendered over
      # its copy.
      install =
        name: s:
        "cp -r ${s.dir} \"$out\"/${lib.escapeShellArg name}\nchmod -R u+w \"$out\"/${lib.escapeShellArg name}\n"
        + lib.concatStrings (
          lib.mapAttrsToList (
            rel: text:
            "cp ${pkgs.writeText "skill-${name}-${baseNameOf rel}" text} \"$out\"/${lib.escapeShellArg "${name}/${rel}"}\n"
          ) s.md
        );
    in
    pkgs.runCommandLocal "ravnix-claude-skills"
      {
        passthru = {
          names = lib.attrNames skills;
          missing = lib.mapAttrs (_: s: s.missing) skills;
        };
      }
      (
        "mkdir -p \"$out\"\n"
        + lib.concatStrings (lib.mapAttrsToList install skills)
        + "find \"$out\" -name __pycache__ -prune -exec rm -r {} +\n"
      );
in
{
  inherit
    names
    requires
    steps
    renderText
    renderSkill
    render
    ;
}
