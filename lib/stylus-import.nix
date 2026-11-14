# The Catppuccin userstyles as one Stylus import file in the theme: the
# `import.json` of github.com/catppuccin/userstyles' releases, with every
# style's flavor set to Mocha and its accent to the host's, so the step in
# Stylus is Manage, Backup, Import, one click, and no style needs its settings
# opened (modules/desktop/apps.nix, "Userstyles").
#
#   callPackage ./stylus-import.nix { } { src, accent }
#
#   src      the file, as a path: a fetchurl of the release asset with your
#            own hash (ravnix.apps.userstylesImport). ravnix pins none, and
#            this checkout has no copy of the file.
#   accent   "mauve", "teal" ... (ravnix.theme.accent)
#
# The file is a JSON array of Stylus styles. A UserCSS style has
# `usercssData.vars`, and the userstyles declare three select variables there:
# `lightFlavor`, `darkFlavor` (both set to "mocha": the palette is Mocha,
# always) and `accentColor`. Stylus keeps the chosen option's name in the
# variable's `value`, which is what is set. Every other entry, and every other
# variable, is left as it is.
#
# It stops, and names what it found, when the shape is not the one described:
# an option the variable does not offer, or a file in which no style has an
# `accentColor` at all. A wrong guess about the file must fail the build, not
# produce an import that changes nothing.
{ runCommand, jq }:
{ src, accent }:
runCommand "stylus-import.json"
  {
    nativeBuildInputs = [ jq ];
    inherit src accent;
  }
  ''
    jq --arg accent "$accent" --arg flavor mocha '
      def choose($name; $want):
        if has($name) then
          if (.[$name].options // [] | any(.name == $want)) then
            .[$name].value = $want
          else
            error("variable \($name) has no option \($want)")
          end
        else . end;
      if type != "array" then error("not a JSON array of styles") else . end
      | map(
          if (.usercssData.vars? | type) == "object" then
            .usercssData.vars |= (
              choose("lightFlavor"; $flavor)
              | choose("darkFlavor"; $flavor)
              | choose("accentColor"; $accent)
            )
          else . end)
      | if any(.[]; (.usercssData.vars? | type) == "object" and (.usercssData.vars | has("accentColor")))
        then . else error("no style has an accentColor variable: this is not the userstyles import file") end
    ' "$src" > "$out"
  ''
