# The exclude patterns of the host's backup (./backup.nix), made from
# ravnix.backup.nas's paths, exclude and keep. Not a module: backup.nix and
# its test call it as
#
#   import ./backup-excludes.nix { inherit lib; } { home; paths; exclude; keep; always; }
#   => { patterns = [ "--exclude" values, in order ]; problems = [ messages ]; }
#
# Why keep is an option and not a `!` pattern in exclude. restic never goes
# into a directory it excludes, so `~/Nextcloud` with `!~/Nextcloud/notes`
# leaves out notes as well; a path of `paths` inside an excluded directory is
# worse, since restic records the bare directory and nothing in it. Both
# lose the carved-back folder without a word (checked with restic 0.19.1).
# What works is to exclude the directory's contents, not the directory, and
# to take the way to the kept path back, one level at a time:
#
#   ~/Nextcloud/*  !~/Nextcloud/a  ~/Nextcloud/a/*  !~/Nextcloud/a/b
#
# restic decides by the last pattern that matches, and a pattern matches a
# path's parents too, so the order matters: a pattern for a deeper level
# comes later, and at one level the way back comes after the exclusion. The
# other entries of exclude follow, so they can only leave out more, never
# take anything back, and the entries of always, which nothing takes back,
# come last.
{ lib }:
{
  home,
  paths,
  exclude,
  keep,
  # Left out whatever keep says, such as ~/.cache; a kept path inside one
  # is refused.
  always ? [ ],
}:
let
  expand =
    p:
    if p == "~" then
      home
    else if lib.hasPrefix "~/" p then
      home + lib.removePrefix "~" p
    else
      p;
  # restic reads `*`, `?`, `[` and `\` in a pattern as a wildcard, a class
  # and an escape (Go's filepath.Match). In a path of its own, a kept one or
  # the home, each is that character, so the pattern escapes it: an
  # unescaped `[2024] notes` would match `2 notes` and lose the folder.
  escape = lib.replaceStrings [ "\\" "*" "?" "[" ] [ "\\\\" "\\*" "\\?" "\\[" ];
  under = parent: p: lib.hasPrefix "${parent}/" p;
  # A pattern without restic's wildcards, as the user wrote it (the home's
  # own characters do not count), so "under" means what it says.
  plain = p: builtins.match ".*[][*?\\].*" (lib.removePrefix "~" p) == null;

  # The user's pattern, with the home in front of it escaped.
  pattern' =
    e:
    if e == "~" then
      escape home
    else if lib.hasPrefix "~/" e then
      escape home + lib.removePrefix "~" e
    else
      e;
  fixed = map (e: {
    path = expand e;
    plain = plain e;
    pattern = pattern' e;
  }) always;
  excluded = map (e: {
    path = expand e;
    plain = plain e;
    pattern = pattern' e;
  }) exclude;
  kept = lib.unique (map expand keep);
  backedUp = map expand paths;
  # A path kept inside another kept path is kept by that one already.
  outer = lib.filter (k: !lib.any (other: under other k) kept) kept;
  carvedFrom = k: map (e: e.path) (lib.filter (e: e.plain && under e.path k) excluded);
  stray = lib.filter (k: carvedFrom k == [ ]) outer;
  carving = lib.filter (k: carvedFrom k != [ ]) outer;
  outside = lib.filter (k: !lib.any (p: p == k || under p k) backedUp) kept;
  sealed = k: lib.filter (e: e.path == k || under e.path k) fixed;

  # The steps from the outermost excluded directory down to k.
  steps =
    k:
    let
      top = lib.head (lib.sort (a: b: lib.stringLength a < lib.stringLength b) (carvedFrom k));
      below = lib.splitString "/" (lib.removePrefix "${top}/" k);
      dirs = lib.genList (i: "${top}/${lib.concatStringsSep "/" (lib.take (i + 1) below)}") (
        lib.length below
      );
    in
    [
      {
        dir = top;
        back = false;
      }
    ]
    ++ lib.concatMap (
      d:
      [
        {
          dir = d;
          back = true;
        }
      ]
      ++ lib.optional (d != k) {
        dir = d;
        back = false;
      }
    ) dirs;
  # `D/*` matches one level below D, `!D` D itself.
  depth = s: lib.length (lib.splitString "/" s.dir) + (if s.back then 0 else 1);
  ordered = lib.sort (a: b: depth a < depth b || (depth a == depth b && !a.back && b.back)) (
    lib.unique (lib.concatMap steps carving)
  );
  pattern = s: if s.back then "!${escape s.dir}" else "${escape s.dir}/*";
  carved = lib.unique (lib.concatMap carvedFrom carving);

  buried =
    p: map (e: e.path) (lib.filter (e: e.plain && (e.path == p || under e.path p)) (excluded ++ fixed));
  isKept = p: lib.any (k: k == p || under k p) kept;
in
{
  patterns =
    map pattern ordered
    ++ map (e: e.pattern) (lib.filter (e: !lib.elem e.path carved) excluded)
    ++ map (e: e.pattern) fixed;
  problems =
    map (
      k:
      "ravnix.backup.nas.keep has ${k}, which is inside no plain path of exclude (one without *, ? or [): it is backed up anyway, or a wildcard leaves it out; drop it, or exclude its parent by name"
    ) stray
    ++ map (
      k: "ravnix.backup.nas.keep has ${k}, which is inside no entry of paths: nothing backs it up. Drop it, or add a path above it"
    ) outside
    ++ map (
      k:
      "ravnix.backup.nas.keep has ${k}, which is inside ${(lib.head (sealed k)).path}, which is left out always: drop it"
    ) (lib.filter (k: sealed k != [ ]) kept)
    ++ lib.concatMap (
      p:
      let
        p' = expand p;
      in
      lib.optional (buried p' != [ ] && !isKept p')
        "ravnix.backup.nas.paths has ${p'}, which exclude leaves out (${lib.head (buried p')}): restic would record the bare directory and nothing in it. Put it in keep instead."
    ) paths;
}
