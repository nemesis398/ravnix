# The exclude patterns of the host's backup (./backup.nix), made from
# ravnix.backup.nas's paths, exclude and keep. Not a module: backup.nix and
# its test call it as
#
#   import ./backup-excludes.nix { inherit lib; } { home; paths; exclude; keep; }
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
# take anything back.
{ lib }:
{
  home,
  paths,
  exclude,
  keep,
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
  under = parent: p: lib.hasPrefix "${parent}/" p;
  # A path without restic's wildcards, so "under" means what it says.
  plain = p: builtins.match ".*[][*?\\\\].*" p == null;

  excluded = map expand exclude;
  kept = lib.unique (map expand keep);
  # A path kept inside another kept path is kept by that one already.
  outer = lib.filter (k: !lib.any (other: under other k) kept) kept;
  carvedFrom = k: lib.filter (e: plain e && under e k) excluded;
  stray = lib.filter (k: carvedFrom k == [ ]) outer;
  carving = lib.filter (k: carvedFrom k != [ ]) outer;

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
  pattern = s: if s.back then "!${s.dir}" else "${s.dir}/*";
  carved = lib.unique (lib.concatMap carvedFrom carving);

  buried = p: lib.filter (e: plain e && (e == p || under e p)) excluded;
  isKept = p: lib.any (k: k == p || under k p) kept;
in
{
  patterns = map pattern ordered ++ lib.filter (e: !lib.elem e carved) excluded;
  problems =
    map (
      k:
      "ravnix.backup.nas.keep has ${k}, which is inside no plain path of exclude (one without *, ? or [): it is backed up anyway, or a wildcard leaves it out; drop it, or exclude its parent by name"
    ) stray
    ++ lib.concatMap (
      p:
      let
        p' = expand p;
      in
      lib.optional (buried p' != [ ] && !isKept p')
        "ravnix.backup.nas.paths has ${p'}, which exclude leaves out (${lib.head (buried p')}): restic would record the bare directory and nothing in it. Put it in keep instead."
    ) paths;
}
